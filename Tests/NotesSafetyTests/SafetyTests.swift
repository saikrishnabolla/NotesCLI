import Foundation
import XCTest
import NotesCore
@testable import NotesSafety

final class SafetyTests: XCTestCase {
    func testJournalResolutionIdentityDoesNotInferFromNamesOrTitles() throws {
        let titleOnly = JournalEntry(id: "one", operation: "createNote", argumentsHash: "", arguments: Data(#"{"title":"Unique"}"#.utf8),
                                     idempotencyKey: nil, started: Date(), outcome: .unknown, noteID: nil, result: nil, message: nil)
        XCTAssertNil(titleOnly.stableDispatchIdentity)
        let stable = JournalEntry(id: "two", operation: "renameNote", argumentsHash: "", arguments: Data(#"{"ref":"Old title","stable_id":"uuid-1"}"#.utf8),
                                  idempotencyKey: nil, started: Date(), outcome: .unknown, noteID: nil, result: nil, message: nil)
        XCTAssertEqual(stable.stableDispatchIdentity, "uuid-1")
    }
    func testAllowlistMatchesOnlyConfiguredTrees() throws {
        let guardrail = WriteAllowlist("Work, Inbox > Agents")
        XCTAssertTrue(guardrail.allows(["Work"]))
        XCTAssertTrue(guardrail.allows(["Work", "Archive"]))
        XCTAssertTrue(guardrail.allows(["Inbox", "Agents", "Runs"]))
        XCTAssertFalse(guardrail.allows(["Inbox"]))
        XCTAssertFalse(guardrail.allows(["Personal"]))
        XCTAssertThrowsError(try guardrail.require(["Personal"])) { error in
            XCTAssertEqual((error as? NotesError)?.code, "write_not_allowed")
        }
        XCTAssertTrue(WriteAllowlist(nil).allows(["Anywhere"]))
    }

    func testJournalReplaysAKeyAndRejectsDifferentArguments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try WriteJournal(url: directory.appendingPathComponent("journal.sqlite"))
        let first = try journal.begin(operation: "rename", arguments: Data(#"{"ref":"one","title":"new"}"#.utf8), idempotencyKey: "key")
        XCTAssertFalse(first.replayed)
        try journal.finish(first.entry.id, outcome: .verified, noteID: "note-1", result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "note-1")))
        let replay = try journal.begin(operation: "rename", arguments: Data(#"{"ref":"one","title":"new"}"#.utf8), idempotencyKey: "key")
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.entry.outcome, .verified)
        XCTAssertEqual(replay.entry.result?.noteID?.uuid, "note-1")
        XCTAssertThrowsError(try journal.begin(operation: "rename", arguments: Data(#"{"ref":"one","title":"other"}"#.utf8), idempotencyKey: "key")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "idempotency_conflict")
        }
        XCTAssertEqual(try journal.list().count, 1)
    }

    func testSnapshotWritesFullJSONAndMarkdownAndLoadsLatest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(rootURL: directory)
        let note = try InMemoryNotes.sample().note("welcome")
        let saved = try store.save(note)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.directory.appendingPathComponent("note.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.directory.appendingPathComponent("note.md").path))
        XCTAssertEqual(try store.load(note.summary.id.uuid, snapshot: saved.id).note.summary.title, note.summary.title)
        XCTAssertEqual(try store.load(note.summary.id.uuid).markdown, note.document?.markdown())
        XCTAssertEqual(try store.history(note.summary.id.uuid).map(\.id), [saved.id])
        XCTAssertThrowsError(try store.load(note.summary.id.uuid, snapshot: "../../outside")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_not_found")
        }
    }

    func testConcurrencyRejectsStaleDateAndRevision() throws {
        let note = try InMemoryNotes.sample().note("welcome")
        let modified = try XCTUnwrap(note.summary.modified)
        let iso = ISO8601DateFormatter().string(from: modified)
        XCTAssertNoThrow(try ConcurrencyGuard.require(note, ifModified: iso, expectRevision: nil))
        var subsecondNote = note
        subsecondNote.summary.modified = modified.addingTimeInterval(0.75)
        XCTAssertThrowsError(try ConcurrencyGuard.require(subsecondNote, ifModified: iso, expectRevision: nil)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "stale_note")
        }
        XCTAssertNoThrow(try ConcurrencyGuard.require(note, ifModified: nil, expectRevision: ConcurrencyGuard.revision(note)))
        XCTAssertThrowsError(try ConcurrencyGuard.require(note, ifModified: "2020-01-01T00:00:00Z", expectRevision: nil)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "stale_note")
        }
        XCTAssertThrowsError(try ConcurrencyGuard.require(note, ifModified: nil, expectRevision: "old")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "stale_note")
        }
    }

    func testSnapshotsWithAttachmentsAreMarkedUnrestorable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(rootURL: directory)
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(id: "attachment", typeUTI: "public.png")]
        note.summary.attachmentCount = 1
        let saved = try store.save(note)
        XCTAssertFalse(saved.restorable)
        XCTAssertFalse(try XCTUnwrap(store.history(note.summary.id.uuid).first).restorable)
        XCTAssertThrowsError(try store.loadRestorable(note.summary.id.uuid, snapshot: saved.id)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_has_attachments")
        }
    }
}
