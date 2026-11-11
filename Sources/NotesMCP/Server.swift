import Foundation
import NotesCore

public final class MCPServer {
    public let reader: any NotesReading
    public let writer: (any NotesWriting)?
    public let readOnly: Bool
    public static let textLimit = 48 * 1024
    public static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public init(reader: any NotesReading, writer: (any NotesWriting)? = nil, readOnly: Bool = false) {
        self.reader = reader; self.writer = writer; self.readOnly = readOnly
    }

    private struct Tool {
        let name: String
        let description: String
        let write: Bool
        let required: [String]
        let properties: [String: [String: Any]]
        var schema: [String: Any] { ["type": "object", "properties": properties, "required": required, "additionalProperties": false] }
    }
    private var tools: [Tool] {
        let string: [String: Any] = ["type": "string"]
        let bool: [String: Any] = ["type": "boolean"]
        let integer: [String: Any] = ["type": "integer", "minimum": 0]
        let page = ["offset": integer, "limit": integer]
        func t(_ name: String, _ description: String, _ required: [String] = [], _ properties: [String: [String: Any]] = [:], write: Bool = false) -> Tool {
            var p = properties; if write { p["dry_run"] = bool }
            return Tool(name: name, description: description, write: write, required: required, properties: p)
        }
        let filters: [String: [String: Any]] = ["folder": string, "account": string, "pinned": bool, "tag": string, "since": string, "until": string, "include_deleted": bool]
        return [
            t("list_accounts", "List Notes accounts."),
            t("list_folders", "List folders.", [], ["account": string]),
            t("list_notes", "List notes ordered by modification date.", [], filters.merging(page) { a, _ in a }),
            t("search_notes", "Search note titles and bodies.", ["query"], ["query": string, "folder": string].merging(page) { a, _ in a }),
            t("get_note", "Read one note.", ["ref"], ["ref": string, "format": ["type": "string", "enum": ["markdown", "text", "html", "json"]], "attachments": bool]),
            t("list_tags", "List tags and note counts."),
            t("create_note", "Create a note from Markdown.", ["title", "body"], ["title": string, "body": string, "folder": string], write: true),
            t("append_to_note", "Append Markdown to a note.", ["ref", "body"], ["ref": string, "body": string], write: true),
            t("update_note", "Replace the body. Attachments and checklists may downgrade.", ["ref", "body"], ["ref": string, "body": string], write: true),
            t("rename_note", "Rename a note.", ["ref", "title"], ["ref": string, "title": string], write: true),
            t("move_note", "Move a note to a folder.", ["ref", "folder"], ["ref": string, "folder": string], write: true),
            t("delete_note", "Move a note to Recently Deleted.", ["ref"], ["ref": string], write: true),
            t("create_folder", "Create a folder.", ["name"], ["name": string, "parent": string, "account": string], write: true),
            t("rename_folder", "Rename a folder.", ["ref", "name"], ["ref": string, "name": string], write: true),
            t("delete_folder", "Delete a folder, moving its notes to Recently Deleted.", ["ref"], ["ref": string], write: true)
        ].filter { !readOnly || !$0.write }
    }

    public func handleLine(_ line: String) -> String? {
        let response: [String: Any]?
        do {
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])
            guard let request = value as? [String: Any] else { return encode(error(id: NSNull(), code: -32600, message: "Invalid request")) }
            response = handle(request)
        } catch { response = self.error(id: NSNull(), code: -32700, message: "Parse error") }
        return response.map(encode)
    }
    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Encoding failed\"}}"
        }
        return String(decoding: data, as: UTF8.self)
    }
    private func error(id: Any, code: Int, message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]] }
    public func handle(_ request: [String: Any]) -> [String: Any]? {
        let id = request["id"] ?? NSNull()
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String,
              request["id"] == nil || id is NSNull || id is String || (id is NSNumber && String(cString: (id as! NSNumber).objCType) != "c") else {
            return error(id: NSNull(), code: -32600, message: "Invalid request")
        }
        if request["id"] == nil { return nil }
        guard request["params"] == nil || request["params"] is [String: Any] else { return error(id: id, code: -32602, message: "Parameters must be an object") }
        let params = request["params"] as? [String: Any] ?? [:]
        do {
            let result: [String: Any]
            switch method {
            case "initialize":
                guard let version = params["protocolVersion"] as? String else { return error(id: id, code: -32602, message: "protocolVersion is required") }
                result = ["protocolVersion": Self.versions.contains(version) ? version : Self.versions[0],
                          "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "notescli", "version": "1.0.0"]]
            case "ping": result = [:]
            case "tools/list": result = ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema, "annotations": ["readOnlyHint": !$0.write, "destructiveHint": $0.name == "delete_note" || $0.name == "delete_folder" || $0.name == "update_note"]] as [String: Any] }]
            case "tools/call":
                guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else { return error(id: id, code: -32602, message: "Unknown or unavailable tool") }
                guard params["arguments"] == nil || params["arguments"] is [String: Any] else { return error(id: id, code: -32602, message: "arguments must be an object") }
                let args = params["arguments"] as? [String: Any] ?? [:]
                if let issue = validate(args, tool: tool) { return error(id: id, code: -32602, message: issue) }
                do { result = try call(tool, args) }
                catch { let e = error as? NotesError ?? NotesError("internal_error", String(describing: error)); result = try content(["error": NotePresentation.object(e)], isError: true) }
            default: return error(id: id, code: -32601, message: "Method not found")
            }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch { return self.error(id: id, code: -32603, message: "Internal error") }
    }
    private func validate(_ args: [String: Any], tool: Tool) -> String? {
        for key in tool.required where args[key] == nil { return "Missing argument: \(key)" }
        for (key, value) in args {
            guard let spec = tool.properties[key] else { return "Unknown argument: \(key)" }
            switch spec["type"] as? String {
            case "string": if !(value is String) { return "\(key) must be a string" }
            case "boolean": if !(value is NSNumber) || String(cString: (value as! NSNumber).objCType) != "c" { return "\(key) must be a boolean" }
            case "integer":
                guard let n = value as? NSNumber, String(cString: n.objCType) != "c", n.doubleValue >= 0, n.doubleValue < Double(Int.max), n.doubleValue.rounded() == n.doubleValue else { return "\(key) must be a nonnegative integer" }
            default: break
            }
            if let values = spec["enum"] as? [String], !values.contains(value as? String ?? "") { return "Invalid \(key)" }
        }
        return nil
    }
    private func content(_ structured: [String: Any], isError: Bool = false) throws -> [String: Any] {
        var structured = structured
        let data = try JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys])
        var text = String(decoding: data, as: UTF8.self)
        if data.count > Self.textLimit {
            structured["truncated"] = true
            var prefix = Data(data.prefix(Self.textLimit - 128))
            while String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
            text = String(decoding: prefix, as: UTF8.self) + "\n[Text truncated; use structuredContent and offset/limit for lists.]"
        }
        return ["content": [["type": "text", "text": text]], "structuredContent": structured, "isError": isError]
    }
    private func call(_ tool: Tool, _ a: [String: Any]) throws -> [String: Any] {
        func s(_ key: String) -> String? { a[key] as? String }
        func b(_ key: String) -> Bool { a[key] as? Bool ?? false }
        if tool.write && b("dry_run") {
            var arguments = a; arguments.removeValue(forKey: "dry_run")
            return try content(["dry_run": true, "tool": tool.name, "arguments": arguments, "message": "No changes made."])
        }
        switch tool.name {
        case "list_accounts": return try content(["accounts": NotePresentation.object(reader.accounts())])
        case "list_folders": return try content(["folders": NotePresentation.object(reader.folders(account: s("account")))])
        case "list_tags": return try content(["tags": reader.tags()])
        case "get_note":
            let n = try reader.note(s("ref")!)
            let format = s("format") ?? "markdown"
            if format == "json" {
                let rendered = try NotePresentation.render(n, format: format, attachments: a["attachments"] as? Bool ?? true)
                return try content(["note": JSONSerialization.jsonObject(with: Data(rendered.utf8))])
            }
            return try content(["summary": NotePresentation.object(n.summary), "format": format,
                                "body": NotePresentation.render(n, format: format, attachments: a["attachments"] as? Bool ?? true)])
        case "list_notes", "search_notes":
            let offset = a["offset"] as? Int ?? 0, limit = min(a["limit"] as? Int ?? 100, 1000)
            let q = NoteQuery(folder: s("folder"), account: s("account"), text: s("query"), includeDeleted: b("include_deleted"), pinnedOnly: b("pinned"), tag: s("tag"), modifiedAfter: try s("since").map { try NotePresentation.date($0) }, modifiedBefore: try s("until").map { try NotePresentation.date($0) })
            let all = try reader.notes(q)
            var page = Array(all.dropFirst(offset).prefix(limit))
            while page.count > 1 {
                if try NotePresentation.json(page).count <= Self.textLimit - 1024 { break }
                page.removeLast()
            }
            let next = offset + page.count
            var result: [String: Any] = ["notes": try NotePresentation.object(page), "offset": offset, "limit": limit, "total": all.count, "truncated": next < all.count]
            if next < all.count { result["next_offset"] = next; result["hint"] = "Call again with next_offset as offset and a positive limit." }
            return try content(result)
        default:
            guard !readOnly, let writer else { throw NotesError("read_only", "Writing is disabled.") }
            let result: WriteResult
            switch tool.name {
            case "create_note": result = try writer.createNote(title: s("title")!, markdown: s("body")!, folder: s("folder"))
            case "append_to_note": result = try writer.appendToNote(s("ref")!, markdown: s("body")!)
            case "update_note": result = try writer.replaceBody(s("ref")!, markdown: s("body")!)
            case "rename_note": result = try writer.renameNote(s("ref")!, title: s("title")!)
            case "move_note": result = try writer.moveNote(s("ref")!, toFolder: s("folder")!)
            case "delete_note": result = try writer.deleteNote(s("ref")!)
            case "create_folder": result = try writer.createFolder(name: s("name")!, parent: s("parent"), account: s("account"))
            case "rename_folder": result = try writer.renameFolder(s("ref")!, name: s("name")!)
            case "delete_folder": result = try writer.deleteFolder(s("ref")!)
            default: throw NotesError("unknown_tool", "Unknown tool.")
            }
            return try content(["result": NotePresentation.object(result)], isError: result.outcome == .unknown)
        }
    }
    public func run() {
        while let line = readLine() {
            if let response = handleLine(line) { FileHandle.standardOutput.write(Data((response + "\n").utf8)) }
        }
    }
}
