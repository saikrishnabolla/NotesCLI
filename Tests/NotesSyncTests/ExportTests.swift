import Foundation
import NotesCore
import XCTest
@testable import NotesSync

final class ExportTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-export-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMarkdownGoldenAndIncrementalManifest() throws {
        let root = try temporaryDirectory(), fake = InMemoryNotes.sample()
        let exporter = NotesExporter(reader: fake)
        let first = try exporter.run(ExportOptions(output: root, format: .markdown))
        XCTAssertEqual(first.exported, 2)
        let welcome = try XCTUnwrap(first.files.first { $0.contains("Welcome--welcome.md") })
        XCTAssertEqual(try String(contentsOfFile: welcome, encoding: .utf8), """
        ---
        id: "welcome"
        title: "Welcome"
        folder: ["Notes"]
        created: 2027-01-15T08:00:00Z
        modified: 2027-01-15T08:00:00Z
        tags: ["demo"]
        ---

        Welcome to notescli. Browse your shopping notes. #demo

        """)
        let second = try exporter.run(ExportOptions(output: root, format: .markdown))
        XCTAssertEqual(second.unchanged, 2)
        XCTAssertEqual(second.exported, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".notescli-export.json").path))
    }

    func testAllArchiveAndStructuredFormats() throws {
        for format in [NotesExportFormat.html, .json, .ndjson, .sqlite, .zip] {
            let root = try temporaryDirectory().appendingPathComponent(format.rawValue)
            let report = try NotesExporter(reader: InMemoryNotes.sample()).run(ExportOptions(output: root, format: format))
            XCTAssertEqual(report.exported, 2, format.rawValue)
            XCTAssertEqual(report.files.count, [.html, .json].contains(format) ? 2 : 1, format.rawValue)
            for path in report.files { XCTAssertGreaterThan((try Data(contentsOf: URL(fileURLWithPath: path))).count, 0) }
        }
    }

    func testExportCanonicalizesSymlinkedTemporaryRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/notescli-export-tests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.resolvingSymlinksInPath()) }
        let report = try NotesExporter(reader: InMemoryNotes.sample()).run(ExportOptions(output: root))
        XCTAssertEqual(report.exported, 2)
        XCTAssertTrue(report.files.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    func testObsidianDuplicateTitlesAndIncompleteNotes() throws {
        let root = try temporaryDirectory()
        let account = Account(id: "a", name: "A", kind: "local")
        let folder = Folder(id: "f", name: "F", accountID: "a", parentID: nil, path: ["F"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 2)
        func note(_ id: String, locked: Bool) -> Note {
            Note(summary: NoteSummary(id: NoteID(uuid: id), title: "Same", snippet: "", folderID: "f", folderPath: ["F"], accountID: "a", created: nil, modified: nil, isPinned: false, isLocked: locked, isDeleted: false, hasChecklist: false, attachmentCount: 0, tags: []), document: locked ? nil : NoteDocument(text: "body", runs: []), attachments: [])
        }
        let report = try NotesExporter(reader: InMemoryNotes(accounts: [account], folders: [folder], notes: [note("one", locked: false), note("two", locked: true)]))
            .run(ExportOptions(output: root, obsidian: true))
        XCTAssertEqual(Set(report.files.map { URL(fileURLWithPath: $0).lastPathComponent }).count, 2)
        XCTAssertEqual(report.incomplete.map(\.reason), ["locked"])
    }

    func testCopiesAndEmbedsAttachmentsAndAppliesTemplates() throws {
        let root = try temporaryDirectory(), source = root.appendingPathComponent("source.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        try png.write(to: source)
        let account = Account(id: "a", name: "A", kind: "local")
        let folder = Folder(id: "f", name: "F", accountID: "a", parentID: nil, path: ["F"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 1)
        let summary = NoteSummary(id: NoteID(uuid: "id"), title: "Picture", snippet: "", folderID: "f", folderPath: ["F"], accountID: "a", created: nil, modified: nil, isPinned: false, isLocked: false, isDeleted: false, hasChecklist: false, attachmentCount: 1, tags: [])
        let note = Note(summary: summary, document: NoteDocument(text: "body", runs: []), attachments: [Attachment(id: "asset", typeUTI: "public.png", filename: "pixel.png", filePath: source.path)])
        let fake = InMemoryNotes(accounts: [account], folders: [folder], notes: [note])
        let markdownRoot = root.appendingPathComponent("markdown")
        let markdown = try NotesExporter(reader: fake).run(ExportOptions(output: markdownRoot, template: "# {{title}}\n{{body}}", filenameTemplate: "{{id}}"))
        let text = try String(contentsOfFile: try XCTUnwrap(markdown.files.first))
        XCTAssertTrue(text.contains("# Picture\nbody")); XCTAssertTrue(text.contains("pixel.png"))
        XCTAssertEqual(try Data(contentsOf: markdownRoot.appendingPathComponent("F/id-attachments/asset-pixel.png")), png)
        let html = try NotesExporter(reader: fake).run(ExportOptions(output: root.appendingPathComponent("html"), format: .html, embedMedia: true))
        XCTAssertTrue(try String(contentsOfFile: try XCTUnwrap(html.files.first)).contains("data:image/png;base64,"))
    }

    func testPruneRemovesOnlyManagedDeletedNoteFiles() throws {
        let root = try temporaryDirectory(), fake = InMemoryNotes.sample(), exporter = NotesExporter(reader: fake)
        let first = try exporter.run(ExportOptions(output: root))
        let welcome = try XCTUnwrap(first.files.first { $0.contains("Welcome--welcome") })
        let unmanaged = root.appendingPathComponent("keep.txt"); try "keep".write(to: unmanaged, atomically: true, encoding: .utf8)
        _ = try fake.deleteNote("welcome")
        let second = try exporter.run(ExportOptions(output: root, prune: true))
        XCTAssertEqual(second.pruned, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: welcome))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanaged.path))
    }
}
