import AppKit
@testable import NotesNative
import XCTest

final class ScanEvidenceTests: XCTestCase {
    func testExactPNGMatchesItself() throws {
        try withFixtures { fixtures in
            let png = try evidence(fixtures.png)
            XCTAssertTrue(png.visuallyMatches(png))
        }
    }

    func testDeterministicPNGToJPEGConversionMatches() throws {
        try withFixtures { fixtures in
            let png = try evidence(fixtures.png)
            let jpeg = try evidence(fixtures.jpeg)
            XCTAssertNotEqual(png.rasterSHA256, jpeg.rasterSHA256)
            XCTAssertTrue(png.visuallyMatches(jpeg), differenceDescription(png, jpeg))
        }
    }

    func testChangedPNGToJPEGDoesNotMatch() throws {
        try withFixtures { fixtures in
            let png = try evidence(fixtures.png)
            let jpeg = try evidence(fixtures.changedJPEG)
            XCTAssertFalse(png.visuallyMatches(jpeg), differenceDescription(png, jpeg))
        }
    }

    func testReverseJPEGToPNGComparisonIsRefused() throws {
        try withFixtures { fixtures in
            XCTAssertFalse(try evidence(fixtures.jpeg).visuallyMatches(evidence(fixtures.png)))
        }
    }

    func testDifferingJPEGToJPEGComparisonIsRefused() throws {
        try withFixtures { fixtures in
            XCTAssertFalse(try evidence(fixtures.jpeg).visuallyMatches(evidence(fixtures.changedJPEG)))
        }
    }

    func testUnsupportedRasterFormatIsRefusedEvenWhenPixelsMatch() throws {
        try withFixtures { fixtures in
            let tiff = try evidence(fixtures.tiff)
            XCTAssertFalse(tiff.visuallyMatches(tiff))
        }
    }

    private struct Fixtures {
        var png: URL
        var jpeg: URL
        var changedJPEG: URL
        var tiff: URL
    }

    private func withFixtures(_ body: (Fixtures) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-scan-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = Fixtures(
            png: try imageURL(in: directory, name: "source.png", type: .png, changed: false),
            jpeg: try imageURL(in: directory, name: "stored.jpg", type: .jpeg, changed: false),
            changedJPEG: try imageURL(in: directory, name: "changed.jpg", type: .jpeg, changed: true),
            tiff: try imageURL(in: directory, name: "source.tiff", type: .tiff, changed: false)
        )
        try body(fixtures)
    }

    private func evidence(_ url: URL) throws -> NativeNotesWriter.ScanPageEvidence {
        try NativeNotesWriter.scanPageEvidence(url: url, name: url.lastPathComponent)
    }

    private func differenceDescription(_ first: NativeNotesWriter.ScanPageEvidence,
                                       _ second: NativeNotesWriter.ScanPageEvidence) -> String {
        var total = 0
        var changed = 0
        var blocks = [Int](repeating: 0, count: 64 * 64)
        for pixel in 0..<(256 * 256) {
            let offset = pixel * 4
            let differences = (0..<3).map { abs(Int(first.samples[offset + $0]) - Int(second.samples[offset + $0])) }
            let sum = differences.reduce(0, +)
            total += sum
            if differences.max() ?? 0 > 24 { changed += 1 }
            blocks[((pixel / 256) / 4) * 64 + ((pixel % 256) / 4)] += sum
        }
        return "average=\(Double(total) / Double(256 * 256 * 3)) changed=\(changed) block=\(Double(blocks.max() ?? 0) / 48)"
    }

    private func imageURL(in directory: URL, name: String, type: NSBitmapImageRep.FileType,
                          changed: Bool) throws -> URL {
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        NSColor.black.setFill()
        NSRect(x: 96, y: 96, width: 832, height: 8).fill()
        if changed {
            NSColor.systemRed.setFill()
            NSRect(x: 480, y: 480, width: 64, height: 64).fill()
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(
                using: type,
                properties: type == .jpeg ? [.compressionFactor: 1.0] : [:]
              ) else {
            throw XCTSkip("AppKit could not render the deterministic scan fixture.")
        }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
