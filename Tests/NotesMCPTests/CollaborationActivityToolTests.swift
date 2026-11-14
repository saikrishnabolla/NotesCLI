import XCTest
import NotesCore
@testable import NotesMCP

final class CollaborationActivityToolTests: XCTestCase {
    private func request(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": method, "params": params]))
    }

    func testToolIsReadOnlyNativeAndForwardsArguments() throws {
        let fake = InMemoryNotes.sample()
        var received: (String, [String: Any])?
        let server = MCPServer(reader: fake, allowNative: true, nativeHandler: { tool, arguments in
            received = (tool, arguments)
            return try MCPNativeResult(value: ["status": "absent", "noteID": "N1"])
        })
        let tools = (try request(server, "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
        let tool = try XCTUnwrap(tools.first { $0["name"] as? String == "collaboration_activity" })
        XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["ref"])
        let limit = try XCTUnwrap((schema["properties"] as? [String: Any])?["limit"] as? [String: Any])
        XCTAssertEqual(limit["maximum"] as? Int, 500)

        let response = try request(server, "tools/call", ["name": "collaboration_activity", "arguments": ["ref": "welcome", "limit": 5]])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let value = try XCTUnwrap((result["structuredContent"] as? [String: Any])?["value"] as? [String: Any])
        XCTAssertEqual(value["status"] as? String, "absent")
        XCTAssertEqual(received?.0, "collaboration_activity")
        XCTAssertEqual(received?.1["ref"] as? String, "welcome")
        XCTAssertEqual(received?.1["limit"] as? Int, 5)

        let readOnly = MCPServer(reader: fake, readOnly: true, allowNative: true, nativeHandler: { _, _ in try MCPNativeResult(value: [String: String]()) })
        let readOnlyTools = (try request(readOnly, "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertTrue(readOnlyTools.contains { $0["name"] as? String == "collaboration_activity" })
    }
}
