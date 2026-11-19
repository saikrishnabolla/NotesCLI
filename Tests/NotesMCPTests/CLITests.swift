import CoreGraphics
import CryptoKit
import XCTest
import Foundation
import ImageIO
import NotesSafety
import UniformTypeIdentifiers

final class CLITests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func run(_ args: [String], input: String = "", environment: [String: String] = [:]) throws -> (Int32, String, String) {
        let paths = [".build/debug/notescli", ".build/out/Products/Debug/notescli", ".build/arm64-apple-macosx/debug/notescli"]
        let binary = try XCTUnwrap(paths.map { root.appendingPathComponent($0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }, "Build notescli before running CLI tests")
        let process = Process(); process.executableURL = binary; process.arguments = args; process.currentDirectoryURL = root
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["NOTESCLI_CAPABILITY_HOST"] = "direct"
        process.environment = processEnvironment.merging(environment) { _, new in new }
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
    private func writeImage(to url: URL, value: UInt8) throws -> Data {
        let width = 8, height = 6
        var bytes = [UInt8](repeating: value, count: width * height * 4)
        for offset in stride(from: 3, to: bytes.count, by: 4) { bytes[offset] = 255 }
        let image = try XCTUnwrap(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try Data(contentsOf: url)
    }

    func testAppendRecordsSnapshotAndJournalPreimage() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]

        let append = try run(["--backend", "fake", "--json", "append", "welcome", "--body", "More"],
                             environment: environment)
        XCTAssertEqual(append.0, 0, append.2)

        let support = home.appendingPathComponent("Library/Application Support/NotesCLI")
        let entry = try XCTUnwrap(WriteJournal(url: support.appendingPathComponent("journal.sqlite")).list(limit: 1).first)
        XCTAssertEqual(entry.operation, "appendToNote")
        let snapshotID = try XCTUnwrap(entry.snapshotID)

        let history = try run(["--backend", "fake", "--json", "history", "welcome"], environment: environment)
        XCTAssertEqual(history.0, 0, history.2)
        let snapshots = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(history.1.utf8)) as? [[String: Any]])
        XCTAssertEqual(snapshots.map { $0["id"] as? String }, [snapshotID])
    }

    func testScanCommandIsRegisteredAndRequiresImagePages() throws {
        let help = try run(["scan", "add", "--help"])
        XCTAssertEqual(help.0, 0, help.2)
        XCTAssertTrue(help.1.contains("Create a native scanned document"))
        XCTAssertTrue(help.1.contains("<images>"))
        XCTAssertTrue(help.1.contains("--perspective-correct"), help.1)

        let appendHelp = try run(["scan", "append", "--help"])
        XCTAssertEqual(appendHelp.0, 0, appendHelp.2)
        XCTAssertTrue(appendHelp.1.contains("--perspective-correct"), appendHelp.1)

        let cropHelp = try run(["scan", "crop", "--help"])
        XCTAssertEqual(cropHelp.0, 0, cropHelp.2)
        XCTAssertTrue(cropHelp.1.contains("--detect-edges"), cropHelp.1)

        let missing = try run(["--backend", "fake", "scan", "add", "welcome"])
        XCTAssertNotEqual(missing.0, 0)
        XCTAssertTrue(missing.2.contains("Provide between 1 and 100 image pages"), missing.2)

        let mixedCrop = try run([
            "--backend", "fake", "scan", "crop", "welcome", "gallery", "page", "--detect-edges",
            "--bottom-left", "0,1", "--bottom-right", "1,1", "--top-left", "0,0", "--top-right", "1,0",
        ])
        XCTAssertNotEqual(mixedCrop.0, 0)
        XCTAssertTrue(mixedCrop.2.contains("Choose either --detect-edges or all four crop points"), mixedCrop.2)

        let crossedCrop = try run([
            "--backend", "fake", "--engine", "native", "scan", "crop", "welcome", "gallery", "page",
            "--bottom-left", "0,1", "--bottom-right", "1,0", "--top-left", "0,0", "--top-right", "1,1",
        ])
        XCTAssertNotEqual(crossedCrop.0, 0)
        XCTAssertTrue(crossedCrop.2.contains("unsafe_scan_geometry"), crossedCrop.2)
    }

    func testCameraCaptureStartsOnlyAfterDryRunAndWriteSafetyChecks() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-camera-must-not-read-" + UUID().uuidString + ".png").path

        for command in ["photo", "scan"] {
            let dryRun = try run([
                "--backend", "fake", "--engine", "native", "--json", "camera", command, "welcome",
                "--source-image", missing, "--dry-run",
            ])
            XCTAssertEqual(dryRun.0, 0, "\(command): \(dryRun.2)")
            let plan = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(dryRun.1.utf8)) as? [String: Any])
            XCTAssertEqual(plan["dryRun"] as? Bool, true)
            XCTAssertEqual(plan["operation"] as? String, command == "photo" ? "cameraPhoto" : "cameraScan")

            let refused = try run([
                "--backend", "fake", "--engine", "native", "--json", "camera", command, "welcome",
                "--source-image", missing, "--write-folders", "Personal",
            ])
            XCTAssertNotEqual(refused.0, 0, command)
            XCTAssertTrue(refused.2.contains("write_not_allowed"), "\(command): \(refused.2)")
            XCTAssertFalse(refused.2.contains("camera source image"), "\(command): \(refused.2)")
        }
    }

    func testLockedAttachmentExportRequiresStdinPasswordAndSaveDirectory() throws {
        let help = try run(["attachments", "--help"])
        XCTAssertEqual(help.0, 0, help.2)
        XCTAssertTrue(help.1.contains("--password-stdin"), help.1)
        XCTAssertTrue(help.1.contains("--save"), help.1)

        let secret = "cli-password-must-not-appear"
        let missingSave = try run(
            ["--backend", "fake", "attachments", "welcome", "--password-stdin"],
            input: secret + "\n")
        XCTAssertNotEqual(missingSave.0, 0)
        XCTAssertTrue(missingSave.2.contains("--password-stdin requires --save"), missingSave.2)
        XCTAssertFalse((missingSave.1 + missingSave.2).contains(secret))

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-locked-cli-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let unavailable = try run(
            ["--backend", "fake", "attachments", "welcome", "--password-stdin", "--save", output.path],
            input: secret + "\n")
        XCTAssertNotEqual(unavailable.0, 0)
        XCTAssertTrue(unavailable.2.contains("Locked attachment export requires the full read backend"), unavailable.2)
        XCTAssertFalse((unavailable.1 + unavailable.2).contains(secret))

        let unlocked = try run(["--backend", "fake", "--json", "attachments", "welcome"])
        XCTAssertEqual(unlocked.0, 0, unlocked.2)
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
        XCTAssertTrue(names.contains("scan_add"))
        XCTAssertTrue(names.contains("ocr_attachment"))
        XCTAssertTrue(names.contains("map_add"))
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

    func testFakeBackendNeverRoutesThroughCapabilityHost() throws {
        for arguments in [["--backend", "fake", "--json", "accounts"], ["--backend=fake", "--json", "accounts"]] {
            let result = try run(arguments, environment: ["NOTESCLI_CAPABILITY_HOST": "force"])
            XCTAssertEqual(result.0, 0, result.2)
            let accounts = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [[String: Any]])
            XCTAssertEqual(accounts.first?["name"] as? String, "Demo")
        }
        let environmentResult = try run(["--json", "accounts"], environment: [
            "NOTESCLI_CAPABILITY_HOST": "force", "NOTESCLI_BACKEND": "fake",
        ])
        XCTAssertEqual(environmentResult.0, 0, environmentResult.2)
    }

    func testDoctorAgentReadinessHasStableAccessContract() throws {
        let result = try run(["--backend", "fake", "doctor", "--for-agent", "--json"])
        XCTAssertEqual(result.0, 0, result.2)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [String: Any])
        let access = try XCTUnwrap(report["access"] as? [String: Any])
        let direct = try XCTUnwrap(access["direct"] as? [String: Any])
        let effective = try XCTUnwrap(access["effective"] as? [String: Any])
        let readiness = try XCTUnwrap(report["readiness"] as? [String: Any])
        let permissions = try XCTUnwrap(report["permissions"] as? [String: Any])
        XCTAssertNotNil(direct["available"] as? Bool)
        XCTAssertEqual(effective["available"] as? Bool, true)
        XCTAssertEqual(effective["fidelity"] as? String, "full")
        XCTAssertEqual(readiness["ready"] as? Bool, true)
        XCTAssertTrue(access.keys.contains("capabilityHost"))
        for name in ["fullDiskAccess", "notesAutomation", "speechRecognition", "camera"] {
            let permission = try XCTUnwrap(permissions[name] as? [String: Any])
            XCTAssertNotNil(permission["status"] as? String)
            XCTAssertNotNil(permission["required"] as? Bool)
        }
    }

    func testMCPStatusHasStableJSONForTheControlCenter() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try run(["mcp", "status", "--json"], environment: [
            "HOME": home.path, "CFFIXED_USER_HOME": home.path,
        ])
        XCTAssertEqual(result.0, 0, result.2)
        let reports = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [[String: Any]])
        XCTAssertEqual(Set(reports.compactMap { $0["client"] as? String }),
                       ["claude-code", "claude-desktop", "codex", "cursor", "vscode", "tailscale"])
        for report in reports {
            XCTAssertNotNil(report["label"] as? String)
            XCTAssertNotNil(report["status"] as? String)
            XCTAssertNotNil(report["available"] as? Bool)
            XCTAssertNotNil(report["connected"] as? Bool)
        }
        let tailscale = try XCTUnwrap(reports.first { $0["client"] as? String == "tailscale" })
        XCTAssertNotNil(tailscale["read_only"] as? Bool)
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
        XCTAssertEqual(steps.first { $0["id"] as? String == "mcp-install" }?["status"] as? String, "pending")
        XCTAssertEqual(steps.first { $0["id"] as? String == "host-install" }?["status"] as? String, "not_available")
        XCTAssertEqual(steps.first { $0["id"] as? String == "host-ready" }?["required"] as? Bool, false)
        let state = home.appendingPathComponent("Library/Application Support/NotesCLI/onboarding.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testOnboardKeepsDeliberatelyDisconnectedClientsComplete() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/NotesCLI", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"steps":{"mcp-install":"complete"}}"#.utf8)
            .write(to: support.appendingPathComponent("onboarding.json"))
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]

        let result = try run(["--backend", "fake", "onboard", "--check-only", "--json"], environment: environment)
        XCTAssertEqual(result.0, 0, result.2)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [String: Any])
        let steps = try XCTUnwrap(report["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.first { $0["id"] as? String == "mcp-install" }?["status"] as? String, "complete")
    }

    func testOnboardRecognizesInstalledNotesCLIApp() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Applications/Notes CLI.app")
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

    func testOnboardRecognizesLegacyAppForMigration() throws {
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
        modified = modified.replacingOccurrences(of: #"args = ["mcp", "--allow-native"]"#, with: #"args = ["mcp", "--read-only"]"#)
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

    func testMCPUninstallAllPreservesNotesCLIAppAndNonMCPFiles() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]

        let installed = try run(["mcp", "install", "--client", "codex"], environment: environment)
        XCTAssertEqual(installed.0, 0, installed.2)

        let app = home.appendingPathComponent("Applications/Notes CLI.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let support = home.appendingPathComponent("Library/Application Support/NotesCLI")
        let onboarding = support.appendingPathComponent("onboarding.json")
        try Data(#"{"schemaVersion":1,"steps":{}}"#.utf8).write(to: onboarding)
        let manifest = support.appendingPathComponent("install-manifest.json")
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var files = root["files"] as? [[String: Any]] ?? []
        files.append(["path": onboarding.path, "category": "config"])
        root["files"] = files
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)

        let removed = try run(["mcp", "uninstall", "--client", "all", "--json"], environment: environment)
        XCTAssertEqual(removed.0, 0, removed.2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: onboarding.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertFalse(removed.1.contains(app.path), removed.1)
        let config = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertFalse(config.contains("[mcp_servers.notescli]"))
    }

    func testMCPUninstallAllDryRunListsTailscaleFiles() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
        let support = home.appendingPathComponent("Library/Application Support/NotesCLI")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let paths = [
            support.appendingPathComponent("mcp-http.json").path,
            home.appendingPathComponent("Library/LaunchAgents/com.saikrishnabolla.notescli.mcp-http.plist").path,
            home.appendingPathComponent("Library/Logs/notescli-mcp-http.log").path,
        ]
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "owner": "NotesCLI",
            "mcpClients": [["client": "tailscale", "readOnly": false, "allowNative": true]],
            "files": paths.map { ["path": $0, "category": "runtime"] },
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: support.appendingPathComponent("install-manifest.json"))

        let result = try run(["mcp", "uninstall", "--client", "all", "--dry-run", "--json"], environment: environment)
        XCTAssertEqual(result.0, 0, result.2)
        let actions = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [[String: Any]])
        let listed = Set(actions.filter { $0["kind"] as? String == "file" }.compactMap { $0["target"] as? String })
        XCTAssertEqual(listed, Set(paths))
        XCTAssertFalse(actions.contains { $0["kind"] as? String == "capability_host" })
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

    func testMCPInstallEnablesNativeForEveryWriteEnabledStdioClientByDefault() throws {
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
            let result = try run(["mcp", "install", "--client", client], environment: environment)
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

        let kept = try run(["uninstall", "--dry-run", "--keep-config", "--json"], environment: environment)
        XCTAssertEqual(kept.0, 0, kept.2)
        XCTAssertFalse(kept.1.contains(onboarding.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: onboarding.path))

        let outside = home.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        try writeManifest(path: outside.path)
        let refused = try run(["uninstall", "--json"], environment: environment)
        XCTAssertNotEqual(refused.0, 0)
        XCTAssertTrue(refused.2.contains("uninstall_path_refused"), refused.2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        try writeManifest(path: onboarding.path)
        let removed = try run(["uninstall", "--json"], environment: environment)
        XCTAssertEqual(removed.0, 0, removed.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: onboarding.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))

        let log = home.appendingPathComponent("Library/Logs/notescli-mcp-http.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("log".utf8).write(to: log)
        try writeManifest(path: log.path)
        let removedLog = try run(["uninstall", "--json"], environment: environment)
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
        let locked = try run(["--backend", "fake", "show", "welcome", "--password-stdin", "--no-attachments", "--json"],
                             input: "never-print-this-password\n")
        XCTAssertNotEqual(locked.0, 0)
        XCTAssertTrue(locked.2.contains("locked_note_full_access_required"), locked.2)
        XCTAssertFalse(locked.1.contains("never-print-this-password"))
        XCTAssertFalse(locked.2.contains("never-print-this-password"))
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
        XCTAssertEqual(home["version"] as? String, "1.1.12")
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
        XCTAssertEqual((report["features"] as? [[String: Any]])?.count, 96)

        let blocked = try run(["--backend", "fake", "capabilities", "--write", "Print", "--json"])
        XCTAssertNotEqual(blocked.0, 0)
        let blockedError = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(blocked.2.utf8)) as? [String: Any])
        XCTAssertEqual(blockedError["code"] as? String, "apple_blocked")
        XCTAssertTrue((blockedError["message"] as? String)?.contains("blocked by Apple") == true)

        let forcedHost = try run(["capabilities", "--json"], environment: ["NOTESCLI_CAPABILITY_HOST": "force"])
        XCTAssertEqual(forcedHost.0, 0, forcedHost.2)
        let forcedReport = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(forcedHost.1.utf8)) as? [String: Any])
        let forcedFeatures = try XCTUnwrap(forcedReport["features"] as? [[String: Any]])
        XCTAssertEqual(forcedFeatures.count, 96)
        XCTAssertNotNil(forcedFeatures.first { $0["feature"] as? String == "Print" }?["reasons"])

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

    func testParityCommandsValidateBeforeNativeDispatch() throws {
        let map = try run(["--backend", "fake", "map", "add", "welcome", "https://example.com/map"])
        XCTAssertEqual(map.0, 2, map.2)
        XCTAssertTrue(map.2.contains("invalid_map_url"), map.2)
        XCTAssertFalse(map.2.contains("native_unavailable"), map.2)

        let style = try run(["--backend", "fake", "settings", "default-style", "--set", "caption"])
        XCTAssertEqual(style.0, 2, style.2)
        XCTAssertTrue(style.2.contains("caption"), style.2)

        let grouping = try run(["--backend", "fake", "folder", "group-by-date", "Notes", "--enabled", "maybe"])
        XCTAssertEqual(grouping.0, 2, grouping.2)
        XCTAssertTrue(grouping.2.contains("maybe"), grouping.2)
    }

    func testNativeSettingsCLIValidatesAndSerializesValues() throws {
        let show = try run(["--backend", "fake", "--engine=native", "--json", "settings", "show"])
        XCTAssertEqual(show.0, 0, show.2)
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(show.1.utf8)) as? [String: Any])
        XCTAssertEqual(settings["sort"] as? String, "modified")
        XCTAssertEqual(settings["groupsByDate"] as? Bool, true)
        XCTAssertEqual(settings["defaultTextSize"] as? Int, 12)
        XCTAssertEqual(settings["resumesLastQuickNote"] as? Bool, true)
        XCTAssertEqual(settings["autoConvertsToTags"] as? Bool, true)

        let cases: [([String], String, [String: String])] = [
            (["sort", "--set", "title"], "globalNoteSort",
             ["sort": "title", "previous_sort": "modified", "engine": "native"]),
            (["group-by-date", "--enabled", "false"], "globalDateGrouping",
             ["enabled": "false", "previous_enabled": "true", "engine": "native"]),
            (["default-text-size", "--points", "24"], "defaultTextSize",
             ["points": "24", "previous_points": "12", "engine": "native"]),
            (["resume-quick-note", "--enabled", "false"], "resumeLastQuickNote",
             ["enabled": "false", "previous_enabled": "true", "engine": "native"]),
            (["auto-convert-tags", "--enabled", "false"], "autoConvertToTags",
             ["enabled": "false", "previous_enabled": "true", "engine": "native"]),
        ]
        for (arguments, operation, expectedArguments) in cases {
            let result = try run(["--backend", "fake", "--engine=native", "--json", "settings"]
                                 + arguments + ["--dry-run"])
            XCTAssertEqual(result.0, 0, result.2)
            let plan = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [String: Any])
            XCTAssertEqual(plan["dryRun"] as? Bool, true)
            XCTAssertEqual(plan["operation"] as? String, operation)
            XCTAssertEqual(plan["target"] as? String, "Notes settings")
            XCTAssertEqual(plan["engine"] as? String, "native")
            XCTAssertEqual(plan["arguments"] as? [String: String], expectedArguments)
        }

        let invalidSort = try run(["--backend", "fake", "settings", "sort", "--set", "alphabetical"])
        XCTAssertEqual(invalidSort.0, 2, invalidSort.2)
        XCTAssertTrue(invalidSort.2.contains("alphabetical"), invalidSort.2)

        let invalidSize = try run(["--backend", "fake", "settings", "default-text-size", "--points", "16"])
        XCTAssertEqual(invalidSize.0, 2, invalidSize.2)
        XCTAssertTrue(invalidSize.2.contains("Use 10, 12, 14, 18, or 24 points."), invalidSize.2)

        let invalidAutoConvert = try run(["--backend", "fake", "settings", "auto-convert-tags", "--enabled", "maybe"])
        XCTAssertEqual(invalidAutoConvert.0, 2, invalidAutoConvert.2)
        XCTAssertTrue(invalidAutoConvert.2.contains("maybe"), invalidAutoConvert.2)
    }

    func testQuickNoteCLIProducesExactCreateAndSetPlans() throws {
        let create = try run(["--backend", "fake", "--engine=native", "--json", "quick-note", "create",
                              "Research", "--body", "# Findings", "--folder", "Notes", "--dry-run"])
        XCTAssertEqual(create.0, 0, create.2)
        let createPlan = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(create.1.utf8)) as? [String: Any])
        XCTAssertEqual(createPlan["operation"] as? String, "createQuickNote")
        XCTAssertEqual(createPlan["target"] as? String, "Research")
        XCTAssertEqual(createPlan["engine"] as? String, "native")
        XCTAssertEqual(createPlan["arguments"] as? [String: String], [
            "title": "Research", "body": "# Findings", "folder": "Notes", "engine": "native",
        ])
        XCTAssertEqual(createPlan["resultingHTML"] as? String, "<h1>Research</h1><h1>Findings</h1>")

        let set = try run(["--backend", "fake", "--engine=native", "--json", "quick-note", "set",
                           "welcome", "--enabled", "true", "--dry-run"])
        XCTAssertEqual(set.0, 0, set.2)
        let setPlan = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(set.1.utf8)) as? [String: Any])
        XCTAssertEqual(setPlan["operation"] as? String, "setQuickNote")
        XCTAssertEqual(setPlan["target"] as? String, "welcome")
        XCTAssertEqual(setPlan["engine"] as? String, "native")
        XCTAssertEqual(setPlan["arguments"] as? [String: String], [
            "ref": "welcome", "enabled": "true", "previous_enabled": "false", "engine": "native",
        ])

        let missingEnabled = try run(["--backend", "fake", "--engine=native", "quick-note", "set", "welcome"])
        XCTAssertEqual(missingEnabled.0, 2, missingEnabled.2)
        XCTAssertTrue(missingEnabled.2.contains("--enabled"), missingEnabled.2)

        let conflictingBody = try run(["--backend", "fake", "--engine=native", "quick-note", "create",
                                       "Research", "--body", "body", "--stdin"])
        XCTAssertEqual(conflictingBody.0, 2, conflictingBody.2)
        XCTAssertTrue(conflictingBody.2.contains("Choose only one of --body, --stdin, or --file."), conflictingBody.2)
    }

    func testFakeBackendScanAndMapNeverReachNativeWriterAndJournalHashesImages() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["CFFIXED_USER_HOME": home.path]
        let images = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-scan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: images) }
        let first = images.appendingPathComponent("page,one.png"), second = images.appendingPathComponent("page two.png")
        let firstData = try writeImage(to: first, value: 40)
        let secondData = try writeImage(to: second, value: 180)
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

        let dryRun = try run([
            "--backend", "fake", "--engine=native", "--json", "scan", "add", "welcome",
            first.path, "--perspective-correct", "--dry-run",
        ], environment: environment)
        XCTAssertEqual(dryRun.0, 0, dryRun.2)
        let dryRunPlan = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(dryRun.1.utf8)) as? [String: Any])
        let dryRunArguments = try XCTUnwrap(dryRunPlan["arguments"] as? [String: String])
        XCTAssertEqual(dryRunArguments["source_page_sha256"], sha(firstData))
        XCTAssertEqual(dryRunArguments["page_sha256"], "")
        XCTAssertEqual(dryRunArguments["perspective_correct"], "true")

        // "welcome" exists only in the fake store, so a native write could not succeed.
        let scan = try run(["--backend", "fake", "--engine=native", "--json", "scan", "add", "welcome", first.path, second.path],
                           environment: environment)
        XCTAssertEqual(scan.0, 0, scan.2)
        let scanResult = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(scan.1.utf8)) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(scanResult["outcome"] as? String, "unverified")
        XCTAssertTrue((scanResult["message"] as? String ?? "").contains("fake backend"), scan.1)

        for arguments in [
            ["scan", "filter", "welcome", "gallery", "page", "color"],
            ["scan", "rotate", "welcome", "gallery", "page", "right"],
            ["scan", "move", "welcome", "gallery", "page", "0"],
        ] {
            let edited = try run(["--backend", "fake", "--engine=native", "--json"] + arguments,
                                 environment: environment)
            XCTAssertEqual(edited.0, 0, "\(arguments): \(edited.2)")
            let result = try XCTUnwrap(
                (try JSONSerialization.jsonObject(with: Data(edited.1.utf8)) as? [String: Any])?["result"] as? [String: Any]
            )
            XCTAssertEqual(result["outcome"] as? String, "unverified")
            XCTAssertTrue((result["message"] as? String ?? "").contains("Apple Notes was not changed"))
        }
        let invalidMove = try run(["--backend", "fake", "--engine=native", "--json", "scan", "move",
                                   "welcome", "gallery", "page", "1"], environment: environment)
        XCTAssertNotEqual(invalidMove.0, 0)
        XCTAssertTrue(invalidMove.2.contains("invalid_scan_page_index"), invalidMove.2)

        let map = try run(["--backend", "fake", "--engine=native", "--json", "map", "add", "welcome", "https://maps.apple.com/?q=Cupertino"],
                          environment: environment)
        XCTAssertEqual(map.0, 0, map.2)
        let mapResult = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(map.1.utf8)) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(mapResult["outcome"] as? String, "unverified")

        let list = try run(["--backend", "fake", "--json", "journal", "list"], environment: environment)
        XCTAssertEqual(list.0, 0, list.2)
        let entries = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(list.1.utf8)) as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first { $0["operation"] as? String == "scanAdd" })
        let encoded = try XCTUnwrap(entry["arguments"] as? String)
        let rawArguments = try XCTUnwrap(Data(base64Encoded: encoded))
        let arguments = try XCTUnwrap(try JSONSerialization.jsonObject(with: rawArguments) as? [String: String])
        XCTAssertNil(arguments["images"])
        XCTAssertEqual(arguments["page_count"], "2")
        let hashes = [sha(firstData), sha(secondData)]
        XCTAssertEqual(arguments["source_page_sha256"]?.split(separator: ",").map(String.init), hashes)
        XCTAssertEqual(arguments["page_sha256"]?.split(separator: ",").map(String.init), hashes)
        XCTAssertNil(arguments["source_image_sha256"])
        XCTAssertNil(arguments["image_sha256"])
        XCTAssertFalse(String(decoding: rawArguments, as: UTF8.self).contains(images.lastPathComponent))
    }

    func testFakeBackendParitySettingsNeverReachNativePreferencesOrFolders() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let preferences = home.appendingPathComponent(
            "Library/Group Containers/group.com.apple.notes/Library/Preferences/group.com.apple.notes.plist"
        )
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let sentinel = Data("fake-backend-sentinel".utf8)
        try sentinel.write(to: preferences)
        let environment = ["CFFIXED_USER_HOME": home.path]

        let style = try run(["--backend", "fake", "--engine=native", "--json", "settings", "default-style",
                             "--set", "body"], environment: environment)
        XCTAssertEqual(style.0, 0, style.2)
        let styleResult = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(style.1.utf8)) as? [String: Any])?["result"] as? [String: Any]
        )
        XCTAssertEqual(styleResult["outcome"] as? String, "unverified")
        XCTAssertTrue((styleResult["message"] as? String ?? "").contains("Apple Notes was not changed"))

        let grouping = try run(["--backend", "fake", "--engine=native", "--json", "folder", "group-by-date",
                                "Notes", "--enabled", "true"], environment: environment)
        XCTAssertEqual(grouping.0, 0, grouping.2)
        let groupingResult = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(grouping.1.utf8)) as? [String: Any])?["result"] as? [String: Any]
        )
        XCTAssertEqual(groupingResult["outcome"] as? String, "unverified")
        XCTAssertEqual(groupingResult["folderID"] as? String, "fake-folder")
        XCTAssertEqual(try Data(contentsOf: preferences), sentinel)
    }

    func testSettingsShowListsEverySupportedSettingAndPreferenceWritesPlanTheirPreimage() throws {
        let show = try run(["--backend", "fake", "--engine=native", "--json", "settings", "show"])
        XCTAssertEqual(show.0, 0, show.2)
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(show.1.utf8)) as? [String: Any])
        for key in ["sort", "groupsByDate", "defaultTextSize", "resumesLastQuickNote", "autoConvertsToTags",
                    "defaultParagraphStyle", "checklistAutoSort", "defaultAccountID", "queryDateGrouping",
                    "autoFormatMarkdown", "darkBackgrounds", "showNoteCount", "noteContainerView"] {
            XCTAssertNotNil(settings[key], key)
        }
        XCTAssertEqual((settings["darkBackgrounds"] as? [String: Any])?["state"] as? String, "default")
        let table = try run(["--backend", "fake", "--engine=native", "settings", "show"])
        for name in ["default-style", "checklist-auto-sort", "default-account", "query-date-grouping",
                     "auto-format-markdown", "dark-backgrounds", "show-note-count", "view"] {
            XCTAssertTrue(table.1.contains(name), name)
        }

        let view = try run(["--backend", "fake", "--engine=native", "--json", "settings", "view"])
        XCTAssertEqual(view.0, 0, view.2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(view.1.utf8)) as? [String: Any])?["mode"] as? String, "list")
        XCTAssertNotEqual(try run(["--backend", "fake", "--engine=native", "settings", "view", "--set", "gallery"]).0, 0)

        for name in ["query-date-grouping", "auto-format-markdown", "dark-backgrounds", "show-note-count"] {
            let read = try run(["--backend", "fake", "--engine=native", "--json", "settings", name])
            XCTAssertEqual(read.0, 0, read.2)
            let dry = try run(["--backend", "fake", "--engine=native", "--json", "settings", name, "--enabled", "false", "--dry-run"])
            XCTAssertEqual(dry.0, 0, dry.2)
            XCTAssertTrue(dry.1.contains("notesPreference"), dry.1)
            XCTAssertTrue(dry.1.contains("previous_state"), dry.1)
            XCTAssertTrue(dry.1.contains(name), dry.1)
            let readOnly = try run(["--backend", "fake", "--engine=native", "--read-only", "settings", name, "--enabled", "true"])
            XCTAssertEqual(readOnly.0, 4, readOnly.2)
        }
        let monospaced = try run(["--backend", "fake", "--engine=native", "settings", "default-style", "--set", "monospaced"])
        XCTAssertNotEqual(monospaced.0, 0)
    }

    func testParitySettingWritesHonorReadOnlyWhileReadsRemainAvailable() throws {
        for arguments in [
            ["settings", "default-style", "--set", "body"],
            ["folder", "group-by-date", "Notes", "--enabled", "true"],
        ] {
            let result = try run(["--backend", "fake", "--engine=native", "--read-only"] + arguments)
            XCTAssertEqual(result.0, 4, result.2)
            XCTAssertTrue(result.2.contains("read_only"), result.2)
        }

        for arguments in [
            ["settings", "default-style"],
            ["folder", "group-by-date", "Notes"],
        ] {
            let result = try run(["--backend", "fake", "--engine=native", "--read-only", "--json"] + arguments)
            XCTAssertEqual(result.0, 0, result.2)
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
        let native = try run(["--backend", "fake", "--json", "add", "Engine", "--body", "Body"])
        let nativeJSON = try JSONSerialization.jsonObject(with: Data(native.1.utf8)) as! [String: Any]
        XCTAssertEqual(nativeJSON["engine"] as? String, "native")
        XCTAssertEqual((nativeJSON["result"] as? [String: Any])?["outcome"] as? String, "verified")
        let folder = try run(["--backend", "fake", "--json", "folder", "create", "Engine folder"])
        let folderJSON = try JSONSerialization.jsonObject(with: Data(folder.1.utf8)) as! [[String: Any]]
        XCTAssertEqual(folderJSON.first?["engine"] as? String, "scripting")
        let batch = try run(["--backend", "fake", "--json", "delete", "welcome", "--yes"])
        let batchJSON = try JSONSerialization.jsonObject(with: Data(batch.1.utf8)) as! [[String: Any]]
        XCTAssertEqual(batchJSON.first?["engine"] as? String, "native")

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

    func testWriteEnabledStdioMCPExposesNativeToolsByDefault() throws {
        let requests = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"# + "\n" +
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"# + "\n"
        let result = try run(["--backend", "fake", "mcp"], input: requests)

        XCTAssertEqual(result.0, 0, result.2)
        let response = try XCTUnwrap(result.1.split(separator: "\n").last)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let tools = try XCTUnwrap((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "checklist_add" })

        let readOnly = try run(["--backend", "fake", "--read-only", "mcp"], input: requests)
        XCTAssertEqual(readOnly.0, 0, readOnly.2)
        let readOnlyResponse = try XCTUnwrap(readOnly.1.split(separator: "\n").last)
        let readOnlyObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(readOnlyResponse.utf8)) as? [String: Any])
        let readOnlyTools = try XCTUnwrap((readOnlyObject["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertFalse(readOnlyTools.contains { $0["name"] as? String == "checklist_add" })
        XCTAssertFalse(readOnlyTools.contains { $0["name"] as? String == "create_note" })

        let scriptingRequests = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"# + "\n" +
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_note","arguments":{"title":"Scripted","body":"Body","dry_run":true}}}"# + "\n"
        let scripting = try run(["--backend", "fake", "--engine=scripting", "mcp"], input: scriptingRequests)
        XCTAssertEqual(scripting.0, 0, scripting.2)
        XCTAssertTrue(scripting.1.contains(#"\"engine\":\"scripting\""#), scripting.1)
    }

    func testUnifiedCommandTreeRoutesAndHidesLegacyNames() throws {
        let help = try run(["--help"])
        XCTAssertEqual(help.0, 0, help.2)
        for command in ["ocr", "image-labels", "map", "settings", "checklist", "pin", "unpin", "tag", "link", "deeplink", "text", "format", "attach", "attachment", "table", "duplicate", "restore", "write"] {
            XCTAssertTrue(help.1.contains("  \(command)"), command)
        }
        for legacy in ["native-checklist", "native-tag", "native-link", "native-text", "native-format", "native-attachment", "native-table", "native-duplicate", "native-restore", "native-move-folder", "write-markdown"] {
            XCTAssertFalse(help.1.contains("  \(legacy)"), legacy)
        }
        for route in [["ocr", "--help"], ["ocr", "set", "--help"], ["image-labels", "set", "--help"], ["map", "--help"], ["settings", "--help"], ["checklist", "--help"], ["tag", "--help"], ["link", "--help"], ["text", "--help"], ["format", "--help"], ["attachment", "--help"], ["table", "--help"], ["folder", "--help"]] {
            let value = try run(route)
            XCTAssertEqual(value.0, 0, "\(route): \(value.2)")
        }
    }

    func testNativeWritesAreDefaultAndScriptingRemainsExplicitFallback() throws {
        let checklist = try run([
            "--backend", "fake", "--json", "checklist", "add", "welcome", "item", "--dry-run",
        ])
        XCTAssertEqual(checklist.0, 0, checklist.2)
        XCTAssertTrue(checklist.1.contains(#""engine":"native""#), checklist.1)

        let richBody = "<mark data-apple-notes-highlight=\"mint\">marked</mark>"
        let rich = try run(["--backend", "fake", "--json", "add", "Rich", "--body", richBody])
        XCTAssertEqual(rich.0, 0, rich.2)
        XCTAssertTrue(rich.1.contains(#""engine":"native""#), rich.1)

        let scripted = try run([
            "--backend", "fake", "--engine=scripting", "--json", "add", "Plain", "--body", "Body",
        ])
        XCTAssertEqual(scripted.0, 0, scripted.2)
        XCTAssertTrue(scripted.1.contains(#""engine":"scripting""#), scripted.1)

        let richScripted = try run([
            "--backend", "fake", "--engine=scripting", "--json", "add", "Rich", "--body", richBody,
        ])
        XCTAssertNotEqual(richScripted.0, 0)
        XCTAssertTrue(richScripted.2.contains("native_required"), richScripted.2)

        let unavailable = ["NOTESCLI_TEST_NATIVE_AVAILABLE": "0"]
        let fallback = try run(["--backend", "fake", "--json", "add", "Fallback", "--body", "Body"],
                               environment: unavailable)
        XCTAssertEqual(fallback.0, 0, fallback.2)
        XCTAssertTrue(fallback.1.contains(#""engine":"scripting""#), fallback.1)

        let forcedNative = try run([
            "--backend", "fake", "--engine=native", "--json", "add", "Unavailable", "--body", "Body",
        ], environment: unavailable)
        XCTAssertNotEqual(forcedNative.0, 0)
        XCTAssertTrue(forcedNative.2.contains("native_unavailable"), forcedNative.2)

        let richEdit = try run([
            "--backend", "fake", "--json", "edit", "welcome", "--dry-run",
        ], environment: [
            "NOTESCLI_TEST_NATIVE_AVAILABLE": "0",
            "EDITOR": "printf -- '- [ ] task\\n' >",
        ])
        XCTAssertNotEqual(richEdit.0, 0)
        XCTAssertTrue(richEdit.2.contains("native_unavailable"), richEdit.2)

        let environmentScripting = try run([
            "--backend", "fake", "--json", "add", "Environment", "--body", "Body",
        ], environment: ["NOTESCLI_ENGINE": "scripting"])
        XCTAssertEqual(environmentScripting.0, 0, environmentScripting.2)
        XCTAssertTrue(environmentScripting.1.contains(#""engine":"scripting""#), environmentScripting.1)

        for alias in [
            ["native-checklist", "insert", "welcome", "--text", "item"],
            ["native-tag", "add", "demo", "--ref", "welcome"],
            ["native-text", "insert", "welcome", "--text", "x", "--position", "0"],
        ] {
            let result = try run(["--backend", "fake", "--engine=scripting", "--json"] + alias)
            XCTAssertNotEqual(result.0, 0, "\(alias) unexpectedly used native")
            XCTAssertTrue(result.2.contains("native_required"), "\(alias): \(result.2)")
        }
    }

    func testImageMetadataWritesHonorReadOnlyAndSupportNativeDryRuns() throws {
        let commands = [
            ["ocr", "set", "welcome", "--attachment", "image-1", "--text", "words"],
            ["image-labels", "set", "welcome", "--attachment", "image-1", "--clear"],
        ]
        for command in commands {
            let readOnly = try run(["--backend", "fake", "--engine=native", "--read-only"] + command)
            XCTAssertEqual(readOnly.0, 4, readOnly.2)
            XCTAssertTrue(readOnly.2.contains("read_only"), readOnly.2)

            let dryRun = try run(["--backend", "fake", "--engine=native", "--json"] + command + ["--dry-run"])
            XCTAssertEqual(dryRun.0, 0, dryRun.2)
            XCTAssertTrue(dryRun.1.contains(#""engine":"native""#), dryRun.1)
        }
    }

    func testAddWithoutAttachmentsHonorsExplicitAndEnvironmentNativeEngine() throws {
        let cases: [([String], [String: String])] = [
            (["--backend", "fake", "--engine=native", "--json", "add", "Native add", "--body", "body"], [:]),
            (["--backend", "fake", "--json", "add", "Native add", "--body", "body"], ["NOTESCLI_ENGINE": "native"]),
        ]
        for (arguments, environment) in cases {
            let result = try run(arguments, environment: environment)
            XCTAssertEqual(result.0, 0, result.2)
            let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [String: Any])
            XCTAssertEqual(response["engine"] as? String, "native")
            XCTAssertEqual((response["result"] as? [String: Any])?["outcome"] as? String, "verified")
        }
    }

    func testDeleteHonorsExplicitAndEnvironmentNativeEngine() throws {
        let cases: [([String], [String: String])] = [
            (["--backend", "fake", "--engine=native", "--json", "delete", "welcome", "--yes"], [:]),
            (["--backend", "fake", "--json", "delete", "welcome", "--yes"], ["NOTESCLI_ENGINE": "native"]),
        ]
        for (arguments, environment) in cases {
            let result = try run(arguments, environment: environment)
            XCTAssertEqual(result.0, 0, result.2)
            let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.1.utf8)) as? [[String: Any]])
            XCTAssertEqual(response.first?["engine"] as? String, "native")
            XCTAssertEqual((response.first?["result"] as? [String: Any])?["outcome"] as? String, "verified")
        }
    }

    func testNativeAddAndDeleteDryRunsReportNativeEngine() throws {
        let add = try run(["--backend", "fake", "--engine=native", "--json", "add", "Native dry run", "--body", "body", "--dry-run"])
        XCTAssertEqual(add.0, 0, add.2)
        let addPlan = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(add.1.utf8)) as? [String: Any])
        XCTAssertEqual(addPlan["engine"] as? String, "native")

        let delete = try run(["--backend", "fake", "--engine=native", "--json", "delete", "welcome", "--dry-run"])
        XCTAssertEqual(delete.0, 0, delete.2)
        let deletePlans = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(delete.1.utf8)) as? [[String: Any]])
        XCTAssertEqual(deletePlans.first?["engine"] as? String, "native")
    }
}
