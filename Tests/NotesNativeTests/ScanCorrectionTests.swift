import CoreGraphics
import ImageIO
import NotesCore
import UniformTypeIdentifiers
import XCTest
@testable import NotesNative

final class ScanCorrectionTests: XCTestCase {
    private let identity = ScanCrop(
        bottomLeft: ScanPoint(x: 0, y: 1), bottomRight: ScanPoint(x: 1, y: 1),
        topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1, y: 0)
    )

    func testVisionCoordinatesMapExactlyToNotesCoordinates() throws {
        let crop = ScanCorrection.scanCrop(
            visionTopLeft: CGPoint(x: 0.1, y: 0.8), visionTopRight: CGPoint(x: 0.9, y: 0.7),
            visionBottomRight: CGPoint(x: 0.8, y: 0.2), visionBottomLeft: CGPoint(x: 0.2, y: 0.1)
        )
        XCTAssertEqual(crop.topLeft.x, 0.1, accuracy: 0.000_000_000_001)
        XCTAssertEqual(crop.topLeft.y, 0.2, accuracy: 0.000_000_000_001)
        XCTAssertEqual(crop.topRight.x, 0.9, accuracy: 0.000_000_000_001)
        XCTAssertEqual(crop.topRight.y, 0.3, accuracy: 0.000_000_000_001)
        XCTAssertEqual(crop.bottomRight.x, 0.8, accuracy: 0.000_000_000_001)
        XCTAssertEqual(crop.bottomRight.y, 0.8, accuracy: 0.000_000_000_001)
        XCTAssertEqual(crop.bottomLeft.x, 0.2, accuracy: 0.000_000_000_001)
        XCTAssertEqual(crop.bottomLeft.y, 0.9, accuracy: 0.000_000_000_001)
        XCTAssertNoThrow(try ScanCorrection.validate(crop))
    }

    func testGeometryRejectsSelfIntersectionAndTinyQuadrilaterals() throws {
        let crossed = ScanCrop(
            bottomLeft: ScanPoint(x: 0, y: 1), bottomRight: ScanPoint(x: 1, y: 0),
            topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1, y: 1)
        )
        XCTAssertThrowsError(try ScanCorrection.validate(crossed)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "unsafe_scan_geometry")
        }
        let tiny = ScanCrop(
            bottomLeft: ScanPoint(x: 0.49, y: 0.51), bottomRight: ScanPoint(x: 0.51, y: 0.51),
            topLeft: ScanPoint(x: 0.49, y: 0.49), topRight: ScanPoint(x: 0.51, y: 0.49)
        )
        XCTAssertThrowsError(try ScanCorrection.validate(tiny)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "unsafe_scan_geometry")
        }
    }

    func testCandidateSelectionRejectsComparableRectangles() throws {
        let inset = ScanCrop(
            bottomLeft: ScanPoint(x: 0.05, y: 0.95), bottomRight: ScanPoint(x: 0.95, y: 0.95),
            topLeft: ScanPoint(x: 0.05, y: 0.05), topRight: ScanPoint(x: 0.95, y: 0.05)
        )
        XCTAssertThrowsError(try ScanCorrection.selectCandidate([
            ScanEdgeCandidate(crop: identity, confidence: 0.95),
            ScanEdgeCandidate(crop: inset, confidence: 0.94),
        ])) {
            XCTAssertEqual(($0 as? NotesError)?.code, "ambiguous_scan_edges")
        }
        XCTAssertEqual(try ScanCorrection.selectCandidate([
            ScanEdgeCandidate(crop: identity, confidence: 0.95),
            ScanEdgeCandidate(crop: ScanCrop(
                bottomLeft: ScanPoint(x: 0.25, y: 0.75), bottomRight: ScanPoint(x: 0.75, y: 0.75),
                topLeft: ScanPoint(x: 0.25, y: 0.25), topRight: ScanPoint(x: 0.75, y: 0.25)
            ), confidence: 0.9),
        ]), identity)
    }

    func testIdentityPerspectiveCorrectionPreservesExactPixelsAndDimensions() throws {
        let bytes: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255,
        ]
        var sourceBytes = bytes
        let source = try XCTUnwrap(sourceBytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: 2, height: 2,
                      bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let png = try ScanCorrection.correctedPNG(image: source, crop: identity)
        let decodedSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decodedSource, 0, nil))
        XCTAssertEqual(output.width, 2)
        XCTAssertEqual(output.height, 2)
        XCTAssertEqual(try rgbaBytes(output), bytes)
    }

    func testPerspectiveCorrectionRendersExactCropDimensionsAndSolidPixels() throws {
        var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            bytes[offset...] = [12, 34, 56, 255][...]
        }
        let source = try XCTUnwrap(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: 4, height: 4,
                      bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let crop = ScanCrop(
            bottomLeft: ScanPoint(x: 0.25, y: 0.75), bottomRight: ScanPoint(x: 0.75, y: 0.75),
            topLeft: ScanPoint(x: 0.25, y: 0.25), topRight: ScanPoint(x: 0.75, y: 0.25))
        let png = try ScanCorrection.correctedPNG(image: source, crop: crop)
        let decodedSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decodedSource, 0, nil))
        XCTAssertEqual(output.width, 2)
        XCTAssertEqual(output.height, 2)
        XCTAssertEqual(try rgbaBytes(output), [12, 34, 56, 255, 12, 34, 56, 255,
                                               12, 34, 56, 255, 12, 34, 56, 255])
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(rendered)
        return bytes
    }
}
