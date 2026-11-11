import Foundation
import NotesCore

public enum NotesExportFormat: String, Codable, Sendable {
    case markdown, html, json, ndjson, sqlite, zip
}

public struct ExportOptions: Sendable {
    public var output: URL
    public var folder: String?
    public var format: NotesExportFormat
    public var includeAttachments: Bool
    public var embedMedia: Bool
    public var template: String?
    public var filenameTemplate: String?
    public var obsidian: Bool
    public var prune: Bool

    public init(output: URL, folder: String? = nil, format: NotesExportFormat = .markdown,
                includeAttachments: Bool = true, embedMedia: Bool = false, template: String? = nil,
                filenameTemplate: String? = nil, obsidian: Bool = false, prune: Bool = false) {
        self.output = output; self.folder = folder; self.format = format
        self.includeAttachments = includeAttachments; self.embedMedia = embedMedia
        self.template = template; self.filenameTemplate = filenameTemplate
        self.obsidian = obsidian; self.prune = prune
    }
}

public struct ExportIssue: Codable, Equatable, Sendable {
    public var noteID: String
    public var title: String
    public var reason: String
    public init(noteID: String, title: String, reason: String) {
        self.noteID = noteID; self.title = title; self.reason = reason
    }
}

public struct ExportReport: Codable, Equatable, Sendable {
    public var files: [String]
    public var exported: Int
    public var unchanged: Int
    public var pruned: Int
    public var bytes: Int64
    public var incomplete: [ExportIssue]
    public init(files: [String] = [], exported: Int = 0, unchanged: Int = 0, pruned: Int = 0,
                bytes: Int64 = 0, incomplete: [ExportIssue] = []) {
        self.files = files; self.exported = exported; self.unchanged = unchanged
        self.pruned = pruned; self.bytes = bytes; self.incomplete = incomplete
    }
}

private struct ExportManifest: Codable {
    struct Entry: Codable {
        var path: String
        var attachmentPaths: [String]
        var hash: String
    }
    var version = 1
    var entries: [String: Entry]
}

public final class NotesExporter {
    private let reader: any NotesReading
    private let fileManager: FileManager

    public init(reader: any NotesReading, fileManager: FileManager = .default) {
        self.reader = reader; self.fileManager = fileManager
    }

    public func run(_ options: ExportOptions) throws -> ExportReport {
        if options.format == .zip { return try zip(options) }
        let requestedRoot = options.output.standardizedFileURL
        try fileManager.createPrivateDirectory(at: requestedRoot)
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let summaries = try reader.notes(NoteQuery(folder: options.folder))
        let accounts = try reader.accounts()
        let manifestURL = root.appendingPathComponent(".notescli-export.json")
        let oldManifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(ExportManifest.self, from: $0) } ?? ExportManifest(entries: [:])
        var report = ExportReport(), manifest = ExportManifest(entries: [:])
        var prepared: [(Note, String, String)] = []
        var pathsInUse: [String: String] = [:]

        for summary in summaries {
            var note: Note
            do { note = try reader.note(summary.id.uuid) }
            catch let error as NotesError where summary.isLocked || error.code == "body_unavailable" {
                note = Note(summary: summary, document: nil, attachments: [])
                report.incomplete.append(ExportIssue(noteID: summary.id.uuid, title: summary.title,
                                                     reason: summary.isLocked ? "locked" : "body not downloaded"))
            }
            if (summary.isLocked || note.document == nil) && !report.incomplete.contains(where: { $0.noteID == summary.id.uuid }) {
                report.incomplete.append(ExportIssue(noteID: summary.id.uuid, title: summary.title,
                                                     reason: summary.isLocked ? "locked" : "body not downloaded"))
            }
            let relativeDirectory = directory(for: summary, accounts: accounts)
            let ext = options.format == .markdown ? "md" : options.format.rawValue
            let stemTemplate = options.filenameTemplate ?? (options.obsidian ? "{{title}}" : "{{title}}--{{id}}")
            var stem = SafePath.component(render(stemTemplate, summary: summary, body: ""))
            var relative = ([relativeDirectory, stem + "." + ext].filter { !$0.isEmpty }).joined(separator: "/")
            if let owner = pathsInUse[relative], owner != summary.id.uuid {
                stem += "--" + SafePath.component(summary.id.uuid, limit: 24)
                relative = ([relativeDirectory, stem + "." + ext].filter { !$0.isEmpty }).joined(separator: "/")
            }
            pathsInUse[relative] = summary.id.uuid
            let attachmentPaths = try prepareAttachments(note: &note, root: root, relativeDirectory: relativeDirectory,
                                                         linkBaseDirectory: [.markdown, .html].contains(options.format) ? relativeDirectory : "",
                                                         stem: stem, embed: options.format == .html && options.embedMedia,
                                                         include: options.includeAttachments, report: &report)
            let text = try content(note: note, summary: summary, format: options.format, template: options.template)
            let attachmentHashes = attachmentPaths.compactMap { path -> String? in
                guard let data = try? Data(contentsOf: root.appendingPathComponent(path)) else { return nil }
                return StableHash.hex(data)
            }.joined(separator: ":")
            let hash = StableHash.hex(text + "\n" + attachmentHashes)
            manifest.entries[summary.id.uuid] = .init(path: relative, attachmentPaths: attachmentPaths, hash: hash)
            prepared.append((note, relative, text))
        }

        switch options.format {
        case .markdown, .html, .json:
            for (index, item) in prepared.enumerated() {
                let summary = summaries[index], target = try SafePath.child(item.1, of: root)
                if oldManifest.entries[summary.id.uuid]?.hash == manifest.entries[summary.id.uuid]?.hash,
                   fileManager.fileExists(atPath: target.path) {
                    report.unchanged += 1
                } else {
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(item.2.utf8).write(to: target, options: .atomic)
                    try setDates(target, summary: summary)
                    report.exported += 1
                }
                report.files.append(target.path)
            }
        case .ndjson:
            let target = root.appendingPathComponent("notes.ndjson")
            var data = Data()
            for item in prepared { data.append(try noteJSON(item.0)); data.append(0x0a) }
            try data.write(to: target, options: .atomic)
            report.files = [target.path]; report.exported = prepared.count
        case .sqlite:
            let target = root.appendingPathComponent("notes.sqlite")
            try SQLiteExport.write(to: target, accounts: accounts, folders: try reader.folders(account: nil), notes: prepared.map(\.0))
            report.files = [target.path]; report.exported = prepared.count
        case .zip: break
        }

        if options.prune {
            let active = Set(manifest.entries.values.flatMap { [$0.path] + $0.attachmentPaths })
            for entry in oldManifest.entries.values {
                for path in [entry.path] + entry.attachmentPaths where !active.contains(path) {
                    let target = try SafePath.child(path, of: root)
                    if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target); report.pruned += 1 }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        report.bytes = report.files.reduce(0) { total, path in
            total + Int64((try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return report
    }

    private func zip(_ options: ExportOptions) throws -> ExportReport {
        let archive = options.output.pathExtension.lowercased() == "zip" ? options.output : options.output.appendingPathComponent("notes-export.zip")
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("notescli-export-" + UUID().uuidString, isDirectory: true)
        try fileManager.createPrivateDirectory(at: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        var nested = options; nested.output = temporary; nested.format = .markdown; nested.prune = false
        var report = try run(nested)
        try fileManager.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: archive.path) { try fileManager.removeItem(at: archive) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", temporary.path, archive.path]
        let error = Pipe(); process.standardError = error
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NotesSyncError.externalTool(String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        report.files = [archive.path]
        report.bytes = Int64((try? fileManager.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? 0)
        return report
    }

    private func directory(for summary: NoteSummary, accounts: [Account]) -> String {
        var components: [String] = []
        if accounts.count > 1 {
            components.append(SafePath.component(accounts.first(where: { $0.id == summary.accountID })?.name ?? summary.accountID))
        }
        components += summary.folderPath.map { SafePath.component($0) }
        return components.joined(separator: "/")
    }

    private func prepareAttachments(note: inout Note, root: URL, relativeDirectory: String, linkBaseDirectory: String, stem: String,
                                    embed: Bool, include: Bool, report: inout ExportReport) throws -> [String] {
        guard include else { note.attachments = []; return [] }
        var paths: [String] = []
        for index in note.attachments.indices {
            let attachment = note.attachments[index]
            guard let sourcePath = attachment.filePath, fileManager.fileExists(atPath: sourcePath) else {
                report.incomplete.append(ExportIssue(noteID: note.summary.id.uuid, title: note.summary.title,
                                                     reason: "attachment not downloaded: \(attachment.filename ?? attachment.id)"))
                continue
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            if embed {
                note.attachments[index].filePath = "data:\(mimeType(attachment));base64,\(data.base64EncodedString())"
                continue
            }
            let filename = SafePath.component(attachment.filename ?? URL(fileURLWithPath: sourcePath).lastPathComponent)
            let relative = ([relativeDirectory, stem + "-attachments", SafePath.component(attachment.id, limit: 40) + "-" + filename].filter { !$0.isEmpty }).joined(separator: "/")
            let destination = try SafePath.child(relative, of: root)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            note.attachments[index].filePath = relativePath(from: linkBaseDirectory, to: relative)
            paths.append(relative)
        }
        return paths
    }

    private func relativePath(from directory: String, to path: String) -> String {
        let depth = directory.split(separator: "/").count
        return String(repeating: "../", count: depth) + path
    }

    private func mimeType(_ attachment: Attachment) -> String {
        let uti = attachment.typeUTI.lowercased()
        if uti.contains("png") { return "image/png" }
        if uti.contains("gif") { return "image/gif" }
        if uti.contains("heic") { return "image/heic" }
        if uti.contains("pdf") { return "application/pdf" }
        if uti.contains("jpeg") || uti.contains("jpg") { return "image/jpeg" }
        return "application/octet-stream"
    }

    private func content(note: Note, summary: NoteSummary, format: NotesExportFormat, template: String?) throws -> String {
        if format == .json {
            let object = try JSONSerialization.jsonObject(with: noteJSON(note))
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) + "\n"
        }
        let body: String
        switch format {
        case .html:
            body = (note.document.map { NoteRenderer.html($0, attachments: note.attachments) } ?? "<p>[Locked note]</p>") + htmlAttachments(note.attachments)
        default:
            body = (note.document.map { NoteRenderer.markdown($0, attachments: note.attachments) } ?? "[Locked note]") + markdownAttachments(note.attachments)
        }
        if let template { return render(template, summary: summary, body: body) }
        if format == .html {
            let metadata: [String: Any] = ["id": summary.id.uuid, "title": summary.title,
                "folder": summary.folderPath, "created": summary.created.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "modified": summary.modified.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(), "tags": summary.tags]
            let metadataText = String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self)
                .replacingOccurrences(of: "<", with: "\\u003c")
            return "<!doctype html>\n<html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>\(escapeHTML(summary.title))</title><script type=\"application/json\" id=\"notescli-metadata\">\(metadataText)</script></head><body>\n\(body)\n</body></html>\n"
        }
        let encoder = JSONEncoder()
        func value<T: Encodable>(_ item: T) -> String { String(decoding: (try? encoder.encode(item)) ?? Data("null".utf8), as: UTF8.self) }
        return "---\nid: \(value(summary.id.uuid))\ntitle: \(value(summary.title))\nfolder: \(value(summary.folderPath))\ncreated: \(summary.created.map { ISO8601DateFormatter().string(from: $0) } ?? "null")\nmodified: \(summary.modified.map { ISO8601DateFormatter().string(from: $0) } ?? "null")\ntags: \(value(summary.tags))\n---\n\n\(body)\n"
    }

    private func render(_ template: String, summary: NoteSummary, body: String) -> String {
        let values = ["title": summary.title, "id": summary.id.uuid,
                      "folder": summary.folderPath.joined(separator: "/"), "account": summary.accountID,
                      "created": summary.created.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                      "modified": summary.modified.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                      "tags": summary.tags.joined(separator: ", "), "body": body]
        return values.reduce(template) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func markdownAttachments(_ attachments: [Attachment]) -> String {
        let links = attachments.compactMap { attachment -> String? in
            guard let path = attachment.filePath else { return nil }
            let label = attachment.filename ?? attachment.title ?? attachment.id
            return "[\(label.replacingOccurrences(of: "]", with: "\\]"))](<\(path)>)"
        }
        return links.isEmpty ? "" : "\n\n" + links.joined(separator: "\n")
    }

    private func htmlAttachments(_ attachments: [Attachment]) -> String {
        let links = attachments.compactMap { attachment -> String? in
            guard let path = attachment.filePath else { return nil }
            let label = escapeHTML(attachment.filename ?? attachment.title ?? attachment.id)
            let source = escapeHTML(path)
            let image = attachment.typeUTI.lowercased().contains("image") || attachment.typeUTI.lowercased().contains("jpeg") || attachment.typeUTI.lowercased().contains("png")
            return image ? "<figure><img src=\"\(source)\" alt=\"\(label)\"></figure>" : "<p><a href=\"\(source)\">\(label)</a></p>"
        }
        return links.isEmpty ? "" : "\n" + links.joined(separator: "\n")
    }

    private func noteJSON(_ note: Note) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(note)
    }

    private func setDates(_ url: URL, summary: NoteSummary) throws {
        var attributes: [FileAttributeKey: Any] = [:]
        if let created = summary.created { attributes[.creationDate] = created }
        if let modified = summary.modified { attributes[.modificationDate] = modified }
        if !attributes.isEmpty { try fileManager.setAttributes(attributes, ofItemAtPath: url.path) }
    }
}
