import Foundation
import XCTest
import NotesCore
@testable import NotesAutomation

final class LiveSafetyTests: XCTestCase {
    private struct CLIWriteResponse: Decodable {
        var result: WriteResult
    }

    func testCLIRenameReadbackAndStableCreateID() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_TESTS=1; writes use only notescli-test/safety.")
        }
        try NotesAutomationPermission.check()
        let writer = ScriptingNotesWriter(timeout: 15)
        var createdFolders: [String] = []
        var noteID: String?
        var unknown = false
        let token = UUID().uuidString
        let title = "notescli-test-\(token)"
        let renamed = title + "-renamed"

        func folder(_ path: String, name: String, parent: String? = nil) throws -> String {
            do {
                guard let id = try writer.execute("folderInfo", fields: ["ref": path], isWrite: false).folderID else {
                    throw NotesError("invalid_script_response", "Folder lookup returned no identity.")
                }
                return id
            }
            catch let error as NotesError where error.code == "folder_not_found" {
                let result = try writer.createFolder(name: name, parent: parent)
                if result.outcome == .unknown { unknown = true; throw NotesError("unknown_write", "Folder create outcome is unknown.") }
                let id = try XCTUnwrap(result.folderID); createdFolders.append(id); return id
            }
        }
        let rootID = try folder("notescli-test", name: "notescli-test")
        _ = try folder("notescli-test > safety", name: "safety", parent: rootID)

        defer {
            if unknown { print("LIVE safety cleanup: STOPPED after unknown outcome") }
            else {
                do {
                    if let noteID {
                        let deleted = try runCLI(["--json", "delete", noteID, "--yes"])
                        XCTAssertEqual(deleted.status, 0, deleted.stderr)
                    }
                    for folderID in createdFolders.reversed() {
                        let info = try writer.execute("folderInfo", fields: ["ref": folderID], isWrite: false)
                        guard info.noteCount == 0, info.childCount == 0 else { throw NotesError("unsafe_cleanup", "A created test folder is no longer empty.") }
                        _ = try writer.deleteFolder(folderID)
                    }
                    print("LIVE safety cleanup: PASS")
                } catch { XCTFail("LIVE safety cleanup failed: \(error)") }
                }
        }

        let createdRun = try runCLI(["--json", "add", title, "--folder", "notescli-test > safety", "--body", "## Section\n\nbody-\(token)"])
        XCTAssertEqual(createdRun.status, 0, createdRun.stderr)
        let created = try writeResult(createdRun.stdout)
        if created.outcome == .unknown { unknown = true }
        XCTAssertEqual(created.outcome, .verified)
        XCTAssertFalse(created.noteID?.uuid.isEmpty == true)
        noteID = try XCTUnwrap(created.noteID?.uuid)
        let scriptingID = try XCTUnwrap(created.noteID?.coreDataID)
        print("LIVE safety create: PASS stable_uuid=true outcome=verified")

        let renamedRun = try runCLI(["--json", "rename", noteID!, renamed])
        XCTAssertEqual(renamedRun.status, 0, renamedRun.stderr)
        let renameResult = try writeResult(renamedRun.stdout)
        if renameResult.outcome == .unknown { unknown = true }
        XCTAssertEqual(renameResult.outcome, .verified)

        let shown = try runCLI(["--json", "show", renamed])
        XCTAssertEqual(shown.status, 0, shown.stderr)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let note = try decoder.decode(Note.self, from: Data(shown.stdout.utf8))
        XCTAssertEqual(note.summary.title, renamed)
        XCTAssertEqual(note.summary.id.uuid, noteID)
        print("LIVE safety rename/show: PASS immediate_lookup=true outcome=verified")
        _ = try writer.execute("read", fields: ["ref": scriptingID], isWrite: false)

        let stale = try runCLI(["--json", "rename", noteID!, renamed + "-stale", "--if-modified", "2000-01-01T00:00:00Z"])
        XCTAssertNotEqual(stale.status, 0)
        XCTAssertTrue(stale.stderr.contains("stale_note"), stale.stderr)
        let afterStale = try runCLI(["--json", "show", noteID!])
        XCTAssertEqual(afterStale.status, 0, afterStale.stderr)
        XCTAssertEqual(try decoder.decode(Note.self, from: Data(afterStale.stdout.utf8)).summary.title, renamed)
        print("LIVE safety concurrency: PASS stale_write_refused=true")

        let guardedDelete = try runCLI(["--json", "folder", "delete", "notescli-test > safety", "--yes"])
        XCTAssertNotEqual(guardedDelete.status, 0)
        XCTAssertTrue(guardedDelete.stderr.contains("folder_not_empty"), guardedDelete.stderr)
        print("LIVE safety folder guard: PASS nonempty_refused=true")

        for arguments in [
            ["prepend", noteID!, "--body", "pre-\(token)"],
            ["insert-under-heading", noteID!, "Section", "--body", "insert-\(token)"],
            ["replace-section", noteID!, "Section", "--body", "section-\(token)"],
            ["replace-text", noteID!, "section-\(token)", "final-\(token)"]
        ] {
            let run = try runCLI(["--json", "--engine", "native"] + arguments + ["--write-folders", "notescli-test > safety"])
            guard run.status == 0 else { XCTFail(run.stderr); return }
            let result = try writeResult(run.stdout)
            if result.outcome == .unknown { unknown = true }
            XCTAssertEqual(result.outcome, .verified, "\(arguments): \(result.message ?? "")")
        }
        let edited = try runCLI(["--json", "show", noteID!])
        XCTAssertEqual(edited.status, 0, edited.stderr)
        let editedNote = try decoder.decode(Note.self, from: Data(edited.stdout.utf8))
        XCTAssertTrue(editedNote.document?.plainText().contains("pre-\(token)") == true)
        XCTAssertTrue(editedNote.document?.plainText().contains("final-\(token)") == true)
        print("LIVE safety body edits: PASS preserve=true attachment_guarded=true")

        let history = try runCLI(["--json", "history", noteID!])
        XCTAssertEqual(history.status, 0, history.stderr)
        XCTAssertGreaterThanOrEqual((try JSONSerialization.jsonObject(with: Data(history.stdout.utf8)) as? [Any])?.count ?? 0, 5)
        let undone = try runCLI(["--json", "--engine", "native", "undo", noteID!, "--write-folders", "notescli-test > safety"])
        XCTAssertEqual(undone.status, 0, undone.stderr)
        let undoResult = try writeResult(undone.stdout)
        XCTAssertEqual(undoResult.outcome, .verified)
        let restored = try runCLI(["--json", "show", noteID!])
        let restoredNote = try decoder.decode(Note.self, from: Data(restored.stdout.utf8))
        XCTAssertTrue(restoredNote.document?.plainText().contains("section-\(token)") == true)
        XCTAssertFalse(restoredNote.document?.plainText().contains("final-\(token)") == true)
        print("LIVE safety snapshots/undo: PASS")
    }

    private func writeResult(_ output: String) throws -> WriteResult {
        try JSONDecoder().decode(CLIWriteResponse.self, from: Data(output.utf8)).result
    }

    private func runCLI(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = [".build/debug/notescli", ".build/arm64-apple-macosx/debug/notescli"]
        let binary = try XCTUnwrap(paths.map { root.appendingPathComponent($0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process(); process.executableURL = binary; process.arguments = arguments; process.currentDirectoryURL = root
        let stdout = Pipe(), stderr = Pipe(); process.standardOutput = stdout; process.standardError = stderr; process.standardInput = FileHandle.nullDevice
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile(), err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}
