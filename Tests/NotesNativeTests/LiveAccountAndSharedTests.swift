import Foundation
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesStore
import XCTest

final class LiveAccountAndSharedTests: XCTestCase {
    func testLocalAccountWorkflow() throws {
        guard environment("NOTESCLI_LIVE_ACCOUNT_TESTS") == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_ACCOUNT_TESTS=1 after ticking Enable On My Mac account in Notes Settings.")
        }
        try NotesAutomationPermission.check()
        let reader = ScriptingNotesReader(timeout: 20, snapshotTTL: 0)
        let localAccounts = try reader.accounts().filter {
            $0.name.compare("On My Mac", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard localAccounts.count == 1, let account = localAccounts.first else {
            XCTFail("Expected one local account. Tick Enable On My Mac account in Notes Settings; the test will not create it.")
            return
        }

        let writer = ScriptingNotesWriter(timeout: 20)
        let token = UUID().uuidString.lowercased()
        let rootName = "notescli-test-local-\(token)"
        var noteID: String?
        var folders: [String] = []
        defer {
            if let noteID { _ = try? writer.deleteNote(noteID) }
            for folder in folders.reversed() { _ = try? writer.deleteFolder(folder) }
        }

        let root = try verified(writer.createFolder(name: rootName, account: account.id))
        let rootID = try XCTUnwrap(root.folderID)
        folders.append(rootID)
        let child = try verified(writer.createFolder(name: "moved", parent: rootID, account: account.id))
        let childID = try XCTUnwrap(child.folderID)
        folders.append(childID)

        let created = try verified(writer.createNote(title: "notescli-test-local-\(token)", markdown: "local account proof", folder: rootID))
        noteID = try XCTUnwrap(created.noteID?.uuid ?? created.noteID?.coreDataID)
        let createdID = try XCTUnwrap(noteID)

        try waitForReader {
            let note = try? reader.note(createdID)
            return note?.summary.accountID == account.id && note?.summary.folderID != nil
        }
        let beforeMove = try reader.note(createdID)
        XCTAssertEqual(beforeMove.summary.accountID, account.id)
        XCTAssertTrue(beforeMove.document?.text.contains("local account proof") == true)
        XCTAssertTrue(try reader.notes(NoteQuery(account: account.id)).contains { $0.id.uuid == beforeMove.summary.id.uuid })
        XCTAssertTrue(try reader.folders(account: account.id).contains { $0.id == beforeMove.summary.folderID })

        _ = try verified(writer.moveNote(createdID, toFolder: childID))
        try waitForReader {
            (try? reader.note(createdID).summary.folderID) == childID
        }
        XCTAssertEqual(try reader.note(createdID).summary.folderID, childID)

        _ = try verified(writer.deleteNote(createdID))
        noteID = nil
        _ = try verified(writer.deleteFolder(childID))
        folders.removeAll { $0 == childID }
        _ = try verified(writer.deleteFolder(rootID))
        folders.removeAll { $0 == rootID }
    }

    func testSharedOwnerParticipantRolesMentionActivityAndConcurrentEdit() throws {
        guard environment("NOTESCLI_LIVE_SHARED_TESTS") == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SHARED_TESTS=1 with the documented owner, read-write, and read-only fixture IDs.")
        }
        let ownerID = try requiredEnvironment("NOTESCLI_SHARED_NOTE_ID")
        let writableID = try requiredEnvironment("NOTESCLI_SHARED_READ_WRITE_NOTE_ID")
        let readOnlyID = try requiredEnvironment("NOTESCLI_SHARED_READ_ONLY_NOTE_ID")
        let store = try SQLiteNotesStore(refresh: true)
        let owner = try fixture(ownerID, store: store)
        let writable = try fixture(writableID, store: store)
        let readOnly = try fixture(readOnlyID, store: store)
        XCTAssertEqual(Set([owner.summary.id.uuid, writable.summary.id.uuid, readOnly.summary.id.uuid]).count, 3)

        let writer = NativeNotesWriter()
        let token = UUID().uuidString.lowercased()
        let ownerMarker = "notescli-owner-\(token)"
        let participantMarker = "notescli-participant-\(token)"
        let readOnlyMarker = "notescli-read-only-refusal-\(token)"
        let concurrentMarker = "notescli-concurrent-\(token)"
        var insertedMentionID: String?
        defer {
            if let insertedMentionID { _ = try? writer.deleteAttachment(owner.summary.id.uuid, attachmentID: insertedMentionID, allowShared: true) }
            _ = try? writer.replaceText(owner.summary.id.uuid, find: ownerMarker, replacement: "", allowShared: true)
            _ = try? writer.replaceText(owner.summary.id.uuid, find: concurrentMarker, replacement: "", allowShared: true)
            _ = try? writer.replaceText(writable.summary.id.uuid, find: participantMarker, replacement: "", allowShared: true)
            _ = try? writer.replaceText(readOnly.summary.id.uuid, find: readOnlyMarker, replacement: "", allowShared: true)
        }

        _ = try writer.appendMarkdown(owner.summary.id.uuid, markdown: ownerMarker, allowShared: true)
        _ = try writer.appendMarkdown(writable.summary.id.uuid, markdown: participantMarker, allowShared: true)
        let edited = try SQLiteNotesStore(refresh: true)
        XCTAssertTrue(try edited.note(owner.summary.id.uuid).document?.text.contains(ownerMarker) == true)
        XCTAssertTrue(try edited.note(writable.summary.id.uuid).document?.text.contains(participantMarker) == true)

        let beforeMention = Set(owner.attachments.map(\.id))
        let participant = try XCTUnwrap(owner.summary.participants?.first(where: { $0.userID?.isEmpty == false }))
        let mentionText = participant.displayName.map { "@\($0)" } ?? "@participant"
        _ = try writer.insertMention(owner.summary.id.uuid, text: mentionText,
                                     userRecordName: try XCTUnwrap(participant.userID), position: nil, allowShared: true)
        let afterMention = try SQLiteNotesStore(refresh: true).note(owner.summary.id.uuid)
        insertedMentionID = try XCTUnwrap(afterMention.attachments.first {
            $0.kind == "mention" && !beforeMention.contains($0.id)
        }?.id)

        XCTAssertThrowsError(try writer.appendMarkdown(readOnly.summary.id.uuid, markdown: readOnlyMarker, allowShared: true)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "shared_read_only")
        }

        print("LIVE shared: append \(concurrentMarker) to the owner fixture from the second Apple ID within 60 seconds.")
        let deadline = Date().addingTimeInterval(60)
        var concurrentSeen = false
        while Date() < deadline {
            if let text = try? SQLiteNotesStore(refresh: true).note(owner.summary.id.uuid).document?.text,
               text.contains(ownerMarker), text.contains(concurrentMarker) {
                concurrentSeen = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(concurrentSeen, "While this test runs, append the printed concurrent marker from the second Apple ID on iCloud.com.")
        guard concurrentSeen else { return }

        for note in [owner, writable] {
            let activity = try waitForActivity(note.summary.id.uuid, writer: writer)
            XCTAssertEqual(activity.noteID, note.summary.id.uuid)
            XCTAssertNotNil(activity.blob)
        }
    }

    private func fixture(_ ref: String, store: SQLiteNotesStore) throws -> Note {
        let note = try store.note(ref)
        guard note.summary.title.hasPrefix("notescli-test-") else {
            throw NotesError("unsafe_test_target", "Shared live fixtures must have titles beginning with notescli-test-.")
        }
        guard note.summary.isShared == true else {
            throw NotesError("fixture_not_shared", "The supplied note is not shared.")
        }
        return note
    }

    private func verified(_ result: WriteResult) throws -> WriteResult {
        guard result.outcome != .unknown else {
            throw NotesError("unknown_write", "A live account write had an unknown outcome; no retry was attempted.")
        }
        return result
    }

    private func waitForReader(_ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw NotesError("live_test_timeout", "Notes did not expose the live-test change before the timeout.")
    }

    private func waitForActivity(_ ref: String, writer: NativeNotesWriter) throws -> CollaborationActivityExport {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let activity = try writer.collaborationActivity(ref)
            if activity.status != .absent, activity.status != .decoderUnavailable { return activity }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw NotesError("live_test_timeout", "Notes did not expose collaboration activity before the timeout.")
    }

    private func requiredEnvironment(_ name: String) throws -> String {
        guard let value = environment(name), !value.isEmpty else {
            throw NotesError("missing_fixture", "Set \(name) for the shared live test.")
        }
        return value
    }

    private func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }
}
