import XCTest
@testable import NotesCore

final class FakesTests: XCTestCase {
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
