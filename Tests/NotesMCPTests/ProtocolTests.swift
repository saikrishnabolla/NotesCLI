import CryptoKit
import CoreGraphics
import ImageIO
import XCTest
import NotesCore
import NotesNative
import NotesSafety
import UniformTypeIdentifiers
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
    private func imageData(width: Int, height: Int, orientation: UInt32 = 1) throws -> Data {
        var bytes = [UInt8](repeating: 127, count: width * height * 4)
        let image = try XCTUnwrap(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testStdioRunKeepsTheMainQueueAvailableForNativeRequests() throws {
        XCTAssertTrue(Thread.isMainThread)
        let input = Pipe()
        let output = Pipe()
        let server = MCPServer(reader: InMemoryNotes.sample(), allowNative: true, nativeHandler: { _, _ in
            let serviced = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { serviced.signal() }
            return try MCPNativeResult(value: [
                "main_queue_available": serviced.wait(timeout: .now() + 0.2) == .success,
            ])
        })
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "link_list", "arguments": ["ref": "welcome"]],
        ]
        var requestData = try JSONSerialization.data(withJSONObject: request)
        requestData.append(0x0a)
        input.fileHandleForWriting.write(requestData)
        input.fileHandleForWriting.closeFile()

        server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        output.fileHandleForWriting.closeFile()

        let responseData = output.fileHandleForReading.readDataToEndOfFile()
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let value = try XCTUnwrap((try structured(result))["value"] as? [String: Any])
        XCTAssertEqual(value["main_queue_available"] as? Bool, true)
    }
    func testStdioRejectsOversizedLineAndContinuesWithNextRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-stdio-limit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputURL = root.appendingPathComponent("input"), outputURL = root.appendingPathComponent("output")
        var inputData = Data(repeating: 0x61, count: MCPServer.maximumStdioLineBytes + 1)
        inputData.append(Data("\n{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}\n".utf8))
        try inputData.write(to: inputURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let input = try FileHandle(forReadingFrom: inputURL), output = try FileHandle(forWritingTo: outputURL)
        MCPServer(reader: InMemoryNotes.sample()).run(input: input, output: output)
        try input.close(); try output.close()
        let lines = try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let responses = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual((responses[0]["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual((responses[0]["error"] as? [String: Any])?["message"] as? String, "Request exceeds the 4 MiB stdio limit")
        XCTAssertEqual((responses[1]["id"] as? NSNumber)?.intValue, 7)
    }
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
            XCTAssertEqual(tools.count, readOnly ? 31 : 54)
            XCTAssertEqual(tools.contains { $0["name"] as? String == "delete_note" }, !readOnly)
            XCTAssertEqual(tools.contains { $0["name"] as? String == "anchor_add" }, !readOnly)
            XCTAssertEqual(tools.contains { $0["name"] as? String == "anchor_prune" }, !readOnly)
            for tool in tools { XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object") }
            if readOnly {
                let response = try request(server, method: "tools/call", params: ["name": "create_note", "arguments": ["title": "No", "body": "No", "dry_run": true]])
                XCTAssertNotNil(response["error"])
            }
        }
        let names = ((try request(MCPServer(reader: fake, writer: fake), method: "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["list_accounts", "list_folders", "list_notes", "search_notes", "query_notes", "get_note", "history", "diff", "get_notes", "list_tags", "list_attachments", "save_attachment", "list_backlinks", "get_deeplink", "list_smart_folders", "list_deleted", "recent_notes", "today_notes", "pinned_notes", "count_notes", "get_stats", "get_capabilities", "get_raw_note", "related_notes", "get_write_policy", "export_notes", "file_pull", "file_push", "file_diff", "sync_notes", "create_note", "append_to_note", "prepend_to_note", "update_note", "insert_under_heading", "replace_section", "replace_text", "rename_note", "move_note", "delete_note", "batch_move_notes", "batch_delete_notes", "create_folder", "rename_folder", "delete_folder", "write_markdown", "recording_transcript", "index_status", "get_attachment", "anchor_add", "anchor_list", "anchor_resolve", "anchor_prune", "table_get"])
        let defaultTools = (try request(MCPServer(reader: fake, writer: fake), method: "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
        func readOnlyHint(_ name: String) -> Bool? {
            (defaultTools.first { $0["name"] as? String == name }?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool
        }
        XCTAssertEqual(readOnlyHint("anchor_add"), false)
        XCTAssertEqual(readOnlyHint("anchor_prune"), false)
        XCTAssertEqual(readOnlyHint("anchor_list"), true)
        XCTAssertEqual(readOnlyHint("anchor_resolve"), true)
        let nativeTools = (try request(MCPServer(reader: fake, writer: fake, allowNative: true), method: "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(nativeTools.count, 154)
        for name in ["ocr_set", "image_labels_set", "attachment_markup_inspect", "attachment_markup_export",
                     "attachment_markup_set", "attachment_markup_copy", "attachment_markup_clear",
                     "handwriting_recognize", "handwriting_persist", "handwriting_set", "paper_add", "paper_regenerate_fallback"] {
            XCTAssertTrue(nativeTools.contains { $0["name"] as? String == name }, name)
        }
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "undo" })
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "revert" })
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "checklist_add" })
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "move_folder" })
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "recording_add" })
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "recording_create" })
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "recording_transcribe" })
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "recording_transcript" })
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "recording_summary_clear" })
        for name in ["recording_add", "recording_create", "recording_transcribe"] {
            let schema = try XCTUnwrap(nativeTools.first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual((properties["transcript_path"] as? [String: Any])?["type"] as? String, "string")
        }
        for name in ["attach_pasteboard", "add_url", "link_capture", "smart_folder_create", "smart_folder_rename", "smart_folder_edit_rules", "smart_folder_delete",
                     "insert_divider", "insert_math", "evaluate_math", "insert_math_result", "insert_mention", "table_convert_to_text", "checklist_auto_sort"] {
            XCTAssertTrue(nativeTools.contains { $0["name"] as? String == name }, name)
        }
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "table_format_cell" })
        XCTAssertTrue(nativeTools.contains { $0["name"] as? String == "diagram_add" })
        for name in ["smart_folder_edit_typed", "get_folder_sort", "set_folder_sort", "set_default_account",
                     "get_folder_date_grouping", "set_folder_date_grouping", "get_default_paragraph_style",
                     "set_default_paragraph_style", "get_notes_settings", "set_global_note_sort",
                     "set_global_date_grouping", "set_default_text_size", "set_resume_last_quick_note", "set_auto_convert_tags",
                     "create_quick_note", "set_quick_note", "ocr_attachment", "map_add", "scan_add",
                     "scan_page_state", "scan_filter", "scan_rotate", "scan_crop", "scan_move", "scan_delete", "scan_append",
                     "get_note_container_view", "set_query_date_grouping", "set_auto_format_markdown",
                     "set_dark_backgrounds", "set_show_note_count"] {
            XCTAssertTrue(nativeTools.contains { $0["name"] as? String == name }, name)
        }
        let styleTool = try XCTUnwrap(nativeTools.first { $0["name"] as? String == "set_default_paragraph_style" })
        let styleProperties = try XCTUnwrap((styleTool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual((styleProperties["style"] as? [String: Any])?["enum"] as? [String], ["title", "heading", "subheading", "body"])
        let scanCrop = try XCTUnwrap(nativeTools.first { $0["name"] as? String == "scan_crop" })
        let scanCropProperties = try XCTUnwrap((scanCrop["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual((scanCropProperties["detect_edges"] as? [String: Any])?["type"] as? String, "boolean")
        for name in ["bottom_left_x", "bottom_left_y", "bottom_right_x", "bottom_right_y",
                     "top_left_x", "top_left_y", "top_right_x", "top_right_y"] {
            let coordinate = try XCTUnwrap(scanCropProperties[name] as? [String: Any])
            XCTAssertEqual((coordinate["minimum"] as? NSNumber)?.doubleValue, 0)
            XCTAssertEqual((coordinate["maximum"] as? NSNumber)?.doubleValue, 1)
        }
        for name in ["scan_add", "scan_append"] {
            let input = try XCTUnwrap(nativeTools.first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(input["properties"] as? [String: Any])
            XCTAssertEqual((properties["perspective_correct"] as? [String: Any])?["type"] as? String, "boolean")
        }
        for name in ["drawing_add", "drawing_create", "drawing_export"] {
            XCTAssertTrue(nativeTools.contains { $0["name"] as? String == name }, name)
        }
        let drawingAdd = try XCTUnwrap(nativeTools.first { $0["name"] as? String == "drawing_add" })
        let drawingAddSchema = try XCTUnwrap(drawingAdd["inputSchema"] as? [String: Any])
        XCTAssertEqual(drawingAddSchema["required"] as? [String], ["ref", "svg"])
        let drawingProperties = try XCTUnwrap(drawingAddSchema["properties"] as? [String: Any])
        XCTAssertEqual((drawingProperties["ink"] as? [String: Any])?["enum"] as? [String], ["pen", "marker", "pencil", "monoline"])
        XCTAssertEqual((drawingProperties["fit"] as? [String: Any])?["enum"] as? [String], ["contain", "stretch"])
        XCTAssertEqual((drawingProperties["fill"] as? [String: Any])?["enum"] as? [String], ["outline", "hatch"])
        XCTAssertEqual((drawingProperties["legacy"] as? [String: Any])?["type"] as? String, "boolean")
        let create = try XCTUnwrap(nativeTools.first { $0["name"] as? String == "create_note" })
        let createProperties = ((create["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(createProperties?["attachments"])
        XCTAssertNotNil(createProperties?["wait_sync"])
        XCTAssertNotNil(createProperties?["allow_shared"])
        XCTAssertEqual(try fake.notes(NoteQuery()).count, 2)
    }

    func testImageMetadataNativeWritesAreValidatedJournaledAndDispatchedWithStableRefs() throws {
        let fake = InMemoryNotes.sample()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-mcp-image-metadata-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls: [(String, [String: Any])] = []
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { tool, arguments in
            calls.append((tool, arguments))
            return try MCPNativeResult(
                result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "welcome")),
                value: ["attachmentID": arguments["attachment_id"] as? String ?? ""]
            )
        }, stateRoot: root)

        let ocr = try structured(call(server, "ocr_set", [
            "ref": "n1", "attachment_id": "image-1", "text": "Exact OCR",
        ]))
        XCTAssertNil(ocr["error"])
        XCTAssertEqual(calls.last?.0, "ocr_set")
        XCTAssertEqual(calls.last?.1["ref"] as? String, "welcome")
        XCTAssertEqual(calls.last?.1["text"] as? String, "Exact OCR")

        let labels = try structured(call(server, "image_labels_set", [
            "ref": "welcome", "attachment_id": "image-1", "clear": true,
        ]))
        XCTAssertNil(labels["error"])
        XCTAssertEqual(calls.last?.0, "image_labels_set")
        XCTAssertEqual(calls.last?.1["clear"] as? Bool, true)

        let invalid = try structured(call(server, "ocr_set", [
            "ref": "welcome", "attachment_id": "image-1", "text": "x", "clear": true,
        ]))
        XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? String, "invalid_ocr_text")
        XCTAssertEqual(calls.count, 2)

        let journal = try WriteJournal(url: root.appendingPathComponent("journal.sqlite")).list(limit: 10)
        XCTAssertEqual(Set(journal.map(\.operation)), Set(["ocr_set", "image_labels_set"]))
        XCTAssertTrue(journal.allSatisfy { $0.snapshotID != nil })
    }

    func testPinnedNotesAndCapabilities() throws {
        let server = MCPServer(reader: InMemoryNotes.sample())
        let pinned = try structured(call(server, "pinned_notes", ["limit": 1]))
        let notes = try XCTUnwrap(pinned["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0]["title"] as? String, "Welcome")
        XCTAssertEqual(notes[0]["number"] as? Int, 1)

        let capabilities = try structured(call(server, "get_capabilities"))
        XCTAssertEqual(capabilities["macOS"] as? String, ProcessInfo.processInfo.operatingSystemVersionString)
        XCTAssertEqual((capabilities["features"] as? [[String: Any]])?.count, 95)
        let pin = (capabilities["features"] as? [[String: Any]])?.first { $0["feature"] as? String == "Pin and unpin" }
        XCTAssertEqual(pin?["read"] as? String, "Done")
        XCTAssertEqual(pin?["write"] as? String, "Done")
        XCTAssertEqual(pin?["writeEngine"] as? String, "native")
        XCTAssertNotNil(pin?["permissions"])
        XCTAssertNotNil(pin?["nativeSelectors"])
        let diagrams = (capabilities["features"] as? [[String: Any]])?.first { $0["feature"] as? String == "Editorial SVG and HTML diagrams" }
        XCTAssertEqual(diagrams?["readEngine"] as? String, "database")
        XCTAssertEqual(diagrams?["writeEngine"] as? String, "native")
    }

    func testMCPNoteReferencesRejectNumberTitleCollisionsAndAcceptExplicitSyntax() throws {
        let sample = InMemoryNotes.sample()
        let account = try XCTUnwrap(try sample.accounts().first)
        let folder = try XCTUnwrap(try sample.folders(account: nil).first)
        let hashTitled = Note(summary: NoteSummary(
            id: NoteID(uuid: "hash-title", shortID: "n7"), title: "#1", snippet: "", folderID: folder.id,
            folderPath: folder.path, accountID: account.id, created: nil, modified: nil, isPinned: false,
            isLocked: false, isDeleted: false, hasChecklist: false, attachmentCount: 0, tags: []
        ), document: NoteDocument(text: "hash body", runs: []), attachments: [])
        let notes = InMemoryNotes(accounts: [account], folders: [folder], notes: [try sample.note("#1"), hashTitled])
        let server = MCPServer(reader: notes, writer: notes)
        let ambiguous = try call(server, "get_note", ["ref": "#1", "format": "json"])
        XCTAssertEqual(ambiguous["isError"] as? Bool, true)
        XCTAssertEqual((try structured(ambiguous)["error"] as? [String: Any])?["code"] as? String, "ambiguous_reference")
        let deleteAmbiguous = try call(server, "delete_note", ["ref": "#1"])
        XCTAssertEqual((try structured(deleteAmbiguous)["error"] as? [String: Any])?["code"] as? String, "ambiguous_reference")
        XCTAssertEqual(try notes.notes(NoteQuery()).count, 2)
        let titled = try structured(try call(server, "get_note", ["ref": "title:#1", "format": "json"]))
        XCTAssertEqual((titled["summary"] as? [String: Any])?["title"] as? String, "#1")
        let numbered = try structured(try call(server, "get_note", ["ref": "id:1", "format": "json"]))
        XCTAssertEqual((numbered["summary"] as? [String: Any])?["title"] as? String, "Welcome")
    }

    func testCapabilityCatalogMatchesFeatureDocument() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("docs/APPLE-NOTES-FEATURES.md"), encoding: .utf8)
        let documented = text.split(separator: "\n").compactMap { line -> FeatureDefinition? in
            guard line.hasPrefix("| "), !line.hasPrefix("| Feature"), !line.hasPrefix("| ---") else { return nil }
            let columns = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count == 4 else { return nil }
            return FeatureDefinition(feature: columns[0], read: columns[1], write: columns[2])
        }
        XCTAssertEqual(documented.count, 95)
        XCTAssertEqual(CapabilityCatalog.features, documented)
    }

    func testPaperDrawingWriteIsDoneAfterThePencilRoundTrip() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("docs/APPLE-NOTES-FEATURES.md"), encoding: .utf8)
        let row = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("| Modern Paper drawings |") })
        XCTAssertTrue(row.hasPrefix("| Modern Paper drawings | Done | Done |"), String(row))
        XCTAssertTrue(row.contains("edited with Apple Pencil on iPad, synced back, and read with every original and new stroke."), String(row))
        XCTAssertEqual(CapabilityCatalog.features.first { $0.feature == "Modern Paper drawings" },
                       FeatureDefinition(feature: "Modern Paper drawings", read: "Done", write: "Done"))
    }

    func testNativeFormattingSchemasAndValidationRejectInvalidValuesBeforeDispatch() throws {
        let fake = InMemoryNotes.sample()
        var dispatchCount = 0
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { _, _ in
            dispatchCount += 1
            return try MCPNativeResult(result: WriteResult(outcome: .verified), value: ["ok": true])
        })
        let tools = ((try request(server, method: "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]])
        func property(_ tool: String, _ name: String) throws -> [String: Any] {
            let schema = try XCTUnwrap(tools.first { $0["name"] as? String == tool }?["inputSchema"] as? [String: Any])
            return try XCTUnwrap((schema["properties"] as? [String: Any])?[name] as? [String: Any])
        }
        XCTAssertEqual(try property("format_paragraph", "alignment")["enum"] as? [String], ["left", "right", "center", "justified", "natural"])
        XCTAssertEqual(try property("format_paragraph", "writing_direction")["enum"] as? [String], ["natural", "left-to-right", "right-to-left"])
        XCTAssertEqual(try property("format_inline", "highlight")["enum"] as? [String], ["purple", "pink", "orange", "mint", "blue"])
        XCTAssertEqual(try property("table_format_cell", "highlight")["enum"] as? [String], ["purple", "pink", "orange", "mint", "blue"])
        XCTAssertEqual(try property("set_default_text_size", "points")["enum"] as? [Int], [10, 12, 14, 18, 24])
        XCTAssertEqual(try property("set_auto_convert_tags", "enabled")["type"] as? String, "boolean")
        XCTAssertEqual(try property("evaluate_math", "expression")["type"] as? String, "string")
        XCTAssertEqual(try property("insert_math_result", "position")["type"] as? String, "integer")

        let validCrop: [String: Any] = [
            "ref": "welcome", "attachment_id": "gallery", "page_id": "page",
            "bottom_left_x": 0.0, "bottom_left_y": 1.0,
            "bottom_right_x": 1.0, "bottom_right_y": 1.0,
            "top_left_x": 0.0, "top_left_y": 0.0,
            "top_right_x": 1.0, "top_right_y": 0.0,
        ]
        var negativeCrop = validCrop
        negativeCrop["bottom_left_x"] = -0.01
        var oversizedCrop = validCrop
        oversizedCrop["top_right_y"] = 1.01
        let invalid: [(String, [String: Any], String)] = [
            ("format_paragraph", ["ref": "welcome", "start": 0, "length": 1, "style": "body", "alignment": "diagonal"], "Invalid alignment; use left, right, center, justified, or natural."),
            ("format_paragraph", ["ref": "welcome", "start": 0, "length": 1, "style": "body", "writing_direction": "up"], "Invalid writing_direction; use natural, left-to-right, or right-to-left."),
            ("format_inline", ["ref": "welcome", "start": 0, "length": 1, "highlight": "green"], "Invalid highlight; use purple, pink, orange, mint, or blue."),
            ("format_inline", ["ref": "welcome", "start": 0, "length": 1, "superscript": true, "subscript": true], "Choose one of superscript, subscript, or clear_script."),
            ("set_default_text_size", ["points": 13], "Invalid points; use 10, 12, 14, 18, or 24."),
            ("scan_crop", negativeCrop, "bottom_left_x must be at least 0"),
            ("scan_crop", oversizedCrop, "top_right_y must be at most 1"),
            ("scan_crop", ["ref": "welcome", "attachment_id": "gallery", "page_id": "page"], "Provide detect_edges or all eight scan crop coordinates."),
            ("scan_crop", validCrop.merging(["detect_edges": true]) { _, new in new }, "Choose detect_edges or explicit scan crop coordinates, not both.")
        ]
        for (name, arguments, message) in invalid {
            let response = try request(server, method: "tools/call", params: ["name": name, "arguments": arguments])
            XCTAssertEqual((response["error"] as? [String: Any])?["message"] as? String, message)
        }
        XCTAssertEqual(dispatchCount, 0)
    }
    func testScanAddEnforcesTheMCPPayloadLimitBeforeDispatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-scan-limit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = InMemoryNotes.sample()
        var dispatched = 0
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { tool, _ in
            if tool == "scan_add" { dispatched += 1 }
            return try MCPNativeResult(result: WriteResult(outcome: .verified), value: ["ok": true])
        }, stateRoot: root)

        let tools = ((try request(server, method: "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]])
        let scan = try XCTUnwrap(tools.first { $0["name"] as? String == "scan_add" })
        XCTAssertTrue((scan["description"] as? String)?.contains("at most 4,000,000 base64 characters (3,000,000 decoded bytes)") == true)
        let pagesSchema = try XCTUnwrap(((scan["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["pages"] as? [String: Any])
        XCTAssertEqual(pagesSchema["maxItems"] as? Int, 100)
        XCTAssertEqual((pagesSchema["items"] as? [String: Any])?["maxLength"] as? Int, 4_000_000)

        func rejection(_ pages: [String]) throws -> String? {
            let response = try request(server, method: "tools/call",
                                       params: ["name": "scan_add", "arguments": ["ref": "welcome", "pages": pages]])
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? Int, -32602)
            return (error["data"] as? [String: Any])?["code"] as? String
        }
        let overHalf = String(repeating: "A", count: 2_000_004)
        XCTAssertEqual(try rejection([overHalf, overHalf]), "scan_too_large")
        let validData = try imageData(width: 8, height: 6)
        let valid = validData.base64EncodedString()
        XCTAssertEqual(try rejection([valid, "not base64!"]), "invalid_scan_page")
        XCTAssertEqual(try rejection([""]), "invalid_scan_page")
        XCTAssertEqual(dispatched, 0)

        let first = validData, second = try imageData(width: 9, height: 7)
        let pages = [first.base64EncodedString(), second.base64EncodedString()]
        let privatePath = "/Users/reviewer/Private/secret-scan.png"
        let arguments: [String: Any] = ["ref": "welcome", "pages": pages,
                                        "page_names": [privatePath, "two.png"]]
        let wire = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "scan_add", "arguments": arguments],
        ] as [String: Any])
        let defaultHTTPBody = try HTTPMCPServer.Configuration(tokenProvider: { nil }, allowedHosts: ["127.0.0.1"],
                                                              allowedOrigins: []).maximumBodyBytes
        XCTAssertLessThanOrEqual(wire.count, defaultHTTPBody)

        let accepted = try call(server, "scan_add", arguments)
        XCTAssertNotEqual(accepted["isError"] as? Bool, true)
        XCTAssertEqual(dispatched, 1)
        let entry = try XCTUnwrap(WriteJournal(url: root.appendingPathComponent("journal.sqlite")).list(limit: 1).first)
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: entry.arguments) as? [String: Any])
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(recorded["page_sha256"] as? String, sha(first) + "," + sha(second))
        XCTAssertEqual(recorded["source_page_sha256"] as? String, sha(first) + "," + sha(second))
        XCTAssertEqual(recorded["page_count"] as? Int, 2)
        XCTAssertNil(recorded["pages"])
        XCTAssertNil(recorded["page_names"])
        XCTAssertFalse(String(decoding: entry.arguments, as: UTF8.self).contains(privatePath))
    }

    func testScanCorrectionRunsAfterSafetyAndReappliesEncodedAndDecodedPayloadCaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-scan-corrected-limit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = InMemoryNotes.sample()
        var correctionCount = 0
        var dispatchCount = 0
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { tool, arguments in
            if tool == "scan_add" {
                dispatchCount += 1
                XCTAssertEqual(arguments["perspective_correct"] as? Bool, false)
            }
            return try MCPNativeResult(result: WriteResult(outcome: .verified), value: ["ok": true])
        }, stateRoot: root)
        let source = try imageData(width: 8, height: 6).base64EncodedString()
        server.scanPageCorrector = { page in
            correctionCount += 1
            let count = correctionCount == 1 ? 1_499_998 : 1_500_001
            return try FrozenAttachmentInput(data: Data(repeating: UInt8(correctionCount), count: count),
                                             suggestedName: page.sourceName)
        }

        let dryRun = try structured(call(server, "scan_add", [
            "ref": "welcome", "pages": [source], "perspective_correct": true, "dry_run": true,
        ]))
        XCTAssertEqual(dryRun["dry_run"] as? Bool, true)
        XCTAssertEqual(correctionCount, 0)
        XCTAssertEqual(dispatchCount, 0)

        let denied = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { _, _ in
            XCTFail("Denied correction must not dispatch")
            return try MCPNativeResult(result: WriteResult(outcome: .unknown), value: ["ok": false])
        }, writeFolders: "Personal", stateRoot: root.appendingPathComponent("denied"))
        denied.scanPageCorrector = server.scanPageCorrector
        let deniedResult = try structured(call(denied, "scan_add", [
            "ref": "welcome", "pages": [source], "perspective_correct": true,
        ]))
        XCTAssertEqual((deniedResult["error"] as? [String: Any])?["code"] as? String, "write_not_allowed")
        XCTAssertEqual(correctionCount, 0)

        let encodedCapped = try structured(call(server, "scan_add", [
            "ref": "welcome", "pages": [source, source], "perspective_correct": true,
        ]))
        XCTAssertEqual((encodedCapped["error"] as? [String: Any])?["code"] as? String,
                       "scan_corrected_payload_too_large")
        XCTAssertEqual(correctionCount, 2)
        XCTAssertEqual(dispatchCount, 0)

        correctionCount = 0
        server.scanPageCorrector = { page in
            correctionCount += 1
            return try FrozenAttachmentInput(data: Data(repeating: UInt8(correctionCount), count: 1_500_001),
                                             suggestedName: page.sourceName)
        }
        let decodedCapped = try structured(call(server, "scan_add", [
            "ref": "welcome", "pages": [source, source], "perspective_correct": true,
        ]))
        XCTAssertEqual((decodedCapped["error"] as? [String: Any])?["code"] as? String,
                       "scan_corrected_payload_too_large")
        XCTAssertEqual(correctionCount, 2)
        XCTAssertEqual(dispatchCount, 0)
    }

    func testScanCorrectionCompletesStableJournalHashes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-scan-corrected-hashes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = InMemoryNotes.sample()
        let sourceData = try imageData(width: 8, height: 6)
        let correctedData = try imageData(width: 7, height: 5)
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { tool, arguments in
            XCTAssertEqual(tool, "scan_add")
            XCTAssertEqual(arguments["perspective_correct"] as? Bool, false)
            return try MCPNativeResult(result: WriteResult(outcome: .verified), value: ["ok": true])
        }, stateRoot: root)
        server.scanPageCorrector = { page in
            try FrozenAttachmentInput(data: correctedData, suggestedName: page.sourceName)
        }

        let result = try structured(call(server, "scan_add", [
            "ref": "welcome", "pages": [sourceData.base64EncodedString()], "perspective_correct": true,
        ]))
        XCTAssertNil(result["error"])
        let entry = try XCTUnwrap(WriteJournal(url: root.appendingPathComponent("journal.sqlite")).list(limit: 1).first)
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: entry.arguments) as? [String: Any])
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(recorded["source_page_sha256"] as? String, sha(sourceData))
        XCTAssertEqual(recorded["page_sha256"] as? String, sha(correctedData))
        XCTAssertNil(recorded["pages"])
    }

    func testScanPayloadMetadataRejectsRotatedEXIFForCorrection() throws {
        let server = MCPServer(reader: InMemoryNotes.sample(), allowNative: true, nativeHandler: { _, _ in
            XCTFail("Invalid metadata must not dispatch")
            return try MCPNativeResult(result: WriteResult(outcome: .unknown), value: ["ok": false])
        })
        let up = try imageData(width: 12, height: 8, orientation: 1).base64EncodedString()
        let rotated = try imageData(width: 12, height: 8, orientation: 6).base64EncodedString()

        let accepted = try structured(call(server, "scan_add", [
            "ref": "welcome", "pages": [up], "perspective_correct": true, "dry_run": true,
        ]))
        XCTAssertEqual(accepted["dry_run"] as? Bool, true)
        let response = try request(server, method: "tools/call", params: [
            "name": "scan_add", "arguments": ["ref": "welcome", "pages": [rotated], "perspective_correct": true],
        ])
        XCTAssertEqual(((response["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String,
                       "scan_exif_orientation_unsupported")
    }

    func testScanEdgeDetectionUsesCropSafetyAndUndoContracts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-scan-detect-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = InMemoryNotes.sample()
        let noteID = try fake.summary("welcome").id.uuid
        let previous = ScanCrop(
            bottomLeft: ScanPoint(x: 0, y: 1), bottomRight: ScanPoint(x: 1, y: 1),
            topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1, y: 0))
        let detected = ScanCrop(
            bottomLeft: ScanPoint(x: 0.1, y: 0.9), bottomRight: ScanPoint(x: 0.85, y: 0.95),
            topLeft: ScanPoint(x: 0.15, y: 0.1), topRight: ScanPoint(x: 0.9, y: 0.15))
        var cropDispatch: [String: Any]?
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { tool, arguments in
            switch tool {
            case "scan_page_state":
                return try MCPNativeResult(value: NativeScanPageState(
                    noteID: noteID, attachmentID: "gallery", pageID: "page", pageIDs: ["page"],
                    filter: .photo, orientation: .upright, crop: previous, hasMarkup: false))
            case "scan_detect_edges":
                return try MCPNativeResult(value: detected)
            case "scan_crop":
                cropDispatch = arguments
                return try MCPNativeResult(result: WriteResult(outcome: .verified, noteID: NoteID(uuid: noteID)), value: ["ok": true])
            default:
                throw NotesError("unexpected_test_dispatch", tool)
            }
        }, stateRoot: root)

        let result = try call(server, "scan_crop", [
            "ref": "welcome", "attachment_id": "gallery", "page_id": "page", "detect_edges": true,
        ])
        XCTAssertNotEqual(result["isError"] as? Bool, true, "\(result)")
        XCTAssertEqual(cropDispatch?["top_left_x"] as? Double, detected.topLeft.x)
        XCTAssertEqual(cropDispatch?["top_left_y"] as? Double, detected.topLeft.y)
        XCTAssertEqual(cropDispatch?["bottom_right_x"] as? Double, detected.bottomRight.x)
        XCTAssertEqual(cropDispatch?["bottom_right_y"] as? Double, detected.bottomRight.y)
        XCTAssertEqual(cropDispatch?["expected_crop"] as? String, "0.0,1.0;1.0,1.0;0.0,0.0;1.0,0.0")

        let entry = try XCTUnwrap(WriteJournal(url: root.appendingPathComponent("journal.sqlite")).list(limit: 1).first)
        XCTAssertEqual(try entry.restoreAction(), .scanCrop(
            noteID: noteID, attachmentID: "gallery", pageID: "page", crop: previous, expectedCurrent: detected))
    }
    func testDiagramSchemaAndValidationUseLiteralNotesDefaults() throws {
        let fake = InMemoryNotes.sample()
        var dispatchCount = 0
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { _, _ in
            dispatchCount += 1
            return try MCPNativeResult(result: WriteResult(outcome: .verified), value: ["ok": true])
        })
        let tools = ((try request(server, method: "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]])
        let diagram = try XCTUnwrap(tools.first { $0["name"] as? String == "diagram_add" })
        let properties = try XCTUnwrap((diagram["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual((properties["width"] as? [String: Any])?["maximum"] as? Int, 2400)
        XCTAssertEqual((properties["scale"] as? [String: Any])?["enum"] as? [Int], [2, 3])
        XCTAssertEqual((properties["background"] as? [String: Any])?["enum"] as? [String], ["white", "transparent", "auto"])

        for (arguments, message) in [
            (["ref": "welcome", "file": "/tmp/diagram.svg", "scale": 4] as [String: Any], "Invalid scale; use 2 or 3."),
            (["ref": "welcome", "file": "/tmp/diagram.svg", "width": 2401] as [String: Any], "width must be between 1 and 2400"),
            (["ref": "welcome", "file": "/tmp/diagram.svg", "background": "gray"] as [String: Any], "Invalid background; use white, transparent, or auto.")
        ] {
            let response = try request(server, method: "tools/call", params: ["name": "diagram_add", "arguments": arguments])
            XCTAssertEqual((response["error"] as? [String: Any])?["message"] as? String, message)
        }
        XCTAssertEqual(dispatchCount, 0)
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
        _ = try call(server, "create_note", ["title": "Native", "body": "Body", "folder": "Notes", "engine": "native"])
        _ = try call(server, "update_note", ["ref": "Welcome", "body": "Changed", "engine": "native"])
        XCTAssertEqual(calls.map(\.0), ["create_note", "create_note", "update_note"])
        XCTAssertEqual(calls[2].1["ref"] as? String, "welcome")
    }
    func testNativeEngineRequestsNeverSilentlyDowngrade() throws {
        let fake = InMemoryNotes.sample()
        var calls = 0
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { _, _ in
            calls += 1
            return try MCPNativeResult(result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "native")),
                                       operationID: "native-operation", value: ["ok": true])
        })

        let unsupported = try call(server, "rename_note", ["ref": "welcome", "title": "Changed", "engine": "native"])
        XCTAssertEqual(unsupported["isError"] as? Bool, true)
        XCTAssertEqual(((try structured(unsupported)["error"] as? [String: Any])?["code"] as? String), "unsupported_engine")
        XCTAssertEqual(try fake.note("welcome").summary.title, "Welcome")
        XCTAssertEqual(calls, 0)

        let attachmentDowngrade = try call(server, "create_note", [
            "title": "No downgrade", "body": "Body", "folder": "Notes",
            "engine": "scripting", "attachments": ["/tmp/file"],
        ])
        XCTAssertEqual(attachmentDowngrade["isError"] as? Bool, true)
        XCTAssertEqual(((try structured(attachmentDowngrade)["error"] as? [String: Any])?["code"] as? String), "native_required")
        XCTAssertEqual(calls, 0)

        let dryRun = try structured(call(server, "create_note", [
            "title": "Dry run", "body": "Body", "folder": "Notes", "engine": "native", "dry_run": true,
        ]))
        XCTAssertEqual(dryRun["engine"] as? String, "native")
        XCTAssertEqual(dryRun["dry_run"] as? Bool, true)
        XCTAssertEqual(calls, 0)

        let disabled = MCPServer(reader: fake, writer: fake)
        let unavailable = try call(disabled, "create_note", [
            "title": "Disabled", "body": "Body", "folder": "Notes", "engine": "native",
        ])
        XCTAssertEqual(unavailable["isError"] as? Bool, true)
        XCTAssertEqual(((try structured(unavailable)["error"] as? [String: Any])?["code"] as? String), "native_unavailable")
        XCTAssertEqual(try fake.notes(NoteQuery()).count, 2)
    }
    func testScriptingBodyRewriteRequiresNativeOrExplicitDowngrade() throws {
        let sample = InMemoryNotes.sample()
        var note = try sample.note("welcome")
        note.document = NoteDocument(text: "task", runs: [
            .init(length: 4, paragraph: .init(kind: .checklist, checked: false), font: .init(bold: true), highlight: .mint),
        ])
        let fake = InMemoryNotes(accounts: try sample.accounts(), folders: try sample.folders(account: nil), notes: [note])
        let server = MCPServer(reader: fake, writer: fake)

        let refused = try structured(call(server, "append_to_note", ["ref": "welcome", "body": "more"]))
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "native_required")
        XCTAssertTrue(((refused["error"] as? [String: Any])?["message"] as? String)?.contains("checklists, highlights") == true)

        let allowed = try structured(call(server, "append_to_note", ["ref": "welcome", "body": "more", "allow_downgrade": true]))
        XCTAssertEqual((allowed["result"] as? [String: Any])?["outcome"] as? String, "verified")
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
        let written = try structured(call(server, "update_note", ["ref": "welcome", "body": "Changed", "engine": "native", "allow_shared": true,
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
        let journalID = try XCTUnwrap(result["journalID"] as? String)
        XCTAssertEqual((result["result"] as? [String: Any])?["journalID"] as? String, journalID)

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

        let rolledBack = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { _, _ in
            try MCPNativeResult(result: WriteResult(outcome: .rolledBack, noteID: NoteID(uuid: "partial-note"),
                                                    message: "The partly created note partial-note was moved to Recently Deleted."),
                                operationID: "operation-rollback", value: ["ok": false])
        })
        let rolledBackResult = try call(rolledBack, "pin_note", ["ref": "welcome"])
        XCTAssertEqual(rolledBackResult["isError"] as? Bool, true)
        let rolledBackValue = try XCTUnwrap(try structured(rolledBackResult)["result"] as? [String: Any])
        XCTAssertEqual(rolledBackValue["outcome"] as? String, "rolled_back")
        XCTAssertEqual((rolledBackValue["noteID"] as? [String: Any])?["uuid"] as? String, "partial-note")
    }
    func testNativeFolderAndSmartFolderWritesUseFolderIdentity() throws {
        let account = Account(id: "account", name: "Demo", kind: "local", isDefault: true)
        let regular = Folder(id: "regular-id", name: "Regular", accountID: account.id, parentID: nil, path: ["Regular"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 0)
        let smart = Folder(id: "smart-id", name: "Smart", accountID: account.id, parentID: nil, path: ["Smart"], isSmartFolder: true, isRecentlyDeleted: false, noteCount: 0,
                           smartFolderQuery: #"{"tag":"old"}"#)
        let fake = InMemoryNotes(accounts: [account], folders: [regular, smart])
        var calls: [(String, String)] = []
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { tool, arguments in
            if tool == "journal_get_smart_folder_query" {
                return try MCPNativeResult(value: #"{"tag":"old"}"#)
            }
            if tool == "get_folder_sort" {
                return try MCPNativeResult(value: ["folderID": arguments["ref"] as! String, "order": "title", "direction": "ascending"])
            }
            let ref = arguments["ref"] as! String
            calls.append((tool, ref))
            return try MCPNativeResult(result: WriteResult(outcome: .verified, folderID: ref), value: ["ok": true])
        })
        _ = try call(server, "set_folder_sort", ["ref": "Regular", "by": "modified", "direction": "newest"])
        _ = try call(server, "smart_folder_edit_typed", ["ref": "Smart", "expected_count": 1, "tags": ["work"]])
        XCTAssertEqual(calls.map(\.0), ["set_folder_sort", "smart_folder_edit_typed"])
        XCTAssertEqual(calls.map(\.1), ["regular-id", "smart-id"])
    }

    func testNativeSettingAndSmartFolderWritesJournalLiteralPreimages() throws {
        struct FolderDateGrouping: Encodable { let enabled: Bool; let type: Int }
        struct NotesSettings: Encodable {
            let sort = "modified"
            let groupsByDate = true
            let defaultTextSize = 12
            let resumesLastQuickNote = true
            let autoConvertsToTags = true
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-native-preimages-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(id: "account-new", name: "Demo", kind: "local", isDefault: true)
        let regular = Folder(id: "regular-id", name: "Regular", accountID: account.id, parentID: nil, path: ["Regular"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 0)
        let smart = Folder(id: "smart-id", name: "Smart", accountID: account.id, parentID: nil, path: ["Smart"], isSmartFolder: true, isRecentlyDeleted: false, noteCount: 0,
                           smartFolderQuery: #"{"tag":"old"}"#)
        let fake = InMemoryNotes(accounts: [account], folders: [regular, smart])
        let quickNoteID = try XCTUnwrap(try fake.createNote(title: "Welcome", markdown: "", folder: regular.id).noteID?.uuid)
        var cropDispatch: [String: Any]?
        var deleteDispatch: [String: Any]?
        var undoSortDispatch: [String: Any]?
        var preferenceWrite: [String: Any]?
        var preferenceUndoDispatch: [String: Any]?
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { tool, arguments in
            switch tool {
            case "journal_get_checklist_auto_sort": return try MCPNativeResult(value: false)
            case "journal_get_default_account": return try MCPNativeResult(value: "account-old")
            case "journal_get_smart_folder_query": return try MCPNativeResult(value: #"{"tag":"old"}"#)
            case "get_folder_sort": return try MCPNativeResult(value: ["folderID": "regular-id", "order": "created", "direction": "oldest"])
            case "get_folder_date_grouping": return try MCPNativeResult(value: FolderDateGrouping(enabled: true, type: 0))
            case "get_default_paragraph_style": return try MCPNativeResult(value: ["style": "title", "value": "0"])
            case "get_notes_settings": return try MCPNativeResult(value: NotesSettings())
            case "scan_page_state":
                return try MCPNativeResult(value: NativeScanPageState(
                    noteID: quickNoteID, attachmentID: "gallery-1", pageID: "page-1",
                    pageIDs: ["page-2", "page-1"], filter: .photo, orientation: .right,
                    crop: ScanCrop(
                        bottomLeft: ScanPoint(x: 0, y: 1), bottomRight: ScanPoint(x: 1, y: 1),
                        topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1, y: 0)),
                    hasMarkup: false))
            case "scan_crop":
                cropDispatch = arguments
                return try MCPNativeResult(result: WriteResult(outcome: .verified, folderID: arguments["ref"] as? String), value: ["ok": true])
            case "scan_delete":
                deleteDispatch = arguments
                return try MCPNativeResult(result: WriteResult(outcome: .verified, folderID: arguments["ref"] as? String), value: ["ok": true])
            case "scan_append":
                return try MCPNativeResult(
                    result: WriteResult(outcome: .verified, noteID: NoteID(uuid: quickNoteID)),
                    value: ["pageAttachmentIDs": ["page-3"]])
            case "_journal_get_notes_preference":
                return try MCPNativeResult(value: NativePreferenceValue(setting: .darkBackgrounds, state: .default))
            case "set_dark_backgrounds":
                preferenceWrite = arguments
                return try MCPNativeResult(result: WriteResult(outcome: .verified), value: ["ok": true])
            case "_journal_set_notes_preference":
                preferenceUndoDispatch = arguments
                return try MCPNativeResult(result: WriteResult(outcome: .verified), value: ["ok": true])
            case "set_global_note_sort":
                if arguments["expected_sort"] != nil { undoSortDispatch = arguments }
                return try MCPNativeResult(result: WriteResult(outcome: .verified), value: ["ok": true])
            default:
                return try MCPNativeResult(result: WriteResult(outcome: .verified, folderID: arguments["ref"] as? String), value: ["ok": true])
            }
        }, stateRoot: root)

        _ = try call(server, "checklist_auto_sort", ["enabled": true])
        _ = try call(server, "set_default_account", ["account_id": "account-new"])
        _ = try call(server, "set_folder_sort", ["ref": "Regular", "by": "title", "direction": "ascending"])
        _ = try call(server, "set_folder_date_grouping", ["ref": "Regular", "enabled": false])
        _ = try call(server, "set_default_paragraph_style", ["style": "body"])
        _ = try call(server, "set_global_note_sort", ["sort": "title"])
        _ = try call(server, "set_global_date_grouping", ["enabled": false])
        _ = try call(server, "set_default_text_size", ["points": 18])
        _ = try call(server, "set_resume_last_quick_note", ["enabled": false])
        _ = try call(server, "set_auto_convert_tags", ["enabled": false])
        _ = try call(server, "set_dark_backgrounds", ["enabled": false])
        let quickNote = try call(server, "set_quick_note", ["ref": quickNoteID, "enabled": true])
        XCTAssertNotEqual(quickNote["isError"] as? Bool, true, "\(quickNote)")
        _ = try call(server, "smart_folder_edit_rules", ["ref": "Smart", "query_json": #"{"tag":"new"}"#, "expected_count": 1])
        _ = try call(server, "scan_filter", ["ref": "Welcome", "attachment_id": "gallery-1", "page_id": "page-1", "filter": "color"])
        _ = try call(server, "scan_rotate", ["ref": "Welcome", "attachment_id": "gallery-1", "page_id": "page-1", "orientation": "upright"])
        let cropArguments: [String: Any] = [
            "ref": "Welcome", "attachment_id": "gallery-1", "page_id": "page-1",
            "bottom_left_x": 0.1, "bottom_left_y": 0.9,
            "bottom_right_x": 0.9, "bottom_right_y": 0.9,
            "top_left_x": 0.1, "top_left_y": 0.1,
            "top_right_x": 0.9, "top_right_y": 0.1,
        ]
        _ = try call(server, "scan_crop", cropArguments)
        XCTAssertEqual(cropDispatch?["expected_crop"] as? String, "0.0,1.0;1.0,1.0;0.0,0.0;1.0,0.0")
        _ = try call(server, "scan_move", ["ref": "Welcome", "attachment_id": "gallery-1", "page_id": "page-1", "to_index": 0])
        _ = try call(server, "scan_delete", ["ref": "Welcome", "attachment_id": "gallery-1", "page_id": "page-1"])
        XCTAssertEqual(deleteDispatch?["expected_page_ids"] as? [String], ["page-2", "page-1"])
        _ = try call(server, "scan_append", [
            "ref": "Welcome", "attachment_id": "gallery-1", "page_id": "page-1",
            "pages": [try imageData(width: 8, height: 6).base64EncodedString()], "page_names": ["page.jpg"],
        ])

        let entries = try WriteJournal(url: root.appendingPathComponent("journal.sqlite")).list(limit: 20)
        let actions = try entries.compactMap { try $0.restoreAction() }
        XCTAssertTrue(actions.contains(.checklistAutoSort(enabled: false)))
        XCTAssertTrue(actions.contains(.defaultAccount(identifier: "account-old")))
        XCTAssertTrue(actions.contains(.folderSort(folderID: "regular-id", order: "created", direction: "oldest")))
        XCTAssertTrue(actions.contains(.folderDateGrouping(folderID: "regular-id", type: 0)))
        XCTAssertTrue(actions.contains(.defaultParagraphStyle(style: "title")))
        XCTAssertTrue(actions.contains(.globalNoteSort(sort: "modified")))
        XCTAssertTrue(actions.contains(.globalDateGrouping(enabled: true)))
        XCTAssertTrue(actions.contains(.defaultTextSize(points: 12)))
        XCTAssertTrue(actions.contains(.resumeLastQuickNote(enabled: true)))
        XCTAssertTrue(actions.contains(.autoConvertToTags(enabled: true)))
        XCTAssertTrue(actions.contains(.quickNote(noteID: quickNoteID, enabled: false)))
        XCTAssertTrue(actions.contains(.smartFolderQuery(folderID: "smart-id", queryJSON: #"{"tag":"old"}"#)))
        XCTAssertTrue(actions.contains(.scanFilter(noteID: quickNoteID, attachmentID: "gallery-1", pageID: "page-1", filter: "photo", expectedCurrent: "color")), "\(actions)")
        XCTAssertTrue(actions.contains(.scanOrientation(noteID: quickNoteID, attachmentID: "gallery-1", pageID: "page-1", orientation: "right", expectedCurrent: "upright")), "\(actions)")
        XCTAssertTrue(actions.contains(.scanCrop(
            noteID: quickNoteID, attachmentID: "gallery-1", pageID: "page-1",
            crop: ScanCrop(
                bottomLeft: ScanPoint(x: 0, y: 1), bottomRight: ScanPoint(x: 1, y: 1),
                topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1, y: 0)),
            expectedCurrent: ScanCrop(
                bottomLeft: ScanPoint(x: 0.1, y: 0.9), bottomRight: ScanPoint(x: 0.9, y: 0.9),
                topLeft: ScanPoint(x: 0.1, y: 0.1), topRight: ScanPoint(x: 0.9, y: 0.1)))), "\(actions)")
        XCTAssertTrue(actions.contains(.scanMove(noteID: quickNoteID, attachmentID: "gallery-1", pageID: "page-1", index: 1,
                                                expectedPageIDs: ["page-1", "page-2"])), "\(actions)")
        XCTAssertTrue(actions.contains(.scanUndelete(noteID: quickNoteID, attachmentID: "gallery-1", pageID: "page-1", index: 1,
                                                     expectedPageIDs: ["page-2"])), "\(actions)")
        XCTAssertTrue(actions.contains(.scanDeletePages(
            noteID: quickNoteID, attachmentID: "gallery-1", pageIDs: ["page-3"],
            expectedPageIDs: ["page-2", "page-1", "page-3"])), "\(actions)")

        let sortEntry = try XCTUnwrap(entries.first { $0.operation == "set_global_note_sort" })
        XCTAssertTrue(actions.contains(.notesPreference(setting: "dark-backgrounds", state: "default")), "\(actions)")
        let preferenceEntry = try XCTUnwrap(entries.first { $0.operation == "set_dark_backgrounds" })
        XCTAssertEqual(try preferenceEntry.restoreExpectation(), .notesPreference("off"))
        XCTAssertEqual(preferenceWrite?["enabled"] as? Bool, false)
        let preferenceUndo = try call(server, "undo", ["operation_id": preferenceEntry.id])
        XCTAssertNotEqual(preferenceUndo["isError"] as? Bool, true, "\(preferenceUndo)")
        XCTAssertEqual(preferenceUndoDispatch?["setting"] as? String, "dark-backgrounds")
        XCTAssertEqual(preferenceUndoDispatch?["state"] as? String, "default")
        XCTAssertEqual(preferenceUndoDispatch?["expected_state"] as? String, "off")
        let undo = try call(server, "undo", ["operation_id": sortEntry.id])
        XCTAssertNotEqual(undo["isError"] as? Bool, true, "\(undo)")
        XCTAssertEqual(undoSortDispatch?["sort"] as? String, "modified")
        XCTAssertEqual(undoSortDispatch?["expected_sort"] as? String, "title")
    }
    func testReadAndPaging() throws {
        let server = MCPServer(reader: InMemoryNotes.sample())
        let first = try structured(call(server, "list_notes", ["limit": 1]))
        XCTAssertEqual((first["notes"] as? [Any])?.count, 1)
        let cursor = try XCTUnwrap(first["next_cursor"] as? String)
        let second = try structured(call(server, "list_notes", ["limit": 1, "cursor": cursor]))
        XCTAssertNil(second["next_cursor"])
        let search = try structured(call(server, "search_notes", ["query": "coffee"]))
        XCTAssertEqual((search["notes"] as? [Any])?.count, 1)
        for format in ["markdown", "text", "html", "json"] {
            let note = try structured(call(server, "get_note", ["ref": "welcome", "format": format]))
            XCTAssertNotNil(note[format == "json" ? "note" : "body"])
        }
        let accounts = try structured(call(server, "list_accounts"))
        XCTAssertNotNil(accounts["accounts"])
        XCTAssertEqual((accounts["default_location"] as? [String: Any])?["folderName"] as? String, "Notes")
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

        let local = try String(contentsOf: path).replacingOccurrences(of: "Welcome to notescli. Browse your shopping notes. #demo", with: "changed")
        try local.write(to: path, atomically: true, encoding: .utf8)
        let safetyRoot = root.appendingPathComponent("safety")
        let denied = MCPServer(reader: fake, writer: fake, writeFolders: "Personal", stateRoot: safetyRoot)
        let deniedPush = try structured(call(denied, "file_push", ["path": path.path]))
        XCTAssertEqual((deniedPush["error"] as? [String: Any])?["code"] as? String, "write_not_allowed")
        XCTAssertEqual(try fake.note("welcome").document?.text, "Welcome to notescli. Browse your shopping notes. #demo")

        let allowed = MCPServer(reader: fake, writer: fake, writeFolders: "Notes", stateRoot: safetyRoot)
        _ = try call(allowed, "file_push", ["path": path.path, "idempotency_key": "file-push-test"])
        XCTAssertEqual(try fake.note("welcome").document?.text, "changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: safetyRoot.appendingPathComponent("journal.sqlite").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: safetyRoot.appendingPathComponent("snapshots/welcome"), includingPropertiesForKeys: nil).isEmpty)
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
        XCTAssertNotNil(page["next_cursor"])

        var note = try fake.note("welcome")
        note.attachments = [Attachment(id: "huge", typeUTI: "public.data", filename: String(repeating: "x", count: 60_000))]
        note.summary.attachmentCount = 1
        let bounded = MCPServer(reader: InMemoryNotes(accounts: try fake.accounts(), folders: try fake.folders(account: nil), notes: [note]))
        let attachments = try call(bounded, "list_attachments", ["ref": "welcome"])
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: attachments["structuredContent"]!).count, 49_152)
        XCTAssertEqual((attachments["structuredContent"] as? [String: Any])?["truncated"] as? Bool, true)
    }
    func testStableCursorSurvivesInsertionBeforeTheCursor() throws {
        let sample = InMemoryNotes.sample()
        let firstServer = MCPServer(reader: sample)
        let first = try structured(call(firstServer, "list_notes", ["limit": 1]))
        let firstID = try XCTUnwrap((first["notes"] as? [[String: Any]])?.first?["id"] as? [String: Any])
        let firstUUID = try XCTUnwrap(firstID["uuid"] as? String)
        let cursor = try XCTUnwrap(first["next_cursor"] as? String)

        let account = try XCTUnwrap(try sample.accounts().first)
        let folder = try XCTUnwrap(try sample.folders(account: nil).first)
        let inserted = Note(summary: NoteSummary(
            id: NoteID(uuid: "inserted", shortID: "n99"), title: "Inserted", snippet: "", folderID: folder.id,
            folderPath: folder.path, accountID: account.id, created: nil, modified: Date(timeIntervalSince1970: 1_900_000_000),
            isPinned: false, isLocked: false, isDeleted: false, hasChecklist: false, attachmentCount: 0, tags: []
        ), document: NoteDocument(text: "", runs: []), attachments: [])
        let mutated = InMemoryNotes(accounts: [account], folders: [folder], notes: [try sample.note("welcome"), try sample.note("shopping"), inserted])
        let second = try structured(call(MCPServer(reader: mutated), "list_notes", ["limit": 10, "cursor": cursor]))
        let remaining = (second["notes"] as? [[String: Any]])?.compactMap { ($0["id"] as? [String: Any])?["uuid"] as? String } ?? []
        XCTAssertFalse(remaining.contains("inserted"))
        XCTAssertFalse(remaining.contains(firstUUID))
        XCTAssertEqual(remaining.count, 1)
    }

    func testTitleCursorUsesTheNaturalTitleOrder() throws {
        let account = Account(id: "a", name: "A", kind: "local")
        let folder = Folder(id: "f", name: "F", accountID: "a", parentID: nil, path: ["F"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 3)
        let notes = [("n1", "Note 1"), ("n2", "Note 2"), ("n10", "Note 10")].map { id, title in
            Note(summary: NoteSummary(id: NoteID(uuid: id), title: title, snippet: "", folderID: "f", folderPath: ["F"], accountID: "a",
                                      created: nil, modified: nil, isPinned: false, isLocked: false, isDeleted: false,
                                      hasChecklist: false, attachmentCount: 0, tags: []),
                 document: NoteDocument(text: "", runs: []), attachments: [])
        }
        let server = MCPServer(reader: InMemoryNotes(accounts: [account], folders: [folder], notes: notes))
        let first = try structured(call(server, "list_notes", ["sort": "title", "limit": 2]))
        let cursor = try XCTUnwrap(first["next_cursor"] as? String)
        let second = try structured(call(server, "list_notes", ["sort": "title", "limit": 2, "cursor": cursor]))
        let ids = (second["notes"] as? [[String: Any]])?.compactMap { ($0["id"] as? [String: Any])?["uuid"] as? String }
        XCTAssertEqual(ids, ["n10"])
    }
    func testDates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertLessThan(try NotePresentation.date("7d", now: now), now)
        XCTAssertEqual(try NotePresentation.date("today", now: now), Calendar.current.startOfDay(for: now))
        XCTAssertLessThan(try NotePresentation.date("yesterday", now: now), try NotePresentation.date("today", now: now))
        for input in ["2026-11-11", "2026-11-11T12:00:00Z", "2026-11-11T12:00:00.123Z"] { XCTAssertNoThrow(try NotePresentation.date(input)) }
        XCTAssertThrowsError(try NotePresentation.date("2026-99-99"))
    }

    func testReadParityToolsUseSyntheticData() throws {
        let sample = InMemoryNotes.sample(), account = try XCTUnwrap(try sample.accounts().first), folder = try XCTUnwrap(try sample.folders(account: nil).first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-mcp-read-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let imageURL = root.appendingPathComponent("image.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAD0lEQVR42mNk+M8ABBgAEQAB/7M2VQAAAABJRU5ErkJggg==")!.write(to: imageURL)
        let audioURL = root.appendingPathComponent("recording.mp3")
        try Data([0x49, 0x44, 0x33]).write(to: audioURL)
        let largeAudioURL = root.appendingPathComponent("large-recording.mp3")
        try Data(repeating: 0, count: 1_200_000).write(to: largeAudioURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: largeAudioURL.path)
        let text = "Title\nSection\n"
        var document = NoteDocument(text: text, runs: [
            AttributeRun(length: 6, paragraph: ParagraphStyle(kind: .title)),
            AttributeRun(length: 8, paragraph: ParagraphStyle(kind: .heading))
        ])
        document.tables = ["table-1": [["A", "B"], ["1", "2"]]]
        let summary = NoteSummary(id: NoteID(uuid: "rich", shortID: "n50"), title: "Rich", snippet: "", folderID: folder.id,
                                  folderPath: folder.path, accountID: account.id, created: nil, modified: Date(), isPinned: false,
                                  isLocked: false, isDeleted: false, hasChecklist: false, attachmentCount: 4, tags: [])
        let rich = Note(summary: summary, document: document, attachments: [
            Attachment(id: "image-1", typeUTI: "public.png", filePath: imageURL.path),
            Attachment(id: "table-1", typeUTI: "com.apple.notes.table"),
            Attachment(id: "audio-1", typeUTI: "public.mp3", filePath: audioURL.path),
            Attachment(id: "audio-large", typeUTI: "public.mp3", filePath: largeAudioURL.path)
        ])
        let reader = InMemoryNotes(accounts: [account], folders: [folder], notes: [rich])
        let server = MCPServer(reader: reader, stateRoot: root)

        let outline = try structured(call(server, "get_note", ["ref": "n50", "format": "outline"]))
        XCTAssertEqual((outline["outline"] as? [Any])?.count, 1)
        let table = try structured(call(server, "table_get", ["ref": "50", "attachment_id": "table-1", "format": "csv"]))
        XCTAssertTrue((table["body"] as? String)?.contains("\"A\",\"B\"") == true)
        let filtered = try structured(call(server, "list_notes", ["has": "image"]))
        XCTAssertEqual((filtered["notes"] as? [Any])?.count, 1)
        let added = try structured(call(server, "anchor_add", ["ref": "rich", "offset": 0]))
        let anchor = try XCTUnwrap((added["anchor"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual((try structured(call(server, "anchor_resolve", ["id": anchor]))["resolution"] as? [String: Any])?["offset"] as? Int, 0)
        XCTAssertEqual((try structured(call(server, "anchor_list"))["anchors"] as? [Any])?.count, 1)
        XCTAssertNotNil(try structured(call(server, "index_status"))["job"])
        let binary = try call(server, "get_attachment", ["ref": "rich", "attachment_id": "image-1"])
        XCTAssertEqual((binary["content"] as? [[String: Any]])?.first?["type"] as? String, "image")
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: binary["content"]!).count, MCPServer.textLimit)
        let audio = try call(server, "get_attachment", ["ref": "rich", "attachment_id": "audio-1"])
        XCTAssertEqual((audio["content"] as? [[String: Any]])?.first?["type"] as? String, "audio")
        let resource = try call(server, "get_attachment", ["ref": "rich", "attachment_id": "audio-large"])
        XCTAssertEqual((resource["content"] as? [[String: Any]])?.first?["type"] as? String, "resource_link")
        let resourceURI = try XCTUnwrap((resource["content"] as? [[String: Any]])?.first?["uri"] as? String)
        XCTAssertTrue(resourceURI.hasPrefix("notes://attachment/"))
        XCTAssertFalse(resourceURI.contains("file://"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: largeAudioURL.path)
        let read = try request(server, method: "resources/read", params: ["uri": resourceURI])
        let contents = ((read["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(contents?.first?["blob"] as? String))?.count, 1_048_576)
        let metadata = try XCTUnwrap(contents?.first?["_meta"] as? [String: Any])
        let nextURI = try XCTUnwrap(metadata["nextUri"] as? String)
        let next = try request(server, method: "resources/read", params: ["uri": nextURI])
        let nextContents = ((next["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(nextContents?.first?["blob"] as? String))?.count,
                       1_200_000 - 1_048_576)
        XCTAssertEqual((nextContents?.first?["_meta"] as? [String: Any])?["complete"] as? Bool, true)
    }

    func testReadOnlyAnchorReadsDoNotCreateState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-readonly-anchors-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MCPServer(reader: InMemoryNotes.sample(), readOnly: true, stateRoot: root)

        XCTAssertEqual((try structured(call(server, "anchor_list"))["anchors"] as? [Any])?.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("anchors.sqlite").path))
        let missing = try structured(call(server, "anchor_resolve", ["id": "a-missing"]))
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? String, "anchor_not_found")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("anchors.sqlite").path))
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

    func testLinkCaptureIsIdempotentAndExactUndoRestoresItsSnapshot() throws {
        let fake = InMemoryNotes.sample()
        let before = try fake.note("welcome").document?.text
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-mcp-link-capture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var captureCalls = 0
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { tool, arguments in
            switch tool {
            case "link_capture":
                captureCalls += 1
                let result = try fake.replaceBody(arguments["ref"] as! String, markdown: "captured link", allowAttachmentLoss: true)
                return try MCPNativeResult(result: result, value: ["captured": true])
            case "_journal_restore_snapshot":
                XCTAssertNil(arguments["snapshot"])
                XCTAssertNotNil(arguments["_restore_material"] as? SnapshotRestoreMaterial)
                XCTAssertNotNil(arguments["_expected_revision"] as? String)
                let snapshot = try XCTUnwrap(arguments["_snapshot_note"] as? Note)
                let markdown = snapshot.document?.markdown(attachments: snapshot.attachments) ?? ""
                let result = try fake.replaceBody(arguments["ref"] as! String, markdown: markdown, allowAttachmentLoss: true)
                return try MCPNativeResult(result: result, value: ["restored": true])
            default:
                throw NotesError("unexpected_native_tool", tool)
            }
        }, stateRoot: root)
        let arguments: [String: Any] = ["ref": "welcome", "url": "https://example.com",
                                        "title": "Example", "idempotency_key": "link-capture-test"]

        let first = try structured(call(server, "link_capture", arguments))
        let operationID = try XCTUnwrap(first["journalID"] as? String)
        let replay = try structured(call(server, "link_capture", arguments))
        XCTAssertEqual(replay["replayed"] as? Bool, true)
        XCTAssertEqual(captureCalls, 1)

        let journal = try WriteJournal.openReadOnlyIfExists(url: root.appendingPathComponent("journal.sqlite"))
        let entry = try XCTUnwrap(journal?.entry(id: operationID))
        XCTAssertNotNil(entry.snapshotID)
        XCTAssertNotNil(entry.postRevision)

        let undo = try structured(call(server, "undo", ["operation_id": operationID]))
        XCTAssertNil(undo["error"])
        XCTAssertEqual(try fake.note("welcome").document?.text, before)
    }

    func testPrivateSnapshotRestoreOperationIsNotAnMCPTool() throws {
        let server = MCPServer(reader: InMemoryNotes.sample(), allowNative: true, nativeHandler: { _, _ in
            XCTFail("A public MCP request reached the private native snapshot operation.")
            return try MCPNativeResult(value: ["unexpected": true])
        })
        let response = try request(
            server,
            method: "tools/call",
            params: ["name": "_journal_restore_snapshot", "arguments": [String: Any]()]
        )
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual(error["message"] as? String, "Unknown or unavailable tool")
    }

    func testHistoryDiffAndConflictSafeUndoUseTheSameSnapshots() throws {
        let fake = InMemoryNotes.sample()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-mcp-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = MCPServer(reader: fake, writer: fake, allowNative: true, nativeHandler: { tool, arguments in
            guard tool == "_journal_restore_snapshot",
                  arguments["snapshot"] == nil,
                  arguments["_restore_material"] is SnapshotRestoreMaterial,
                  arguments["_expected_revision"] is String,
                  let snapshot = arguments["_snapshot_note"] as? Note else {
                throw NotesError("unexpected_native_tool", tool)
            }
            let markdown = snapshot.document?.markdown(attachments: snapshot.attachments) ?? ""
            let result = try fake.replaceBody(arguments["ref"] as! String, markdown: markdown, allowAttachmentLoss: true)
            return try MCPNativeResult(result: result, value: ["restored": true])
        }, stateRoot: root)

        let first = try structured(call(server, "update_note", ["ref": "welcome", "body": "first"]))
        let firstID = try XCTUnwrap(first["journalID"] as? String)
        let snapshots = try structured(call(server, "history", ["ref": "welcome"]))["snapshots"] as? [[String: Any]]
        XCTAssertEqual(snapshots?.count, 1)
        let snapshotID = try XCTUnwrap(snapshots?.first?["id"] as? String)
        let diff = try structured(call(server, "diff", ["ref": "welcome", "snapshot": snapshotID]))
        XCTAssertTrue((diff["diff"] as? String)?.contains("first") == true)

        let second = try structured(call(server, "update_note", ["ref": "welcome", "body": "second"]))
        let secondID = try XCTUnwrap(second["journalID"] as? String)
        let conflict = try structured(call(server, "undo", ["operation_id": firstID]))
        XCTAssertEqual((conflict["error"] as? [String: Any])?["code"] as? String, "undo_conflict")

        let undo = try structured(call(server, "undo", ["operation_id": secondID]))
        XCTAssertNil(undo["error"])
        XCTAssertEqual(try fake.note("welcome").document?.text, "first")

        let revert = try structured(call(server, "revert", ["ref": "welcome", "snapshot": snapshotID]))
        XCTAssertNil(revert["error"])
        XCTAssertNotEqual(try fake.note("welcome").document?.text, "first")
    }

    func testPerCallWriteFoldersCanNarrowButNotBroadenServerPolicy() throws {
        let fake = InMemoryNotes.sample()
        let serverRestricted = MCPServer(reader: fake, writer: fake, writeFolders: "Personal")
        let broadened = try structured(call(serverRestricted, "update_note", [
            "ref": "welcome", "body": "changed", "write_folders": "Notes", "dry_run": true,
        ]))
        XCTAssertEqual((broadened["error"] as? [String: Any])?["code"] as? String, "write_not_allowed")

        let serverAllowed = MCPServer(reader: fake, writer: fake, writeFolders: "Notes")
        let narrowed = try structured(call(serverAllowed, "update_note", [
            "ref": "welcome", "body": "changed", "write_folders": "Personal", "dry_run": true,
        ]))
        XCTAssertEqual((narrowed["error"] as? [String: Any])?["code"] as? String, "write_not_allowed")

        let matching = try structured(call(serverAllowed, "update_note", [
            "ref": "welcome", "body": "changed", "write_folders": "Notes", "dry_run": true,
        ]))
        XCTAssertEqual(matching["dry_run"] as? Bool, true)
    }

    func testRestoreChecksDestinationAgainstServerWritePolicy() throws {
        let sample = InMemoryNotes.sample()
        let account = try XCTUnwrap(try sample.accounts().first)
        let notesFolder = try XCTUnwrap(try sample.folders(account: nil).first)
        let personalFolder = Folder(
            id: "personal-folder", name: "Personal", accountID: account.id, parentID: nil,
            path: ["Personal"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 0
        )
        let fake = InMemoryNotes(
            accounts: [account], folders: [notesFolder, personalFolder], notes: [try sample.note("welcome")]
        )
        let server = MCPServer(
            reader: fake, writer: fake, allowNative: true,
            nativeHandler: { _, _ in try MCPNativeResult(result: WriteResult(outcome: .verified), value: ["ok": true]) },
            writeFolders: "Notes"
        )

        let denied = try structured(call(server, "restore_note", [
            "ref": "welcome", "folder": "Personal", "dry_run": true,
        ]))
        XCTAssertEqual((denied["error"] as? [String: Any])?["code"] as? String, "write_not_allowed")

        let omitted = try structured(call(server, "restore_note", [
            "ref": "welcome", "dry_run": true,
        ]))
        XCTAssertEqual((omitted["error"] as? [String: Any])?["code"] as? String, "write_not_allowed")

        let allowed = try structured(call(server, "restore_note", [
            "ref": "welcome", "folder": "Notes", "dry_run": true,
        ]))
        XCTAssertEqual(allowed["dry_run"] as? Bool, true)
    }
}

final class OptionalSelectorCapabilityTests: XCTestCase {
    func testMissingDividerSelectorMarksOnlyDividerUnavailable() {
        let missing = ["+[ICInlineAttachment newDividerLineAttachmentWithIdentifier:note:parentAttachment:]"]
        XCTAssertFalse(CapabilityCatalog.optionalSelectorsPresent(for: "Divider lines", missing: missing))
        XCTAssertTrue(CapabilityCatalog.optionalSelectorsPresent(for: "Mentions", missing: missing))
        XCTAssertTrue(CapabilityCatalog.optionalSelectorsPresent(for: "Bold", missing: missing))
    }
}

final class ServerVersionTests: XCTestCase {
    func testInitializeReportsTheReleaseVersion() throws {
        let fake = InMemoryNotes.sample()
        let server = MCPServer(reader: fake, writer: fake)
        let response = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "t", "version": "1"]]]))
        let info = try XCTUnwrap((response["result"] as? [String: Any])?["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["version"] as? String, "1.1.10")
    }
}
