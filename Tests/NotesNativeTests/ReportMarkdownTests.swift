import Foundation
import XCTest
import NotesCore
@testable import NotesNative

final class ReportMarkdownTests: XCTestCase {
    func testPreparesAllReportAssetsBeforeWriting() throws {
        var downloaded: [URL] = []
        var rendered: [String] = []
        let plan = try ReportMarkdownPreprocessor.prepare(
            title: "Research brief",
            markdown: """
            # Research brief

            Intro [^1] #research

            https://example.com/story

            ![Remote chart](https://images.example.com/chart.png)

            ```svg
            <svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10"/></svg>
            ```

            [^1]: [Primary source](https://example.com/source)
            """,
            tags: ["brief"],
            downloadImage: { url in
                downloaded.append(url)
                return URL(fileURLWithPath: "/tmp/remote.png")
            },
            renderDiagram: { language, source in
                rendered.append(language + ":" + source)
                return URL(fileURLWithPath: "/tmp/diagram.png")
            }
        )

        XCTAssertFalse(plan.markdown.hasPrefix("# Research brief"))
        XCTAssertTrue(plan.markdown.contains("file:///tmp/remote.png"))
        XCTAssertTrue(plan.markdown.contains("file:///tmp/diagram.png"))
        XCTAssertTrue(plan.markdown.contains("notescli-card:"))
        XCTAssertTrue(plan.markdown.contains("notescli-tag:research"))
        XCTAssertTrue(plan.markdown.contains("notescli-tag:brief"))
        XCTAssertTrue(plan.markdown.contains("<sup>[1]</sup>"))
        XCTAssertTrue(plan.markdown.contains("## Citations"))
        XCTAssertEqual(downloaded.map(\.absoluteString), ["https://images.example.com/chart.png"])
        XCTAssertEqual(rendered.count, 1)
        XCTAssertEqual(plan.requested.remoteImages, 1)
        XCTAssertEqual(plan.requested.diagrams, 1)
        XCTAssertEqual(plan.requested.richLinks, 1)
        XCTAssertEqual(plan.requested.tags, 2)
        XCTAssertEqual(plan.requested.citations, 1)
    }

    func testUnsupportedDiagramFailsDuringPreflight() {
        XCTAssertThrowsError(try ReportMarkdownPreprocessor.prepare(
            title: "Report", markdown: "```mermaid\nsequenceDiagram\nA->>B: Hi\n```", tags: [],
            downloadImage: { $0 }, renderDiagram: { _, _ in XCTFail("must not render"); return URL(fileURLWithPath: "/tmp/no") }
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "unsupported_report_diagram")
        }
    }

    func testNormalizesParagraphsCountsBlocksAndStagesLocalResources() throws {
        var staged: [String] = []
        let plan = try ReportMarkdownPreprocessor.prepare(
            title: "Research brief",
            markdown: """
            # Research brief

            ## Findings



            Summary.

            | **Metric** | [Source](https://example.com) |
            | :--- | ---: |
            | *A* | 1 |

            - [ ] Verify result

            ---

            ![Chart](chart.png)

            [Appendix](appendix.pdf)
            """,
            tags: [],
            downloadImage: { $0 },
            renderDiagram: { _, _ in URL(fileURLWithPath: "/tmp/unused.png") },
            stageLocalResource: { source in
                staged.append(source)
                return URL(fileURLWithPath: "/tmp/staged", isDirectory: true).appendingPathComponent(source)
            }
        )

        XCTAssertFalse(plan.markdown.contains("# Research brief"))
        XCTAssertNil(plan.markdown.range(of: "\n{3,}", options: .regularExpression))
        XCTAssertEqual(staged, ["chart.png", "appendix.pdf"])
        XCTAssertTrue(plan.markdown.contains("file:///tmp/staged/chart.png"), plan.markdown)
        XCTAssertTrue(plan.markdown.contains("file:///tmp/staged/appendix.pdf"), plan.markdown)
        XCTAssertEqual(plan.requested.headings, 1)
        XCTAssertEqual(plan.requested.tables, 1)
        XCTAssertEqual(plan.requested.links, 1)
        XCTAssertEqual(plan.requested.images, 1)
        XCTAssertEqual(plan.requested.checklists, 1)
        XCTAssertEqual(plan.requested.attachments, 1)
        XCTAssertEqual(plan.requested.dividers, 1)
    }

    func testDownloaderByteLimitsDoNotOverflow() {
        XCTAssertTrue(SafeReportDownloader.canAppend(currentCount: 0, incomingCount: 10, maximumBytes: 10))
        XCTAssertTrue(SafeReportDownloader.canAppend(currentCount: 9, incomingCount: 1, maximumBytes: 10))
        XCTAssertFalse(SafeReportDownloader.canAppend(currentCount: 0, incomingCount: 11, maximumBytes: 10))
        XCTAssertFalse(SafeReportDownloader.canAppend(currentCount: 6, incomingCount: 5, maximumBytes: 10))
        XCTAssertFalse(SafeReportDownloader.canAppend(currentCount: 1, incomingCount: .max, maximumBytes: 10))
        XCTAssertFalse(SafeReportDownloader.canAppend(currentCount: -1, incomingCount: 1, maximumBytes: 10))
        XCTAssertEqual(SafeReportDownloader.Kind.image.maximumBytes, 12 * 1024 * 1024)
        XCTAssertEqual(SafeReportDownloader.Kind.attachment(1).maximumBytes, 25 * 1024 * 1024)
    }

    func testDownloaderBlocksExecutableMIMETypes() {
        XCTAssertFalse(SafeReportDownloader.allowsAttachmentMIME("application/x-mach-binary"))
        XCTAssertFalse(SafeReportDownloader.allowsAttachmentMIME("Application/X-MsDownload"))
        XCTAssertFalse(SafeReportDownloader.allowsAttachmentMIME("application/javascript"))
        XCTAssertFalse(SafeReportDownloader.allowsAttachmentMIME("text/javascript"))
        XCTAssertTrue(SafeReportDownloader.allowsAttachmentMIME("application/pdf"))
    }
}
