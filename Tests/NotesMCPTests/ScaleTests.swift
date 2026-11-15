import Foundation
import NotesCore
@testable import NotesMCP
import XCTest

final class ScaleTests: XCTestCase {
    func testFiveThousandNotesRemainCountableSearchableAndPageable() throws {
        let account = Account(id: "scale-account", name: "Scale", kind: "local", isDefault: true,
                              defaultFolderID: "scale-folder", defaultFolderName: "Notes")
        let folder = Folder(id: "scale-folder", name: "Notes", accountID: account.id, parentID: nil,
                            path: ["Notes"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 5_000)
        let notes = (0..<5_000).map { index in
            let token = index.isMultiple(of: 13) ? " parity-target" : ""
            let body = "Body \(index)\(token)"
            return Note(
                summary: NoteSummary(
                    id: NoteID(uuid: String(format: "scale-%05d", index), shortID: "n\(index + 1)"),
                    title: String(format: "Note %05d", index), snippet: body,
                    folderID: folder.id, folderPath: folder.path, accountID: account.id,
                    created: Date(timeIntervalSince1970: TimeInterval(index)),
                    modified: Date(timeIntervalSince1970: TimeInterval(index)),
                    isPinned: false, isLocked: false, isDeleted: false, hasChecklist: false,
                    attachmentCount: 0, tags: index.isMultiple(of: 13) ? ["target"] : []
                ),
                document: NoteDocument(text: body, runs: []), attachments: []
            )
        }
        let server = MCPServer(reader: InMemoryNotes(accounts: [account], folders: [folder], notes: notes))

        let start = ContinuousClock.now
        XCTAssertEqual(try value(try call(server, "count_notes"))["count"] as? Int, 5_000)
        XCTAssertEqual(try value(try call(server, "get_stats"))["total"] as? Int, 5_000)

        var cursor: String?
        var found = Set<String>()
        repeat {
            var arguments: [String: Any] = ["query": "parity-target", "limit": 100]
            if let cursor { arguments["cursor"] = cursor }
            let page = try value(try call(server, "search_notes", arguments))
            let rows = try XCTUnwrap(page["notes"] as? [[String: Any]])
            for row in rows {
                let id = try XCTUnwrap((row["id"] as? [String: Any])?["uuid"] as? String)
                XCTAssertTrue(found.insert(id).inserted, "Search paging returned \(id) twice.")
            }
            cursor = page["next_cursor"] as? String
        } while cursor != nil

        XCTAssertEqual(found.count, 385)
        XCTAssertLessThan(start.duration(to: .now), .seconds(10))
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ]
        let response = try XCTUnwrap(server.handle(request))
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func value(_ result: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }
}
