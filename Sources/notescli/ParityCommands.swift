import ArgumentParser
import Foundation
import NotesCore
import NotesNative
import NotesSafety
import NotesStore

struct MapCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "map", subcommands: [MapAddCommand.self])
}

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scan", subcommands: [ScanAddCommand.self, ScanAppendCommand.self, ScanStateCommand.self, ScanFilterCommand.self, ScanRotateCommand.self, ScanCropCommand.self, ScanMoveCommand.self, ScanDeleteCommand.self])
}

struct ScanStateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "state", abstract: "Read a scanned-document page's native edit state.")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String; @Argument var attachmentID: String; @Argument var pageID: String
    func run() throws {
        try UnifiedNative.read(options, ref: ref) {
            try NativeNotesWriter().scanPageState($0, attachmentID: attachmentID, pageID: pageID)
        }
    }
}

struct ScanFilterCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "filter", abstract: "Apply a native filter to one scanned-document page.")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var attachmentID: String; @Argument var pageID: String
    @Argument var filter: NativeScanFilter
    func run() throws { try UnifiedNative.scanFilter(options, write, ref: ref, attachmentID: attachmentID, pageID: pageID, filter: filter) }
}

struct ScanRotateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rotate", abstract: "Set a scanned-document page orientation.")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var attachmentID: String; @Argument var pageID: String
    @Argument var orientation: NativeScanOrientation
    func run() throws { try UnifiedNative.scanOrientation(options, write, ref: ref, attachmentID: attachmentID, pageID: pageID, orientation: orientation) }
}

struct ScanMoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move a scanned-document page to a zero-based index.")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var attachmentID: String; @Argument var pageID: String
    @Argument var toIndex: Int
    func run() throws { try UnifiedNative.scanMove(options, write, ref: ref, attachmentID: attachmentID, pageID: pageID, toIndex: toIndex) }
}

struct ScanCropCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "crop", abstract: "Set or detect a scanned-document page crop.")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var attachmentID: String; @Argument var pageID: String
    @Option(help: "Normalized x,y point.") var bottomLeft: ScanPoint?
    @Option(help: "Normalized x,y point.") var bottomRight: ScanPoint?
    @Option(help: "Normalized x,y point.") var topLeft: ScanPoint?
    @Option(help: "Normalized x,y point.") var topRight: ScanPoint?
    @Flag(help: "Detect document edges with Vision and store the resulting crop.") var detectEdges = false
    func validate() throws {
        let points = [bottomLeft, bottomRight, topLeft, topRight]
        if detectEdges && points.contains(where: { $0 != nil }) {
            throw ValidationError("Choose either --detect-edges or all four crop points.")
        }
        if !detectEdges && !points.allSatisfy({ $0 != nil }) {
            throw ValidationError("Provide --detect-edges or all four crop points.")
        }
    }
    func run() throws {
        let crop = bottomLeft.flatMap { bottomLeft in
            bottomRight.flatMap { bottomRight in
                topLeft.flatMap { topLeft in
                    topRight.map { ScanCrop(bottomLeft: bottomLeft, bottomRight: bottomRight,
                                            topLeft: topLeft, topRight: $0) }
                }
            }
        }
        try UnifiedNative.scanCrop(options, write, ref: ref, attachmentID: attachmentID, pageID: pageID,
                                   crop: crop, detectEdges: detectEdges)
    }
}

struct ScanDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete one page from a multi-page scanned document.")
    @OptionGroup var options: GlobalOptions; @OptionGroup var write: WriteOptions
    @Argument var ref: String; @Argument var attachmentID: String; @Argument var pageID: String
    func run() throws {
        try UnifiedNative.scanDelete(options, write, ref: ref, attachmentID: attachmentID, pageID: pageID)
    }
}

struct MathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "math", subcommands: [MathEvaluateCommand.self, MathInsertResultCommand.self])
}

struct MathEvaluateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "evaluate", abstract: "Evaluate an expression with Apple's Calculate framework.")
    @OptionGroup var options: GlobalOptions
    @Argument var expression: String

    func run() throws {
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: false)
        let value = try NativeNotesWriter().evaluateMath(expression)
        if options.json { try Output.json(value) }
        else { Output.table(["EXPRESSION", "RESULT", "TEXT"], [[value.formattedExpression, value.result, value.renderedText]]) }
    }
}

struct MathInsertResultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "insert-result", abstract: "Insert an evaluated expression as Notes-compatible plain text.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var expression: String
    @Option var position: Int?

    func run() throws {
        try UnifiedNative.mathResultInsert(options, write, ref: ref, expression: expression, position: position)
    }
}

struct QuickNoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "quick-note", subcommands: [QuickNoteCreateCommand.self, QuickNoteSetCommand.self])
}

struct QuickNoteCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a native Quick Note.")
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
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let markdown = try inputBody(body: body, stdin: stdin, file: file, allowEditor: true)
        let targetPath = try SafetyExecutor.folderPath(folder, reader: backend.reader)
        let arguments = ["title": title, "body": markdown, "folder": folder ?? "", "engine": "native"]
        let plan = DryRunPlan(operation: "createQuickNote", target: title, arguments: arguments,
                              resultingHTML: SafetyExecutor.bodyHTML(title: title, markdown: markdown), engine: "native")
        var captured: NativeCreateResult?
        let result = try SafetyExecutor.run(options: write, operation: "createQuickNote", arguments: arguments,
                                            allowedPaths: targetPath.map { [$0] } ?? [], plan: plan) {
            if backend.isFake { return try backend.writer().createNote(title: title, markdown: markdown, folder: folder) }
            let value = try NativeNotesWriter().createQuickNote(title: title, markdown: markdown, folder: folder,
                                                                 allowShared: write.allowShared)
            captured = value
            return value.write.writeResult
        }
        guard let result else { return }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result,
                                                  operationID: captured?.write.operationID,
                                                  verification: captured?.write.verification), options: options)
    }
}

struct QuickNoteSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Convert a note to or from a native Quick Note.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Option var enabled: Bool
    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let note = try backend.reader.note(ref)
        let previous = note.summary.isSystemPaper == true
        let arguments = ["ref": note.summary.id.uuid, "enabled": String(enabled),
                         "previous_enabled": String(previous), "engine": "native"]
        let plan = DryRunPlan(operation: "setQuickNote", target: note.summary.id.uuid, arguments: arguments,
                              resultingHTML: SafetyExecutor.html(note), engine: "native")
        var captured: NativeWriteResult?
        let result = try SafetyExecutor.run(options: write, operation: "setQuickNote", arguments: arguments,
                                            note: note, allowedPaths: [note.summary.folderPath], destructive: true, plan: plan) {
            if backend.isFake { return FakeParityWrite.result(note, storing: "Quick Note state") }
            let value = try NativeNotesWriter().setQuickNote(note.summary.id.uuid, enabled: enabled,
                                                             expectedCurrent: previous,
                                                             allowShared: write.allowShared)
            captured = value
            return value.writeResult
        }
        guard let result else { return }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result,
                                                  operationID: captured?.operationID,
                                                  verification: captured?.verification), options: options)
    }
}

enum FakeParityWrite {
    static func result(_ note: Note, storing kind: String) -> WriteResult {
        WriteResult(outcome: .unverified, noteID: note.summary.id,
                    message: "The fake backend does not store \(kind); Apple Notes was not changed.")
    }

    static func folder(_ folder: Folder, storing kind: String) -> WriteResult {
        WriteResult(outcome: .unverified, folderID: folder.id,
                    message: "The fake backend does not store \(kind); Apple Notes was not changed.")
    }

    static let settings = NativeNotesSettings(
        sort: .modified, groupsByDate: true, defaultTextSize: 12, resumesLastQuickNote: true, autoConvertsToTags: true,
        defaultParagraphStyle: .title, checklistAutoSort: false, defaultAccountID: "fake-account",
        preferences: NativeNotesPreference.allCases.map { NativePreferenceValue(setting: $0, state: .default) },
        noteContainerView: NativeNoteContainerViewState(mode: "list", preferredMode: nil, galleryItemSizeRatio: 1))

    static func setting(_ kind: String) -> WriteResult {
        WriteResult(outcome: .unverified,
                    message: "The fake backend does not store \(kind); Apple Notes was not changed.")
    }
}

struct ScanAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a native scanned document from image pages.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument(help: "Image files in page order.") var images: [String] = []
    @Option var position: Int?
    @Flag(help: "Detect edges and perspective-correct every page before insertion.") var perspectiveCorrect = false

    func validate() throws {
        guard (1...NativeNotesWriter.maximumScanPages).contains(images.count) else {
            throw ValidationError("Provide between 1 and \(NativeNotesWriter.maximumScanPages) image pages.")
        }
    }

    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let note = try backend.reader.note(ref)
        let paths = try images.map {
            try InputFile.validated(URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath),
                                    kind: "scan image", maxBytes: FrozenAttachmentInput.maxBytes)
        }
        let sourcePages = try paths.map(FrozenAttachmentInput.init(file:))
        try ScanCorrection.validateImages(at: sourcePages.map(\.url), requireUpOrientation: perspectiveCorrect)
        let sourceHashes = sourcePages.map(\.sha256).joined(separator: ",")
        var finalHashes = perspectiveCorrect ? "" : sourceHashes
        // Hex digests contain no commas, so the joined list stays unambiguous and records no local paths.
        let arguments = ["ref": note.summary.id.uuid, "source_page_sha256": sourceHashes,
                         "page_sha256": finalHashes, "page_count": String(sourcePages.count),
                         "position": position.map(String.init) ?? "",
                         "perspective_correct": String(perspectiveCorrect), "engine": "native"]
        let plan = DryRunPlan(operation: "scanAdd", target: note.summary.id.uuid, arguments: arguments,
                              resultingHTML: SafetyExecutor.html(note), engine: "native")
        var captured: NativeScanResult?
        let result = try SafetyExecutor.run(options: write, operation: "scanAdd", arguments: arguments,
                                            note: note, allowedPaths: [note.summary.folderPath], destructive: true, plan: plan,
                                            capturePrivatePayloads: !backend.isFake,
                                            finishArguments: { ["page_sha256": finalHashes] }) {
            if backend.isFake { return FakeParityWrite.result(note, storing: "scanned documents") }
            let pages = perspectiveCorrect ? try sourcePages.map(ScanCorrection.correctedPage) : sourcePages
            finalHashes = pages.map(\.sha256).joined(separator: ",")
            let value = try NativeNotesWriter().insertScan(note.summary.id.uuid, pages: pages, position: position,
                                                           allowShared: write.allowShared)
            captured = value
            return value.write.writeResult
        }
        guard let result else { return }
        let details = captured.map { ["attachment_id": $0.attachmentID,
                                      "page_ids": $0.pageAttachmentIDs.joined(separator: ","),
                                      "page_count": String($0.pageAttachmentIDs.count),
                                      "position": String($0.position)] }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result,
                                                  operationID: captured?.write.operationID,
                                                  verification: captured?.write.verification,
                                                  details: details), options: options)
    }
}

struct ScanAppendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "append", abstract: "Append image pages to an existing native scanned document.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var attachmentID: String
    @Argument(help: "Image files in page order.") var images: [String] = []
    @Flag(help: "Detect edges and perspective-correct every page before appending.") var perspectiveCorrect = false

    func validate() throws {
        guard (1...NativeNotesWriter.maximumScanPages).contains(images.count) else {
            throw ValidationError("Provide between 1 and \(NativeNotesWriter.maximumScanPages) image pages.")
        }
    }

    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let note = try backend.reader.note(ref)
        guard let gallery = note.attachments.first(where: { $0.id == attachmentID && $0.typeUTI == "com.apple.notes.gallery" }),
              let previousPageIDs = gallery.childAttachmentIDs, !previousPageIDs.isEmpty else {
            throw NotesError("scan_not_found", "No readable scanned document matches the attachment ID in this note.")
        }
        let paths = try images.map {
            try InputFile.validated(URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath),
                                    kind: "scan image", maxBytes: FrozenAttachmentInput.maxBytes)
        }
        let sourcePages = try paths.map(FrozenAttachmentInput.init(file:))
        try ScanCorrection.validateImages(at: sourcePages.map(\.url), requireUpOrientation: perspectiveCorrect)
        let sourceHashes = sourcePages.map(\.sha256).joined(separator: ",")
        var finalHashes = perspectiveCorrect ? "" : sourceHashes
        let arguments = ["ref": note.summary.id.uuid, "attachment_id": attachmentID,
                         "source_page_sha256": sourceHashes, "page_sha256": finalHashes,
                         "page_count": String(sourcePages.count),
                         "perspective_correct": String(perspectiveCorrect),
                         "previous_page_order": previousPageIDs.joined(separator: ","), "engine": "native"]
        let plan = DryRunPlan(operation: "scanAppend", target: note.summary.id.uuid, arguments: arguments,
                              resultingHTML: SafetyExecutor.html(note), engine: "native")
        var captured: NativeScanResult?
        let result = try SafetyExecutor.run(options: write, operation: "scanAppend", arguments: arguments,
                                            note: note, allowedPaths: [note.summary.folderPath],
                                            destructive: true, plan: plan,
                                            capturePrivatePayloads: !backend.isFake, finishArguments: {
            var values = ["page_sha256": finalHashes]
            if let captured {
                values["created_page_ids"] = captured.pageAttachmentIDs.joined(separator: ",")
                values["applied_page_order"] = (previousPageIDs + captured.pageAttachmentIDs).joined(separator: ",")
            }
            return values
        }) {
            if backend.isFake { return FakeParityWrite.result(note, storing: "scanned document pages") }
            let pages = perspectiveCorrect ? try sourcePages.map(ScanCorrection.correctedPage) : sourcePages
            finalHashes = pages.map(\.sha256).joined(separator: ",")
            let value = try NativeNotesWriter().appendScanPages(
                note.summary.id.uuid, attachmentID: attachmentID, pages: pages,
                expectedPageIDs: previousPageIDs, allowShared: write.allowShared)
            captured = value
            return value.write.writeResult
        }
        guard let result else { return }
        let details = captured.map { ["attachment_id": $0.attachmentID,
                                      "page_ids": $0.pageAttachmentIDs.joined(separator: ","),
                                      "page_count": String($0.pageAttachmentIDs.count)] }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result,
                                                  operationID: captured?.write.operationID,
                                                  verification: captured?.write.verification,
                                                  details: details), options: options)
    }
}

struct MapAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Insert a native Apple Maps card.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var url: String
    @Option var position: Int?

    func run() throws {
        guard let parsed = URL(string: url) else { throw NotesError("invalid_map_url", "The Apple Maps URL is invalid.") }
        try NativeMapURL.validate(parsed)
        let backend = try options.writable(), note = try backend.reader.note(ref)
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let arguments = ["ref": note.summary.id.uuid, "url": url, "position": position.map(String.init) ?? "", "engine": "native"]
        let plan = DryRunPlan(operation: "mapAdd", target: note.summary.id.uuid, arguments: arguments,
                              resultingHTML: SafetyExecutor.html(note), engine: "native")
        var captured: NativeActionResult?
        let result = try SafetyExecutor.run(options: write, operation: "mapAdd", arguments: arguments,
                                            note: note, allowedPaths: [note.summary.folderPath], destructive: true, plan: plan,
                                            capturePrivatePayloads: !backend.isFake) {
            if backend.isFake { return FakeParityWrite.result(note, storing: "map cards") }
            let value = NativeActionResult(try NativeNotesWriter().insertMap(note.summary.id.uuid, url: parsed, position: position,
                                                                             allowShared: write.allowShared))
            captured = value
            return value.result
        }
        guard let result else { return }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.operationID,
                                                  verification: captured?.verification, details: captured?.details), options: options)
    }
}

struct FolderGroupByDateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "group-by-date", abstract: "Read or change date grouping for a folder.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Option(help: "Enable or disable date grouping.") var enabled: Bool?

    func run() throws {
        let backend = try enabled == nil ? options.backends() : options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let folder = try SafetyExecutor.folder(ref, reader: backend.reader)
        guard let folder, !folder.isSmartFolder, !folder.isRecentlyDeleted else {
            throw NotesError("folder_not_found", "No writable folder matches the reference.")
        }
        let writer = NativeNotesWriter()
        guard let enabled else {
            let value = backend.isFake ? false : try writer.folderSort(folder.id).groupsByDate
            if options.json { try Output.json(["folderID": folder.id, "enabled": String(value)]) }
            else { Output.table(["FOLDER", "GROUPED BY DATE"], [[folder.path.joined(separator: " > "), String(value)]]) }
            return
        }
        let previousType = backend.isFake ? 0 : try SQLiteNotesStore(refresh: true).folderDateHeadersType(folder.id)
        let arguments = ["ref": folder.id, "stable_id": folder.id, "enabled": String(enabled),
                         "previous_type": String(previousType), "engine": "native"]
        let plan = DryRunPlan(operation: "folderDateGrouping", target: folder.id, arguments: arguments,
                              resultingHTML: nil, engine: "native")
        var captured: NativeWriteResult?
        let result = try SafetyExecutor.run(options: write, operation: "folderDateGrouping", arguments: arguments,
                                            allowedPaths: [folder.path], plan: plan) {
            if backend.isFake { return FakeParityWrite.folder(folder, storing: "folder date grouping") }
            let value = try writer.setFolderDateGrouping(folder.id, type: enabled ? 2 : 1,
                                                          expectedCurrentType: previousType,
                                                          allowShared: write.allowShared)
            captured = value
            return value.writeResult
        }
        guard let result else { return }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result,
                                                  operationID: captured?.operationID,
                                                  verification: captured?.verification), options: options)
    }
}

struct SettingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "settings", subcommands: [
        SettingsShowCommand.self, GlobalNoteSortCommand.self, GlobalDateGroupingCommand.self,
        DefaultTextSizeCommand.self, ResumeQuickNoteCommand.self, AutoConvertTagsCommand.self,
        DefaultParagraphStyleCommand.self, QueryDateGroupingCommand.self, AutoFormatMarkdownCommand.self,
        DarkBackgroundsCommand.self, ShowNoteCountCommand.self, NoteContainerViewCommand.self
    ])
}

private func runSettingWrite(options: GlobalOptions, write: WriteOptions, operation: String,
                             arguments: [String: String], description: String,
                             action: () throws -> NativeWriteResult) throws {
    let backend = try options.writable()
    _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
    let recorded = arguments.merging(["engine": "native"]) { $1 }
    let plan = DryRunPlan(operation: operation, target: "Notes settings", arguments: recorded,
                          resultingHTML: nil, engine: "native")
    var captured: NativeWriteResult?
    let result = try SafetyExecutor.run(options: write, operation: operation, arguments: recorded,
                                        allowedPaths: [], plan: plan) {
        if backend.isFake { return FakeParityWrite.setting(description) }
        let value = try action(); captured = value; return value.writeResult
    }
    guard let result else { return }
    try outputEngineWrite(EngineWriteResponse(engine: "native", result: result,
                                              operationID: captured?.operationID,
                                              verification: captured?.verification), options: options)
}

struct SettingsShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show Notes' global settings.")
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let backend = try options.backends()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let settings = backend.isFake ? FakeParityWrite.settings : try NativeNotesWriter().notesSettings()
        if options.json { try Output.json(settings) }
        else {
            var rows = [
                ["sort", settings.sort.rawValue], ["group-by-date", String(settings.groupsByDate)],
                ["default-text-size", String(settings.defaultTextSize)],
                ["resume-quick-note", String(settings.resumesLastQuickNote)],
                ["auto-convert-tags", String(settings.autoConvertsToTags)],
                ["default-style", settings.defaultParagraphStyle?.rawValue ?? ""],
                ["checklist-auto-sort", settings.checklistAutoSort.map(String.init) ?? ""],
                ["default-account", settings.defaultAccountID ?? ""],
            ]
            for setting in NativeNotesPreference.allCases {
                rows.append([setting.rawValue, settings[setting].map(preferenceText) ?? ""])
            }
            rows.append(["view", settings.noteContainerView?.mode ?? "unknown"])
            Output.table(["SETTING", "VALUE"], rows)
        }
    }
}

private func preferenceText(_ value: NativePreferenceValue) -> String {
    value.state == .default ? "\(value.enabled) (Notes default)" : String(value.enabled)
}

/// Reads or changes one simple Notes preference stored in Notes' real container files.
private func runPreferenceCommand(_ setting: NativeNotesPreference, enabled: Bool?, options: GlobalOptions,
                                  write: WriteOptions) throws {
    let backend = try options.backends()
    _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
    let current = backend.isFake ? NativePreferenceValue(setting: setting, state: .default)
                                 : try NativeNotesWriter().notesPreference(setting)
    guard let enabled else {
        if options.json { try Output.json(current) }
        else { Output.table(["SETTING", "VALUE"], [[setting.rawValue, preferenceText(current)]]) }
        return
    }
    let state: NativePreferenceState = enabled ? .on : .off
    try runSettingWrite(options: options, write: write, operation: "notesPreference",
                        arguments: ["setting": setting.rawValue, "state": state.rawValue,
                                    "previous_state": current.state.rawValue],
                        description: "the \(setting.rawValue) setting") {
        try NativeNotesWriter().setNotesPreference(setting, state: state, expectedCurrent: current.state)
    }
}

struct QueryDateGroupingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "query-date-grouping",
        abstract: "Read or change date grouping for tag, search, and Smart Folder results.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option(help: "Set true or false.") var enabled: Bool?
    func run() throws { try runPreferenceCommand(.queryDateGrouping, enabled: enabled, options: options, write: write) }
}

struct AutoFormatMarkdownCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "auto-format-markdown",
        abstract: "Read or change whether Notes formats Markdown as you type.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option(help: "Set true or false.") var enabled: Bool?
    func run() throws { try runPreferenceCommand(.autoFormatMarkdown, enabled: enabled, options: options, write: write) }
}

struct DarkBackgroundsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dark-backgrounds",
        abstract: "Read or change \"Use dark backgrounds for note content\".")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option(help: "Set true or false.") var enabled: Bool?
    func run() throws { try runPreferenceCommand(.darkBackgrounds, enabled: enabled, options: options, write: write) }
}

struct ShowNoteCountCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show-note-count",
        abstract: "Read or change whether the folder list shows note counts.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option(help: "Set true or false.") var enabled: Bool?
    func run() throws { try runPreferenceCommand(.showNoteCount, enabled: enabled, options: options, write: write) }
}

struct NoteContainerViewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "view",
        abstract: "Read Notes' window-wide list or gallery mode from its last saved window state.")
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let backend = try options.backends()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let value = backend.isFake ? FakeParityWrite.settings.noteContainerView : try NativeNotesWriter().noteContainerView()
        guard let value else { throw NotesError("view_state_unavailable", "Notes has not saved a main window state yet.") }
        if options.json { try Output.json(value) }
        else {
            Output.table(["MODE", "PREFERRED", "GALLERY ITEM SIZE"],
                         [[value.mode, value.preferredMode ?? "", value.galleryItemSizeRatio.map { String($0) } ?? ""]])
        }
    }
}

struct GlobalNoteSortCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sort", abstract: "Read or change the global note sort.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option(help: "Set modified, created, or title.") var set: NativeGlobalNoteSort?
    func run() throws {
        guard let set else {
            let backend = try options.backends()
            _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
            let value: NativeGlobalNoteSort = backend.isFake ? .modified : try NativeNotesWriter().notesSettings().sort
            if options.json { try Output.json(["sort": value.rawValue]) }
            else { Output.table(["SORT"], [[value.rawValue]]) }
            return
        }
        let backend = try options.backends()
        let previous: NativeGlobalNoteSort = backend.isFake ? .modified : try NativeNotesWriter().notesSettings().sort
        try runSettingWrite(options: options, write: write, operation: "globalNoteSort",
                            arguments: ["sort": set.rawValue, "previous_sort": previous.rawValue],
                            description: "the global note sort") {
            try NativeNotesWriter().setGlobalNoteSort(set, expectedCurrent: previous)
        }
    }
}

struct GlobalDateGroupingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "group-by-date", abstract: "Read or change global date grouping.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option var enabled: Bool?
    func run() throws {
        guard let enabled else {
            let backend = try options.backends()
            _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
            let value = backend.isFake ? true : try NativeNotesWriter().notesSettings().groupsByDate
            if options.json { try Output.json(["enabled": value]) }
            else { Output.table(["GROUP BY DATE"], [[String(value)]]) }
            return
        }
        let backend = try options.backends()
        let previous = backend.isFake ? true : try NativeNotesWriter().notesSettings().groupsByDate
        try runSettingWrite(options: options, write: write, operation: "globalDateGrouping",
                            arguments: ["enabled": String(enabled), "previous_enabled": String(previous)],
                            description: "global date grouping") {
            try NativeNotesWriter().setGlobalDateGrouping(enabled, expectedCurrent: previous)
        }
    }
}

struct DefaultTextSizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "default-text-size", abstract: "Read or change the default note text size.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option(help: "Set 10, 12, 14, 18, or 24 points.") var points: Int?
    func validate() throws {
        if let points, ![10, 12, 14, 18, 24].contains(points) { throw ValidationError("Use 10, 12, 14, 18, or 24 points.") }
    }
    func run() throws {
        guard let points else {
            let backend = try options.backends()
            _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
            let value = backend.isFake ? 12 : try NativeNotesWriter().notesSettings().defaultTextSize
            if options.json { try Output.json(["points": value]) }
            else { Output.table(["POINTS"], [[String(value)]]) }
            return
        }
        let backend = try options.backends()
        let previous = backend.isFake ? 12 : try NativeNotesWriter().notesSettings().defaultTextSize
        try runSettingWrite(options: options, write: write, operation: "defaultTextSize",
                            arguments: ["points": String(points), "previous_points": String(previous)],
                            description: "the default note text size") {
            try NativeNotesWriter().setDefaultTextSize(points, expectedCurrent: previous)
        }
    }
}

struct ResumeQuickNoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume-quick-note", abstract: "Read or change whether Quick Note resumes the last note.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option var enabled: Bool?
    func run() throws {
        guard let enabled else {
            let backend = try options.backends()
            _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
            let value = backend.isFake ? true : try NativeNotesWriter().notesSettings().resumesLastQuickNote
            if options.json { try Output.json(["enabled": value]) }
            else { Output.table(["RESUME LAST QUICK NOTE"], [[String(value)]]) }
            return
        }
        let backend = try options.backends()
        let previous = backend.isFake ? true : try NativeNotesWriter().notesSettings().resumesLastQuickNote
        try runSettingWrite(options: options, write: write, operation: "resumeLastQuickNote",
                            arguments: ["enabled": String(enabled), "previous_enabled": String(previous)],
                            description: "the Quick Note resume setting") {
            try NativeNotesWriter().setResumeLastQuickNote(enabled, expectedCurrent: previous)
        }
    }
}

struct AutoConvertTagsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "auto-convert-tags", abstract: "Read or change automatic tag conversion.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option(help: "Set true or false.") var enabled: Bool?
    func run() throws {
        guard let enabled else {
            let backend = try options.backends()
            _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
            let value = backend.isFake ? true : try NativeNotesWriter().notesSettings().autoConvertsToTags
            if options.json { try Output.json(["enabled": value]) }
            else { Output.table(["AUTO CONVERT TO TAGS"], [[String(value)]]) }
            return
        }
        let backend = try options.backends()
        let previous = backend.isFake ? true : try NativeNotesWriter().notesSettings().autoConvertsToTags
        try runSettingWrite(options: options, write: write, operation: "autoConvertToTags",
                            arguments: ["enabled": String(enabled), "previous_enabled": String(previous)],
                            description: "automatic tag conversion") {
            try NativeNotesWriter().setAutoConvertToTags(enabled, expectedCurrent: previous)
        }
    }
}

struct DefaultParagraphStyleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "default-style", abstract: "Read or change the style used for new notes.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option(help: "Set title, heading, subheading, or body.") var set: NativeDefaultParagraphStyle?

    func run() throws {
        let backend = try set == nil ? options.backends() : options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let writer = NativeNotesWriter()
        guard let set else {
            let value: NativeDefaultParagraphStyle = backend.isFake ? .title : try writer.defaultParagraphStyle()
            if options.json { try Output.json(["style": value.rawValue, "value": String(value.value)]) }
            else { Output.table(["DEFAULT STYLE"], [[value.rawValue]]) }
            return
        }
        let previous: NativeDefaultParagraphStyle = backend.isFake ? .title : try writer.defaultParagraphStyle()
        let arguments = ["style": set.rawValue, "previous_style": previous.rawValue, "engine": "native"]
        let plan = DryRunPlan(operation: "defaultParagraphStyle", target: "Notes settings", arguments: arguments,
                              resultingHTML: nil, engine: "native")
        var captured: NativeWriteResult?
        let result = try SafetyExecutor.run(options: write, operation: "defaultParagraphStyle", arguments: arguments,
                                            allowedPaths: [], plan: plan) {
            if backend.isFake { return FakeParityWrite.setting("the default paragraph style") }
            let value = try writer.setDefaultParagraphStyle(set, expectedCurrent: previous)
            captured = value
            return value.writeResult
        }
        guard let result else { return }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result,
                                                  operationID: captured?.operationID,
                                                  verification: captured?.verification), options: options)
    }
}
