import XCTest
import NotesCore
@testable import NotesMCP

final class ProtocolTests: XCTestCase {
    func request(_ server: MCPServer, method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": method, "params": params]))
    }
    func call(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        let response = try request(server, method: "tools/call", params: ["name": name, "arguments": args])
        return try XCTUnwrap(response["result"] as? [String: Any])
    }
    func structured(_ result: [String: Any]) throws -> [String: Any] { try XCTUnwrap(result["structuredContent"] as? [String: Any]) }
    func testVersionsAndNotifications() throws {
        let server = MCPServer(reader: InMemoryNotes.sample())
        for version in MCPServer.versions + ["future"] {
            let result = try request(server, method: "initialize", params: ["protocolVersion": version])["result"] as? [String: Any]
            XCTAssertEqual(result?["protocolVersion"] as? String, version == "future" ? MCPServer.versions[0] : version)
        }
        XCTAssertNil(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNotNil(try request(server, method: "ping")["result"])
        XCTAssertTrue(server.handleLine("{")!.contains("-32700"))
        XCTAssertTrue(server.handleLine("[]")!.contains("-32600"))
        XCTAssertTrue(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"other"}"#)!.contains("-32601"))
    }
    func testSchemasAndReadOnlyHiding() throws {
        let fake = InMemoryNotes.sample()
        for readOnly in [false, true] {
            let server = MCPServer(reader: fake, writer: fake, readOnly: readOnly)
            let result = try request(server, method: "tools/list")["result"] as! [String: Any]
            let tools = result["tools"] as! [[String: Any]]
            XCTAssertEqual(tools.count, readOnly ? 21 : 42)
            XCTAssertEqual(tools.contains { $0["name"] as? String == "delete_note" }, !readOnly)
            for tool in tools { XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object") }
            if readOnly {
                let response = try request(server, method: "tools/call", params: ["name": "create_note", "arguments": ["title": "No", "body": "No", "dry_run": true]])
                XCTAssertNotNil(response["error"])
            }
        }
        let names = ((try request(MCPServer(reader: fake, writer: fake), method: "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["list_accounts", "list_folders", "list_notes", "search_notes", "query_notes", "get_note", "get_notes", "list_tags", "list_attachments", "save_attachment", "list_backlinks", "get_deeplink", "list_smart_folders", "list_deleted", "recent_notes", "today_notes", "count_notes", "get_stats", "get_raw_note", "related_notes", "get_write_policy", "export_notes", "file_pull", "file_push", "file_diff", "sync_notes", "create_note", "append_to_note", "prepend_to_note", "update_note", "insert_under_heading", "replace_section", "replace_text", "rename_note", "move_note", "delete_note", "batch_move_notes", "batch_delete_notes", "create_folder", "rename_folder", "delete_folder", "write_markdown"])
        let nativeTools = (try request(MCPServer(reader: fake, writer: fake, allowNative: true), method: "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(nativeTools.count, 78)
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "checklist_add" })
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "move_folder" })
        for name in ["attach_pasteboard", "add_url", "smart_folder_create", "smart_folder_rename", "smart_folder_delete"] {
            XCTAssertTrue(nativeTools.contains { $0["name"] as? String == name }, name)
        }
        let create = try XCTUnwrap(nativeTools.first { $0["name"] as? String == "create_note" })
        let createProperties = ((create["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(createProperties?["attachments"])
        XCTAssertNotNil(createProperties?["wait_sync"])
        XCTAssertNotNil(createProperties?["allow_shared"])
        XCTAssertEqual(try fake.notes(NoteQuery()).count, 2)
    }
    func testAttachmentsAndNativeMarkdownRouteThroughNativeHandler() throws {
        let fake = InMemoryNotes.sample()
        var calls: [(String, [String: Any])] = []
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { tool, arguments in
            calls.append((tool, arguments))
            return try MCPNativeResult(result: WriteResult(outcome: .verified, noteID: NoteID(uuid: arguments["ref"] as? String ?? "created")),
                                       operationID: "native-operation", value: ["ok": true])
        })
        _ = try call(server, "create_note", ["title": "With file", "body": "Body", "folder": "Notes", "attachments": ["/tmp/file"]])
        _ = try call(server, "update_note", ["ref": "Welcome", "body": "Changed"])
        XCTAssertEqual(calls.map(\.0), ["create_note", "update_note"])
        XCTAssertEqual(calls[1].1["ref"] as? String, "welcome")
    }
    func testSharedGuardAndSyncTimeout() throws {
        let sample = InMemoryNotes.sample()
        var note = try sample.note("welcome")
        note.summary.isShared = true
        let fake = InMemoryNotes(accounts: try sample.accounts(), folders: try sample.folders(account: nil), notes: [note])
        var calls = 0
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { _, arguments in
            calls += 1
            return try MCPNativeResult(result: WriteResult(outcome: .verified, noteID: NoteID(uuid: arguments["ref"] as! String)),
                                       operationID: "shared-native", value: ["ok": true])
        }, syncWaiter: { _, _, _ in false })
        let refused = try structured(call(server, "update_note", ["ref": "welcome", "body": "Changed"]))
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "shared_write_refused")
        XCTAssertEqual(calls, 0)
        let written = try structured(call(server, "update_note", ["ref": "welcome", "body": "Changed", "allow_shared": true,
                                                                   "wait_sync": true, "sync_timeout": 0]))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual((written["result"] as? [String: Any])?["syncPending"] as? Bool, true)
        XCTAssertEqual(written["operationID"] as? String, "shared-native")
    }
    func testNativeWriteUsesStableIdentityAndSurfacesOperationID() throws {
        let fake = InMemoryNotes.sample()
        var dispatchedRef: String?
        var dispatchedParent: String?
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { tool, arguments in
            dispatchedRef = arguments["ref"] as? String
            dispatchedParent = arguments["parent"] as? String
            if tool == "move_folder" {
                return try MCPNativeResult(result: WriteResult(outcome: .verified, folderID: dispatchedRef),
                                           operationID: "operation-folder", value: ["ok": true])
            }
            return try MCPNativeResult(result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "welcome")),
                                       operationID: "operation-123", value: ["ok": true])
        })
        let result = try structured(call(server, "pin_note", ["ref": "Welcome"]))
        XCTAssertEqual(dispatchedRef, "welcome")
        XCTAssertEqual(result["engine"] as? String, "native")
        XCTAssertEqual(result["operationID"] as? String, "operation-123")

        _ = try fake.createFolder(name: "Target", parent: nil, account: nil)
        let folders = try fake.folders(account: nil)
        let source = try XCTUnwrap(folders.first { $0.name == "Notes" })
        let target = try XCTUnwrap(folders.first { $0.name == "Target" })
        let moved = try structured(call(server, "move_folder", ["ref": "Notes", "parent": "Target"]))
        XCTAssertEqual(dispatchedRef, source.id)
        XCTAssertEqual(dispatchedParent, target.id)
        XCTAssertEqual(moved["engine"] as? String, "native")
        XCTAssertEqual(moved["operationID"] as? String, "operation-folder")

        let unknown = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { _, _ in
            try MCPNativeResult(result: WriteResult(outcome: .unknown, noteID: NoteID(uuid: "welcome")),
                                operationID: "operation-unknown", value: ["ok": false])
        })
        let unknownResult = try call(unknown, "pin_note", ["ref": "welcome"])
        XCTAssertEqual(unknownResult["isError"] as? Bool, true)
        XCTAssertEqual(try structured(unknownResult)["operationID"] as? String, "operation-unknown")
    }
    func testReadAndPaging() throws {
        let server = MCPServer(reader: InMemoryNotes.sample())
        let first = try structured(call(server, "list_notes", ["limit": 1]))
        XCTAssertEqual((first["notes"] as? [Any])?.count, 1)
        XCTAssertEqual(first["next_offset"] as? Int, 1)
        let second = try structured(call(server, "list_notes", ["limit": 1, "offset": 1]))
        XCTAssertNil(second["next_offset"])
        let search = try structured(call(server, "search_notes", ["query": "coffee"]))
        XCTAssertEqual((search["notes"] as? [Any])?.count, 1)
        for format in ["markdown", "text", "html", "json"] {
            let note = try structured(call(server, "get_note", ["ref": "welcome", "format": format]))
            XCTAssertNotNil(note[format == "json" ? "note" : "body"])
        }
        XCTAssertNotNil(try structured(call(server, "list_accounts"))["accounts"])
        XCTAssertNotNil(try structured(call(server, "list_folders"))["folders"])
        XCTAssertNotNil(try structured(call(server, "list_tags"))["tags"])
        XCTAssertEqual((try structured(call(server, "get_notes", ["refs": ["welcome", "shopping"]]))["notes"] as? [Any])?.count, 2)
        let resources = try request(server, method: "resources/list")["result"] as! [String: Any]
        XCTAssertEqual((resources["resources"] as? [Any])?.count, 1)
        XCTAssertNotNil(try request(server, method: "resources/read", params: ["uri": "notes://note/welcome"])["result"])
        XCTAssertEqual(((try request(server, method: "prompts/list")["result"] as! [String: Any])["prompts"] as? [Any])?.count, 2)
    }
    func testWriteDryRunAndLifecycle() throws {
        let fake = InMemoryNotes.sample(), server = MCPServer(reader: InMemoryNotes.sample())
        let dry = try structured(call(server, "create_note", ["title": "Draft", "body": "Body", "dry_run": true]))
        XCTAssertEqual(dry["dry_run"] as? Bool, true)
        XCTAssertEqual(try server.reader.notes(NoteQuery()).count, 2)
        let export = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-mcp-dry-run-" + UUID().uuidString)
        let dryExport = try structured(call(server, "export_notes", ["output": export.path, "dry_run": true]))
        XCTAssertEqual(dryExport["engine"] as? String, "filesystem")
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        let writable = MCPServer(reader: fake, writer: fake)
        let created = try structured(call(writable, "create_note", ["title": "Draft", "body": "Body"]))
        XCTAssertEqual((created["result"] as? [String: Any])?["outcome"] as? String, "verified")
        _ = try call(writable, "append_to_note", ["ref": "Draft", "body": "More"])
        XCTAssertEqual(try fake.note("Draft").document?.text, "Body\nMore")
        _ = try call(writable, "update_note", ["ref": "Draft", "body": "Replaced"])
        _ = try call(writable, "rename_note", ["ref": "Draft", "title": "Renamed"])
        _ = try call(writable, "create_folder", ["name": "Work"])
        _ = try call(writable, "move_note", ["ref": "Renamed", "folder": "Work"])
        _ = try call(writable, "rename_folder", ["ref": "Work", "name": "New work"])
        XCTAssertEqual(try fake.note("Renamed").summary.folderPath, ["New work"])
        _ = try call(writable, "delete_note", ["ref": "Renamed"])
        _ = try call(writable, "delete_folder", ["ref": "New work"])
        XCTAssertTrue(try fake.note("Renamed").summary.isDeleted)
    }
    func testExportAndSingleFileTools() throws {
        let fake = InMemoryNotes.sample(), server = MCPServer(reader: fake, writer: fake)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-mcp-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let exported = try structured(call(server, "export_notes", ["output": root.appendingPathComponent("epub").path, "format": "epub"]))
        let report = try XCTUnwrap(exported["report"] as? [String: Any])
        XCTAssertEqual((report["files"] as? [String])?.count, 1)

        let path = root.appendingPathComponent("welcome.md")
        let pulled = try structured(call(server, "file_pull", ["ref": "welcome", "path": path.path]))
        XCTAssertEqual((pulled["report"] as? [String: Any])?["action"] as? String, "pull")
        let diff = try structured(call(server, "file_diff", ["path": path.path]))
        XCTAssertEqual((diff["report"] as? [String: Any])?["action"] as? String, "unchanged")
        let dryPush = try structured(call(server, "file_push", ["path": path.path, "dry_run": true]))
        XCTAssertEqual(dryPush["dry_run"] as? Bool, true)
    }
    func testInvalidArgumentsAndToolErrors() throws {
        let server = MCPServer(reader: InMemoryNotes.sample())
        for arguments: [String: Any] in [["limit": -1], ["limit": true], ["limit": "3"], ["unknown": "x"]] {
            XCTAssertNotNil(try request(server, method: "tools/call", params: ["name": "list_notes", "arguments": arguments])["error"])
        }
        let missing = try call(server, "get_note", ["ref": "missing"])
        XCTAssertEqual(missing["isError"] as? Bool, true)
        XCTAssertEqual((try structured(missing)["error"] as? [String: Any])?["code"] as? String, "note_not_found")
    }
    func testTruncationPreservesStructuredContentAndUTF8() throws {
        let fake = InMemoryNotes.sample()
        _ = try fake.createNote(title: "Large", markdown: String(repeating: "📝", count: 20_000), folder: nil)
        let server = MCPServer(reader: fake)
        let result = try call(server, "get_note", ["ref": "Large"])
        let content = result["content"] as! [[String: Any]]
        XCTAssertLessThanOrEqual((content[0]["text"] as! String).utf8.count, MCPServer.textLimit)
        XCTAssertFalse((content[0]["text"] as! String).contains("�"))
        let structured = try structured(result)
        XCTAssertEqual(structured["truncated"] as? Bool, true)
        XCTAssertLessThan((structured["body"] as? String)?.count ?? 0, 20_000)
        let next = try XCTUnwrap(structured["next_offset"] as? Int)
        let continuation = try self.structured(call(server, "get_note", ["ref": "Large", "offset": next]))
        XCTAssertFalse((continuation["body"] as? String)?.isEmpty ?? true)
        for i in 0..<100 { _ = try fake.createNote(title: "Long \(i) " + String(repeating: "x", count: 1000), markdown: "Body", folder: nil) }
        let page = try self.structured(call(server, "list_notes", ["limit": 1000]))
        XCTAssertLessThan((page["notes"] as! [Any]).count, 103)
        XCTAssertNotNil(page["next_offset"])
    }
    func testDates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertLessThan(try NotePresentation.date("7d", now: now), now)
        XCTAssertEqual(try NotePresentation.date("today", now: now), Calendar.current.startOfDay(for: now))
        XCTAssertLessThan(try NotePresentation.date("yesterday", now: now), try NotePresentation.date("today", now: now))
        for input in ["2026-11-11", "2026-11-11T12:00:00Z", "2026-11-11T12:00:00.123Z"] { XCTAssertNoThrow(try NotePresentation.date(input)) }
        XCTAssertThrowsError(try NotePresentation.date("2026-99-99"))
    }

    func testWritesUseAllowlistJournalAndSnapshots() throws {
        let fake = InMemoryNotes.sample()
        let denied = MCPServer(reader: fake, writer: fake, writeFolders: "Personal")
        let deniedResult = try call(denied, "update_note", ["ref": "welcome", "body": "changed"])
        XCTAssertEqual((try structured(deniedResult)["error"] as? [String: Any])?["code"] as? String, "write_not_allowed")
        let deniedDryRun = try call(denied, "update_note", ["ref": "welcome", "body": "changed", "dry_run": true])
        XCTAssertEqual((try structured(deniedDryRun)["error"] as? [String: Any])?["code"] as? String, "write_not_allowed")
        XCTAssertNotEqual(try fake.note("welcome").document?.text, "changed")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-mcp-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MCPServer(reader: fake, writer: fake, writeFolders: "Notes", stateRoot: root)
        _ = try call(server, "update_note", ["ref": "welcome", "body": "changed", "idempotency_key": "mcp-test"])
        XCTAssertEqual(try fake.note("welcome").document?.text, "changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("journal.sqlite").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("snapshots/welcome"), includingPropertiesForKeys: nil).isEmpty)
        let replay = try structured(call(server, "update_note", ["ref": "welcome", "body": "changed", "idempotency_key": "mcp-test"]))
        XCTAssertEqual(replay["replayed"] as? Bool, true)

        let batch = try structured(call(server, "batch_move_notes", ["refs": ["welcome", "shopping"], "folder": "Notes", "idempotency_key": "batch-test"]))
        let items = try XCTUnwrap(batch["results"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0["error"] == nil })
    }
}
