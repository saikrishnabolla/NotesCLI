import Foundation
import NotesCore
import NotesNative
import XCTest
@testable import NotesMCP

final class CameraAndScanEditingToolTests: XCTestCase {
    private func request(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": method, "params": params]))
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(try request(server, "tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any])
    }

    private func structured(_ result: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }

    func testCameraToolsAreLocalWritableOnly() throws {
        let writable = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true)
        let tools = try XCTUnwrap((try request(writable, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for name in ["camera_devices", "camera_photo", "camera_scan", "scan_reorder", "scan_replace", "scan_correct"] {
            XCTAssertTrue(tools.contains { $0["name"] as? String == name }, name)
        }
        let readOnly = MCPServer(reader: InMemoryNotes.sample(), readOnly: true, allowNative: true)
        let readOnlyTools = try XCTUnwrap((try request(readOnly, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for name in ["camera_devices", "camera_photo", "camera_scan"] {
            XCTAssertFalse(readOnlyTools.contains { $0["name"] as? String == name }, name)
        }
    }

    func testRemoteProfileHidesAndRefusesLocalResourceTools() throws {
        var nativeCalls = 0
        let remote = MCPServer(
            reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true,
            nativeHandler: { _, _ in
                nativeCalls += 1
                return try MCPNativeResult(value: ["unexpected": true])
            }, exposureProfile: .remote
        )
        let tools = try XCTUnwrap((try request(remote, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        let denied = [
            "camera_devices", "camera_photo", "camera_scan", "doctor",
            "attachment_markup_export", "attachment_markup_render", "attachment_markup_set",
        ]
        XCTAssertTrue(Set(denied).isDisjoint(with: names))

        for name in denied {
            let response = try structured(call(remote, name, [:]))
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String,
                           "remote_local_resource_denied", name)
        }
        XCTAssertEqual(nativeCalls, 0)
    }

    func testCameraPhotoDispatchesBoundedCaptureOptions() throws {
        var dispatched: [String: Any] = [:]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-camera-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true,
                               nativeHandler: { tool, arguments in
            XCTAssertEqual(tool, "camera_photo")
            dispatched = arguments
            return try MCPNativeResult(
                result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "welcome")),
                value: ["attachmentIDs": ["image-1"]]
            )
        }, stateRoot: root)

        _ = try call(server, "camera_photo", ["ref": "title:Welcome", "device": "camera-id", "delay": 2.5, "count": 1])

        XCTAssertEqual(dispatched["ref"] as? String, "welcome")
        XCTAssertEqual(dispatched["device"] as? String, "camera-id")
        XCTAssertEqual((dispatched["delay"] as? NSNumber)?.doubleValue, 2.5)
        XCTAssertEqual((dispatched["count"] as? NSNumber)?.intValue, 1)
    }

    func testScanReorderCapturesPreimageAndDispatchesExpectedOrder() throws {
        var reorder: [String: Any] = [:]
        let state = NativeScanPageState(noteID: "welcome", attachmentID: "gallery", pageID: "p1",
                                        pageIDs: ["p1", "p2"], filter: .photo, orientation: .upright,
                                        crop: nil, hasMarkup: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-reorder-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true,
                               nativeHandler: { tool, arguments in
            if tool == "scan_page_state" { return try MCPNativeResult(value: state) }
            XCTAssertEqual(tool, "scan_reorder")
            reorder = arguments
            return try MCPNativeResult(result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "welcome")),
                                       value: ["pageOrder": "p2,p1"])
        }, stateRoot: root)

        _ = try call(server, "scan_reorder", ["ref": "welcome", "attachment_id": "gallery",
                                               "page_id": "p1", "page_ids": ["p2", "p1"]])

        XCTAssertEqual(reorder["expected_page_ids"] as? [String], ["p1", "p2"])
        XCTAssertEqual(reorder["page_ids"] as? [String], ["p2", "p1"])
    }
}
