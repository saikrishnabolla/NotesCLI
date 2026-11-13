import ArgumentParser
@preconcurrency import Dispatch
import Foundation
import NotesCore
import NotesMCP
import NotesAutomation
import NotesNative
import NotesSafety
import NotesHost
import Darwin

@main
struct NotesCLI: ParsableCommand {
    nonisolated(unsafe) private static var hostParentMonitor: DispatchSourceProcess?
    static let version = notesCLIVersion
    static let configuration = CommandConfiguration(commandName: "notescli", abstract: "Read and manage Apple Notes.", version: version, subcommands: [Accounts.self, Folders.self, ReadList.self, Show.self, IndexedSearch.self, Tags.self, Recent.self, Pinned.self, Capabilities.self, HelpAlias.self, Add.self, Append.self, Edit.self, Rename.self, Move.self, Delete.self, FolderCommand.self, Export.self, FileCommand.self, Open.self, SyncCommand.self, SyncDaemonCommand.self, WatchCommand.self, EngineCommand.self, ChecklistCommand.self, PinCommand.self, UnpinCommand.self, TagCommand.self, LinkCommand.self, DeepLink.self, TextCommand.self, FormatCommand.self, AttachCommand.self, AttachmentsCommand.self, AttachmentCommand.self, ReadTableCommand.self, DuplicateCommand.self, RestoreCommand.self, WriteMarkdownCommand.self, NativeDoctor.self, NativeChecklist.self, NativePin.self, NativeTag.self, NativeLink.self, NativeText.self, NativeFormat.self, NativeAttachment.self, NativeTableCommand.self, NativeDuplicate.self, NativeRestore.self, NativeMoveFolder.self, NativeWriteMarkdown.self, Fetch.self, IndexCommand.self, Stats.self, Count.self, ShowMany.self, Selection.self, Backlinks.self, Raw.self, Deleted.self, SmartFolders.self, PrependCommand.self, InsertUnderHeadingCommand.self, ReplaceSectionCommand.self, ReplaceTextCommand.self, ClipCommand.self, Exists.self, HistoryCommand.self, DiffCommand.self, UndoCommand.self, RevertCommand.self, JournalCommand.self, SmartFolderCommand.self, DrawingCommand.self, DiagramCommand.self, RecordingCommand.self, SpeechHelperCommand.self, Doctor.self, Setup.self, Permissions.self, MCPRoot.self, Completion.self, AnchorCommand.self, WaitSyncCommand.self, HostCommand.self, UninstallCommand.self])
    @OptionGroup var options: GlobalOptions
    @Flag(name: .customLong("no-recent"), help: "Hide recently edited titles on the home screen. Also set by NOTESCLI_HOME_RECENT=0.")
    var noRecent = false

    func run() throws { try HomeScreen.run(options: options, noRecent: noRecent) }

    static var namedSubcommands: [(String, ParsableCommand.Type)] {
        configuration.subcommands.map { type in
            (type.configuration.commandName ?? String(describing: type).lowercased(), type)
        }
    }

    static func suggestion(for message: String) -> String? {
        let prefix = "Unexpected argument '"
        guard let start = message.range(of: prefix), let end = message[start.upperBound...].firstIndex(of: "'") else { return nil }
        let value = String(message[start.upperBound..<end])
        guard let suggestion = namedSubcommands.map(\.0).min(by: { FuzzySearch.distance(value, $0) < FuzzySearch.distance(value, $1) }),
              FuzzySearch.distance(value, suggestion) <= 3 else { return nil }
        return "Did you mean '\(suggestion)'?"
    }

    static func main() {
        do {
            if shouldUseCapabilityHost() {
                Darwin.exit(try CapabilityHostClient.run(arguments: Array(CommandLine.arguments.dropFirst())))
            }
            startHostParentMonitor()
            var command = try parseAsRoot()
            try command.run()
        }
        catch {
            if let e = error as? NotesError { fail(e) }
            let code = exitCode(for: error).rawValue
            if code == 0 { exit(withError: error) }
            let shortMessage = message(for: error)
            let hint = suggestion(for: shortMessage)
            if CommandLine.arguments.contains("--json") {
                fail(NotesError(code == 64 ? "usage" : "error", shortMessage, hint: hint), status: code == 64 ? 2 : 1)
            }
            let diagnostic = fullMessage(for: error) + (hint.map { "\n  \($0)" } ?? "")
            FileHandle.standardError.write(Data((diagnostic + "\n").utf8))
            Darwin.exit(code == 64 ? 2 : 1)
        }
    }

    private static func startHostParentMonitor() {
        guard ProcessInfo.processInfo.environment["NOTESCLI_HOST_ACTIVE"] == "1" else { return }
        let parent = getppid()
        guard parent > 1 else { Darwin.exit(70) }
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        source.setEventHandler {
            Darwin.signal(SIGTERM, SIG_IGN)
            _ = kill(-getpgrp(), SIGTERM)
            usleep(500_000)
            _ = kill(-getpgrp(), SIGKILL)
            Darwin._exit(70)
        }
        hostParentMonitor = source
        source.resume()
    }

    private static func shouldUseCapabilityHost() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["NOTESCLI_HOST_ACTIVE"] == "1" { return false }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if requestedBackend(arguments: arguments, environment: environment) == "fake" { return false }
        let route = CapabilityHostRoute(rawValue: environment["NOTESCLI_CAPABILITY_HOST"] ?? "auto") ?? .auto
        if route == .direct { return false }
        if arguments.contains("--help") || arguments.contains("-h") || arguments.contains("--version") {
            return false
        }
        if CapabilityHostPolicy.commandIndex(arguments).map({ arguments[$0] }) == "doctor" { return false }
        guard CapabilityHostPolicy.commandIndex(arguments) != nil else {
            return CapabilityHostPolicy.allows(arguments) && (route == .force || CapabilityHostClient.isAvailable())
        }
        guard CapabilityHostPolicy.allows(arguments) else { return false }
        return route == .force || CapabilityHostClient.isAvailable()
    }

    private static func requestedBackend(arguments: [String], environment: [String: String]) -> String {
        for (index, argument) in arguments.enumerated() {
            if argument == "--backend", arguments.indices.contains(index + 1) { return arguments[index + 1] }
            if argument.hasPrefix("--backend=") { return String(argument.dropFirst("--backend=".count)) }
        }
        return environment["NOTESCLI_BACKEND"] ?? "default"
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
    @OptionGroup var write: WriteOptions
    @Option var setDefault: String?
    func run() throws {
        if let setDefault { try UnifiedNative.defaultAccount(options, write, ref: setDefault); return }
        let backend = try options.backends(), rows = try backend.reader.accounts()
        if options.json { try Output.readJSON(rows, backend: backend) }
        else {
            Output.table(["ID", "NAME", "KIND", "DEFAULT", "DEFAULT FOLDER"], rows.map { [$0.id, $0.name, $0.kind, $0.isDefault ? "yes" : "", $0.defaultFolderName ?? ""] })
            Output.fidelityNotice(backend)
        }
    }
}
struct Folders: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Option var account: String?
    @Flag var tree = false
    func run() throws {
        let backend = try options.backends(), rows = try backend.reader.folders(account: account)
        if options.json { try Output.readJSON(rows, backend: backend) }
        else {
            Output.table(["ID", "FOLDER", "NOTES"], rows.map { [$0.id, tree ? String(repeating: "  ", count: max(0, $0.path.count - 1)) + $0.name : $0.path.joined(separator: " > "), String($0.noteCount)] })
            Output.fidelityNotice(backend)
        }
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
enum NoteFormat: String, ExpressibleByArgument { case markdown, text, html, json, outline }
struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(discussion: """
        EXAMPLES:
          notescli show '#8800'
          notescli show '#8800' --format json
        """)
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Option var format: NoteFormat = .markdown
    @Flag var noAttachments = false
    func run() throws {
        let backend = try options.backends(), note = try backend.reader.note(ref)
        if format == .outline {
            let outline = note.document?.outline() ?? []
            if options.json { try Output.readJSON(outline, backend: backend) }
            else if !options.quiet { print(String(decoding: try NotePresentation.json(outline), as: UTF8.self)) }
            if !options.json { Output.fidelityNotice(backend) }
        } else if options.json, backend.fidelity == .limited {
            var value = note
            if noAttachments { value.attachments = [] }
            try Output.readJSON(value, backend: backend)
        } else if !options.quiet || options.json {
            print(try NotePresentation.render(note, format: options.json ? "json" : format.rawValue, attachments: !noAttachments))
            if !options.json { Output.fidelityNotice(backend) }
        }
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
    static let configuration = CommandConfiguration(discussion: """
        EXAMPLES:
          notescli recent 5
          notescli recent 20 --json
        """)
    @OptionGroup var options: GlobalOptions
    @Argument var n: Int?
    @Option var limit: Int?
    func validate() throws {
        if n != nil, limit != nil { throw ValidationError("Choose N or --limit, not both.") }
        try positive(n ?? limit, name: "limit")
    }
    func run() throws { try Output.notes(options.backends().reader.notes(NoteQuery(limit: n ?? limit ?? 10)), json: options.json) }
}
struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(discussion: """
        EXAMPLES:
          notescli add "Research brief" --body "# Findings"
          notescli add "Research brief" --file report.md
        """)
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var title: String = "Untitled"
    @Option var folder: String?
    @Option var body: String?
    @Flag var stdin = false
    @Option var file: String?
    @Option(name: .long, parsing: .upToNextOption) var attach: [String] = []
    func validate() throws { try validateBodySources(body: body, stdin: stdin, file: file, allowEditor: true) }
    func run() throws {
        let backend = try options.writable()
        let markdown = try inputBody(body: body, stdin: stdin, file: file, allowEditor: true)
        if !attach.isEmpty { try writeExtraCreate(options: options, write: write, title: title, folder: folder, markdown: markdown, paths: attach); return }
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
        let selected = try UnifiedNative.engine(options, scriptingAvailable: true, fake: backend.isFake)
        if selected == .scripting {
            try SnapshotRestorePolicy.requireScriptingBodyRewriteAllowed(note, allowDowngrade: write.allowDowngrade)
        }
        if selected == .scripting, note.summary.attachmentCount > 0 {
            throw NotesError("attachments_would_be_lost", "Appending through HTML could remove existing attachments; the note was not changed.")
        }
        let markdown = try inputBody(body: body, stdin: stdin)
        let currentHTML = try SafetyExecutor.plannedHTML(note, backend: backend, write: write)
        let plan = DryRunPlan(operation: "appendToNote", target: note.summary.id.uuid, arguments: ["body": markdown],
                              resultingHTML: currentHTML + MarkdownToNotesHTML.convert(markdown).html, engine: selected.rawValue)
        var native: NativeWriteResult?
        if let result = try SafetyExecutor.run(options: write, operation: "appendToNote", arguments: ["ref": note.summary.id.uuid, "body": markdown],
            note: note, allowedPaths: [note.summary.folderPath], plan: plan,
            action: {
                switch selected {
                case .scripting: return try backend.writer().appendToNote(note.summary.id.uuid, markdown: markdown)
                case .native:
                    let value = try NativeNotesWriter().appendMarkdown(note.summary.id.uuid, markdown: markdown, allowShared: write.allowShared)
                    native = value; return value.writeResult
                }
            }) {
            try outputEngineWrite(EngineWriteResponse(engine: selected.rawValue, result: result, operationID: native?.operationID,
                                                      verification: native?.verification), options: options)
        }
    }
}
struct Edit: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    func run() throws {
        try writeExtraEdit(options: options, write: write, ref: ref)
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
    static let configuration = CommandConfiguration(commandName: "folder", subcommands: [CreateFolder.self, RenameFolder.self, MoveFolder.self, DeleteFolder.self, FolderExists.self, FolderSortCommand.self])
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
        var currentParentPath = resolvedParent?.path.joined(separator: " > ")
        var currentParentRef = backend.isFake ? currentParentPath : resolvedParent?.coreDataID
        var currentPath = resolvedParent?.path ?? []
        var activePaths = try (writer as? ScriptingNotesWriter).map {
            Set(try $0.listFoldersViaScripting().map { $0.path.joined(separator: " > ") })
        }
        if resolvedParent != nil, currentParentRef == nil {
            throw NotesError("stale_folder", "The parent folder has no stable Notes.app identity.")
        }
        if let currentParentPath, let activePaths, !activePaths.contains(currentParentPath) {
            throw NotesError("folder_not_found", "The parent folder does not exist in Notes.app.")
        }
        var results: [WriteResult] = []
        var plans: [DryRunPlan] = []
        for component in components {
            let path = currentPath + [component]
            let pathRef = path.joined(separator: " > ")
            let exists = activePaths?.contains(pathRef) ?? ((try? SafetyExecutor.folder(pathRef, reader: backend.reader)) != nil)
            if exists {
                let existing = try SafetyExecutor.folder(pathRef, reader: backend.reader)
                currentParentPath = pathRef
                currentParentRef = backend.isFake ? pathRef : existing?.coreDataID
                guard currentParentRef != nil else { throw NotesError("stale_folder", "The existing folder has no stable Notes.app identity.") }
                currentPath = path
                continue
            }
            let plan = DryRunPlan(operation: "createFolder", target: path.joined(separator: " > "), arguments: ["name": component], resultingHTML: nil)
            var itemWrite = write
            itemWrite.idempotencyKey = write.idempotencyKey.map { "\($0):\(path.joined(separator: ">"))" }
            if let result = try SafetyExecutor.run(options: itemWrite, operation: "createFolder", arguments: ["name": component, "parent": currentParentRef ?? "", "account": account ?? ""],
                allowedPaths: [path], plan: plan, emitDryRun: false,
                action: { try writer.createFolder(name: component, parent: currentParentRef, account: account) }) {
                results.append(result)
                currentParentPath = pathRef
                currentParentRef = backend.isFake ? pathRef : result.folderID
                activePaths?.insert(pathRef)
            }
            plans.append(plan)
            if write.dryRun {
                currentParentPath = pathRef
                currentParentRef = pathRef
            }
            currentPath = path
        }
        if write.dryRun { try outputDryRunPlans(plans, json: options.json) }
        else if options.json { try Output.json(results.map { EngineWriteResponse(engine: "scripting", result: $0) }) }
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
        if let result = try SafetyExecutor.run(options: write, operation: "renameFolder", arguments: ["ref": ref, "name": name, "stable_id": folder?.id ?? ""],
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
        // Identify the subtree by stable ids and parent links, never by path: Notes allows
        // sibling folders with the same name, so paths are ambiguous.
        var allFolders = try backend.reader.folders(account: nil)
        var activeNoteIDs: Set<String>?
        if let scripting = writer as? ScriptingNotesWriter, let coreDataID = folder.coreDataID {
            let active = try scripting.listFoldersViaScripting()
            guard active.contains(where: { $0.id == coreDataID }) else {
                throw NotesError("folder_not_found", "Notes.app does not show this folder.")
            }
            let activeIDs = Set(active.map(\.id))
            allFolders.removeAll { item in
                guard let id = item.coreDataID else { return true }
                return !activeIDs.contains(id)
            }
            activeNoteIDs = Set(try scripting.listViaScripting().map(\.id))
        }
        var subtreeIDs: Set<String> = [folder.id]
        var grew = true
        while grew {
            grew = false
            for item in allFolders where !subtreeIDs.contains(item.id) {
                if let parent = item.parentID, subtreeIDs.contains(parent) { subtreeIDs.insert(item.id); grew = true }
            }
        }
        let descendants = allFolders.filter { subtreeIDs.contains($0.id) }
        let notes = try backend.reader.notes(NoteQuery(includeDeleted: false)).filter { summary in
            guard subtreeIDs.contains(summary.folderID ?? "") else { return false }
            guard let activeNoteIDs else { return true }
            guard let id = summary.id.coreDataID else { return false }
            return activeNoteIDs.contains(id)
        }
        if backend.isFake && expectCount == nil {
            if !write.dryRun { try confirm("Delete folder \(ref) and move its notes to Recently Deleted?", yes: yes) }
            let plan = DryRunPlan(operation: "deleteFolder", target: folder.path.joined(separator: " > "), arguments: [:], resultingHTML: nil)
            if let result = try SafetyExecutor.run(options: write, operation: "deleteFolder", arguments: ["ref": ref, "stable_id": folder.id], allowedPaths: [folder.path],
                plan: plan, action: { try backend.writer().deleteFolder(ref) }) { try Output.write(result, json: options.json) }
            return
        }
        if !notes.isEmpty || descendants.count > 1 {
            guard let expectCount else { throw NotesError("folder_not_empty", "Non-empty folder deletion requires --expect-count \(notes.count).") }
            guard expectCount == notes.count else { throw NotesError("stale_folder", "Expected \(expectCount) notes but found \(notes.count).") }
        }
        if !write.dryRun { try confirm("Delete folder \(ref) and move \(notes.count) note(s) to Recently Deleted?", yes: yes) }
        if let scripting = writer as? ScriptingNotesWriter {
            try scripting.validateFolderDelete(folder.coreDataID ?? folder.path.joined(separator: " > "), expectedCount: notes.count)
        }
        let allowedFolderIDs = descendants.compactMap(\.coreDataID)
        if writer is ScriptingNotesWriter, allowedFolderIDs.count != descendants.count {
            throw NotesError("stale_folder", "The folder subtree could not be resolved to stable Notes.app folder identities.")
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
                action: {
                    if let scripting = writer as? ScriptingNotesWriter {
                        return try scripting.deleteNote(summary.id.uuid, allowedFolderIDs: allowedFolderIDs)
                    }
                    return try writer.deleteNote(summary.id.uuid)
                })
            plans.append(plan)
        }
        for item in descendants.sorted(by: { $0.path.count > $1.path.count }) {
            let plan = DryRunPlan(operation: "deleteFolder", target: item.path.joined(separator: " > "), arguments: [:], resultingHTML: nil)
            var itemWrite = write
            itemWrite.idempotencyKey = write.idempotencyKey.map { "\($0):folder:\(item.path.joined(separator: ">"))" }
            let itemRef = backend.isFake ? item.path.joined(separator: " > ") : (item.coreDataID ?? item.path.joined(separator: " > "))
            if let result = try SafetyExecutor.run(options: itemWrite, operation: "deleteFolder", arguments: ["ref": itemRef, "stable_id": item.id], allowedPaths: [item.path],
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
    @Flag var folder = false
    @Flag var account = false
    @Option var attachment: String?
    @Flag var reveal = false
    func validate() throws {
        if [folder, account, attachment != nil].filter({ $0 }).count > 1 { throw ValidationError("Choose one of --folder, --account, or --attachment.") }
        if reveal && attachment == nil { throw ValidationError("--reveal requires --attachment.") }
    }
    func run() throws {
        let backend = try options.backends()
        let opened: String
        if account {
            let matches = try backend.reader.accounts().filter { $0.id.caseInsensitiveCompare(ref) == .orderedSame || $0.name == ref }
            guard matches.count == 1 else { throw NotesError(matches.isEmpty ? "account_not_found" : "ambiguous_account", "Account must resolve uniquely.") }
            if !backend.isFake { try ReadOpen.account(matches[0]) }; opened = matches[0].id
        } else if folder {
            let matches = try backend.reader.folders(account: nil).filter { $0.id.caseInsensitiveCompare(ref) == .orderedSame || $0.name == ref || $0.path.joined(separator: " > ") == ref }
            guard matches.count == 1 else { throw NotesError(matches.isEmpty ? "folder_not_found" : "ambiguous_folder", "Folder must resolve uniquely.") }
            if !backend.isFake { try ReadOpen.folder(matches[0]) }; opened = matches[0].id
        } else if let attachment {
            let matches = try backend.reader.attachments(ref).filter { $0.id.caseInsensitiveCompare(attachment) == .orderedSame }
            guard matches.count == 1 else { throw NotesError("attachment_not_found", "No attachment matches the id.") }
            if !backend.isFake { try ReadOpen.attachment(matches[0], reveal: reveal) }; opened = matches[0].id
        } else {
            let note = try backend.reader.note(ref); try backend.openNote(note.summary.id); opened = note.summary.id.shortID ?? note.summary.id.uuid
        }
        if options.json { try Output.json(["opened": opened]) } else if !options.quiet { print("Opened \(opened)") }
    }
}
struct Completion: ParsableCommand {
    @Argument var shell: String = "zsh"
    func run() throws {
        guard let shell = CompletionShell(rawValue: shell) else { throw ValidationError("Use bash, zsh, or fish.") }
        print(NotesCLI.completionScript(for: shell))
    }
}
