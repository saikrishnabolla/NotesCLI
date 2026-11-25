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
        {"id":"x-coredata://note/1","title":"Quarterly plan","bodyText":"Quarterly plan\n\nRevenue & costs","folderID":"folder-1","folderPath":["Notes"],"accountID":"account-1","created":"2026-01-01T12:00:00Z","modified":"2026-01-02T12:00:00Z","isLocked":false},
        {"id":"x-coredata://note/2","title":"Private","bodyText":null,"folderID":"folder-1","folderPath":["Notes"],"accountID":"account-1","created":null,"modified":null,"isLocked":true}
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
        XCTAssertEqual(note.document?.text, "Quarterly plan\n\nRevenue & costs")
        XCTAssertThrowsError(try reader.note("Private")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "note_locked")
        }
        XCTAssertFalse(runner.calls[0].source.contains("revenue"))
    }

    func testPickerCatalogAndSearchShareOneAutomationSnapshotAndSkipLockedText() throws {
        let input = snapshot.replacingOccurrences(of: "\"bodyText\":null", with: #""bodyText":"secret needle""#)
        let runner = StubRunner([ScriptOutput(stdout: input)])
        let reader = ScriptingNotesReader(runner: runner, snapshotTTL: 60, permissionCheck: {})
        XCTAssertEqual(Set(try reader.notes(.init(), sort: .modified).map(\.title)), ["Quarterly plan", "Private"])
        XCTAssertEqual(try reader.editorSearch(XCTUnwrap(EditorSearchQuery("Notes costs"))),
                       [.init(id: "x-coredata://note/1", excerpt: "Revenue & costs")])
        XCTAssertTrue(try reader.editorSearch(XCTUnwrap(EditorSearchQuery("secret needle"))).isEmpty)
        XCTAssertTrue(try reader.notes(.init(text: "secret needle")).isEmpty)
        XCTAssertEqual(try reader.editorSearch(XCTUnwrap(EditorSearchQuery("Private"))), [.init(id: "x-coredata://note/2")])
        XCTAssertEqual(runner.calls.count, 1)
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

    func testReaderRefreshesExpiredSnapshot() throws {
        let updated = snapshot.replacingOccurrences(of: "Quarterly plan", with: "Updated plan")
        let runner = StubRunner([ScriptOutput(stdout: snapshot), ScriptOutput(stdout: updated)])
        let reader = ScriptingNotesReader(runner: runner, snapshotTTL: 0, permissionCheck: {})

        XCTAssertEqual(try reader.notes(NoteQuery()).first?.title, "Quarterly plan")
        XCTAssertEqual(try reader.notes(NoteQuery()).first?.title, "Updated plan")
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testWarmSnapshotChecksPermissionAndDropsCachedBodiesOnDenial() throws {
        let checks = Recorder()
        let updated = snapshot.replacingOccurrences(of: "Revenue & costs", with: "Updated")
        let runner = StubRunner([ScriptOutput(stdout: snapshot), ScriptOutput(stdout: updated)])
        let reader = ScriptingNotesReader(runner: runner, snapshotTTL: 60, permissionCheck: { try checks.check() })
        let query = try XCTUnwrap(EditorSearchQuery("revenue"))
        XCTAssertEqual(try reader.editorSearch(query).count, 1)
        XCTAssertEqual(try reader.editorSearch(query).count, 1)
        XCTAssertThrowsError(try reader.editorSearch(query)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "automation_denied")
        }
        XCTAssertTrue(try reader.editorSearch(query).isEmpty)
        XCTAssertEqual(runner.calls.count, 2)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func check() throws {
            try lock.withLock {
                count += 1
                if count == 3 { throw NotesError("automation_denied", "Denied") }
            }
        }
    }

    func testSnapshotScriptKeepsBodiesTiedToTheExactUnlockedNote() throws {
        let snapshot = try runSnapshotScript(scenario: "lock flips")
        let notes = try XCTUnwrap(snapshot["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.compactMap { $0["id"] as? String }, ["open", "locked", "flip"])
        XCTAssertEqual(notes[0]["bodyText"] as? String, "Open text")
        XCTAssertNil(notes[0]["bodyHTML"])
        XCTAssertTrue(notes[1]["bodyText"] is NSNull)
        XCTAssertTrue(notes[2]["bodyText"] is NSNull)
        XCTAssertEqual(notes[2]["isLocked"] as? Bool, true)
        XCTAssertEqual(notes[0]["folderPath"] as? [String], ["Root", "Nested"])
        let folders = try XCTUnwrap(snapshot["folders"] as? [[String: Any]])
        let trash = try XCTUnwrap(folders.first { $0["id"] as? String == "trash" })
        XCTAssertEqual(trash["isRecentlyDeleted"] as? Bool, true)
        XCTAssertEqual(trash["noteCount"] as? Int, 1)
    }

    func testSnapshotScriptRejectsAPropertiesRecordForTheWrongNote() throws {
        let snapshot = try runSnapshotScript(scenario: "wrong id")
        XCTAssertEqual(snapshot["errorCode"] as? String, "automation_snapshot_changed")
        XCTAssertNil(snapshot["notes"])
    }

    func testLiveAutomationSnapshotWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_AUTOMATION_READ"] == "1" else {
            throw XCTSkip("Requires an existing Notes Automation grant.")
        }
        let reader = ScriptingNotesReader(snapshotTTL: 8)
        let marker = ProcessInfo.processInfo.environment["NOTESCLI_LIVE_AUTOMATION_MARKER"]
        let query = try XCTUnwrap(EditorSearchQuery(marker ?? "notescli-live-probe-" + UUID().uuidString))
        let start = ContinuousClock.now
        XCTAssertFalse(try reader.notes(.init(), sort: .modified).isEmpty)
        let catalog = start.duration(to: .now)
        let firstStart = ContinuousClock.now
        let hits = try reader.editorSearch(query)
        let first = firstStart.duration(to: .now)
        let warmStart = ContinuousClock.now
        XCTAssertEqual(try reader.editorSearch(query), hits)
        print("Live Notes Automation: open picker \(catalog), first body search \(first), repeat \(warmStart.duration(to: .now))")
        if let marker {
            XCTAssertEqual(hits.count, 1)
            XCTAssertTrue(hits.first?.excerpt?.contains(marker) == true)
        } else {
            XCTAssertTrue(hits.isEmpty)
        }
        XCTAssertFalse(try reader.accounts().isEmpty)
        XCTAssertFalse(try reader.folders(account: nil).isEmpty)
        print("Live Notes Automation snapshot and access: \(start.duration(to: .now))")
    }

    private func runSnapshotScript(scenario: String) throws -> [String: Any] {
        let fixture = #"""
        function Application() {
          const account = {id: () => 'account', name: () => 'Test'};
          const root = {id: () => 'root', properties: () => ({id: 'root', name: 'Root', container: account})};
          const nested = {id: () => 'nested', properties: () => ({id: 'nested', name: 'Nested', container: root})};
          const trash = {id: () => 'trash', properties: () => ({id: 'trash', name: 'Corbeille test', container: account})};
          account.defaultFolder = () => root;
          account.folders = {id: () => ['nested', 'root', 'trash'], byId: key => ({root, nested, trash})[key]};
          root.notes = {id: () => []};
          trash.notes = {id: () => ['trashed'], whose: () => {throw Error('must not read trash');}};
          nested.notes = {
            id: () => ['open', 'locked', 'flip'],
            whose: selector => {
              if (selector.passwordProtected === false) return {id: () => ['open', 'flip']};
              const [key, lock] = selector._and;
              if (lock.passwordProtected !== false || !['open', 'flip'].includes(key.id)) throw Error('unsafe selector');
              return {at: index => ({properties: () => {
                if (index !== 0) throw Error('must read one exact record');
                if (key.id === 'flip') throw {errorNumber: -1719};
                return {id: scenario === 'wrong id' ? 'other' : 'open', name: 'Open',
                  container: nested, passwordProtected: false, plaintext: 'Open text', body: '<img src="data:...">'};
              }})};
            },
            byId: key => ({id: () => key, name: () => key, container: () => nested, passwordProtected: () => true,
                creationDate: () => null, modificationDate: () => null,
                properties: () => {throw Error('unfiltered properties requested');}})
          };
          return {defaultAccount: () => account, accounts: () => [account]};
        }
        """#
        let script = ScriptingNotesReader.source.replacingOccurrences(of: "function run(argv)", with: "function snapshot(argv)")
        let wrapper = #"""
        function run(argv) {
          const scenario = argv[0];
          SCRIPT_FIXTURE
          SCRIPT_SNAPSHOT
          return snapshot(['["Corbeille test"]']);
        }
        """#
        let source = wrapper.replacingOccurrences(of: "SCRIPT_FIXTURE", with: fixture)
            .replacingOccurrences(of: "SCRIPT_SNAPSHOT", with: script)
        let output = try OSAScriptRunner().run(source: source, language: .javaScript,
                                               arguments: [scenario], timeout: 5)
        XCTAssertEqual(output.status, 0, output.stderr)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
    }
}
