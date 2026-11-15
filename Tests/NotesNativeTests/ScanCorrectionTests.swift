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
        let mirrored = ScanCrop(
            bottomLeft: identity.bottomRight, bottomRight: identity.bottomLeft,
            topLeft: identity.topRight, topRight: identity.topLeft
        )
        XCTAssertThrowsError(try ScanCorrection.validate(mirrored)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "unsafe_scan_geometry")
        }
    }

    func testCandidateSelectionIgnoresInvalidCandidatesAndRejectsDistinctRectangles() throws {
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
        let invalid = ScanCrop(
            bottomLeft: ScanPoint(x: 0, y: 0), bottomRight: ScanPoint(x: 1, y: 1),
            topLeft: ScanPoint(x: 0, y: 1), topRight: ScanPoint(x: 1, y: 0)
        )
        XCTAssertEqual(try ScanCorrection.selectCandidate([
            ScanEdgeCandidate(crop: invalid, confidence: 1),
            ScanEdgeCandidate(crop: inset, confidence: 0.91),
        ]), inset)

        let inner = ScanCrop(
            bottomLeft: ScanPoint(x: 0.25, y: 0.75), bottomRight: ScanPoint(x: 0.75, y: 0.75),
            topLeft: ScanPoint(x: 0.25, y: 0.25), topRight: ScanPoint(x: 0.75, y: 0.25)
        )
        XCTAssertThrowsError(try ScanCorrection.selectCandidate([
            ScanEdgeCandidate(crop: identity, confidence: 0.71),
            ScanEdgeCandidate(crop: inner, confidence: 0.99),
        ])) {
            XCTAssertEqual(($0 as? NotesError)?.code, "ambiguous_scan_edges")
        }
        XCTAssertEqual(try ScanCorrection.selectCandidate([
            ScanEdgeCandidate(crop: identity, confidence: 0.69),
            ScanEdgeCandidate(crop: inset, confidence: 0.91),
        ]), inset)
    }

    func testImageMetadataAcceptsUpAndRefusesRotatedEXIFBeforeCorrection() throws {
        let up = try temporaryImage(width: 24, height: 16, orientation: 1)
        let rotated = try temporaryImage(width: 24, height: 16, orientation: 6)
        defer { try? FileManager.default.removeItem(at: up.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: rotated.deletingLastPathComponent()) }

        XCTAssertNoThrow(try ScanCorrection.validateImages(at: [up], requireUpOrientation: true))
        XCTAssertThrowsError(try ScanCorrection.validateImages(at: [rotated], requireUpOrientation: true)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "scan_exif_orientation_unsupported")
        }
        XCTAssertNoThrow(try ScanCorrection.validateImages(at: [rotated], requireUpOrientation: false))
    }

    func testImagePixelLimitsAreConservativePerImageAndInAggregate() throws {
        XCTAssertNoThrow(try ScanCorrection.validateMetadata(width: 6_000, height: 6_000, orientation: 1,
                                                             requireUpOrientation: false))
        XCTAssertThrowsError(try ScanCorrection.validateMetadata(width: 8_000, height: 6_000, orientation: 1,
                                                                 requireUpOrientation: false)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "scan_image_too_large")
        }
        XCTAssertThrowsError(try ScanCorrection.validatePixelTotal([36_000_000, 36_000_000, 36_000_000])) {
            XCTAssertEqual(($0 as? NotesError)?.code, "scan_total_pixels_too_large")
        }
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

    func testPerspectiveCorrectionPreservesAsymmetricCornerColorsWithoutMirroring() throws {
        let width = 80, height = 60
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colors: [[UInt8]] = [[240, 20, 30, 255], [20, 220, 40, 255],
                                  [30, 60, 235, 255], [235, 210, 20, 255]]
        for y in 0..<height {
            for x in 0..<width {
                let quadrant = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                bytes.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 4,
                                      with: colors[quadrant])
            }
        }
        let source = try XCTUnwrap(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let crop = ScanCrop(
            bottomLeft: ScanPoint(x: 0.08, y: 0.9), bottomRight: ScanPoint(x: 0.88, y: 0.84),
            topLeft: ScanPoint(x: 0.15, y: 0.1), topRight: ScanPoint(x: 0.94, y: 0.18)
        )
        let png = try ScanCorrection.correctedPNG(image: source, crop: crop)
        let decodedSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decodedSource, 0, nil))
        let outputBytes = try rgbaBytes(output)
        func pixel(_ x: Int, _ y: Int) -> ArraySlice<UInt8> {
            let offset = (y * output.width + x) * 4
            return outputBytes[offset..<offset + 4]
        }
        XCTAssertEqual(Array(pixel(2, 2)), colors[0])
        XCTAssertEqual(Array(pixel(output.width - 3, 2)), colors[1])
        XCTAssertEqual(Array(pixel(2, output.height - 3)), colors[2])
        XCTAssertEqual(Array(pixel(output.width - 3, output.height - 3)), colors[3])
    }

    func testVisionDetectCropUsesUpOrientedDocumentImage() throws {
        let url = try temporaryDocumentImage()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let crop = try ScanCorrection.detectCrop(at: url)
        try ScanCorrection.validate(crop)
        XCTAssertGreaterThan(crop.topLeft.x, 0.05)
        XCTAssertLessThan(crop.topLeft.x, 0.3)
        XCTAssertGreaterThan(crop.bottomRight.x, 0.7)
        XCTAssertLessThan(crop.bottomRight.x, 0.95)
    }

    private func temporaryImage(width: Int, height: Int, orientation: UInt32) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-scan-metadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("page.jpg")
        var bytes = [UInt8](repeating: 127, count: width * height * 4)
        let image = try XCTUnwrap(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func temporaryDocumentImage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-scan-vision-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("document.png")
        let width = 800, height = 600
        var bytes = [UInt8](repeating: 20, count: width * height * 4)
        for offset in stride(from: 3, to: bytes.count, by: 4) { bytes[offset] = 255 }
        for y in 90..<510 {
            for x in 100..<700 {
                let offset = (y * width + x) * 4
                bytes.replaceSubrange(offset..<offset + 4, with: [245, 245, 240, 255])
            }
        }
        let image = try XCTUnwrap(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
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
