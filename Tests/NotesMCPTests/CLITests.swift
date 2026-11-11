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
    func testAllWritesRefuseBeforeBackendOrEditor() throws {
        let commands = [["add"], ["append", "welcome", "--body", "x"], ["edit", "welcome"], ["rename", "welcome", "X"], ["move", "welcome", "Notes"], ["delete", "welcome", "--yes"], ["folder", "create", "X"], ["folder", "rename", "Notes", "X"], ["folder", "delete", "Notes", "--yes"]]
        for args in commands {
            let r = try run(["--read-only", "--json"] + args, environment: ["NOTESCLI_BACKEND": "default", "EDITOR": "false"])
            XCTAssertEqual(r.0, 4, "\(args): \(r.2)")
            XCTAssertTrue(r.2.contains("read_only"), "\(args): \(r.2)")
        }
    }
    func testFuzzyRankingAndDeterminism() throws {
        for query in ["cofee", "shoppng", "aples bread", "welcom", "NOTESCli"] {
            let args = ["--backend", "fake", "search", query, "--fuzzy", "--json"]
            let first = try run(args), second = try run(args)
            XCTAssertEqual(first.0, 0, first.2); XCTAssertEqual(first.1, second.1)
            let notes = try JSONSerialization.jsonObject(with: Data(first.1.utf8)) as! [[String: Any]]
            XCTAssertEqual(notes.count, query == "shoppng" ? 2 : 1, query)
            XCTAssertEqual(notes.first?["title"] as? String, ["welcom", "NOTESCli"].contains(query) ? "Welcome" : "Shopping")
        }
        let ranked = try run(["--backend", "fake", "search", "shopping", "--fuzzy", "--json"])
        let ranking = try JSONSerialization.jsonObject(with: Data(ranked.1.utf8)) as! [[String: Any]]
        XCTAssertEqual(ranking.compactMap { $0["title"] as? String }, ["Shopping", "Welcome"])
        let limited = try run(["--backend", "fake", "search", "shopping", "--fuzzy", "--limit", "1", "--json"])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(limited.1.utf8)) as! [Any]).count, 1)
        let absent = try run(["--backend", "fake", "search", "unrelated", "--fuzzy", "--json"])
        XCTAssertEqual(absent.1.trimmingCharacters(in: .whitespacesAndNewlines), "[]")
        let exact = try run(["--backend", "fake", "search", "cofee", "--json"])
        XCTAssertEqual(exact.1.trimmingCharacters(in: .whitespacesAndNewlines), "[]")
    }
    func testReadsWritesAndEditor() throws {
        let commands = [["folders", "--tree", "--account", "Demo"], ["list", "--folder", "Notes", "--account", "Demo", "--pinned", "--tag", "demo", "--since", "2020-01-01", "--until", "2030-01-01", "--limit", "1", "--include-deleted"], ["tags"], ["recent", "1"], ["show", "welcome", "--no-attachments"], ["add", "Draft", "--body", "Body"], ["append", "welcome", "--body", "More"], ["rename", "welcome", "New"], ["move", "welcome", "Notes"], ["delete", "welcome", "shopping", "--yes"], ["folder", "create", "Child", "--parent", "Notes", "--account", "Demo"], ["folder", "rename", "Notes", "Renamed"], ["folder", "delete", "Notes", "--yes"], ["open", "welcome"]]
        for args in commands { let r = try run(["--backend", "fake"] + args); XCTAssertEqual(r.0, 0, "\(args): \(r.2)") }
        for args in [["add", "Draft", "--stdin"], ["append", "welcome", "--stdin"]] {
            let r = try run(["--backend", "fake"] + args, input: "Body from stdin\n"); XCTAssertEqual(r.0, 0, r.2)
        }
        let unchanged = try run(["--backend", "fake", "edit", "welcome"], environment: ["EDITOR": "true"])
        XCTAssertEqual(unchanged.0, 0, unchanged.2); XCTAssertTrue(unchanged.1.contains("Unchanged")); XCTAssertTrue(unchanged.2.contains("checklists"))
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
    }
    func testExportsAndFileInput() throws {
        let directory = root.appendingPathComponent(".build/cli-tests-" + UUID().uuidString)
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
