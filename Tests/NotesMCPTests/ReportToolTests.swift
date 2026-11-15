import Foundation
import NotesCore
import NotesNative
import XCTest
@testable import NotesMCP

final class ReportToolTests: XCTestCase {
    func testCreateReportSchemaAndNativeDispatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-report-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var dispatched: [String: Any] = [:]
        let server = MCPServer(
            reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true,
            nativeHandler: { tool, arguments in
                XCTAssertEqual(tool, "create_report")
                dispatched = arguments
                return try MCPNativeResult(
                    result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "report-id")),
                    value: StubReport(noteID: "report-id", degraded: [])
                )
            }, stateRoot: root
        )
        let listed = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]
        ])?["result"] as? [String: Any])
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        let report = try XCTUnwrap(tools.first { $0["name"] as? String == "create_report" })
        XCTAssertEqual((report["inputSchema"] as? [String: Any])?["required"] as? [String], ["title"])

        let response = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "create_report", "arguments": [
                "title": "Report", "body": "Body", "tags": ["research"], "replace": true,
            ]],
        ])?["result"] as? [String: Any])
        XCTAssertEqual(response["isError"] as? Bool, false)
        XCTAssertEqual(dispatched["title"] as? String, "Report")
        XCTAssertEqual(dispatched["body"] as? String, "Body")
        XCTAssertEqual(dispatched["replace"] as? Bool, true)
    }

    func testRemoteCreateReportDoesNotExposePaths() throws {
        let server = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(),
                               allowNative: true, exposureProfile: .remote)
        let listed = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]
        ])?["result"] as? [String: Any])
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        let report = try XCTUnwrap(tools.first { $0["name"] as? String == "create_report" })
        let properties = try XCTUnwrap((report["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(properties["body"])
        XCTAssertNil(properties["file"])
        XCTAssertNil(properties["attachments"])
    }
}

private struct StubReport: Encodable { var noteID: String; var degraded: [String] }
