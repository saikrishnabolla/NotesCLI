import Foundation
import NotesCore
import NotesIndex
import NotesSafety
import NotesStore
import NotesSync
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct MCPNativeResult {
    public var result: WriteResult?
    public var operationID: String?
    public var value: Data
    public init<T: Encodable>(result: WriteResult? = nil, operationID: String? = nil, value: T) throws {
        self.result = result
        self.operationID = operationID
        self.value = try JSONEncoder().encode(value)
    }
}

public typealias MCPNativeHandler = (_ tool: String, _ arguments: [String: Any]) throws -> MCPNativeResult
public typealias MCPSyncWaiter = (_ noteID: String, _ modifiedAfter: Date, _ timeout: TimeInterval) throws -> Bool

public final class MCPServer: @unchecked Sendable {
    public let reader: any NotesReading
    public let writer: (any NotesWriting)?
    public let readOnly: Bool
    public let allowNative: Bool
    public let exposureProfile: MCPToolExposureProfile
    public let readFidelity: String
    public let unavailableReadFields: [String]
    public static let textLimit = 48 * 1024
    public static let versions = MCPProtocol.legacyVersions

    private let nativeHandler: MCPNativeHandler?
    private let syncWaiter: MCPSyncWaiter?
    private let writeFolders: String?
    private let stateRoot: URL
    private let defaultConnection = MCPConnection()
    private let executionGate = MCPExecutionGate()

    public init(reader: any NotesReading, writer: (any NotesWriting)? = nil, readOnly: Bool = false,
                allowNative: Bool = false, nativeHandler: MCPNativeHandler? = nil, syncWaiter: MCPSyncWaiter? = nil,
                writeFolders: String? = nil, stateRoot: URL? = nil,
                exposureProfile: MCPToolExposureProfile = .local,
                readFidelity: String = "full", unavailableReadFields: [String] = []) {
        self.reader = reader
        self.writer = writer
        self.readOnly = readOnly
        self.allowNative = allowNative
        self.exposureProfile = exposureProfile
        self.readFidelity = readFidelity
        self.unavailableReadFields = unavailableReadFields
        self.nativeHandler = nativeHandler
        self.syncWaiter = syncWaiter
        self.writeFolders = writeFolders
        self.stateRoot = stateRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("notescli-mcp-" + UUID().uuidString)
    }

    private struct Tool {
        let name: String
        let description: String
        let write: Bool
        let native: Bool
        let destructive: Bool
        let required: [String]
        let properties: [String: [String: Any]]
        var schema: [String: Any] { ["type": "object", "properties": properties, "required": required, "additionalProperties": false] }
    }

    private struct AttachmentResourceReference: Codable {
        var ref: String
        var attachmentID: String
    }

    private var resourceTemplates: [[String: Any]] {
        [
            ["uriTemplate": "notes://note/{uuid}", "name": "Apple Note", "mimeType": "application/json"],
            ["uriTemplate": "notes://attachment/{token}", "name": "Apple Notes attachment"],
        ]
    }

    private var tools: [Tool] {
        let string: [String: Any] = ["type": "string"]
        let bool: [String: Any] = ["type": "boolean"]
        let integer: [String: Any] = ["type": "integer", "minimum": 0]
        let strings: [String: Any] = ["type": "array", "items": string]
        let rows: [String: Any] = ["type": "array", "items": ["type": "array", "items": string]]
        let alignment: [String: Any] = ["type": "string", "enum": ["left", "right", "center", "justified", "natural"]]
        let writingDirection: [String: Any] = ["type": "string", "enum": ["natural", "left-to-right", "right-to-left"]]
        let highlight: [String: Any] = ["type": "string", "enum": ["purple", "pink", "orange", "mint", "blue"]]
        // MARK: w9-paper begin
        let drawingInput: [String: [String: Any]] = [
            "svg": string,
            "ink": ["type": "string", "enum": ["pen", "marker", "pencil", "monoline"]],
            "width": ["type": "number", "exclusiveMinimum": 0],
            "color": string,
            "bw": bool,
            "size": string,
            "fit": ["type": "string", "enum": ["contain", "stretch"]],
            "fill": ["type": "string", "enum": ["outline", "hatch"]],
        ]
        // MARK: w9-paper end
        let page = ["offset": integer, "limit": integer]
        let cursorPage = ["cursor": string, "limit": integer]
        let writeCommon = ["dry_run": bool, "idempotency_key": string, "if_modified": string,
                           "expect_revision": string, "write_folders": string, "allow_attachment_loss": bool,
                           "allow_downgrade": bool, "engine": ["type": "string", "enum": ["scripting", "native"]],
                           "allow_shared": bool, "wait_sync": bool, "sync_timeout": ["type": "number", "minimum": 0]]
        func t(_ name: String, _ description: String, _ required: [String] = [], _ properties: [String: [String: Any]] = [:],
               write: Bool = false, native: Bool = false, destructive: Bool = false) -> Tool {
            Tool(name: name, description: description, write: write, native: native, destructive: destructive,
                 required: required, properties: write ? properties.merging(writeCommon) { old, _ in old } : properties)
        }
        let filters: [String: [String: Any]] = ["folder": string, "account": string, "pinned": bool, "tag": string, "has": string,
            "since": string, "until": string, "include_deleted": bool,
            "sort": ["type": "string", "enum": ["modified", "created", "opened", "title", "display"]]]
        var values: [Tool] = [
            t("list_accounts", "List Notes accounts."),
            t("list_folders", "List folders.", [], ["account": string]),
            t("list_notes", "List notes with filters and stable cursor paging.", [], filters.merging(cursorPage) { old, _ in old }),
            t("search_notes", "Search note titles and bodies with stable cursor paging.", ["query"], ["query": string, "folder": string, "has": string].merging(cursorPage) { old, _ in old }),
            t("query_notes", "Search the local index with boolean, field, date, kind, and stable cursor expressions.", ["query"], ["query": string, "folder": string, "rebuild": bool].merging(cursorPage) { old, _ in old }),
            t("get_note", "Read one note in Markdown, text, HTML, JSON, or outline form.", ["ref"], ["ref": string, "format": ["type": "string", "enum": ["markdown", "text", "html", "json", "outline"]], "attachments": bool].merging(page) { old, _ in old }),
            t("get_notes", "Read several notes.", ["refs"], ["refs": strings, "format": ["type": "string", "enum": ["markdown", "text", "html", "json"]]].merging(page) { old, _ in old }),
            t("list_tags", "List tags and note counts."),
            t("list_attachments", "List attachment metadata for a note.", ["ref"], ["ref": string]),
            t("save_attachment", "Copy one attachment original to a new file.", ["ref", "attachment_id", "output"], ["ref": string, "attachment_id": string, "output": string], write: true),
            t("list_backlinks", "List notes that link to a note.", ["ref"], ["ref": string]),
            t("get_deeplink", "Get an applenotes deep link.", ["ref"], ["ref": string]),
            t("list_smart_folders", "List smart folders and decoded rules.", [], ["evaluate": bool]),
            t("list_deleted", "List notes in Recently Deleted.", [], page),
            t("recent_notes", "List recently modified notes.", [], ["days": integer].merging(page) { old, _ in old }),
            t("today_notes", "List notes modified today.", [], page),
            // MARK: w9-ux begin
            t("pinned_notes", "List pinned notes.", [], ["limit": integer]),
            // MARK: w9-ux end
            t("count_notes", "Count notes matching filters.", [], filters),
            t("get_stats", "Get note, folder, account, and attachment-kind counts."),
            // MARK: w9-ux begin
            t("get_capabilities", "Report Apple Notes feature, engine, permission, and native selector support."),
            // MARK: w9-ux end
            t("get_raw_note", "Read decoded raw note protobuf data with paging.", ["ref"], ["ref": string].merging(page) { old, _ in old }),
            t("related_notes", "Find notes related by links or tags.", ["ref"], ["ref": string].merging(page) { old, _ in old }),
            t("get_write_policy", "Show read-only, native, and write-folder policy."),
            // MARK: w3-export begin
            t("export_notes", "Export notes with optional templates and attachments.", ["output"], ["output": string, "folder": string,
                "format": ["type": "string", "enum": ["markdown", "html", "json", "ndjson", "sqlite", "zip", "pdf", "docx", "rtf", "epub", "bear", "joplin", "quiver"]],
                "template": string, "filename_template": string, "include_attachments": bool, "embed_media": bool,
                "obsidian": bool, "prune": bool, "combine": bool, "scans_pdf": bool,
                "order": ["type": "string", "enum": ["display", "modified", "created", "title"]]], write: true),
            t("file_pull", "Pull one note into a Markdown file with a three-way merge base.", ["ref", "path"],
              ["ref": string, "path": string, "dry_run": bool], write: true),
            t("file_push", "Push one Markdown file identified by notes-id with three-way merge safety.", ["path"],
              ["path": string, "dry_run": bool], write: true, destructive: true),
            t("file_diff", "Compare one Markdown file with its note and stored merge base.", ["path"], ["path": string]),
            // MARK: w3-export end
            t("sync_notes", "Run one two-way Markdown folder sync pass.", ["directory", "folder"], ["directory": string, "folder": string, "propagate_deletes": bool], write: true, destructive: true),
            t("create_note", "Create a note from Markdown.", ["title", "body"], ["title": string, "body": string, "folder": string, "attachments": strings], write: true),
            t("append_to_note", "Append Markdown to a note.", ["ref", "body"], ["ref": string, "body": string], write: true),
            t("prepend_to_note", "Prepend Markdown while preserving supported rich content.", ["ref", "body"], ["ref": string, "body": string], write: true, destructive: true),
            t("update_note", "Replace a note body.", ["ref", "body"], ["ref": string, "body": string], write: true, destructive: true),
            t("insert_under_heading", "Insert Markdown below a heading.", ["ref", "heading", "body"], ["ref": string, "heading": string, "body": string], write: true, destructive: true),
            t("replace_section", "Replace a heading section.", ["ref", "heading", "body"], ["ref": string, "heading": string, "body": string], write: true, destructive: true),
            t("replace_text", "Replace exact text in a note.", ["ref", "find", "replacement"], ["ref": string, "find": string, "replacement": string], write: true, destructive: true),
            t("rename_note", "Rename a note.", ["ref", "title"], ["ref": string, "title": string], write: true),
            t("move_note", "Move a note to a folder.", ["ref", "folder"], ["ref": string, "folder": string], write: true),
            t("delete_note", "Move a note to Recently Deleted.", ["ref"], ["ref": string], write: true, destructive: true),
            t("batch_move_notes", "Move several notes.", ["refs", "folder"], ["refs": strings, "folder": string], write: true),
            t("batch_delete_notes", "Move several notes to Recently Deleted.", ["refs"], ["refs": strings], write: true, destructive: true),
            t("create_folder", "Create a folder.", ["name"], ["name": string, "parent": string, "account": string], write: true),
            t("rename_folder", "Rename a folder.", ["ref", "name"], ["ref": string, "name": string], write: true),
            t("move_folder", "Move a folder below another folder.", ["ref"], ["ref": string, "parent": string, "account": string], write: true, native: true),
            t("delete_folder", "Delete an empty folder.", ["ref"], ["ref": string], write: true, destructive: true),
            t("write_markdown", "Replace a note with Markdown using the scripting engine.", ["ref", "body"], ["ref": string, "body": string], write: true, destructive: true)
        ]
        if allowNative {
            values += [
                // MARK: w9-audio begin
                t("recording_add", "Add a native Apple Notes recording from an audio file.", ["ref", "path"], ["ref": string, "path": string, "title": string, "transcribe": bool, "locale": string, "transcript_path": string], write: true, native: true),
                t("recording_create", "Create a note containing a native Apple Notes recording.", ["folder", "title", "path"], ["folder": string, "title": string, "path": string, "transcribe": bool, "locale": string, "transcript_path": string], write: true, native: true),
                t("recording_transcribe", "Transcribe native recordings that lack a transcript.", ["ref"], ["ref": string, "attachment": string, "locale": string, "transcript_path": string], write: true, native: true),
                // MARK: w9-audio end
                // MARK: w3-write begin
                t("attach_pasteboard", "Attach the frozen pasteboard bytes to a note.", ["ref"], ["ref": string, "position": integer, "view": string], write: true, native: true),
                t("add_url", "Add a URL link or native preview card.", ["ref", "url"], ["ref": string, "url": string, "card": bool, "position": integer], write: true, native: true),
                t("smart_folder_create", "Create a tag-based Smart Folder.", ["name", "tags", "match"], ["name": string, "tags": strings, "match": ["type": "string", "enum": ["any", "all"]]], write: true, native: true),
                t("smart_folder_rename", "Rename one Smart Folder after an expected-count check.", ["ref", "name", "expected_count"], ["ref": string, "name": string, "expected_count": integer], write: true, native: true),
                // MARK: w4-format begin
                t("smart_folder_edit_rules", "Replace a Smart Folder query JSON after an expected-count check.", ["ref", "query_json", "expected_count"], ["ref": string, "query_json": string, "expected_count": integer], write: true, native: true, destructive: true),
                t("smart_folder_edit_typed", "Replace Smart Folder rules from typed predicates.", ["ref", "expected_count"], ["ref": string, "expected_count": integer, "match": ["type": "string", "enum": ["all", "any"]], "tags": strings, "tags_match": ["type": "string", "enum": ["all", "any"]], "created_from": string, "created_to": string, "modified_from": string, "modified_to": string, "folders": strings, "checklists": bool, "attachments": strings, "shared": bool, "locked": bool, "mentions": bool, "quick_notes": bool], write: true, native: true, destructive: true),
                // MARK: w4-format end
                t("smart_folder_delete", "Delete one Smart Folder after an expected-count check.", ["ref", "expected_count"], ["ref": string, "expected_count": integer], write: true, native: true, destructive: true),
                // MARK: w3-write end
                t("checklist_list", "List native checklist items.", ["ref"], ["ref": string], native: true),
                t("checklist_add", "Add a native checklist item.", ["ref", "text"], ["ref": string, "text": string, "position": integer], write: true, native: true),
                t("checklist_toggle", "Toggle a native checklist item.", ["ref"], ["ref": string, "index": integer, "text": string, "done": bool], write: true, native: true),
                t("checklist_check_all", "Check all native checklist items.", ["ref"], ["ref": string], write: true, native: true),
                t("checklist_uncheck_all", "Uncheck all native checklist items.", ["ref"], ["ref": string], write: true, native: true),
                t("checklist_clear_done", "Delete completed checklist items.", ["ref"], ["ref": string], write: true, native: true, destructive: true),
                // MARK: w4-format begin
                t("checklist_auto_sort", "Set whether Notes moves checked checklist items to the bottom.", ["enabled"], ["enabled": bool], write: true, native: true),
                // MARK: w4-format end
                t("pin_note", "Pin a note.", ["ref"], ["ref": string], write: true, native: true),
                t("unpin_note", "Unpin a note.", ["ref"], ["ref": string], write: true, native: true),
                t("tag_add", "Add a native tag.", ["ref", "tag"], ["ref": string, "tag": string, "position": integer], write: true, native: true),
                t("tag_remove", "Remove a native tag.", ["ref", "tag"], ["ref": string, "tag": string], write: true, native: true),
                t("tag_rename", "Rename a native tag after checking its note count.", ["tag", "new_name", "expected_count"], ["tag": string, "new_name": string, "expected_count": integer], write: true, native: true),
                t("tag_delete", "Delete a native tag after checking its note count.", ["tag", "expected_count"], ["tag": string, "expected_count": integer], write: true, native: true, destructive: true),
                t("link_add", "Insert a native note link.", ["ref", "target"], ["ref": string, "target": string, "text": string, "position": integer], write: true, native: true),
                t("link_list", "List native note links.", ["ref"], ["ref": string], native: true),
                t("text_find", "Find native UTF-16 text ranges.", ["ref", "text"], ["ref": string, "text": string, "case_insensitive": bool], native: true),
                t("text_insert", "Insert text at a UTF-16 position.", ["ref", "text", "position"], ["ref": string, "text": string, "position": integer], write: true, native: true),
                t("text_delete", "Delete a UTF-16 range.", ["ref", "start", "length"], ["ref": string, "start": integer, "length": integer], write: true, native: true, destructive: true),
                t("text_replace", "Replace a UTF-16 range.", ["ref", "start", "length", "text"], ["ref": string, "start": integer, "length": integer, "text": string], write: true, native: true, destructive: true),
                // MARK: w4-format begin
                t("format_paragraph", "Apply native paragraph formatting.", ["ref", "start", "length", "style"], ["ref": string, "start": integer, "length": integer, "style": string, "indent": integer, "alignment": alignment, "writing_direction": writingDirection, "collapsed": bool], write: true, native: true),
                t("format_inline", "Apply native inline formatting.", ["ref", "start", "length"], ["ref": string, "start": integer, "length": integer, "bold": bool, "italic": bool, "underline": bool, "strike": bool, "link": string, "color": string, "clear_link": bool, "clear_color": bool, "superscript": bool, "subscript": bool, "clear_script": bool, "font_name": string, "font_size": ["type": "number"], "highlight": highlight, "clear_highlight": bool], write: true, native: true),
                t("insert_divider", "Insert a native divider line.", ["ref"], ["ref": string, "position": integer], write: true, native: true),
                t("insert_math", "Insert a native math graph expression.", ["ref", "expression"], ["ref": string, "expression": string, "position": integer], write: true, native: true),
                t("insert_mention", "Insert a participant mention in a shared note.", ["ref", "text", "user_record_name"], ["ref": string, "text": string, "user_record_name": string, "position": integer], write: true, native: true),
                t("table_format_cell", "Apply native inline formatting inside a table cell.", ["ref", "attachment_id", "row", "column", "start", "length"], ["ref": string, "attachment_id": string, "row": integer, "column": integer, "start": integer, "length": integer, "bold": bool, "italic": bool, "underline": bool, "strike": bool, "link": string, "color": string, "highlight": highlight, "clear_link": bool, "clear_color": bool, "clear_highlight": bool, "superscript": bool, "subscript": bool, "clear_script": bool, "font_name": string, "font_size": ["type": "number", "exclusiveMinimum": 0]], write: true, native: true),
                t("table_convert_to_text", "Replace a native table with tab- or comma-separated text.", ["ref", "attachment_id"], ["ref": string, "attachment_id": string, "separator": ["type": "string", "enum": ["tab", "comma"]]], write: true, native: true, destructive: true),
                t("get_folder_sort", "Read a folder's native custom sort.", ["ref"], ["ref": string], native: true),
                t("set_folder_sort", "Set a folder's native custom sort.", ["ref", "by", "direction"], ["ref": string, "by": string, "direction": string], write: true, native: true),
                t("set_default_account", "Set the account Notes uses for new notes.", ["account_id"], ["account_id": string], write: true, native: true),
                // MARK: w4-format end
                // MARK: w9-paper begin
                t("drawing_add", "Convert an SVG to an editable Paper drawing and add it to a note.", ["ref", "svg"],
                  drawingInput.merging(["ref": string, "position": integer]) { old, _ in old }, write: true, native: true),
                t("drawing_create", "Create a note containing an editable Paper drawing.", ["folder", "title", "svg"],
                  drawingInput.merging(["folder": string, "title": string]) { old, _ in old }, write: true, native: true),
                t("drawing_export", "Export editable drawing strokes as SVG or base64-encoded PNG.", ["ref"],
                  ["ref": string, "attachment_id": string, "format": ["type": "string", "enum": ["svg", "png"]]], native: true),
                // MARK: w9-paper end
                t("attach_file", "Insert a file or positioned image.", ["ref", "path"], ["ref": string, "path": string, "position": integer, "view": string], write: true, native: true),
                // MARK: w9-diagram begin
                t("diagram_add", "Render SVG or HTML as an image, or convert SVG to an editable drawing.", ["ref", "file"],
                  ["ref": string, "file": string, "as": ["type": "string", "enum": ["image", "drawing"]],
                   "width": ["type": "integer", "minimum": 1, "maximum": 2400],
                   "scale": ["type": "integer", "enum": [2, 3]],
                   "background": ["type": "string", "enum": ["white", "transparent", "auto"]],
                   "dark": bool], write: true, native: true),
                // MARK: w9-diagram end
                t("delete_attachment", "Delete a native attachment.", ["ref", "attachment_id"], ["ref": string, "attachment_id": string], write: true, native: true, destructive: true),
                t("table_create", "Create a native table.", ["ref", "rows"], ["ref": string, "rows": rows, "position": integer], write: true, native: true),
                t("table_set", "Set a native table cell.", ["ref", "attachment_id", "row", "column", "text"], ["ref": string, "attachment_id": string, "row": integer, "column": integer, "text": string], write: true, native: true),
                t("table_add_row", "Add a native table row.", ["ref", "attachment_id", "index"], ["ref": string, "attachment_id": string, "index": integer], write: true, native: true),
                t("table_add_column", "Add a native table column.", ["ref", "attachment_id", "index"], ["ref": string, "attachment_id": string, "index": integer], write: true, native: true),
                t("table_remove_row", "Remove a native table row.", ["ref", "attachment_id", "index"], ["ref": string, "attachment_id": string, "index": integer], write: true, native: true, destructive: true),
                t("table_remove_column", "Remove a native table column.", ["ref", "attachment_id", "index"], ["ref": string, "attachment_id": string, "index": integer], write: true, native: true, destructive: true),
                t("duplicate_note", "Duplicate a note.", ["ref"], ["ref": string, "title": string], write: true, native: true),
                t("restore_note", "Restore a note from Recently Deleted.", ["ref"], ["ref": string, "folder": string], write: true, native: true)
            ]
        }
        // MARK: w3-read begin
        values += [
            // MARK: w9-audio begin
            t("recording_transcript", "Read native recording transcripts with timing and speakers.", ["ref"],
              ["ref": string, "format": ["type": "string", "enum": ["text", "srt", "vtt", "json"]]]),
            // MARK: w9-audio end
            t("index_status", "Get search index and background job progress."),
            t("get_attachment", "Return an attachment as an image/audio content block or resource link.", ["ref", "attachment_id"], ["ref": string, "attachment_id": string]),
            t("anchor_add", "Create a persistent paragraph anchor.", ["ref"], ["ref": string, "heading": string, "offset": integer], write: true),
            t("anchor_list", "List persistent paragraph anchors.", [], ["ref": string]),
            t("anchor_resolve", "Resolve a persistent paragraph anchor after edits.", ["id"], ["id": string]),
            t("anchor_prune", "Remove anchors whose note or paragraph no longer exists.", write: true),
            t("table_get", "Read decoded native tables.", ["ref"], ["ref": string, "attachment_id": string, "format": ["type": "string", "enum": ["markdown", "json", "csv"]]])
        ]
        // MARK: w3-read end
        var exposed = values.filter { (!readOnly || !$0.write) && (!$0.native || allowNative) }
        guard exposureProfile == .remote else { return exposed }
        let pathTools: Set<String> = [
            "save_attachment", "export_notes", "file_pull", "file_push", "file_diff", "sync_notes",
            "recording_add", "recording_create", "attach_file", "diagram_add", "drawing_add", "drawing_create",
        ]
        exposed.removeAll { pathTools.contains($0.name) }
        exposed = exposed.map { tool in
            guard tool.name == "create_note" || tool.name == "recording_transcribe" else { return tool }
            var properties = tool.properties
            properties.removeValue(forKey: tool.name == "create_note" ? "attachments" : "transcript_path")
            return Tool(name: tool.name, description: tool.description, write: tool.write, native: tool.native,
                        destructive: tool.destructive, required: tool.required, properties: properties)
        }
        return exposed
    }

    public func makeConnection() -> MCPConnection { MCPConnection() }

    public func handleLine(_ line: String, connection: MCPConnection? = nil) -> String? {
        let response: [String: Any]?
        do {
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])
            guard let request = value as? [String: Any] else {
                return encode(error(id: NSNull(), code: -32600, message: "Invalid request"))
            }
            response = handle(request, connection: connection ?? defaultConnection)
        } catch {
            response = self.error(id: NSNull(), code: -32700, message: "Parse error")
        }
        return response.map(encode)
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Encoding failed"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func error(id: Any, code: Int, message: String, data: [String: Any]? = nil) -> [String: Any] {
        var value: [String: Any] = ["code": code, "message": message]
        if let data { value["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": value]
    }

    public func handle(_ request: [String: Any]) -> [String: Any]? {
        handle(request, connection: defaultConnection)
    }

    /// Transport-neutral request entrypoint. HTTP transports can keep one
    /// connection per legacy session and use a fresh connection for modern,
    /// stateless requests.
    public func handle(_ request: [String: Any], connection: MCPConnection) -> [String: Any]? {
        let id = request["id"] ?? NSNull()
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String,
              request["id"] == nil || MCPProtocol.isValidRequestID(id) else {
            return error(id: NSNull(), code: -32600, message: "Invalid request")
        }
        guard request["params"] == nil || request["params"] is [String: Any] else {
            return request["id"] == nil ? nil : error(id: id, code: -32602, message: "Parameters must be an object")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        if request["id"] == nil {
            handleNotification(method: method, params: params, connection: connection)
            return nil
        }
        guard let cancellation = connection.reserve(id) else {
            return error(id: id, code: -32600, message: "This request id is already running")
        }
        defer { connection.release(id, cancellation: cancellation) }
        return handleReserved(id: id, method: method, params: params, connection: connection,
                              cancellation: cancellation)
    }

    private func handleReserved(id: Any, method: String, params: [String: Any],
                                connection: MCPConnection, cancellation: MCPRequestCancellation) -> [String: Any]? {
        do {
            let context = try requestContext(method: method, params: params, connection: connection,
                                             cancellation: cancellation)
            var result: [String: Any]
            switch method {
            case "initialize":
                guard context.era == .legacy else {
                    throw MCPRPCError(code: -32601,
                                      message: "initialize is a legacy method; use server/discover.",
                                      data: ["supported": MCPProtocol.supportedVersions])
                }
                guard let version = params["protocolVersion"] as? String else { return error(id: id, code: -32602, message: "protocolVersion is required") }
                let selected = Self.versions.contains(version) ? version : Self.versions[0]
                let capabilities = params["capabilities"] as? [String: Any] ?? [:]
                connection.updateLegacy(version: selected, capabilities: capabilities)
                result = ["protocolVersion": selected, "capabilities": serverCapabilities(),
                          "serverInfo": serverInfo(),
                          "instructions": "Read and write Apple Notes through typed tools."]
            case "server/discover":
                result = cacheable([
                    "supportedVersions": MCPProtocol.supportedVersions,
                    "capabilities": serverCapabilities(),
                    "instructions": "Read and write Apple Notes through typed tools.",
                ], context: context, scope: "public")
            case "ping": result = [:]
            case "tools/list":
                result = cacheable(["tools": tools.map { toolDescriptor($0, context: context) }],
                                   context: context, scope: "public")
            case "tools/call":
                result = try executeTool(params: params, context: context)
            case "resources/list":
                var resources: [[String: Any]] = [["uri": "notes://folders", "name": "Apple Notes folders", "mimeType": "application/json"]]
                if context.apps { resources.append(NotesMCPWidget.descriptor) }
                result = cacheable(["resources": resources, "resourceTemplates": resourceTemplates],
                                   context: context, scope: "public")
            case "resources/templates/list":
                result = cacheable(["resourceTemplates": resourceTemplates],
                                   context: context, scope: "public")
            case "resources/read":
                do {
                    if context.cancellation.isCancelled { throw MCPRequestCancelled() }
                    guard executionGate.acquire(.read, cancellation: context.cancellation) else { throw MCPRequestCancelled() }
                    defer { executionGate.release(.read) }
                    if context.cancellation.isCancelled { throw MCPRequestCancelled() }
                    result = cacheable(try readResource(params), context: context, scope: "private")
                } catch let value as NotesError {
                    let code = context.era == .legacy && value.code == "resource_not_found" ? -32002 : -32602
                    throw MCPRPCError(code: code, message: value.message,
                                      data: (try? NotePresentation.object(value)) as? [String: Any])
                }
            case "prompts/list":
                result = cacheable(["prompts": [["name": "find_note", "description": "Find and summarize matching notes", "arguments": [["name": "query", "required": true]]],
                                                     ["name": "weekly_review", "description": "Review notes modified in the last seven days", "arguments": []]]],
                                   context: context, scope: "public")
            case "prompts/get":
                do { result = try getPrompt(params) }
                catch let value as NotesError {
                    throw MCPRPCError(code: -32602, message: value.message,
                                      data: (try? NotePresentation.object(value)) as? [String: Any])
                }
            default: return error(id: id, code: -32601, message: "Method not found")
            }
            return ["jsonrpc": "2.0", "id": id, "result": decorate(result, context: context)]
        } catch is MCPRequestCancelled {
            return nil
        } catch let value as MCPRPCError {
            return error(id: id, code: value.code, message: value.message, data: value.data)
        } catch {
            let value = error as? NotesError ?? NotesError("internal_error", String(describing: error))
            return self.error(id: id, code: -32603, message: value.message, data: (try? NotePresentation.object(value)) as? [String: Any])
        }
    }

    private func requestContext(method: String, params: [String: Any], connection: MCPConnection,
                                cancellation: MCPRequestCancellation) throws -> MCPRequestContext {
        if let rawMeta = params["_meta"], !(rawMeta is [String: Any]) {
            throw MCPRPCError(code: -32602, message: "params._meta must be an object", data: nil)
        }
        let meta = params["_meta"] as? [String: Any] ?? [:]
        let hasVersion = meta[MCPProtocol.protocolVersionKey] != nil
        let hasCapabilities = meta[MCPProtocol.clientCapabilitiesKey] != nil
        if method == "server/discover" || hasVersion || hasCapabilities {
            if hasVersion, meta[MCPProtocol.protocolVersionKey] as? String != MCPProtocol.modernVersion {
                throw MCPRPCError(code: MCPProtocol.unsupportedVersionError,
                                  message: "UnsupportedProtocolVersion",
                                  data: ["supported": MCPProtocol.supportedVersions,
                                         "requested": meta[MCPProtocol.protocolVersionKey] ?? NSNull()])
            }
            if !hasVersion || !hasCapabilities {
                throw MCPRPCError(code: -32602,
                                  message: "Modern requests require protocolVersion and clientCapabilities in params._meta.",
                                  data: ["supported": MCPProtocol.supportedVersions])
            }
            guard !hasCapabilities || meta[MCPProtocol.clientCapabilitiesKey] is [String: Any] else {
                throw MCPRPCError(code: -32602, message: "clientCapabilities must be an object",
                                  data: ["supported": MCPProtocol.supportedVersions])
            }
            let capabilities = meta[MCPProtocol.clientCapabilitiesKey] as? [String: Any] ?? [:]
            return MCPRequestContext(era: .modern, version: MCPProtocol.modernVersion,
                                     apps: MCPProtocol.supportsApps(capabilities), legacyAliases: false,
                                     capabilities: capabilities, cancellation: cancellation)
        }
        let state = connection.legacyState()
        let apps = MCPProtocol.supportsApps(state.capabilities)
        return MCPRequestContext(era: .legacy, version: state.version, apps: apps,
                                 legacyAliases: true, capabilities: state.capabilities,
                                 cancellation: cancellation)
    }

    private func handleNotification(method: String, params: [String: Any], connection: MCPConnection) {
        guard method == "notifications/cancelled", let requestID = params["requestId"] else { return }
        connection.cancel(requestID)
    }

    private func serverInfo() -> [String: Any] { ["name": "notescli", "version": notesCLIVersion] }

    private func serverCapabilities() -> [String: Any] {
        [
            "tools": ["listChanged": false],
            "resources": ["subscribe": false, "listChanged": false],
            "prompts": ["listChanged": false],
            "extensions": [MCPProtocol.appsExtension: ["mimeTypes": [MCPProtocol.appsMIMEType]]],
        ]
    }

    private func cacheable(_ result: [String: Any], context: MCPRequestContext, scope: String) -> [String: Any] {
        guard context.era == .modern else { return result }
        var value = result
        value["ttlMs"] = MCPProtocol.listTTL
        value["cacheScope"] = scope
        return value
    }

    private func decorate(_ result: [String: Any], context: MCPRequestContext) -> [String: Any] {
        var value = result
        if context.era == .modern { value["resultType"] = "complete" }
        var meta = value["_meta"] as? [String: Any] ?? [:]
        meta[MCPProtocol.serverInfoKey] = serverInfo()
        meta["net.notescli/readFidelity"] = ["fidelity": readFidelity,
                                                   "unavailableFields": unavailableReadFields]
        value["_meta"] = meta
        return value
    }

    private func toolDescriptor(_ tool: Tool, context: MCPRequestContext) -> [String: Any] {
        var descriptor: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
            "inputSchema": tool.schema,
            "annotations": ["readOnlyHint": !tool.write, "destructiveHint": tool.destructive],
        ]
        let meta = widgetMetadata(context: context, includeResultHint: false)
        if !meta.isEmpty { descriptor["_meta"] = meta }
        return descriptor
    }

    private func widgetMetadata(context: MCPRequestContext, includeResultHint: Bool) -> [String: Any] {
        var meta: [String: Any] = [:]
        if context.apps { meta["ui"] = ["resourceUri": MCPProtocol.widgetURI] }
        if context.legacyAliases {
            meta["ui/resourceUri"] = MCPProtocol.widgetURI
            meta["openai/outputTemplate"] = MCPProtocol.widgetURI
            meta["openai/widgetAccessible"] = true
            meta["openai/widgetDescription"] = "Interactive Apple Notes results."
        }
        if context.apps && includeResultHint {
            meta["net.notescli/ui"] = ["resourceUri": MCPProtocol.widgetURI, "view": "notes"]
        }
        return meta
    }

    private func executeTool(params: [String: Any], context: MCPRequestContext) throws -> [String: Any] {
        guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
            throw MCPRPCError(code: -32602, message: "Unknown or unavailable tool", data: nil)
        }
        guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
            throw MCPRPCError(code: -32602, message: "arguments must be an object", data: nil)
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        if let issue = validate(arguments, tool: tool) {
            throw MCPRPCError(code: -32602, message: issue, data: nil)
        }
        if context.cancellation.isCancelled { throw MCPRequestCancelled() }
        let access: MCPExecutionGate.Access = tool.write ? .write : .read
        guard executionGate.acquire(access, cancellation: context.cancellation) else { throw MCPRequestCancelled() }
        defer { executionGate.release(access) }
        if context.cancellation.isCancelled { throw MCPRequestCancelled() }
        var result: [String: Any]
        do {
            result = try call(tool, arguments)
        } catch {
            let value = error as? NotesError ?? NotesError("internal_error", String(describing: error))
            result = try content(["error": NotePresentation.object(value)], isError: true)
        }
        if context.cancellation.isCancelled {
            if tool.write {
                var meta = result["_meta"] as? [String: Any] ?? [:]
                meta["cancellationRequested"] = true
                result["_meta"] = meta
            } else {
                throw MCPRequestCancelled()
            }
        }
        var meta = result["_meta"] as? [String: Any] ?? [:]
        for (key, value) in widgetMetadata(context: context, includeResultHint: true) { meta[key] = value }
        if !meta.isEmpty { result["_meta"] = meta }
        return result
    }


    private func validate(_ args: [String: Any], tool: Tool) -> String? {
        for key in tool.required where args[key] == nil { return "Missing argument: \(key)" }
        for (key, value) in args {
            guard let spec = tool.properties[key] else { return "Unknown argument: \(key)" }
            switch spec["type"] as? String {
            case "string": if !(value is String) { return "\(key) must be a string" }
            case "boolean": if !(value is NSNumber) || String(cString: (value as! NSNumber).objCType) != "c" { return "\(key) must be a boolean" }
            case "integer":
                guard let number = value as? NSNumber, String(cString: number.objCType) != "c", number.doubleValue >= 0,
                      number.doubleValue < Double(Int.max), number.doubleValue.rounded() == number.doubleValue else { return "\(key) must be a nonnegative integer" }
            // MARK: w9-paper begin
            case "number":
                guard let number = value as? NSNumber, String(cString: number.objCType) != "c", number.doubleValue.isFinite else {
                    return "\(key) must be a number"
                }
                if let minimum = spec["exclusiveMinimum"] as? NSNumber, number.doubleValue <= minimum.doubleValue {
                    return "\(key) must be greater than \(minimum)"
                }
            // MARK: w9-paper end
            case "array": if !(value is [Any]) { return "\(key) must be an array" }
            default: break
            }
            if let values = spec["enum"] as? [String], !values.contains(value as? String ?? "") {
                let last = values.last ?? ""
                let choices = values.dropLast().joined(separator: ", ") + (values.count > 1 ? ", or " : "") + last
                return "Invalid \(key); use \(choices)."
            }
        }
        if ["format_inline", "table_format_cell"].contains(tool.name) {
            let scripts = ["superscript", "subscript", "clear_script"].filter { args[$0] as? Bool == true }
            if scripts.count > 1 { return "Choose one of superscript, subscript, or clear_script." }
        }
        // MARK: w9-diagram begin
        if tool.name == "diagram_add" {
            if let width = (args["width"] as? NSNumber)?.intValue, !(1...2400).contains(width) {
                return "width must be between 1 and 2400"
            }
            if let scale = (args["scale"] as? NSNumber)?.intValue, ![2, 3].contains(scale) {
                return "Invalid scale; use 2 or 3."
            }
        }
        // MARK: w9-diagram end
        return nil
    }

    private func content(_ structured: [String: Any], isError: Bool = false) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys])
        var text = String(decoding: data, as: UTF8.self)
        if text.utf8.count > Self.textLimit {
            var prefix = Data(data.prefix(Self.textLimit - 96))
            while String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
            text = String(decoding: prefix, as: UTF8.self) + "\n[Result truncated; use offset and limit.]"
        }
        let bounded: [String: Any]
        if data.count <= Self.textLimit {
            bounded = structured
        } else {
            bounded = ["truncated": true, "message": "Structured result exceeded the 48 KB budget; use paging or narrower arguments."]
        }
        return ["content": [["type": "text", "text": text]], "structuredContent": bounded, "isError": isError]
    }

    private func page<T>(_ values: [T], offset: Int, limit: Int, encode: ([T]) throws -> Any) throws -> [String: Any] {
        let maximum = min(limit, 1000)
        var valuesPage = Array(values.dropFirst(offset).prefix(maximum))
        while valuesPage.count > 1 {
            let object: [String: Any] = ["items": try encode(valuesPage)]
            if try JSONSerialization.data(withJSONObject: object).count < Self.textLimit / 2 { break }
            valuesPage.removeLast()
        }
        let next = offset + valuesPage.count
        var result: [String: Any] = ["items": try encode(valuesPage), "offset": offset, "limit": maximum, "total": values.count, "truncated": next < values.count]
        if next < values.count { result["next_offset"] = next }
        return result
    }

    private func attachmentKinds(_ raw: String?) throws -> [String] {
        guard let raw else { return [] }
        let allowed = Set(["image", "audio", "pdf", "scan", "drawing", "table", "checklist", "link", "file"])
        let values = raw.split(separator: "|").map { String($0).lowercased() }
        guard values.allSatisfy(allowed.contains) else { throw NotesError("invalid_attachment_kind", "Invalid attachment kind.") }
        return values
    }

    private func noteCursor(_ note: NoteSummary, sort: NoteSort) -> StableCursorPayload {
        switch sort {
        case .modified: return StableCursorPayload(sort: sort.rawValue, key: String(note.modified?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude), id: note.id.uuid)
        case .created: return StableCursorPayload(sort: sort.rawValue, key: String(note.created?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude), id: note.id.uuid)
        case .opened: return StableCursorPayload(sort: sort.rawValue, key: String(note.lastOpened?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude), secondary: String(note.modified?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude), id: note.id.uuid)
        case .title: return StableCursorPayload(sort: sort.rawValue, key: note.title, id: note.id.uuid)
        case .display: return StableCursorPayload(sort: sort.rawValue, key: String(note.displayOrder ?? Double.greatestFiniteMagnitude), id: note.id.uuid)
        }
    }

    private func follows(_ candidate: StableCursorPayload, _ cursor: StableCursorPayload) -> Bool {
        switch NoteSort(rawValue: cursor.sort) ?? .modified {
        case .modified, .created:
            let left = Double(candidate.key) ?? 0, right = Double(cursor.key) ?? 0
            return left < right || (left == right && candidate.id < cursor.id)
        case .opened:
            let left = Double(candidate.key) ?? 0, right = Double(cursor.key) ?? 0
            let left2 = Double(candidate.secondary ?? "") ?? 0, right2 = Double(cursor.secondary ?? "") ?? 0
            return left < right || (left == right && (left2 < right2 || (left2 == right2 && candidate.id < cursor.id)))
        case .title:
            let order = NoteTitleOrder.compare(candidate.key, cursor.key)
            return order == .orderedDescending || (order == .orderedSame && candidate.id > cursor.id)
        case .display:
            let left = Double(candidate.key) ?? 0, right = Double(cursor.key) ?? 0
            return left > right || (left == right && candidate.id > cursor.id)
        }
    }

    private func stableNotePage(_ notes: [NoteSummary], sort: NoteSort, cursor: String?, limit: Int) throws -> [String: Any] {
        var values = notes
        if let cursor {
            let decoded = try StableCursor.decode(cursor)
            guard decoded.sort == sort.rawValue else { throw NotesError("invalid_cursor", "The cursor uses a different sort order.") }
            values = values.filter { follows(noteCursor($0, sort: sort), decoded) }
        }
        var selected = Array(values.prefix(min(limit, 1000)))
        while selected.count > 1,
              try JSONSerialization.data(withJSONObject: ["items": NotePresentation.object(selected)]).count >= Self.textLimit / 2 { selected.removeLast() }
        var result: [String: Any] = ["items": try NotePresentation.object(selected), "limit": min(limit, 1000), "truncated": selected.count < values.count]
        if selected.count < values.count, let last = selected.last { result["next_cursor"] = try StableCursor.encode(noteCursor(last, sort: sort)) }
        return result
    }

    private func stableHitPage(_ hits: [NotesSearchHit], cursor: String?, limit: Int) throws -> [String: Any] {
        func payload(_ hit: NotesSearchHit) -> StableCursorPayload {
            StableCursorPayload(sort: "search", key: String(hit.score), secondary: String(hit.modified?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude), id: hit.noteID)
        }
        var values = hits
        if let cursor {
            let decoded = try StableCursor.decode(cursor)
            guard decoded.sort == "search" else { throw NotesError("invalid_cursor", "The cursor is not a search cursor.") }
            values = values.filter { hit in
                let value = payload(hit), score = Double(value.key) ?? 0, cursorScore = Double(decoded.key) ?? 0
                let modified = Double(value.secondary ?? "") ?? 0, cursorModified = Double(decoded.secondary ?? "") ?? 0
                return score < cursorScore || (score == cursorScore && (modified < cursorModified || (modified == cursorModified && value.id < decoded.id)))
            }
        }
        var selected = Array(values.prefix(min(limit, 1000)))
        while selected.count > 1,
              try JSONSerialization.data(withJSONObject: ["items": NotePresentation.object(selected)]).count >= Self.textLimit / 2 { selected.removeLast() }
        var result: [String: Any] = ["items": try NotePresentation.object(selected), "limit": min(limit, 1000), "truncated": selected.count < values.count]
        if selected.count < values.count, let last = selected.last { result["next_cursor"] = try StableCursor.encode(payload(last)) }
        return result
    }

    private func tableText(_ rows: [[String]], format: String) -> String {
        if format == "csv" {
            return rows.map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }.joined(separator: "\n")
        }
        guard let first = rows.first else { return "" }
        func row(_ cells: [String]) -> String { "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }.joined(separator: " | ") + " |" }
        return ([row(first), "| " + first.map { _ in "---" }.joined(separator: " | ") + " |"] + rows.dropFirst().map(row)).joined(separator: "\n")
    }

    private func attachmentContent(ref: String, attachmentID: String) throws -> [String: Any] {
        let matches = try reader.attachments(ref).filter { $0.id.caseInsensitiveCompare(attachmentID) == .orderedSame }
        guard matches.count == 1 else { throw NotesError("attachment_not_found", "No attachment matches the id.") }
        let attachment = matches[0]
        guard let path = attachment.filePath ?? attachment.fallbackRasterPath else { throw NotesError("attachment_unavailable", "The attachment file is not downloaded.") }
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue else {
            throw NotesError("attachment_unavailable", "The attachment size is unavailable.")
        }
        let budget = 34 * 1024
        var blocks: [[String: Any]] = []
        var mime = mimeType(attachment, url: url)
        if attachment.kind == "image" || attachment.kind == "drawing" || attachment.kind == "scan" {
            if let resized = resizedImage(url, maximumDimension: 1600, maximumBytes: budget) {
                blocks.append(["type": "image", "data": resized.base64EncodedString(), "mimeType": "image/jpeg"]); mime = "image/jpeg"
            }
        } else if attachment.kind == "audio", size <= budget {
            let data = try Data(contentsOf: url)
            blocks.append(["type": "audio", "data": data.base64EncodedString(), "mimeType": mime])
        }
        if blocks.isEmpty {
            let resourceURI = try attachmentResourceURI(ref: ref, attachmentID: attachment.id)
            blocks.append(["type": "resource_link", "name": attachment.filename ?? attachment.id, "uri": resourceURI,
                           "description": "Attachment exceeds the inline 48 KB budget.", "mimeType": mime, "size": size])
        }
        let structured: [String: Any] = ["id": attachment.id, "kind": attachment.kind, "filename": attachment.filename ?? NSNull(),
                                         "inline": blocks.first?["type"] as? String != "resource_link", "mime_type": mime, "size": size,
                                         "resource_uri": blocks.first?["uri"] ?? NSNull()]
        return ["content": blocks, "structuredContent": structured, "isError": false]
    }

    private func attachmentResourceURI(ref: String, attachmentID: String) throws -> String {
        let data = try JSONEncoder().encode(AttachmentResourceReference(ref: ref, attachmentID: attachmentID))
        let token = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "notes://attachment/\(token)"
    }

    private func attachmentResource(_ uri: String) throws -> [String: Any] {
        let suffix = String(uri.dropFirst("notes://attachment/".count))
        let tokenPart = String(suffix.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        var token = tokenPart
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        token += String(repeating: "=", count: (4 - token.count % 4) % 4)
        guard let encoded = Data(base64Encoded: token),
              let reference = try? JSONDecoder().decode(AttachmentResourceReference.self, from: encoded) else {
            throw NotesError("resource_not_found", "The attachment resource is invalid.")
        }
        let matches = try reader.attachments(reference.ref).filter {
            $0.id.caseInsensitiveCompare(reference.attachmentID) == .orderedSame
        }
        guard matches.count == 1 else { throw NotesError("attachment_not_found", "No attachment matches the id.") }
        let attachment = matches[0]
        guard let path = attachment.filePath ?? attachment.fallbackRasterPath else {
            throw NotesError("attachment_unavailable", "The attachment file is not downloaded.")
        }
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let total = (attributes[.size] as? NSNumber)?.intValue, total >= 0 else {
            throw NotesError("attachment_unavailable", "The attachment size is unavailable.")
        }
        let components = URLComponents(string: uri)
        let offsetText = components?.queryItems?.first { $0.name == "offset" }?.value ?? "0"
        guard let offset = Int(offsetText), offset >= 0, offset <= total else {
            throw NotesError("invalid_resource", "The attachment resource offset is invalid.")
        }
        let chunkLimit = 1_048_576
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: min(chunkLimit, total - offset)) ?? Data()
        let nextOffset = offset + data.count
        let nextURI = nextOffset < total ? "notes://attachment/\(tokenPart)?offset=\(nextOffset)" : nil
        var metadata: [String: Any] = ["offset": offset, "bytes": data.count, "totalBytes": total,
                                       "complete": nextURI == nil]
        if let nextURI { metadata["nextUri"] = nextURI }
        return ["contents": [["uri": uri, "mimeType": mimeType(attachment, url: url),
                               "blob": data.base64EncodedString(), "_meta": metadata]]]
    }

    private func mimeType(_ attachment: Attachment, url: URL) -> String {
        if let type = UTType(attachment.typeUTI), let mime = type.preferredMIMEType { return mime }
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private func resizedImage(_ url: URL, maximumDimension: Int, maximumBytes: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
              ] as CFDictionary) else { return nil }
        for quality in [0.75, 0.55, 0.35, 0.2] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length <= maximumBytes { return data as Data }
        }
        return nil
    }

    private func textPage(_ text: String, offset: Int, limit: Int) -> (String, Int?) {
        let characters = Array(text)
        guard offset < characters.count else { return ("", nil) }
        var output = "", index = offset
        let maximum = min(limit, 32_000)
        while index < characters.count && output.utf8.count + String(characters[index]).utf8.count <= maximum {
            output.append(characters[index]); index += 1
        }
        return (output, index < characters.count ? index : nil)
    }

    private func call(_ tool: Tool, _ a: [String: Any]) throws -> [String: Any] {
        func s(_ key: String) -> String? { a[key] as? String }
        func b(_ key: String) -> Bool { a[key] as? Bool ?? false }
        func i(_ key: String, _ fallback: Int = 0) -> Int { (a[key] as? NSNumber)?.intValue ?? fallback }
        let offset = i("offset"), limit = max(1, i("limit", 100))
        // MARK: w3-write begin
        let nativeBodyTools = Set(["append_to_note", "prepend_to_note", "update_note", "write_markdown", "insert_under_heading", "replace_section", "replace_text"])
        if ["file_push", "sync_notes"].contains(tool.name), s("engine") == "native" {
            throw NotesError("unsupported_engine", "The native engine is not available for MCP file or folder sync. Use write_markdown for an explicit native body replacement.")
        }
        if nativeBodyTools.contains(tool.name), s("engine") == "native" {
            guard allowNative else { throw NotesError("native_unavailable", "Native MCP writes are disabled.") }
            return try callNative(tool, a)
        }
        if allowNative && tool.name == "create_note" && a["attachments"] != nil {
            return try callNative(tool, a)
        }
        // MARK: w3-write end
        if tool.native { return try callNative(tool, a) }
        if tool.write && b("dry_run") && ["save_attachment", "export_notes"].contains(tool.name) {
            return try content(["dry_run": true, "tool": tool.name, "engine": "filesystem", "arguments": a, "message": "No changes made."])
        }
        switch tool.name {
        case "list_accounts": return try content(["accounts": NotePresentation.object(reader.accounts()), "default_location": try reader.defaultLocation().map(NotePresentation.object) ?? NSNull()])
        case "list_folders": return try content(["folders": NotePresentation.object(reader.folders(account: s("account")))])
        case "list_tags": return try content(["tags": reader.tags()])
        case "get_write_policy":
            let effectiveWriteFolders: Any
            if let configured = writeFolders ?? ProcessInfo.processInfo.environment["NOTESCLI_WRITE_FOLDERS"] { effectiveWriteFolders = configured }
            else { effectiveWriteFolders = NSNull() }
            return try content(["read_only": readOnly, "allow_native": allowNative, "write_folders": effectiveWriteFolders])
        case "get_note":
            let note = try reader.note(s("ref")!), format = s("format") ?? "markdown"
            let rendered = format == "outline"
                ? String(decoding: try NotePresentation.json(note.document?.outline() ?? []), as: UTF8.self)
                : try NotePresentation.render(note, format: format, attachments: a["attachments"] as? Bool ?? true)
            let value = textPage(rendered, offset: offset, limit: min(a["limit"] == nil ? 16_000 : limit, 16_000))
            var result: [String: Any] = ["summary": try NotePresentation.object(note.summary), "format": format, "body": value.0, "offset": offset, "truncated": value.1 != nil]
            if let next = value.1 { result["next_offset"] = next }
            if format == "json", value.1 == nil { result["note"] = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) }
            if format == "outline", value.1 == nil { result["outline"] = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) }
            return try content(result)
        case "get_notes":
            let refs = a["refs"] as! [String], format = s("format") ?? "markdown", maximum = min(limit, 100)
            let selected = Array(refs.dropFirst(offset).prefix(maximum))
            let values = try selected.map { ref -> [String: Any] in
                let note = try reader.note(ref)
                let rendered = try NotePresentation.render(note, format: format, attachments: true)
                return ["summary": try NotePresentation.object(note.summary), "format": format,
                        "body": textPage(rendered, offset: 0, limit: max(1_000, 16_000 / max(1, selected.count))).0]
            }
            let next = offset + selected.count
            var result: [String: Any] = ["notes": values, "offset": offset, "limit": maximum, "total": refs.count, "truncated": next < refs.count]
            if next < refs.count { result["next_offset"] = next }
            return try content(result)
        case "list_notes", "search_notes":
            let sort = NoteSort(rawValue: s("sort") ?? "modified") ?? .modified
            let query = NoteQuery(folder: s("folder"), account: s("account"), text: s("query"), includeDeleted: b("include_deleted"),
                                  pinnedOnly: b("pinned"), tag: s("tag"), modifiedAfter: try s("since").map { try NotePresentation.date($0) },
                                  modifiedBefore: try s("until").map { try NotePresentation.date($0) },
                                  attachmentKinds: try attachmentKinds(s("has")))
            let all = try reader.notes(query, sort: sort)
            var result = try stableNotePage(all, sort: sort, cursor: s("cursor"), limit: limit)
            result["notes"] = result.removeValue(forKey: "items")
            return try content(result)
        case "query_notes":
            let index = LocalNotesIndex(url: stateRoot.appendingPathComponent("index.sqlite"))
            _ = try index.update(from: reader, rebuild: b("rebuild"))
            let all = try index.search(s("query")!, folder: s("folder"), limit: 5000)
            var result = try stableHitPage(all, cursor: s("cursor"), limit: limit)
            result["hits"] = result.removeValue(forKey: "items")
            return try content(result)
        case "list_attachments": return try content(["attachments": NotePresentation.object(reader.attachments(s("ref")!))])
        case "save_attachment":
            var result = try saveAttachment(ref: s("ref")!, attachmentID: s("attachment_id")!, output: s("output")!)
            result["engine"] = "filesystem"
            return try content(result)
        case "list_backlinks": return try content(["notes": NotePresentation.object(reader.backlinks(s("ref")!))])
        case "get_deeplink":
            let summary = try reader.summary(s("ref")!)
            return try content(["url": summary.deepLink ?? "applenotes://showNote?identifier=\(summary.id.uuid)"])
        case "list_smart_folders": return try content(["folders": NotePresentation.object(reader.smartFolders(evaluate: b("evaluate")))])
        case "list_deleted":
            let all = try reader.notes(NoteQuery(includeDeleted: true)).filter(\.isDeleted)
            var result = try page(all, offset: offset, limit: limit) { try NotePresentation.object($0) }; result["notes"] = result.removeValue(forKey: "items")
            return try content(result)
        case "recent_notes", "today_notes":
            let calendar = Calendar.current
            let start = tool.name == "today_notes" ? calendar.startOfDay(for: Date()) : calendar.date(byAdding: .day, value: -max(1, i("days", 7)), to: Date())!
            let all = try reader.notes(NoteQuery(modifiedAfter: start), sort: .modified)
            var result = try page(all, offset: offset, limit: limit) { try NotePresentation.object($0) }; result["notes"] = result.removeValue(forKey: "items")
            return try content(result)
        // MARK: w9-ux begin
        case "pinned_notes":
            let requested = a["limit"] == nil ? 100 : i("limit")
            let notes = try reader.notes(NoteQuery(pinnedOnly: true, limit: requested), sort: .modified)
            return try content(["notes": NotePresentation.object(notes), "limit": requested, "total": notes.count])
        // MARK: w9-ux end
        case "count_notes":
            let query = NoteQuery(folder: s("folder"), account: s("account"), includeDeleted: b("include_deleted"), pinnedOnly: b("pinned"), tag: s("tag"), modifiedAfter: try s("since").map { try NotePresentation.date($0) }, modifiedBefore: try s("until").map { try NotePresentation.date($0) })
            return try content(["count": reader.notes(query).count])
        case "get_stats":
            let notes = try reader.notes(NoteQuery(includeDeleted: true))
            var folders: [String: Int] = [:], accounts: [String: Int] = [:]
            for note in notes { folders[note.folderPath.joined(separator: " > "), default: 0] += 1; accounts[note.accountID, default: 0] += 1 }
            return try content(["total": notes.count, "by_folder": folders, "by_account": accounts, "by_kind": reader.attachmentKindCounts()])
        // MARK: w9-ux begin
        case "get_capabilities":
            return try content(try NotePresentation.object(CapabilityReporter.report()) as! [String: Any])
        // MARK: w9-ux end
        case "get_raw_note":
            let raw = try String(decoding: NotePresentation.json(reader.rawNote(s("ref")!)), as: UTF8.self)
            let value = textPage(raw, offset: offset, limit: min(a["limit"] == nil ? 16_000 : limit, 16_000))
            var result: [String: Any] = ["json": value.0, "offset": offset, "truncated": value.1 != nil]
            if let next = value.1 { result["next_offset"] = next }
            return try content(result)
        case "related_notes":
            let note = try reader.note(s("ref")!), backlinks = try reader.backlinks(note.summary.id.uuid)
            let candidates = try reader.notes(NoteQuery()).filter { $0.id.uuid != note.summary.id.uuid }
            let tagSet = Set(note.summary.tags)
            let related = candidates.filter { !tagSet.isDisjoint(with: $0.tags) || backlinks.contains($0) }
            var result = try page(related, offset: offset, limit: limit) { try NotePresentation.object($0) }; result["notes"] = result.removeValue(forKey: "items")
            return try content(result)
        // MARK: w3-export begin
        case "export_notes":
            let format = NotesExportFormat(rawValue: s("format") ?? "markdown") ?? .markdown
            let order = NotesExportOrder(rawValue: s("order") ?? "display") ?? .display
            let report = try NotesExporter(reader: reader).run(ExportOptions(output: URL(fileURLWithPath: s("output")!), folder: s("folder"), format: format,
                includeAttachments: a["include_attachments"] as? Bool ?? true, embedMedia: b("embed_media"), template: s("template"),
                filenameTemplate: s("filename_template"), obsidian: b("obsidian"), prune: b("prune"), combine: b("combine"),
                scansPDF: b("scans_pdf"), order: order))
            return try content(["engine": "filesystem", "report": NotePresentation.object(report)])
        case "file_pull":
            let report = try SingleFileSync(reader: reader, writer: nil).pull(note: s("ref")!, to: URL(fileURLWithPath: s("path")!), dryRun: b("dry_run"))
            return try content(["engine": "filesystem", "report": NotePresentation.object(report)])
        case "file_diff":
            let report = try SingleFileSync(reader: reader, writer: nil).diff(URL(fileURLWithPath: s("path")!))
            return try content(["engine": "filesystem", "report": NotePresentation.object(report)])
        case "file_push":
            let path = URL(fileURLWithPath: s("path")!)
            if b("dry_run") {
                let report = try SingleFileSync(reader: reader, writer: nil).push(from: path, dryRun: true)
                return try content(["engine": "scripting", "dry_run": true, "report": NotePresentation.object(report)])
            }
            guard !readOnly, let writer else { throw NotesError("read_only", "Writing is disabled.") }
            let markdown = MarkdownFile.parse(try InputFile.readText(path, kind: "Markdown file", maxBytes: InputFile.maxTextBytes), fallbackTitle: path.deletingPathExtension().lastPathComponent)
            guard let noteID = markdown.noteID else { throw NotesError("invalid_file", "The Markdown file must contain notes-id front matter.") }
            let note = try reader.note(noteID), paths = [note.summary.folderPath]
            return try safeWrite(tool: tool, arguments: a, note: note, paths: paths, engine: "scripting", snapshotNotes: [note]) {
                do {
                    let guarded = ScriptingRewriteGuard(writer: writer, reader: reader, allowDowngrade: b("allow_downgrade"))
                    let report = try SingleFileSync(reader: reader, writer: guarded).push(from: path)
                    return (WriteResult(outcome: .verified, noteID: note.summary.id, message: report.message), try NotePresentation.object(report), nil)
                } catch NotesSyncError.writeUnknown(let message) {
                    return (WriteResult(outcome: .unknown, noteID: note.summary.id, message: message), nil, nil)
                }
            }
        // MARK: w3-export end
        case "sync_notes":
            guard !readOnly, let writer else { throw NotesError("read_only", "Writing is disabled.") }
            let folder = s("folder")!, paths = try folderPaths(folder)
            let notes = try reader.notes(NoteQuery(folder: folder)).compactMap { try? reader.note($0.id.uuid) }
            return try safeWrite(tool: tool, arguments: a, note: nil, paths: paths, engine: "scripting", snapshotNotes: notes) {
                let guarded = ScriptingRewriteGuard(writer: writer, reader: reader, allowDowngrade: b("allow_downgrade"))
                let report = try MarkdownSync(reader: reader, writer: guarded).run(SyncOptions(directory: URL(fileURLWithPath: s("directory")!), folder: folder, propagateDeletes: b("propagate_deletes")))
                return (WriteResult(outcome: .verified, message: "Sync pass completed."), try NotePresentation.object(report), nil)
            }
        // MARK: w3-read begin
        case "index_status":
            let index = LocalNotesIndex(url: stateRoot.appendingPathComponent("index.sqlite"))
            return try content(["index": NotePresentation.object(try index.status()), "job": NotePresentation.object(NotesIndexJobs.status())])
        case "get_attachment":
            return try attachmentContent(ref: s("ref")!, attachmentID: s("attachment_id")!)
        case "anchor_add":
            guard (s("heading") != nil) != (a["offset"] != nil) else { throw NotesError("invalid_anchor", "Choose one of heading or offset.") }
            let anchor = try ParagraphAnchorStore(url: stateRoot.appendingPathComponent("anchors.sqlite"))
                .add(note: reader.note(s("ref")!), heading: s("heading"), offset: a["offset"].map { _ in i("offset") })
            return try content(["anchor": NotePresentation.object(anchor)])
        case "anchor_list":
            let anchors = try ParagraphAnchorStore(url: stateRoot.appendingPathComponent("anchors.sqlite"), readOnly: readOnly).list(noteRef: s("ref"))
            return try content(["anchors": NotePresentation.object(anchors)])
        case "anchor_resolve":
            let resolved = try ParagraphAnchorStore(url: stateRoot.appendingPathComponent("anchors.sqlite"), readOnly: readOnly).resolve(s("id")!, reader: reader)
            return try content(["resolution": NotePresentation.object(resolved)])
        case "anchor_prune":
            let count = try ParagraphAnchorStore(url: stateRoot.appendingPathComponent("anchors.sqlite")).prune(reader: reader)
            return try content(["pruned": count])
        case "table_get":
            let note = try reader.note(s("ref")!), tables = note.document?.tables ?? [:]
            let selected: [String: [[String]]]
            if let id = s("attachment_id") {
                guard let rows = tables[id] else { throw NotesError("table_not_found", "No table matches the attachment id.") }
                selected = [id: rows]
            } else { selected = tables }
            guard !selected.isEmpty else { throw NotesError("table_not_found", "The note has no decoded table.") }
            let format = s("format") ?? "json"
            if format == "json" {
                let rich = note.document?.tableCells?.filter { selected[$0.key] != nil } ?? [:]
                return try content(["tables": NotePresentation.object(selected), "table_cells": NotePresentation.object(rich), "format": format])
            }
            let rendered = selected.sorted { $0.key < $1.key }.map { tableText($0.value, format: format) }.joined(separator: "\n\n")
            return try content(["tables": NotePresentation.object(selected), "format": format, "body": rendered])
        // MARK: w9-audio begin
        case "recording_transcript":
            let note = try reader.note(s("ref")!)
            let format = RecordingTranscriptFormat(rawValue: s("format") ?? "text") ?? .text
            let recordings = note.attachments.filter { $0.childAttachmentIDs?.isEmpty == false }.map {
                RecordingTranscript(attachmentID: $0.id, duration: $0.duration, segments: $0.transcriptWords ?? [])
            }
            guard !recordings.isEmpty else { throw NotesError("recording_not_found", "The note has no native recordings.") }
            return try content(["format": format.rawValue, "body": RecordingTranscriptRenderer.render(recordings, format: format)])
        // MARK: w9-audio end
        // MARK: w3-read end
        default: return try callScriptingWrite(tool, a)
        }
    }

    private func callScriptingWrite(_ tool: Tool, _ a: [String: Any]) throws -> [String: Any] {
        func s(_ key: String) -> String? { a[key] as? String }
        func b(_ key: String) -> Bool { a[key] as? Bool ?? false }
        if ["batch_move_notes", "batch_delete_notes"].contains(tool.name) {
            let refs = a["refs"] as! [String]
            var results: [[String: Any]] = []
            for ref in refs {
                var item = a; item.removeValue(forKey: "refs"); item["ref"] = ref
                if let key = a["idempotency_key"] as? String { item["idempotency_key"] = "\(key):\(ref)" }
                let itemTool = tools.first { $0.name == (tool.name == "batch_move_notes" ? "move_note" : "delete_note") }!
                do { results.append(["ref": ref, "response": try callScriptingWrite(itemTool, item)]) }
                catch { results.append(["ref": ref, "error": try NotePresentation.object(error as? NotesError ?? NotesError("internal_error", String(describing: error)))]) }
            }
            return try content(["results": results])
        }
        let noteTools = Set(["append_to_note", "prepend_to_note", "update_note", "write_markdown", "insert_under_heading", "replace_section", "replace_text", "rename_note", "move_note", "delete_note"])
        let note = try noteTools.contains(tool.name) ? s("ref").flatMap { try reader.note($0) } : nil
        let bodyRewriteTools = Set(["append_to_note", "prepend_to_note", "update_note", "write_markdown", "insert_under_heading", "replace_section", "replace_text"])
        if bodyRewriteTools.contains(tool.name), let note {
            try SnapshotRestorePolicy.requireScriptingBodyRewriteAllowed(note, allowDowngrade: b("allow_downgrade"))
        }
        let paths = try writePaths(tool: tool, arguments: a, note: note)
        return try safeWrite(tool: tool, arguments: a, note: note, paths: paths, engine: "scripting") {
            guard !readOnly, let writer else { throw NotesError("read_only", "Writing is disabled.") }
            let result: WriteResult
            // MARK: w9-ux begin
            let resolvedRef = note?.summary.id.uuid ?? s("ref")
            switch tool.name {
            case "create_note": result = try writer.createNote(title: s("title")!, markdown: s("body")!, folder: s("folder"))
            case "append_to_note": result = try writer.appendToNote(resolvedRef!, markdown: s("body")!)
            case "prepend_to_note": result = try writer.prependToNote(resolvedRef!, markdown: s("body")!, allowAttachmentLoss: b("allow_attachment_loss"))
            case "update_note", "write_markdown": result = try writer.replaceBody(resolvedRef!, markdown: s("body")!, allowAttachmentLoss: b("allow_attachment_loss"))
            case "insert_under_heading": result = try writer.insertUnderHeading(resolvedRef!, heading: s("heading")!, markdown: s("body")!, allowAttachmentLoss: b("allow_attachment_loss"))
            case "replace_section": result = try writer.replaceSection(resolvedRef!, heading: s("heading")!, markdown: s("body")!, allowAttachmentLoss: b("allow_attachment_loss"))
            case "replace_text": result = try writer.replaceText(resolvedRef!, find: s("find")!, replacement: s("replacement")!, allowAttachmentLoss: b("allow_attachment_loss"))
            case "rename_note": result = try writer.renameNote(resolvedRef!, title: s("title")!)
            case "move_note": result = try writer.moveNote(resolvedRef!, toFolder: s("folder")!)
            case "delete_note": result = try writer.deleteNote(resolvedRef!)
            case "create_folder": result = try writer.createFolder(name: s("name")!, parent: s("parent"), account: s("account"))
            case "rename_folder": result = try writer.renameFolder(s("ref")!, name: s("name")!)
            case "move_folder": result = try writer.moveFolder(s("ref")!, toParent: s("parent"), account: s("account"))
            case "delete_folder": result = try writer.deleteFolder(s("ref")!)
            default: throw NotesError("unknown_tool", "Unknown tool.")
            }
            // MARK: w9-ux end
            return (result, nil, nil)
        }
    }

    private func callNative(_ tool: Tool, _ arguments: [String: Any]) throws -> [String: Any] {
        guard allowNative else { throw NotesError("native_required", "This tool requires the private native engine.", hint: "Start notescli mcp with --allow-native.") }
        guard let nativeHandler else { throw NotesError("native_unavailable", "The native engine is not available.") }
        if !tool.write {
            let value = try nativeHandler(tool.name, arguments)
            return try content(["engine": "native", "value": try JSONSerialization.jsonObject(with: value.value)])
        }
        if tool.name == "checklist_auto_sort" {
            let current = try nativeHandler("journal_get_checklist_auto_sort", [:])
            guard let previous = try JSONSerialization.jsonObject(with: current.value, options: .fragmentsAllowed) as? Bool else {
                throw NotesError("invalid_native_result", "The native engine did not return the checklist auto-sort preimage.")
            }
            var recorded = arguments
            recorded["previous_enabled"] = previous
            return try safeWrite(tool: tool, arguments: recorded, note: nil, paths: [], engine: "native") {
                let value = try nativeHandler(tool.name, arguments)
                guard let result = value.result else { throw NotesError("invalid_native_result", "The native write did not return a write result.") }
                return (result, try JSONSerialization.jsonObject(with: value.value), value.operationID)
            }
        }
        if tool.name == "set_default_account" {
            let current = try nativeHandler("journal_get_default_account", [:])
            guard let previous = try JSONSerialization.jsonObject(with: current.value, options: .fragmentsAllowed) as? String else {
                throw NotesError("invalid_native_result", "The native engine did not return the default-account preimage.")
            }
            var recorded = arguments
            recorded["previous_account_id"] = previous
            return try safeWrite(tool: tool, arguments: recorded, note: nil, paths: [], engine: "native") {
                let value = try nativeHandler(tool.name, arguments)
                guard let result = value.result else { throw NotesError("invalid_native_result", "The native write did not return a write result.") }
                return (result, try JSONSerialization.jsonObject(with: value.value), value.operationID)
            }
        }
        if tool.name == "move_folder" {
            let source = try folder(arguments["ref"] as! String)
            let destination = try (arguments["parent"] as? String).map(folder)
            let notes = try reader.notes(NoteQuery()).filter { $0.folderPath.starts(with: source.path) }
                .map { try reader.note($0.id.uuid) }
            var dispatch = arguments
            dispatch["ref"] = source.id
            dispatch["parent"] = destination?.id
            let paths = [source.path, (destination?.path ?? []) + [source.name]]
            return try safeWrite(tool: tool, arguments: arguments, note: nil, paths: paths, engine: "native", snapshotNotes: notes) {
                let value = try nativeHandler(tool.name, dispatch)
                guard let result = value.result else { throw NotesError("invalid_native_result", "The native write did not return a write result.") }
                return (result, try JSONSerialization.jsonObject(with: value.value), value.operationID)
            }
        }
        // MARK: w9-audio begin
        if tool.name == "recording_create" {
            let paths = try folderPaths(arguments["folder"] as! String)
            return try safeWrite(tool: tool, arguments: arguments, note: nil, paths: paths, engine: "native") {
                let value = try nativeHandler(tool.name, arguments)
                guard let result = value.result else { throw NotesError("invalid_native_result", "The native write did not return a write result.") }
                return (result, try JSONSerialization.jsonObject(with: value.value), value.operationID)
            }
        }
        // MARK: w9-audio end
        // MARK: w4-format begin
        if ["smart_folder_create", "smart_folder_rename", "smart_folder_edit_rules", "smart_folder_edit_typed", "smart_folder_delete"].contains(tool.name) {
            var dispatch = arguments
            var recorded = arguments
            var paths: [[String]] = []
            if tool.name == "smart_folder_create" { paths = [[arguments["name"] as! String]] }
            else {
                let target = try folder(arguments["ref"] as! String)
                guard target.isSmartFolder else { throw NotesError("smart_folder_not_found", "No Smart Folder matches the reference.") }
                dispatch["ref"] = target.id; paths = [target.path]
                recorded["stable_id"] = target.id
                if ["smart_folder_edit_rules", "smart_folder_edit_typed"].contains(tool.name) {
                    let current = try nativeHandler("journal_get_smart_folder_query", ["ref": target.id])
                    guard let query = try JSONSerialization.jsonObject(with: current.value, options: .fragmentsAllowed) as? String else {
                        throw NotesError("invalid_native_result", "The native engine did not return the Smart Folder query preimage.")
                    }
                    recorded["previous_query_json"] = query
                }
            }
            return try safeWrite(tool: tool, arguments: recorded, note: nil, paths: paths, engine: "native") {
                let value = try nativeHandler(tool.name, dispatch)
                guard let result = value.result else { throw NotesError("invalid_native_result", "The native write did not return a write result.") }
                return (result, try JSONSerialization.jsonObject(with: value.value), value.operationID)
            }
        }
        if tool.name == "set_folder_sort" {
            let target = try folder(arguments["ref"] as! String)
            guard !target.isSmartFolder, !target.isRecentlyDeleted else { throw NotesError("folder_not_found", "No writable folder matches the reference.") }
            var dispatch = arguments
            dispatch["ref"] = target.id
            let current = try nativeHandler("get_folder_sort", ["ref": target.id])
            guard let setting = try JSONSerialization.jsonObject(with: current.value) as? [String: Any],
                  let previousOrder = setting["order"] as? String, let previousDirection = setting["direction"] as? String else {
                throw NotesError("invalid_native_result", "The native engine did not return the folder-sort preimage.")
            }
            var recorded = arguments
            recorded["stable_id"] = target.id
            recorded["previous_by"] = previousOrder
            recorded["previous_direction"] = previousDirection
            return try safeWrite(tool: tool, arguments: recorded, note: nil, paths: [target.path], engine: "native") {
                let value = try nativeHandler(tool.name, dispatch)
                guard let result = value.result else { throw NotesError("invalid_native_result", "The native write did not return a write result.") }
                return (result, try JSONSerialization.jsonObject(with: value.value), value.operationID)
            }
        }
        // MARK: w4-format end
        var targetNotes: [Note] = []
        if let ref = arguments["ref"] as? String { targetNotes = [try reader.note(ref)] }
        else if let tag = arguments["tag"] as? String { targetNotes = try reader.notes(NoteQuery(tag: tag)).map { try reader.note($0.id.uuid) } }
        let note = targetNotes.first
        var paths = targetNotes.map(\.summary.folderPath)
        if tool.name == "create_note", let folder = arguments["folder"] as? String { paths += try folderPaths(folder) }
        // MARK: w9-paper begin
        if tool.name == "drawing_create", let folder = arguments["folder"] as? String { paths += try folderPaths(folder) }
        // MARK: w9-paper end
        var dispatchArguments = arguments
        if let note { dispatchArguments["ref"] = note.summary.id.uuid }
        if tool.name == "link_add", let target = arguments["target"] as? String {
            dispatchArguments["target"] = try reader.summary(target).id.uuid
        }
        return try safeWrite(tool: tool, arguments: arguments, note: note, paths: paths, engine: "native", snapshotNotes: targetNotes) {
            let value = try nativeHandler(tool.name, dispatchArguments)
            guard let result = value.result else { throw NotesError("invalid_native_result", "The native write did not return a write result.") }
            return (result, try JSONSerialization.jsonObject(with: value.value), value.operationID)
        }
    }

    private func safeWrite(tool: Tool, arguments: [String: Any], note: Note?, paths: [[String]], engine: String,
                           snapshotNotes: [Note] = [],
                           action: () throws -> (WriteResult, Any?, String?)) throws -> [String: Any] {
        let configured = arguments["write_folders"] as? String ?? writeFolders ?? ProcessInfo.processInfo.environment["NOTESCLI_WRITE_FOLDERS"]
        let allowlist = WriteAllowlist(configured)
        if allowlist.isRestricted && paths.isEmpty { throw NotesError("write_not_allowed", "The target folder could not be resolved for the write allowlist.") }
        for path in paths { try allowlist.require(path) }
        if let note {
            try ConcurrencyGuard.require(note, ifModified: arguments["if_modified"] as? String, expectRevision: arguments["expect_revision"] as? String)
            if note.summary.isShared == true {
                guard arguments["allow_shared"] as? Bool == true else {
                    throw NotesError("shared_write_refused", "The note is shared. Set allow_shared to confirm the write.")
                }
                guard engine == "native" else { throw NotesError("native_required", "Shared-note writes require MCP native mode so Notes can check write permission.") }
            }
        }
        if arguments["dry_run"] as? Bool == true {
            var clean = arguments
            for key in ["dry_run", "idempotency_key", "if_modified", "expect_revision", "write_folders"] { clean.removeValue(forKey: key) }
            return try content(["dry_run": true, "tool": tool.name, "engine": engine, "arguments": clean, "message": "No changes made."])
        }
        if !snapshotNotes.isEmpty {
            for target in snapshotNotes { _ = try SnapshotStore(rootURL: stateRoot.appendingPathComponent("snapshots")).save(target) }
        } else if tool.destructive, let note {
            _ = try SnapshotStore(rootURL: stateRoot.appendingPathComponent("snapshots")).save(note)
        }
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var recorded = arguments
        recorded["tool"] = tool.name; recorded["engine"] = engine
        if let note { recorded["stable_id"] = note.summary.id.uuid }
        let data = try JSONSerialization.data(withJSONObject: recorded, options: [.sortedKeys])
        let journal = try WriteJournal(url: stateRoot.appendingPathComponent("journal.sqlite"))
        let begun = try journal.begin(operation: tool.name, arguments: data, idempotencyKey: arguments["idempotency_key"] as? String)
        if begun.replayed {
            if let result = begun.entry.result { return try content(["engine": engine, "result": NotePresentation.object(result), "replayed": true]) }
            throw NotesError("write_outcome_unknown", "The recorded operation has an unresolved outcome.")
        }
        do {
            let started = Date().addingTimeInterval(-1)
            var (result, details, operationID) = try action()
            if arguments["wait_sync"] as? Bool == true, result.outcome == .verified,
               let noteID = result.noteID?.uuid, !noteID.isEmpty {
                let timeout = (arguments["sync_timeout"] as? NSNumber)?.doubleValue ?? 30
                result.syncPending = !((try? syncWaiter?(noteID, started, timeout)) ?? false)
            }
            let outcome = JournalOutcome(rawValue: result.outcome.rawValue) ?? .failed
            let identity = result.noteID.flatMap { $0.uuid.isEmpty ? $0.coreDataID : $0.uuid } ?? result.folderID
            try journal.finish(begun.entry.id, outcome: outcome, noteID: identity, result: result, message: result.message)
            var value: [String: Any] = ["engine": engine, "result": try NotePresentation.object(result)]
            if let operationID { value["operationID"] = operationID }
            if let details { value["details"] = details }
            return try content(value, isError: result.outcome == .unknown || result.outcome == .rolledBack)
        } catch {
            try? journal.finish(begun.entry.id, outcome: .failed, message: String(describing: error))
            throw error
        }
    }

    private func writePaths(tool: Tool, arguments: [String: Any], note: Note?) throws -> [[String]] {
        if let note {
            var values = [note.summary.folderPath]
            if let folder = arguments["folder"] as? String { values += try folderPaths(folder) }
            return values
        }
        if tool.name == "create_note", let folder = arguments["folder"] as? String { return try folderPaths(folder) }
        if ["create_folder", "rename_folder", "move_folder", "delete_folder"].contains(tool.name) {
            var values: [[String]] = []
            if let ref = arguments["ref"] as? String { values += try folderPaths(ref) }
            if let parent = arguments["parent"] as? String { values += try folderPaths(parent) }
            if tool.name == "create_folder" {
                let parent = (arguments["parent"] as? String).map { $0.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
                values.append(parent + [arguments["name"] as! String])
            }
            return values
        }
        return []
    }

    private func folderPaths(_ ref: String) throws -> [[String]] {
        [try folder(ref).path]
    }

    private func folder(_ ref: String) throws -> Folder {
        let matches = try reader.folders(account: nil).filter { $0.id == ref || $0.coreDataID == ref || $0.name == ref || $0.path.joined(separator: " > ") == ref }
        guard matches.count == 1 else { throw NotesError(matches.isEmpty ? "folder_not_found" : "ambiguous_folder", "Folder must resolve uniquely.") }
        return matches[0]
    }

    private func saveAttachment(ref: String, attachmentID: String, output: String) throws -> [String: Any] {
        let attachment = try reader.attachments(ref).first { $0.id == attachmentID }
        guard let attachment else { throw NotesError("attachment_not_found", "The attachment was not found.") }
        guard let path = attachment.filePath else { throw NotesError("attachment_unavailable", "The attachment original is not available on disk.") }
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let target = URL(fileURLWithPath: output).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: target.path) else { throw NotesError("file_exists", "Refusing to replace an existing file.") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        return ["attachment_id": attachmentID, "path": target.path, "bytes": (try Data(contentsOf: target)).count]
    }

    private func readResource(_ params: [String: Any]) throws -> [String: Any] {
        guard let uri = params["uri"] as? String else { throw NotesError("invalid_resource", "uri is required.") }
        if uri == MCPProtocol.widgetURI {
            return ["contents": [["uri": uri, "mimeType": MCPProtocol.appsMIMEType,
                                   "text": NotesMCPWidget.html, "_meta": NotesMCPWidget.contentMetadata]]]
        }
        if uri == "notes://folders" {
            let text = String(decoding: try NotePresentation.json(reader.folders(account: nil)), as: UTF8.self)
            return ["contents": [["uri": uri, "mimeType": "application/json", "text": text]]]
        }
        if uri.hasPrefix("notes://attachment/") { return try attachmentResource(uri) }
        guard uri.hasPrefix("notes://note/") else { throw NotesError("resource_not_found", "Unknown Notes resource.") }
        let ref = String(uri.dropFirst("notes://note/".count)).removingPercentEncoding ?? ""
        let text = String(decoding: try NotePresentation.json(reader.note(ref)), as: UTF8.self)
        return ["contents": [["uri": uri, "mimeType": "application/json", "text": text]]]
    }

    private func getPrompt(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw NotesError("invalid_prompt", "name is required.") }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "find_note":
            guard let query = arguments["query"] as? String else { throw NotesError("invalid_prompt", "query is required.") }
            return ["description": "Find and summarize matching notes", "messages": [["role": "user", "content": ["type": "text", "text": "Use search_notes for \"\(query)\". Summarize only the matching Notes content and cite note titles."]]]]
        case "weekly_review":
            return ["description": "Review recent notes", "messages": [["role": "user", "content": ["type": "text", "text": "Use recent_notes with days=7. Group the results by topic and list unresolved checklist items."]]]]
        default: throw NotesError("prompt_not_found", "Unknown prompt.")
        }
    }

    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        let connection = makeConnection()
        let writer = MCPOutputWriter(output)
        let queue = DispatchQueue(label: "notescli.mcp.requests", qos: .userInitiated, attributes: .concurrent)
        let group = DispatchGroup()

        func submit(_ line: Data) {
            guard !line.isEmpty else { return }
            let value: Any
            do {
                value = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
            } catch {
                writer.send(self.error(id: NSNull(), code: -32700, message: "Parse error"))
                return
            }
            guard let request = value as? [String: Any] else {
                writer.send(self.error(id: NSNull(), code: -32600, message: "Invalid request"))
                return
            }
            let id = request["id"] ?? NSNull()
            guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String,
                  request["id"] == nil || MCPProtocol.isValidRequestID(id),
                  request["params"] == nil || request["params"] is [String: Any] else {
                writer.send(self.handle(request, connection: connection))
                return
            }
            let params = request["params"] as? [String: Any] ?? [:]
            if request["id"] == nil {
                _ = self.handle(request, connection: connection)
                return
            }
            guard let cancellation = connection.reserve(id) else {
                writer.send(self.error(id: id, code: -32600, message: "This request id is already running"))
                return
            }
            let prepared = MCPPreparedRequest(id: id, method: method, params: params, cancellation: cancellation)
            group.enter()
            queue.async { [self] in
                let response = handleReserved(id: prepared.id, method: prepared.method, params: prepared.params,
                                              connection: connection, cancellation: prepared.cancellation)
                writer.send(response)
                connection.release(prepared.id, cancellation: prepared.cancellation)
                group.leave()
            }
        }

        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0a) {
                var line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.last == 0x0d { line.removeLast() }
                submit(line)
            }
        }
        if !buffer.isEmpty { submit(buffer) }
        group.wait()
    }
}
