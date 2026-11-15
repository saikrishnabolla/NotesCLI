import Foundation
import XCTest

final class RecordingSummaryDeleteCLITests: XCTestCase {
    func testRecordingCommandExposesClearSummary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            ".build/debug/notescli",
            ".build/out/Products/Debug/notescli",
            ".build/arm64-apple-macosx/debug/notescli",
        ]
        let binary = try XCTUnwrap(candidates.map(root.appendingPathComponent)
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process()
        process.executableURL = binary
        process.arguments = ["recording", "--help"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("  clear-summary"), text)
    }
}
