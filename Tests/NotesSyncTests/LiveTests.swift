import Foundation
import PDFKit
import XCTest
@testable import NotesSync

private enum LiveCLIJSON {
    static func notes(from json: String) throws -> [[String: Any]] {
        guard let response = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let notes = response["notes"] as? [[String: Any]] else {
            throw NotesSyncError.invalidState("notescli list returned an invalid response.")
        }
        return notes
    }
}

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

    func testListResponseReadsPaginatedNotes() throws {
        let notes = try LiveCLIJSON.notes(from: #"{"notes":[{"title":"Owned"}]}"#)
        XCTAssertEqual(notes.first?["title"] as? String, "Owned")
    }

    func testLiveExportReportsOnlyCountsAndSizes() throws {
        try liveOnly()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-live-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let formats = ["markdown", "html", "json", "ndjson", "sqlite", "zip", "pdf", "docx", "rtf", "epub", "bear", "joplin", "quiver"]
        for format in formats {
            let output = directory.appendingPathComponent(format)
            let json = try run(["--json", "export", "--out", output.path, "--format", format])
            let paths = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String])
            let bytes = try paths.reduce(Int64(0)) { total, path in
                total + ((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
            }
            XCTAssertFalse(paths.isEmpty, format)
            let valid = try validateExport(format: format, paths: paths)
            XCTAssertTrue(valid, format)
            print("LIVE export \(format): files=\(paths.count) bytes=\(bytes) valid=\(valid)")
        }
    }

    func testLiveFileSyncOnlyUsesIsolatedFolderAndCleansUp() throws {
        try liveOnly()
        let fm = FileManager.default, directory = fm.temporaryDirectory.appendingPathComponent("notescli-live-sync-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let syncPath = "notescli-test > w3-export", title = "notescli-test-" + UUID().uuidString
        var createdNoteID: String?
        var safeToClean = true
        defer {
            if safeToClean {
                if let createdNoteID { _ = try? run(["delete", createdNoteID, "--yes"]) }
                try? cleanupLiveFolders()
            }
        }
        try ensureLiveFolders()
        let existing = try LiveCLIJSON.notes(from: run(["--json", "list", "--folder", syncPath]))
        guard existing.allSatisfy({ ($0["title"] as? String)?.hasPrefix("notescli-test-") == true }) else {
            throw NotesSyncError.invalidState("notescli-test/sync contains a title not owned by live tests.")
        }
        do {
            let created = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(run(["--json", "add", title, "--folder", syncPath, "--body", "initial"]).utf8)) as? [String: Any])
            let result = try XCTUnwrap(created["result"] as? [String: Any])
            let identity = try XCTUnwrap(result["noteID"] as? [String: Any])
            let noteID = try XCTUnwrap(identity["uuid"] as? String)
            createdNoteID = noteID
            try waitForNote(noteID)
            let file = directory.appendingPathComponent("note.md")
            _ = try run(["--json", "file", "pull", noteID, file.path])
            var markdown = MarkdownFile.parse(try String(contentsOf: file), fallbackTitle: title)
            markdown.body = "live-file-updated"; try markdown.rendered().write(to: file, atomically: true, encoding: .utf8)
            _ = try run(["--json", "file", "diff", file.path])
            _ = try run(["--json", "file", "push", file.path])
            let shown = try run(["show", noteID, "--format", "text"])
            XCTAssertTrue(shown.contains("live-file-updated"))
            _ = try run(["delete", noteID, "--yes"]); createdNoteID = nil
            try cleanupLiveFolders()
            let script = try process("/usr/bin/osascript", ["-l", "JavaScript", "-e", "Application(\"Notes\").folders.name()"])
            XCTAssertFalse(script.localizedCaseInsensitiveContains("notescli-test"))
            print("LIVE file sync: pulled=1 pushed=1 cleaned=1")
        } catch let error as NotesSyncError {
            if case .writeUnknown = error { safeToClean = false }
            throw error
        }
    }

    private func ensureLiveFolders() throws {
        let script = """
        const app = Application("Notes");
        function children(parent) {
          const parentID = parent.id();
          return parent.folders().filter(folder => { try { return folder.container().id() === parentID; } catch (_) { return false; } });
        }
        const account = app.defaultAccount();
        let root = children(account).find(f => f.name() === "notescli-test");
        if (!root) root = app.make({new: "folder", at: account, withProperties: {name: "notescli-test"}});
        let child = children(root).find(f => f.name() === "w3-export");
        if (!child) child = app.make({new: "folder", at: root, withProperties: {name: "w3-export"}});
        child.id();
        """
        let childID = try process("/usr/bin/osascript", ["-l", "JavaScript", "-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let folders = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(run(["--json", "folders"]).utf8)) as? [[String: Any]])
            if folders.contains(where: { ($0["coreDataID"] as? String) == childID }) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw NotesSyncError.invalidState("The isolated live-test folder did not appear in the Notes store.")
    }

    private func waitForNote(_ noteID: String) throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if (try? run(["--json", "show", noteID])) != nil { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw NotesSyncError.invalidState("The isolated live-test note did not appear in the Notes store.")
    }

    private func validateExport(format: String, paths: [String]) throws -> Bool {
        switch format {
        case "pdf": return paths.allSatisfy { (PDFDocument(url: URL(fileURLWithPath: $0))?.pageCount ?? 0) > 0 }
        case "docx": return try paths.allSatisfy { try process("/usr/bin/unzip", ["-Z1", $0]).contains("word/document.xml") }
        case "rtf": return try paths.allSatisfy { try String(contentsOfFile: $0).hasPrefix("{\\rtf") }
        case "epub": return try paths.allSatisfy {
            let listing = try process("/usr/bin/unzip", ["-Z1", $0])
            return listing.split(separator: "\n").first == "mimetype" && listing.contains("META-INF/container.xml") && listing.contains("EPUB/package.opf")
        }
        case "bear": return paths.allSatisfy { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("info.json").path) }
        case "joplin": return paths.contains { $0.hasSuffix(".md") }
        case "quiver": return paths.allSatisfy { URL(fileURLWithPath: $0).pathExtension == "qvlibrary" }
        default: return paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
        }
    }

    private func cleanupLiveFolders() throws {
        let folders = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(run(["--json", "folders"]).utf8)) as? [[String: Any]])
        let active = try activeFolderIDs()
        let owned = folders.filter {
            guard let path = $0["path"] as? [String], let coreDataID = $0["coreDataID"] as? String, active.contains(coreDataID) else { return false }
            return path == ["notescli-test"] || Array(path.prefix(2)) == ["notescli-test", "w3-export"]
        }
            .sorted { (($0["path"] as? [String])?.count ?? 0) > (($1["path"] as? [String])?.count ?? 0) }
        for folder in owned {
            guard let id = folder["id"] as? String else { continue }
            let notes = try LiveCLIJSON.notes(from: run(["--json", "list", "--folder", id]))
            guard notes.allSatisfy({ ($0["title"] as? String)?.hasPrefix("notescli-test-") == true }) else {
                throw NotesSyncError.invalidState("Refusing to clean a notescli-test folder containing an unowned title.")
            }
            for note in notes {
                if let noteID = note["id"] as? [String: Any], let uuid = noteID["uuid"] as? String { _ = try run(["delete", uuid, "--yes"]) }
                else if let uuid = note["id"] as? String { _ = try run(["delete", uuid, "--yes"]) }
            }
            try waitForFolderToEmpty(id)
            _ = try run(["folder", "delete", id, "--yes", "--expect-count", "0"])
            try waitForFolderToDisappear(try XCTUnwrap(folder["coreDataID"] as? String))
        }
    }

    private func activeFolderIDs() throws -> Set<String> {
        let script = """
        const app = Application("Notes");
        function children(parent) {
          const parentID = parent.id();
          return parent.folders().filter(folder => { try { return folder.container().id() === parentID; } catch (_) { return false; } });
        }
        function folders(parent) {
          let result = [];
          children(parent).forEach(folder => { result.push(folder.id()); result = result.concat(folders(folder)); });
          return result;
        }
        JSON.stringify(app.accounts().flatMap(folders));
        """
        let output = try process("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
        return Set(try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String]))
    }

    private func waitForFolderToEmpty(_ id: String) throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            guard let json = try? run(["--json", "list", "--folder", id]) else { return }
            if let notes = try? LiveCLIJSON.notes(from: json), notes.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw NotesSyncError.invalidState("The isolated live-test folder did not become empty.")
    }

    private func waitForFolderToDisappear(_ coreDataID: String) throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if try !activeFolderIDs().contains(coreDataID) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw NotesSyncError.invalidState("The isolated live-test folder did not disappear.")
    }

    private func process(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let output = Pipe(), error = Pipe(); process.standardOutput = output; process.standardError = error
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NotesSyncError.externalTool(String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self)
    }
}
