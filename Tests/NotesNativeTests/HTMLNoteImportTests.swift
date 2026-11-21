import XCTest
import NotesCore
import NotesNative

final class HTMLNoteImportTests: XCTestCase {
    func testImportsReportWithoutPageChrome() throws {
        let result = try HTMLNoteImport.convert("""
        <!doctype html><html><head><title>Quarterly &amp; Annual</title>
        <base href="https://example.org/"><style>nav { color: red }</style></head><body>
        <header><h1>Quarterly review</h1><nav>Menu</nav></header>
        <main><p>Results for <strong>all</strong> <em>teams</em>.<p>Read
        <a href="#details">details</a> or <a href="https://example.org/?a=1&amp;b=2">the source</a>.
        <h2 id="details">Details</h2>
        <ol start="3"><li>First<ul><li>Nested</li></ul></li><li>Second</li></ol>
        <footer>Page footer</footer></main></body></html>
        """)
        XCTAssertEqual(result.title, "Quarterly & Annual")
        XCTAssertEqual(result.markdown, """
        # Quarterly review

        Results for **all** *teams*.

        Read [details](#details) or [the source](https://example.org/?a=1&amp;b=2).

        ## Details

        3. First
           - Nested
        4. Second
        """)
        XCTAssertEqual(result.warnings, [])
    }

    func testImportsNativeTableAndPreservesInlineImageReferences() throws {
        let result = try HTMLNoteImport.convert("""
        <h1>☃ Assets</h1>
        <table><caption>Inventory</caption><thead><tr><th>Kind</th><th>Asset</th></tr></thead>
        <tbody><tr><td><strong>A | B</strong></td><td><img src="./figures/chart (1).png" alt="Chart"></td></tr>
        <tr><td><code>a|b</code></td><td><img src="https://example.org/icon.png" alt="Icon"></td></tr></tbody></table>
        """)
        XCTAssertEqual(result.title, "☃ Assets")
        let document = NotesMarkdownDocument(parsing: result.markdown)
        XCTAssertEqual(document.paragraphs.map(\.kind), [.title, .body, .table])
        XCTAssertEqual(document.paragraphs[1].plainText, "Inventory")
        let table = try XCTUnwrap(document.paragraphs.last?.table)
        XCTAssertEqual(table.map { $0.map(\.plainText) }, [["Kind", "Asset"], ["A | B", "Chart"], ["a|b", "Icon"]])
        XCTAssertEqual(table[1][0].runs.first?.bold, true)
        XCTAssertEqual(table[2][0].runs.first?.code, true)
        XCTAssertEqual(document.resources.map(\.source), ["./figures/chart%20%281%29.png", "https://example.org/icon.png"])
        XCTAssertEqual(document.localResources.map(\.alt), ["Chart"])
        XCTAssertEqual(result.warnings, ["Image references were preserved but not checked or loaded."])
    }

    func testSkipsRuntimeWidgetsAndReportsUnresolvedAssets() throws {
        let result = try HTMLNoteImport.convert("""
        <!DOCTYPE html SYSTEM "https://example.invalid/unused.dtd">
        <style>.hidden { display: none }</style>
        <div class="toolbar">Tools</div><p hidden>Hidden</p><p>Visible</p>
        <script>document.write("Runtime text")</script><iframe src="https://example.invalid/"></iframe>
        <canvas>Runtime chart</canvas><img data-src="lazy.png" alt="Lazy chart">
        <img src="file:///private/chart.png" alt="Local file">
        """)
        XCTAssertEqual(result.markdown, "Visible\n\nLazy chart Local file")
        XCTAssertEqual(result.warnings, [
            "Skipped unsupported HTML content: <script>.",
            "Skipped unsupported HTML content: <iframe>.",
            "Skipped unsupported HTML content: <canvas>.",
            "Skipped an image with no static src.",
            "Skipped an image with an unsafe or unsupported src."
        ])
    }

    func testUnsafeDestinationsBecomePlainLabels() throws {
        let result = try HTMLNoteImport.convert("""
        <p><a href="j&#97;vascript:alert(1)">One</a> <a href="java&#x09;script:alert(1)">Two</a>
        <a href="data:text/html,unsafe">Three</a> <a href="notescli-attachment:abc">Four</a>
        <a href="javascript%3Aalert(1)">Five</a> <a href="//example.invalid/">Six</a>
        <img src="assets/%2e%2e/%2e%2e/file.png" alt="Seven"> <img src="~/file.png" alt="Eight">
        <img src="%2Fprivate/file.png" alt="Nine"> <img src="assets/%3F/../../file.png" alt="Ten">
        <a href="https://example.org/reference">Safe</a></p>
        """)
        XCTAssertEqual(result.markdown, "One Two Three Four Five Six Seven Eight Nine Ten [Safe](https://example.org/reference)")
        XCTAssertEqual(result.warnings, [
            "Skipped a link with an unsafe or unsupported URL.",
            "Skipped an image with an unsafe or unsupported src."
        ])
    }

    func testKeepsLiteralMarkupAndCodeInert() throws {
        let result = try HTMLNoteImport.convert("""
        <p>1. Not a list: &lt;script&gt; \(String(repeating: "*", count: 2))bold** &amp;lt;</p>
        <p>Use <code>a`b</code>.</p>
        <pre><code class="language-swift">  let x = "&lt;img&gt;"
        ```
        </code></pre>
        """)
        let document = NotesMarkdownDocument(parsing: result.markdown)
        XCTAssertEqual(document.paragraphs.map(\.kind), [.body, .body, .monospaced, .monospaced])
        XCTAssertEqual(document.paragraphs[0].plainText, "1. Not a list: <script> **bold** &lt;")
        XCTAssertEqual(document.paragraphs[1].runs.first(where: \.code)?.text, "a`b")
        XCTAssertEqual(document.paragraphs.suffix(2).map(\.plainText), ["  let x = \"<img>\"", "```"])
        XCTAssertEqual(document.paragraphs[2].language, "swift")
        XCTAssertEqual(document.resources, [])
    }

    func testRejectsNULRatherThanImportingPartialHTML() {
        XCTAssertThrowsError(try HTMLNoteImport.convert("<p>Before\u{0}after</p>"))
    }
}
