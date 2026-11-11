import XCTest
import NotesCore
import NotesMCP

final class PresentationTests: XCTestCase {
    func testFormatsAndAttachments() throws {
        var note = try InMemoryNotes.sample().note("welcome")
        note.document = NoteDocument(text: "Bold\nTask\n\u{fffc}", runs: [
            AttributeRun(length: 5, paragraph: ParagraphStyle(kind: .heading), font: FontStyle(bold: true)),
            AttributeRun(length: 5, paragraph: ParagraphStyle(kind: .checklist, checked: true)),
            AttributeRun(length: 1, attachment: InlineRef(id: "a", typeUTI: "public.text"))])
        note.attachments = [Attachment(id: "a", typeUTI: "public.text", filename: "example.txt", filePath: "/tmp/example.txt")]
        let markdown = try NotePresentation.render(note, format: "markdown")
        XCTAssertTrue(markdown.contains("## **Bold")); XCTAssertTrue(markdown.contains("example.txt"))
        XCTAssertTrue(markdown.contains("- [x] Task"))
        let text = try NotePresentation.render(note, format: "text", attachments: false)
        XCTAssertEqual(text, "Bold\nTask\n")
        let html = try NotePresentation.render(note, format: "html")
        XCTAssertTrue(html.contains("<strong>")); XCTAssertTrue(html.contains("href="))
        let json = try NotePresentation.render(note, format: "json", attachments: false)
        let decoded = try JSONDecoder().decode(JSONNote.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.attachments.isEmpty)
        XCTAssertEqual(decoded.document?.runs.map(\.length), [5, 5, 1])
        XCTAssertNil(decoded.document?.runs.last?.attachment)
    }
    private struct JSONNote: Decodable {
        let document: NoteDocument?
        let attachments: [Attachment]
    }
    func testLockedNotesAndHTMLEscaping() throws {
        var note = try InMemoryNotes.sample().note("welcome")
        note.document = nil
        XCTAssertEqual(try NotePresentation.render(note, format: "text"), "[Locked note]")
        note.document = NoteDocument(text: "<script>&\"", runs: [])
        XCTAssertEqual(try NotePresentation.render(note, format: "html"), "<div>&lt;script&gt;&amp;&quot;</div>")
    }
}
