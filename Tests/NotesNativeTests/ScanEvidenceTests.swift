import AppKit
@testable import NotesNative
import XCTest

final class ScanEvidenceTests: XCTestCase {
    func testLocalizedScanPageChangeDoesNotPassVisualVerification() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-scan-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try imageURL(in: directory, name: "first.png", changed: false)
        let second = try imageURL(in: directory, name: "second.png", changed: true)

        let expected = try NativeNotesWriter.scanPageEvidence(url: first, name: first.lastPathComponent)
        let changed = try NativeNotesWriter.scanPageEvidence(url: second, name: second.lastPathComponent)

        XCTAssertFalse(expected.visuallyMatches(changed))
    }

    private func imageURL(in directory: URL, name: String, changed: Bool) throws -> URL {
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        NSColor.black.setFill()
        NSRect(x: 96, y: 96, width: 832, height: 8).fill()
        if changed {
            NSColor.systemRed.setFill()
            NSRect(x: 500, y: 500, width: 24, height: 24).fill()
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw XCTSkip("AppKit could not render the deterministic scan fixture.")
        }
        let url = directory.appendingPathComponent(name)
        try png.write(to: url, options: .atomic)
        return url
    }
}
