import XCTest
import NotesCore
@testable import NotesAutomation

final class VerificationTests: XCTestCase {
    func testRenameDoesNotVerifyOnlyBecauseModifiedDateIsRecent() throws {
        let reader = InMemoryNotes.sample()
        let note = try reader.note("welcome")
        let request = WriteVerificationRequest(operation: .renameNote, ref: "welcome", title: "Expected", result: WriteResult(
            outcome: .unverified, noteID: note.summary.id))
        let verifier = FreshWriteVerifier(attempts: 1, interval: 0, freshReader: { reader })
        let result = verifier.verify(request)
        XCTAssertEqual(result.outcome, .unverified)
        XCTAssertEqual(result.noteID?.uuid, "welcome")
        XCTAssertTrue(result.mismatch?.contains("title") == true)
    }

    func testCreateVerificationReturnsStableIdentifier() throws {
        let reader = InMemoryNotes.sample()
        let created = try reader.createNote(title: "Draft", markdown: "Body", folder: "Notes")
        let request = WriteVerificationRequest(operation: .createNote, title: "Draft", markdown: "Body", expectedBody: "Body",
            expectedFolderPath: ["Notes"],
            result: WriteResult(outcome: .unverified, noteID: created.noteID))
        let result = FreshWriteVerifier(attempts: 1, interval: 0, freshReader: { reader }).verify(request)
        XCTAssertEqual(result.outcome, .verified)
        XCTAssertFalse(result.noteID?.uuid.isEmpty == true)
    }

    func testFolderVerificationUsesScriptingIdentity() throws {
        let reader = InMemoryNotes.sample()
        let folderID = "x-coredata://active-folder"
        let created = WriteVerificationRequest(operation: .createFolder, expectedFolderPath: ["Notes"],
            result: WriteResult(outcome: .unverified, folderID: folderID))
        let createResult = FreshWriteVerifier(attempts: 1, interval: 0, freshReader: { reader }, activeFolders: {
            [ScriptingFolder(id: folderID, path: ["Notes"], accountID: "account")]
        }).verify(created)
        XCTAssertEqual(createResult.outcome, .verified)
        XCTAssertEqual(createResult.folderID, folderID)

        let deleted = WriteVerificationRequest(operation: .deleteFolder, expectedFolderPath: ["Notes"],
            result: WriteResult(outcome: .unverified, folderID: folderID))
        let deleteResult = FreshWriteVerifier(attempts: 1, interval: 0, freshReader: { reader }, activeFolders: {
            [ScriptingFolder(id: "x-coredata://stale-path", path: ["Notes"], accountID: "account")]
        }).verify(deleted)
        XCTAssertEqual(deleteResult.outcome, .verified)
        XCTAssertEqual(deleteResult.folderID, folderID)
    }

    func testDeleteVerificationUsesScriptingIdentityWhenStoreLags() throws {
        let reader = InMemoryNotes.sample()
        let note = try reader.note("welcome")
        let coreDataID = "x-coredata://synthetic/ICNote/p1"
        let request = WriteVerificationRequest(operation: .deleteNote,
            result: WriteResult(outcome: .unverified, noteID: NoteID(uuid: note.summary.id.uuid, coreDataID: coreDataID)))
        let result = FreshWriteVerifier(attempts: 1, interval: 0, freshReader: { reader }, deletionReader: { ref in
            XCTAssertEqual(ref, coreDataID)
            return true
        }).verify(request)
        XCTAssertEqual(result.outcome, .verified)
    }

    func testAppendAndReplaceRequireExactExpectedBodyIncludingWhitespace() throws {
        let sample = InMemoryNotes.sample()
        var note = try sample.note("welcome")
        note.document = NoteDocument(text: note.summary.title + "\nbefore  \nappend\n", runs: [])
        let reader = InMemoryNotes(accounts: try sample.accounts(), folders: try sample.folders(account: nil), notes: [note])
        let id = note.summary.id
        let exact = note.summary.title + "\nbefore  \nappend\n"
        let append = WriteVerificationRequest(operation: .appendToNote, ref: id.uuid, markdown: "append",
            bodyBefore: note.summary.title + "\nbefore  \n", expectedBody: exact, expectedBodyIncludesTitle: true,
            result: WriteResult(outcome: .unverified, noteID: id))
        XCTAssertEqual(FreshWriteVerifier(attempts: 1, interval: 0, freshReader: { reader }).verify(append).outcome, .verified)

        let wrongAppend = WriteVerificationRequest(operation: .appendToNote, ref: id.uuid, markdown: "append",
            bodyBefore: note.summary.title + "\nbefore \n", expectedBody: note.summary.title + "\nbefore \nappend\n",
            expectedBodyIncludesTitle: true, result: WriteResult(outcome: .unverified, noteID: id))
        XCTAssertEqual(FreshWriteVerifier(attempts: 1, interval: 0, freshReader: { reader }).verify(wrongAppend).outcome, .unverified)

        let replace = WriteVerificationRequest(operation: .replaceBody, ref: id.uuid, markdown: "before  \nappend",
            bodyBefore: "ignored", expectedBody: "before  \nappend\n",
            result: WriteResult(outcome: .unverified, noteID: id))
        XCTAssertEqual(FreshWriteVerifier(attempts: 1, interval: 0, freshReader: { reader }).verify(replace).outcome, .verified)
    }

    func testBodyRewriteCannotVerifyAfterNativeFeaturesDisappear() throws {
        let sample = InMemoryNotes.sample()
        var note = try sample.note("welcome")
        note.document = NoteDocument(text: "Welcome\nbody", runs: [])
        let reader = InMemoryNotes(accounts: try sample.accounts(), folders: try sample.folders(account: nil), notes: [note])
        let request = WriteVerificationRequest(operation: .appendToNote, ref: note.summary.id.uuid,
            bodyBefore: "Welcome\n", expectedBody: "Welcome\nbody", expectedBodyIncludesTitle: true,
            nativeFeaturesBefore: ["checklists", "highlights"],
            result: WriteResult(outcome: .unverified, noteID: note.summary.id))

        let result = FreshWriteVerifier(attempts: 1, interval: 0, freshReader: { reader }).verify(request)
        XCTAssertEqual(result.outcome, .unverified)
        XCTAssertEqual(result.mismatch, "native-only features changed: before checklists, highlights; after none")
    }
}
