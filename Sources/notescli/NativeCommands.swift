import ArgumentParser
import Foundation
import NotesCore
import NotesNative
import NotesSafety

extension NativeParagraphStyle: ExpressibleByArgument {}
extension NativeParagraphAlignment: ExpressibleByArgument {}
extension NativeWritingDirection: ExpressibleByArgument {}
extension HighlightColor: ExpressibleByArgument {}

struct EngineWriteResponse: Encodable {
    var engine: String
    var result: WriteResult
    var operationID: String? = nil
    var syncPending: Bool? = nil
    var verification: NativeVerification? = nil
    var details: [String: String]? = nil
}

private struct EngineReadResponse<T: Encodable>: Encodable { var engine: String; var result: T }

struct NativeActionResult {
    var result: WriteResult
    var operationID: String?
    var verification: NativeVerification?
    var details: [String: String]?
    init(_ value: NativeWriteResult, details: [String: String]? = nil) {
        result = value.writeResult; operationID = value.operationID; verification = value.verification; self.details = details
    }
    init(_ value: NativeAttachmentResult) {
        result = value.write.writeResult; operationID = value.write.operationID; verification = value.write.verification
        details = ["attachment_id": value.attachmentID, "type_uti": value.typeUTI, "position": String(value.position),
                   "source_sha256": value.sourceSHA256 ?? "", "stored_sha256": value.storedSHA256 ?? ""]
    }
    init(_ value: WriteResult) { result = value; operationID = nil; verification = nil; details = nil }
}

func outputEngineWrite(_ input: EngineWriteResponse, options: GlobalOptions) throws {
    var response = input
    response.operationID = response.operationID ?? response.result.operationID
    response.syncPending = response.syncPending ?? response.result.syncPending
    if response.result.outcome == .unknown {
        if options.json { try Output.json(response) }
        let operation = response.operationID.map { " Native operation ID: \($0)." } ?? ""
        throw NotesError("write_outcome_unknown", (response.result.message ?? "The write may have completed. Do not retry automatically.") + operation, hint: "Read the note before retrying.")
    }
    if options.json { try Output.json(response) }
    else { Output.table(["ENGINE", "OUTCOME", "ID", "MESSAGE"], [[response.engine, response.result.outcome.rawValue,
        response.result.noteID?.uuid ?? response.result.folderID ?? "", response.result.message ?? ""]]) }
}

enum UnifiedNative {
    static func nativeAvailable() -> Bool {
        let report = NativeNotesWriter().doctor()
        return report.frameworkLoaded && report.error == nil && report.missing.isEmpty
    }

    static func engine(_ options: GlobalOptions, scriptingAvailable: Bool, fake: Bool) throws -> WriteEngine {
        switch options.resolvedEngine {
        case .native:
            guard nativeAvailable() else { throw NotesError("native_unavailable", "The native Notes framework check failed. Run notescli engine doctor --json.") }
            return .native
        case .scripting:
            guard scriptingAvailable else {
                throw NotesError("native_required", "This operation requires the private native engine.", hint: "Pass --engine native or set NOTESCLI_ENGINE=native.")
            }
            return .scripting
        }
    }

    static func output(_ response: EngineWriteResponse, options: GlobalOptions) throws {
        try outputEngineWrite(response, options: options)
    }

    static func read<T: Encodable>(_ options: GlobalOptions, ref: String,
                                   action: (String) throws -> T) throws {
        let backend = try options.backends()
        _ = try engine(options, scriptingAvailable: false, fake: backend.isFake)
        let stableRef = try backend.reader.summary(ref).id.uuid
        try Output.json(EngineReadResponse(engine: "native", result: try action(stableRef)))
    }

    static func requireNative(_ options: GlobalOptions) throws {
        let backend = try options.backends()
        _ = try engine(options, scriptingAvailable: false, fake: backend.isFake)
    }

    static func noteWrite(options: GlobalOptions, write: WriteOptions, ref: String, operation: String,
                          arguments: [String: String], native: @escaping (String) throws -> NativeActionResult,
                          scripting: ((String) throws -> WriteResult)? = nil) throws {
        let backend = try options.writable(), note = try backend.reader.note(ref)
        let selected = try engine(options, scriptingAvailable: scripting != nil, fake: backend.isFake)
        var plan = DryRunPlan(operation: operation, target: note.summary.id.uuid, arguments: arguments,
                              resultingHTML: SafetyExecutor.html(note), engine: selected.rawValue)
        if operation == "writeMarkdown", let body = arguments["body"] {
            plan.resultingHTML = SafetyExecutor.bodyHTML(title: note.summary.title, markdown: body)
        }
        var captured: NativeActionResult?
        let result = try SafetyExecutor.run(options: write, operation: operation,
            arguments: arguments.merging(["ref": note.summary.id.uuid, "engine": selected.rawValue]) { $1 },
            note: note, allowedPaths: [note.summary.folderPath], destructive: true, plan: plan) {
                switch selected {
                case .native: let value = try native(note.summary.id.uuid); captured = value; return value.result
                case .scripting: let value = try scripting!(note.summary.id.uuid); captured = NativeActionResult(value); return value
                }
            }
        guard let result else { return }
        try output(EngineWriteResponse(engine: selected.rawValue, result: result, operationID: captured?.operationID,
                                       verification: captured?.verification, details: captured?.details), options: options)
    }

    static func globalWrite(options: GlobalOptions, write: WriteOptions, operation: String,
                            arguments: [String: String], notes: [Note], native: @escaping () throws -> NativeActionResult) throws {
        let backend = try options.writable()
        let selected = try engine(options, scriptingAvailable: false, fake: backend.isFake)
        let plan = DryRunPlan(operation: operation, target: arguments["tag"], arguments: arguments, resultingHTML: nil, engine: selected.rawValue)
        var captured: NativeActionResult?
        let result = try SafetyExecutor.run(options: write, operation: operation,
            arguments: arguments.merging(["engine": selected.rawValue]) { $1 }, allowedPaths: notes.map(\.summary.folderPath), plan: plan) {
                for note in notes { _ = try SnapshotStore().save(note) }
                let value = try native(); captured = value; return value.result
            }
        guard let result else { return }
        try output(EngineWriteResponse(engine: selected.rawValue, result: result, operationID: captured?.operationID,
                                       verification: captured?.verification, details: captured?.details), options: options)
    }

    static func checklistAdd(_ o: GlobalOptions, _ w: WriteOptions, ref: String, text: String, position: Int?) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "checklistAdd", arguments: ["text": text, "position": position.map(String.init) ?? ""]) { stableRef in
            NativeActionResult(try NativeNotesWriter().insertChecklist(stableRef, text: text, position: position, allowShared: w.allowShared))
        }
    }
    static func checklistToggle(_ o: GlobalOptions, _ w: WriteOptions, ref: String, index: Int?, text: String?, done: Bool?) throws {
        let selection: ChecklistSelection
        if let index { selection = .index(index) } else { selection = .text(try required(text, "--text or --index")) }
        try noteWrite(options: o, write: w, ref: ref, operation: "checklistToggle", arguments: ["index": index.map(String.init) ?? "", "text": text ?? "", "done": done.map(String.init) ?? ""]) { stableRef in
            NativeActionResult(try NativeNotesWriter().toggleChecklist(stableRef, selection: selection, done: done, allowShared: w.allowShared))
        }
    }
    static func checklistAll(_ o: GlobalOptions, _ w: WriteOptions, ref: String, done: Bool) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: done ? "checklistCheckAll" : "checklistUncheckAll", arguments: [:]) { stableRef in
            NativeActionResult(try NativeNotesWriter().setAllChecklist(stableRef, done: done, allowShared: w.allowShared))
        }
    }
    static func checklistClear(_ o: GlobalOptions, _ w: WriteOptions, ref: String) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "checklistClearDone", arguments: [:]) { stableRef in
            NativeActionResult(try NativeNotesWriter().deleteCompleted(stableRef, allowShared: w.allowShared))
        }
    }
    static func pin(_ o: GlobalOptions, _ w: WriteOptions, ref: String, pinned: Bool) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: pinned ? "pinNote" : "unpinNote", arguments: [:]) { stableRef in
            NativeActionResult(try NativeNotesWriter().setPinned(stableRef, pinned: pinned, allowShared: w.allowShared))
        }
    }
    static func tagAdd(_ o: GlobalOptions, _ w: WriteOptions, ref: String, tag: String, position: Int?) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "tagAdd", arguments: ["tag": tag, "position": position.map(String.init) ?? ""]) { stableRef in
            NativeActionResult(try NativeNotesWriter().addTag(stableRef, tag: tag, position: position, allowShared: w.allowShared))
        }
    }
    static func tagRemove(_ o: GlobalOptions, _ w: WriteOptions, ref: String, tag: String) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "tagRemove", arguments: ["tag": tag]) { stableRef in
            NativeActionResult(try NativeNotesWriter().removeTag(stableRef, tag: tag, allowShared: w.allowShared))
        }
    }
    static func tagGlobal(_ o: GlobalOptions, _ w: WriteOptions, tag: String, to: String?, expected: Int, delete: Bool) throws {
        let backend = try o.backends(), summaries = try backend.reader.notes(NoteQuery(tag: tag))
        guard summaries.count == expected else { throw NotesError("stale_tag_count", "Expected \(expected) notes with the tag but found \(summaries.count).") }
        let notes = try summaries.map { try backend.reader.note($0.id.uuid) }
        try globalWrite(options: o, write: w, operation: delete ? "tagDelete" : "tagRename",
                        arguments: ["tag": tag, "to": to ?? "", "expected_count": String(expected)], notes: notes) {
            let writer = NativeNotesWriter()
            return NativeActionResult(try delete ? writer.deleteTag(tag, expectedCount: expected, allowShared: w.allowShared) : writer.renameTag(tag, to: to!, expectedCount: expected, allowShared: w.allowShared))
        }
    }
    static func linkAdd(_ o: GlobalOptions, _ w: WriteOptions, ref: String, target: String, text: String?, position: Int?) throws {
        let stableTarget = try o.backends().reader.summary(target).id.uuid
        try noteWrite(options: o, write: w, ref: ref, operation: "linkAdd", arguments: ["target": stableTarget, "text": text ?? "", "position": position.map(String.init) ?? ""]) { stableRef in
            NativeActionResult(try NativeNotesWriter().insertNoteLink(stableRef, target: stableTarget, text: text, position: position, allowShared: w.allowShared))
        }
    }
    static func textEdit(_ o: GlobalOptions, _ w: WriteOptions, ref: String, operation: String, start: Int, length: Int, text: String?) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: operation, arguments: ["start": String(start), "length": String(length), "text": text ?? ""]) { stableRef in
            let writer = NativeNotesWriter(), range = UTF16Range(location: start, length: length)
            if operation == "textInsert" { return NativeActionResult(try writer.insertText(stableRef, text: text!, position: start, allowShared: w.allowShared)) }
            if operation == "textDelete" { return NativeActionResult(try writer.deleteRange(stableRef, range: range, allowShared: w.allowShared)) }
            return NativeActionResult(try writer.replaceRange(stableRef, range: range, text: text!, allowShared: w.allowShared))
        }
    }
    static func paragraphFormat(_ o: GlobalOptions, _ w: WriteOptions, ref: String, start: Int, length: Int, style: NativeParagraphStyle, indent: Int?,
                                alignment: NativeParagraphAlignment?, writingDirection: NativeWritingDirection?, collapsed: Bool?) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "formatParagraph", arguments: ["start": String(start), "length": String(length), "style": style.rawValue]) { stableRef in
            NativeActionResult(try NativeNotesWriter().setParagraphStyle(stableRef, range: UTF16Range(location: start, length: length), style: style, indent: indent,
                                                                          alignment: alignment, writingDirection: writingDirection, collapsed: collapsed, allowShared: w.allowShared))
        }
    }
    static func inlineFormat(_ o: GlobalOptions, _ w: WriteOptions, ref: String, start: Int, length: Int, format: InlineFormat) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "formatInline", arguments: ["start": String(start), "length": String(length)]) { stableRef in
            NativeActionResult(try NativeNotesWriter().setInlineFormat(stableRef, range: UTF16Range(location: start, length: length), format: format, allowShared: w.allowShared))
        }
    }
    static func attach(_ o: GlobalOptions, _ w: WriteOptions, ref: String, path: String, position: Int?, view: String?) throws {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
        try noteWrite(options: o, write: w, ref: ref, operation: "attachFile", arguments: ["path": url.path, "position": position.map(String.init) ?? "", "view": view ?? ""]) { stableRef in
            NativeActionResult(try NativeNotesWriter().insertFile(stableRef, file: url, position: position, imageView: view, allowShared: w.allowShared))
        }
    }
    static func attachmentDelete(_ o: GlobalOptions, _ w: WriteOptions, ref: String, id: String) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "attachmentDelete", arguments: ["attachment_id": id]) { stableRef in
            NativeActionResult(try NativeNotesWriter().deleteAttachment(stableRef, attachmentID: id, allowShared: w.allowShared))
        }
    }
    static func tableCreate(_ o: GlobalOptions, _ w: WriteOptions, ref: String, rows: [[String]], position: Int?) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "tableCreate", arguments: ["rows": String(data: try JSONEncoder().encode(rows), encoding: .utf8)!]) { stableRef in
            NativeActionResult(try NativeNotesWriter().createTable(stableRef, rows: rows, position: position, allowShared: w.allowShared))
        }
    }
    static func tableSet(_ o: GlobalOptions, _ w: WriteOptions, ref: String, id: String, row: Int, column: Int, text: String) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "tableSet", arguments: ["attachment_id": id, "row": String(row), "column": String(column), "text": text]) { stableRef in
            NativeActionResult(try NativeNotesWriter().editTable(stableRef, attachmentID: id, row: row, column: column, text: text, allowShared: w.allowShared))
        }
    }
    static func tableResize(_ o: GlobalOptions, _ w: WriteOptions, ref: String, id: String, axis: String, index: Int, add: Bool) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "table\(add ? "Add" : "Remove")\(axis.capitalized)", arguments: ["attachment_id": id, "index": String(index)]) { stableRef in
            NativeActionResult(try NativeNotesWriter().resizeTable(stableRef, attachmentID: id, axis: axis, index: index, add: add, allowShared: w.allowShared))
        }
    }
    static func duplicate(_ o: GlobalOptions, _ w: WriteOptions, ref: String, title: String?) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "duplicateNote", arguments: ["title": title ?? ""]) { stableRef in
            NativeActionResult(try NativeNotesWriter().duplicate(stableRef, title: title, allowShared: w.allowShared))
        }
    }
    static func restore(_ o: GlobalOptions, _ w: WriteOptions, ref: String, folder: String?) throws {
        try noteWrite(options: o, write: w, ref: ref, operation: "restoreNote", arguments: ["folder": folder ?? ""], native: { stableRef in
            NativeActionResult(try NativeNotesWriter().restore(stableRef, folder: folder, allowShared: w.allowShared))
        })
    }
    static func writeMarkdown(_ o: GlobalOptions, _ w: WriteOptions, ref: String, body: String, backup: Bool) throws {
        let backend = try o.backends()
        try noteWrite(options: o, write: w, ref: ref, operation: "writeMarkdown", arguments: ["body": body, "backup": String(backup)], native: { stableRef in
            NativeActionResult(try NativeNotesWriter().writeMarkdown(stableRef, markdown: body, dryRun: false, backup: backup, allowShared: w.allowShared))
        }, scripting: { stableRef in try backend.writer().replaceBody(stableRef, markdown: body, allowAttachmentLoss: w.allowAttachmentLoss) })
    }
}

func unifiedNativeFolderMove(options: GlobalOptions, write: WriteOptions, ref: String, parent: String?) throws {
    let backend = try options.writable()
    let source = try SafetyExecutor.folder(ref, reader: backend.reader)
    let destination = try SafetyExecutor.folder(parent, reader: backend.reader)
    guard let source else { throw NotesError("folder_not_found", "Folder was not found.") }
    _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
    let notes = try backend.reader.notes(NoteQuery()).filter { $0.folderPath.starts(with: source.path) }.map { try backend.reader.note($0.id.uuid) }
    let targetPath = (destination?.path ?? []) + [source.name]
    let plan = DryRunPlan(operation: "moveFolder", target: source.id, arguments: ["parent": parent ?? ""], resultingHTML: nil, engine: "native")
    var captured: NativeActionResult?
    let result = try SafetyExecutor.run(options: write, operation: "moveFolder", arguments: ["ref": source.id, "parent": destination?.id ?? "", "engine": "native", "stable_id": source.id, "stable_parent_id": destination?.id ?? ""],
        allowedPaths: [source.path, targetPath], plan: plan) {
            for note in notes { _ = try SnapshotStore().save(note) }
            let value = NativeActionResult(try NativeNotesWriter().moveFolder(source.id, parent: destination?.id, allowShared: write.allowShared))
            captured = value
            return value.result
        }
    guard let result else { return }
    try UnifiedNative.output(EngineWriteResponse(engine: "native", result: result, operationID: captured?.operationID,
                                                 verification: captured?.verification, details: captured?.details), options: options)
}

struct EngineCommand: ParsableCommand { static let configuration = CommandConfiguration(commandName: "engine", subcommands: [EngineDoctor.self]) }
struct EngineDoctor: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor")
    @OptionGroup var options: GlobalOptions
    func run() throws { try Output.json(NativeNotesWriter().doctor()) }
}

struct ChecklistCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "checklist", subcommands: [ChecklistAdd.self, ChecklistToggle.self, ChecklistCheckAll.self, ChecklistUncheckAll.self, ChecklistClearDone.self, ChecklistList.self])
}
struct ChecklistAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var text: String; @Option var position: Int?
    func run() throws { try UnifiedNative.checklistAdd(options, write, ref: ref, text: text, position: position) }
}
struct ChecklistToggle: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "toggle")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Option var index: Int?; @Option var text: String?; @Option var done: Bool?
    func run() throws { try UnifiedNative.checklistToggle(options, write, ref: ref, index: index, text: text, done: done) }
}
struct ChecklistCheckAll: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "check-all")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String
    func run() throws { try UnifiedNative.checklistAll(options, write, ref: ref, done: true) }
}
struct ChecklistUncheckAll: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uncheck-all")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String
    func run() throws { try UnifiedNative.checklistAll(options, write, ref: ref, done: false) }
}
struct ChecklistClearDone: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear-done")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String
    func run() throws { try UnifiedNative.checklistClear(options, write, ref: ref) }
}
struct ChecklistList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var options: GlobalOptions; @Argument var ref: String
    func run() throws { try UnifiedNative.read(options, ref: ref) { try NativeNotesWriter().checklistItems($0) } }
}

struct PinCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pin")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String
    func run() throws { try UnifiedNative.pin(options, write, ref: ref, pinned: true) }
}
struct UnpinCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unpin")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String
    func run() throws { try UnifiedNative.pin(options, write, ref: ref, pinned: false) }
}

struct TagCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tag", subcommands: [TagAdd.self, TagRemove.self, TagRename.self, TagDelete.self])
}
struct TagAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Argument var tag: String; @Option var position: Int?
    func run() throws { try UnifiedNative.tagAdd(options, write, ref: ref, tag: tag, position: position) }
}
struct TagRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Argument var tag: String
    func run() throws { try UnifiedNative.tagRemove(options, write, ref: ref, tag: tag) }
}
struct TagRename: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var tag: String; @Argument var newName: String; @Option var expectedCount: Int
    func run() throws { try UnifiedNative.tagGlobal(options, write, tag: tag, to: newName, expected: expectedCount, delete: false) }
}
struct TagDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var tag: String; @Option var expectedCount: Int
    func run() throws { try UnifiedNative.tagGlobal(options, write, tag: tag, to: nil, expected: expectedCount, delete: true) }
}

struct LinkCommand: ParsableCommand { static let configuration = CommandConfiguration(commandName: "link", subcommands: [LinkAdd.self, LinkAddURL.self, LinkList.self]) }
struct LinkAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Argument var target: String; @Option var text: String?; @Option var position: Int?
    func run() throws { try UnifiedNative.linkAdd(options, write, ref: ref, target: target, text: text, position: position) }
}
struct LinkList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var options: GlobalOptions; @Argument var ref: String
    func run() throws { try UnifiedNative.read(options, ref: ref) { try NativeNotesWriter().links($0) } }
}
struct DeepLink: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "deeplink")
    @OptionGroup var options: GlobalOptions; @Argument var ref: String
    func run() throws { let summary = try options.backends().reader.summary(ref); let url = summary.deepLink ?? "applenotes://showNote?identifier=\(summary.id.uuid)"; if options.json { try Output.json(["url": url]) } else { print(url) } }
}

struct TextCommand: ParsableCommand { static let configuration = CommandConfiguration(commandName: "text", subcommands: [TextInsert.self, TextDelete.self, TextReplace.self, TextFind.self]) }
struct TextInsert: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "insert")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Argument var text: String; @Option var position: Int
    func run() throws { try UnifiedNative.textEdit(options, write, ref: ref, operation: "textInsert", start: position, length: 0, text: text) }
}
struct TextDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Option var start: Int; @Option var length: Int
    func run() throws { try UnifiedNative.textEdit(options, write, ref: ref, operation: "textDelete", start: start, length: length, text: nil) }
}
struct TextReplace: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "replace")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Argument var text: String; @Option var start: Int; @Option var length: Int
    func run() throws { try UnifiedNative.textEdit(options, write, ref: ref, operation: "textReplace", start: start, length: length, text: text) }
}
struct TextFind: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "find")
    @OptionGroup var options: GlobalOptions; @Argument var ref: String; @Argument var text: String; @Flag var caseInsensitive = false
    func run() throws { try UnifiedNative.read(options, ref: ref) { try NativeNotesWriter().searchOffsets($0, text: text, caseInsensitive: caseInsensitive) } }
}

struct FormatCommand: ParsableCommand { static let configuration = CommandConfiguration(commandName: "format", subcommands: [FormatParagraph.self, FormatInline.self]) }
struct FormatParagraph: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "paragraph")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Option var start: Int; @Option var length: Int; @Option var style: NativeParagraphStyle; @Option var indent: Int?
    @Option var alignment: NativeParagraphAlignment?; @Option var writingDirection: NativeWritingDirection?; @Option var collapsed: Bool?
    func run() throws { try UnifiedNative.paragraphFormat(options, write, ref: ref, start: start, length: length, style: style, indent: indent,
                                                           alignment: alignment, writingDirection: writingDirection, collapsed: collapsed) }
}
struct FormatInline: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inline")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Option var start: Int; @Option var length: Int
    @Option var bold: Bool?; @Option var italic: Bool?; @Option var underline: Bool?; @Option var strike: Bool?
    @Option var link: String?; @Option var color: String?; @Flag var clearLink = false; @Flag var clearColor = false
    @Flag var superscript = false; @Flag var `subscript` = false; @Flag var clearScript = false
    @Option var fontName: String?; @Option var fontSize: Double?; @Option var highlight: HighlightColor?; @Flag var clearHighlight = false
    func validate() throws { guard [superscript, `subscript`, clearScript].filter({ $0 }).count <= 1 else { throw ValidationError("Choose one of --superscript, --subscript, or --clear-script.") } }
    func run() throws { try UnifiedNative.inlineFormat(options, write, ref: ref, start: start, length: length,
        format: InlineFormat(bold: bold, italic: italic, underline: underline, strike: strike, link: link, clearLink: clearLink, color: color, clearColor: clearColor,
                             superscript: superscript ? 1 : (`subscript` ? -1 : (clearScript ? 0 : nil)), fontName: fontName, fontSize: fontSize,
                             highlight: highlight, clearHighlight: clearHighlight)) }
}
struct AttachCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "attach")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var path: String?; @Flag var pasteboard = false; @Option var position: Int?; @Option var view: String?
    func validate() throws {
        guard (path != nil) != pasteboard else { throw ValidationError("Provide either FILE or --pasteboard.") }
    }
    func run() throws { try writeExtraAttach(options: options, write: write, ref: ref, path: path, pasteboard: pasteboard, position: position, view: view) }
}
struct AttachmentCommand: ParsableCommand { static let configuration = CommandConfiguration(commandName: "attachment", subcommands: [AttachmentDelete.self]) }
struct AttachmentDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Argument var attachmentID: String
    func run() throws { try UnifiedNative.attachmentDelete(options, write, ref: ref, id: attachmentID) }
}
struct TableCommand: ParsableCommand { static let configuration = CommandConfiguration(commandName: "table", subcommands: [TableCreate.self, TableSet.self, TableAddRow.self, TableAddColumn.self, TableRemoveRow.self, TableRemoveColumn.self]) }
struct TableCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Option var rows: String; @Option var position: Int?
    func run() throws { try UnifiedNative.tableCreate(options, write, ref: ref, rows: try JSONDecoder().decode([[String]].self, from: Data(rows.utf8)), position: position) }
}
struct TableSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Argument var attachmentID: String; @Option var row: Int; @Option var column: Int; @Argument var text: String
    func run() throws { try UnifiedNative.tableSet(options, write, ref: ref, id: attachmentID, row: row, column: column, text: text) }
}
protocol TableResizeCommand: ParsableCommand {
    var options: GlobalOptions { get }; var write: WriteOptions { get }; var ref: String { get }; var attachmentID: String { get }; var index: Int { get }
    static var axis: String { get }; static var add: Bool { get }
}
extension TableResizeCommand { func run() throws { try UnifiedNative.tableResize(options, write, ref: ref, id: attachmentID, axis: Self.axis, index: index, add: Self.add) } }
struct TableAddRow: TableResizeCommand { static let configuration = CommandConfiguration(commandName: "add-row"); static let axis = "row"; static let add = true; @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Argument var attachmentID: String; @Option var index: Int }
struct TableAddColumn: TableResizeCommand { static let configuration = CommandConfiguration(commandName: "add-column"); static let axis = "column"; static let add = true; @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Argument var attachmentID: String; @Option var index: Int }
struct TableRemoveRow: TableResizeCommand { static let configuration = CommandConfiguration(commandName: "remove-row"); static let axis = "row"; static let add = false; @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Argument var attachmentID: String; @Option var index: Int }
struct TableRemoveColumn: TableResizeCommand { static let configuration = CommandConfiguration(commandName: "remove-column"); static let axis = "column"; static let add = false; @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Argument var attachmentID: String; @Option var index: Int }
struct DuplicateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "duplicate")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Option var title: String?
    func run() throws { try UnifiedNative.duplicate(options, write, ref: ref, title: title) }
}
struct RestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Option var folder: String?
    func run() throws { try UnifiedNative.restore(options, write, ref: ref, folder: folder) }
}
struct WriteMarkdownCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "write")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String
    @Option var body: String?; @Flag var stdin = false; @Option var file: String?; @Flag var backup = false
    func validate() throws { try validateBodySources(body: body, stdin: stdin, file: file) }
    func run() throws { try UnifiedNative.writeMarkdown(options, write, ref: ref, body: try inputBody(body: body, stdin: stdin, file: file), backup: backup) }
}

// Hidden one-release aliases. The legacy native prefix remains callable but never enables native by itself.
struct NativeDoctor: ParsableCommand { static let configuration = CommandConfiguration(commandName: "native-doctor", shouldDisplay: false); @OptionGroup var options: GlobalOptions; func run() throws { try Output.json(NativeNotesWriter().doctor()) } }
enum LegacyChecklistAction: String, ExpressibleByArgument { case list, insert, append, toggle, checkAll = "check-all", uncheckAll = "uncheck-all", deleteCompleted = "delete-completed" }
struct NativeChecklist: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-checklist", shouldDisplay: false)
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var action: LegacyChecklistAction; @Argument var ref: String
    @Option var text: String?; @Option var index: Int?; @Option var position: Int?; @Option var done: Bool?
    func run() throws {
        switch action {
        case .list:
            try UnifiedNative.requireNative(options)
            try Output.json(NativeNotesWriter().checklistItems(ref))
        case .insert: try UnifiedNative.checklistAdd(options, write, ref: ref, text: try required(text, "--text"), position: position)
        case .append: try UnifiedNative.checklistAdd(options, write, ref: ref, text: try required(text, "--text"), position: nil)
        case .toggle: try UnifiedNative.checklistToggle(options, write, ref: ref, index: index, text: text, done: done)
        case .checkAll: try UnifiedNative.checklistAll(options, write, ref: ref, done: true)
        case .uncheckAll: try UnifiedNative.checklistAll(options, write, ref: ref, done: false)
        case .deleteCompleted: try UnifiedNative.checklistClear(options, write, ref: ref)
        }
    }
}
struct NativePin: ParsableCommand { static let configuration = CommandConfiguration(commandName: "native-pin", shouldDisplay: false); @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Flag var unpin = false; func run() throws { try UnifiedNative.pin(options, write, ref: ref, pinned: !unpin) } }
enum LegacyTagAction: String, ExpressibleByArgument { case add, remove, rename, delete }
struct NativeTag: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-tag", shouldDisplay: false)
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var action: LegacyTagAction; @Argument var tag: String; @Option var ref: String?; @Option(name: .customLong("to")) var newName: String?
    @Option var position: Int?; @Option var expectedCount: Int?
    func run() throws {
        switch action {
        case .add: try UnifiedNative.tagAdd(options, write, ref: try required(ref, "--ref"), tag: tag, position: position)
        case .remove: try UnifiedNative.tagRemove(options, write, ref: try required(ref, "--ref"), tag: tag)
        case .rename: try UnifiedNative.tagGlobal(options, write, tag: tag, to: try required(newName, "--to"), expected: try required(expectedCount, "--expected-count"), delete: false)
        case .delete: try UnifiedNative.tagGlobal(options, write, tag: tag, to: nil, expected: try required(expectedCount, "--expected-count"), delete: true)
        }
    }
}
enum LegacyLinkAction: String, ExpressibleByArgument { case add, list, backlinks }
struct NativeLink: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-link", shouldDisplay: false)
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var action: LegacyLinkAction; @Argument var ref: String; @Option var target: String?; @Option var text: String?; @Option var position: Int?
    func run() throws {
        switch action {
        case .add: try UnifiedNative.linkAdd(options, write, ref: ref, target: try required(target, "--target"), text: text, position: position)
        case .list:
            try UnifiedNative.requireNative(options)
            try Output.json(NativeNotesWriter().links(ref))
        case .backlinks: try Output.json(options.backends().reader.backlinks(ref))
        }
    }
}
enum LegacyTextAction: String, ExpressibleByArgument { case insert, delete, replace, search }
struct NativeText: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-text", shouldDisplay: false)
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var action: LegacyTextAction; @Argument var ref: String; @Option var text: String?; @Option var position: Int?; @Option var start: Int?; @Option var length: Int?
    @Flag var caseInsensitive = false
    func run() throws {
        switch action {
        case .insert: try UnifiedNative.textEdit(options, write, ref: ref, operation: "textInsert", start: try required(position, "--position"), length: 0, text: try required(text, "--text"))
        case .delete: try UnifiedNative.textEdit(options, write, ref: ref, operation: "textDelete", start: try required(start, "--start"), length: try required(length, "--length"), text: nil)
        case .replace: try UnifiedNative.textEdit(options, write, ref: ref, operation: "textReplace", start: try required(start, "--start"), length: try required(length, "--length"), text: try required(text, "--text"))
        case .search:
            try UnifiedNative.requireNative(options)
            try Output.json(NativeNotesWriter().searchOffsets(ref, text: try required(text, "--text"), caseInsensitive: caseInsensitive))
        }
    }
}
enum LegacyFormatAction: String, ExpressibleByArgument { case paragraph, inline }
struct NativeFormat: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-format", shouldDisplay: false)
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var action: LegacyFormatAction; @Argument var ref: String; @Option var start: Int; @Option var length: Int; @Option var style: NativeParagraphStyle?; @Option var indent: Int?
    @Option var alignment: NativeParagraphAlignment?; @Option var writingDirection: NativeWritingDirection?; @Option var collapsed: Bool?
    @Option var bold: Bool?; @Option var italic: Bool?; @Option var underline: Bool?; @Option var strike: Bool?; @Option var link: String?; @Option var color: String?
    @Flag var clearLink = false; @Flag var clearColor = false
    @Flag var superscript = false; @Flag var `subscript` = false; @Flag var clearScript = false
    @Option var fontName: String?; @Option var fontSize: Double?; @Option var highlight: HighlightColor?; @Flag var clearHighlight = false
    func validate() throws { guard [superscript, `subscript`, clearScript].filter({ $0 }).count <= 1 else { throw ValidationError("Choose one script option.") } }
    func run() throws {
        switch action {
        case .paragraph: try UnifiedNative.paragraphFormat(options, write, ref: ref, start: start, length: length, style: try required(style, "--style"), indent: indent,
                                                            alignment: alignment, writingDirection: writingDirection, collapsed: collapsed)
        case .inline: try UnifiedNative.inlineFormat(options, write, ref: ref, start: start, length: length, format: InlineFormat(bold: bold, italic: italic, underline: underline, strike: strike, link: link, clearLink: clearLink, color: color, clearColor: clearColor,
                                                                                                                       superscript: superscript ? 1 : (`subscript` ? -1 : (clearScript ? 0 : nil)), fontName: fontName, fontSize: fontSize,
                                                                                                                       highlight: highlight, clearHighlight: clearHighlight))
        }
    }
}
enum LegacyAttachmentAction: String, ExpressibleByArgument { case image, file, delete }
struct NativeAttachment: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-attachment", shouldDisplay: false)
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var action: LegacyAttachmentAction; @Argument var ref: String; @Option var path: String?; @Option var attachmentID: String?; @Option var position: Int?; @Option var view: String?
    func run() throws {
        switch action {
        case .image: try UnifiedNative.attach(options, write, ref: ref, path: try required(path, "--path"), position: position, view: view)
        case .file: try UnifiedNative.attach(options, write, ref: ref, path: try required(path, "--path"), position: position, view: nil)
        case .delete: try UnifiedNative.attachmentDelete(options, write, ref: ref, id: try required(attachmentID, "--attachment-id"))
        }
    }
}
enum LegacyTableAction: String, ExpressibleByArgument { case create, edit, addRow = "add-row", removeRow = "remove-row", addColumn = "add-column", removeColumn = "remove-column" }
struct NativeTableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-table", shouldDisplay: false)
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var action: LegacyTableAction; @Argument var ref: String; @Option var rows: String?; @Option var attachmentID: String?; @Option var row: Int?; @Option var column: Int?
    @Option var text: String?; @Option var index: Int?; @Option var position: Int?
    func run() throws {
        switch action {
        case .create: try UnifiedNative.tableCreate(options, write, ref: ref, rows: try JSONDecoder().decode([[String]].self, from: Data(try required(rows, "--rows").utf8)), position: position)
        case .edit: try UnifiedNative.tableSet(options, write, ref: ref, id: try required(attachmentID, "--attachment-id"), row: try required(row, "--row"), column: try required(column, "--column"), text: try required(text, "--text"))
        case .addRow, .removeRow, .addColumn, .removeColumn:
            let axis = action == .addRow || action == .removeRow ? "row" : "column", add = action == .addRow || action == .addColumn
            try UnifiedNative.tableResize(options, write, ref: ref, id: try required(attachmentID, "--attachment-id"), axis: axis, index: try required(index, "--index"), add: add)
        }
    }
}
struct NativeDuplicate: ParsableCommand { static let configuration = CommandConfiguration(commandName: "native-duplicate", shouldDisplay: false); @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Option var title: String?; func run() throws { try UnifiedNative.duplicate(options, write, ref: ref, title: title) } }
struct NativeRestore: ParsableCommand { static let configuration = CommandConfiguration(commandName: "native-restore", shouldDisplay: false); @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Option var folder: String?; func run() throws { try UnifiedNative.restore(options, write, ref: ref, folder: folder) } }
struct NativeMoveFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-move-folder", shouldDisplay: false)
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Option var parent: String?
    func run() throws {
        try unifiedNativeFolderMove(options: options, write: write, ref: ref, parent: parent)
    }
}
struct NativeWriteMarkdown: ParsableCommand { static let configuration = CommandConfiguration(commandName: "write-markdown", shouldDisplay: false); @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions; @Argument var ref: String; @Option var body: String?; @Flag var stdin = false; @Option var file: String?; @Flag var backup = false; func validate() throws { try validateBodySources(body: body, stdin: stdin, file: file) }; func run() throws { try UnifiedNative.writeMarkdown(options, write, ref: ref, body: try inputBody(body: body, stdin: stdin, file: file), backup: backup) } }

private func required<T>(_ value: T?, _ option: String) throws -> T {
    guard let value else { throw ValidationError("Provide \(option).") }
    return value
}
