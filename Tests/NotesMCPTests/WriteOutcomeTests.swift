import XCTest
import NotesCore
import NotesMCP

private struct UnknownWriter: NotesWriting {
    private var result: WriteResult { WriteResult(outcome: .unknown, message: "Synthetic timeout; do not retry.") }
    func createNote(title: String, markdown: String, folder: String?) throws -> WriteResult { result }
    func appendToNote(_ ref: String, markdown: String) throws -> WriteResult { result }
    func replaceBody(_ ref: String, markdown: String) throws -> WriteResult { result }
    func renameNote(_ ref: String, title: String) throws -> WriteResult { result }
    func moveNote(_ ref: String, toFolder: String) throws -> WriteResult { result }
    func deleteNote(_ ref: String) throws -> WriteResult { result }
    func createFolder(name: String, parent: String?, account: String?) throws -> WriteResult { result }
    func renameFolder(_ ref: String, name: String) throws -> WriteResult { result }
    func deleteFolder(_ ref: String) throws -> WriteResult { result }
}
final class WriteOutcomeTests: XCTestCase {
    func testUnknownOutcomeIsAnExplicitToolFailure() throws {
        let server = MCPServer(reader: InMemoryNotes.sample(), writer: UnknownWriter())
        let response = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "create_note", "arguments": ["title": "Synthetic", "body": "Body"]]])!
        let result = response["result"] as! [String: Any]
        XCTAssertEqual(result["isError"] as? Bool, true)
        let structured = result["structuredContent"] as! [String: Any]
        XCTAssertEqual((structured["result"] as? [String: Any])?["outcome"] as? String, "unknown")
    }
}
