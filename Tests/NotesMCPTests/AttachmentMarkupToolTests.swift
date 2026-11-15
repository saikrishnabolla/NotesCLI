import Foundation
import NotesCore
import NotesNative
import NotesSafety
import XCTest
@testable import NotesMCP

final class AttachmentMarkupToolTests: XCTestCase {
    private func request(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": method, "params": params]))
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(try request(server, "tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any])
    }

    private func structured(_ result: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }

    private func knownMarkup() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "$archiver": "NSKeyedArchiver",
            "$version": 100_000,
            "$top": ["AKComprArchiveRoot": 1],
            "$objects": ["$null", "AKComprSizeKey", "AKComprDataKey", 10, Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 1])],
        ], format: .binary, options: 0)
    }

    func testMarkupToolSchemasAndReadOnlyExposure() throws {
        let names = ["attachment_markup_inspect", "attachment_markup_export", "attachment_markup_set", "attachment_markup_copy", "attachment_markup_clear"]
        let writable = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true)
        let tools = try XCTUnwrap((try request(writable, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for name in names { XCTAssertTrue(tools.contains { $0["name"] as? String == name }, name) }
        let set = try XCTUnwrap(tools.first { $0["name"] as? String == "attachment_markup_set" })
        let setSchema = try XCTUnwrap(set["inputSchema"] as? [String: Any])
        XCTAssertEqual(setSchema["required"] as? [String], ["ref", "attachment_id", "path"])
        let copy = try XCTUnwrap(tools.first { $0["name"] as? String == "attachment_markup_copy" })
        XCTAssertEqual((copy["inputSchema"] as? [String: Any])?["required"] as? [String],
                       ["ref", "attachment_id", "source_ref", "source_attachment_id"])

        let readOnly = MCPServer(reader: InMemoryNotes.sample(), readOnly: true, allowNative: true)
        let readOnlyTools = try XCTUnwrap((try request(readOnly, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertTrue(readOnlyTools.contains { $0["name"] as? String == "attachment_markup_inspect" })
        for name in names.dropFirst() { XCTAssertFalse(readOnlyTools.contains { $0["name"] as? String == name }, name) }

        let remote = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true, exposureProfile: .remote)
        let remoteTools = try XCTUnwrap((try request(remote, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertFalse(remoteTools.contains { $0["name"] as? String == "attachment_markup_export" })
        XCTAssertFalse(remoteTools.contains { $0["name"] as? String == "attachment_markup_set" })
        XCTAssertTrue(remoteTools.contains { $0["name"] as? String == "attachment_markup_copy" })
    }

    func testMarkupSetFreezesAndSanitizesFileBeforeDispatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-markup-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("markup.data")
        let payload = try knownMarkup()
        try payload.write(to: file)
        var dispatched: [String: Any] = [:]
        let server = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true,
                               nativeHandler: { tool, arguments in
            XCTAssertEqual(tool, "attachment_markup_set")
            dispatched = arguments
            let result = WriteResult(outcome: .verified, noteID: NoteID(uuid: "welcome"))
            return try MCPNativeResult(result: result, value: ["attachmentID": "image-1"])
        }, stateRoot: root)

        let response = try structured(call(server, "attachment_markup_set", [
            "ref": "welcome", "attachment_id": "image-1", "path": file.path, "embedded": true,
        ]))

        XCTAssertEqual(dispatched["ref"] as? String, "welcome")
        XCTAssertEqual(dispatched["attachment_id"] as? String, "image-1")
        XCTAssertEqual(dispatched["embedded"] as? Bool, true)
        XCTAssertEqual(dispatched["_markup_data"] as? Data, payload)
        XCTAssertNil(dispatched["path"])
        XCTAssertNotNil(response["journalID"])
        let entry = try XCTUnwrap(WriteJournal(url: root.appendingPathComponent("journal.sqlite")).list(limit: 1).first)
        let arguments = try XCTUnwrap(try JSONSerialization.jsonObject(with: entry.arguments) as? [String: Any])
        XCTAssertNil(arguments["path"])
        XCTAssertEqual(arguments["markup_bytes"] as? Int, payload.count)
        XCTAssertEqual(arguments["markup_sha256"] as? String, FrozenAttachmentInput.hash(payload))
    }

    func testMarkupSetRejectsUnknownPayloadAndScriptingBeforeNativeDispatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-markup-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("unknown.data")
        try Data("unknown".utf8).write(to: file)
        var calls = 0
        let server = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true,
                               nativeHandler: { _, _ in calls += 1; return try MCPNativeResult(value: [:] as [String: String]) },
                               stateRoot: root)

        let unknown = try structured(call(server, "attachment_markup_set", [
            "ref": "welcome", "attachment_id": "image-1", "path": file.path,
        ]))
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? String, "unknown_attachment_markup")
        let scripting = try structured(call(server, "attachment_markup_clear", [
            "ref": "welcome", "attachment_id": "image-1", "engine": "scripting",
        ]))
        XCTAssertEqual((scripting["error"] as? [String: Any])?["code"] as? String, "native_required")
        XCTAssertEqual(calls, 0)
    }

    func testMarkupCopyResolvesBothNoteReferencesBeforeDispatch() throws {
        var dispatched: [String: Any] = [:]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-markup-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true,
                               nativeHandler: { tool, arguments in
            XCTAssertEqual(tool, "attachment_markup_copy")
            dispatched = arguments
            return try MCPNativeResult(result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "welcome")), value: [:] as [String: String])
        }, stateRoot: root)

        _ = try call(server, "attachment_markup_copy", [
            "ref": "title:Welcome", "attachment_id": "image-1",
            "source_ref": "title:Shopping", "source_attachment_id": "image-2",
        ])

        XCTAssertEqual(dispatched["ref"] as? String, "welcome")
        XCTAssertEqual(dispatched["source_ref"] as? String, "shopping")
    }
}
