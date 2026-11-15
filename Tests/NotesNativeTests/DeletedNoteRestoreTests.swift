import Foundation
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesSafety
import NotesStore
import XCTest

final class DeletedNoteRestoreTests: XCTestCase {
    func testLiveSnapshotRestoresBodyWhileNoteIsInRecentlyDeleted() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-deleted-restore-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>saved body</p>'}}); return note.id(); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable deleted-restore fixture creation failed: \(reply.stderr)")
        }
        let scriptingID = reply.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var noteID: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            noteID = try? SQLiteNotesStore(refresh: true).note(scriptingID).summary.id.uuid
            if noteID != nil { break }
        }
        let ref = try XCTUnwrap(noteID)
        defer {
            if let note = try? SQLiteNotesStore(refresh: true).note(ref), !note.summary.isDeleted {
                _ = try? scripting.deleteNote(ref)
            }
        }

        let captured = try SQLiteNotesStore(refresh: true).note(ref)
        let originalFolderID = try XCTUnwrap(captured.summary.folderID)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-deleted-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let saved = try store.save(captured)
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)

        XCTAssertEqual(try native.deleteNote(ref, allowShared: false).writeResult.outcome, .verified)
        XCTAssertTrue(try SQLiteNotesStore(refresh: true).note(ref).summary.isDeleted)

        let bodyRestore = try native.restoreSnapshot(
            ref,
            snapshot: loaded.note,
            material: try store.restoreMaterial(for: loaded),
            expectedRevision: nil,
            expectedModified: nil,
            allowShared: false
        )
        XCTAssertEqual(bodyRestore.writeResult.outcome, .verified, bodyRestore.writeResult.message ?? "no detail")

        let locationRestore = try native.restore(ref, folder: originalFolderID, allowShared: false)
        XCTAssertEqual(locationRestore.writeResult.outcome, .verified, locationRestore.writeResult.message ?? "no detail")
        let restored = try SQLiteNotesStore(refresh: true).note(ref)
        XCTAssertFalse(restored.summary.isDeleted)
        XCTAssertEqual(restored.summary.title, captured.summary.title)
        XCTAssertEqual(restored.document?.text, captured.document?.text)
    }
}
