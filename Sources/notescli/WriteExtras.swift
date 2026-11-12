import AppKit
import ArgumentParser
import Foundation
import NotesAutomation
import NotesCore
import NotesMCP
import NotesNative

func writeExtraCreate(options: GlobalOptions, write: WriteOptions, title: String, folder: String?, markdown: String, paths: [String]) throws {
    let backend = try options.writable()
    _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
    let targetPath = try SafetyExecutor.folderPath(folder, reader: backend.reader)
    let plan = DryRunPlan(operation: "createNote", target: title,
                          arguments: ["folder": folder ?? "", "attachments": paths.joined(separator: ",")],
                          resultingHTML: SafetyExecutor.bodyHTML(title: title, markdown: markdown), engine: "native")
    var captured: NativeCreateResult?
    let result = try SafetyExecutor.run(options: write, operation: "createNote",
        arguments: ["title": title, "body": markdown, "folder": folder ?? "", "attachments": paths.joined(separator: ","), "engine": "native"],
        allowedPaths: targetPath.map { [$0] } ?? [], plan: plan) {
            let frozen = try paths.map { try FrozenAttachmentInput(file: URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)) }
            let value = try NativeNotesWriter().createNote(title: title, markdown: markdown, folder: folder,
                                                           attachments: frozen, allowShared: write.allowShared)
            captured = value
            return value.write.writeResult
        }
    guard let result else { return }
    let details = captured.map {
        ["attachment_ids": $0.attachmentIDs.joined(separator: ","),
         "attachment_sha256": $0.attachmentSHA256.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")]
    }
    try outputEngineWrite(EngineWriteResponse(engine: "native", result: result,
                                              operationID: captured?.write.operationID,
                                              verification: captured?.write.verification, details: details), options: options)
}

func frozenPasteboardInput() throws -> FrozenAttachmentInput {
    let pasteboard = NSPasteboard.general
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
       let url = urls.first {
        return try FrozenAttachmentInput(file: url)
    }
    let types: [(NSPasteboard.PasteboardType, String)] = [
        (.init("public.png"), "pasteboard.png"), (.tiff, "pasteboard.tiff"),
        (.init("com.adobe.pdf"), "pasteboard.pdf"), (.init("public.data"), "pasteboard.bin")
    ]
    for (type, name) in types {
        if let data = pasteboard.data(forType: type), !data.isEmpty { return try FrozenAttachmentInput(data: data, suggestedName: name) }
    }
    throw NotesError("pasteboard_attachment_missing", "The pasteboard has no file or supported binary content.")
}

func writeExtraAttach(options: GlobalOptions, write: WriteOptions, ref: String, path: String?, pasteboard: Bool,
                      position: Int?, view: String?) throws {
    let backend = try options.writable()
    _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
    let note = try backend.reader.note(ref)
    var captured: NativeAttachmentResult?
    let source = pasteboard ? "pasteboard" : path!
    let plan = DryRunPlan(operation: pasteboard ? "attachPasteboard" : "attachFile", target: note.summary.id.uuid,
                          arguments: ["source": source, "position": position.map(String.init) ?? ""],
                          resultingHTML: SafetyExecutor.html(note), engine: "native")
    let result = try SafetyExecutor.run(options: write, operation: pasteboard ? "attachPasteboard" : "attachFile",
        arguments: ["ref": note.summary.id.uuid, "source": source, "position": position.map(String.init) ?? "", "engine": "native"],
        note: note, allowedPaths: [note.summary.folderPath], destructive: true, plan: plan) {
            let frozen = try pasteboard ? frozenPasteboardInput() : FrozenAttachmentInput(file: URL(fileURLWithPath: NSString(string: path!).expandingTildeInPath))
            let value = try NativeNotesWriter().insertFrozenFile(note.summary.id.uuid, frozen: frozen, position: position,
                                                                 imageView: view, allowShared: write.allowShared)
            captured = value
            return value.write.writeResult
        }
    guard let result else { return }
    let details = captured.map { ["attachment_id": $0.attachmentID, "source_sha256": $0.sourceSHA256 ?? "", "stored_sha256": $0.storedSHA256 ?? ""] }
    try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.write.operationID,
                                              verification: captured?.write.verification, details: details), options: options)
}

func writeExtraEdit(options: GlobalOptions, write: WriteOptions, ref: String) throws {
    let backend = try options.writable(), note = try backend.reader.note(ref)
    guard !note.summary.isLocked else { throw NotesError("note_locked", "The note is locked.") }
    let selected = try UnifiedNative.engine(options, scriptingAvailable: true, fake: backend.isFake)
    if selected == .scripting {
        try SafetyExecutor.requireAttachmentSafety(note, allowLoss: write.allowAttachmentLoss)
        Output.error("Warning: replacing the body may downgrade attachments and checklists.")
    }
    guard let document = note.document else { throw NotesError("note_locked", "The note body is unavailable.") }
    let portableAttachments = note.attachments.map { attachment -> Attachment in
        var copy = attachment; copy.filePath = nil; copy.url = nil; copy.pageImagePaths = nil; copy.fallbackRasterPath = nil; return copy
    }
    let original = NoteRenderer.markdown(document, attachments: portableAttachments)
    let edited = try editor(original)
    if edited == original {
        try outputEngineWrite(EngineWriteResponse(engine: selected.rawValue,
                                                  result: WriteResult(outcome: .verified, noteID: note.summary.id, message: "Unchanged; no write made.")), options: options)
        return
    }
    let plan = DryRunPlan(operation: "edit", target: note.summary.id.uuid, arguments: [:],
                          resultingHTML: SafetyExecutor.bodyHTML(title: note.summary.title, markdown: edited), engine: selected.rawValue)
    var native: NativeWriteResult?
    let result = try SafetyExecutor.run(options: write, operation: "edit",
        arguments: ["ref": note.summary.id.uuid, "body": edited, "engine": selected.rawValue], note: note,
        allowedPaths: [note.summary.folderPath], destructive: true, plan: plan) {
            switch selected {
            case .native:
                let value = try NativeNotesWriter().writeMarkdown(note.summary.id.uuid, markdown: edited, dryRun: false,
                                                                  backup: false, allowShared: write.allowShared)
                native = value; return value.writeResult
            case .scripting:
                return try backend.writer().replaceBody(note.summary.id.uuid, markdown: edited, allowAttachmentLoss: write.allowAttachmentLoss)
            }
        }
    guard let result else { return }
    try outputEngineWrite(EngineWriteResponse(engine: selected.rawValue, result: result, operationID: native?.operationID,
                                              verification: native?.verification), options: options)
}

struct LinkAddURL: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-url")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var url: String
    @Flag var card = false
    @Option var position: Int?

    func run() throws {
        guard let parsed = URL(string: url) else { throw NotesError("invalid_url", "The URL is invalid.") }
        try UnifiedNative.noteWrite(options: options, write: write, ref: ref, operation: "linkAddURL",
                                    arguments: ["url": url, "card": String(card), "position": position.map(String.init) ?? ""],
                                    native: { stableRef in
            NativeActionResult(try NativeNotesWriter().insertURL(stableRef, url: parsed, card: card, position: position,
                                                                 allowShared: write.allowShared))
        })
    }
}

enum SmartFolderMatch: String, ExpressibleByArgument { case any, all }

struct SmartFolderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-folder", subcommands: [SmartFolderCreate.self, SmartFolderRename.self, SmartFolderEditRules.self, SmartFolderEditTyped.self, SmartFolderDelete.self])
}

struct SmartFolderCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var name: String
    @Option var tags: String
    @Option var match: SmartFolderMatch

    func run() throws {
        let backend = try options.writable(); _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let values = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let plan = DryRunPlan(operation: "smartFolderCreate", target: name,
                              arguments: ["tags": values.joined(separator: ","), "match": match.rawValue], resultingHTML: nil, engine: "native")
        var captured: NativeWriteResult?
        let result = try SafetyExecutor.run(options: write, operation: "smartFolderCreate",
            arguments: ["name": name, "tags": values.joined(separator: ","), "match": match.rawValue, "engine": "native"],
            allowedPaths: [[name]], plan: plan) {
                let value = try NativeNotesWriter().createSmartFolder(name: name, tags: values, matchAll: match == .all)
                captured = value; return value.writeResult
            }
        guard let result else { return }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.operationID,
                                                  verification: captured?.verification), options: options)
    }
}

private func smartFolderWrite(options: GlobalOptions, write: WriteOptions, ref: String, name: String?, expected: Int, delete: Bool) throws {
    let backend = try options.writable(); _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
    let folder = try SafetyExecutor.folder(ref, reader: backend.reader)
    guard let folder, folder.isSmartFolder else { throw NotesError("smart_folder_not_found", "No Smart Folder matches the reference.") }
    let operation = delete ? "smartFolderDelete" : "smartFolderRename"
    let plan = DryRunPlan(operation: operation, target: folder.id,
                          arguments: ["name": name ?? "", "expected_count": String(expected)], resultingHTML: nil, engine: "native")
    var captured: NativeWriteResult?
    let result = try SafetyExecutor.run(options: write, operation: operation,
        arguments: ["ref": folder.id, "name": name ?? "", "expected_count": String(expected), "engine": "native"],
        allowedPaths: [folder.path], destructive: true, plan: plan) {
            let writer = NativeNotesWriter()
            let value = try delete ? writer.deleteSmartFolder(folder.id, expectedCount: expected)
                                   : writer.renameSmartFolder(folder.id, name: name!, expectedCount: expected)
            captured = value; return value.writeResult
        }
    guard let result else { return }
    try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.operationID,
                                              verification: captured?.verification), options: options)
}

struct SmartFolderRename: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var name: String; @Option var expectedCount: Int
    func run() throws { try smartFolderWrite(options: options, write: write, ref: ref, name: name, expected: expectedCount, delete: false) }
}

struct SmartFolderEditRules: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit-rules")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Option var queryJSON: String; @Option var expectedCount: Int
    func run() throws {
        let backend = try options.writable(); _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let folder = try SafetyExecutor.folder(ref, reader: backend.reader)
        guard let folder, folder.isSmartFolder else { throw NotesError("smart_folder_not_found", "No Smart Folder matches the reference.") }
        let writer = NativeNotesWriter(), previousQuery = try writer.smartFolderQuery(folder.id)
        let plan = DryRunPlan(operation: "smartFolderEditRules", target: folder.id, arguments: ["query_json": queryJSON, "expected_count": String(expectedCount)], resultingHTML: nil, engine: "native")
        var captured: NativeWriteResult?
        let result = try SafetyExecutor.run(options: write, operation: "smartFolderEditRules", arguments: ["ref": folder.id, "stable_id": folder.id, "query_json": queryJSON, "previous_query_json": previousQuery, "expected_count": String(expectedCount), "engine": "native"], allowedPaths: [folder.path], destructive: true, plan: plan) {
            let value = try writer.editSmartFolderRules(folder.id, queryJSON: queryJSON, expectedCount: expectedCount); captured = value; return value.writeResult
        }
        guard let result else { return }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.operationID, verification: captured?.verification), options: options)
    }
}

struct SmartFolderEditTyped: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit-typed")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Option var expectedCount: Int
    @Option var match: SmartFolderMatch = .all; @Option var tags: String?; @Option var tagsMatch: SmartFolderMatch = .any
    @Option var createdFrom: String?; @Option var createdTo: String?; @Option var modifiedFrom: String?; @Option var modifiedTo: String?
    @Option var folders: String?; @Option var checklists: Bool?; @Option var attachments: String?
    @Option var shared: Bool?; @Option var locked: Bool?; @Option var mentions: Bool?; @Option var quickNotes: Bool?
    func run() throws {
        let backend = try options.writable(); _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let folder = try SafetyExecutor.folder(ref, reader: backend.reader)
        guard let folder, folder.isSmartFolder else { throw NotesError("smart_folder_not_found", "No Smart Folder matches the reference.") }
        let writer = NativeNotesWriter(), previousQuery = try writer.smartFolderQuery(folder.id)
        let sections = try csvValues(attachments).map { value -> SmartFolderAttachmentSection in
            guard let section = SmartFolderAttachmentSection(name: value) else { throw ValidationError("Unknown attachment rule: \(value).") }
            return section
        }
        let rules = SmartFolderRules(match: match == .all ? .all : .any, tags: csvValues(tags), tagsMatch: tagsMatch == .all ? .all : .any,
                                     createdFrom: try createdFrom.map { try NotePresentation.date($0) }, createdTo: try createdTo.map { try NotePresentation.date($0) },
                                     modifiedFrom: try modifiedFrom.map { try NotePresentation.date($0) }, modifiedTo: try modifiedTo.map { try NotePresentation.date($0) },
                                     folders: csvValues(folders), checklists: checklists, attachmentSections: sections,
                                     shared: shared, locked: locked, mentions: mentions, quickNotes: quickNotes)
        let queryJSON = try rules.json()
        let plan = DryRunPlan(operation: "smartFolderEditTyped", target: folder.id, arguments: ["query_json": queryJSON, "expected_count": String(expectedCount)], resultingHTML: nil, engine: "native")
        var captured: NativeWriteResult?
        let result = try SafetyExecutor.run(options: write, operation: "smartFolderEditTyped", arguments: ["ref": folder.id, "stable_id": folder.id, "query_json": queryJSON, "previous_query_json": previousQuery, "expected_count": String(expectedCount), "engine": "native"], allowedPaths: [folder.path], destructive: true, plan: plan) {
            let value = try writer.editSmartFolderRules(folder.id, queryJSON: queryJSON, expectedCount: expectedCount); captured = value; return value.writeResult
        }
        guard let result else { return }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.operationID, verification: captured?.verification), options: options)
    }
    private func csvValues(_ text: String?) -> [String] { text?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? [] }
}

struct SmartFolderDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Option var expectedCount: Int
    func run() throws { try smartFolderWrite(options: options, write: write, ref: ref, name: nil, expected: expectedCount, delete: true) }
}
