import XCTest
@testable import NotesAutomation

final class MarkdownTests: XCTestCase {
    func testGoldenFormatting() {
        let input = """
        # Title
        ## Heading
        ### Subheading
        #### Also subheading

        **bold** *italic* <u>under</u> ++line++ ~~gone~~ & <script>
        [site](https://example.com/?a=1&b=2) `x < y`

        > quoted **text**

        ```swift
        let x = "<&>"
        ```
        """
        XCTAssertEqual(MarkdownToNotesHTML.convert(input).html,
            "<h1>Title</h1><h2>Heading</h2><h3>Subheading</h3><h3>Also subheading</h3>" +
            "<div><b>bold</b> <i>italic</i> <u>under</u> <u>line</u> <strike>gone</strike> &amp; &lt;script&gt;<br>" +
            "<a href=\"https://example.com/?a=1&amp;b=2\">site</a> <tt>x &lt; y</tt></div>" +
            "<blockquote><div>quoted <b>text</b></div></blockquote><pre>let x = &quot;&lt;&amp;&gt;&quot;</pre>")
    }
    func testGoldenNestedListsAndChecklists() {
        let result = MarkdownToNotesHTML.convert("- parent\n  3. third\n     - deep\n  4. fourth\n- [ ] todo\n- [x] done\n\n1. one\n2. two")
        XCTAssertEqual(result.html, "<ul><li>parent<ol start=\"3\"><li>third<ul><li>deep</li></ul></li><li>fourth</li></ol></li><li>☐ todo</li><li>☑ done</li></ul><ol><li>one</li><li>two</li></ol>")
        XCTAssertEqual(result.downgraded, ["checklist"])
    }
    func testImagesAreDataAndRemoteImagesDowngrade() {
        let result = MarkdownToNotesHTML.convert("![local](</tmp/a b.png>) ![remote](https://example.com/a.png) ![file](file:///tmp/a%20b.png)")
        XCTAssertEqual(result.localImagePaths, ["/tmp/a b.png", "/tmp/a b.png"])
        XCTAssertEqual(result.downgraded, ["image"])
        XCTAssertEqual(result.html, "<div>[image: local] [image: remote] [image: file]</div>")
    }
    func testEscapeAndUnsafeLinks() {
        XCTAssertEqual(MarkdownToNotesHTML.convert(#"[bad](javascript:alert(1)) <img src="x" onerror="bad"> \*literal\*"#).html,
                       "<div>bad &lt;img src=&quot;x&quot; onerror=&quot;bad&quot;&gt; *literal*</div>")
        XCTAssertEqual(MarkdownToNotesHTML.convert("a_b_c __bold__ ***both***").html,
                       "<div>a_b_c <b>bold</b> <b><i>both</i></b></div>")
    }
    func testEmptyAndUnicode() {
        XCTAssertEqual(MarkdownToNotesHTML.convert("").html, "")
        XCTAssertEqual(MarkdownToNotesHTML.convert("👩🏽‍💻 café\r\nnext").html, "<div>👩🏽‍💻 café<br>next</div>")
    }
    func testNestedEmphasis() {
        XCTAssertEqual(MarkdownToNotesHTML.convert("**bold *italic*** and *italic **bold***").html,
                       "<div><b>bold <i>italic</i></b> and <i>italic <b>bold</b></i></div>")
    }
    func testReadableWebClipExtraction() throws {
        let source = try XCTUnwrap(URL(string: "https://example.com/post"))
        let clip = WebPageClipper.extract("<html><head><title>Example</title><style>secret</style></head><body><nav>menu</nav><article><h2>Heading</h2><p>Hello <a href='https://example.com/x'>world</a>.</p><script>bad()</script></article></body></html>", source: source)
        XCTAssertEqual(clip.title, "Example")
        XCTAssertTrue(clip.markdown.contains("Source: https://example.com/post"))
        XCTAssertTrue(clip.markdown.contains("Heading"))
        XCTAssertTrue(clip.markdown.contains("[world](https://example.com/x)"))
        XCTAssertFalse(clip.markdown.contains("secret"))
        XCTAssertFalse(clip.markdown.contains("bad()"))
    }

}
