import XCTest
@testable import NotesAutomation

final class MarkdownTests: XCTestCase {
    func testGoldenFormatting() {
        let input = """
        # Title
        ## Heading
        ### Subheading
        #### Also subheading

        **bold** *italic* <u>under</u> <u>line</u> ~~gone~~ & <script>
        [site](https://example.com/?a=1&b=2) `x < y`

        > quoted **text**

        ```swift
        let x = "<&>"
        ```
        """
        XCTAssertEqual(MarkdownToNotesHTML.convert(input).html, """
        <h1>Title</h1>
        <h2>Heading</h2>
        <h3>Subheading</h3>
        <h3>Also subheading</h3>
        <p><strong>bold</strong> <em>italic</em> <u>under</u> <u>line</u> <del>gone</del> &amp; &lt;script&gt; <a href="https://example.com/?a=1&amp;b=2">site</a> <code>x &lt; y</code></p>
        <blockquote><p>quoted <strong>text</strong></p></blockquote>
        <pre><code class="language-swift">let x = &quot;&lt;&amp;&gt;&quot;</code></pre>
        """)
    }
    func testGoldenNestedListsAndChecklists() {
        let result = MarkdownToNotesHTML.convert("- parent\n\n    3. third\n       - deep\n    4. fourth\n- [ ] todo\n- [x] done\n\n1. one\n2. two")
        XCTAssertEqual(result.html, "<ul><li>parent<ol start=\"3\"><li>third<ul><li>deep</li></ul></li><li>fourth</li></ol></li><li><input type=\"checkbox\" disabled> todo</li><li><input type=\"checkbox\" disabled checked> done</li></ul>\n<ol><li>one</li><li>two</li></ol>")
        XCTAssertEqual(result.downgraded, ["checklist"])
    }
    func testImagesAreDataAndRemoteImagesDowngrade() {
        let result = MarkdownToNotesHTML.convert("![local](</tmp/a b.png>) ![remote](https://example.com/a.png) ![file](file:///tmp/a%20b.png)")
        XCTAssertEqual(result.localImagePaths, ["/tmp/a b.png", "/tmp/a b.png"])
        XCTAssertEqual(result.downgraded, ["image"])
        XCTAssertEqual(result.html, "<p>[image: local] [image: remote] [image: file]</p>")
    }
    func testEscapeAndUnsafeLinks() {
        XCTAssertEqual(MarkdownToNotesHTML.convert(#"[bad](javascript:alert(1)) <img src="x" onerror="bad"> \*literal\*"#).html,
                       "<p>bad &lt;img src=&quot;x&quot; onerror=&quot;bad&quot;&gt; *literal*</p>")
        XCTAssertEqual(MarkdownToNotesHTML.convert("a_b_c __bold__ ***both***").html,
                       "<p>a_b_c <strong>bold</strong> <em><strong>both</strong></em></p>")
    }
    func testEmptyAndUnicode() {
        XCTAssertEqual(MarkdownToNotesHTML.convert("").html, "")
        XCTAssertEqual(MarkdownToNotesHTML.convert("👩🏽‍💻 café\r\nnext").html, "<p>👩🏽‍💻 café next</p>")
    }
    func testNestedEmphasis() {
        XCTAssertEqual(MarkdownToNotesHTML.convert("**bold *italic*** and *italic **bold***").html,
                       "<p><strong>bold </strong><em><strong>italic</strong></em> and <em>italic </em><em><strong>bold</strong></em></p>")
    }
    func testInvalidInlineHTMLRemainsLiteralAndEscaped() {
        let input = #"<kbd>unknown</kbd> | <u class="wide">malformed</u> | <u>mismatched</sup> | <mark data-apple-notes-highlight="mint">unclosed"#

        XCTAssertEqual(MarkdownToNotesHTML.convert(input).html,
                       #"<p>&lt;kbd&gt;unknown&lt;/kbd&gt; | &lt;u class=&quot;wide&quot;&gt;malformed&lt;/u&gt; | &lt;u&gt;mismatched&lt;/sup&gt; | &lt;mark data-apple-notes-highlight=&quot;mint&quot;&gt;unclosed</p>"#)
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
