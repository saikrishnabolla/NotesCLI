import ArgumentParser
import Foundation
import NotesCore
import NotesStore

extension EditorTemplate {
    static func choices(_ templates: [Self], matching value: String) -> [EditorSlashChoice] {
        let query = value.trimmingCharacters(in: .whitespaces).lowercased()
        let term = query.hasPrefix("template ") ? String(query.dropFirst(9)) : query
        let all = query.isEmpty || "template".hasPrefix(query)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let matches = templates.filter { all || $0.title.range(of: term, options: options) != nil }
        let titleCounts = Dictionary(grouping: matches, by: { $0.title.folding(options: options, locale: .current) })
        return matches.map { value in
            let duplicate = (titleCounts[value.title.folding(options: options, locale: .current)]?.count ?? 0) > 1
            let folder = value.folder.joined(separator: " › ")
            let suffix = duplicate ? " (\(folder), \(value.id.uuidString.prefix(8)))" : ""
            return EditorSlashChoice(label: value.title + suffix, aliases: [], action: .template(value.id))
        }
    }
}

extension PaletteClient {
    func templates(destination: UUID) throws -> [EditorTemplate] {
        let id = destination.uuidString
        let data = try invoke(["editor-template", "--destination", id])
        return try JSONDecoder().decode([EditorTemplate].self, from: data)
    }

    func template(destination: UUID, source: UUID) throws -> EditorTemplatePayload {
        let target = destination.uuidString
        let key = source.uuidString
        let data = try invoke(["editor-template", "--destination", target, "--source", key])
        return try JSONDecoder().decode(EditorTemplatePayload.self, from: data)
    }
}

struct EditorTemplateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "editor-template", shouldDisplay: false)
    @OptionGroup var options: GlobalOptions
    @Option var destination: String
    @Option var source: String?

    func run() throws {
        guard options.json, let target = UUID(uuidString: destination) else {
            throw NotesError("invalid_template_reference", "Use a stable destination note ID and JSON output.")
        }
        let backend = try options.backends()
        guard backend.fidelity == .full else {
            throw NotesError("template_full_access_required", "Templates need full Notes read access.")
        }
        let store = EditorTemplateStore(reader: backend.reader)
        if let source, let key = UUID(uuidString: source) {
            try Output.json(store.render(source: key, destination: target))
        } else if source == nil {
            try Output.json(store.catalog(destination: target))
        } else {
            throw NotesError("invalid_template_reference", "Use a stable source note ID.")
        }
    }
}
