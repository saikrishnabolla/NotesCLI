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
            XCTAssertEqual(tools.count, readOnly ? 6 : 15)
            XCTAssertEqual(tools.contains { $0["name"] as? String == "delete_note" }, !readOnly)
            for tool in tools { XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object") }
            if readOnly {
                let response = try request(server, method: "tools/call", params: ["name": "create_note", "arguments": ["title": "No", "body": "No", "dry_run": true]])
                XCTAssertNotNil(response["error"])
            }
        }
        XCTAssertEqual(try fake.notes(NoteQuery()).count, 2)
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
    }
    func testWriteDryRunAndLifecycle() throws {
        let fake = InMemoryNotes.sample(), server = MCPServer(reader: InMemoryNotes.sample())
        let dry = try structured(call(server, "create_note", ["title": "Draft", "body": "Body", "dry_run": true]))
        XCTAssertEqual(dry["dry_run"] as? Bool, true)
        XCTAssertEqual(try server.reader.notes(NoteQuery()).count, 2)
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
        XCTAssertEqual((structured["body"] as? String)?.count, 20_000)
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
}
