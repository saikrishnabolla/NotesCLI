import AppKit
import Foundation
import NotesCore
import PDFKit
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

    func testPDFDOCXRTFAndCombinedPDFAreValid() throws {
        for format in [NotesExportFormat.pdf, .docx, .rtf] {
            let root = try temporaryDirectory().appendingPathComponent(format.rawValue)
            let report = try NotesExporter(reader: InMemoryNotes.sample()).run(ExportOptions(output: root, format: format))
            XCTAssertEqual(report.exported, 2)
            XCTAssertEqual(report.files.count, 2)
            for path in report.files {
                let url = URL(fileURLWithPath: path), data = try Data(contentsOf: url)
                if format == .pdf { XCTAssertGreaterThan(PDFDocument(url: url)?.pageCount ?? 0, 0) }
                if format == .docx { XCTAssertTrue(try zipListing(url).contains("word/document.xml")) }
                if format == .rtf { XCTAssertTrue(String(decoding: data.prefix(16), as: UTF8.self).contains("{\\rtf")) }
            }
        }
        let root = try temporaryDirectory().appendingPathComponent("combined")
        let report = try NotesExporter(reader: InMemoryNotes.sample()).run(ExportOptions(output: root, format: .pdf, combine: true))
        XCTAssertEqual(report.files.count, 1)
        XCTAssertGreaterThanOrEqual(PDFDocument(url: URL(fileURLWithPath: report.files[0]))?.pageCount ?? 0, 2)
    }

    func testPDFEmbedsInlineImageAndOfficeFormatsRemainValid() throws {
        let root = try temporaryDirectory(), source = root.appendingPathComponent("pixel.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        try png.write(to: source)
        let account = Account(id: "a", name: "A", kind: "local")
        let folder = Folder(id: "f", name: "F", accountID: "a", parentID: nil, path: ["F"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 1)
        let summary = NoteSummary(id: NoteID(uuid: "image"), title: "Image", snippet: "", folderID: "f", folderPath: ["F"], accountID: "a",
                                  created: nil, modified: nil, isPinned: false, isLocked: false, isDeleted: false,
                                  hasChecklist: false, attachmentCount: 1, tags: [])
        let ref = InlineRef(id: "asset", typeUTI: "public.png")
        let note = Note(summary: summary, document: NoteDocument(text: "\u{fffc}", runs: [AttributeRun(length: 1, attachment: ref)]),
                        attachments: [Attachment(id: "asset", typeUTI: "public.png", filename: "pixel.png", filePath: source.path)])
        let fake = InMemoryNotes(accounts: [account], folders: [folder], notes: [note])
        let pdf = try NotesExporter(reader: fake).run(ExportOptions(output: root.appendingPathComponent("pdf"), format: .pdf))
        XCTAssertTrue(String(data: try Data(contentsOf: URL(fileURLWithPath: pdf.files[0])), encoding: .isoLatin1)?.contains("/Image") == true)
        let docx = try NotesExporter(reader: fake).run(ExportOptions(output: root.appendingPathComponent("docx"), format: .docx))
        XCTAssertTrue(try zipListing(URL(fileURLWithPath: docx.files[0])).contains("word/document.xml"))
        let rtf = try NotesExporter(reader: fake).run(ExportOptions(output: root.appendingPathComponent("rtf"), format: .rtf))
        XCTAssertTrue(try String(contentsOfFile: rtf.files[0]).hasPrefix("{\\rtf"))
    }

    func testEPUB3StructureAndXML() throws {
        let root = try temporaryDirectory()
        let report = try NotesExporter(reader: InMemoryNotes.sample()).run(ExportOptions(output: root, format: .epub))
        let epub = URL(fileURLWithPath: try XCTUnwrap(report.files.first))
        let listing = try zipListing(epub)
        XCTAssertEqual(listing.first, "mimetype")
        XCTAssertTrue(listing.contains("META-INF/container.xml"))
        XCTAssertTrue(listing.contains("EPUB/package.opf"))
        XCTAssertTrue(listing.contains("EPUB/nav.xhtml"))
        XCTAssertEqual(listing.filter { $0.hasPrefix("EPUB/text/chapter-") }.count, 2)
        for path in ["META-INF/container.xml", "EPUB/package.opf", "EPUB/nav.xhtml"] + listing.filter({ $0.hasPrefix("EPUB/text/") }) {
            let data = try unzip(epub, path: path)
            let parser = XMLParser(data: data)
            XCTAssertTrue(parser.parse(), "\(path): \(String(describing: parser.parserError))")
        }
        XCTAssertEqual(String(decoding: try unzip(epub, path: "mimetype"), as: UTF8.self), "application/epub+zip")
    }

    func testBearJoplinAndQuiverImportStructures() throws {
        let bearRoot = try temporaryDirectory()
        let bear = try NotesExporter(reader: InMemoryNotes.sample()).run(ExportOptions(output: bearRoot, format: .bear))
        XCTAssertEqual(bear.files.count, 2)
        for path in bear.files {
            let bundle = URL(fileURLWithPath: path)
            XCTAssertEqual(bundle.pathExtension, "textbundle")
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("text.md").path))
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("info.json"))) as? [String: Any])
        }

        let joplinRoot = try temporaryDirectory(), attachment = joplinRoot.appendingPathComponent("source.txt")
        try Data("attachment".utf8).write(to: attachment)
        let account = Account(id: "a", name: "A", kind: "local")
        let folder = Folder(id: "f", name: "F", accountID: "a", parentID: nil, path: ["F"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 1)
        let summary = NoteSummary(id: NoteID(uuid: "joplin-note"), title: "Joplin", snippet: "", folderID: "f", folderPath: ["F"], accountID: "a",
                                  created: nil, modified: nil, isPinned: false, isLocked: false, isDeleted: false,
                                  hasChecklist: false, attachmentCount: 1, tags: [])
        let note = Note(summary: summary, document: NoteDocument(text: "body", runs: []),
                        attachments: [Attachment(id: "resource", typeUTI: "public.plain-text", filename: "source.txt", filePath: attachment.path)])
        let joplinFake = InMemoryNotes(accounts: [account], folders: [folder], notes: [note])
        let joplin = try NotesExporter(reader: joplinFake).run(ExportOptions(output: joplinRoot, format: .joplin))
        let joplinText = try joplin.files.filter { $0.hasSuffix(".md") }.map { try String(contentsOfFile: $0) }.joined(separator: "\n")
        XCTAssertTrue(joplinText.contains("type_: 1")); XCTAssertTrue(joplinText.contains("type_: 2")); XCTAssertTrue(joplinText.contains("type_: 4"))
        let resources = joplinRoot.appendingPathComponent("resources", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: resources.path).contains { $0.hasSuffix(".txt") })

        let quiverRoot = try temporaryDirectory()
        let quiver = try NotesExporter(reader: InMemoryNotes.sample()).run(ExportOptions(output: quiverRoot, format: .quiver))
        let library = URL(fileURLWithPath: try XCTUnwrap(quiver.files.first))
        XCTAssertEqual(library.pathExtension, "qvlibrary")
        let children = try XCTUnwrap(FileManager.default.enumerator(at: library, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        XCTAssertEqual(children.filter { $0.pathExtension == "qvnote" }.count, 2)
        for content in children.filter({ $0.lastPathComponent == "content.json" }) {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: content)) as? [String: Any])
            let cells = try XCTUnwrap(object["cells"] as? [[String: Any]])
            XCTAssertEqual(cells.first?["type"] as? String, "markdown")
            let metadata = content.deletingLastPathComponent().appendingPathComponent("meta.json")
            XCTAssertNotNil(try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])["title"] as? String)
        }
    }

    func testCombinedPDFAndEPUBKeepAccountsAndFullFolderPathsSeparate() throws {
        let accounts = [Account(id: "a1", name: "One", kind: "local"), Account(id: "a2", name: "Two", kind: "local")]
        let folders = [
            Folder(id: "f1", name: "Shared", accountID: "a1", parentID: nil, path: ["Parent", "Shared"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 1),
            Folder(id: "f2", name: "Shared", accountID: "a2", parentID: nil, path: ["Other", "Shared"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 1),
        ]
        let notes = folders.enumerated().map { index, folder in
            let summary = NoteSummary(id: NoteID(uuid: "n\(index)"), title: "Note \(index)", snippet: "", folderID: folder.id,
                                      folderPath: folder.path, accountID: folder.accountID, created: nil, modified: nil,
                                      isPinned: false, isLocked: false, isDeleted: false, hasChecklist: false,
                                      attachmentCount: 0, tags: [])
            return Note(summary: summary, document: NoteDocument(text: "body", runs: []), attachments: [])
        }
        let fake = InMemoryNotes(accounts: accounts, folders: folders, notes: notes)

        let pdf = try NotesExporter(reader: fake).run(ExportOptions(output: try temporaryDirectory(), format: .pdf, combine: true))
        XCTAssertEqual(pdf.files.count, 2)
        XCTAssertEqual(Set(pdf.files.map { URL(fileURLWithPath: $0).lastPathComponent }).count, 2)
        XCTAssertTrue(pdf.files.allSatisfy { PDFDocument(url: URL(fileURLWithPath: $0))?.pageCount == 1 })

        let epub = try NotesExporter(reader: fake).run(ExportOptions(output: try temporaryDirectory(), format: .epub))
        XCTAssertEqual(epub.files.count, 2)
        XCTAssertEqual(Set(epub.files.map { URL(fileURLWithPath: $0).lastPathComponent }).count, 2)
        for path in epub.files {
            XCTAssertEqual(try zipListing(URL(fileURLWithPath: path)).filter { $0.hasPrefix("EPUB/text/chapter-") }.count, 1)
        }
    }

    func testScanPDFPreservesPageCountAndOrderIndexUsesDisplayOrder() throws {
        let root = try temporaryDirectory(), page1 = root.appendingPathComponent("page1.png"), page2 = root.appendingPathComponent("page2.png")
        try writePNG(to: page1, red: 255, green: 0, blue: 0)
        try writePNG(to: page2, red: 0, green: 0, blue: 255)
        let account = Account(id: "a", name: "A", kind: "local")
        let folder = Folder(id: "f", name: "F", accountID: "a", parentID: nil, path: ["F"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 2)
        func make(_ id: String, order: Double, scan: Bool) -> Note {
            let summary = NoteSummary(id: NoteID(uuid: id), title: id, snippet: "", folderID: "f", folderPath: ["F"], accountID: "a",
                                      created: nil, modified: nil, isPinned: false, isLocked: false, isDeleted: false,
                                      hasChecklist: false, attachmentCount: scan ? 1 : 0, tags: [], displayOrder: order)
            let attachment = Attachment(id: "scan", typeUTI: "com.apple.paper.doc.scan", pageImagePaths: [page1.path, page2.path])
            return Note(summary: summary, document: NoteDocument(text: "body", runs: []), attachments: scan ? [attachment] : [])
        }
        let fake = InMemoryNotes(accounts: [account], folders: [folder], notes: [make("later", order: 2, scan: false), make("first", order: 1, scan: true)])
        let output = root.appendingPathComponent("out")
        let report = try NotesExporter(reader: fake).run(ExportOptions(output: output, scansPDF: true, order: .display))
        let scan = try XCTUnwrap(report.files.first { $0.contains("-scans/") })
        XCTAssertEqual(PDFDocument(url: URL(fileURLWithPath: scan))?.pageCount, 2)
        let index = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent(".notescli-order.json"))) as? [[String: Any]])
        XCTAssertEqual(index.map { $0["id"] as? String }, ["first", "later"])
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent(".notescli-export.json"))) as? [String: Any])
        XCTAssertEqual(manifest["order"] as? [String], ["first", "later"])
    }

    private func zipListing(_ url: URL) throws -> [String] {
        try process("/usr/bin/unzip", ["-Z1", url.path]).split(separator: "\n").map(String.init)
    }

    private func writePNG(to url: URL, red: UInt8, green: UInt8, blue: UInt8) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 64,
                                                    bitsPerPixel: 32))
        let data = try XCTUnwrap(bitmap.bitmapData)
        for offset in stride(from: 0, to: 16 * 16 * 4, by: 4) {
            data[offset] = red; data[offset + 1] = green; data[offset + 2] = blue; data[offset + 3] = 255
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func unzip(_ url: URL, path: String) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, path]
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NotesSyncError.externalTool("unzip failed") }
        return data
    }

    private func process(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NotesSyncError.externalTool("\(executable) failed") }
        return String(decoding: data, as: UTF8.self)
    }
}
