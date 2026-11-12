import XCTest
@testable import NotesCore

final class FakesTests: XCTestCase {
    func testNumberReferencesPreferExplicitHashAndRejectAmbiguousBareNumbers() throws {
        let sample = InMemoryNotes.sample()
        XCTAssertEqual(try sample.note("#1").summary.title, "Welcome")
        XCTAssertEqual(try sample.note("n1").summary.title, "Welcome")
        XCTAssertEqual(try sample.note("1").summary.title, "Welcome")
        XCTAssertEqual(try sample.summary("#2").number, 2)

        let account = try XCTUnwrap(try sample.accounts().first)
        let folder = try XCTUnwrap(try sample.folders(account: nil).first)
        let titledNumber = Note(summary: NoteSummary(
            id: NoteID(uuid: "numeric-title", shortID: "n99"), title: "1", snippet: "", folderID: folder.id,
            folderPath: folder.path, accountID: account.id, created: nil, modified: nil, isPinned: false,
            isLocked: false, isDeleted: false, hasChecklist: false, attachmentCount: 0, tags: []
        ), document: NoteDocument(text: "", runs: []), attachments: [])
        let ambiguous = InMemoryNotes(accounts: [account], folders: [folder], notes: [try sample.note("#1"), titledNumber])
        XCTAssertThrowsError(try ambiguous.note("1")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "ambiguous_reference")
        }
        XCTAssertEqual(try ambiguous.note("#1").summary.title, "Welcome")
    }
    func testHashTitleCollidingWithNoteNumberIsAmbiguousAndExplicitSyntaxResolves() throws {
        let sample = InMemoryNotes.sample()
        let account = try XCTUnwrap(try sample.accounts().first)
        let folder = try XCTUnwrap(try sample.folders(account: nil).first)
        let hashTitled = Note(summary: NoteSummary(
            id: NoteID(uuid: "hash-title", shortID: "n7"), title: "#1", snippet: "", folderID: folder.id,
            folderPath: folder.path, accountID: account.id, created: nil, modified: nil, isPinned: false,
            isLocked: false, isDeleted: false, hasChecklist: false, attachmentCount: 0, tags: []
        ), document: NoteDocument(text: "", runs: []), attachments: [])
        let notes = InMemoryNotes(accounts: [account], folders: [folder], notes: [try sample.note("#1"), hashTitled])
        XCTAssertThrowsError(try notes.note("#1")) { error in
            let error = error as? NotesError
            XCTAssertEqual(error?.code, "ambiguous_reference")
            XCTAssertEqual(error?.message, ##"Reference "#1" matches more than one note: #1 welcome "Welcome" (number), #7 hash-title "#1" (title)."##)
            XCTAssertEqual(error?.hint, "Use id:1 for the note number or title:#1 for the exact title.")
        }
        XCTAssertThrowsError(try notes.renameNote("#1", title: "Renamed")) { XCTAssertEqual(($0 as? NotesError)?.code, "ambiguous_reference") }
        XCTAssertEqual(try notes.note("title:#1").summary.id.uuid, "hash-title")
        XCTAssertEqual(try notes.note("TITLE:#1").summary.id.uuid, "hash-title")
        XCTAssertEqual(try notes.note("id:1").summary.id.uuid, "welcome")
        XCTAssertEqual(try notes.note("n1").summary.id.uuid, "welcome")
        XCTAssertEqual(try notes.note("id:7").summary.id.uuid, "hash-title")
        XCTAssertThrowsError(try notes.note("title:#2")) { XCTAssertEqual(($0 as? NotesError)?.code, "note_not_found") }
        XCTAssertThrowsError(try notes.note("id:99")) { XCTAssertEqual(($0 as? NotesError)?.code, "note_not_found") }

        let onlyTitled = InMemoryNotes(accounts: [account], folders: [folder], notes: [hashTitled])
        XCTAssertEqual(try onlyTitled.note("#1").summary.id.uuid, "hash-title")
    }
    func testNoteLifecycleAndFilters() throws {
        let fake = InMemoryNotes.sample()
        let folder = try fake.createFolder(name: "Work", parent: "Notes", account: "Demo").folderID!
        let id = try fake.createNote(title: "Plan", markdown: "First #work", folder: folder).noteID!.uuid
        XCTAssertEqual(try fake.note(id).summary.folderPath, ["Notes", "Work"])
        _ = try fake.appendToNote(id, markdown: "Second")
        XCTAssertEqual(try fake.note(id).document?.text, "First #work\nSecond")
        _ = try fake.renameNote(id, title: "New plan")
        XCTAssertEqual(try fake.note("New plan").summary.id.uuid, id)
        XCTAssertEqual(try fake.notes(NoteQuery(folder: folder, tag: "#work")).count, 1)
        _ = try fake.replaceBody(id, markdown: "Replacement")
        XCTAssertEqual(try fake.note(id).document?.text, "Replacement")
        XCTAssertNil(try fake.tags()["work"])
        _ = try fake.moveNote(id, toFolder: "Notes")
        XCTAssertEqual(try fake.note(id).summary.folderPath, ["Notes"])
        _ = try fake.deleteNote(id)
        XCTAssertTrue(try fake.note(id).summary.isDeleted)
        XCTAssertEqual(try fake.note(id).summary.folderPath, ["Recently Deleted"])
        XCTAssertFalse(try fake.notes(NoteQuery()).contains { $0.id.uuid == id })
        XCTAssertTrue(try fake.notes(NoteQuery(includeDeleted: true)).contains { $0.id.uuid == id })
    }
    func testFolderRenameDescendantsAndDeleteSoftly() throws {
        let fake = InMemoryNotes.sample()
        let child = try fake.createFolder(name: "Child", parent: "Notes", account: nil).folderID!
        let id = try fake.createNote(title: "Child note", markdown: "Body", folder: child).noteID!.uuid
        _ = try fake.renameFolder("Notes", name: "Renamed")
        XCTAssertEqual(try fake.note(id).summary.folderPath, ["Renamed", "Child"])
        _ = try fake.deleteFolder("Renamed")
        XCTAssertTrue(try fake.note(id).summary.isDeleted)
        XCTAssertEqual(try fake.notes(NoteQuery(includeDeleted: true)).count, 3)
        XCTAssertEqual(try fake.folders(account: nil).map(\.name), ["Recently Deleted"])
    }
    func testAmbiguityAndMissing() throws {
        let fake = InMemoryNotes.sample()
        _ = try fake.createNote(title: "Welcome", markdown: "Duplicate", folder: nil)
        XCTAssertThrowsError(try fake.note("Welcome")) { XCTAssertEqual(($0 as? NotesError)?.code, "ambiguous_note") }
        XCTAssertEqual(try fake.note("welcome").summary.id.uuid, "welcome")
        XCTAssertThrowsError(try fake.note("missing")) { XCTAssertEqual(($0 as? NotesError)?.code, "note_not_found") }
        XCTAssertEqual(try fake.notes(NoteQuery(limit: 0)).count, 0)
        XCTAssertEqual(try fake.notes(NoteQuery(pinnedOnly: true)).map { $0.id.uuid }, ["welcome"])
    }
}
