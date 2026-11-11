import Foundation
import XCTest
@testable import NotesSync

final class LiveTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    private func run(_ arguments: [String]) throws -> String {
        let candidates = [".build/debug/notescli", ".build/arm64-apple-macosx/debug/notescli", ".build/out/Products/Debug/notescli"]
        let binary = try XCTUnwrap(candidates.map { root.appendingPathComponent($0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(); process.executableURL = binary; process.arguments = arguments; process.currentDirectoryURL = root
        let output = Pipe(), error = Pipe(); process.standardOutput = output; process.standardError = error
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile(), stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr, as: UTF8.self)
            if process.terminationStatus == 5 || message.contains("outcome_unknown") {
                throw NotesSyncError.writeUnknown("A live write outcome is unknown; cleanup stopped.")
            }
            throw NotesSyncError.externalTool("notescli exited \(process.terminationStatus): \(message)")
        }
        return String(decoding: stdout, as: UTF8.self)
    }

    private func liveOnly() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_TESTS=1 for real-library export and isolated notescli-test/sync verification.")
        }
    }

    func testLiveExportReportsOnlyCountsAndSizes() throws {
        try liveOnly()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-live-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = try run(["--json", "export", "--out", directory.path, "--format", "ndjson"])
        let paths = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String])
        let bytes = try paths.reduce(Int64(0)) { total, path in
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
        XCTAssertFalse(paths.isEmpty)
        print("LIVE export: files=\(paths.count) bytes=\(bytes)")
    }

    func testLiveSyncOnlyUsesIsolatedFolderAndCleansUp() throws {
        try liveOnly()
        let fm = FileManager.default, directory = fm.temporaryDirectory.appendingPathComponent("notescli-live-sync-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let rootName = "notescli-test", syncPath = "notescli-test > sync", title = "notescli-test-" + UUID().uuidString
        var createdRoot = false, createdSync = false, createdNote = false
        var safeToClean = true
        defer {
            if safeToClean {
                if createdNote { _ = try? run(["delete", title, "--yes"]) }
                if createdSync { _ = try? run(["folder", "delete", syncPath, "--yes"]) }
                if createdRoot { _ = try? run(["folder", "delete", rootName, "--yes"]) }
            }
        }
        let folders = try JSONSerialization.jsonObject(with: Data(try run(["--json", "folders"]).utf8)) as! [[String: Any]]
        if !folders.contains(where: { ($0["path"] as? [String]) == [rootName] }) {
            _ = try run(["folder", "create", rootName]); createdRoot = true
        }
        let refreshed = try JSONSerialization.jsonObject(with: Data(try run(["--json", "folders"]).utf8)) as! [[String: Any]]
        if !refreshed.contains(where: { ($0["path"] as? [String]) == [rootName, "sync"] }) {
            _ = try run(["folder", "create", "sync", "--parent", rootName]); createdSync = true
        }
        let existing = try JSONSerialization.jsonObject(with: Data(try run(["--json", "list", "--folder", syncPath]).utf8)) as! [[String: Any]]
        guard existing.allSatisfy({ ($0["title"] as? String)?.hasPrefix("notescli-test-") == true }) else {
            throw NotesSyncError.invalidState("notescli-test/sync contains a title not owned by live tests.")
        }
        do {
            _ = try run(["add", title, "--folder", syncPath, "--body", "initial"]); createdNote = true
            _ = try run(["--json", "sync", directory.path, "--folder", syncPath])
            let files = try XCTUnwrap(fm.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL])
            let file = try XCTUnwrap(files.first { $0.pathExtension == "md" && (try? String(contentsOf: $0).contains("title: \"\(title)\"")) == true })
            var markdown = MarkdownFile.parse(try String(contentsOf: file), fallbackTitle: title)
            markdown.body = "live-sync-updated"; try markdown.rendered().write(to: file, atomically: true, encoding: .utf8)
            _ = try run(["--json", "sync", directory.path, "--folder", syncPath])
            let shown = try run(["show", title, "--format", "text"])
            XCTAssertTrue(shown.contains("live-sync-updated"))
            _ = try run(["delete", title, "--yes"]); createdNote = false
            if createdSync { _ = try run(["folder", "delete", syncPath, "--yes"]); createdSync = false }
            if createdRoot { _ = try run(["folder", "delete", rootName, "--yes"]); createdRoot = false }
            print("LIVE sync: created=1 updated=1 cleaned=1")
        } catch let error as NotesSyncError {
            if case .writeUnknown = error { safeToClean = false }
            throw error
        }
    }
}
