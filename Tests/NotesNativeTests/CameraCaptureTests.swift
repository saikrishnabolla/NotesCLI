import CoreGraphics
import Foundation
import ImageIO
import NotesCore
import UniformTypeIdentifiers
import XCTest
@testable import NotesNative

final class CameraCaptureTests: XCTestCase {
    func testCaptureRequestRejectsUnsafeDelayAndCount() throws {
        XCTAssertThrowsError(try CameraCaptureRequest(delay: -1)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "invalid_camera_delay")
        }
        XCTAssertThrowsError(try CameraCaptureRequest(count: 0)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "invalid_camera_count")
        }
        XCTAssertThrowsError(try CameraCaptureRequest(count: CameraCaptureRequest.maximumCount + 1)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "invalid_camera_count")
        }
    }

    func testInjectedSourceRepeatsReadableImageWithoutCameraAccess() throws {
        let data = try png(width: 12, height: 8)
        let source = try InjectedCameraImageSource(data: data, name: "fixture.png")
        let images = try source.capture(CameraCaptureRequest(device: "ignored", delay: 0, count: 3))

        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(images.map(\.sourceName), ["fixture-1.png", "fixture-2.png", "fixture-3.png"])
        XCTAssertEqual(Set(images.map(\.sha256)).count, 1)
        for image in images {
            XCTAssertNoThrow(try ScanCorrection.validateImages(at: [image.url], requireUpOrientation: false))
        }
    }

    func testInjectedSourceRejectsNonImageBytes() throws {
        XCTAssertThrowsError(try InjectedCameraImageSource(data: Data("not an image".utf8))) {
            XCTAssertEqual(($0 as? NotesError)?.code, "invalid_scan_image_metadata")
        }
    }

    private func png(width: Int, height: Int) throws -> Data {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let image = try XCTUnwrap(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
