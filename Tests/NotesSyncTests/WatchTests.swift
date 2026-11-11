import NotesCore
import XCTest
@testable import NotesSync

final class WatchTests: XCTestCase {
    func testPollsCreatedModifiedAndDeletedEvents() throws {
        let fake = InMemoryNotes.sample(), poller = NoteEventPoller(reader: fake)
        XCTAssertTrue(try poller.poll().isEmpty)
        _ = try fake.renameNote("welcome", title: "Changed")
        XCTAssertEqual(try poller.poll().map(\.kind), [.modified])
        let created = try fake.createNote(title: "New", markdown: "body", folder: "Notes")
        XCTAssertEqual(try poller.poll().map(\.kind), [.created])
        _ = try fake.deleteNote(try XCTUnwrap(created.noteID?.uuid))
        XCTAssertEqual(try poller.poll().map(\.kind), [.deleted])
    }
}
