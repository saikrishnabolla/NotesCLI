import Foundation
import NotesCore
import XCTest
@testable import NotesAutomation

final class LimitedReaderTests: XCTestCase {
    private let snapshot = #"""
    {
      "accounts": [
        {"id":"account-1","name":"iCloud","isDefault":true,"defaultFolderID":"folder-1"}
      ],
      "folders": [
        {"id":"folder-1","name":"Notes","accountID":"account-1","parentID":null,"path":["Notes"],"isRecentlyDeleted":false}
      ],
      "notes": [
        {"id":"x-coredata://note/1","title":"Quarterly plan","bodyHTML":"<h1>Quarterly plan</h1><div>Revenue &amp; costs</div>","folderID":"folder-1","folderPath":["Notes"],"accountID":"account-1","created":"2026-01-01T12:00:00Z","modified":"2026-01-02T12:00:00Z","isLocked":false},
        {"id":"x-coredata://note/2","title":"Private","bodyHTML":null,"folderID":"folder-1","folderPath":["Notes"],"accountID":"account-1","created":null,"modified":null,"isLocked":true}
      ]
    }
    """#

    func testReaderLabelsLimitedFidelityAndUnavailableFields() throws {
        let reader = ScriptingNotesReader(runner: StubRunner([ScriptOutput(stdout: snapshot)]), permissionCheck: {})

        XCTAssertEqual(reader.fidelity, .limited)
        XCTAssertTrue(reader.unavailableFields.contains("stable_note_id"))
        XCTAssertTrue(reader.unavailableFields.contains("attachments"))
        XCTAssertTrue(reader.unavailableFields.contains("formatting"))
        XCTAssertEqual(try reader.accounts().map(\.name), ["iCloud"])
        XCTAssertEqual(try reader.folders(account: "iCloud").map(\.path), [["Notes"]])
    }

    func testReaderSupportsLimitedListShowAndSearch() throws {
        let runner = StubRunner(Array(repeating: ScriptOutput(stdout: snapshot), count: 3))
        let reader = ScriptingNotesReader(runner: runner, permissionCheck: {})

        XCTAssertEqual(try reader.notes(NoteQuery(folder: "Notes", text: "revenue")).map(\.title), ["Quarterly plan"])
        let note = try reader.note("Quarterly plan")
        XCTAssertEqual(note.summary.id.coreDataID, "x-coredata://note/1")
        XCTAssertEqual(note.document?.text, "Quarterly plan\nRevenue & costs")
        XCTAssertThrowsError(try reader.note("Private")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "note_locked")
        }
        XCTAssertFalse(runner.calls[0].source.contains("revenue"))
    }

    func testReaderRejectsFiltersThatWouldImplyFullFidelity() throws {
        let reader = ScriptingNotesReader(runner: StubRunner([]), permissionCheck: {})

        XCTAssertThrowsError(try reader.notes(NoteQuery(pinnedOnly: true))) { error in
            XCTAssertEqual((error as? NotesError)?.code, "limited_read_unsupported")
        }
        XCTAssertThrowsError(try reader.attachments("x-coredata://note/1")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "limited_read_unsupported")
        }
        XCTAssertThrowsError(try reader.tags()) { error in
            XCTAssertEqual((error as? NotesError)?.code, "limited_read_unsupported")
        }
    }
}
