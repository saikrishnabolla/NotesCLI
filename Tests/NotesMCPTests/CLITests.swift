import XCTest
import Foundation

final class CLITests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func run(_ args: [String], input: String = "", environment: [String: String] = [:]) throws -> (Int32, String, String) {
        let paths = [".build/debug/notescli", ".build/out/Products/Debug/notescli", ".build/arm64-apple-macosx/debug/notescli"]
        let binary = try XCTUnwrap(paths.map { root.appendingPathComponent($0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }, "Build notescli before running CLI tests")
        let process = Process(); process.executableURL = binary; process.arguments = args; process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8)); try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile(), err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-cli-home-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        return home
    }

    func testCapabilityHostStdioMCPUsesRemoteSafeToolExposure() throws {
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        let hiddenCall = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"save_attachment","arguments":{"ref":"welcome","attachment_id":"x","output":"/tmp/x"}}}"#
        let strippedField = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"create_note","arguments":{"title":"No","body":"No","attachments":["/etc/passwd"]}}}"#
        let result = try run(["--backend", "fake", "mcp", "--allow-native"],
                             input: [initialize, list, hiddenCall, strippedField].joined(separator: "\n") + "\n",
                             environment: ["NOTESCLI_HOST_ACTIVE": "1"])
        XCTAssertEqual(result.0, 0, result.2)
        let lines = result.1.split(separator: "\n")
        XCTAssertEqual(lines.count, 4, result.1)
        let responses = try lines.reduce(into: [Int: [String: Any]]()) { values, line in
            let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let id = try XCTUnwrap(response["id"] as? Int)
            values[id] = response
        }
        let response = try XCTUnwrap(responses[2])
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        let pathTools: Set<String> = [
            "save_attachment", "export_notes", "file_pull", "file_push", "file_diff", "sync_notes",
            "recording_add", "recording_create", "attach_file", "diagram_add", "drawing_add", "drawing_create",
        ]
        XCTAssertTrue(pathTools.isDisjoint(with: names))
        for tool in tools {
            let properties = ((tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
            XCTAssertTrue(Set(["path", "file", "output", "directory", "transcript_path"])
                .isDisjoint(with: properties.keys), String(describing: tool["name"]))
        }
        let create = try XCTUnwrap(tools.first { $0["name"] as? String == "create_note" })
        let createProperties = try XCTUnwrap((create["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNil(createProperties["attachments"])
        let hiddenResponse = try XCTUnwrap(responses[3])
        XCTAssertEqual((hiddenResponse["error"] as? [String: Any])?["code"] as? Int, -32602)
        let strippedResponse = try XCTUnwrap(responses[4])
        XCTAssertEqual((strippedResponse["error"] as? [String: Any])?["message"] as? String,
                       "Unknown argument: attachments")
    }

    func testDoctorAgentReadinessHasStableAccessContract() throws {
        let result = try run(["--backend", "fake", "doctor", "--for-agent", "--json"])
        XCTAssertEqual(result.0, 0, result.2)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [String: Any])
        let access = try XCTUnwrap(report["access"] as? [String: Any])
        let direct = try XCTUnwrap(access["direct"] as? [String: Any])
        let effective = try XCTUnwrap(access["effective"] as? [String: Any])
        let readiness = try XCTUnwrap(report["readiness"] as? [String: Any])
        XCTAssertNotNil(direct["available"] as? Bool)
        XCTAssertEqual(effective["available"] as? Bool, true)
        XCTAssertEqual(effective["fidelity"] as? String, "full")
        XCTAssertEqual(readiness["ready"] as? Bool, true)
        XCTAssertTrue(access.keys.contains("capabilityHost"))
    }

    func testOnboardCheckOnlyIsIdempotentAndDoesNotWriteState() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]

        let first = try run(["--backend", "fake", "onboard", "--check-only", "--json"], environment: environment)
        let second = try run(["--backend", "fake", "onboard", "--check-only", "--json"], environment: environment)
        XCTAssertEqual(first.0, 0, first.2)
        XCTAssertEqual(first.1, second.1)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(first.1.utf8)) as? [String: Any])
        XCTAssertEqual(report["checkOnly"] as? Bool, true)
        XCTAssertNotNil(report["complete"] as? Bool)
        let steps = try XCTUnwrap(report["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.first { $0["id"] as? String == "host-install" }?["status"] as? String, "not_available")
        XCTAssertEqual(steps.first { $0["id"] as? String == "host-ready" }?["required"] as? Bool, false)
        let state = home.appendingPathComponent("Library/Application Support/NotesCLI/onboarding.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testOnboardRecognizesArchiveLayoutCapabilityHost() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Applications/NotesCLI Capability Host.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]

        let result = try run(["--backend", "fake", "onboard", "--check-only", "--json"], environment: environment)
        XCTAssertEqual(result.0, 0, result.2)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [String: Any])
        let steps = try XCTUnwrap(report["steps"] as? [[String: Any]])
        let install = try XCTUnwrap(steps.first { $0["id"] as? String == "host-install" })
        XCTAssertEqual(install["required"] as? Bool, true)
        XCTAssertEqual(install["status"] as? String, "pending")
    }

    func testManifestUninstallDryRunAndOwnershipGuard() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]

        let installed = try run(["mcp", "install", "--client", "codex"], environment: environment)
        XCTAssertEqual(installed.0, 0, installed.2)
        let config = home.appendingPathComponent(".codex/config.toml")
        let before = try Data(contentsOf: config)

        let dryRun = try run(["mcp", "uninstall", "--client", "codex", "--dry-run", "--json"], environment: environment)
        XCTAssertEqual(dryRun.0, 0, dryRun.2)
        XCTAssertEqual(try Data(contentsOf: config), before)
        XCTAssertTrue(dryRun.1.contains("mcp_client"), dryRun.1)

        let removed = try run(["mcp", "uninstall", "--client", "codex", "--json"], environment: environment)
        XCTAssertEqual(removed.0, 0, removed.2)
        XCTAssertFalse((try String(contentsOf: config, encoding: .utf8)).contains("[mcp_servers.notescli]"))

        let reinstalled = try run(["mcp", "install", "--client", "codex"], environment: environment)
        XCTAssertEqual(reinstalled.0, 0, reinstalled.2)
        var modified = try String(contentsOf: config, encoding: .utf8)
        modified = modified.replacingOccurrences(of: #"args = ["mcp"]"#, with: #"args = ["mcp", "--read-only"]"#)
        try modified.write(to: config, atomically: true, encoding: .utf8)
        let refused = try run(["mcp", "uninstall", "--client", "codex", "--json"], environment: environment)
        XCTAssertNotEqual(refused.0, 0)
        XCTAssertTrue(refused.2.contains("uninstall_entry_modified"), refused.2)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), modified)
    }

    func testJSONMCPUninstallRemovesExactEntryAndPreservesModifiedEntry() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
        let config = home.appendingPathComponent(".cursor/mcp.json")

        let installed = try run(["mcp", "install", "--client", "cursor"], environment: environment)
        XCTAssertEqual(installed.0, 0, installed.2)
        let removed = try run(["mcp", "uninstall", "--client", "cursor", "--json"], environment: environment)
        XCTAssertEqual(removed.0, 0, removed.2)
        let removedRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertNil((removedRoot["mcpServers"] as? [String: Any])?["notescli"])

        let reinstalled = try run(["mcp", "install", "--client", "cursor"], environment: environment)
        XCTAssertEqual(reinstalled.0, 0, reinstalled.2)
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        var servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        var entry = try XCTUnwrap(servers["notescli"] as? [String: Any])
        entry["env"] = ["USER_OVERRIDE": "1"]
        servers["notescli"] = entry
        root["mcpServers"] = servers
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: config)
        let modified = try Data(contentsOf: config)

        let refused = try run(["mcp", "uninstall", "--client", "cursor", "--json"], environment: environment)
        XCTAssertNotEqual(refused.0, 0)
        XCTAssertTrue(refused.2.contains("uninstall_entry_modified"), refused.2)
        XCTAssertEqual(try Data(contentsOf: config), modified)
    }

    func testLegacyManifestDecodesButCannotAuthorizeMCPEntryRemoval() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = "[mcp_servers.notescli]\ncommand = \"notescli\"\nargs = [\"mcp\"]\n"
        try entry.write(to: config, atomically: true, encoding: .utf8)
        let support = home.appendingPathComponent("Library/Application Support/NotesCLI")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "owner": "NotesCLI",
            "mcpClients": [["client": "codex", "readOnly": false, "allowNative": false]],
            "files": [],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: support.appendingPathComponent("install-manifest.json"))

        let refused = try run(["mcp", "uninstall", "--client", "codex", "--json"], environment: environment)
        XCTAssertNotEqual(refused.0, 0)
        XCTAssertTrue(refused.2.contains("uninstall_ownership_unknown"), refused.2)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), entry)
    }

    func testMCPInstallPersistsAllowNativeForEveryFileBasedStdioClient() throws {
        let cases: [(String, String, String)] = [
            ("codex", ".codex/config.toml", ""),
            ("claude-desktop", "Library/Application Support/Claude/claude_desktop_config.json", "mcpServers"),
            ("cursor", ".cursor/mcp.json", "mcpServers"),
            ("vscode", "Library/Application Support/Code/User/mcp.json", "servers"),
        ]
        for (client, relativePath, serversKey) in cases {
            let home = try temporaryHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
            let result = try run(["mcp", "install", "--client", client, "--allow-native"], environment: environment)
            XCTAssertEqual(result.0, 0, "\(client): \(result.2)")
            let data = try Data(contentsOf: home.appendingPathComponent(relativePath))
            if serversKey.isEmpty {
                XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#"args = ["mcp", "--allow-native"]"#))
            } else {
                let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                let servers = try XCTUnwrap(root[serversKey] as? [String: Any])
                let notescli = try XCTUnwrap(servers["notescli"] as? [String: Any])
                XCTAssertEqual(notescli["args"] as? [String], ["mcp", "--allow-native"])
            }
        }
    }

    func testMCPInstallRejectsReadOnlyWithAllowNativeBeforeWritingConfig() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
        let result = try run(["mcp", "install", "--client", "codex", "--read-only", "--allow-native", "--json"], environment: environment)
        XCTAssertEqual(result.0, 2, result.2)
        XCTAssertTrue(result.2.contains("allow-native"), result.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
    }

    func testMCPInstallRejectsWriteFoldersForNonTailscaleClients() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
        let result = try run([
            "mcp", "install", "--client", "codex", "--write-folders", "Notes", "--json",
        ], environment: environment)
        XCTAssertEqual(result.0, 2, result.2)
        XCTAssertTrue(result.2.contains("tailscale"), result.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
    }

    func testMCPInstallRejectsMalformedTailscaleWriteFoldersBeforeSetup() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
        let result = try run([
            "mcp", "install", "--client", "tailscale", "--write-folders", "Notes >", "--json",
        ], environment: environment)
        XCTAssertEqual(result.0, 2, result.2)
        XCTAssertTrue(result.2.contains("write-folders"), result.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/NotesCLI/mcp-http.json").path))

        let whitespace = try run([
            "mcp", "install", "--client", "tailscale", "--write-folders", "   ", "--json",
        ], environment: environment)
        XCTAssertEqual(whitespace.0, 2, whitespace.2)
        XCTAssertTrue(whitespace.2.contains("write-folders"), whitespace.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/NotesCLI/mcp-http.json").path))

        let clearing = try run([
            "mcp", "install", "--client", "tailscale", "--write-folders", "", "--json",
        ], environment: environment)
        XCTAssertEqual(clearing.0, 1, clearing.1 + clearing.2)
        XCTAssertTrue((clearing.1 + clearing.2).contains("capability_host_required"), clearing.1 + clearing.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/NotesCLI/mcp-http.json").path))
    }

    func testTailscaleConfigVersionProtectsPersistedWritePolicy() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("Library/Application Support/NotesCLI/mcp-http.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let environment = [
            "HOME": home.path, "CFFIXED_USER_HOME": home.path,
            "NOTESCLI_BACKEND": "invalid", "NOTESCLI_CAPABILITY_HOST": "direct",
        ]
        func writeConfig(version: Int, writeFolders: String?) throws {
            var value: [String: Any] = [
                "version": version, "host": "127.0.0.1", "port": 17362, "path": "/notescli",
                "token": String(repeating: "t", count: 32), "tailscaleHostname": "notes.test.ts.net",
                "tailscaleIPs": [String](), "readOnly": false, "allowNative": true,
            ]
            if let writeFolders { value["writeFolders"] = writeFolders }
            try JSONSerialization.data(withJSONObject: value).write(to: config, options: .atomic)
        }

        try writeConfig(version: 1, writeFolders: nil)
        let legacy = try run(["mcp", "serve", "--http"], environment: environment)
        XCTAssertTrue(legacy.2.contains("invalid_backend"), legacy.2)

        try writeConfig(version: 2, writeFolders: "Notes")
        let protected = try run(["mcp", "serve", "--http"], environment: environment)
        XCTAssertTrue(protected.2.contains("invalid_backend"), protected.2)

        try writeConfig(version: 1, writeFolders: "Notes")
        let unsafeLegacy = try run(["mcp", "serve", "--http"], environment: environment)
        XCTAssertTrue(unsafeLegacy.2.contains("invalid_http_config"), unsafeLegacy.2)

        try writeConfig(version: 2, writeFolders: "   ")
        let emptyProtected = try run(["mcp", "serve", "--http"], environment: environment)
        XCTAssertTrue(emptyProtected.2.contains("invalid_http_config"), emptyProtected.2)
    }

    func testMCPInstallPassesAllowNativeToClaudeCode() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        let claude = bin.appendingPathComponent("claude")
        let log = home.appendingPathComponent("claude.log")
        try """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$CLAUDE_LOG"
            case "$1 $2" in
              "mcp get")
                /usr/bin/grep -q '"notescli"' "$HOME/.claude.json" 2>/dev/null
                exit $?
                ;;
              "mcp add")
                printf '{"mcpServers":{"notescli":{"args":["mcp","--allow-native"],"command":"%s"}}}\\n' "$7" > "$HOME/.claude.json"
                exit 0
                ;;
              "mcp remove")
                printf '{"mcpServers":{}}\\n' > "$HOME/.claude.json"
                exit 0
                ;;
            esac
            exit 1
            """
            .write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)
        let environment = [
            "HOME": home.path, "CFFIXED_USER_HOME": home.path,
            "PATH": bin.path + ":/usr/bin:/bin", "CLAUDE_LOG": log.path,
        ]

        let result = try run(["mcp", "install", "--client", "claude-code", "--allow-native"], environment: environment)
        XCTAssertEqual(result.0, 0, result.2)
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(calls.contains("mcp add --scope user notescli --"), calls)
        XCTAssertTrue(calls.contains("mcp --allow-native"), calls)

        let removed = try run(["mcp", "uninstall", "--client", "claude-code", "--json"], environment: environment)
        XCTAssertEqual(removed.0, 0, removed.2)
        let removedConfig = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".claude.json"))) as? [String: Any])
        XCTAssertNil((removedConfig["mcpServers"] as? [String: Any])?["notescli"])

        let reinstalled = try run(["mcp", "install", "--client", "claude-code", "--allow-native"], environment: environment)
        XCTAssertEqual(reinstalled.0, 0, reinstalled.2)
        let config = home.appendingPathComponent(".claude.json")
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        var servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        var entry = try XCTUnwrap(servers["notescli"] as? [String: Any])
        entry["args"] = ["mcp", "--read-only"]
        servers["notescli"] = entry
        root["mcpServers"] = servers
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: config)
        let modified = try Data(contentsOf: config)

        let refused = try run(["mcp", "uninstall", "--client", "claude-code", "--json"], environment: environment)
        XCTAssertNotEqual(refused.0, 0)
        XCTAssertTrue(refused.2.contains("uninstall_entry_modified"), refused.2)
        XCTAssertEqual(try Data(contentsOf: config), modified)
    }

    func testManifestUninstallKeepsConfigAndRefusesTamperedPaths() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
        let support = home.appendingPathComponent("Library/Application Support/NotesCLI")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let onboarding = support.appendingPathComponent("onboarding.json")
        try Data(#"{"schemaVersion":1,"steps":{}}"#.utf8).write(to: onboarding)
        let manifest = support.appendingPathComponent("install-manifest.json")
        func writeManifest(path: String) throws {
            let value: [String: Any] = [
                "schemaVersion": 1, "owner": "NotesCLI", "mcpClients": [],
                "files": [["path": path, "category": "config"]],
            ]
            try JSONSerialization.data(withJSONObject: value).write(to: manifest)
        }
        try writeManifest(path: onboarding.path)

        let kept = try run(["mcp", "uninstall", "--dry-run", "--keep-config", "--json"], environment: environment)
        XCTAssertEqual(kept.0, 0, kept.2)
        XCTAssertFalse(kept.1.contains(onboarding.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: onboarding.path))

        let outside = home.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        try writeManifest(path: outside.path)
        let refused = try run(["mcp", "uninstall", "--json"], environment: environment)
        XCTAssertNotEqual(refused.0, 0)
        XCTAssertTrue(refused.2.contains("uninstall_path_refused"), refused.2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        try writeManifest(path: onboarding.path)
        let removed = try run(["mcp", "uninstall", "--json"], environment: environment)
        XCTAssertEqual(removed.0, 0, removed.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: onboarding.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))

        let log = home.appendingPathComponent("Library/Logs/notescli-mcp-http.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("log".utf8).write(to: log)
        try writeManifest(path: log.path)
        let removedLog = try run(["mcp", "uninstall", "--json"], environment: environment)
        XCTAssertEqual(removedLog.0, 0, removedLog.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
    }
    func testGlobalOptionsAndParsing() throws {
        for args in [["--backend", "fake", "accounts", "--json"], ["accounts", "--backend", "fake", "--json"], ["--json", "--backend", "fake", "accounts"]] {
            let r = try run(args); XCTAssertEqual(r.0, 0, r.2)
            XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(r.1.utf8)) as? [[String: Any]])?.first?["name"] as? String, "Demo")
        }
        let env = try run(["accounts", "--json"], environment: ["NOTESCLI_BACKEND": "fake"])
        XCTAssertEqual(env.0, 0, env.2)
        for args in [["list", "--limit", "-1"], ["show", "welcome", "--format", "bogus"], ["append", "welcome"], ["add", "--body", "A", "--stdin"], ["list", "--since", "bad-date"], ["delete"]] {
            let r = try run(["--backend", "fake", "--json"] + args)
            XCTAssertEqual(r.0, 2, "\(args): \(r.2)")
            XCTAssertTrue(r.1.isEmpty)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(r.2.utf8)) as? [String: Any])
        }
        let usageBeforeBackend = try run(["--backend", "default", "add", "--body", "A", "--stdin", "--json"])
        XCTAssertEqual(usageBeforeBackend.0, 2)
        XCTAssertTrue(usageBeforeBackend.2.contains("usage"))
        let missing = try run(["--backend", "fake", "show", "absent", "--json"])
        XCTAssertEqual(missing.0, 3)
        XCTAssertTrue(missing.2.contains("note_not_found"))
        let confirmation = try run(["--backend", "fake", "delete", "welcome"])
        XCTAssertEqual(confirmation.0, 1)
        XCTAssertTrue(confirmation.2.contains("confirmation_required"))
    }
    func testFileInputsFromHiddenHomeFoldersAreRefused() throws {
        let hidden = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notescli-test-cli-input-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: hidden) }
        let markdown = hidden.appendingPathComponent("note.md")
        try Data("---\nnotes-id: welcome\n---\nSecret body\n".utf8).write(to: markdown)
        let exportOut = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: exportOut) }
        for args in [["file", "push", markdown.path, "--dry-run"], ["file", "diff", markdown.path],
                     ["add", "Title", "--file", markdown.path, "--dry-run"],
                     ["export", "--out", exportOut.path, "--template", markdown.path]] {
            let result = try run(["--backend", "fake", "--json"] + args)
            XCTAssertNotEqual(result.0, 0, "\(args): \(result.1)")
            XCTAssertTrue(result.2.contains("input_path_refused"), "\(args): \(result.2)")
        }
    }
    func testHomePinnedCapabilitiesHelpAndExamples() throws {
        let plain = try run([])
        XCTAssertEqual(plain.0, 0, plain.2)
        XCTAssertTrue(plain.1.contains("USAGE: notescli"), plain.1)
        XCTAssertFalse(plain.1.contains("Recently Edited"), plain.1)

        let json = try run(["--backend", "fake", "--json"])
        XCTAssertEqual(json.0, 0, json.2)
        let home = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.1.utf8)) as? [String: Any])
        XCTAssertEqual(home["version"] as? String, "1.1.3")
        XCTAssertEqual((home["recent"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((home["recent"] as? [[String: Any]])?.compactMap { $0["number"] as? Int }, [2, 1])
        XCTAssertEqual((home["recent"] as? [[String: Any]])?.map { $0.keys.sorted() },
                       [["folder", "modified", "number", "title"], ["folder", "modified", "number", "title"]])
        XCTAssertEqual((home["recent"] as? [[String: Any]])?.first?["title"] as? String, "Shopping")
        XCTAssertEqual((home["recent"] as? [[String: Any]])?.first?["folder"] as? String, "Notes")
        XCTAssertFalse(json.1.contains("Apples, coffee"), json.1)

        for (args, environment) in [(["--backend", "fake", "--json", "--no-recent"], [String: String]()),
                                    (["--backend", "fake", "--json"], ["NOTESCLI_HOME_RECENT": "0"])] {
            let hidden = try run(args, environment: environment)
            XCTAssertEqual(hidden.0, 0, hidden.2)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(hidden.1.utf8)) as? [String: Any])
            XCTAssertEqual((object["recent"] as? [Any])?.count, 0, "\(args) \(environment)")
        }

        let pinned = try run(["--backend", "fake", "pinned", "--limit", "1"])
        XCTAssertEqual(pinned.0, 0, pinned.2)
        XCTAssertTrue(pinned.1.contains("#1"), pinned.1)

        let capabilities = try run(["--backend", "fake", "capabilities", "--json"])
        XCTAssertEqual(capabilities.0, 0, capabilities.2)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(capabilities.1.utf8)) as? [String: Any])
        XCTAssertEqual((report["features"] as? [[String: Any]])?.count, 95)

        let help = try run(["help", "search"])
        XCTAssertEqual(help.0, 0, help.2)
        XCTAssertTrue(help.1.contains("EXAMPLES:"), help.1)
        XCTAssertTrue(help.1.contains("notescli search"), help.1)

        let typo = try run(["serach"])
        XCTAssertEqual(typo.0, 2)
        XCTAssertTrue(typo.2.contains("Did you mean 'search'?"), typo.2)
    }
    func testQuietSuppressesHumanOutputButNotErrors() throws {
        let quiet = try run(["--backend", "fake", "--quiet", "accounts"])
        XCTAssertEqual(quiet.0, 0, quiet.2)
        XCTAssertTrue(quiet.1.isEmpty)
        XCTAssertTrue(quiet.2.isEmpty)

        let failure = try run(["--backend", "fake", "--quiet", "show", "absent"])
        XCTAssertEqual(failure.0, 3)
        XCTAssertTrue(failure.1.isEmpty)
        XCTAssertTrue(failure.2.contains("note_not_found"))
    }
    func testAllWritesRefuseBeforeBackendOrEditor() throws {
        let commands = [["add"], ["append", "welcome", "--body", "x"], ["edit", "welcome"], ["rename", "welcome", "X"], ["move", "welcome", "Notes"], ["delete", "welcome", "--yes"], ["folder", "create", "X"], ["folder", "rename", "Notes", "X"], ["folder", "delete", "Notes", "--yes"]]
        for args in commands {
            let r = try run(["--read-only", "--json"] + args, environment: ["NOTESCLI_BACKEND": "default", "EDITOR": "false"])
            XCTAssertEqual(r.0, 4, "\(args): \(r.2)")
            XCTAssertTrue(r.2.contains("read_only"), "\(args): \(r.2)")
        }
    }

    func testReadOnlyAnchorCommandsRefuseWritesAndDoNotCreateState() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-anchor-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["CFFIXED_USER_HOME": home.path]
        let database = home.appendingPathComponent("Library/Application Support/NotesCLI/anchors.sqlite")

        for arguments in [["anchor", "add", "welcome", "--offset", "0"], ["anchor", "prune"]] {
            let result = try run(["--backend", "fake", "--read-only", "--json"] + arguments, environment: environment)
            XCTAssertEqual(result.0, 4, result.2)
            XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(result.2.utf8)) as? [String: Any])?["code"] as? String, "read_only")
        }

        let listed = try run(["--backend", "fake", "--read-only", "--json", "anchor", "list"], environment: environment)
        XCTAssertEqual(listed.0, 0, listed.2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(listed.1.utf8)) as? [Any])?.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))

        let resolved = try run(["--backend", "fake", "--read-only", "--json", "anchor", "resolve", "a-missing"], environment: environment)
        XCTAssertEqual(resolved.0, 3, resolved.2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(resolved.2.utf8)) as? [String: Any])?["code"] as? String, "anchor_not_found")
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    }

    func testReadOnlySafetyCommandsDoNotCreateJournalFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-safety-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["CFFIXED_USER_HOME": home.path]
        let support = home.appendingPathComponent("Library/Application Support/NotesCLI")
        let journalNames = ["journal.sqlite", "journal.sqlite-wal", "journal.sqlite-shm"]

        let list = try run(["--backend", "fake", "--read-only", "--json", "journal", "list"], environment: environment)
        XCTAssertEqual(list.0, 0, list.2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(list.1.utf8)) as? [Any])?.count, 0)

        for arguments in [["undo", "welcome"], ["revert", "welcome", "missing"], ["journal", "resolve"]] {
            let result = try run(["--backend", "fake", "--read-only", "--json"] + arguments, environment: environment)
            XCTAssertEqual(result.0, 4, "\(arguments): \(result.2)")
            XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(result.2.utf8)) as? [String: Any])?["code"] as? String,
                           "read_only")
        }

        let history = try run(["--backend", "fake", "--read-only", "--json", "history", "welcome"], environment: environment)
        XCTAssertEqual(history.0, 0, history.2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(history.1.utf8)) as? [Any])?.count, 0)

        let diff = try run(["--backend", "fake", "--read-only", "--json", "diff", "welcome"], environment: environment)
        XCTAssertEqual(diff.0, 3, diff.2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(diff.2.utf8)) as? [String: Any])?["code"] as? String,
                       "snapshot_not_found")
        XCTAssertEqual(journalNames.filter { FileManager.default.fileExists(atPath: support.appendingPathComponent($0).path) }, [])
    }

    func testCLIFormattingRejectsUnknownAndConflictingValuesBeforeDispatch() throws {
        let invalid = [
            (["format", "paragraph", "welcome", "--start", "0", "--length", "1", "--style", "body", "--alignment", "diagonal"], "diagonal"),
            (["format", "paragraph", "welcome", "--start", "0", "--length", "1", "--style", "body", "--writing-direction", "up"], "up"),
            (["format", "inline", "welcome", "--start", "0", "--length", "1", "--highlight", "green"], "green"),
            (["format", "inline", "welcome", "--start", "0", "--length", "1", "--superscript", "--subscript"], "Choose one of --superscript, --subscript, or --clear-script.")
        ]
        for (arguments, expected) in invalid {
            let result = try run(["--backend", "fake", "--engine", "native"] + arguments)
            XCTAssertEqual(result.0, 2, result.2)
            XCTAssertTrue(result.2.contains(expected), result.2)
            XCTAssertFalse(result.2.contains("native_unavailable"), result.2)
        }
    }
    func testDiagramCLIRejectsInvalidRenderOptionsBeforeNativeDispatch() throws {
        let invalid = [
            (["diagram", "add", "welcome", "--file", "/tmp/diagram.svg", "--scale", "4"], "Diagram scale must be 2 or 3."),
            (["diagram", "add", "welcome", "--file", "/tmp/diagram.svg", "--width", "0"], "Diagram width must be between 1 and 2400 pixels."),
            (["diagram", "add", "welcome", "--file", "/tmp/diagram.svg", "--background", "gray"], "gray")
        ]
        for (arguments, message) in invalid {
            let result = try run(["--backend", "fake"] + arguments)
            XCTAssertEqual(result.0, 2, result.2)
            XCTAssertTrue(result.2.contains(message), result.2)
            XCTAssertFalse(result.2.contains("native_unavailable"), result.2)
        }
    }
    func testFuzzyRankingAndDeterminism() throws {
        for query in ["cofee", "shoppng", "aples bread", "welcom", "NOTESCli"] {
            let args = ["--backend", "fake", "search", query, "--fuzzy", "--json"]
            let first = try run(args), second = try run(args)
            XCTAssertEqual(first.0, 0, first.2); XCTAssertEqual(first.1, second.1)
            let page = try JSONSerialization.jsonObject(with: Data(first.1.utf8)) as! [String: Any]
            let notes = page["notes"] as! [[String: Any]]
            XCTAssertEqual(notes.count, query == "shoppng" ? 2 : 1, query)
            XCTAssertEqual(notes.first?["title"] as? String, ["welcom", "NOTESCli"].contains(query) ? "Welcome" : "Shopping")
        }
        let ranked = try run(["--backend", "fake", "search", "shopping", "--fuzzy", "--json"])
        let ranking = (try JSONSerialization.jsonObject(with: Data(ranked.1.utf8)) as! [String: Any])["notes"] as! [[String: Any]]
        XCTAssertEqual(ranking.compactMap { $0["title"] as? String }, ["Shopping", "Welcome"])
        let limited = try run(["--backend", "fake", "search", "shopping", "--fuzzy", "--limit", "1", "--json"])
        let limitedPage = try JSONSerialization.jsonObject(with: Data(limited.1.utf8)) as! [String: Any]
        XCTAssertEqual((limitedPage["notes"] as! [Any]).count, 1)
        let cursor = try XCTUnwrap(limitedPage["nextCursor"] as? String)
        let continued = try run(["--backend", "fake", "search", "shopping", "--fuzzy", "--limit", "1", "--cursor", cursor, "--json"])
        let continuedPage = try JSONSerialization.jsonObject(with: Data(continued.1.utf8)) as! [String: Any]
        XCTAssertEqual((continuedPage["notes"] as! [Any]).count, 1)
        XCTAssertNil(continuedPage["nextCursor"])
        let absent = try run(["--backend", "fake", "search", "unrelated", "--fuzzy", "--json"])
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: Data(absent.1.utf8)) as! [String: Any])["notes"] as! [Any]).count, 0)
        let exact = try run(["--backend", "fake", "search", "cofee", "--json"])
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: Data(exact.1.utf8)) as! [String: Any])["notes"] as! [Any]).count, 0)
    }
    func testReadsWritesAndEditor() throws {
        let commands = [["folders", "--tree", "--account", "Demo"], ["list", "--folder", "Notes", "--account", "Demo", "--pinned", "--tag", "demo", "--since", "2020-01-01", "--until", "2030-01-01", "--limit", "1", "--include-deleted"], ["tags"], ["recent", "1"], ["show", "welcome", "--no-attachments"], ["add", "Draft", "--body", "Body"], ["append", "welcome", "--body", "More"], ["rename", "welcome", "New"], ["move", "welcome", "Notes"], ["delete", "welcome", "shopping", "--yes"], ["folder", "create", "Child", "--parent", "Notes", "--account", "Demo"], ["folder", "rename", "Notes", "Renamed"], ["folder", "delete", "Notes", "--yes"], ["open", "welcome"]]
        for args in commands { let r = try run(["--backend", "fake"] + args); XCTAssertEqual(r.0, 0, "\(args): \(r.2)") }
        for args in [["add", "Draft", "--stdin"], ["append", "welcome", "--stdin"]] {
            let r = try run(["--backend", "fake"] + args, input: "Body from stdin\n"); XCTAssertEqual(r.0, 0, r.2)
        }
        let unchanged = try run(["--backend", "fake", "edit", "welcome"], environment: ["EDITOR": "true"])
        XCTAssertEqual(unchanged.0, 0, unchanged.2); XCTAssertTrue(unchanged.1.contains("Unchanged")); XCTAssertTrue(unchanged.2.isEmpty)
        let changed = try run(["--backend", "fake", "edit", "welcome"], environment: ["EDITOR": "printf 'changed' >"])
        XCTAssertEqual(changed.0, 0, changed.2); XCTAssertFalse(changed.1.contains("Unchanged"))
        let addEditor = try run(["--backend", "fake", "add"], environment: ["EDITOR": "printf 'new body' >"])
        XCTAssertEqual(addEditor.0, 0, addEditor.2)
        let scripted = try run(["--backend", "fake", "--json", "add", "Engine", "--body", "Body"])
        let scriptedJSON = try JSONSerialization.jsonObject(with: Data(scripted.1.utf8)) as! [String: Any]
        XCTAssertEqual(scriptedJSON["engine"] as? String, "scripting")
        XCTAssertEqual((scriptedJSON["result"] as? [String: Any])?["outcome"] as? String, "verified")
        let folder = try run(["--backend", "fake", "--json", "folder", "create", "Engine folder"])
        let folderJSON = try JSONSerialization.jsonObject(with: Data(folder.1.utf8)) as! [[String: Any]]
        XCTAssertEqual(folderJSON.first?["engine"] as? String, "scripting")
        let batch = try run(["--backend", "fake", "--json", "delete", "welcome", "--yes"])
        let batchJSON = try JSONSerialization.jsonObject(with: Data(batch.1.utf8)) as! [[String: Any]]
        XCTAssertEqual(batchJSON.first?["engine"] as? String, "scripting")

        for command in [["open", "Demo", "--account"], ["open", "Notes", "--folder"]] {
            let value = try run(["--backend", "fake"] + command)
            XCTAssertEqual(value.0, 0, value.2)
        }
        let missingAttachment = try run(["--backend", "fake", "--json", "open", "welcome", "--attachment", "missing"])
        XCTAssertEqual(missingAttachment.0, 3)
        XCTAssertTrue(missingAttachment.2.contains("attachment_not_found"))
    }
    func testExportsAndFileInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.md"); try "File body".write(to: source, atomically: true, encoding: .utf8)
        let add = try run(["--backend", "fake", "add", "File", "--file", source.path]); XCTAssertEqual(add.0, 0, add.2)
        for format in ["markdown", "html", "json"] {
            let target = directory.appendingPathComponent(format)
            let r = try run(["--backend", "fake", "export", "--out", target.path, "--format", format, "--attachments", "--json"])
            XCTAssertEqual(r.0, 0, r.2)
            let paths = try JSONSerialization.jsonObject(with: Data(r.1.utf8)) as! [String]
            XCTAssertEqual(paths.count, 2)
            for path in paths {
                XCTAssertTrue(path.contains("/Notes/"))
                let text = try String(contentsOfFile: path, encoding: .utf8)
                for key in ["id", "title", "folder", "created", "modified", "tags"] { XCTAssertTrue(text.contains(key)) }
            }
        }
        let syncFile = directory.appendingPathComponent("welcome.md")
        let pull = try run(["--backend", "fake", "file", "pull", "welcome", syncFile.path])
        XCTAssertEqual(pull.0, 0, pull.2)
        var markdown = try String(contentsOf: syncFile, encoding: .utf8)
        markdown += "\nchanged\n"; try markdown.write(to: syncFile, atomically: true, encoding: .utf8)
        let denied = try run(["--backend", "fake", "file", "push", syncFile.path, "--write-folders", "Personal", "--json"])
        XCTAssertEqual(denied.0, 1, denied.2)
        XCTAssertTrue(denied.2.contains("write_not_allowed"), denied.2)
    }
    func testStdioMCPAndCompletion() throws {
        let requests = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"# + "\n" + #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n" + #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"
        let r = try run(["--backend", "fake", "--read-only", "mcp"], input: requests)
        XCTAssertEqual(r.0, 0, r.2)
        XCTAssertEqual(r.1.split(separator: "\n").count, 2)
        XCTAssertFalse(r.1.contains("create_note"))
        for shell in ["bash", "zsh", "fish"] {
            let completion = try run(["completion", shell]); XCTAssertEqual(completion.0, 0, completion.2); XCTAssertTrue(completion.1.contains("notescli"))
        }
    }

    func testUnifiedCommandTreeRoutesAndHidesLegacyNames() throws {
        let help = try run(["--help"])
        XCTAssertEqual(help.0, 0, help.2)
        for command in ["checklist", "pin", "unpin", "tag", "link", "deeplink", "text", "format", "attach", "attachment", "table", "duplicate", "restore", "write"] {
            XCTAssertTrue(help.1.contains("  \(command)"), command)
        }
        for legacy in ["native-checklist", "native-tag", "native-link", "native-text", "native-format", "native-attachment", "native-table", "native-duplicate", "native-restore", "native-move-folder", "write-markdown"] {
            XCTAssertFalse(help.1.contains("  \(legacy)"), legacy)
        }
        for route in [["checklist", "--help"], ["tag", "--help"], ["link", "--help"], ["text", "--help"], ["format", "--help"], ["attachment", "--help"], ["table", "--help"], ["folder", "--help"]] {
            let value = try run(route)
            XCTAssertEqual(value.0, 0, "\(route): \(value.2)")
        }
    }

    func testNativeWritesAreOptInAndLegacySyntaxStillParses() throws {
        let commands = [
            ["checklist", "add", "welcome", "item"], ["pin", "welcome"], ["unpin", "welcome"],
            ["tag", "add", "welcome", "demo"], ["link", "add", "welcome", "shopping"],
            ["text", "insert", "welcome", "x", "--position", "0"],
            ["format", "paragraph", "welcome", "--start", "0", "--length", "1", "--style", "body"],
            ["attach", "welcome", "/tmp/missing"], ["table", "create", "welcome", "--rows", "[[\"x\"]]"],
            ["duplicate", "welcome"], ["restore", "welcome"], ["folder", "move", "Notes", "Notes"]
        ]
        for command in commands {
            let value = try run(["--backend", "fake", "--json"] + command)
            XCTAssertNotEqual(value.0, 0, "\(command) unexpectedly succeeded")
            XCTAssertTrue(value.2.contains("native_required"), "\(command): \(value.2)")
        }
        let nativeReads = [
            ["checklist", "list", "welcome"], ["link", "list", "welcome"],
            ["text", "find", "welcome", "Welcome"],
            ["native-checklist", "list", "welcome"], ["native-link", "list", "welcome"],
            ["native-text", "search", "welcome", "--text", "Welcome"]
        ]
        for command in nativeReads {
            let value = try run(["--backend", "fake", "--json"] + command)
            XCTAssertTrue(value.2.contains("native_required"), "native read did not require opt-in: \(command): \(value.2)")
        }
        let aliases = [
            ["native-checklist", "insert", "welcome", "--text", "item"],
            ["native-tag", "add", "demo", "--ref", "welcome"],
            ["native-link", "add", "welcome", "--target", "shopping"],
            ["native-text", "insert", "welcome", "--text", "x", "--position", "0"],
            ["native-format", "paragraph", "welcome", "--start", "0", "--length", "1", "--style", "body"],
            ["native-attachment", "file", "welcome", "--path", "/tmp/missing"],
            ["native-table", "create", "welcome", "--rows", "[[\"x\"]]"],
            ["native-duplicate", "welcome"], ["native-restore", "welcome"],
            ["native-move-folder", "Notes", "--parent", "Notes"]
        ]
        for command in aliases {
            let value = try run(["--backend", "fake", "--json"] + command)
            XCTAssertTrue(value.2.contains("native_required"), "legacy syntax did not route: \(command): \(value.2)")
        }
        let env = try run(["--backend", "fake", "--json", "checklist", "add", "welcome", "item", "--dry-run"], environment: ["NOTESCLI_ENGINE": "native"])
        XCTAssertFalse(env.2.contains("native_required"), env.2)
        XCTAssertFalse(env.2.contains("usage"), env.2)
        let explicit = try run(["--backend", "fake", "--engine=native", "--json", "checklist", "add", "welcome", "item", "--dry-run"], environment: ["NOTESCLI_ENGINE": "scripting"])
        XCTAssertEqual(explicit.0, 0, explicit.2)
        XCTAssertTrue(explicit.1.contains(#""engine":"native""#), explicit.1)
    }
}
