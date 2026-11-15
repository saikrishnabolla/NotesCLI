import Foundation
import NotesCore
import NotesNative
import NotesSafety
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
                "title": "Report", "body": "Body", "tags": ["research"], "replace": false,
            ]],
        ])?["result"] as? [String: Any])
        XCTAssertEqual(response["isError"] as? Bool, false)
        XCTAssertEqual(dispatched["title"] as? String, "Report")
        XCTAssertEqual(dispatched["body"] as? String, "Body")
        XCTAssertEqual(dispatched["replace"] as? Bool, false)
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

    func testReplaceInDefaultFolderHonorsAllowlistAndSnapshotsOldReport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-report-replace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = reportReader(shared: false)
        var dispatched: [String: Any] = [:]
        let server = MCPServer(
            reader: reader, writer: reader, allowNative: true,
            nativeHandler: { _, arguments in
                dispatched = arguments
                return try MCPNativeResult(
                    result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "new-report")),
                    value: StubReport(noteID: "new-report", degraded: [])
                )
            }, writeFolders: "Notes", stateRoot: root
        )

        let response = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "create_report", "arguments": [
                "title": "Report", "body": "Body", "replace": true,
            ]],
        ])?["result"] as? [String: Any])

        XCTAssertNotEqual(response["isError"] as? Bool, true, "\(response)")
        XCTAssertEqual(dispatched["folder"] as? String, "fake-folder")
        XCTAssertEqual(
            try SnapshotStore(rootURL: root.appendingPathComponent("snapshots")).history("old-report").count,
            1
        )
    }

    func testReplaceAppliesSharedNoteGuardBeforeNativeDispatch() throws {
        let reader = reportReader(shared: true)
        var dispatched = false
        let server = MCPServer(
            reader: reader, writer: reader, allowNative: true,
            nativeHandler: { _, _ in
                dispatched = true
                return try MCPNativeResult(
                    result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "new-report")),
                    value: StubReport(noteID: "new-report", degraded: [])
                )
            }, writeFolders: "Notes"
        )

        let response = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "create_report", "arguments": [
                "title": "Report", "body": "Body", "replace": true,
            ]],
        ])?["result"] as? [String: Any])

        XCTAssertEqual(response["isError"] as? Bool, true)
        let structured = response["structuredContent"] as? [String: Any]
        XCTAssertEqual((structured?["error"] as? [String: Any])?["code"] as? String, "shared_write_refused")
        XCTAssertFalse(dispatched)
    }
}

private struct StubReport: Encodable { var noteID: String; var degraded: [String] }

private func reportReader(shared: Bool) -> InMemoryNotes {
    let account = Account(id: "fake-account", name: "Demo", kind: "local", isDefault: true,
                          defaultFolderID: "fake-folder", defaultFolderName: "Notes")
    let folder = Folder(id: "fake-folder", name: "Notes", accountID: account.id, parentID: nil,
                        path: ["Notes"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 1)
    let note = Note(summary: NoteSummary(
        id: NoteID(uuid: "old-report"), title: "Report", snippet: "Old body",
        folderID: folder.id, folderPath: folder.path, accountID: account.id,
        created: nil, modified: nil, isPinned: false, isLocked: false, isDeleted: false,
        hasChecklist: false, attachmentCount: 0, tags: [], isShared: shared
    ), document: NoteDocument(text: "Old body", runs: []), attachments: [])
    return InMemoryNotes(accounts: [account], folders: [folder], notes: [note])
}
