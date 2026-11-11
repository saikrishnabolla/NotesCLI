import ArgumentParser
import Foundation
import NotesCore
import NotesMCP

enum ExportFormat: String, ExpressibleByArgument { case markdown, html, json }
struct Export: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Option var out: String = "notes-export"
    @Option var folder: String?
    @Option var format: ExportFormat = .markdown
    @Flag var attachments = false

    static func component(_ text: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let encoded = text.isEmpty ? "untitled" : text.addingPercentEncoding(withAllowedCharacters: safe)!
        if encoded.utf8.count <= 80 { return encoded }
        let hash = text.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return String(encoded.prefix(60)) + "-" + String(hash, radix: 16)
    }
    func run() throws {
        let reader = try options.backends().reader
        let notes = try reader.notes(NoteQuery(folder: folder))
        let root = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolvedRoot = root.resolvingSymlinksInPath().path
        func checked(_ url: URL) throws -> URL {
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(resolvedRoot + "/") else { throw NotesError("invalid_export_path", "Export path leaves the output directory.") }
            return url
        }
        var files: [String] = []
        let accounts = try reader.accounts()
        for summary in notes {
            var note = try reader.note(summary.id.uuid)
            var directory = root
            if accounts.count > 1 { directory.appendPathComponent(Self.component(summary.accountID), isDirectory: true) }
            for part in summary.folderPath { directory.appendPathComponent(Self.component(part), isDirectory: true) }
            if directory != root { _ = try checked(directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stem = Self.component(summary.title) + "--" + Self.component(summary.id.uuid)
            if attachments {
                let attachmentDirectory = try checked(directory.appendingPathComponent(stem + "-attachments", isDirectory: true))
                for i in note.attachments.indices {
                    guard let path = note.attachments[i].filePath else { continue }
                    let source = URL(fileURLWithPath: path)
                    let filename = Self.component(note.attachments[i].id) + "-" + Self.component(note.attachments[i].filename ?? source.lastPathComponent)
                    try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
                    let destination = try checked(attachmentDirectory.appendingPathComponent(filename))
                    // Atomic replacement lets repeated exports refresh the same attachment.
                    try Data(contentsOf: source).write(to: destination, options: .atomic)
                    note.attachments[i].filePath = stem + "-attachments/" + filename
                }
            }
            let ext = format == .markdown ? "md" : format.rawValue
            let target = try checked(directory.appendingPathComponent(stem + "." + ext))
            let metadata: [String: Any] = ["id": summary.id.uuid, "title": summary.title,
                "folder": summary.folderPath, "created": summary.created.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                "modified": summary.modified.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(), "tags": summary.tags]
            let text: String
            if format == .json {
                let object: [String: Any] = ["metadata": metadata, "note": try JSONSerialization.jsonObject(with: Data(NotePresentation.render(note, format: "json", attachments: attachments).utf8))]
                text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self)
            } else {
                let frontMatter = try ["id", "title", "folder", "created", "modified", "tags"].map { key in
                    let value = try JSONSerialization.data(withJSONObject: metadata[key]!, options: [.fragmentsAllowed, .sortedKeys])
                    return key + ": " + String(decoding: value, as: UTF8.self)
                }.joined(separator: "\n")
                let body = try NotePresentation.render(note, format: format.rawValue, attachments: attachments)
                text = format == .markdown ? "---\n\(frontMatter)\n---\n\n\(body)\n" : "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>\(NotePresentation.escapeHTML(summary.title))</title></head><body>\n<pre class=\"front-matter\">\(NotePresentation.escapeHTML(frontMatter))</pre>\n\(body)\n</body></html>\n"
            }
            try text.write(to: target, atomically: true, encoding: .utf8); files.append(target.path)
        }
        if options.json { try Output.json(files) } else { Output.table(["EXPORTED FILE"], files.map { [$0] }) }
    }
}
