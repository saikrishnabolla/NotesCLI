import Foundation
import XCTest
@testable import NotesCore

final class NotesImportFormattingTests: XCTestCase {
    func testSpacingDoesNotBreakListsTablesOrFences() {
        let source = """
        # My report

        A paragraph.

        Another paragraph.

        # Section

        - First
        - Second

        | A | B | C | D | E |
        |---|---|---|---|---|
        | 1 | 2 | 3 | 4 | 5 |

        ```sh
        echo hello

        # Not a heading
        ```
        """
        let root = URL(fileURLWithPath: "/tmp")
        let result = NotesImportFormatting(source, relativeTo: root, allowedRoot: root, attachmentLimit: 100)
        XCTAssertEqual(result.title, "My report")
        XCTAssertFalse(result.markdown.contains("# My report"))
        XCTAssertTrue(result.markdown.contains("## Section"))
        XCTAssertTrue(result.markdown.contains("<!-- notescli-empty-paragraph:0:0 -->"))
        XCTAssertTrue(result.markdown.contains("echo hello\n\n# Not a heading"))
        let note = NotesMarkdownDocument(parsing: result.markdown)
        XCTAssertEqual(note.paragraphs.filter { $0.kind == .bulleted }.map(\.plainText), ["First", "Second"])
        XCTAssertEqual(note.paragraphs.compactMap(\.table).first?.first?.count, 5)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("wide table") }))
    }

    func testInlineImageKeepsListPositionAndDoesNotFollowExternalAssets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceFile = folder.appendingPathComponent("figure one.png")
        try Data([0x89, 0x50]).write(to: sourceFile)
        let source = """
        - Before
        - café ![Diagram](<figure one.png>) and context
        - After

        ![Remote](https://example.com/chart.png)

        ![Missing](../private.png)
        """
        let result = NotesImportFormatting(source, relativeTo: folder, allowedRoot: folder, attachmentLimit: 100)
        let note = NotesMarkdownDocument(parsing: result.markdown)
        XCTAssertEqual(result.assetFiles.map(\.lastPathComponent), ["figure one.png"])
        XCTAssertEqual(note.resources.count, 1)
        let list = note.paragraphs.filter { $0.kind == .bulleted }
        XCTAssertEqual(list.map(\.plainText), ["Before", "café Diagram and context", "After"])
        XCTAssertEqual(list[1].runs.filter { $0.resource != nil }.count, 1)
        XCTAssertTrue(result.markdown.contains("[Remote](<https://example.com/chart.png>)"))
        XCTAssertEqual(result.warnings.count, 2)
    }

    func testPlainTextDoesNotCreateMarkdownElements() {
        let root = URL(fileURLWithPath: "/tmp")
        let formatted = NotesImportFormatting("# Heading\n\n- literal *asterisks*", relativeTo: root, allowedRoot: root,
                                              attachmentLimit: 100, recognizedAsPlainText: true)
        let note = NotesMarkdownDocument(parsing: formatted.markdown)
        XCTAssertNil(formatted.title)
        XCTAssertFalse(note.paragraphs.contains { $0.kind == .bulleted || $0.kind == .title })
        XCTAssertTrue(note.paragraphs.map(\.plainText).contains("- literal *asterisks*"))
    }

    func testRemovingFirstHeadingPreservesEarlierReferenceDefinitions() {
        let root = URL(fileURLWithPath: "/tmp")
        let formatted = NotesImportFormatting("[ref]: https://example.com\n\n# Report\n\nRead [this][ref].",
                                              relativeTo: root, allowedRoot: root, attachmentLimit: 100)
        let note = NotesMarkdownDocument(parsing: formatted.markdown)
        XCTAssertEqual(formatted.title, "Report")
        XCTAssertTrue(note.paragraphs.flatMap(\.runs).contains { $0.link == "https://example.com" })
    }

    func testOpeningAnImportSourceDoesNotFollowSwappedSymlinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("actual.md")
        try "text".write(to: source, atomically: true, encoding: .utf8)
        let symlink = folder.appendingPathComponent("swapped.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        XCTAssertThrowsError(try InputFile.openRegularSource(symlink, kind: "attachment", maxBytes: 100))
        XCTAssertEqual(try InputFile.readImportText(source), "text")
    }
}
