import ArgumentParser
import Foundation
import NotesAutomation
import NotesCore
import NotesNative
import NotesSafety
import NotesStore

struct WriteOptions: ParsableArguments {
    @Flag(help: "Print the operation and resulting HTML without writing.") var dryRun = false
    @Option(help: "Return the recorded result when this key is repeated.") var idempotencyKey: String?
    @Option(help: "Comma-separated folder trees allowed for writes.") var writeFolders: String?
    @Option(help: "Write only if the note's modified date equals this ISO 8601 value.") var ifModified: String?
    @Option(help: "Write only if the note revision equals this SHA-256 token.") var expectRevision: String?
    @Flag(help: "Permit an HTML body rewrite that can remove attachments.") var allowAttachmentLoss = false
    @Flag(help: "Permit a native write after Notes confirms shared-note write access.") var allowShared = false
    @Flag(help: "Wait for the new local note version to reach iCloud.") var waitSync = false
    @Option(help: "Seconds to wait with --wait-sync.") var syncTimeout: Double = 30

    func validate() throws {
        guard syncTimeout >= 0 else { throw ValidationError("--sync-timeout must be nonnegative.") }
    }
}

struct DryRunPlan: Codable {
    var dryRun = true
    var operation: String
    var target: String?
    var arguments: [String: String]
    var resultingHTML: String?
    var engine: String? = "scripting"
}

struct BatchItemResult: Codable {
    var ref: String
    var result: WriteResult?
    var error: NotesError?
    var engine: String = "scripting"
}

func selectedNotes(reader: any NotesReading, refs: [String], fromQuery: String?, folder: String?, account: String?, tag: String?, max: Int) throws -> [Note] {
    guard max >= 0 else { throw NotesError("invalid_max", "--max must be nonnegative.") }
    var notes = try refs.map { try reader.note($0) }
    if fromQuery != nil || folder != nil || account != nil || tag != nil {
        let summaries = try reader.notes(NoteQuery(folder: folder, account: account, text: fromQuery, tag: tag))
        notes += try summaries.map { try reader.note($0.id.uuid) }
    }
    var seen: Set<String> = []
    notes = notes.filter { seen.insert($0.summary.id.uuid).inserted }
    guard !notes.isEmpty else { throw NotesError("note_not_found", "No notes matched.") }
    guard notes.count <= max else { throw NotesError("max_exceeded", "Matched \(notes.count) notes; increase --max to proceed.") }
    return notes
}

func outputBatch(_ items: [BatchItemResult], json: Bool) throws {
    if json { try Output.json(items) }
    else { Output.table(["REF", "OUTCOME", "ID", "ERROR"], items.map {
        [$0.ref, $0.result?.outcome.rawValue ?? "failed", $0.result?.noteID?.uuid ?? "", $0.error?.description ?? ""]
    }) }
}

func outputDryRunPlans(_ plans: [DryRunPlan], json: Bool) throws {
    if json { try Output.json(plans) }
    else {
        for plan in plans {
            Output.table(["OPERATION", "TARGET", "RESULTING HTML"],
                         [[plan.operation, plan.target ?? "", plan.resultingHTML ?? ""]])
        }
    }
}

enum SafetyExecutor {
    static func allowlist(_ options: WriteOptions) -> WriteAllowlist {
        WriteAllowlist(options.writeFolders ?? ProcessInfo.processInfo.environment["NOTESCLI_WRITE_FOLDERS"])
    }

    static func run(options: WriteOptions, operation: String, arguments: [String: String], note: Note? = nil,
                    allowedPaths: [[String]] = [], destructive: Bool = false, plan: DryRunPlan, emitDryRun: Bool = true,
                    action: () throws -> WriteResult) throws -> WriteResult? {
        let guardrail = allowlist(options)
        if guardrail.isRestricted && allowedPaths.isEmpty {
            throw NotesError("write_not_allowed", "The target folder could not be resolved for the write allowlist.")
        }
        for path in allowedPaths { try guardrail.require(path) }
        if let note { try ConcurrencyGuard.require(note, ifModified: options.ifModified, expectRevision: options.expectRevision) }
        if let note, note.summary.isShared == true {
            guard options.allowShared else { throw NotesError("shared_write_refused", "The note is shared. Pass --allow-shared to confirm the write.") }
            guard plan.engine == "native" else {
                throw NotesError("native_required", "Shared-note writes require the native engine so Notes can check write permission.", hint: "Pass --engine native with --allow-shared.")
            }
        }
        if options.dryRun {
            if emitDryRun && CommandLine.arguments.contains("--json") { try Output.json(plan) }
            else if emitDryRun {
                Output.table(["FIELD", "VALUE"], [
                    ["operation", plan.operation], ["target", plan.target ?? ""],
                    ["arguments", arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")],
                    ["resulting_html", plan.resultingHTML ?? ""]])
            }
            return nil
        }
        if destructive, let note { _ = try SnapshotStore().save(note) }
        var recordedArguments = arguments.merging(["operation": operation]) { current, _ in current }
        if let note { recordedArguments["stable_id"] = note.summary.id.uuid }
        let data = try JSONSerialization.data(withJSONObject: recordedArguments, options: .sortedKeys)
        let journal = try WriteJournal()
        let begun = try journal.begin(operation: operation, arguments: data, idempotencyKey: options.idempotencyKey)
        if begun.replayed {
            if let result = begun.entry.result { return result }
            if begun.entry.outcome == .started || begun.entry.outcome == .unknown {
                return WriteResult(outcome: .unknown, noteID: begun.entry.noteID.map { NoteID(uuid: $0) },
                                   message: "The recorded operation has an unresolved outcome. Use notescli journal resolve.")
            }
            throw NotesError("idempotent_write_failed", begun.entry.message ?? "The recorded write failed.")
        }
        do {
            let started = Date().addingTimeInterval(-1)
            var result = try action()
            if result.operationID == nil { result.operationID = begun.entry.id }
            if options.waitSync, result.outcome == .verified, let noteID = result.noteID?.uuid, !noteID.isEmpty {
                result.syncPending = !((try? NoteSyncWaiter.wait(noteID: noteID, modifiedAfter: started, timeout: options.syncTimeout)) ?? false)
            }
            let outcome = JournalOutcome(rawValue: result.outcome.rawValue) ?? .failed
            let noteID = result.noteID.flatMap { $0.uuid.isEmpty ? $0.coreDataID : $0.uuid }
            try journal.finish(begun.entry.id, outcome: outcome, noteID: noteID, result: result, message: result.message)
            return result
        } catch {
            try? journal.finish(begun.entry.id, outcome: .failed, message: String(describing: error))
            throw error
        }
    }

    static func folder(_ ref: String?, reader: any NotesReading) throws -> Folder? {
        guard let ref else { return nil }
        let matches = try reader.folders(account: nil).filter {
            $0.id == ref || $0.coreDataID == ref || $0.name == ref || $0.path.joined(separator: " > ") == ref
        }
        if matches.count > 1 {
            let active = try ScriptingNotesWriter().listFoldersViaScripting().filter {
                $0.id == ref || $0.path.last == ref || $0.path.joined(separator: " > ") == ref
            }
            if active.count == 1, let match = matches.first(where: { $0.path == active[0].path }) {
                return match
            }
        }
        guard matches.count == 1 else {
            throw NotesError(matches.isEmpty ? "folder_not_found" : "ambiguous_folder", "Folder must resolve uniquely.")
        }
        return matches[0]
    }

    static func folderPath(_ ref: String?, reader: any NotesReading) throws -> [String]? {
        guard let ref else { return nil }
        if ref.contains(">") {
            let path = ref.split(separator: ">").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !path.isEmpty, !path.contains(where: \.isEmpty) else { throw NotesError("folder_not_found", "Folder path is invalid.") }
            return path
        }
        return try folder(ref, reader: reader)?.path
    }

    static func html(_ note: Note) -> String { note.document?.html(attachments: note.attachments) ?? "" }
    static func plannedHTML(_ note: Note, backend: Backends, write: WriteOptions) throws -> String {
        guard write.dryRun, !backend.isFake else { return html(note) }
        return try backend.writer().htmlBody(note.summary.id.uuid)
    }
    static func bodyHTML(title: String, markdown: String) -> String {
        "<h1>\(MarkdownToNotesHTML.escape(title))</h1>" + MarkdownToNotesHTML.convert(markdown).html
    }
    static func requireAttachmentSafety(_ note: Note, allowLoss: Bool) throws {
        if note.summary.attachmentCount > 0 && !allowLoss {
            throw NotesError("attachments_would_be_lost", "Editing through HTML could remove existing attachments; the note was not changed.")
        }
    }
}

private struct ExistsResponse: Codable { var exists: Bool; var id: String }

struct Exists: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    func run() throws {
        let note = try options.backends().reader.note(ref)
        if options.json { try Output.json(ExistsResponse(exists: true, id: note.summary.id.uuid)) }
        else { print(note.summary.id.uuid) }
    }
}

struct FolderExists: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "exists")
    @OptionGroup var options: GlobalOptions
    @Argument var path: String
    func run() throws {
        let backend = try options.backends()
        if backend.isFake {
            guard let folder = try SafetyExecutor.folder(path, reader: backend.reader) else {
                throw NotesError("folder_not_found", "Folder was not found.")
            }
            if options.json { try Output.json(ExistsResponse(exists: true, id: folder.id)) } else { print(folder.id) }
            return
        }
        let matches = try ScriptingNotesWriter().listFoldersViaScripting().filter {
            $0.id == path || $0.path.last == path || $0.path.joined(separator: " > ") == path
        }
        guard !matches.isEmpty else { throw NotesError("folder_not_found", "Folder was not found.") }
        guard matches.count == 1 else { throw NotesError("ambiguous_folder", "Folder must resolve uniquely.") }
        if options.json { try Output.json(ExistsResponse(exists: true, id: matches[0].id)) } else { print(matches[0].id) }
    }
}

struct JournalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "journal", subcommands: [JournalList.self, JournalResolve.self])
}
struct JournalList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var options: GlobalOptions
    @Option var limit = 100
    func run() throws {
        let items = try WriteJournal().list(limit: limit)
        if options.json { try Output.json(items) }
        else { Output.table(["OPERATION ID", "OP", "STARTED", "OUTCOME", "NOTE"], items.map {
            [$0.id, $0.operation, ISO8601DateFormatter().string(from: $0.started), $0.outcome.rawValue, $0.noteID ?? ""]
        }) }
    }
}
struct JournalResolve: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resolve")
    @OptionGroup var options: GlobalOptions
    @Argument var operationIDs: [String] = []
    func run() throws {
        let journal = try WriteJournal(), reader = try options.backends().reader
        let candidates = try journal.unresolved().filter { operationIDs.isEmpty || operationIDs.contains($0.id) }
        var settled: [JournalEntry] = []
        for entry in candidates {
            let args = (try? JSONSerialization.jsonObject(with: entry.arguments)) as? [String: Any] ?? [:]
            func argument(_ key: String) -> String? { args[key] as? String }
            guard let stableID = entry.stableDispatchIdentity else {
                settled.append(entry)
                continue
            }
            var verified = false
            var resolvedNoteID: String? = stableID
            let note = try? reader.note(stableID)
            if let note {
                let actual = note.document?.plainText(attachments: note.attachments) ?? ""
                let expected = MarkdownToNotesHTML.plainText(argument("body") ?? "")
                switch entry.operation {
                case "renameNote": verified = note.summary.title == argument("title")
                case "moveNote": verified = note.summary.folderPath.joined(separator: " > ") == argument("folder")
                case "deleteNote": verified = note.summary.isDeleted
                case "appendToNote", "prependToNote", "insertUnderHeading", "replaceSection": verified = actual.contains(expected)
                case "replaceBody":
                    let withoutTitle = actual.hasPrefix(note.summary.title + "\n") ? String(actual.dropFirst(note.summary.title.count + 1)) : actual
                    verified = withoutTitle.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines)
                case "replaceText": verified = actual.contains(argument("replacement") ?? "")
                default: break
                }
            } else if ["renameFolder", "moveFolder", "deleteFolder"].contains(entry.operation) {
                resolvedNoteID = nil
                let folders = (try? reader.folders(account: nil)) ?? []
                switch entry.operation {
                case "renameFolder":
                    verified = folders.contains { $0.id == stableID && $0.name == argument("name") }
                case "moveFolder":
                    let stableParentID = argument("stable_parent_id")
                    let parentID = stableParentID?.isEmpty == false ? stableParentID : nil
                    verified = folders.contains { $0.id == stableID && $0.parentID == parentID }
                case "deleteFolder":
                    verified = !folders.contains { $0.id == stableID }
                default: break
                }
            }
            let result = WriteResult(outcome: verified ? .verified : .unverified, noteID: resolvedNoteID.map { NoteID(uuid: $0) },
                                     message: verified ? "Resolved from a fresh snapshot." : "mismatch: the expected result was not present in a fresh snapshot")
            try journal.finish(entry.id, outcome: verified ? .verified : .unverified, noteID: resolvedNoteID, result: result, message: result.message)
            if let updated = try journal.list(limit: Int(Int32.max)).first(where: { $0.id == entry.id }) { settled.append(updated) }
        }
        if options.json { try Output.json(settled) }
        else { Output.table(["OPERATION ID", "OUTCOME", "NOTE"], settled.map { [$0.id, $0.outcome.rawValue, $0.noteID ?? ""] }) }
    }
}

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "history")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    func run() throws {
        let note = try options.backends().reader.note(ref), items = try SnapshotStore().history(note.summary.id.uuid)
        if options.json { try Output.json(items) }
        else { Output.table(["SNAPSHOT", "CREATED", "TITLE", "FOLDER", "RESTORABLE"], items.map {
            [$0.id, ISO8601DateFormatter().string(from: $0.created), $0.title, $0.folderPath.joined(separator: " > "), $0.restorable ? "yes" : "no"]
        }) }
    }
}

struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diff")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Argument var snapshot: String?
    func run() throws {
        let note = try options.backends().reader.note(ref)
        let old = try SnapshotStore().load(note.summary.id.uuid, snapshot: snapshot).markdown
        let current = note.document?.markdown(attachments: note.attachments) ?? ""
        if old == current { print("No changes") }
        else {
            print("--- snapshot\n+++ current")
            for line in old.split(separator: "\n", omittingEmptySubsequences: false) { print("-" + line) }
            for line in current.split(separator: "\n", omittingEmptySubsequences: false) { print("+" + line) }
        }
    }
}

private func restore(_ ref: String, snapshotID: String?, options: GlobalOptions, write: WriteOptions) throws {
    if let entry = try WriteJournal().entry(id: ref), let action = try entry.restoreAction() {
        guard snapshotID == nil else { throw NotesError("invalid_revert", "A journal operation ID cannot be combined with a snapshot ID.") }
        try restore(entry: entry, action: action, options: options, write: write)
        return
    }
    let backend = try options.writable(), current = try backend.reader.note(ref)
    try SafetyExecutor.requireAttachmentSafety(current, allowLoss: write.allowAttachmentLoss)
    let snapshot = try SnapshotStore().loadRestorable(current.summary.id.uuid, snapshot: snapshotID)
    let writer = try backend.writer(), target = current.summary.id.uuid
    let paths = [current.summary.folderPath, snapshot.note.summary.folderPath]
    let replacePlan = DryRunPlan(operation: "replaceBody", target: target, arguments: ["snapshot": snapshot.info.id],
                                 resultingHTML: SafetyExecutor.bodyHTML(title: snapshot.note.summary.title, markdown: snapshot.markdown))
    let renamePlan = current.summary.title == snapshot.note.summary.title ? nil :
        DryRunPlan(operation: "renameNote", target: target, arguments: ["title": snapshot.note.summary.title], resultingHTML: replacePlan.resultingHTML)
    let destination = snapshot.note.summary.folderPath.joined(separator: " > ")
    let movePlan = current.summary.folderPath == snapshot.note.summary.folderPath ? nil :
        DryRunPlan(operation: "moveNote", target: target, arguments: ["folder": destination], resultingHTML: replacePlan.resultingHTML)
    if write.dryRun {
        let plans = [replacePlan, renamePlan, movePlan].compactMap { $0 }
        for plan in plans {
            _ = try SafetyExecutor.run(options: write, operation: plan.operation,
                arguments: plan.arguments.merging(["ref": target]) { $1 }, note: current,
                allowedPaths: paths, destructive: true, plan: plan, emitDryRun: false, action: {
                    throw NotesError("dry_run_dispatched", "A dry-run attempted to dispatch a write.")
                })
        }
        try outputDryRunPlans(plans, json: options.json)
        return
    }
    var replaceWrite = write
    replaceWrite.idempotencyKey = write.idempotencyKey.map { "\($0):replace" }
    if let result = try SafetyExecutor.run(options: replaceWrite, operation: "replaceBody", arguments: ["ref": target, "snapshot": snapshot.info.id],
        note: current, allowedPaths: paths, destructive: true, plan: replacePlan,
        action: { try writer.replaceBody(target, markdown: snapshot.markdown, allowAttachmentLoss: write.allowAttachmentLoss) }) {
        try Output.write(result, json: options.json)
    }
    var followupWrite = write
    followupWrite.ifModified = nil
    followupWrite.expectRevision = nil
    if let renamePlan {
        followupWrite.idempotencyKey = write.idempotencyKey.map { "\($0):rename" }
        _ = try SafetyExecutor.run(options: followupWrite, operation: "renameNote", arguments: ["ref": target, "title": snapshot.note.summary.title],
            note: try backend.reader.note(target), allowedPaths: paths, destructive: true,
            plan: renamePlan,
            action: { try writer.renameNote(target, title: snapshot.note.summary.title) })
    }
    if let movePlan {
        followupWrite.idempotencyKey = write.idempotencyKey.map { "\($0):move" }
        _ = try SafetyExecutor.run(options: followupWrite, operation: "moveNote", arguments: ["ref": target, "folder": destination],
            note: try backend.reader.note(target), allowedPaths: paths, destructive: true,
            plan: movePlan,
            action: { try writer.moveNote(target, toFolder: destination) })
    }
}

private func restore(entry: JournalEntry, action: JournalRestoreAction, options: GlobalOptions, write: WriteOptions) throws {
    let backend = try options.writable()
    _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
    let writer = NativeNotesWriter()
    let target: String
    let paths: [[String]]
    switch action {
    case .checklistAutoSort:
        target = "Notes settings"; paths = []
    case .defaultAccount(let identifier):
        target = identifier; paths = []
    case .folderSort(let folderID, _, _), .smartFolderQuery(let folderID, _):
        let folder = try SafetyExecutor.folder(folderID, reader: backend.reader)
        guard let folder else { throw NotesError("folder_not_found", "The journal target folder was not found.") }
        target = folder.id; paths = [folder.path]
    }
    let arguments = ["operation_id": entry.id, "restored_operation": entry.operation, "engine": "native"]
    let plan = DryRunPlan(operation: "restoreJournalPreimage", target: target, arguments: arguments, resultingHTML: nil, engine: "native")
    var captured: NativeWriteResult?
    let result = try SafetyExecutor.run(options: write, operation: "restoreJournalPreimage", arguments: arguments,
                                        allowedPaths: paths, plan: plan) {
        let value: NativeWriteResult
        switch action {
        case .checklistAutoSort(let enabled):
            value = try writer.setChecklistAutoSort(enabled)
        case .folderSort(let folderID, let orderName, let directionName):
            guard let order = NativeFolderSortOrder(rawValue: orderName), let direction = NativeFolderSortDirection(rawValue: directionName) else {
                throw NotesError("invalid_journal", "The recorded folder sort preimage is invalid.")
            }
            value = try writer.setFolderSort(folderID, order: order, direction: direction)
        case .defaultAccount(let identifier):
            value = try writer.setDefaultAccount(identifier)
        case .smartFolderQuery(let folderID, let queryJSON):
            try SmartFolderQueryGrammar.validate(queryJSON)
            value = try writer.editSmartFolderRules(folderID, queryJSON: queryJSON, expectedCount: 1)
        }
        captured = value
        return value.writeResult
    }
    guard let result else { return }
    try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.operationID,
                                              verification: captured?.verification), options: options)
}

struct UndoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "undo")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    func run() throws { try restore(ref, snapshotID: nil, options: options, write: write) }
}
struct RevertCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revert")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var snapshot: String?
    func run() throws { try restore(ref, snapshotID: snapshot, options: options, write: write) }
}

private func bodyEdit(options: GlobalOptions, write: WriteOptions, ref: String, operation: String,
                      arguments: [String: String], resultingHTML: (Note, String) throws -> String,
                      action: (any NotesWriting) throws -> WriteResult) throws {
    let backend = try options.writable(), note = try backend.reader.note(ref), writer = try backend.writer()
    try SafetyExecutor.requireAttachmentSafety(note, allowLoss: write.allowAttachmentLoss)
    let sourceHTML = write.dryRun && !backend.isFake ? try writer.htmlBody(note.summary.id.uuid) : SafetyExecutor.html(note)
    let plannedHTML: String
    do { plannedHTML = try resultingHTML(note, sourceHTML) }
    catch {
        if write.dryRun { throw error }
        plannedHTML = SafetyExecutor.html(note)
    }
    let plan = DryRunPlan(operation: operation, target: note.summary.id.uuid, arguments: arguments,
                          resultingHTML: plannedHTML)
    if let result = try SafetyExecutor.run(options: write, operation: operation, arguments: arguments.merging(["ref": note.summary.id.uuid]) { $1 },
        note: note, allowedPaths: [note.summary.folderPath], destructive: true, plan: plan, action: { try action(writer) }) {
        try Output.write(result, json: options.json)
    }
}

private enum HTMLPlan {
    struct Heading { var level: Int; var text: String; var range: NSRange }
    static func headings(_ html: String) throws -> [Heading] {
        let expression = try NSRegularExpression(pattern: #"<h([1-6])\b[^>]*>(.*?)</h\1>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let fullRange = NSRange(html.startIndex..., in: html)
        var matches: [Heading] = expression.matches(in: html, range: fullRange).compactMap { match in
            guard let levelRange = Range(match.range(at: 1), in: html), let bodyRange = Range(match.range(at: 2), in: html), let level = Int(html[levelRange]) else { return nil }
            return Heading(level: level, text: MarkdownToNotesHTML.plainText(html: String(html[bodyRange])), range: match.range)
        }
        let blocks = try NSRegularExpression(pattern: #"<div\b[^>]*>(.*?)</div>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let sizes = try NSRegularExpression(pattern: #"font-size:\s*([0-9]+(?:\.[0-9]+)?)px"#, options: .caseInsensitive)
        for block in blocks.matches(in: html, range: fullRange) {
            guard let bodyRange = Range(block.range(at: 1), in: html) else { continue }
            let body = String(html[bodyRange])
            guard body.range(of: #"<b\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let match = sizes.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let range = Range(match.range(at: 1), in: body), let size = Double(body[range]) else { continue }
            matches.append(Heading(level: size >= 22 ? 1 : size >= 17 ? 2 : 3,
                                   text: MarkdownToNotesHTML.plainText(html: body), range: block.range))
        }
        return matches.sorted { $0.range.location < $1.range.location }
    }
    static func prepend(_ current: String, markdown: String) throws -> String {
        let addition = MarkdownToNotesHTML.convert(markdown).html
        let titleRange = try headings(current).first(where: { $0.level == 1 }).flatMap { Range($0.range, in: current) }
        let index = current.range(of: "</h1>", options: .caseInsensitive)?.upperBound ?? titleRange?.upperBound ?? current.startIndex
        return String(current[..<index]) + addition + String(current[index...])
    }
    static func insert(_ current: String, heading: String, markdown: String) throws -> String {
        guard let match = try headings(current).first(where: { $0.text == heading }), let range = Range(match.range, in: current) else {
            throw NotesError("heading_not_found", "Heading \(heading) was not found.")
        }
        return String(current[..<range.upperBound]) + MarkdownToNotesHTML.convert(markdown).html + String(current[range.upperBound...])
    }
    static func section(_ current: String, heading: String, markdown: String) throws -> String {
        let found = try headings(current)
        guard let index = found.firstIndex(where: { $0.text == heading }), let range = Range(found[index].range, in: current) else {
            throw NotesError("heading_not_found", "Heading \(heading) was not found.")
        }
        let endLocation = found.dropFirst(index + 1).first(where: { $0.level <= found[index].level })?.range.lowerBound ?? current.utf16.count
        guard let end = Range(NSRange(location: endLocation, length: 0), in: current)?.lowerBound else { throw NotesError("invalid_note_html", "The section range was invalid.") }
        return String(current[..<range.upperBound]) + MarkdownToNotesHTML.convert(markdown).html + String(current[end...])
    }
    static func replace(_ current: String, find: String, replacement: String) throws -> String {
        let needle = MarkdownToNotesHTML.escape(find)
        guard current.contains(needle) else { throw NotesError("text_not_found", "The requested text was not found in one HTML text run.") }
        return current.replacingOccurrences(of: needle, with: MarkdownToNotesHTML.escape(replacement))
    }
}

struct PrependCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prepend")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Option var body: String?; @Flag var stdin = false
    func validate() throws { try validateBodySources(body: body, stdin: stdin) }
    func run() throws {
        let markdown = try inputBody(body: body, stdin: stdin)
        try bodyEdit(options: options, write: write, ref: ref, operation: "prependToNote", arguments: ["body": markdown], resultingHTML: { _, html in try HTMLPlan.prepend(html, markdown: markdown) }) {
            try $0.prependToNote(ref, markdown: markdown, allowAttachmentLoss: write.allowAttachmentLoss)
        }
    }
}
struct InsertUnderHeadingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "insert-under-heading")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var heading: String; @Option var body: String?; @Flag var stdin = false
    func validate() throws { try validateBodySources(body: body, stdin: stdin) }
    func run() throws {
        let markdown = try inputBody(body: body, stdin: stdin)
        try bodyEdit(options: options, write: write, ref: ref, operation: "insertUnderHeading", arguments: ["heading": heading, "body": markdown], resultingHTML: { _, html in try HTMLPlan.insert(html, heading: heading, markdown: markdown) }) {
            try $0.insertUnderHeading(ref, heading: heading, markdown: markdown, allowAttachmentLoss: write.allowAttachmentLoss)
        }
    }
}
struct ReplaceSectionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "replace-section")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var heading: String; @Option var body: String?; @Flag var stdin = false
    func validate() throws { try validateBodySources(body: body, stdin: stdin) }
    func run() throws {
        let markdown = try inputBody(body: body, stdin: stdin)
        try bodyEdit(options: options, write: write, ref: ref, operation: "replaceSection", arguments: ["heading": heading, "body": markdown], resultingHTML: { _, html in try HTMLPlan.section(html, heading: heading, markdown: markdown) }) {
            try $0.replaceSection(ref, heading: heading, markdown: markdown, allowAttachmentLoss: write.allowAttachmentLoss)
        }
    }
}
struct ReplaceTextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "replace-text")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var find: String; @Argument var replacement: String
    func run() throws {
        try bodyEdit(options: options, write: write, ref: ref, operation: "replaceText", arguments: ["find": find, "replacement": replacement], resultingHTML: { _, html in try HTMLPlan.replace(html, find: find, replacement: replacement) }) {
            try $0.replaceText(ref, find: find, replacement: replacement, allowAttachmentLoss: write.allowAttachmentLoss)
        }
    }
}

struct MoveFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var parent: String?; @Option var account: String?
    func run() throws {
        try unifiedNativeFolderMove(options: options, write: write, ref: ref, parent: parent)
    }
}

struct ClipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clip")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var url: String; @Option var folder: String?
    func run() throws {
        guard let source = URL(string: url), ["http", "https"].contains(source.scheme?.lowercased() ?? "") else {
            throw NotesError("invalid_url", "Clip accepts only HTTP and HTTPS URLs.")
        }
        let clip = try WebPageClipper.fetch(source)
        let backend = try options.writable(), targetPath = try SafetyExecutor.folderPath(folder, reader: backend.reader)
        let paths = targetPath.map { [$0] } ?? []
        let plan = DryRunPlan(operation: "clip", target: source.absoluteString, arguments: ["folder": folder ?? ""],
                              resultingHTML: SafetyExecutor.bodyHTML(title: clip.title, markdown: clip.markdown))
        if let result = try SafetyExecutor.run(options: write, operation: "clip", arguments: ["url": url, "title": clip.title, "body": clip.markdown, "folder": folder ?? ""],
            allowedPaths: paths, plan: plan,
            action: { try backend.writer().createNote(title: clip.title, markdown: clip.markdown, folder: folder) }) {
            try Output.write(result, json: options.json)
        }
    }
}
