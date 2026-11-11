import Foundation
import XCTest
@testable import NotesCore

final class ReadParityTests: XCTestCase {
    func testOutlineUsesUTF16OffsetsAndBuildsTree() throws {
        let text = "😀 Title\nSection\nChild\nBody"
        let runs = [
            AttributeRun(length: "😀 Title\n".utf16.count, paragraph: ParagraphStyle(kind: .title)),
            AttributeRun(length: "Section\n".utf16.count, paragraph: ParagraphStyle(kind: .heading)),
            AttributeRun(length: "Child\n".utf16.count, paragraph: ParagraphStyle(kind: .subheading)),
            AttributeRun(length: "Body".utf16.count, paragraph: ParagraphStyle(kind: .body))
        ]
        let outline = NoteDocument(text: text, runs: runs).outline()
        XCTAssertEqual(outline.first?.offset, 0)
        XCTAssertEqual(outline.first?.length, 8)
        XCTAssertEqual(outline.first?.children.first?.offset, 9)
        XCTAssertEqual(outline.first?.children.first?.children.first?.title, "Child")
    }

    func testStableCursorIsOpaqueAndRejectsInvalidInput() throws {
        let payload = StableCursorPayload(sort: "modified", key: "12", id: "N1")
        let cursor = try StableCursor.encode(payload)
        XCTAssertFalse(cursor.contains("{"))
        XCTAssertEqual(try StableCursor.decode(cursor), payload)
        XCTAssertThrowsError(try StableCursor.decode("not-a-cursor"))
    }

    func testClassicDrawingJSONStrokesBecomeSVGAndMentionIdentityRenders() throws {
        let data = try JSONSerialization.data(withJSONObject: ["strokes": [[["x": 1, "y": 2], ["x": 3, "y": 4]]]])
        let svg = try XCTUnwrap(NotesDrawingDecoder.svg(data))
        XCTAssertTrue(svg.contains("<path")); XCTAssertTrue(svg.contains("M1.000 2.000"))

        var ref = InlineRef(id: "mention", typeUTI: "com.apple.notes.inlinetextattachment.mention")
        ref.displayText = "Pat"
        let document = NoteDocument(text: "\u{fffc}", runs: [AttributeRun(length: 1, attachment: ref)])
        let attachment = Attachment(id: "mention", typeUTI: ref.typeUTI, participantName: "Pat",
                                    participantEmail: "pat@example.test", participantUserID: "user-1")
        let markdown = document.markdown(attachments: [attachment])
        XCTAssertTrue(markdown.contains("Pat")); XCTAssertTrue(markdown.contains("pat@example.test")); XCTAssertTrue(markdown.contains("user-1"))
    }

    func testShortAndNumericReferencesAndAttachmentKinds() throws {
        let fake = InMemoryNotes.sample()
        XCTAssertEqual(try fake.note("n1").summary.id.uuid, "welcome")
        XCTAssertEqual(try fake.note("1").summary.id.uuid, "welcome")
        let summary = NoteSummary(id: NoteID(uuid: "with-image", shortID: "n9"), title: "Image", snippet: "", folderID: "fake-folder",
                                  folderPath: ["Notes"], accountID: "fake-account", created: nil, modified: nil,
                                  isPinned: false, isLocked: false, isDeleted: false, hasChecklist: true,
                                  attachmentCount: 1, tags: [])
        let custom = InMemoryNotes(accounts: try fake.accounts(), folders: try fake.folders(account: nil),
                                   notes: [Note(summary: summary, document: NoteDocument(text: "", runs: []),
                                                attachments: [Attachment(id: "i", typeUTI: "public.jpeg"),
                                                              Attachment(id: "l", typeUTI: "com.apple.notes.inlinetextattachment.link")])])
        XCTAssertEqual(try custom.notes(NoteQuery(attachmentKinds: ["image", "checklist"])).count, 1)
        XCTAssertEqual(try custom.notes(NoteQuery(attachmentKinds: ["link"])).count, 1)
        XCTAssertEqual(Attachment(id: "f", typeUTI: "public.data").kind, "file")
    }
}
