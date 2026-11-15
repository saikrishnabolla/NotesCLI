import Foundation
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesStore
import XCTest

final class TableRTLRestoreTests: XCTestCase {
    func testLiveSnapshotRecreatesRightToLeftTableWithoutMirroringCells() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-table-rtl-\(UUID().uuidString.lowercased())"
        let source = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return String(note.id()); }"
        let reply = try runner.run(source: source, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable RTL-table fixture creation failed: \(reply.stderr)")
        }
        let scriptingID = reply.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var noteID: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            noteID = try? SQLiteNotesStore(refresh: true).note(scriptingID).summary.id.uuid
            if noteID != nil { break }
        }
        let ref = try XCTUnwrap(noteID)
        defer { _ = try? scripting.deleteNote(ref) }

        let expected = [["A", "B", "C"], ["D", "E", "F"]]
        let created = try native.createTable(ref, rows: expected, position: nil, allowShared: false)
        XCTAssertEqual(created.writeResult.outcome, .verified)
        let oldID = try XCTUnwrap(created.verification.nativeReadback["tableID"])
        var snapshot = try SQLiteNotesStore(refresh: true).note(ref)
        let index = try XCTUnwrap(snapshot.attachments.firstIndex(where: { $0.id == oldID }))
        XCTAssertEqual(snapshot.attachments[index].tableRightToLeft, false)
        snapshot.attachments[index].tableRightToLeft = true

        setenv("NOTESCLI_TEST_TREAT_ABSENT", oldID, 1)
        defer { unsetenv("NOTESCLI_TEST_TREAT_ABSENT") }
        let restored = try native.restoreSnapshot(ref, snapshot: snapshot, allowShared: false)
        XCTAssertEqual(restored.writeResult.outcome, .verified, restored.writeResult.message ?? "no detail")
        let mapData = try XCTUnwrap(restored.verification.nativeReadback["attachmentIDMap"]?.data(using: .utf8))
        let idMap = try XCTUnwrap(JSONSerialization.jsonObject(with: mapData) as? [String: String])
        let newID = try XCTUnwrap(idMap[oldID])
        XCTAssertNotEqual(newID, oldID)

        let readback = try SQLiteNotesStore(refresh: true).note(ref)
        let table = try XCTUnwrap(readback.attachments.first(where: { $0.id == newID }))
        XCTAssertEqual(table.tableRightToLeft, true)
        XCTAssertEqual(readback.document?.tables?[newID], expected)
    }
}
