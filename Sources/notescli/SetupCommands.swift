import AppKit
import ArgumentParser
import Darwin
import Foundation
import NotesAutomation
import NotesCore
import NotesDiagrams
import NotesHost
import NotesMCP
import NotesNative
import NotesSafety
import NotesStore
import PencilKit

enum MCPClient: String, CaseIterable, ExpressibleByArgument {
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case codex
    case cursor
    case vscode
    case tailscale
    case all

    static var concrete: [MCPClient] { [.claudeCode, .claudeDesktop, .codex, .cursor, .vscode] }
    static var installable: [MCPClient] { concrete + [.tailscale] }
    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .tailscale: return "Tailscale"
        case .all: return "All clients"
        }
    }
}

struct MCPRoot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run MCP on stdio or manage client connections.",
        subcommands: [MCPInstall.self, MCPUninstall.self, MCPStatus.self, MCPServe.self, MCPToken.self]
    )
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Expose opt-in tools that write through Apple's private Notes framework.") var allowNative = false

    func run() throws {
        let backend = try options.backends(live: true)
        let selectedWriter: (any NotesWriting)? = options.readOnly ? nil : try backend.writer()
        let handler: MCPNativeHandler? = allowNative ? { try mcpNativeCall($0, $1, reader: backend.reader) } : nil
        let environment = ProcessInfo.processInfo.environment
        let exposure: MCPToolExposureProfile = environment["NOTESCLI_MCP_REMOTE_SAFE"] == "1" ||
            environment["NOTESCLI_HOST_ACTIVE"] == "1" ? .remote : .local
        let server = MCPServer(reader: backend.reader, writer: selectedWriter, readOnly: options.readOnly,
                               allowNative: allowNative, nativeHandler: handler,
                               syncWaiter: { try NoteSyncWaiter.wait(noteID: $0, modifiedAfter: $1, timeout: $2) },
                               stateRoot: NotesSafetyPaths.applicationSupport, exposureProfile: exposure,
                               readFidelity: backend.fidelity.rawValue, unavailableReadFields: backend.unavailableFields)
        server.run()
    }
}

struct MCPServe: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "Run an MCP transport.", shouldDisplay: false)
    @Flag(help: "Serve authenticated Streamable HTTP on the configured loopback port.") var http = false

    func validate() throws {
        guard http else { throw ValidationError("Use --http.") }
    }

    func run() throws {
        let config = try TailscaleMCP.loadConfiguration()
        let backend = try Backends.make(nil, live: true)
        let writer: (any NotesWriting)? = config.readOnly ? nil : try backend.writer()
        let native: MCPNativeHandler? = config.allowNative ? { try mcpNativeCall($0, $1, reader: backend.reader) } : nil
        let mcp = MCPServer(reader: backend.reader, writer: writer, readOnly: config.readOnly,
                            allowNative: config.allowNative, nativeHandler: native,
                            syncWaiter: { try NoteSyncWaiter.wait(noteID: $0, modifiedAfter: $1, timeout: $2) },
                            writeFolders: config.writeFolders,
                            stateRoot: NotesSafetyPaths.applicationSupport, exposureProfile: .remote,
                            readFidelity: backend.fidelity.rawValue, unavailableReadFields: backend.unavailableFields)
        let endpoint = try HTTPMCPServer.Configuration(
            port: UInt16(config.port),
            tokenProvider: { (try? TailscaleMCP.loadConfiguration())?.token },
            allowedHosts: config.allowedHosts,
            allowedOrigins: config.allowedOrigins
        )
        let server = HTTPMCPServer(configuration: endpoint, handlerFactory: {
            let connection = mcp.makeConnection()
            return { mcp.handle($0, connection: connection) }
        })
        _ = try server.start()

        Darwin.signal(SIGTERM, SIG_IGN)
        Darwin.signal(SIGINT, SIG_IGN)
        let stopped = DispatchSemaphore(value: 0)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        term.setEventHandler { stopped.signal() }
        interrupt.setEventHandler { stopped.signal() }
        term.resume()
        interrupt.resume()
        MCPRunLoopWaiter.wait(for: stopped)
        server.stop()
    }
}

struct MCPToken: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "token", abstract: "Show or rotate the Tailscale MCP token.",
                                                    subcommands: [MCPTokenShow.self, MCPTokenRotate.self])
}

private struct MCPRemoteCredentials: Codable {
    var endpoint: String
    var token: String
}

struct MCPTokenShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show")
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let config = try TailscaleMCP.loadConfiguration()
        let value = MCPRemoteCredentials(endpoint: config.endpoint, token: config.token)
        if options.json { try Output.json(value) }
        else { Output.table(["ENDPOINT", "TOKEN"], [[value.endpoint, value.token]]) }
    }
}

struct MCPTokenRotate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rotate")
    @OptionGroup var options: GlobalOptions
    func run() throws {
        try TailscaleMCP.rotateToken()
        let config = try TailscaleMCP.loadConfiguration()
        let value = MCPRemoteCredentials(endpoint: config.endpoint, token: config.token)
        if options.json { try Output.json(value) }
        else { print("Rotated the Tailscale MCP token. Run 'notescli mcp token show' to display it.") }
    }
}

private struct MCPDrawingExportAttachment: Codable {
    var attachmentID: String
    var typeUTI: String
    var drawingCount: Int
    var strokeCount: Int
}

private struct MCPDrawingExportValue: Codable {
    var format: String
    var mediaType: String
    var encoding: String
    var data: String
    var strokeCount: Int
    var attachments: [MCPDrawingExportAttachment]
}

private func mcpNativeCall(_ tool: String, _ arguments: [String: Any], reader: any NotesReading) throws -> MCPNativeResult {
    func string(_ key: String) -> String? { arguments[key] as? String }
    func integer(_ key: String) -> Int? { (arguments[key] as? NSNumber)?.intValue }
    func boolean(_ key: String) -> Bool? { arguments[key] as? Bool }
    func number(_ key: String) -> Double? { (arguments[key] as? NSNumber)?.doubleValue }
    func ref() throws -> String {
        guard let value = string("ref") else { throw NotesError("invalid_arguments", "ref is required.") }
        return value
    }
    func result(_ value: NativeWriteResult) throws -> MCPNativeResult {
        try MCPNativeResult(result: value.writeResult, operationID: value.operationID, value: value)
    }
    func result(_ value: NativeRecordingResult) throws -> MCPNativeResult {
        try MCPNativeResult(result: value.write.writeResult, operationID: value.write.operationID, value: value)
    }
    func enumValue<T: RawRepresentable>(_ key: String, as type: T.Type, choices: String) throws -> T? where T.RawValue == String {
        guard let raw = string(key) else { return nil }
        guard let value = T(rawValue: raw) else { throw NotesError("invalid_arguments", "Invalid \(key); use \(choices).") }
        return value
    }
    func scriptValue() throws -> Int? {
        let selected = [("superscript", 1), ("subscript", -1), ("clear_script", 0)].filter { boolean($0.0) == true }
        guard selected.count <= 1 else { throw NotesError("invalid_arguments", "Choose one of superscript, subscript, or clear_script.") }
        return selected.first?.1
    }
    func drawing() throws -> PKDrawing {
        guard let path = string("svg") else { throw NotesError("invalid_arguments", "svg is required.") }
        let width = number("width")
        if let width, width <= 0 { throw NotesError("invalid_arguments", "width must be greater than zero.") }
        let ink: DrawingInk
        if let raw = string("ink") {
            guard let value = DrawingInk(rawValue: raw) else { throw NotesError("invalid_arguments", "Invalid ink; use pen, marker, pencil, or monoline.") }
            ink = value
        } else { ink = .pen }
        let fit: SVGFit
        if let raw = string("fit") {
            guard let value = SVGFit(rawValue: raw) else { throw NotesError("invalid_arguments", "Invalid fit; use contain or stretch.") }
            fit = value
        } else { fit = .contain }
        let fill: SVGFillMode
        if let raw = string("fill") {
            guard let value = SVGFillMode(rawValue: raw) else { throw NotesError("invalid_arguments", "Invalid fill; use outline or hatch.") }
            fill = value
        } else { fill = .outline }
        let color: DrawingColor?
        if let raw = string("color") {
            let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
            guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else {
                throw NotesError("invalid_arguments", "color must be a six-digit hex color.")
            }
            color = DrawingColor(red: Double((rgb >> 16) & 255) / 255,
                                 green: Double((rgb >> 8) & 255) / 255,
                                 blue: Double(rgb & 255) / 255)
        } else { color = nil }
        let size: DrawingSize?
        if let raw = string("size") {
            let values = raw.lowercased().split(separator: "x", maxSplits: 1).compactMap { Double($0) }
            guard values.count == 2, values[0] > 0, values[1] > 0 else {
                throw NotesError("invalid_arguments", "size must be WIDTHxHEIGHT with positive numbers.")
            }
            size = DrawingSize(width: values[0], height: values[1])
        } else { size = nil }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        return try SVGDrawingConverter.drawing(contentsOf: url, options: SVGDrawingOptions(
            ink: ink, width: width, color: color, blackAndWhite: boolean("bw") ?? false,
            size: size, fit: fit, fill: fill
        ))
    }
    let writer = NativeNotesWriter()
    let allowShared = boolean("allow_shared") ?? false
    switch tool {
    case "journal_get_checklist_auto_sort": return try MCPNativeResult(value: writer.checklistAutoSortEnabled())
    case "journal_get_default_account": return try MCPNativeResult(value: writer.defaultAccountIdentifier())
    case "journal_get_smart_folder_query": return try MCPNativeResult(value: writer.smartFolderQuery(ref()))
    case "recording_add":
        guard !(boolean("transcribe") == true && string("transcript_path") != nil) else {
            throw NotesError("invalid_transcript_file", "Choose transcribe or transcript_path, not both.")
        }
        let prepared = try AudioTranscriber.prepareBlocking(URL(fileURLWithPath: NSString(string: string("path")!).expandingTildeInPath), title: string("title"))
        let segments = try mcpRecordingTranscript(arguments: arguments, prepared: prepared.url)
        let frozen = try FrozenAttachmentInput(file: prepared.url)
        return try result(writer.insertRecording(ref(), frozen: frozen, title: string("title"), duration: prepared.duration,
                                                 transcript: segments, allowShared: allowShared))
    case "recording_create":
        guard !(boolean("transcribe") == true && string("transcript_path") != nil) else {
            throw NotesError("invalid_transcript_file", "Choose transcribe or transcript_path, not both.")
        }
        let prepared = try AudioTranscriber.prepareBlocking(URL(fileURLWithPath: NSString(string: string("path")!).expandingTildeInPath), title: string("title"))
        let segments = try mcpRecordingTranscript(arguments: arguments, prepared: prepared.url)
        let frozen = try FrozenAttachmentInput(file: prepared.url)
        return try result(writer.createRecordingNote(folder: string("folder"), title: string("title")!, frozen: frozen,
                                                      duration: prepared.duration, transcript: segments, allowShared: allowShared))
    case "recording_transcribe":
        let note = try reader.note(ref())
        var recordings = note.attachments.filter { ($0.childAttachmentIDs?.isEmpty == false) && ($0.transcriptWords?.isEmpty != false) }
        if let selected = string("attachment") { recordings = recordings.filter { $0.id.caseInsensitiveCompare(selected) == .orderedSame } }
        guard !recordings.isEmpty else { throw NotesError("recording_not_found", "No matching recording without a transcript was found.") }
        if string("transcript_path") != nil, recordings.count != 1 {
            throw NotesError("invalid_transcript_file", "transcript_path requires exactly one matching recording; provide attachment.")
        }
        var transcripts: [String: [TranscriptWord]] = [:]
        if let path = string("transcript_path") {
            transcripts[recordings[0].id] = try AudioTranscriber.readTranscriptFile(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)).segments
        } else {
            for recording in recordings {
                transcripts[recording.id] = try AudioTranscriber.transcribeRecordingBlocking(recording, locale: string("locale"))
            }
        }
        return try result(writer.writeRecordingTranscripts(note.summary.id.uuid, transcripts: transcripts, allowShared: allowShared))
    case "create_note":
        let paths = arguments["attachments"] as? [String] ?? []
        let frozen = try paths.map { try FrozenAttachmentInput(file: URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)) }
        let value = try writer.createNote(title: string("title")!, markdown: string("body")!, folder: string("folder"), attachments: frozen, allowShared: allowShared)
        return try MCPNativeResult(result: value.write.writeResult, operationID: value.write.operationID, value: value)
    case "update_note", "write_markdown":
        return try result(writer.writeMarkdown(ref(), markdown: string("body")!, dryRun: false, backup: false, allowShared: allowShared))
    case "append_to_note":
        return try result(writer.appendMarkdown(ref(), markdown: string("body")!, allowShared: allowShared))
    case "prepend_to_note":
        return try result(writer.prependMarkdown(ref(), markdown: string("body")!, allowShared: allowShared))
    case "insert_under_heading":
        return try result(writer.insertMarkdown(ref(), underHeading: string("heading")!, markdown: string("body")!, allowShared: allowShared))
    case "replace_section":
        return try result(writer.replaceSection(ref(), heading: string("heading")!, markdown: string("body")!, allowShared: allowShared))
    case "replace_text":
        return try result(writer.replaceText(ref(), find: string("find")!, replacement: string("replacement")!, allowShared: allowShared))
    case "attach_pasteboard":
        let value = try writer.insertFrozenFile(ref(), frozen: frozenPasteboardInput(), position: integer("position"), imageView: string("view"), allowShared: allowShared)
        return try MCPNativeResult(result: value.write.writeResult, operationID: value.write.operationID, value: value)
    case "add_url":
        guard let url = URL(string: string("url") ?? "") else { throw NotesError("invalid_url", "The URL is invalid.") }
        return try result(writer.insertURL(ref(), url: url, card: boolean("card") ?? false, position: integer("position"), allowShared: allowShared))
    case "smart_folder_create":
        return try result(writer.createSmartFolder(name: string("name")!, tags: arguments["tags"] as! [String], matchAll: string("match") == "all"))
    case "smart_folder_rename":
        return try result(writer.renameSmartFolder(ref(), name: string("name")!, expectedCount: integer("expected_count")!))
    case "smart_folder_edit_rules":
        return try result(writer.editSmartFolderRules(ref(), queryJSON: string("query_json")!, expectedCount: integer("expected_count")!))
    case "smart_folder_edit_typed":
        func date(_ key: String) throws -> Date? { try string(key).map { try NotePresentation.date($0) } }
        func match(_ key: String, default fallback: SmartFolderRuleMatch) throws -> SmartFolderRuleMatch {
            guard let value = string(key) else { return fallback }
            guard let result = SmartFolderRuleMatch(rawValue: value) else { throw NotesError("invalid_smart_folder_rules", "\(key) must be all or any.") }
            return result
        }
        let sections = try (arguments["attachments"] as? [String] ?? []).map { value -> SmartFolderAttachmentSection in
            guard let section = SmartFolderAttachmentSection(name: value) else { throw NotesError("invalid_smart_folder_rules", "Unknown attachment rule: \(value).") }
            return section
        }
        let rules = SmartFolderRules(match: try match("match", default: .all), tags: arguments["tags"] as? [String] ?? [],
                                     tagsMatch: try match("tags_match", default: .any),
                                     createdFrom: try date("created_from"), createdTo: try date("created_to"),
                                     modifiedFrom: try date("modified_from"), modifiedTo: try date("modified_to"),
                                     folders: arguments["folders"] as? [String] ?? [], checklists: arguments["checklists"] as? Bool,
                                     attachmentSections: sections, shared: arguments["shared"] as? Bool, locked: arguments["locked"] as? Bool,
                                     mentions: arguments["mentions"] as? Bool, quickNotes: arguments["quick_notes"] as? Bool)
        return try result(writer.editSmartFolderRules(ref(), queryJSON: rules.json(), expectedCount: integer("expected_count")!))
    case "smart_folder_delete":
        return try result(writer.deleteSmartFolder(ref(), expectedCount: integer("expected_count")!))
    case "checklist_list": return try MCPNativeResult(value: writer.checklistItems(ref()))
    case "checklist_add": return try result(writer.insertChecklist(ref(), text: string("text")!, position: integer("position"), allowShared: (boolean("allow_shared") ?? false)))
    case "checklist_toggle":
        let selection: ChecklistSelection
        if let index = integer("index") { selection = .index(index) }
        else if let text = string("text") { selection = .text(text) }
        else { throw NotesError("invalid_arguments", "index or text is required.") }
        return try result(writer.toggleChecklist(ref(), selection: selection, done: boolean("done"), allowShared: (boolean("allow_shared") ?? false)))
    case "checklist_check_all": return try result(writer.setAllChecklist(ref(), done: true, allowShared: (boolean("allow_shared") ?? false)))
    case "checklist_uncheck_all": return try result(writer.setAllChecklist(ref(), done: false, allowShared: (boolean("allow_shared") ?? false)))
    case "checklist_clear_done": return try result(writer.deleteCompleted(ref(), allowShared: (boolean("allow_shared") ?? false)))
    case "checklist_auto_sort": return try result(writer.setChecklistAutoSort(boolean("enabled")!))
    case "pin_note": return try result(writer.setPinned(ref(), pinned: true, allowShared: (boolean("allow_shared") ?? false)))
    case "unpin_note": return try result(writer.setPinned(ref(), pinned: false, allowShared: (boolean("allow_shared") ?? false)))
    case "tag_add": return try result(writer.addTag(ref(), tag: string("tag")!, position: integer("position"), allowShared: (boolean("allow_shared") ?? false)))
    case "tag_remove": return try result(writer.removeTag(ref(), tag: string("tag")!, allowShared: (boolean("allow_shared") ?? false)))
    case "tag_rename": return try result(writer.renameTag(string("tag")!, to: string("new_name")!, expectedCount: integer("expected_count")!, allowShared: boolean("allow_shared") ?? false))
    case "tag_delete": return try result(writer.deleteTag(string("tag")!, expectedCount: integer("expected_count")!, allowShared: boolean("allow_shared") ?? false))
    case "link_add": return try result(writer.insertNoteLink(ref(), target: string("target")!, text: string("text"), position: integer("position"), allowShared: (boolean("allow_shared") ?? false)))
    case "link_list": return try MCPNativeResult(value: writer.links(ref()))
    case "text_find": return try MCPNativeResult(value: writer.searchOffsets(ref(), text: string("text")!, caseInsensitive: boolean("case_insensitive") ?? false))
    case "text_insert": return try result(writer.insertText(ref(), text: string("text")!, position: integer("position")!, allowShared: (boolean("allow_shared") ?? false)))
    case "text_delete": return try result(writer.deleteRange(ref(), range: UTF16Range(location: integer("start")!, length: integer("length")!), allowShared: (boolean("allow_shared") ?? false)))
    case "text_replace": return try result(writer.replaceRange(ref(), range: UTF16Range(location: integer("start")!, length: integer("length")!), text: string("text")!, allowShared: (boolean("allow_shared") ?? false)))
    case "format_paragraph":
        guard let style = NativeParagraphStyle(rawValue: string("style") ?? "") else { throw NotesError("invalid_style", "Unknown paragraph style.") }
        let alignment = try enumValue("alignment", as: NativeParagraphAlignment.self, choices: "left, right, center, justified, or natural")
        let direction = try enumValue("writing_direction", as: NativeWritingDirection.self, choices: "natural, left-to-right, or right-to-left")
        return try result(writer.setParagraphStyle(ref(), range: UTF16Range(location: integer("start")!, length: integer("length")!), style: style, indent: integer("indent"),
                                                   alignment: alignment, writingDirection: direction, collapsed: boolean("collapsed"), allowShared: (boolean("allow_shared") ?? false)))
    case "format_inline":
        let script = try scriptValue()
        let format = InlineFormat(bold: boolean("bold"), italic: boolean("italic"), underline: boolean("underline"), strike: boolean("strike"),
                                  link: string("link"), clearLink: boolean("clear_link") ?? false, color: string("color"), clearColor: boolean("clear_color") ?? false,
                                  superscript: script, fontName: string("font_name"), fontSize: (arguments["font_size"] as? NSNumber)?.doubleValue,
                                  highlight: try enumValue("highlight", as: HighlightColor.self, choices: "purple, pink, orange, mint, or blue"), clearHighlight: boolean("clear_highlight") ?? false)
        return try result(writer.setInlineFormat(ref(), range: UTF16Range(location: integer("start")!, length: integer("length")!), format: format, allowShared: (boolean("allow_shared") ?? false)))
    case "insert_divider": return try result(writer.insertDivider(ref(), position: integer("position"), allowShared: (boolean("allow_shared") ?? false)))
    case "insert_math": return try result(writer.insertMathExpression(ref(), expression: string("expression")!, position: integer("position"), allowShared: (boolean("allow_shared") ?? false)))
    case "insert_mention": return try result(writer.insertMention(ref(), text: string("text")!, userRecordName: string("user_record_name")!, position: integer("position"), allowShared: (boolean("allow_shared") ?? false)))
    case "drawing_add":
        let value = try writer.insertDrawing(ref(), drawing: drawing(), position: integer("position"), allowShared: allowShared)
        return try MCPNativeResult(result: value.write.writeResult, operationID: value.write.operationID, value: value)
    case "drawing_create":
        let value = try writer.createDrawingNote(title: string("title")!, folder: string("folder"), drawing: drawing(), allowShared: allowShared)
        return try MCPNativeResult(result: value.write.writeResult, operationID: value.write.operationID, value: value)
    case "drawing_export":
        let stableID = try reader.summary(ref()).id.uuid
        let attachments = try writer.paperDrawings(stableID, attachmentID: string("attachment_id"))
        let drawings = attachments.flatMap(\.drawings)
        let format = string("format") ?? "svg"
        let data: String
        let mediaType: String
        let encoding: String
        if format == "png" {
            data = try SVGDrawingConverter.png(from: drawings).base64EncodedString()
            mediaType = "image/png"
            encoding = "base64"
        } else {
            data = SVGDrawingConverter.svg(from: drawings)
            mediaType = "image/svg+xml"
            encoding = "utf-8"
        }
        let summaries = attachments.map {
            MCPDrawingExportAttachment(attachmentID: $0.attachmentID, typeUTI: $0.typeUTI,
                                       drawingCount: $0.drawings.count, strokeCount: $0.drawings.reduce(0) { $0 + $1.strokes.count })
        }
        return try MCPNativeResult(value: MCPDrawingExportValue(
            format: format, mediaType: mediaType, encoding: encoding, data: data,
            strokeCount: drawings.reduce(0) { $0 + $1.strokes.count }, attachments: summaries
        ))
    case "attach_file":
        let value = try writer.insertFile(ref(), file: URL(fileURLWithPath: string("path")!), position: integer("position"), imageView: string("view"), allowShared: (boolean("allow_shared") ?? false))
        return try MCPNativeResult(result: value.write.writeResult, operationID: value.write.operationID, value: value)
    case "diagram_add":
        guard let mode = DiagramInsertionMode(rawValue: string("as") ?? "image") else {
            throw NotesError("invalid_arguments", "Invalid as; use image or drawing.")
        }
        guard let background = DiagramBackground(rawValue: string("background") ?? "auto") else {
            throw NotesError("invalid_arguments", "Invalid background; use white, transparent, or auto.")
        }
        let renderOptions: DiagramRenderOptions
        do {
            renderOptions = try DiagramRenderOptions(width: integer("width") ?? 700, scale: integer("scale") ?? 2,
                                                     background: background, dark: boolean("dark") ?? false)
        } catch let error as DiagramError {
            throw NotesError("invalid_arguments", error.description)
        }
        let value = try DiagramWriteService().add(file: diagramFile(string("file")!), to: ref(), options: renderOptions,
                                                  mode: mode, allowShared: allowShared)
        return try MCPNativeResult(result: value.0.write.writeResult, operationID: value.0.write.operationID, value: value.0)
    case "delete_attachment": return try result(writer.deleteAttachment(ref(), attachmentID: string("attachment_id")!, allowShared: (boolean("allow_shared") ?? false)))
    case "table_create":
        guard let rows = arguments["rows"] as? [[String]] else { throw NotesError("invalid_arguments", "rows must be an array of string arrays.") }
        return try result(writer.createTable(ref(), rows: rows, position: integer("position"), allowShared: (boolean("allow_shared") ?? false)))
    case "table_set": return try result(writer.editTable(ref(), attachmentID: string("attachment_id")!, row: integer("row")!, column: integer("column")!, text: string("text")!, allowShared: (boolean("allow_shared") ?? false)))
    case "table_format_cell":
        let script = try scriptValue()
        let format = InlineFormat(bold: boolean("bold"), italic: boolean("italic"), underline: boolean("underline"), strike: boolean("strike"),
                                  link: string("link"), clearLink: boolean("clear_link") ?? false, color: string("color"), clearColor: boolean("clear_color") ?? false,
                                  superscript: script, fontName: string("font_name"), fontSize: (arguments["font_size"] as? NSNumber)?.doubleValue,
                                  highlight: try enumValue("highlight", as: HighlightColor.self, choices: "purple, pink, orange, mint, or blue"), clearHighlight: boolean("clear_highlight") ?? false)
        return try result(writer.formatTableCell(ref(), attachmentID: string("attachment_id")!, row: integer("row")!, column: integer("column")!,
                                                 range: UTF16Range(location: integer("start")!, length: integer("length")!), format: format,
                                                 allowShared: boolean("allow_shared") ?? false))
    case "table_convert_to_text": return try result(writer.convertTableToText(ref(), attachmentID: string("attachment_id")!, separator: string("separator") ?? "tab", allowShared: (boolean("allow_shared") ?? false)))
    case "get_folder_sort": return try MCPNativeResult(value: writer.folderSort(ref()))
    case "set_folder_sort":
        guard let order = NativeFolderSortOrder(rawValue: string("by")!), let direction = NativeFolderSortDirection(rawValue: string("direction")!) else { throw NotesError("invalid_folder_sort", "Unknown folder sort order or direction.") }
        return try result(writer.setFolderSort(ref(), order: order, direction: direction))
    case "set_default_account":
        let identifier = string("account_id")!
        guard try reader.accounts().contains(where: { $0.id.caseInsensitiveCompare(identifier) == .orderedSame }) else {
            throw NotesError("account_not_found", "The account was not found.")
        }
        return try result(writer.setDefaultAccount(identifier))
    case "table_add_row", "table_remove_row", "table_add_column", "table_remove_column":
        let axis = tool.contains("row") ? "row" : "column", add = tool.contains("add")
        return try result(writer.resizeTable(ref(), attachmentID: string("attachment_id")!, axis: axis, index: integer("index")!, add: add, allowShared: (boolean("allow_shared") ?? false)))
    case "duplicate_note": return try result(writer.duplicate(ref(), title: string("title"), allowShared: (boolean("allow_shared") ?? false)))
    case "restore_note": return try result(writer.restore(ref(), folder: string("folder"), allowShared: (boolean("allow_shared") ?? false)))
    case "move_folder": return try result(writer.moveFolder(ref(), parent: string("parent"), allowShared: (boolean("allow_shared") ?? false)))
    default: throw NotesError("unknown_tool", "Unknown native MCP tool.")
    }
}

private func mcpRecordingTranscript(arguments: [String: Any], prepared: URL) throws -> [TranscriptWord] {
    if let path = arguments["transcript_path"] as? String {
        return try AudioTranscriber.readTranscriptFile(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)).segments
    }
    guard arguments["transcribe"] as? Bool == true else { return [] }
    return try AudioTranscriber.transcribeBlocking(prepared, locale: arguments["locale"] as? String)
}

struct MCPInstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Connect notescli to an MCP client.", discussion: "The agent skill is in skills/notescli/SKILL.md and is included by the NotesCLI Claude and Codex plugins.")
    @Option(help: "Client: claude-code, claude-desktop, codex, cursor, vscode, tailscale, or all.") var client: MCPClient = .all
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Expose opt-in tools that write through Apple's private Notes framework.")
    var allowNative = false
    @Option(help: "Hard ceiling of comma-separated folder trees for Tailscale writes.")
    var writeFolders: String?

    private var resolvedAllowNative: Bool { allowNative || CommandLine.arguments.contains("--allow-native") }
    private var resolvedReadOnly: Bool { options.readOnly || CommandLine.arguments.contains("--read-only") }

    func validate() throws {
        if resolvedReadOnly && resolvedAllowNative {
            throw ValidationError("--read-only cannot be combined with --allow-native.")
        }
        if writeFolders != nil && client != .tailscale {
            throw ValidationError("--write-folders is supported only with --client tailscale.")
        }
        if let writeFolders,
           (!writeFolders.isEmpty && writeFolders.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
           !WriteAllowlist(writeFolders).isValid {
            throw ValidationError("--write-folders contains an empty folder or path component.")
        }
    }

    func run() throws {
        if client == .tailscale {
            let config = try TailscaleMCP.install(executable: MCPConfiguration.executable,
                                                  readOnly: resolvedReadOnly, allowNative: resolvedAllowNative,
                                                  writeFolders: writeFolders)
            try InstallManifest.recordMCPClient(.tailscale, readOnly: resolvedReadOnly, allowNative: resolvedAllowNative)
            try InstallManifest.recordFile(MCPHTTPPaths.config, category: .config)
            try InstallManifest.recordFile(MCPHTTPPaths.launchAgent, category: .runtime)
            try InstallManifest.recordFile(MCPHTTPPaths.log, category: .runtime)
            if options.json {
                try Output.json(["endpoint": config.endpoint, "token_file": MCPHTTPPaths.config.path])
            } else {
                print("Tailscale: installed at \(config.endpoint)")
                print("Token: run 'notescli mcp token show'")
            }
            return
        }
        try MCPConfiguration.apply(client: client) { selected in
            if MCPConfiguration.status(selected) == "installed", try !InstallManifest.ownsMCPClient(selected) {
                return "skipped existing entry (not owned by NotesCLI)"
            }
            let result = try MCPConfiguration.install(selected, readOnly: resolvedReadOnly, allowNative: resolvedAllowNative)
            if !result.hasPrefix("skipped") {
                guard let entry = try MCPConfiguration.currentOwnership(selected) else {
                    throw NotesError("mcp_entry_missing", "The \(selected.label) entry could not be verified after installation.")
                }
                try InstallManifest.recordMCPClient(selected, readOnly: resolvedReadOnly,
                                                    allowNative: resolvedAllowNative, entry: entry)
            }
            return result
        }
        print("Agent skill: install the NotesCLI plugin or use skills/notescli/SKILL.md")
    }
}

struct MCPUninstall: ParsableCommand {
    enum Scope {
        case mcpClients
        case fullProduct
    }

    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Disconnect notescli from an MCP client.")
    @Option(help: "Client: claude-code, claude-desktop, codex, cursor, vscode, tailscale, or all.") var client: MCPClient = .all
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Show exactly what would be removed without changing files.") var dryRun = false
    @Flag(help: "Keep NotesCLI configuration and onboarding state.") var keepConfig = false

    func run() throws {
        try Self.execute(client: client, options: options, dryRun: dryRun, keepConfig: keepConfig)
    }

    static func execute(client: MCPClient, options: GlobalOptions, dryRun: Bool, keepConfig: Bool,
                        scope: Scope = .mcpClients) throws {
        let selectedClients = client == .all ? MCPClient.installable : [client]
        var actions: [UninstallAction] = []
        for selected in selectedClients {
            guard let record = try InstallManifest.mcpClientRecord(selected) else {
                if client == .all {
                    actions.append(UninstallAction(kind: "mcp_client", target: selected.rawValue, status: "not_recorded"))
                    continue
                }
                throw NotesError("uninstall_not_owned", "Refusing to remove the \(selected.label) entry because NotesCLI did not record owning it.")
            }
            if dryRun {
                if selected != .tailscale {
                    do {
                        guard let expected = record.entry else {
                            throw NotesError("uninstall_ownership_unknown", "The legacy install record has no exact ownership data. Reinstall it first.")
                        }
                        try MCPConfiguration.verifyOwnership(selected, expected: expected)
                    } catch {
                        if client == .all {
                            actions.append(UninstallAction(kind: "mcp_client", target: selected.rawValue,
                                                           status: "would_keep_modified"))
                            continue
                        }
                        throw error
                    }
                }
                actions.append(UninstallAction(kind: "mcp_client", target: selected.rawValue, status: "would_remove"))
                if selected == .tailscale, scope == .mcpClients {
                    let ownedPaths = Set([MCPHTTPPaths.config.path, MCPHTTPPaths.launchAgent.path, MCPHTTPPaths.log.path])
                    for file in try InstallManifest.filesToRemove(keepConfig: keepConfig)
                        where ownedPaths.contains(file.path) {
                        actions.append(UninstallAction(kind: "file", target: file.path, status: "would_remove"))
                    }
                }
            } else {
                let result: String
                if selected == .tailscale {
                    result = try TailscaleMCP.uninstall(keepConfig: keepConfig)
                    let ownedPaths = Set([MCPHTTPPaths.config.path, MCPHTTPPaths.launchAgent.path, MCPHTTPPaths.log.path])
                    for file in try InstallManifest.filesToRemove(keepConfig: keepConfig)
                        where ownedPaths.contains(file.path) {
                        try InstallManifest.removeRecordedFile(file)
                    }
                } else {
                    do {
                        guard let expected = record.entry else {
                            throw NotesError("uninstall_ownership_unknown", "The legacy install record has no exact ownership data. Reinstall it first.")
                        }
                        result = try MCPConfiguration.uninstall(selected, expectedOwnership: expected)
                    } catch {
                        if client == .all {
                            actions.append(UninstallAction(kind: "mcp_client", target: selected.rawValue,
                                                           status: "kept_modified"))
                            continue
                        }
                        throw error
                    }
                }
                try InstallManifest.removeMCPClient(selected)
                actions.append(UninstallAction(kind: "mcp_client", target: selected.rawValue, status: result))
            }
        }
        if scope == .fullProduct {
            if FileManager.default.fileExists(atPath: CapabilityHostPaths.app.path) {
                guard HostInstallation.validSignature(CapabilityHostPaths.app) else {
                    throw NotesError("uninstall_not_owned", "Refusing to remove a capability host that is not signed by the NotesCLI developer team.")
                }
                if dryRun {
                    actions.append(UninstallAction(kind: "capability_host", target: CapabilityHostPaths.app.path, status: "would_remove"))
                    actions.append(UninstallAction(kind: "launch_agent", target: CapabilityHostPaths.launchAgent.path, status: "would_remove"))
                    actions.append(UninstallAction(kind: "socket", target: CapabilityHostPaths.socket.path, status: "would_remove"))
                } else {
                    try HostInstallation.uninstall()
                    actions.append(UninstallAction(kind: "capability_host", target: CapabilityHostPaths.app.path, status: "removed"))
                }
            }
            for file in try InstallManifest.filesToRemove(keepConfig: keepConfig) {
                if dryRun {
                    actions.append(UninstallAction(kind: "file", target: file.path, status: "would_remove"))
                } else {
                    try InstallManifest.removeRecordedFile(file)
                    actions.append(UninstallAction(kind: "file", target: file.path, status: "removed"))
                }
            }
        }
        if !dryRun { try InstallManifest.removeManifestIfEmpty(keepConfig: keepConfig) }
        if options.json { try Output.json(actions) }
        else {
            Output.table(["KIND", "TARGET", "STATUS"], actions.map { [$0.kind, $0.target, $0.status] })
        }
    }
}

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Remove every NotesCLI-managed integration and service.")
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Show exactly what would be removed without changing files.") var dryRun = false
    @Flag(help: "Keep NotesCLI configuration and onboarding state.") var keepConfig = false

    func run() throws {
        try MCPUninstall.execute(client: .all, options: options, dryRun: dryRun, keepConfig: keepConfig,
                                 scope: .fullProduct)
    }
}

private struct UninstallAction: Codable {
    var kind: String
    var target: String
    var status: String
}

struct MCPStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show MCP client connections.")
    @Option(help: "Client: claude-code, claude-desktop, codex, cursor, vscode, tailscale, or all.") var client: MCPClient = .all

    func run() throws {
        let clients = client == .all ? MCPClient.installable : [client]
        Output.table(["CLIENT", "STATUS"], clients.map { selected in
            if selected == .tailscale {
                let status = TailscaleMCP.endpointStatus()
                let ready = status["configured"] as? Bool == true && status["running"] as? Bool == true && status["mounted"] as? Bool == true
                return [selected.label, ready ? "installed" : "not ready"]
            }
            return [selected.label, MCPConfiguration.status(selected)]
        })
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "onboard", abstract: "Resume NotesCLI setup and report readiness.", aliases: ["setup"])
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Report setup state without changing files or requesting permissions.") var checkOnly = false

    func run() throws {
        let report = try Onboarding.run(options: options, checkOnly: checkOnly)
        if options.json { try Output.json(report) }
        else { Output.table(["STEP", "STATUS", "REQUIRED"], report.steps.map { [$0.id, $0.status, $0.required ? "yes" : "no"] }) }
    }
}

struct Permissions: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Full Disk Access and request Notes Automation and Speech Recognition access.")
    func run() throws { try PermissionGuide.run() }
}

enum MCPConfiguration {
    private static var fileManager: FileManager { .default }

    static var home: URL {
        let path = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    static var executable: String {
        if let url = Bundle.main.executableURL { return url.standardizedFileURL.path }
        let value = CommandLine.arguments[0]
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL.path }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(value).standardizedFileURL.path
    }

    static func apply(client: MCPClient, operation: (MCPClient) throws -> String) throws {
        let clients = client == .all ? MCPClient.concrete : [client]
        var failures: [String] = []
        for selected in clients {
            do { print("\(selected.label): \(try operation(selected))") }
            catch {
                failures.append(selected.label)
                Output.error("\(selected.label): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw NotesError("mcp_config_failed", "Could not update: \(failures.joined(separator: ", ")).")
        }
    }

    static func install(_ client: MCPClient, readOnly: Bool, allowNative: Bool) throws -> String {
        switch client {
        case .claudeCode: return try installClaudeCode(readOnly: readOnly, allowNative: allowNative)
        case .claudeDesktop:
            return try installJSON(
                at: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
                serversKey: "mcpServers", readOnly: readOnly, allowNative: allowNative, includeType: false
            )
        case .codex: return try installCodex(readOnly: readOnly, allowNative: allowNative)
        case .cursor:
            return try installJSON(at: home.appendingPathComponent(".cursor/mcp.json"), serversKey: "mcpServers", readOnly: readOnly, allowNative: allowNative, includeType: false)
        case .vscode:
            return try installJSON(
                at: home.appendingPathComponent("Library/Application Support/Code/User/mcp.json"),
                serversKey: "servers", readOnly: readOnly, allowNative: allowNative, includeType: true
            )
        case .tailscale, .all: preconditionFailure("Expand managed clients before installing")
        }
    }

    static func uninstall(_ client: MCPClient, expectedOwnership: MCPEntryOwnership) throws -> String {
        try verifyOwnership(client, expected: expectedOwnership)
        switch client {
        case .claudeCode: return try uninstallClaudeCode()
        case .claudeDesktop:
            return try uninstallJSON(at: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"), serversKey: "mcpServers")
        case .codex: return try uninstallCodex()
        case .cursor: return try uninstallJSON(at: home.appendingPathComponent(".cursor/mcp.json"), serversKey: "mcpServers")
        case .vscode:
            return try uninstallJSON(at: home.appendingPathComponent("Library/Application Support/Code/User/mcp.json"), serversKey: "servers")
        case .tailscale, .all: preconditionFailure("Expand managed clients before uninstalling")
        }
    }

    static func currentOwnership(_ client: MCPClient) throws -> MCPEntryOwnership? {
        switch client {
        case .claudeCode:
            return try jsonOwnership(at: home.appendingPathComponent(".claude.json"), serversKey: "mcpServers")
        case .claudeDesktop:
            return try jsonOwnership(
                at: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
                serversKey: "mcpServers"
            )
        case .codex:
            let path = home.appendingPathComponent(".codex/config.toml")
            guard fileManager.fileExists(atPath: path.path) else { return nil }
            let text = try String(contentsOf: path, encoding: .utf8)
            guard let section = tomlSection("mcp_servers.notescli", in: text) else { return nil }
            return MCPEntryOwnership(format: "toml-section", canonicalValue: section)
        case .cursor:
            return try jsonOwnership(at: home.appendingPathComponent(".cursor/mcp.json"), serversKey: "mcpServers")
        case .vscode:
            return try jsonOwnership(
                at: home.appendingPathComponent("Library/Application Support/Code/User/mcp.json"),
                serversKey: "servers"
            )
        case .tailscale, .all:
            return nil
        }
    }

    static func verifyOwnership(_ client: MCPClient, expected: MCPEntryOwnership) throws {
        let current = try currentOwnership(client)
        guard current == expected else {
            throw NotesError("uninstall_entry_modified", "Refusing to remove the \(client.label) entry because it no longer exactly matches the entry NotesCLI installed.")
        }
    }

    static func status(_ client: MCPClient) -> String {
        switch client {
        case .claudeCode:
            guard let claude = findExecutable("claude") else { return "unavailable (claude CLI not found)" }
            let result = try? run(claude, ["mcp", "get", "notescli"])
            return result?.status == 0 ? "installed" : "not installed"
        case .claudeDesktop:
            return jsonStatus(at: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"), serversKey: "mcpServers")
        case .codex:
            let path = home.appendingPathComponent(".codex/config.toml")
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { return "not installed" }
            return text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.notescli]" } ? "installed" : "not installed"
        case .cursor: return jsonStatus(at: home.appendingPathComponent(".cursor/mcp.json"), serversKey: "mcpServers")
        case .vscode: return jsonStatus(at: home.appendingPathComponent("Library/Application Support/Code/User/mcp.json"), serversKey: "servers")
        case .tailscale: return (TailscaleMCP.endpointStatus()["configured"] as? Bool == true) ? "installed" : "not installed"
        case .all: return ""
        }
    }

    private static func arguments(readOnly: Bool, allowNative: Bool) -> [String] {
        ["mcp"] + (readOnly ? ["--read-only"] : []) + (allowNative ? ["--allow-native"] : [])
    }

    private static func installJSON(at path: URL, serversKey: String, readOnly: Bool, allowNative: Bool, includeType: Bool) throws -> String {
        var root = try readJSON(at: path)
        if let value = root[serversKey], !(value is [String: Any]) {
            throw NotesError("invalid_client_config", "\(path.path): \(serversKey) must be an object.")
        }
        var servers = root[serversKey] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["command": executable, "args": arguments(readOnly: readOnly, allowNative: allowNative)]
        if includeType { entry["type"] = "stdio" }
        servers["notescli"] = entry
        root[serversKey] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
        return try write(data, to: path)
    }

    private static func uninstallJSON(at path: URL, serversKey: String) throws -> String {
        guard fileManager.fileExists(atPath: path.path) else { return "not installed" }
        var root = try readJSON(at: path)
        guard var servers = root[serversKey] as? [String: Any], servers.removeValue(forKey: "notescli") != nil else { return "not installed" }
        root[serversKey] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
        _ = try write(data, to: path)
        return "removed from \(path.path)"
    }

    private static func readJSON(at path: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: path.path) else { return [:] }
        let data = try Data(contentsOf: path)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotesError("invalid_client_config", "\(path.path) must contain a JSON object.")
        }
        return root
    }

    private static func jsonOwnership(at path: URL, serversKey: String) throws -> MCPEntryOwnership? {
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        let root = try readJSON(at: path)
        guard let servers = root[serversKey] as? [String: Any], let entry = servers["notescli"] else { return nil }
        guard let object = entry as? [String: Any], JSONSerialization.isValidJSONObject(object) else {
            throw NotesError("invalid_client_config", "\(path.path): notescli must be a JSON object.")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return MCPEntryOwnership(format: "json", canonicalValue: String(decoding: data, as: UTF8.self))
    }

    private static func jsonStatus(at path: URL, serversKey: String) -> String {
        guard let root = try? readJSON(at: path), let servers = root[serversKey] as? [String: Any], servers["notescli"] != nil else {
            return "not installed"
        }
        return "installed"
    }

    private static func installCodex(readOnly: Bool, allowNative: Bool) throws -> String {
        let path = home.appendingPathComponent(".codex/config.toml")
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let base = removingTOMLSection("mcp_servers.notescli", from: existing).trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = base.isEmpty ? [] : [base, ""]
        lines += ["[mcp_servers.notescli]", "command = \(tomlString(executable))", "args = \(tomlArray(arguments(readOnly: readOnly, allowNative: allowNative)))"]
        return try write(Data((lines.joined(separator: "\n") + "\n").utf8), to: path)
    }

    private static func uninstallCodex() throws -> String {
        let path = home.appendingPathComponent(".codex/config.toml")
        guard fileManager.fileExists(atPath: path.path) else { return "not installed" }
        let existing = try String(contentsOf: path, encoding: .utf8)
        let updated = removingTOMLSection("mcp_servers.notescli", from: existing).trimmingCharacters(in: .whitespacesAndNewlines)
        guard updated != existing.trimmingCharacters(in: .whitespacesAndNewlines) else { return "not installed" }
        let output = updated.isEmpty ? "" : updated + "\n"
        _ = try write(Data(output.utf8), to: path)
        return "removed from \(path.path)"
    }

    private static func removingTOMLSection(_ name: String, from text: String) -> String {
        var output: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if trimmed == "[\(name)]" { skipping = true; continue }
                skipping = false
            }
            if !skipping { output.append(line) }
        }
        while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }

    private static func tomlSection(_ name: String, in text: String) -> String? {
        var output: [String] = []
        var collecting = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if trimmed == "[\(name)]" {
                    collecting = true
                    output = [line]
                    continue
                }
                if collecting { break }
            }
            if collecting { output.append(line) }
        }
        while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { output.removeLast() }
        return output.isEmpty ? nil : output.joined(separator: "\n")
    }

    private static func tomlString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static func tomlArray(_ values: [String]) -> String {
        "[" + values.map(tomlString).joined(separator: ", ") + "]"
    }

    private static func installClaudeCode(readOnly: Bool, allowNative: Bool) throws -> String {
        guard let claude = findExecutable("claude") else { return "skipped (claude CLI not found)" }
        let current = try? run(claude, ["mcp", "get", "notescli"])
        if let current, current.status == 0, current.output.contains(executable), current.output.contains("mcp"),
           current.output.contains("--read-only") == readOnly, current.output.contains("--allow-native") == allowNative {
            return "already installed"
        }
        _ = try backupIfPresent(home.appendingPathComponent(".claude.json"))
        _ = try? run(claude, ["mcp", "remove", "--scope", "user", "notescli"])
        let result = try run(claude, ["mcp", "add", "--scope", "user", "notescli", "--", executable] + arguments(readOnly: readOnly, allowNative: allowNative))
        guard result.status == 0 else { throw NotesError("client_command_failed", result.output) }
        return "installed with claude mcp"
    }

    private static func uninstallClaudeCode() throws -> String {
        guard let claude = findExecutable("claude") else {
            throw NotesError("client_command_failed", "Claude Code is not available, so its MCP entry was not removed.")
        }
        let current = try run(claude, ["mcp", "get", "notescli"])
        guard current.status == 0 else { return "not installed" }
        _ = try backupIfPresent(home.appendingPathComponent(".claude.json"))
        let result = try run(claude, ["mcp", "remove", "--scope", "user", "notescli"])
        guard result.status == 0 else { throw NotesError("client_command_failed", result.output) }
        return "removed with claude mcp"
    }

    private static func findExecutable(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    private static func write(_ data: Data, to path: URL) throws -> String {
        if let current = try? Data(contentsOf: path), current == data { return "already installed" }
        let backup = try backupIfPresent(path)
        try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: path, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        if let backup { return "installed in \(path.path) (backup: \(backup.path))" }
        return "installed in \(path.path)"
    }

    private static func backupIfPresent(_ path: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = URL(fileURLWithPath: path.path + ".backup-" + formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8))
        try fileManager.copyItem(at: path, to: backup)
        return backup
    }
}

enum PermissionGuide {
    static func run(silent: Bool = false) throws {
        func info(_ message: String) { if !silent { print(message) } }
        func warning(_ message: String) { if !silent { Output.error(message) } }
        let speech = AudioTranscriber.authorizationStatus == .notDetermined
            ? try AudioTranscriber.requestAuthorizationBlocking()
            : AudioTranscriber.authorizationStatus
        switch speech {
        case .authorized: info("Speech Recognition: authorized.")
        case .denied: warning("Speech Recognition: denied. Open System Settings > Privacy & Security > Speech Recognition.")
        case .restricted: warning("Speech Recognition: restricted by system policy.")
        case .notDetermined: warning("Speech Recognition: no decision was recorded.")
        @unknown default: warning("Speech Recognition: unknown status.")
        }

        info("Full Disk Access is required for full-fidelity Apple Notes reads.")
        if ProcessInfo.processInfo.environment["NOTESCLI_HOST_ACTIVE"] == "1" {
            info("Add NotesCLI Capability Host.app. Other terminals and agent apps will use its permission.")
            let reveal = Process()
            reveal.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            reveal.arguments = ["-R", CapabilityHostPaths.app.path]
            if (try? reveal.run()) != nil { reveal.waitUntilExit() }
        } else {
            info("Add the app that launches notescli, or run 'notescli onboard' to install the shared capability host.")
        }
        let settings = Process()
        settings.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        settings.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
        try settings.run()
        settings.waitUntilExit()
        if settings.terminationStatus != 0 { warning("Could not open the Full Disk Access pane.") }

        info("Requesting Automation access for Notes. No note content is read.")
        do {
            try ensureNotesIsRunning()
            try NotesAutomationPermission.request()
            info("Automation: authorized for Notes.")
        } catch {
            warning("Automation was not authorized: \(error)")
            warning("Open System Settings > Privacy & Security > Automation and allow Notes for the same terminal or MCP host app.")
        }

    }

    private static func ensureNotesIsRunning() throws {
        let bundleIdentifier = "com.apple.Notes"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else { return }
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = ["-g", "-b", bundleIdentifier]
        try launch.run()
        launch.waitUntilExit()
        guard launch.terminationStatus == 0 else {
            throw NotesError("app_not_running", "Notes could not be launched before requesting Automation access.")
        }
        let deadline = Date().addingTimeInterval(5)
        while NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
            throw NotesError("app_not_running", "Notes did not finish launching before the Automation request.")
        }
    }
}
