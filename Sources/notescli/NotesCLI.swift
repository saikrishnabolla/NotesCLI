import ArgumentParser
import Foundation
import NotesCore
import NotesMCP
import Darwin

@main
struct NotesCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "notescli", abstract: "Read and manage Apple Notes.", version: "1.0.0", subcommands: [Accounts.self, Folders.self, List.self, Show.self, Search.self, Tags.self, Recent.self, Add.self, Append.self, Edit.self, Rename.self, Move.self, Delete.self, FolderCommand.self, Export.self, SyncCommand.self, SyncDaemonCommand.self, WatchCommand.self, Open.self, Doctor.self, MCP.self, Completion.self])
    @OptionGroup var options: GlobalOptions

    static func main() {
        do { var command = try parseAsRoot(); try command.run() }
        catch {
            if let e = error as? NotesError { fail(e) }
            let code = exitCode(for: error).rawValue
            if code == 0 { exit(withError: error) }
            if CommandLine.arguments.contains("--json") {
                fail(NotesError(code == 64 ? "usage" : "error", message(for: error)), status: code == 64 ? 2 : 1)
            }
            FileHandle.standardError.write(Data((fullMessage(for: error) + "\n").utf8))
            Darwin.exit(code == 64 ? 2 : 1)
        }
    }
    static func fail(_ e: NotesError, status: Int32? = nil) -> Never {
        if CommandLine.arguments.contains("--json"), let data = try? NotePresentation.json(e) { FileHandle.standardError.write(data + Data("\n".utf8)) }
        else { Output.error(e.description) }
        let code: Int32 = status ?? (e.code.contains("not_found") ? 3 : e.code.contains("denied") || e.code == "read_only" || e.code.contains("permission") ? 4 : e.code == "write_outcome_unknown" ? 5 : e.code.hasPrefix("invalid_") || e.code == "usage" ? 2 : 1)
        Darwin.exit(code)
    }
}

struct Accounts: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let rows = try options.backends().reader.accounts()
        if options.json { try Output.json(rows) } else { Output.table(["ID", "NAME", "KIND"], rows.map { [$0.id, $0.name, $0.kind] }) }
    }
}
struct Folders: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Option var account: String?
    @Flag var tree = false
    func run() throws {
        let rows = try options.backends().reader.folders(account: account)
        if options.json { try Output.json(rows) }
        else { Output.table(["ID", "FOLDER", "NOTES"], rows.map { [$0.id, tree ? String(repeating: "  ", count: max(0, $0.path.count - 1)) + $0.name : $0.path.joined(separator: " > "), String($0.noteCount)] }) }
    }
}
struct List: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Option var folder: String?
    @Option var account: String?
    @Flag var pinned = false
    @Option var tag: String?
    @Option var since: String?
    @Option var until: String?
    @Option var limit: Int?
    @Flag var includeDeleted = false
    func validate() throws { try positive(limit, name: "limit") }
    func run() throws {
        let after = try since.map { try NotePresentation.date($0) }, before = try until.map { try NotePresentation.date($0) }
        if let after, let before, after > before { throw ValidationError("--since must precede --until.") }
        try Output.notes(options.backends().reader.notes(NoteQuery(folder: folder, account: account, includeDeleted: includeDeleted, pinnedOnly: pinned, tag: tag, modifiedAfter: after, modifiedBefore: before, limit: limit)), json: options.json)
    }
}
enum NoteFormat: String, ExpressibleByArgument { case markdown, text, html, json }
struct Show: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Option var format: NoteFormat = .markdown
    @Flag var noAttachments = false
    func run() throws {
        let note = try options.backends().reader.note(ref)
        print(try NotePresentation.render(note, format: options.json ? "json" : format.rawValue, attachments: !noAttachments))
    }
}
struct Search: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var query: String
    @Option var folder: String?
    @Option var limit: Int?
    @Flag var fuzzy = false
    func validate() throws { try positive(limit, name: "limit") }
    func run() throws {
        let reader = try options.backends().reader
        let notes = try fuzzy ? FuzzySearch.search(query, reader: reader, folder: folder, limit: limit) : reader.notes(NoteQuery(folder: folder, text: query, limit: limit))
        try Output.notes(notes, json: options.json)
    }
}
struct Tags: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let tags = try options.backends().reader.tags()
        if options.json { try Output.json(tags) } else { Output.table(["TAG", "NOTES"], tags.keys.sorted().map { [$0, String(tags[$0]!)] }) }
    }
}
struct Recent: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var n: Int = 10
    func validate() throws { try positive(n, name: "N") }
    func run() throws { try Output.notes(options.backends().reader.notes(NoteQuery(limit: n)), json: options.json) }
}
struct Add: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var title: String = "Untitled"
    @Option var folder: String?
    @Option var body: String?
    @Flag var stdin = false
    @Option var file: String?
    func validate() throws { try validateBodySources(body: body, stdin: stdin, file: file, allowEditor: true) }
    func run() throws {
        let backend = try options.writable()
        let markdown = try inputBody(body: body, stdin: stdin, file: file, allowEditor: true)
        try Output.write(backend.writer().createNote(title: title, markdown: markdown, folder: folder), json: options.json)
    }
}
struct Append: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Option var body: String?
    @Flag var stdin = false
    func validate() throws { try validateBodySources(body: body, stdin: stdin) }
    func run() throws {
        let backend = try options.writable()
        let markdown = try inputBody(body: body, stdin: stdin)
        try Output.write(backend.writer().appendToNote(ref, markdown: markdown), json: options.json)
    }
}
struct Edit: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    func run() throws {
        let backend = try options.writable(), note = try backend.reader.note(ref)
        guard !note.summary.isLocked else { throw NotesError("note_locked", "The note is locked.") }
        Output.error("Warning: replacing the body may downgrade attachments and checklists.")
        let original = try NotePresentation.render(note, format: "markdown")
        let edited = try editor(original)
        if edited == original { try Output.write(WriteResult(outcome: .verified, noteID: note.summary.id, message: "Unchanged; no write made."), json: options.json); return }
        try Output.write(backend.writer().replaceBody(note.summary.id.uuid, markdown: edited), json: options.json)
    }
}
struct Rename: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Argument var title: String
    func run() throws { try Output.write(options.writable().writer().renameNote(ref, title: title), json: options.json) }
}
struct Move: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Argument var folder: String
    func run() throws { try Output.write(options.writable().writer().moveNote(ref, toFolder: folder), json: options.json) }
}
struct Delete: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var refs: [String]
    @Flag var yes = false
    func validate() throws { if refs.isEmpty { throw ValidationError("Provide at least one note reference.") } }
    func run() throws {
        let backend = try options.writable()
        let ids = try refs.map { try backend.reader.note($0).summary.id.uuid }
        try confirm("Move \(ids.count) note(s) to Recently Deleted?", yes: yes)
        let writer = try backend.writer()
        var results: [WriteResult] = []
        for id in ids { let result = try writer.deleteNote(id); if result.outcome == .unknown { try Output.write(result, json: options.json) }; results.append(result) }
        if options.json { try Output.json(results) } else { for result in results { try Output.write(result, json: false) } }
    }
}
struct FolderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "folder", subcommands: [CreateFolder.self, RenameFolder.self, DeleteFolder.self])
    @OptionGroup var options: GlobalOptions
}
struct CreateFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create")
    @OptionGroup var options: GlobalOptions
    @Argument var name: String
    @Option var parent: String?
    @Option var account: String?
    func run() throws { try Output.write(options.writable().writer().createFolder(name: name, parent: parent, account: account), json: options.json) }
}
struct RenameFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Argument var name: String
    func run() throws { try Output.write(options.writable().writer().renameFolder(ref, name: name), json: options.json) }
}
struct DeleteFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Flag var yes = false
    func run() throws {
        let backend = try options.writable()
        try confirm("Delete folder \(ref) and move its notes to Recently Deleted?", yes: yes)
        try Output.write(backend.writer().deleteFolder(ref), json: options.json)
    }
}
struct Open: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    func run() throws {
        let backend = try options.backends(), note = try backend.reader.note(ref)
        try backend.openNote(note.summary.id)
        if options.json { try Output.json(["opened": note.summary.id.uuid]) } else { print("Opened \(note.summary.title)") }
    }
}
struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Run MCP on stdio.")
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let backend = try options.backends()
        MCPServer(reader: backend.reader, writer: options.readOnly ? nil : try backend.writer(), readOnly: options.readOnly).run()
    }
}
struct Completion: ParsableCommand {
    @Argument var shell: String = "zsh"
    func run() throws {
        guard let shell = CompletionShell(rawValue: shell) else { throw ValidationError("Use bash, zsh, or fish.") }
        print(NotesCLI.completionScript(for: shell))
    }
}
