import Foundation
import XCTest
import NotesCore
@testable import NotesAutomation

final class LiveWriterTests: XCTestCase {
    func testLiveLifecycle() throws {
        guard ProcessInfo.processInfo.environment["NOTECTL_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set NOTECTL_LIVE_TESTS=1; writes use only notectl-test in the default account.")
        }
        // Stop before any script if consent is denied or would require a prompt.
        try NotesAutomationPermission.check()
        print("LIVE permission: PASS (already authorized)")
        let writer = ScriptingNotesWriter(timeout: 15)
        let token = UUID().uuidString
        let title = "notectl-test-" + token
        var ownedFolders: [String] = []
        var activeNotes: Set<String> = []
        var stop = false
        func completed(_ value: WriteResult) throws -> WriteResult {
            if value.message?.contains("automation_denied") == true {
                stop = true
                throw NotesError("automation_denied", value.message!)
            }
            if value.outcome == .unknown {
                stop = true
                throw NotesError("unknown_write", "Live write outcome unknown; stopped without retry or cleanup.")
            }
            return value
        }
        func guardedRead(_ ref: String) throws -> ScriptingNotesWriter.Reply {
            guard activeNotes.contains(ref) else { throw NotesError("unsafe_test_target", "Not created by this test.") }
            let result = try writer.execute("read", fields: ["ref": ref], isWrite: false)
            guard result.title?.hasPrefix("notectl-test-") == true else { throw NotesError("unsafe_test_target", "Unexpected test title.") }
            return result
        }
        defer {
            if stop { print("LIVE cleanup: STOPPED after unknown outcome or denied permission; no further Apple Events") }
            else {
                do {
                    for ref in activeNotes {
                        _ = try guardedRead(ref)
                        _ = try completed(writer.deleteNote(ref))
                    }
                    for ref in ownedFolders.reversed() { _ = try completed(writer.deleteFolder(ref)) }
                    print("LIVE cleanup: PASS (created notes soft-deleted; owned empty folders removed)")
                } catch {
                    XCTFail("LIVE cleanup: FAIL \(error)")
                }
            }
        }
        do {
            let rootID: String
            do {
                let existing = try writer.execute("folderInfo", fields: ["ref": "notectl-test"], isWrite: false)
                rootID = try XCTUnwrap(existing.folderID)
            } catch let error as NotesError where error.code == "folder_not_found" {
                rootID = try XCTUnwrap(completed(writer.createFolder(name: "notectl-test")).folderID)
                ownedFolders.append(rootID)
            }
            let subID: String
            do {
                let existing = try writer.execute("folderInfo", fields: ["ref": "notectl-test > sub"], isWrite: false)
                subID = try XCTUnwrap(existing.folderID)
            } catch let error as NotesError where error.code == "folder_not_found" {
                subID = try XCTUnwrap(completed(writer.createFolder(name: "sub", parent: rootID)).folderID)
                ownedFolders.append(subID)
            }
            print("LIVE folders: PASS (notectl-test > sub)")
            let created = try completed(writer.createNote(title: title, markdown: "## Heading\n\n**bold** and `code`\n\n- [ ] task", folder: rootID))
            var ref = try XCTUnwrap(created.noteID?.coreDataID)
            activeNotes.insert(ref)
            var read = try guardedRead(ref)
            XCTAssertEqual(read.title, title)
            XCTAssertEqual(read.folderID, rootID)
            XCTAssertTrue(read.body?.contains("Heading") == true)
            XCTAssertEqual(created.message, #"downgraded: ["checklist"]"#)
            print("LIVE create/read: PASS body=\(read.body ?? "nil")")
            try writer.showInNotes(ref)
            print("LIVE show: PASS (Notes accepted show)")
            _ = try completed(writer.appendToNote(ref, markdown: "append-\(token)"))
            read = try guardedRead(ref)
            XCTAssertTrue(read.body?.contains("append-\(token)") == true)
            XCTAssertTrue(read.body?.contains("Heading") == true)
            print("LIVE append: PASS body=\(read.body ?? "nil")")
            _ = try completed(writer.renameNote(ref, title: title + "-renamed"))
            read = try guardedRead(ref)
            XCTAssertEqual(read.title, title + "-renamed")
            print("LIVE rename: PASS")
            for destination in [subID, rootID] {
                let moved = try completed(writer.moveNote(ref, toFolder: destination))
                let previous = ref
                ref = moved.noteID?.coreDataID ?? ref
                activeNotes.remove(previous); activeNotes.insert(ref)
                read = try guardedRead(ref)
                XCTAssertEqual(read.folderID, destination)
            }
            print("LIVE move: PASS (root → sub → root)")
            _ = try completed(writer.replaceBody(ref, markdown: "replacement-\(token)"))
            read = try guardedRead(ref)
            XCTAssertTrue(read.body?.contains("replacement-\(token)") == true)
            XCTAssertFalse(read.body?.contains("append-\(token)") == true)
            XCTAssertEqual(read.title, title + "-renamed")
            print("LIVE replace: PASS body=\(read.body ?? "nil")")

            let folderName = "notectl-test-folder-" + token
            let extraFolder = try XCTUnwrap(completed(writer.createFolder(name: folderName, parent: rootID)).folderID)
            ownedFolders.append(extraFolder)
            _ = try completed(writer.renameFolder(extraFolder, name: folderName + "-renamed"))
            XCTAssertEqual(try writer.execute("folderInfo", fields: ["ref": extraFolder], isWrite: false).name, folderName + "-renamed")
            _ = try completed(writer.deleteFolder(extraFolder))
            ownedFolders.removeAll { $0 == extraFolder }
            XCTAssertThrowsError(try writer.execute("folderInfo", fields: ["ref": extraFolder], isWrite: false)) { error in
                XCTAssertEqual((error as? NotesError)?.code, "folder_not_found")
            }
            print("LIVE folder create/rename/delete: PASS (deleted folder no longer resolves)")

            let image = FileManager.default.temporaryDirectory.appendingPathComponent("notectl-test-\(token).png")
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
            try png.write(to: image)
            defer { try? FileManager.default.removeItem(at: image) }
            let attached = try completed(writer.createNote(title: title + "-image", markdown: "![pixel](\(image.path))", folder: rootID))
            let imageID = try XCTUnwrap(attached.noteID?.coreDataID)
            activeNotes.insert(imageID)
            let imageRead = try guardedRead(imageID)
            if attached.message?.contains("image") == true {
                XCTAssertEqual(imageRead.attachmentCount, 0)
                XCTAssertFalse(imageRead.body?.contains("<img") == true)
                print("LIVE attachment: DOWNGRADED \(attached.message!)")
            } else {
                XCTAssertEqual(imageRead.attachmentCount, 1)
                print("LIVE attachment: PASS (one PNG attachment)")
            }
            _ = try completed(writer.deleteNote(imageID)); activeNotes.remove(imageID)
            _ = try guardedRead(ref)
            _ = try completed(writer.deleteNote(ref)); activeNotes.remove(ref)
            print("LIVE delete: dispatched once")

            // Only query the synthetic note. Never print library titles or bodies.
            let source = #"""
            function run(argv) {
                const app = Application('com.apple.Notes');
                const trash = app.defaultAccount().folders.whose({name: 'Recently Deleted'})();
                if (trash.length !== 1) return JSON.stringify({visible: false, found: false});
                return JSON.stringify({visible: true, found: trash[0].notes.whose({name: argv[0]})().length === 1});
            }
            """#
            let trash = try OSAScriptRunner().run(source: source, language: .javaScript, arguments: [title + "-renamed"], timeout: 15)
            guard !trash.timedOut, trash.status == 0 else {
                stop = trash.timedOut || [-1743, -1744].contains(ScriptingNotesWriter.eventNumber(trash.stderr) ?? 0)
                throw NotesError("trash_verification_failed", "Recently Deleted scripting check failed (status \(trash.status)).")
            }
            let verification = try JSONDecoder().decode([String: Bool].self, from: Data(trash.stdout.utf8))
            XCTAssertEqual(verification["found"], true, "Recently Deleted visible=\(verification["visible"] ?? false); deletion needs independent verification.")
            print("LIVE Recently Deleted: \(verification["found"] == true ? "PASS" : "UNVERIFIED")")
            XCTAssertThrowsError(try writer.deleteNote(ref)) { error in
                XCTAssertEqual((error as? NotesError)?.code, "protected_folder")
            }
            print("LIVE second-delete guard: PASS (protected_folder)")
        } catch {
            if let notesError = error as? NotesError, notesError.code == "automation_denied" || notesError.code == "automation_timeout" { stop = true }
            print("LIVE stopped: \(error)")
            throw error
        }
    }
}
