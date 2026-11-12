import ArgumentParser
import Foundation
import NotesCore
import NotesMCP
import NotesNative
import NotesSafety
import NotesStore

enum MCPClient: String, CaseIterable, ExpressibleByArgument {
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case codex
    case cursor
    case vscode
    case all

    static var concrete: [MCPClient] { [.claudeCode, .claudeDesktop, .codex, .cursor, .vscode] }
    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .all: return "All clients"
        }
    }
}

struct MCPRoot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run MCP on stdio or manage client connections.",
        subcommands: [MCPInstall.self, MCPUninstall.self, MCPStatus.self]
    )
    @OptionGroup var options: GlobalOptions
    @Flag(help: "Expose opt-in tools that write through Apple's private Notes framework.") var allowNative = false

    func run() throws {
        let backend = try options.backends()
        let selectedWriter: (any NotesWriting)? = options.readOnly ? nil : try backend.writer()
        let handler: MCPNativeHandler? = allowNative ? { try mcpNativeCall($0, $1) } : nil
        let server = MCPServer(reader: backend.reader, writer: selectedWriter, readOnly: options.readOnly,
                               allowNative: allowNative, nativeHandler: handler,
                               syncWaiter: { try NoteSyncWaiter.wait(noteID: $0, modifiedAfter: $1, timeout: $2) },
                               stateRoot: NotesSafetyPaths.applicationSupport)
        server.run()
    }
}

private func mcpNativeCall(_ tool: String, _ arguments: [String: Any]) throws -> MCPNativeResult {
    func string(_ key: String) -> String? { arguments[key] as? String }
    func integer(_ key: String) -> Int? { (arguments[key] as? NSNumber)?.intValue }
    func boolean(_ key: String) -> Bool? { arguments[key] as? Bool }
    func ref() throws -> String {
        guard let value = string("ref") else { throw NotesError("invalid_arguments", "ref is required.") }
        return value
    }
    func result(_ value: NativeWriteResult) throws -> MCPNativeResult {
        try MCPNativeResult(result: value.writeResult, operationID: value.operationID, value: value)
    }
    let writer = NativeNotesWriter()
    let allowShared = boolean("allow_shared") ?? false
    switch tool {
    case "create_note":
        let paths = arguments["attachments"] as? [String] ?? []
        let frozen = try paths.map { try FrozenAttachmentInput(file: URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)) }
        let value = try writer.createNote(title: string("title")!, markdown: string("body")!, folder: string("folder"), attachments: frozen, allowShared: allowShared)
        return try MCPNativeResult(result: value.write.writeResult, operationID: value.write.operationID, value: value)
    case "update_note", "write_markdown":
        return try result(writer.writeMarkdown(ref(), markdown: string("body")!, dryRun: false, backup: false, allowShared: allowShared))
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
        let alignment = string("alignment").flatMap(NativeParagraphAlignment.init(rawValue:))
        let direction = string("writing_direction").flatMap(NativeWritingDirection.init(rawValue:))
        return try result(writer.setParagraphStyle(ref(), range: UTF16Range(location: integer("start")!, length: integer("length")!), style: style, indent: integer("indent"),
                                                   alignment: alignment, writingDirection: direction, collapsed: boolean("collapsed"), allowShared: (boolean("allow_shared") ?? false)))
    case "format_inline":
        let script = boolean("superscript") == true ? 1 : (boolean("subscript") == true ? -1 : (boolean("clear_script") == true ? 0 : nil))
        let format = InlineFormat(bold: boolean("bold"), italic: boolean("italic"), underline: boolean("underline"), strike: boolean("strike"),
                                  link: string("link"), clearLink: boolean("clear_link") ?? false, color: string("color"), clearColor: boolean("clear_color") ?? false,
                                  superscript: script, fontName: string("font_name"), fontSize: (arguments["font_size"] as? NSNumber)?.doubleValue,
                                  highlight: string("highlight").flatMap(HighlightColor.init(rawValue:)), clearHighlight: boolean("clear_highlight") ?? false)
        return try result(writer.setInlineFormat(ref(), range: UTF16Range(location: integer("start")!, length: integer("length")!), format: format, allowShared: (boolean("allow_shared") ?? false)))
    case "insert_divider": return try result(writer.insertDivider(ref(), position: integer("position"), allowShared: (boolean("allow_shared") ?? false)))
    case "insert_math": return try result(writer.insertMathExpression(ref(), expression: string("expression")!, position: integer("position"), allowShared: (boolean("allow_shared") ?? false)))
    case "insert_mention": return try result(writer.insertMention(ref(), text: string("text")!, userRecordName: string("user_record_name")!, position: integer("position"), allowShared: (boolean("allow_shared") ?? false)))
    case "attach_file":
        let value = try writer.insertFile(ref(), file: URL(fileURLWithPath: string("path")!), position: integer("position"), imageView: string("view"), allowShared: (boolean("allow_shared") ?? false))
        return try MCPNativeResult(result: value.write.writeResult, operationID: value.write.operationID, value: value)
    case "delete_attachment": return try result(writer.deleteAttachment(ref(), attachmentID: string("attachment_id")!, allowShared: (boolean("allow_shared") ?? false)))
    case "table_create":
        guard let rows = arguments["rows"] as? [[String]] else { throw NotesError("invalid_arguments", "rows must be an array of string arrays.") }
        return try result(writer.createTable(ref(), rows: rows, position: integer("position"), allowShared: (boolean("allow_shared") ?? false)))
    case "table_set": return try result(writer.editTable(ref(), attachmentID: string("attachment_id")!, row: integer("row")!, column: integer("column")!, text: string("text")!, allowShared: (boolean("allow_shared") ?? false)))
    case "table_convert_to_text": return try result(writer.convertTableToText(ref(), attachmentID: string("attachment_id")!, separator: string("separator") ?? "tab", allowShared: (boolean("allow_shared") ?? false)))
    case "table_add_row", "table_remove_row", "table_add_column", "table_remove_column":
        let axis = tool.contains("row") ? "row" : "column", add = tool.contains("add")
        return try result(writer.resizeTable(ref(), attachmentID: string("attachment_id")!, axis: axis, index: integer("index")!, add: add, allowShared: (boolean("allow_shared") ?? false)))
    case "duplicate_note": return try result(writer.duplicate(ref(), title: string("title"), allowShared: (boolean("allow_shared") ?? false)))
    case "restore_note": return try result(writer.restore(ref(), folder: string("folder"), allowShared: (boolean("allow_shared") ?? false)))
    case "move_folder": return try result(writer.moveFolder(ref(), parent: string("parent"), allowShared: (boolean("allow_shared") ?? false)))
    default: throw NotesError("unknown_tool", "Unknown native MCP tool.")
    }
}

struct MCPInstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Connect notescli to an MCP client.")
    @Option(help: "Client: claude-code, claude-desktop, codex, cursor, vscode, or all.") var client: MCPClient = .all
    @OptionGroup var options: GlobalOptions

    func run() throws {
        try MCPConfiguration.apply(client: client) { selected in
            try MCPConfiguration.install(selected, readOnly: options.readOnly)
        }
    }
}

struct MCPUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Disconnect notescli from an MCP client.")
    @Option(help: "Client: claude-code, claude-desktop, codex, cursor, vscode, or all.") var client: MCPClient = .all

    func run() throws {
        try MCPConfiguration.apply(client: client) { selected in
            try MCPConfiguration.uninstall(selected)
        }
    }
}

struct MCPStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show MCP client connections.")
    @Option(help: "Client: claude-code, claude-desktop, codex, cursor, vscode, or all.") var client: MCPClient = .all

    func run() throws {
        let clients = client == .all ? MCPClient.concrete : [client]
        Output.table(["CLIENT", "STATUS"], clients.map { [$0.label, MCPConfiguration.status($0)] })
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Connect MCP clients and open macOS permission settings.")

    func run() throws {
        try MCPConfiguration.apply(client: .all) { selected in
            try MCPConfiguration.install(selected, readOnly: false)
        }
        try PermissionGuide.run()
    }
}

struct Permissions: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Full Disk Access and request Notes Automation access.")
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

    static func install(_ client: MCPClient, readOnly: Bool) throws -> String {
        switch client {
        case .claudeCode: return try installClaudeCode(readOnly: readOnly)
        case .claudeDesktop:
            return try installJSON(
                at: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
                serversKey: "mcpServers", readOnly: readOnly, includeType: false
            )
        case .codex: return try installCodex(readOnly: readOnly)
        case .cursor:
            return try installJSON(at: home.appendingPathComponent(".cursor/mcp.json"), serversKey: "mcpServers", readOnly: readOnly, includeType: false)
        case .vscode:
            return try installJSON(
                at: home.appendingPathComponent("Library/Application Support/Code/User/mcp.json"),
                serversKey: "servers", readOnly: readOnly, includeType: true
            )
        case .all: preconditionFailure("Expand all before installing")
        }
    }

    static func uninstall(_ client: MCPClient) throws -> String {
        switch client {
        case .claudeCode: return try uninstallClaudeCode()
        case .claudeDesktop:
            return try uninstallJSON(at: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"), serversKey: "mcpServers")
        case .codex: return try uninstallCodex()
        case .cursor: return try uninstallJSON(at: home.appendingPathComponent(".cursor/mcp.json"), serversKey: "mcpServers")
        case .vscode:
            return try uninstallJSON(at: home.appendingPathComponent("Library/Application Support/Code/User/mcp.json"), serversKey: "servers")
        case .all: preconditionFailure("Expand all before uninstalling")
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
        case .all: return ""
        }
    }

    private static func arguments(readOnly: Bool) -> [String] {
        readOnly ? ["mcp", "--read-only"] : ["mcp"]
    }

    private static func installJSON(at path: URL, serversKey: String, readOnly: Bool, includeType: Bool) throws -> String {
        var root = try readJSON(at: path)
        if let value = root[serversKey], !(value is [String: Any]) {
            throw NotesError("invalid_client_config", "\(path.path): \(serversKey) must be an object.")
        }
        var servers = root[serversKey] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["command": executable, "args": arguments(readOnly: readOnly)]
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

    private static func jsonStatus(at path: URL, serversKey: String) -> String {
        guard let root = try? readJSON(at: path), let servers = root[serversKey] as? [String: Any], servers["notescli"] != nil else {
            return "not installed"
        }
        return "installed"
    }

    private static func installCodex(readOnly: Bool) throws -> String {
        let path = home.appendingPathComponent(".codex/config.toml")
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let base = removingTOMLSection("mcp_servers.notescli", from: existing).trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = base.isEmpty ? [] : [base, ""]
        lines += ["[mcp_servers.notescli]", "command = \(tomlString(executable))", "args = \(tomlArray(arguments(readOnly: readOnly)))"]
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

    private static func tomlString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static func tomlArray(_ values: [String]) -> String {
        "[" + values.map(tomlString).joined(separator: ", ") + "]"
    }

    private static func installClaudeCode(readOnly: Bool) throws -> String {
        guard let claude = findExecutable("claude") else { return "skipped (claude CLI not found)" }
        let current = try? run(claude, ["mcp", "get", "notescli"])
        let wantedReadOnly = readOnly
        if let current, current.status == 0, current.output.contains(executable), current.output.contains("mcp"), current.output.contains("--read-only") == wantedReadOnly {
            return "already installed"
        }
        _ = try backupIfPresent(home.appendingPathComponent(".claude.json"))
        _ = try? run(claude, ["mcp", "remove", "--scope", "user", "notescli"])
        let result = try run(claude, ["mcp", "add", "--scope", "user", "notescli", "--", executable] + arguments(readOnly: readOnly))
        guard result.status == 0 else { throw NotesError("client_command_failed", result.output) }
        return "installed with claude mcp"
    }

    private static func uninstallClaudeCode() throws -> String {
        guard let claude = findExecutable("claude") else { return "skipped (claude CLI not found)" }
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
    static func run() throws {
        print("Full Disk Access is required to read Apple Notes.")
        print("Add the app that launches notescli: Terminal for shell use, or the MCP host app (Claude, Codex, Cursor, or VS Code).")
        let settings = Process()
        settings.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        settings.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
        try settings.run()
        settings.waitUntilExit()
        if settings.terminationStatus != 0 { Output.error("Could not open the Full Disk Access pane.") }

        print("Requesting Automation access with a harmless read of the Notes app name. No note content is read.")
        let automation = Process()
        let pipe = Pipe()
        automation.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        automation.arguments = ["-e", "tell application \"Notes\" to get name"]
        automation.standardOutput = pipe
        automation.standardError = pipe
        try automation.run()
        automation.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if automation.terminationStatus == 0 { print("Automation: authorized for Notes.") }
        else {
            Output.error("Automation was not authorized: \(output)")
            Output.error("Open System Settings > Privacy & Security > Automation and allow Notes for the same terminal or MCP host app.")
        }
    }
}
