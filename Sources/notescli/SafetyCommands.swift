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
    @Flag(help: "Permit a scripting body rewrite to convert native-only note features.") var allowDowngrade = false
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
                    allowedPaths: [[String]] = [], destructive: Bool = true, plan: DryRunPlan, emitDryRun: Bool = true,
                    capturePrivatePayloads: Bool = true,
                    finishArguments: (() -> [String: String])? = nil,
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
            if destructive, let note {
                let drawingPayloads = capturePrivatePayloads && plan.engine == "native" && note.attachments.contains(where: { $0.kind == "drawing" })
                    ? try NativeNotesWriter().snapshotDrawingPayloads(note.summary.id.uuid) : [:]
                let scanMarkupPayloads = capturePrivatePayloads && plan.engine == "native"
                    && note.attachments.contains(where: { $0.kind == "scan" || ($0.markupDataBytes ?? 0) > 0 })
                    ? try SQLiteNotesStore(refresh: true).scanMarkupPayloads(note.summary.id.uuid) : [:]
                let paperBundlePayloads = capturePrivatePayloads && plan.engine == "native"
                    && note.attachments.contains(where: { $0.typeUTI.lowercased().contains("paper") })
                    ? try NativeNotesWriter().snapshotPaperBundlePayloads(note.summary.id.uuid) : [:]
                let linkPayloads = capturePrivatePayloads && plan.engine == "native"
                    && note.attachments.contains(where: {
                        $0.url != nil || ($0.synapseDataBytes ?? 0) > 0 || ($0.linkPreviewMetadataBytes ?? 0) > 0
                    }) ? try NativeNotesWriter().snapshotLinkPayloads(note.summary.id.uuid) : [:]
                recordedArguments["snapshot_id"] = try SnapshotStore().save(
                    note, drawingPayloads: drawingPayloads, paperBundlePayloads: paperBundlePayloads,
                    linkPayloads: linkPayloads,
                    scanMarkupPayloads: scanMarkupPayloads
                ).id
                let snapshotArguments = try JSONSerialization.data(withJSONObject: recordedArguments, options: .sortedKeys)
                try journal.updateRecordedArguments(begun.entry.id, arguments: snapshotArguments)
            }
            let started = Date().addingTimeInterval(-1)
            var result = try action()
            var undoMetadataChanged = false
            if let extra = finishArguments?(), !extra.isEmpty {
                recordedArguments.merge(extra) { _, new in new }
                undoMetadataChanged = true
            }
            if let note,
               let current = try? SQLiteNotesStore(refresh: true).note(note.summary.id.uuid) {
                recordedArguments["post_revision"] = ConcurrencyGuard.revision(current)
                undoMetadataChanged = true
            }
            if undoMetadataChanged {
                do {
                    let finalArguments = try JSONSerialization.data(withJSONObject: recordedArguments, options: .sortedKeys)
                    try journal.updateRecordedArguments(begun.entry.id, arguments: finalArguments)
                } catch {
                    let warning = "The write succeeded, but its undo metadata could not be completed."
                    result.message = [result.message, warning].compactMap { $0 }.joined(separator: " ")
                }
            }
            if result.operationID == nil { result.operationID = begun.entry.id }
            result.journalID = begun.entry.id
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
        let items = try WriteJournal.openReadOnlyIfExists()?.list(limit: limit) ?? []
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
        _ = try options.writable()
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
        print(SnapshotLineDiff.unified(snapshot: old, current: current))
    }
}

private func restore(_ ref: String, snapshotID: String?, options: GlobalOptions, write: WriteOptions) throws {
    let backend = try options.writable()
    var targetRef = ref
    var selectedSnapshotID = snapshotID
    if let entry = try WriteJournal.openReadOnlyIfExists()?.entry(id: ref) {
        guard snapshotID == nil else { throw NotesError("invalid_revert", "A journal operation ID cannot be combined with a snapshot ID.") }
        guard entry.outcome == .verified else {
            throw NotesError("unsafe_undo", "Only a verified journal operation can be undone automatically.")
        }
        if let action = try entry.restoreAction() {
            try restore(entry: entry, action: action, options: options, write: write)
            return
        }
        guard let noteID = entry.noteID ?? entry.stableDispatchIdentity, !noteID.isEmpty else {
            throw NotesError("journal_preimage_missing", "Journal operation \(entry.id) has no note identity.")
        }
        guard let snapshotID = entry.snapshotID else {
            throw NotesError("journal_snapshot_missing", "Journal operation \(entry.id) is not paired with an exact snapshot; refusing a broader undo.")
        }
        guard let postRevision = entry.postRevision else {
            throw NotesError("journal_post_state_missing", "Journal operation \(entry.id) has no verified post-write revision; refusing unsafe undo.")
        }
        let current = try backend.reader.note(noteID)
        guard ConcurrencyGuard.revision(current) == postRevision else {
            throw NotesError("undo_conflict", "The note changed after journal operation \(entry.id); refusing to overwrite later edits.")
        }
        targetRef = noteID
        selectedSnapshotID = snapshotID
    }
    let current = try backend.reader.note(targetRef)
    let snapshot = try SnapshotStore().loadRestorable(current.summary.id.uuid, snapshot: selectedSnapshotID)
    let selected = try UnifiedNative.engine(options, scriptingAvailable: true, fake: backend.isFake)
    if selected == .scripting {
        try SnapshotRestorePolicy.requireScriptingRestoreAllowed(snapshot.note, allowDowngrade: write.allowDowngrade)
        try SafetyExecutor.requireAttachmentSafety(current, allowLoss: write.allowAttachmentLoss || write.allowDowngrade)
    }
    let scriptingWriter = try backend.writer(), target = current.summary.id.uuid
    let paths = [current.summary.folderPath, snapshot.note.summary.folderPath]
    let restoreOperation = selected == .native ? "restoreSnapshot" : "replaceBody"
    let replacePlan = DryRunPlan(operation: restoreOperation, target: target, arguments: ["snapshot": snapshot.info.id],
                                 resultingHTML: SafetyExecutor.bodyHTML(title: snapshot.note.summary.title, markdown: snapshot.markdown),
                                 engine: selected.rawValue)
    let renamePlan = selected == .native || current.summary.title == snapshot.note.summary.title ? nil :
        DryRunPlan(operation: "renameNote", target: target, arguments: ["title": snapshot.note.summary.title], resultingHTML: replacePlan.resultingHTML)
    let destination = SnapshotRestorePolicy.destinationFolderPath(
        current: current.summary.folderPath,
        snapshot: snapshot.note.summary.folderPath,
        snapshotIsDeleted: snapshot.note.summary.isDeleted
    )?.joined(separator: " > ")
    let movePlan = destination.map {
        DryRunPlan(operation: "moveNote", target: target, arguments: ["folder": $0], resultingHTML: replacePlan.resultingHTML)
    }
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
    var capturedNative: NativeWriteResult?
    if let result = try SafetyExecutor.run(options: replaceWrite, operation: restoreOperation, arguments: ["ref": target, "snapshot": snapshot.info.id, "engine": selected.rawValue],
        note: current, allowedPaths: paths, destructive: true, plan: replacePlan,
        action: {
            switch selected {
            case .native:
                let value = try NativeNotesWriter().restoreSnapshot(
                    target,
                    snapshot: snapshot.note,
                    material: try SnapshotStore().restoreMaterial(for: snapshot),
                    expectedRevision: ConcurrencyGuard.revision(current),
                    expectedModified: current.summary.modified,
                    allowShared: write.allowShared
                )
                capturedNative = value
                return value.writeResult
            case .scripting:
                return try scriptingWriter.replaceBody(target, markdown: snapshot.markdown,
                                                        allowAttachmentLoss: write.allowAttachmentLoss || write.allowDowngrade)
            }
        }) {
        if selected == .native {
            try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: capturedNative?.operationID,
                                                      verification: capturedNative?.verification), options: options)
        } else {
            try Output.write(result, json: options.json)
        }
        guard result.outcome == .verified else { return }
    }
    var followupWrite = write
    followupWrite.ifModified = nil
    followupWrite.expectRevision = nil
    if let renamePlan {
        followupWrite.idempotencyKey = write.idempotencyKey.map { "\($0):rename" }
        _ = try SafetyExecutor.run(options: followupWrite, operation: "renameNote", arguments: ["ref": target, "title": snapshot.note.summary.title],
            note: try backend.reader.note(target), allowedPaths: paths, destructive: true,
            plan: renamePlan,
            action: { try scriptingWriter.renameNote(target, title: snapshot.note.summary.title) })
    }
    if let movePlan, let destination {
        followupWrite.idempotencyKey = write.idempotencyKey.map { "\($0):move" }
        _ = try SafetyExecutor.run(options: followupWrite, operation: "moveNote", arguments: ["ref": target, "folder": destination],
            note: try backend.reader.note(target), allowedPaths: paths, destructive: true,
            plan: movePlan,
            action: { try scriptingWriter.moveNote(target, toFolder: destination) })
    }
}

private func unsafeJournalExpectation(_ entry: JournalEntry) -> NotesError {
    NotesError("journal_postimage_missing",
               "Journal operation \(entry.id) has no valid recorded result state; refusing an unsafe undo.")
}

private func restore(entry: JournalEntry, action: JournalRestoreAction, options: GlobalOptions, write: WriteOptions) throws {
    let backend = try options.writable()
    _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
    let writer = NativeNotesWriter()
    let expectation = try entry.restoreExpectation()
    let target: String
    let paths: [[String]]
    switch action {
    case .checklistAutoSort, .defaultParagraphStyle, .globalNoteSort, .globalDateGrouping,
         .defaultTextSize, .resumeLastQuickNote, .autoConvertToTags, .notesPreference:
        target = "Notes settings"; paths = []
    case .defaultAccount(let identifier):
        target = identifier; paths = []
    case .quickNote(let noteID, _):
        let note = try backend.reader.note(noteID)
        target = note.summary.id.uuid; paths = [note.summary.folderPath]
    case .scanFilter(let noteID, _, _, _, _), .scanOrientation(let noteID, _, _, _, _),
         .scanCrop(let noteID, _, _, _, _), .scanMove(let noteID, _, _, _, _),
         .scanUndelete(let noteID, _, _, _, _), .scanDeletePages(let noteID, _, _, _):
        let note = try backend.reader.note(noteID)
        target = note.summary.id.uuid; paths = [note.summary.folderPath]
    case .folderSort(let folderID, _, _), .folderDateGrouping(let folderID, _), .smartFolderQuery(let folderID, _):
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
            guard case .checklistAutoSort(let expected)? = expectation else { throw unsafeJournalExpectation(entry) }
            value = try writer.setChecklistAutoSort(enabled, expectedCurrent: expected)
        case .folderSort(let folderID, let orderName, let directionName):
            guard let order = NativeFolderSortOrder(rawValue: orderName), let direction = NativeFolderSortDirection(rawValue: directionName) else {
                throw NotesError("invalid_journal", "The recorded folder sort preimage is invalid.")
            }
            guard case .folderSort(let expectedOrderName, let expectedDirectionName)? = expectation,
                  let expectedOrder = NativeFolderSortOrder(rawValue: expectedOrderName),
                  let expectedDirection = NativeFolderSortDirection(rawValue: expectedDirectionName) else {
                throw unsafeJournalExpectation(entry)
            }
            value = try writer.setFolderSort(folderID, order: order, direction: direction,
                                             expectedOrder: expectedOrder, expectedDirection: expectedDirection)
        case .folderDateGrouping(let folderID, let type):
            guard case .folderDateGrouping(let expectedType)? = expectation else { throw unsafeJournalExpectation(entry) }
            value = try writer.setFolderDateGrouping(folderID, type: type, expectedCurrentType: expectedType,
                                                      allowShared: write.allowShared)
        case .defaultParagraphStyle(let styleName):
            guard let style = NativeDefaultParagraphStyle(rawValue: styleName) else {
                throw NotesError("invalid_journal", "The recorded default paragraph style preimage is invalid.")
            }
            guard case .defaultParagraphStyle(let expectedName)? = expectation,
                  let expected = NativeDefaultParagraphStyle(rawValue: expectedName) else { throw unsafeJournalExpectation(entry) }
            value = try writer.setDefaultParagraphStyle(style, expectedCurrent: expected)
        case .globalNoteSort(let sortName):
            guard let sort = NativeGlobalNoteSort(rawValue: sortName) else {
                throw NotesError("invalid_journal", "The recorded global note sort preimage is invalid.")
            }
            guard case .globalNoteSort(let expectedName)? = expectation,
                  let expected = NativeGlobalNoteSort(rawValue: expectedName) else { throw unsafeJournalExpectation(entry) }
            value = try writer.setGlobalNoteSort(sort, expectedCurrent: expected)
        case .globalDateGrouping(let enabled):
            guard case .globalDateGrouping(let expected)? = expectation else { throw unsafeJournalExpectation(entry) }
            value = try writer.setGlobalDateGrouping(enabled, expectedCurrent: expected)
        case .defaultTextSize(let points):
            guard case .defaultTextSize(let expected)? = expectation else { throw unsafeJournalExpectation(entry) }
            value = try writer.setDefaultTextSize(points, expectedCurrent: expected)
        case .resumeLastQuickNote(let enabled):
            guard case .resumeLastQuickNote(let expected)? = expectation else { throw unsafeJournalExpectation(entry) }
            value = try writer.setResumeLastQuickNote(enabled, expectedCurrent: expected)
        case .autoConvertToTags(let enabled):
            guard case .autoConvertToTags(let expected)? = expectation else { throw unsafeJournalExpectation(entry) }
            value = try writer.setAutoConvertToTags(enabled, expectedCurrent: expected)
        case .notesPreference(let settingName, let stateName):
            guard let setting = NativeNotesPreference(rawValue: settingName),
                  let state = NativePreferenceState(rawValue: stateName) else {
                throw NotesError("invalid_journal", "The recorded Notes preference preimage is invalid.")
            }
            guard case .notesPreference(let expectedName)? = expectation,
                  let expected = NativePreferenceState(rawValue: expectedName) else { throw unsafeJournalExpectation(entry) }
            value = try writer.setNotesPreference(setting, state: state, expectedCurrent: expected)
        case .quickNote(let noteID, let enabled):
            guard case .quickNote(let expected)? = expectation else { throw unsafeJournalExpectation(entry) }
            value = try writer.setQuickNote(noteID, enabled: enabled, expectedCurrent: expected,
                                            allowShared: write.allowShared)
        case .defaultAccount(let identifier):
            guard case .defaultAccount(let expected)? = expectation else { throw unsafeJournalExpectation(entry) }
            value = try writer.setDefaultAccount(identifier, expectedCurrent: expected)
        case .smartFolderQuery(let folderID, let queryJSON):
            try SmartFolderQueryGrammar.validate(queryJSON)
            guard case .smartFolderQuery(let expected)? = expectation else { throw unsafeJournalExpectation(entry) }
            value = try writer.editSmartFolderRules(folderID, queryJSON: queryJSON, expectedCount: 1,
                                                     expectedCurrentQuery: expected)
        case .scanFilter(let noteID, let attachmentID, let pageID, let filterName, let expectedName):
            guard let filter = NativeScanFilter(rawValue: filterName) else {
                throw NotesError("invalid_journal", "The recorded scan-filter preimage is invalid.")
            }
            let expected = try expectedName.map { value in
                guard let parsed = NativeScanFilter(rawValue: value) else {
                    throw NotesError("invalid_journal", "The recorded scan-filter result is invalid.")
                }
                return parsed
            }
            value = try writer.setScanFilter(noteID, attachmentID: attachmentID, pageID: pageID,
                                             filter: filter, expectedCurrent: expected,
                                             allowShared: write.allowShared)
        case .scanOrientation(let noteID, let attachmentID, let pageID, let orientationName, let expectedName):
            guard let orientation = NativeScanOrientation(rawValue: orientationName) else {
                throw NotesError("invalid_journal", "The recorded scan-orientation preimage is invalid.")
            }
            let expected = try expectedName.map { value in
                guard let parsed = NativeScanOrientation(rawValue: value) else {
                    throw NotesError("invalid_journal", "The recorded scan-orientation result is invalid.")
                }
                return parsed
            }
            value = try writer.setScanOrientation(noteID, attachmentID: attachmentID, pageID: pageID,
                                                  orientation: orientation, expectedCurrent: expected,
                                                  allowShared: write.allowShared)
        case .scanCrop(let noteID, let attachmentID, let pageID, let crop, let expected):
            value = try writer.setScanCrop(noteID, attachmentID: attachmentID, pageID: pageID,
                                           crop: crop, expectedCurrent: expected,
                                           allowShared: write.allowShared)
        case .scanMove(let noteID, let attachmentID, let pageID, let index, let expectedPageIDs):
            value = try writer.moveScanPage(noteID, attachmentID: attachmentID, pageID: pageID,
                                            toIndex: index, expectedPageIDs: expectedPageIDs,
                                            allowShared: write.allowShared)
        case .scanUndelete(let noteID, let attachmentID, let pageID, let index, let expectedPageIDs):
            value = try writer.restoreScanPage(noteID, attachmentID: attachmentID, pageID: pageID,
                                               toIndex: index, expectedPageIDs: expectedPageIDs,
                                               allowShared: write.allowShared)
        case .scanDeletePages(let noteID, let attachmentID, let pageIDs, let expectedPageIDs):
            value = try writer.deleteScanPages(noteID, attachmentID: attachmentID, pageIDs: pageIDs,
                                               expectedPageIDs: expectedPageIDs,
                                               allowShared: write.allowShared)
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
    let backend = try options.writable(), note = try backend.reader.note(ref)
    let selected = try UnifiedNative.engine(options, scriptingAvailable: true, fake: backend.isFake)
    if selected == .scripting {
        try SnapshotRestorePolicy.requireScriptingBodyRewriteAllowed(note, allowDowngrade: write.allowDowngrade)
        try SafetyExecutor.requireAttachmentSafety(note, allowLoss: write.allowAttachmentLoss)
    }
    let writer = try backend.writer()
    let sourceHTML = write.dryRun && !backend.isFake && selected == .scripting ? try writer.htmlBody(note.summary.id.uuid) : SafetyExecutor.html(note)
    let plannedHTML: String
    do { plannedHTML = try resultingHTML(note, sourceHTML) }
    catch {
        if write.dryRun { throw error }
        plannedHTML = SafetyExecutor.html(note)
    }
    let plan = DryRunPlan(operation: operation, target: note.summary.id.uuid, arguments: arguments,
                          resultingHTML: plannedHTML, engine: selected.rawValue)
    var native: NativeWriteResult?
    if let result = try SafetyExecutor.run(options: write, operation: operation, arguments: arguments.merging(["ref": note.summary.id.uuid]) { $1 },
        note: note, allowedPaths: [note.summary.folderPath], destructive: true, plan: plan, action: {
            if selected == .scripting { return try action(writer) }
            let value: NativeWriteResult
            switch operation {
            case "prependToNote": value = try NativeNotesWriter().prependMarkdown(note.summary.id.uuid, markdown: arguments["body"]!, allowShared: write.allowShared)
            case "insertUnderHeading": value = try NativeNotesWriter().insertMarkdown(note.summary.id.uuid, underHeading: arguments["heading"]!, markdown: arguments["body"]!, allowShared: write.allowShared)
            case "replaceSection": value = try NativeNotesWriter().replaceSection(note.summary.id.uuid, heading: arguments["heading"]!, markdown: arguments["body"]!, allowShared: write.allowShared)
            case "replaceText": value = try NativeNotesWriter().replaceText(note.summary.id.uuid, find: arguments["find"]!, replacement: arguments["replacement"]!, allowShared: write.allowShared)
            default: throw NotesError("unsupported_operation", "The native engine does not support \(operation).")
            }
            native = value
            return value.writeResult
        }) {
        try outputEngineWrite(EngineWriteResponse(engine: selected.rawValue, result: result, operationID: native?.operationID,
                                                  verification: native?.verification), options: options)
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
