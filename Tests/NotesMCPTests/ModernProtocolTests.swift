import Foundation
import NotesCore
import NotesSafety
import XCTest
@testable import NotesMCP

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

final class ModernProtocolTests: XCTestCase {
    private func envelope(apps: Bool = false) -> [String: Any] {
        var capabilities: [String: Any] = [:]
        if apps {
            capabilities["extensions"] = [
                MCPProtocol.appsExtension: [
                    "mimeTypes": ["text/html; charset=utf-8; profile=\"mcp-app\""]
                ]
            ]
        }
        return [
            MCPProtocol.protocolVersionKey: MCPProtocol.modernVersion,
            MCPProtocol.clientCapabilitiesKey: capabilities,
        ]
    }

    private func request(_ server: MCPServer, id: Any = UUID().uuidString, method: String,
                         params: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": id, "method": method, "params": params]))
    }

    private func modernRequest(_ server: MCPServer, id: Any = UUID().uuidString, method: String,
                               params: [String: Any] = [:], apps: Bool = false) throws -> [String: Any] {
        var value = params
        value["_meta"] = envelope(apps: apps)
        return try request(server, id: id, method: method, params: value)
    }

    func testLegacyInitializePreservesEveryPublishedLegacyRevision() throws {
        let server = MCPServer(reader: InMemoryNotes.sample())
        XCTAssertEqual(MCPServer.versions, ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
        for version in MCPServer.versions {
            let response = try request(server, method: "initialize", params: ["protocolVersion": version])
            XCTAssertEqual((response["result"] as? [String: Any])?["protocolVersion"] as? String, version)
            XCTAssertNil((response["result"] as? [String: Any])?["resultType"])
        }
        let fallback = try request(server, method: "initialize", params: ["protocolVersion": "1900-01-01"])
        XCTAssertEqual((fallback["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
    }

    func testModernDiscoveryAndResultsFollowThePublishedEnvelope() throws {
        let server = MCPServer(reader: InMemoryNotes.sample())
        let missingMeta = try request(server, method: "server/discover", params: [:])
        XCTAssertEqual((missingMeta["error"] as? [String: Any])?["code"] as? Int, -32602)

        let discovery = try modernRequest(server, method: "server/discover")
        let result = try XCTUnwrap(discovery["result"] as? [String: Any])
        XCTAssertEqual(result["supportedVersions"] as? [String],
                       ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["ttlMs"] as? Int, 30_000)
        XCTAssertEqual(result["cacheScope"] as? String, "public")
        XCTAssertEqual(((result["_meta"] as? [String: Any])?[MCPProtocol.serverInfoKey] as? [String: Any])?["name"] as? String, "notescli")

        let tools = try modernRequest(server, method: "tools/list")
        let toolsResult = try XCTUnwrap(tools["result"] as? [String: Any])
        XCTAssertEqual(toolsResult["resultType"] as? String, "complete")
        XCTAssertEqual(toolsResult["cacheScope"] as? String, "public")
        XCTAssertEqual(toolsResult["ttlMs"] as? Int, 30_000)

        let ping = try modernRequest(server, method: "ping")
        let pingResult = try XCTUnwrap(ping["result"] as? [String: Any])
        XCTAssertEqual(pingResult["resultType"] as? String, "complete")
        XCTAssertNil(pingResult["ttlMs"])
        XCTAssertNil(pingResult["cacheScope"])
    }

    func testReadFidelityIsExplicitInEveryResult() throws {
        let server = MCPServer(reader: InMemoryNotes.sample(), readFidelity: "limited",
                               unavailableReadFields: ["attachments", "formatting"])
        let response = try modernRequest(server, method: "ping")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let metadata = try XCTUnwrap(result["_meta"] as? [String: Any])
        let fidelity = try XCTUnwrap(metadata["net.notescli/readFidelity"] as? [String: Any])
        XCTAssertEqual(fidelity["fidelity"] as? String, "limited")
        XCTAssertEqual(fidelity["unavailableFields"] as? [String], ["attachments", "formatting"])
    }

    func testModernRequestsValidateRequiredMetadataAndVersion() throws {
        let server = MCPServer(reader: InMemoryNotes.sample())
        let nullID = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": NSNull(), "method": "ping"]))
        XCTAssertEqual((nullID["error"] as? [String: Any])?["code"] as? Int, -32600)
        let fractionalID = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1.5, "method": "ping"]))
        XCTAssertEqual((fractionalID["error"] as? [String: Any])?["code"] as? Int, -32600)
        let partial = try request(server, method: "tools/list", params: [
            "_meta": [MCPProtocol.protocolVersionKey: MCPProtocol.modernVersion]
        ])
        XCTAssertEqual((partial["error"] as? [String: Any])?["code"] as? Int, -32602)
        let malformedMeta = try request(server, method: "tools/list", params: ["_meta": "bad"])
        XCTAssertEqual((malformedMeta["error"] as? [String: Any])?["code"] as? Int, -32602)
        let malformedCapabilities = try request(server, method: "tools/list", params: [
            "_meta": [
                MCPProtocol.protocolVersionKey: MCPProtocol.modernVersion,
                MCPProtocol.clientCapabilitiesKey: "bad",
            ]
        ])
        XCTAssertEqual((malformedCapabilities["error"] as? [String: Any])?["code"] as? Int, -32602)

        let unsupported = try request(server, method: "tools/list", params: [
            "_meta": [
                MCPProtocol.protocolVersionKey: "1900-01-01",
                MCPProtocol.clientCapabilitiesKey: [String: Any](),
            ]
        ])
        let unsupportedError = try XCTUnwrap(unsupported["error"] as? [String: Any])
        XCTAssertEqual(unsupportedError["code"] as? Int, -32022)
        XCTAssertEqual(unsupportedError["message"] as? String, "UnsupportedProtocolVersion")
        XCTAssertEqual((unsupportedError["data"] as? [String: Any])?["supported"] as? [String],
                       ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
        XCTAssertEqual((unsupportedError["data"] as? [String: Any])?["requested"] as? String, "1900-01-01")

        let modernInitialize = try modernRequest(server, method: "initialize", params: ["protocolVersion": "2025-11-25"])
        XCTAssertEqual((modernInitialize["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testModernCapabilitiesAreStatelessPerRequest() throws {
        let server = MCPServer(reader: InMemoryNotes.sample())
        let withApps = try modernRequest(server, method: "tools/list", apps: true)
        let withTools = try XCTUnwrap((withApps["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(((withTools[0]["_meta"] as? [String: Any])?["ui"] as? [String: Any])?["resourceUri"] as? String,
                       MCPProtocol.widgetURI)

        let withoutApps = try modernRequest(server, method: "tools/list")
        let withoutTools = try XCTUnwrap((withoutApps["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertNil(withoutTools[0]["_meta"])
    }

    func testAppsNegotiationLinksAndServesASelfContainedWidget() throws {
        let server = MCPServer(reader: InMemoryNotes.sample())
        let resourcesResponse = try modernRequest(server, method: "resources/list", apps: true)
        let resources = try XCTUnwrap((resourcesResponse["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        XCTAssertEqual(resources.first { $0["uri"] as? String == MCPProtocol.widgetURI }?["mimeType"] as? String,
                       "text/html;profile=mcp-app")

        let readResponse = try modernRequest(server, method: "resources/read", params: ["uri": MCPProtocol.widgetURI], apps: true)
        let contents = try XCTUnwrap((readResponse["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        let widget = try XCTUnwrap(contents.first)
        XCTAssertEqual(widget["mimeType"] as? String, "text/html;profile=mcp-app")
        let html = try XCTUnwrap(widget["text"] as? String)
        XCTAssertTrue(html.contains("postMessage"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("fetch("))
        XCTAssertFalse(html.contains("XMLHttpRequest"))
        XCTAssertFalse(html.contains(".innerHTML"))
        XCTAssertTrue(html.contains("document.createElement('div')"))
        XCTAssertTrue(html.contains("title.textContent=label(x)"))
        XCTAssertTrue(html.contains("snippet.textContent=String(x.snippet)"))
        let hostileTitle = #"<img src=x onerror=parent.postMessage({stolen:true},'*')>"#
        XCTAssertFalse(html.contains(hostileTitle))
        XCTAssertTrue(html.contains("function label(x){return x.title"))
        XCTAssertEqual((((widget["_meta"] as? [String: Any])?["ui"] as? [String: Any])?["csp"] as? [String: Any])?["connectDomains"] as? [String], [])
        XCTAssertEqual((readResponse["result"] as? [String: Any])?["cacheScope"] as? String, "private")

        let callResponse = try modernRequest(server, method: "tools/call",
                                             params: ["name": "list_accounts", "arguments": [String: Any]()], apps: true)
        let callResult = try XCTUnwrap(callResponse["result"] as? [String: Any])
        let callMeta = try XCTUnwrap(callResult["_meta"] as? [String: Any])
        XCTAssertEqual((callMeta["ui"] as? [String: Any])?["resourceUri"] as? String, MCPProtocol.widgetURI)
        XCTAssertEqual((callMeta["net.notescli/ui"] as? [String: Any])?["view"] as? String, "notes")
        XCTAssertEqual((callMeta[MCPProtocol.serverInfoKey] as? [String: Any])?["name"] as? String, "notescli")

        let noApps = try modernRequest(server, method: "resources/list")
        let noAppResources = try XCTUnwrap((noApps["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        XCTAssertFalse(noAppResources.contains { $0["uri"] as? String == MCPProtocol.widgetURI })

        _ = try request(server, method: "initialize", params: ["protocolVersion": "2025-11-25", "capabilities": [String: Any]()])
        let legacyTools = try request(server, method: "tools/list", params: [:])
        let first = try XCTUnwrap(((legacyTools["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first)
        let legacyMeta = try XCTUnwrap(first["_meta"] as? [String: Any])
        XCTAssertEqual(legacyMeta["ui/resourceUri"] as? String, MCPProtocol.widgetURI)
        XCTAssertEqual(legacyMeta["openai/outputTemplate"] as? String, MCPProtocol.widgetURI)

        let modernMissing = try modernRequest(server, method: "resources/read", params: ["uri": "notes://missing"])
        XCTAssertEqual((modernMissing["error"] as? [String: Any])?["code"] as? Int, -32602)
        let legacyMissing = try request(server, method: "resources/read", params: ["uri": "notes://missing"])
        XCTAssertEqual((legacyMissing["error"] as? [String: Any])?["code"] as? Int, -32002)
    }

    func testRemoteExposureOmitsAndRejectsArbitraryPathInputs() throws {
        let local = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true)
        let remote = MCPServer(reader: InMemoryNotes.sample(), writer: InMemoryNotes.sample(), allowNative: true,
                               nativeHandler: { _, _ in try MCPNativeResult(value: ["ok": true]) },
                               exposureProfile: .remote)
        let localTools = try XCTUnwrap((try request(local, method: "tools/list", params: [:])["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let remoteTools = try XCTUnwrap((try request(remote, method: "tools/list", params: [:])["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let localNames = Set(localTools.compactMap { $0["name"] as? String })
        let remoteNames = Set(remoteTools.compactMap { $0["name"] as? String })
        let pathTools: Set<String> = ["save_attachment", "export_notes", "file_pull", "file_push", "file_diff", "sync_notes",
                                      "recording_add", "recording_create", "attach_file", "diagram_add", "drawing_add", "drawing_create"]
        XCTAssertTrue(pathTools.isSubset(of: localNames))
        XCTAssertTrue(pathTools.isDisjoint(with: remoteNames))
        for tool in remoteTools {
            let properties = ((tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
            XCTAssertTrue(Set(["path", "file", "output", "directory", "transcript_path"]).isDisjoint(with: properties.keys),
                          String(describing: tool["name"]))
        }

        let create = try XCTUnwrap(remoteTools.first { $0["name"] as? String == "create_note" })
        let createProperties = try XCTUnwrap((create["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNil(createProperties["attachments"])
        let transcribe = try XCTUnwrap(remoteTools.first { $0["name"] as? String == "recording_transcribe" })
        let transcribeProperties = try XCTUnwrap((transcribe["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNil(transcribeProperties["transcript_path"])

        let hiddenCall = try request(remote, method: "tools/call", params: [
            "name": "save_attachment", "arguments": ["ref": "welcome", "attachment_id": "x", "output": "/tmp/x"]
        ])
        XCTAssertEqual((hiddenCall["error"] as? [String: Any])?["code"] as? Int, -32602)
        let confinedCall = try request(remote, method: "tools/call", params: [
            "name": "create_note", "arguments": ["title": "No", "body": "No", "attachments": ["/etc/passwd"]]
        ])
        XCTAssertEqual((confinedCall["error"] as? [String: Any])?["message"] as? String, "Unknown argument: attachments")
    }

    func testConcurrentStdioKeepsPingResponsiveAndCancelsAQueuedWrite() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let calls = LockedBox(0)
        let server = MCPServer(reader: InMemoryNotes.sample(), allowNative: true, nativeHandler: { _, _ in
            calls.withValue { $0 += 1 }
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return try MCPNativeResult(result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "welcome")),
                                       value: ["ok": true])
        })
        let input = Pipe(), output = Pipe()
        let runFinished = expectation(description: "stdio run finished")
        DispatchQueue.global().async {
            server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting)
            runFinished.fulfill()
        }
        let received = LockedBox(Data())
        let pingReceived = expectation(description: "ping bypassed slow tool")
        let sawPing = LockedBox(false)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            received.withValue { $0.append(data) }
            if String(decoding: data, as: UTF8.self).contains("\"id\":3") {
                let first = sawPing.withValue { value -> Bool in
                    if value { return false }
                    value = true
                    return true
                }
                if first { pingReceived.fulfill() }
            }
        }
        func send(_ value: String) { input.fileHandleForWriting.write(Data((value + "\n").utf8)) }
        send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"pin_note","arguments":{"ref":"welcome"}}}"#)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"pin_note","arguments":{"ref":"welcome"}}}"#)
        send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2,"reason":"queued"}}"#)
        send(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
        wait(for: [pingReceived], timeout: 2)
        XCTAssertEqual(calls.withValue { $0 }, 1)
        release.signal()
        input.fileHandleForWriting.closeFile()
        wait(for: [runFinished], timeout: 5)
        output.fileHandleForReading.readabilityHandler = nil
        output.fileHandleForWriting.closeFile()

        let lines = String(decoding: received.withValue { $0 }, as: UTF8.self).split(separator: "\n")
        let responses = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(responses.compactMap { ($0["id"] as? NSNumber)?.intValue }, [3, 1])
        XCTAssertEqual(calls.withValue { $0 }, 1)
    }

    func testRunningReadCancellationSuppressesItsResponse() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = MCPServer(reader: InMemoryNotes.sample(), allowNative: true, nativeHandler: { _, _ in
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return try MCPNativeResult(value: ["items": [String]()])
        })
        let connection = server.makeConnection()
        let response = LockedBox<[String: Any]?>(nil)
        let finished = expectation(description: "cancelled read finished")
        DispatchQueue.global().async {
            response.withValue {
                $0 = server.handle(["jsonrpc": "2.0", "id": 14, "method": "tools/call",
                                    "params": ["name": "checklist_list", "arguments": ["ref": "welcome"]]],
                                   connection: connection)
            }
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "notifications/cancelled",
                                    "params": ["requestId": 14]], connection: connection))
        release.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertNil(response.withValue { $0 })
    }

    func testIndependentReadToolsExecuteInParallel() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = MCPServer(reader: InMemoryNotes.sample(), allowNative: true, nativeHandler: { _, _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return try MCPNativeResult(value: ["items": [String]()])
        })
        let connection = server.makeConnection()
        let completed = expectation(description: "parallel reads completed")
        completed.expectedFulfillmentCount = 2
        let succeeded = LockedBox(0)
        for id in [21, 22] {
            DispatchQueue.global().async {
                let response = server.handle(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                              "params": ["name": "checklist_list", "arguments": ["ref": "welcome"]]],
                                             connection: connection)
                if response?["result"] != nil { succeeded.withValue { $0 += 1 } }
                completed.fulfill()
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        release.signal()
        release.signal()
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(succeeded.withValue { $0 }, 2)
    }

    func testCancellationDoesNotInterruptAWriteJournalFinalization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-mcp-cancel-write-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = MCPServer(reader: InMemoryNotes.sample(), allowNative: true, nativeHandler: { _, arguments in
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return try MCPNativeResult(result: WriteResult(outcome: .verified,
                                                           noteID: NoteID(uuid: arguments["ref"] as? String ?? "welcome")),
                                       value: ["ok": true])
        }, stateRoot: root)
        let connection = server.makeConnection()
        let response = LockedBox<[String: Any]?>(nil)
        let finished = expectation(description: "write finished")
        DispatchQueue.global().async {
            response.withValue {
                $0 = server.handle(["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                    "params": ["name": "pin_note", "arguments": ["ref": "welcome"]]],
                                   connection: connection)
            }
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertNil(server.handle(["jsonrpc": "2.0", "method": "notifications/cancelled",
                                    "params": ["requestId": 9, "reason": "user stopped waiting"]],
                                   connection: connection))
        release.signal()
        wait(for: [finished], timeout: 5)
        let result = try XCTUnwrap(response.withValue { $0 }?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["_meta"] as? [String: Any])?["cancellationRequested"] as? Bool, true)
        let entries = try WriteJournal(url: root.appendingPathComponent("journal.sqlite")).list(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].outcome, .verified)
        XCTAssertTrue(try WriteJournal(url: root.appendingPathComponent("journal.sqlite")).unresolved().isEmpty)
    }
}
