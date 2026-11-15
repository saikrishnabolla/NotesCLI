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

    func testPreprocessingTransformsOnlyProseAndExplicitDiagramFences() throws {
        var downloaded: [URL] = []
        var rendered: [String] = []
        var staged: [String] = []
        let plan = try ReportMarkdownPreprocessor.prepare(
            title: "Code-aware report",
            markdown: """
            ## Summary #heading-anchor

            #research

            https://example.com/story

            ![Remote](https://images.example.com/chart.png)

            Inline `#inline https://example.com/inline ![Code](https://images.example.com/inline.png)` sample.

            URL fragment https://example.com/#fragment and issue #1 stay text.

            Query fragment https://example.com/story?topic=#query-tag stays text.

            ```html
            <a href="https://example.com/code">#code</a>
            ![Code](https://images.example.com/fenced.png)
            ![Local code](fenced.png)
            ```

            ```html diagram
            <html><body><div>Flow</div></body></html>
            ```
            """,
            tags: [],
            downloadImage: { url in
                downloaded.append(url)
                return URL(fileURLWithPath: "/tmp/remote.png")
            },
            renderDiagram: { language, source in
                rendered.append(language + ":" + source)
                return URL(fileURLWithPath: "/tmp/diagram.png")
            },
            stageLocalResource: { source in
                staged.append(source)
                if let url = URL(string: source), url.isFileURL { return url }
                return URL(fileURLWithPath: source)
            }
        )

        XCTAssertEqual(downloaded.map(\.absoluteString), ["https://images.example.com/chart.png"])
        XCTAssertEqual(rendered.count, 1)
        XCTAssertFalse(staged.contains("fenced.png"))
        XCTAssertTrue(rendered[0].hasPrefix("html:"))
        XCTAssertTrue(plan.markdown.contains("```html\n<a href=\"https://example.com/code\">#code</a>"))
        XCTAssertTrue(plan.markdown.contains("`#inline https://example.com/inline ![Code](https://images.example.com/inline.png)`"))
        XCTAssertTrue(plan.markdown.contains("https://example.com/#fragment"))
        XCTAssertTrue(plan.markdown.contains("https://example.com/story?topic=#query-tag"))
        XCTAssertTrue(plan.markdown.contains("#1 stay text"))
        XCTAssertFalse(plan.markdown.contains("notescli-tag:heading-anchor"))
        XCTAssertFalse(plan.markdown.contains("notescli-tag:inline"))
        XCTAssertFalse(plan.markdown.contains("notescli-tag:code"))
        XCTAssertFalse(plan.markdown.contains("notescli-tag:fragment"))
        XCTAssertFalse(plan.markdown.contains("notescli-tag:query-tag"))
        XCTAssertFalse(plan.markdown.contains("notescli-tag:1"))
        XCTAssertEqual(plan.requested.tags, 1)
        XCTAssertEqual(plan.requested.richLinks, 1)
        XCTAssertEqual(plan.requested.remoteImages, 1)
        XCTAssertEqual(plan.requested.diagrams, 1)
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

    func testAddsOneNativeEmptyParagraphAtReportBlockBoundaries() throws {
        let plan = try ReportMarkdownPreprocessor.prepare(
            title: "Research brief",
            markdown: """
            # Research brief

            ## Summary

            Intro paragraph.

            ## Evidence

            Evidence paragraph.

            | Source | Finding |
            | --- | --- |
            | A | B |

            - [ ] Review evidence

              ![Chart](chart.png)

            ### Next section

            Closing paragraph.
            """,
            tags: [],
            downloadImage: { $0 },
            renderDiagram: { _, _ in URL(fileURLWithPath: "/tmp/unused.png") },
            stageLocalResource: { _ in URL(fileURLWithPath: "/tmp/chart.png") }
        )

        let paragraphs = NotesMarkdownDocument(parsing: plan.markdown).paragraphs
        XCTAssertEqual(paragraphs.map(\.kind), [
            .heading, .body,
            .body, .heading, .body,
            .body, .table,
            .body, .checklist, .body,
            .body, .subheading, .body,
        ])
        XCTAssertEqual(paragraphs.map(\.plainText), [
            "Summary", "Intro paragraph.",
            "", "Evidence", "Evidence paragraph.",
            "", "Source\tFinding\nA\tB",
            "", "Review evidence", "Chart",
            "", "Next section", "Closing paragraph.",
        ])
        XCTAssertEqual(paragraphs.first { $0.plainText == "Chart" }?.indent, 1)
        XCTAssertFalse(zip(paragraphs, paragraphs.dropFirst()).contains {
            $0.plainText.isEmpty && $1.plainText.isEmpty
        })
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

    func testDownloaderRejectsCGNATAndEmbeddedIPv4Addresses() {
        let blocked = [
            "https://100.64.0.1/image.png",
            "https://100.127.255.255/image.png",
            "https://[::ffff:127.0.0.1]/image.png",
            "https://[::ffff:10.0.0.1]/image.png",
            "https://[::127.0.0.1]/image.png",
        ]
        for value in blocked {
            XCTAssertThrowsError(try SafeReportDownloader.validate(URL(string: value)!)) { error in
                XCTAssertEqual((error as? NotesError)?.code, "unsafe_remote_url", value)
            }
        }
    }

    func testDownloaderRequiresTheConnectedPeerToMatchValidatedDNS() throws {
        let allowed: Set<String> = ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"]
        XCTAssertNoThrow(try SafeReportDownloader.requirePeerAddress("93.184.216.34", allowed: allowed))
        XCTAssertNoThrow(try SafeReportDownloader.requirePeerAddress(
            "[2606:2800:220:1:248:1893:25c8:1946]", allowed: allowed
        ))
        for peer in ["93.184.216.35", "127.0.0.1", "[::ffff:93.184.216.34]"] {
            XCTAssertThrowsError(try SafeReportDownloader.requirePeerAddress(peer, allowed: allowed)) { error in
                XCTAssertEqual((error as? NotesError)?.code, "unsafe_remote_url", peer)
            }
        }
    }

    func testReplacementResolutionUsesOnlyTheDefaultTargetFolder() throws {
        let primary = Account(id: "account-a", name: "Primary", kind: "icloud", isDefault: true,
                              defaultFolderID: "default-folder", defaultFolderName: "Notes")
        let secondary = Account(id: "account-b", name: "Secondary", kind: "icloud")
        let folders = [
            Folder(id: "default-folder", name: "Notes", accountID: primary.id, parentID: nil,
                   path: ["Notes"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 1),
            Folder(id: "archive-folder", name: "Archive", accountID: primary.id, parentID: nil,
                   path: ["Archive"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 1),
            Folder(id: "secondary-folder", name: "Notes", accountID: secondary.id, parentID: nil,
                   path: ["Notes"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 1),
        ]
        func note(_ id: String, folder: Folder) -> Note {
            Note(summary: NoteSummary(
                id: NoteID(uuid: id), title: "Repeated report", snippet: "body",
                folderID: folder.id, folderPath: folder.path, accountID: folder.accountID,
                created: nil, modified: nil, isPinned: false, isLocked: false, isDeleted: false,
                hasChecklist: false, attachmentCount: 0, tags: []
            ), document: NoteDocument(text: "body", runs: []), attachments: [])
        }
        let reader = InMemoryNotes(
            accounts: [primary, secondary], folders: folders,
            notes: [note("default-note", folder: folders[0]), note("archive-note", folder: folders[1]),
                    note("secondary-note", folder: folders[2])]
        )

        let target = try NotesReportWriter.resolveTarget(
            title: "  Repeated report  ", folder: nil, replacing: true, reader: reader
        )

        XCTAssertEqual(target.folder.id, "default-folder")
        XCTAssertEqual(target.existing.map(\.summary.id.uuid), ["default-note"])
    }

    func testReplacementRequiresOneExistingReportInTheTargetFolder() throws {
        let account = Account(id: "account", name: "Primary", kind: "icloud", isDefault: true,
                              defaultFolderID: "default-folder", defaultFolderName: "Notes")
        let folder = Folder(id: "default-folder", name: "Notes", accountID: account.id, parentID: nil,
                            path: ["Notes"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 0)
        let reader = InMemoryNotes(accounts: [account], folders: [folder], notes: [])

        XCTAssertThrowsError(try NotesReportWriter.resolveTarget(
            title: "Missing report", folder: nil, replacing: true, reader: reader
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "report_not_found")
        }
    }

    func testUnknownReplacementDeleteKeepsNewReportAndReportsAmbiguity() {
        XCTAssertEqual(ReportReplacementDecision(deleteOutcome: .verified), .complete)
        XCTAssertEqual(ReportReplacementDecision(deleteOutcome: .unverified), .rollbackNewReport)
        XCTAssertEqual(ReportReplacementDecision(deleteOutcome: .unknown), .ambiguousKeepNewReport)
    }
}
