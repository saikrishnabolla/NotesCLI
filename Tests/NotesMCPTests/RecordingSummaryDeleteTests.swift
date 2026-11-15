import Foundation
import NotesCore
import NotesSafety
import XCTest
@testable import NotesMCP

final class RecordingSummaryDeleteTests: XCTestCase {
    private func request(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": method, "params": params]))
    }

    private func tools(_ server: MCPServer) throws -> [[String: Any]] {
        let result = try XCTUnwrap(try request(server, "tools/list")["result"] as? [String: Any])
        return try XCTUnwrap(result["tools"] as? [[String: Any]])
    }

    private func call(_ server: MCPServer, _ arguments: [String: Any]) throws -> [String: Any] {
        let result = try request(server, "tools/call", [
            "name": "recording_summary_clear",
            "arguments": arguments,
        ])
        return try XCTUnwrap(result["result"] as? [String: Any])
    }

    func testToolSchemaAndReadOnlyExposure() throws {
        let writable = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true)
        let tool = try XCTUnwrap(try tools(writable).first { $0["name"] as? String == "recording_summary_clear" })
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["ref", "attachment_id"])
        XCTAssertEqual((tool["annotations"] as? [String: Any])?["destructiveHint"] as? Bool, true)

        let readOnly = MCPServer(reader: InMemoryNotes.sample(), readOnly: true, allowNative: true)
        XCTAssertFalse(try tools(readOnly).contains { $0["name"] as? String == "recording_summary_clear" })
    }

    func testToolResolvesStableRefAndRecordsSnapshotJournal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-recording-summary-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var dispatched: [String: Any] = [:]
        let server = MCPServer(
            reader: InMemoryNotes.sample(),
            writer: InMemoryNotes.sample(),
            allowNative: true,
            nativeHandler: { tool, arguments in
                XCTAssertEqual(tool, "recording_summary_clear")
                dispatched = arguments
                return try MCPNativeResult(
                    result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "welcome")),
                    value: ["attachmentID": "recording-1"]
                )
            },
            stateRoot: root
        )

        let response = try call(server, [
            "ref": "title:Welcome",
            "attachment_id": "recording-1",
        ])

        XCTAssertEqual(dispatched["ref"] as? String, "welcome")
        XCTAssertEqual(dispatched["attachment_id"] as? String, "recording-1")
        let structured = try XCTUnwrap(response["structuredContent"] as? [String: Any])
        XCTAssertNotNil(structured["journalID"])
        let entry = try XCTUnwrap(WriteJournal(url: root.appendingPathComponent("journal.sqlite")).list(limit: 1).first)
        let recorded = try XCTUnwrap(try JSONSerialization.jsonObject(with: entry.arguments) as? [String: Any])
        XCTAssertEqual(recorded["stable_id"] as? String, "welcome")
        XCTAssertNotNil(recorded["snapshot_id"])
    }

    func testToolRejectsScriptingBeforeNativeDispatch() throws {
        var calls = 0
        let server = MCPServer(
            reader: InMemoryNotes.sample(),
            writer: InMemoryNotes.sample(),
            allowNative: true,
            nativeHandler: { _, _ in
                calls += 1
                return try MCPNativeResult(value: [:] as [String: String])
            }
        )

        let response = try call(server, [
            "ref": "welcome",
            "attachment_id": "recording-1",
            "engine": "scripting",
        ])
        let structured = try XCTUnwrap(response["structuredContent"] as? [String: Any])
        XCTAssertEqual((structured["error"] as? [String: Any])?["code"] as? String, "native_required")
        XCTAssertEqual(calls, 0)
    }
}
