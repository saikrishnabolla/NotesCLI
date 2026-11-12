import AppKit
import Foundation
import PDFKit
import NotesCore

struct PreparedExportNote {
    var note: Note
    var relativeDirectory: String
    var stem: String
    var relativePath: String
    var content: String
    var attachmentPaths: [String]
}

struct ExportFolderKey: Hashable {
    var accountID: String
    var path: [String]

    init(accountID: String, path: [String]) {
        self.accountID = accountID
        self.path = path
    }

    init(_ summary: NoteSummary) {
        accountID = summary.accountID
        path = summary.folderPath
    }
}

enum RichDocumentExport {
    static func attributedString(for note: Note, appendImages: Bool = true) throws -> NSAttributedString {
        var note = note
        for index in note.attachments.indices {
            if let path = note.attachments[index].filePath, path.hasPrefix("/") {
                note.attachments[index].filePath = URL(fileURLWithPath: path).absoluteString
            }
            note.attachments[index].pageImagePaths = note.attachments[index].pageImagePaths?.map {
                $0.hasPrefix("/") ? URL(fileURLWithPath: $0).absoluteString : $0
            }
        }
        let body = note.document.map { NoteRenderer.html($0, attachments: note.attachments) } ?? "<p>[Locked note]</p>"
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, sans-serif; font-size: 12pt; line-height: 1.35; }
        img { max-width: 100%; height: auto; } table { border-collapse: collapse; }
        td, th { border: 1px solid #999; padding: 4px; }
        </style></head><body><h1>\(xml(note.summary.title))</h1>\(body)</body></html>
        """
        let imported = try NSAttributedString(data: Data(html.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ], documentAttributes: nil)
        let result = NSMutableAttributedString(attributedString: imported)
        var seen: Set<String> = []
        let imagePaths = note.attachments.flatMap { attachment in
            ([attachment.filePath] + (attachment.pageImagePaths ?? []).map(Optional.some)).compactMap { value -> String? in
                guard let value, let url = URL(string: value), url.isFileURL else { return nil }
                return url.path
            }
        }
        for path in imagePaths where appendImages && seen.insert(path).inserted {
            guard let image = NSImage(contentsOfFile: path) else { continue }
            let attachment = NSTextAttachment()
            attachment.image = image
            let maximum: CGFloat = 480
            let scale = min(1, maximum / max(1, image.size.width))
            attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
            result.append(NSAttributedString(string: "\n"))
            result.append(NSAttributedString(attachment: attachment))
        }
        return result
    }

    static func write(_ note: Note, format: NotesExportFormat, to url: URL) throws {
        let attributed = try attributedString(for: note, appendImages: format != .rtf)
        switch format {
        case .pdf:
            try MainActor.assumeIsolated { try writePDF(attributed, to: url) }
        case .docx, .rtf:
            let type: NSAttributedString.DocumentType = format == .docx ? .officeOpenXML : .rtf
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                           documentAttributes: [.documentType: type])
            try data.write(to: url, options: .atomic)
        default:
            throw NotesSyncError.invalidState("Unsupported rich document format: \(format.rawValue)")
        }
    }

    static func combinePDFs(_ sources: [URL], to target: URL) throws {
        let output = PDFDocument()
        for source in sources {
            guard let document = PDFDocument(url: source) else { throw NotesSyncError.invalidState("Invalid PDF: \(source.path)") }
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) { output.insert(page, at: output.pageCount) }
            }
        }
        guard output.pageCount > 0, output.write(to: target) else { throw NotesSyncError.invalidState("Could not write PDF: \(target.path)") }
    }

    static func writeScanPDF(pagePaths: [String], fallbackPDF: String?, to url: URL) throws -> Int {
        if pagePaths.isEmpty, let fallbackPDF, let source = PDFDocument(url: URL(fileURLWithPath: fallbackPDF)) {
            guard source.write(to: url) else { throw NotesSyncError.invalidState("Could not write scan PDF.") }
            return source.pageCount
        }
        let document = PDFDocument()
        if pagePaths.isEmpty, let fallbackPDF, let image = NSImage(contentsOfFile: fallbackPDF), let page = PDFPage(image: image) {
            document.insert(page, at: 0)
        }
        for path in pagePaths {
            guard let image = NSImage(contentsOfFile: path), let page = PDFPage(image: image) else {
                throw NotesSyncError.invalidState("Unreadable scan page: \(path)")
            }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0, document.write(to: url) else { throw NotesSyncError.invalidState("Could not write scan PDF.") }
        return document.pageCount
    }

    @MainActor
    private static func writePDF(_ attributed: NSAttributedString, to url: URL) throws {
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let printableWidth: CGFloat = 504
        let container = NSTextContainer(containerSize: NSSize(width: printableWidth, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = max(684, layout.usedRect(for: container).height + 24)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: printableWidth, height: height), textContainer: container)
        view.textContainerInset = NSSize(width: 0, height: 8)

        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.leftMargin = 54; printInfo.rightMargin = 54
        printInfo.topMargin = 54; printInfo.bottomMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw NotesSyncError.invalidState("Could not render PDF: \(url.path)") }
    }
}

enum EPUBExport {
    static func write(notes: [Note], title: String, to url: URL) throws {
        var entries: [ZipEntry] = [ZipEntry(path: "mimetype", data: Data("application/epub+zip".utf8))]
        entries.append(ZipEntry(path: "META-INF/container.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8)))
        var chapters: [(id: String, path: String, title: String)] = []
        var images: [(id: String, path: String, media: String)] = []

        for (noteIndex, original) in notes.enumerated() {
            var note = original
            for attachmentIndex in note.attachments.indices {
                var attachment = note.attachments[attachmentIndex]
                if let source = attachment.filePath, FileManager.default.fileExists(atPath: source) {
                    let ext = URL(fileURLWithPath: source).pathExtension
                    let path = "EPUB/images/note-\(noteIndex + 1)-\(SafePath.component(attachment.id, limit: 40))\(ext.isEmpty ? "" : "." + ext)"
                    entries.append(ZipEntry(path: path, data: try Data(contentsOf: URL(fileURLWithPath: source))))
                    let imageID = "image-\(images.count + 1)"
                    images.append((imageID, String(path.dropFirst("EPUB/".count)), mediaType(path)))
                    attachment.filePath = "../" + String(path.dropFirst("EPUB/".count))
                }
                attachment.pageImagePaths = try attachment.pageImagePaths?.enumerated().map { pageIndex, source in
                    let ext = URL(fileURLWithPath: source).pathExtension
                    let path = "EPUB/images/note-\(noteIndex + 1)-\(SafePath.component(attachment.id, limit: 32))-page-\(pageIndex + 1)\(ext.isEmpty ? "" : "." + ext)"
                    entries.append(ZipEntry(path: path, data: try Data(contentsOf: URL(fileURLWithPath: source))))
                    images.append(("image-\(images.count + 1)", String(path.dropFirst("EPUB/".count)), mediaType(path)))
                    return "../" + String(path.dropFirst("EPUB/".count))
                }
                note.attachments[attachmentIndex] = attachment
            }
            let chapterPath = "text/chapter-\(noteIndex + 1).xhtml"
            chapters.append(("chapter-\(noteIndex + 1)", chapterPath, note.summary.title))
            let rendered = note.document.map { NoteRenderer.html($0, attachments: note.attachments) } ?? "<p>[Locked note]</p>"
            let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(xml(note.summary.title))</title><meta charset="utf-8" /></head><body><h1>\(xml(note.summary.title))</h1>\(xhtml(rendered))</body></html>
            """
            entries.append(ZipEntry(path: "EPUB/\(chapterPath)", data: Data(xhtml.utf8)))
        }

        let navItems = chapters.map { "<li><a href=\"\($0.path)\">\(xml($0.title))</a></li>" }.joined()
        entries.append(ZipEntry(path: "EPUB/nav.xhtml", data: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>\(xml(title))</title></head><body><nav epub:type="toc"><h1>Contents</h1><ol>\(navItems)</ol></nav></body></html>
        """.utf8)))
        let manifest = (["<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\" />"]
            + chapters.map { "<item id=\"\($0.id)\" href=\"\($0.path)\" media-type=\"application/xhtml+xml\" />" }
            + images.map { "<item id=\"\($0.id)\" href=\"\($0.path)\" media-type=\"\($0.media)\" />" }).joined()
        let spine = chapters.map { "<itemref idref=\"\($0.id)\" />" }.joined()
        let identifier = String(StableHash.hex(notes.map { $0.summary.id.uuid }.joined(separator: ":")).prefix(32))
        entries.append(ZipEntry(path: "EPUB/package.opf", data: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">urn:uuid:\(identifier)</dc:identifier><dc:title>\(xml(title))</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
        """.utf8)))
        try ZipArchive.write(entries, to: url)
    }

    private static func mediaType(_ path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    private static func xhtml(_ value: String) -> String {
        value.replacingOccurrences(of: #"<br>"#, with: "<br />")
            .replacingOccurrences(of: #"<hr>"#, with: "<hr />")
            .replacingOccurrences(of: #"<img([^>]*?)(?<!/)>"#, with: #"<img$1 />"#, options: .regularExpression)
            .replacingOccurrences(of: #"<input([^>]*?)(?<!/)>"#, with: #"<input$1 />"#, options: .regularExpression)
            .replacingOccurrences(of: " disabled", with: " disabled=\"disabled\"")
            .replacingOccurrences(of: " checked", with: " checked=\"checked\"")
    }
}

enum ImportFormatExport {
    // Bear imports TextBundle packages: https://bear.app/faq/import-your-notes/
    // TextBundle structure: http://textbundle.org/spec/
    static func writeBear(_ notes: [Note], root: URL) throws -> [String] {
        var files: [String] = []
        for note in notes {
            let directory = try SafePath.child(SafePath.component(note.summary.title) + "--" + SafePath.component(note.summary.id.uuid, limit: 24) + ".textbundle", of: root)
            let assets = try SafePath.child("assets", of: directory)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            var copy = note
            var used: Set<String> = []
            for index in copy.attachments.indices {
                guard let source = copy.attachments[index].filePath, FileManager.default.fileExists(atPath: source) else { continue }
                let name = attachmentName(copy.attachments[index], source: source, used: &used)
                try FileManager.default.copyReplacingItem(at: URL(fileURLWithPath: source), to: SafePath.child(name, of: assets))
                copy.attachments[index].filePath = "assets/" + name
            }
            let text = copy.document.map { NoteRenderer.markdown($0, attachments: copy.attachments) } ?? "[Locked note]"
            let textURL = try SafePath.child("text.md", of: directory)
            try Data(text.utf8).write(to: textURL, options: .atomic)
            let info: [String: Any] = ["version": 2, "type": "net.daringfireball.markdown", "transient": false]
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: SafePath.child("info.json", of: directory), options: .atomic)
            files.append(directory.path)
        }
        return files
    }

    // Joplin RAW is the unpacked lossless export accepted by its importer:
    // https://joplinapp.org/help/apps/import_export/
    // https://github.com/laurent22/joplin/blob/dev/packages/lib/services/interop/InteropService_Importer_Raw.test.ts
    static func writeJoplin(_ notes: [Note], root: URL) throws -> [String] {
        var files: [String] = [], folders: [ExportFolderKey: String] = [:]
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let allPaths = Set(notes.flatMap { note in
            (1...note.summary.folderPath.count).map {
                ExportFolderKey(accountID: note.summary.accountID, path: Array(note.summary.folderPath.prefix($0)))
            }
        })
        for key in allPaths.sorted(by: { ($0.accountID, $0.path.joined(separator: "/")) < ($1.accountID, $1.path.joined(separator: "/")) }) {
            let id = String(StableHash.hex("joplin-folder:" + key.accountID + ":" + key.path.joined(separator: "/")).prefix(32))
            folders[key] = id
            let parent = folders[ExportFolderKey(accountID: key.accountID, path: Array(key.path.dropLast()))] ?? ""
            let text = "\(key.path.last ?? "Notes")\n\nid: \(id)\ncreated_time: 1970-01-01T00:00:00.000Z\nupdated_time: 1970-01-01T00:00:00.000Z\nuser_created_time: 1970-01-01T00:00:00.000Z\nuser_updated_time: 1970-01-01T00:00:00.000Z\nparent_id: \(parent)\nencryption_applied: 0\ntype_: 2\n"
            let url = root.appendingPathComponent(id + ".md")
            try Data(text.utf8).write(to: url, options: .atomic); files.append(url.path)
        }
        for note in notes {
            var copy = note, replacements: [(String, String)] = []
            for index in copy.attachments.indices {
                guard let source = copy.attachments[index].filePath, FileManager.default.fileExists(atPath: source) else { continue }
                let resourceID = String(StableHash.hex("joplin-resource:" + note.summary.id.uuid + ":" + copy.attachments[index].id).prefix(32))
                let ext = URL(fileURLWithPath: source).pathExtension
                let resource = resources.appendingPathComponent(resourceID + (ext.isEmpty ? "" : "." + ext))
                try FileManager.default.copyReplacingItem(at: URL(fileURLWithPath: source), to: resource)
                files.append(resource.path)
                let token = "notescli-resource-" + resourceID
                copy.attachments[index].filePath = token
                replacements.append((token, ":/" + resourceID))
                let resourceDate = iso(note.summary.modified ?? note.summary.created)
                let metadata = "\(copy.attachments[index].filename ?? resource.lastPathComponent)\n\nid: \(resourceID)\nmime: \(joplinMIME(copy.attachments[index], extension: ext))\nfilename: \(copy.attachments[index].filename ?? "")\ncreated_time: \(resourceDate)\nupdated_time: \(resourceDate)\nuser_created_time: \(resourceDate)\nuser_updated_time: \(resourceDate)\nfile_extension: \(ext)\nencryption_applied: 0\nencryption_blob_encrypted: 0\nsize: \((try? Data(contentsOf: URL(fileURLWithPath: source)).count) ?? 0)\ntype_: 4\n"
                let metadataURL = root.appendingPathComponent(resourceID + ".md")
                try Data(metadata.utf8).write(to: metadataURL, options: .atomic); files.append(metadataURL.path)
            }
            var body = copy.document.map { NoteRenderer.markdown($0, attachments: copy.attachments) } ?? "[Locked note]"
            for replacement in replacements { body = body.replacingOccurrences(of: replacement.0, with: replacement.1) }
            let id = String(StableHash.hex("joplin-note:" + note.summary.id.uuid).prefix(32))
            let parent = folders[ExportFolderKey(note.summary)] ?? ""
            let created = iso(note.summary.created), updated = iso(note.summary.modified ?? note.summary.created)
            let text = "\(note.summary.title)\n\n\(body)\n\nid: \(id)\nparent_id: \(parent)\ncreated_time: \(created)\nupdated_time: \(updated)\nis_conflict: 0\nis_todo: 0\ntodo_due: 0\ntodo_completed: 0\nsource: notescli\nsource_application: notescli\nuser_created_time: \(created)\nuser_updated_time: \(updated)\nencryption_applied: 0\nmarkup_language: 1\ntype_: 1\n"
            let url = root.appendingPathComponent(id + ".md")
            try Data(text.utf8).write(to: url, options: .atomic); files.append(url.path)
        }
        return files
    }

    // Quiver's library/notebook/note JSON layout and Markdown cell shape:
    // https://github.com/kuboon/quiver/blob/master/README.md
    // https://github.com/kuboon/quiver/blob/master/lib/quiver/note.rb
    static func writeQuiver(_ notes: [Note], root: URL) throws -> [String] {
        let library = try SafePath.child("Notes.qvlibrary", of: root)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let files: [String] = [library.path]
        for group in Dictionary(grouping: notes, by: { ExportFolderKey($0.summary) }).sorted(by: {
            ($0.key.accountID, $0.key.path.joined(separator: "/")) < ($1.key.accountID, $1.key.path.joined(separator: "/"))
        }) {
            let notebookID = String(StableHash.hex("quiver-folder:" + group.key.accountID + ":" + group.key.path.joined(separator: "/")).prefix(32))
            let notebook = try SafePath.child(notebookID + ".qvnotebook", of: library)
            try FileManager.default.createDirectory(at: notebook, withIntermediateDirectories: true)
            let notebookMeta: [String: Any] = ["uuid": notebookID, "name": group.key.path.last ?? "Notes", "children": []]
            try json(notebookMeta).write(to: SafePath.child("meta.json", of: notebook), options: .atomic)
            for note in group.value {
                let noteID = String(StableHash.hex("quiver-note:" + note.summary.id.uuid).prefix(32))
                let directory = try SafePath.child(noteID + ".qvnote", of: notebook)
                let resources = try SafePath.child("resources", of: directory)
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                var copy = note
                var used: Set<String> = []
                for index in copy.attachments.indices {
                    guard let source = copy.attachments[index].filePath, FileManager.default.fileExists(atPath: source) else { continue }
                    let name = attachmentName(copy.attachments[index], source: source, used: &used)
                    try FileManager.default.copyReplacingItem(at: URL(fileURLWithPath: source), to: SafePath.child(name, of: resources))
                    copy.attachments[index].filePath = "quiver-image-url/" + name
                }
                let body = copy.document.map { NoteRenderer.markdown($0, attachments: copy.attachments) } ?? "[Locked note]"
                let content: [String: Any] = ["title": note.summary.title, "cells": [["type": "markdown", "data": body]]]
                let meta: [String: Any] = ["uuid": noteID, "title": note.summary.title, "tags": note.summary.tags,
                                           "created_at": seconds(note.summary.created), "updated_at": seconds(note.summary.modified)]
                try json(content).write(to: SafePath.child("content.json", of: directory), options: .atomic)
                try json(meta).write(to: SafePath.child("meta.json", of: directory), options: .atomic)
            }
        }
        return files
    }

    private static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) }
    private static func attachmentName(_ attachment: Attachment, source: String, used: inout Set<String>) -> String {
        let original = SafePath.component(attachment.filename ?? URL(fileURLWithPath: source).lastPathComponent)
        let url = URL(fileURLWithPath: original), ext = url.pathExtension
        let stem = SafePath.component(url.deletingPathExtension().lastPathComponent)
        let identity = SafePath.component(attachment.id, limit: 32) + "-" + String(StableHash.hex(attachment.id).prefix(10))
        let base = stem + "--" + identity, suffix = ext.isEmpty ? "" : "." + ext
        var candidate = base + suffix, index = 2
        while !used.insert(candidate).inserted { candidate = base + "-\(index)" + suffix; index += 1 }
        return candidate
    }
    private static func seconds(_ date: Date?) -> Int64 { Int64(date?.timeIntervalSince1970 ?? 0) }
    private static func iso(_ date: Date?) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date ?? Date(timeIntervalSince1970: 0))
    }
    private static func joplinMIME(_ attachment: Attachment, extension ext: String) -> String {
        let value = attachment.typeUTI.lowercased()
        if value.contains("png") || ext.lowercased() == "png" { return "image/png" }
        if value.contains("jpeg") || value.contains("jpg") || ["jpg", "jpeg"].contains(ext.lowercased()) { return "image/jpeg" }
        if value.contains("gif") || ext.lowercased() == "gif" { return "image/gif" }
        if value.contains("pdf") || ext.lowercased() == "pdf" { return "application/pdf" }
        return "application/octet-stream"
    }
}

private extension FileManager {
    func copyReplacingItem(at source: URL, to destination: URL) throws {
        if fileExists(atPath: destination.path) { try removeItem(at: destination) }
        try copyItem(at: source, to: destination)
    }
}

private func xml(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
