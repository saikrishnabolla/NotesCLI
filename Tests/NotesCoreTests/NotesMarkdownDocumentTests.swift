import XCTest
@testable import NotesCore

final class NotesMarkdownDocumentTests: XCTestCase {
    func testCommonMarkParagraphsAndBreaks() {
        let document = NotesMarkdownDocument(parsing: "one\ntwo\n\nthree\\\nfour\n\n\nfive\n")

        XCTAssertEqual(document.paragraphs.map(\.plainText), ["one two", "three\nfour", "five"])
        XCTAssertEqual(document.html, "<p>one two</p>\n<p>three<br>four</p>\n<p>five</p>")
    }

    func testGFMStructureAndImageOrderInsideList() {
        let document = NotesMarkdownDocument(parsing: """
        ## Plan

        - Before

          ![Chart](chart.png)

        - [x] After

        | Name | Value |
        | --- | --- |
        | A\\|B | C |
        """)

        XCTAssertEqual(document.localResources.map(\.source), ["chart.png"])
        XCTAssertEqual(document.paragraphs.map(\.kind), [.heading, .bulleted, .body, .checklist, .table])
        XCTAssertEqual(document.paragraphs[2].runs.compactMap(\.resource?.source), ["chart.png"])
        XCTAssertEqual(document.paragraphs[2].indent, 1)
        XCTAssertEqual(document.paragraphs[3].checked, true)
        XCTAssertEqual(document.paragraphs[4].table?.map { $0.map(\.plainText) }, [["Name", "Value"], ["A|B", "C"]])
    }

    func testInlineFormattingLinksAndNotesExtensions() {
        let document = NotesMarkdownDocument(parsing: """
        ***both*** ~~gone~~ <u>under</u> <sup>up</sup> <sub>down</sub> <mark data-apple-notes-highlight="mint">mark</mark> <u><sup>nested</sup></u> [site](https://example.com) [drawing](notescli-attachment:drawing-1)
        """)

        let runs = document.paragraphs[0].runs
        XCTAssertTrue(runs.contains { $0.text == "both" && $0.bold && $0.italic })
        XCTAssertTrue(runs.contains { $0.text == "gone" && $0.strikethrough })
        XCTAssertTrue(runs.contains { $0.text == "under" && $0.underline })
        XCTAssertTrue(runs.contains { $0.text == "up" && $0.superscript == 1 })
        XCTAssertTrue(runs.contains { $0.text == "down" && $0.superscript == -1 })
        XCTAssertTrue(runs.contains { $0.text == "mark" && $0.highlight == "mint" })
        XCTAssertTrue(runs.contains { $0.text == "nested" && $0.underline && $0.superscript == 1 })
        XCTAssertTrue(runs.contains { $0.text == "site" && $0.link == "https://example.com" })
        XCTAssertTrue(runs.contains { $0.attachmentID == "drawing-1" })
    }

    func testUnsafeLinkSchemesRemainPlainText() {
        let document = NotesMarkdownDocument(parsing: "[safe](https://example.com) [bad](javascript:alert(1)) [also bad](data:text/plain,no)")

        XCTAssertEqual(document.paragraphs[0].runs.compactMap(\.link), ["https://example.com"])
        XCTAssertEqual(document.paragraphs[0].plainText, "safe bad also bad")
        XCTAssertFalse(document.html.contains("javascript:"))
        XCTAssertFalse(document.html.contains("data:text"))
    }

    func testUnsafeHTMLIsLiteralButSupportedNotesTagsRender() {
        let document = NotesMarkdownDocument(parsing: #"""
        <script>alert('x')</script>

        Text <u>safe</u>
        """#)

        XCTAssertEqual(document.html, "<p>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;</p>\n<p>Text <u>safe</u></p>")
    }

    func testInvalidInlineHTMLRemainsLiteralAndEscaped() {
        let cases = [
            (#"<kbd>unknown</kbd>"#, #"<p>&lt;kbd&gt;unknown&lt;/kbd&gt;</p>"#),
            (#"<u class="wide">malformed</u>"#, #"<p>&lt;u class=&quot;wide&quot;&gt;malformed&lt;/u&gt;</p>"#),
            (#"<mark data-apple-notes-highlight="yellow">malformed</mark>"#, #"<p>&lt;mark data-apple-notes-highlight=&quot;yellow&quot;&gt;malformed&lt;/mark&gt;</p>"#),
            (#"<u>mismatched</sup>"#, #"<p>&lt;u&gt;mismatched&lt;/sup&gt;</p>"#),
            (#"<u><sup>crossed</u></sup>"#, #"<p>&lt;u&gt;&lt;sup&gt;crossed&lt;/u&gt;&lt;/sup&gt;</p>"#),
            (#"<u>unclosed"#, #"<p>&lt;u&gt;unclosed</p>"#),
            (#"<sup>unclosed"#, #"<p>&lt;sup&gt;unclosed</p>"#),
            (#"<sub>unclosed"#, #"<p>&lt;sub&gt;unclosed</p>"#),
            (#"<mark data-apple-notes-highlight="mint">unclosed"#, #"<p>&lt;mark data-apple-notes-highlight=&quot;mint&quot;&gt;unclosed</p>"#),
        ]

        for (input, expected) in cases {
            let document = NotesMarkdownDocument(parsing: input)
            XCTAssertEqual(document.html, expected, input)
            XCTAssertTrue(document.paragraphs[0].runs.allSatisfy(\.plainFormatting), input)
        }
    }

    func testLocalFileLinksBecomeOrderedResources() {
        let document = NotesMarkdownDocument(parsing: #"Before [PDF](assets/report.pdf "Quarterly") then [Archive](file:///tmp/archive.zip "Source") and [site](https://example.com) or [cdn](//example.com/file.pdf)."#)

        XCTAssertEqual(document.paragraphs[0].runs.compactMap(\.resource), [
            NotesMarkdownResource(source: "assets/report.pdf", alt: "PDF", title: "Quarterly",
                                  presentation: .file),
            NotesMarkdownResource(source: "file:///tmp/archive.zip", alt: "Archive", title: "Source",
                                  presentation: .file),
        ])
        XCTAssertEqual(document.paragraphs[0].runs.map { $0.resource?.source ?? $0.text },
                       ["Before ", "assets/report.pdf", " then ", "file:///tmp/archive.zip", " and ", "site", " or ", "cdn", "."])
        XCTAssertEqual(document.paragraphs[0].runs.compactMap(\.link),
                       ["https://example.com", "//example.com/file.pdf"])
        XCTAssertEqual(document.resources.map(\.source), ["assets/report.pdf", "file:///tmp/archive.zip"])
    }

    func testThematicBreakAndCodeFenceBecomeNativeParagraphs() {
        let document = NotesMarkdownDocument(parsing: """
        Before

        ---

        ```swift
        let value = 1
        print(value)
        ```
        """)

        XCTAssertEqual(document.paragraphs.map(\.kind), [.body, .divider, .monospaced, .monospaced])
        XCTAssertEqual(document.paragraphs.suffix(2).map(\.plainText), ["let value = 1", "print(value)"])
    }

    func testEmptyParagraphMarkerInsideTableCellDoesNotBecomeLiteralText() throws {
        let document = NotesMarkdownDocument(parsing: """
        | Value |
        | --- |
        | before<br><!-- notescli-empty-paragraph:0:0 --><br>after |
        """)

        let table = try XCTUnwrap(document.paragraphs.first?.table)
        XCTAssertEqual(table[1][0].plainText, "before\n\nafter")
        XCTAssertFalse(table[1][0].plainText.contains("notescli-empty-paragraph"))
    }

    func testNativeWriterRequirementIncludesResourcesAndAppleFormatting() {
        XCTAssertFalse(NotesMarkdownDocument(parsing: "Plain **bold** [link](https://example.com)").requiresNativeWriter)
        for markdown in [
            "![local](image.png)",
            "![remote](https://example.com/image.png)",
            "- [ ] task",
            "---",
            "| A |\n| --- |\n| B |",
            "<mark data-apple-notes-highlight=\"mint\">mark</mark>",
            "<u>underline</u>",
            "<sup>up</sup>",
        ] {
            XCTAssertTrue(NotesMarkdownDocument(parsing: markdown).requiresNativeWriter, markdown)
        }
    }
}

private extension NotesMarkdownRun {
    var plainFormatting: Bool {
        !bold && !italic && !strikethrough && !underline && !code && superscript == 0 && highlight == nil
    }
}
