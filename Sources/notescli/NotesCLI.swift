import ArgumentParser
import Foundation
import NotesCore
import NotesMCP
import NotesAutomation
import Darwin

@main
struct NotesCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "notescli", abstract: "Read and manage Apple Notes.", version: "1.0.0", subcommands: [Accounts.self, Folders.self, List.self, Show.self, Search.self, Tags.self, Recent.self, Add.self, Append.self, Edit.self, Rename.self, Move.self, Delete.self, FolderCommand.self, PrependCommand.self, InsertUnderHeadingCommand.self, ReplaceSectionCommand.self, ReplaceTextCommand.self, ClipCommand.self, Exists.self, HistoryCommand.self, DiffCommand.self, UndoCommand.self, RevertCommand.self, JournalCommand.self, Export.self, Open.self, Doctor.self, MCP.self, Completion.self])
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
    @OptionGroup var write: WriteOptions
    @Argument var title: String = "Untitled"
    @Option var folder: String?
    @Option var body: String?
    @Flag var stdin = false
    @Option var file: String?
    func validate() throws { try validateBodySources(body: body, stdin: stdin, file: file, allowEditor: true) }
    func run() throws {
        let backend = try options.writable()
        let markdown = try inputBody(body: body, stdin: stdin, file: file, allowEditor: true)
        let targetPath = try SafetyExecutor.folderPath(folder, reader: backend.reader)
        let paths = targetPath.map { [$0] } ?? []
        let plan = DryRunPlan(operation: "createNote", target: title, arguments: ["folder": folder ?? ""], resultingHTML: SafetyExecutor.bodyHTML(title: title, markdown: markdown))
        if let result = try SafetyExecutor.run(options: write, operation: "createNote", arguments: ["title": title, "body": markdown, "folder": folder ?? ""],
            allowedPaths: paths, plan: plan, action: { try backend.writer().createNote(title: title, markdown: markdown, folder: folder) }) {
            try Output.write(result, json: options.json)
        }
    }
}
struct Append: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Option var body: String?
    @Flag var stdin = false
    func validate() throws { try validateBodySources(body: body, stdin: stdin) }
    func run() throws {
        let backend = try options.writable(), note = try backend.reader.note(ref)
        if note.summary.attachmentCount > 0 {
            throw NotesError("attachments_would_be_lost", "Appending through HTML could remove existing attachments; the note was not changed.")
        }
        let markdown = try inputBody(body: body, stdin: stdin)
        let currentHTML = try SafetyExecutor.plannedHTML(note, backend: backend, write: write)
        let plan = DryRunPlan(operation: "appendToNote", target: note.summary.id.uuid, arguments: ["body": markdown],
                              resultingHTML: currentHTML + MarkdownToNotesHTML.convert(markdown).html)
        if let result = try SafetyExecutor.run(options: write, operation: "appendToNote", arguments: ["ref": note.summary.id.uuid, "body": markdown],
            note: note, allowedPaths: [note.summary.folderPath], plan: plan,
            action: { try backend.writer().appendToNote(note.summary.id.uuid, markdown: markdown) }) {
            try Output.write(result, json: options.json)
        }
    }
}
struct Edit: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    func run() throws {
        let backend = try options.writable(), note = try backend.reader.note(ref)
        guard !note.summary.isLocked else { throw NotesError("note_locked", "The note is locked.") }
        try SafetyExecutor.requireAttachmentSafety(note, allowLoss: write.allowAttachmentLoss)
        Output.error("Warning: replacing the body may downgrade attachments and checklists.")
        let original = try NotePresentation.render(note, format: "markdown")
        let edited = try editor(original)
        if edited == original { try Output.write(WriteResult(outcome: .verified, noteID: note.summary.id, message: "Unchanged; no write made."), json: options.json); return }
        let plan = DryRunPlan(operation: "replaceBody", target: note.summary.id.uuid, arguments: [:],
                              resultingHTML: SafetyExecutor.bodyHTML(title: note.summary.title, markdown: edited))
        if let result = try SafetyExecutor.run(options: write, operation: "replaceBody", arguments: ["ref": note.summary.id.uuid, "body": edited],
            note: note, allowedPaths: [note.summary.folderPath], destructive: true, plan: plan,
            action: { try backend.writer().replaceBody(note.summary.id.uuid, markdown: edited, allowAttachmentLoss: write.allowAttachmentLoss) }) {
            try Output.write(result, json: options.json)
        }
    }
}
struct Rename: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var title: String
    func run() throws {
        let backend = try options.writable(), note = try backend.reader.note(ref)
        let plan = DryRunPlan(operation: "renameNote", target: note.summary.id.uuid, arguments: ["title": title],
                              resultingHTML: try SafetyExecutor.plannedHTML(note, backend: backend, write: write))
        if let result = try SafetyExecutor.run(options: write, operation: "renameNote", arguments: ["ref": note.summary.id.uuid, "title": title],
            note: note, allowedPaths: [note.summary.folderPath], destructive: true, plan: plan,
            action: { try backend.writer().renameNote(note.summary.id.uuid, title: title) }) {
            try Output.write(result, json: options.json)
        }
    }
}
struct Move: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var values: [String] = []
    @Option var to: String?
    @Option var fromQuery: String?
    @Option var folder: String?
    @Option var account: String?
    @Option var tag: String?
    @Option var max = 100
    func run() throws {
        let destination: String
        let refs: [String]
        if let to { destination = to; refs = values }
        else {
            guard values.count >= 2 else { throw NotesError("usage", "Provide note references followed by a destination folder, or use --to.") }
            destination = values.last!; refs = Array(values.dropLast())
        }
        let backend = try options.writable(), targetPath = try SafetyExecutor.folderPath(destination, reader: backend.reader)
        let notes = try selectedNotes(reader: backend.reader, refs: refs, fromQuery: fromQuery, folder: folder, account: account, tag: tag, max: max)
        var items: [BatchItemResult] = []
        var plans: [DryRunPlan] = []
        for note in notes {
            do {
                var itemWrite = write
                itemWrite.idempotencyKey = write.idempotencyKey.map { "\($0):\(note.summary.id.uuid)" }
                let paths = [note.summary.folderPath] + (targetPath.map { [$0] } ?? [])
                let plan = DryRunPlan(operation: "moveNote", target: note.summary.id.uuid, arguments: ["folder": destination],
                                      resultingHTML: try SafetyExecutor.plannedHTML(note, backend: backend, write: write))
                let result = try SafetyExecutor.run(options: itemWrite, operation: "moveNote", arguments: ["ref": note.summary.id.uuid, "folder": destination],
                    note: note, allowedPaths: paths, destructive: true, plan: plan, emitDryRun: false,
                    action: { try backend.writer().moveNote(note.summary.id.uuid, toFolder: destination) })
                plans.append(plan)
                items.append(BatchItemResult(ref: note.summary.id.uuid, result: result, error: nil))
            } catch let error as NotesError { items.append(BatchItemResult(ref: note.summary.id.uuid, result: nil, error: error)) }
        }
        if write.dryRun {
            try outputDryRunPlans(plans, json: options.json)
        } else { try outputBatch(items, json: options.json) }
    }
}
struct Delete: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var refs: [String] = []
    @Option var fromQuery: String?
    @Option var folder: String?
    @Option var account: String?
    @Option var tag: String?
    @Option var max = 100
    @Flag var yes = false
    func validate() throws {
        if refs.isEmpty && fromQuery == nil && folder == nil && account == nil && tag == nil {
            throw ValidationError("Provide at least one note reference or --from-query/filter.")
        }
    }
    func run() throws {
        let backend = try options.writable()
        let notes = try selectedNotes(reader: backend.reader, refs: refs, fromQuery: fromQuery, folder: folder, account: account, tag: tag, max: max)
        if !write.dryRun { try confirm("Move \(notes.count) note(s) to Recently Deleted?", yes: yes) }
        var items: [BatchItemResult] = []
        var plans: [DryRunPlan] = []
        for note in notes {
            do {
                var itemWrite = write
                itemWrite.idempotencyKey = write.idempotencyKey.map { "\($0):\(note.summary.id.uuid)" }
                let plan = DryRunPlan(operation: "deleteNote", target: note.summary.id.uuid, arguments: [:],
                                      resultingHTML: try SafetyExecutor.plannedHTML(note, backend: backend, write: write))
                let result = try SafetyExecutor.run(options: itemWrite, operation: "deleteNote", arguments: ["ref": note.summary.id.uuid],
                    note: note, allowedPaths: [note.summary.folderPath], destructive: true, plan: plan, emitDryRun: false,
                    action: { try backend.writer().deleteNote(note.summary.id.uuid) })
                plans.append(plan)
                items.append(BatchItemResult(ref: note.summary.id.uuid, result: result, error: nil))
            } catch let error as NotesError { items.append(BatchItemResult(ref: note.summary.id.uuid, result: nil, error: error)) }
        }
        if write.dryRun {
            try outputDryRunPlans(plans, json: options.json)
        } else { try outputBatch(items, json: options.json) }
    }
}
struct FolderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "folder", subcommands: [CreateFolder.self, RenameFolder.self, MoveFolder.self, DeleteFolder.self, FolderExists.self])
    @OptionGroup var options: GlobalOptions
}
struct CreateFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var name: String
    @Option var parent: String?
    @Option var account: String?
    @Flag var parents = false
    func run() throws {
        let backend = try options.writable(), writer = try backend.writer()
        let components = parents ? name.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) } : [name]
        let resolvedParent = try SafetyExecutor.folder(parent, reader: backend.reader)
        var currentParent = resolvedParent?.path.joined(separator: " > ")
        var currentPath = resolvedParent?.path ?? []
        var activePaths = try (writer as? ScriptingNotesWriter).map {
            Set(try $0.listFoldersViaScripting().map { $0.path.joined(separator: " > ") })
        }
        if let currentParent, let activePaths, !activePaths.contains(currentParent) {
            throw NotesError("folder_not_found", "The parent folder does not exist in Notes.app.")
        }
        var results: [WriteResult] = []
        var plans: [DryRunPlan] = []
        for component in components {
            let path = currentPath + [component]
            let pathRef = path.joined(separator: " > ")
            let exists = activePaths?.contains(pathRef) ?? ((try? SafetyExecutor.folder(pathRef, reader: backend.reader)) != nil)
            if exists {
                currentParent = path.joined(separator: " > "); currentPath = path; continue
            }
            let plan = DryRunPlan(operation: "createFolder", target: path.joined(separator: " > "), arguments: ["name": component], resultingHTML: nil)
            var itemWrite = write
            itemWrite.idempotencyKey = write.idempotencyKey.map { "\($0):\(path.joined(separator: ">"))" }
            if let result = try SafetyExecutor.run(options: itemWrite, operation: "createFolder", arguments: ["name": component, "parent": currentParent ?? "", "account": account ?? ""],
                allowedPaths: [path], plan: plan, emitDryRun: false,
                action: { try writer.createFolder(name: component, parent: currentParent, account: account) }) {
                results.append(result); currentParent = path.joined(separator: " > ")
                activePaths?.insert(pathRef)
            }
            plans.append(plan)
            if write.dryRun { currentParent = path.joined(separator: " > ") }
            currentPath = path
        }
        if write.dryRun { try outputDryRunPlans(plans, json: options.json) }
        else if options.json { try Output.json(results) }
        else { for result in results { try Output.write(result, json: false) } }
    }
}
struct RenameFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var name: String
    func run() throws {
        let backend = try options.writable(), folder = try SafetyExecutor.folder(ref, reader: backend.reader)
        let source = folder?.path.joined(separator: " > ") ?? ref
        let targetPath = Array(folder?.path.dropLast() ?? []) + [name]
        let plan = DryRunPlan(operation: "renameFolder", target: ref, arguments: ["name": name], resultingHTML: nil)
        if let result = try SafetyExecutor.run(options: write, operation: "renameFolder", arguments: ["ref": ref, "name": name],
            allowedPaths: [folder?.path, targetPath].compactMap { $0 }, destructive: false, plan: plan,
            action: { try backend.writer().renameFolder(source, name: name) }) { try Output.write(result, json: options.json) }
    }
}
struct DeleteFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Flag var yes = false
    @Option var expectCount: Int?
    func run() throws {
        let backend = try options.writable()
        guard let folder = try SafetyExecutor.folder(ref, reader: backend.reader) else { throw NotesError("folder_not_found", "Folder was not found.") }
        let writer = try backend.writer()
        let descendants: [Folder]
        let notes: [NoteSummary]
        if let scripting = writer as? ScriptingNotesWriter {
            let allActiveFolders = try scripting.listFoldersViaScripting()
            let activeFolders = allActiveFolders.filter { $0.path == folder.path }
            guard activeFolders.count == 1 else { throw NotesError("ambiguous_folder", "Folder must resolve uniquely in Notes.app.") }
            descendants = allActiveFolders.filter {
                $0.accountID == activeFolders[0].accountID && $0.path.starts(with: folder.path)
            }.map {
                Folder(id: $0.id, name: $0.path.last ?? "", accountID: $0.accountID, parentID: nil, path: $0.path,
                       isSmartFolder: false, isRecentlyDeleted: false, noteCount: 0)
            }
            let activeNotes = try scripting.listViaScripting().filter {
                $0.accountID == activeFolders[0].accountID && $0.folderPath.starts(with: folder.path)
            }
            notes = try activeNotes.map { try backend.reader.note($0.id).summary }
        } else {
            let matchingFolders = try backend.reader.folders(account: nil).filter { $0.accountID == folder.accountID && $0.path.starts(with: folder.path) }
            var foldersByPath: [String: Folder] = [:]
            for item in matchingFolders {
                let key = item.path.joined(separator: " > ")
                if foldersByPath[key] == nil || item.noteCount > foldersByPath[key]!.noteCount { foldersByPath[key] = item }
            }
            descendants = Array(foldersByPath.values)
            notes = try backend.reader.notes(NoteQuery(includeDeleted: false)).filter {
                $0.accountID == folder.accountID && $0.folderPath.starts(with: folder.path)
            }
        }
        if backend.isFake && expectCount == nil {
            if !write.dryRun { try confirm("Delete folder \(ref) and move its notes to Recently Deleted?", yes: yes) }
            let plan = DryRunPlan(operation: "deleteFolder", target: folder.path.joined(separator: " > "), arguments: [:], resultingHTML: nil)
            if let result = try SafetyExecutor.run(options: write, operation: "deleteFolder", arguments: ["ref": ref], allowedPaths: [folder.path],
                plan: plan, action: { try backend.writer().deleteFolder(ref) }) { try Output.write(result, json: options.json) }
            return
        }
        if !notes.isEmpty || descendants.count > 1 {
            guard let expectCount else { throw NotesError("folder_not_empty", "Non-empty folder deletion requires --expect-count \(notes.count).") }
            guard expectCount == notes.count else { throw NotesError("stale_folder", "Expected \(expectCount) notes but found \(notes.count).") }
        }
        if !write.dryRun { try confirm("Delete folder \(ref) and move \(notes.count) note(s) to Recently Deleted?", yes: yes) }
        if let scripting = writer as? ScriptingNotesWriter {
            try scripting.validateFolderDelete(folder.path.joined(separator: " > "), expectedCount: notes.count)
        }
        var plans: [DryRunPlan] = []
        for summary in notes {
            let note = try backend.reader.note(summary.id.uuid)
            let plan = DryRunPlan(operation: "deleteNote", target: summary.id.uuid, arguments: [:],
                                  resultingHTML: try SafetyExecutor.plannedHTML(note, backend: backend, write: write))
            var itemWrite = write
            itemWrite.idempotencyKey = write.idempotencyKey.map { "\($0):note:\(summary.id.uuid)" }
            _ = try SafetyExecutor.run(options: itemWrite, operation: "deleteNote", arguments: ["ref": summary.id.uuid], note: note,
                allowedPaths: [note.summary.folderPath], destructive: true,
                plan: plan, emitDryRun: false,
                action: { try writer.deleteNote(summary.id.uuid) })
            plans.append(plan)
        }
        for item in descendants.sorted(by: { $0.path.count > $1.path.count }) {
            let plan = DryRunPlan(operation: "deleteFolder", target: item.path.joined(separator: " > "), arguments: [:], resultingHTML: nil)
            var itemWrite = write
            itemWrite.idempotencyKey = write.idempotencyKey.map { "\($0):folder:\(item.path.joined(separator: ">"))" }
            let itemRef = item.path.joined(separator: " > ")
            if let result = try SafetyExecutor.run(options: itemWrite, operation: "deleteFolder", arguments: ["ref": itemRef], allowedPaths: [item.path],
                destructive: false, plan: plan, emitDryRun: false, action: { try writer.deleteFolder(itemRef) }), item.path == folder.path {
                try Output.write(result, json: options.json)
            }
            plans.append(plan)
        }
        if write.dryRun { try outputDryRunPlans(plans, json: options.json) }
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
