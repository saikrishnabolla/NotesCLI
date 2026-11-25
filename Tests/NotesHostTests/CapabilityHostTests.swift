import Darwin
import Foundation
import NotesCore
@testable import NotesHost
import XCTest

final class CapabilityHostTests: XCTestCase {
    func testEditorReadsCanUseHostButInteractiveCommandsStayLocal() {
        let noteID = "E1EAFE75-7EB2-40C0-8493-CD9AA94793D1"
        XCTAssertTrue(CapabilityHostPolicy.allows(["editor-note-copy", noteID, "copy-markdown", "--json"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["editor-note-copy", noteID, "copy-link", "--json"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["editor-body-search", "--json", "--", "--file"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["editor-body-search", "--json", "--backend", "default", "--", "body text"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["editor-body-search", "--json", "--", String(repeating: "a", count: 1025)]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["editor-body-search", "--json", "--file", "/tmp/notes"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["editor-template", "--destination", noteID, "--json"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["backlinks", "id:" + noteID, "--json"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["editor"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["palette", "--selected-note", noteID]))
    }

    func testPermissionProbeAcceptsNoOptionsOrFilePath() {
        let command = CapabilityHostPolicy.notesAccessProbeArguments
        XCTAssertTrue(CapabilityHostPolicy.allows(command))
        XCTAssertFalse(CapabilityHostPolicy.allows(command + ["/tmp/other.sqlite"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["--json"] + command))
    }

    func testPermissionProbeRequiresSQLiteHeader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("NoteStore.sqlite")
        XCTAssertFalse(HostNotesAccess.canReadStoreHeader(at: file))
        for (bytes, expected) in [
            (Data(), false),
            (Data("SQLite format 3".utf8), false),
            (Data("SQLite format 3\0extra bytes".utf8), true),
        ] {
            try bytes.write(to: file)
            XCTAssertEqual(HostNotesAccess.canReadStoreHeader(at: file), expected)
        }
    }

    func testPermissionProbeDistinguishesDenialFromUnavailableHost() throws {
        for (code, expected): (Int32, Bool?) in [(0, true), (1, false), (2, nil)] {
            let root = URL(fileURLWithPath: "/tmp/nch-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let socket = root.appendingPathComponent("host.sock")
            let server = CapabilityHostServer(socketURL: socket) { request, descriptors, connection in
                defer { descriptors.forEach { close($0) }; close(connection) }
                XCTAssertEqual(request.arguments, CapabilityHostPolicy.notesAccessProbeArguments)
                CapabilityHostServer.reply(CapabilityHostReply(exitCode: code), socket: connection)
            }
            try server.start()
            XCTAssertEqual(CapabilityHostClient.notesAccessReady(socketURL: socket), expected)
            server.stop()
            XCTAssertNil(CapabilityHostClient.notesAccessReady(socketURL: socket))
        }
    }

    func testPublicAppPathUsesNewNameAndKeepsLegacyMigrationPath() {
        XCTAssertEqual(CapabilityHostPaths.app.lastPathComponent, "Notes CLI.app")
        XCTAssertEqual(CapabilityHostPaths.legacyApp.lastPathComponent, "NotesCLI Capability Host.app")
    }

    func testRequestCarriesHostProtocolAndCLIRelease() {
        let request = CapabilityHostRequest(arguments: ["list"], workingDirectory: "/tmp")
        XCTAssertEqual(request.protocolVersion, 2)
        XCTAssertEqual(request.clientVersion, notesCLIVersion)
    }

    func testVersionMismatchExplainsHowToUpgradeTheHost() {
        var request = CapabilityHostRequest(arguments: ["list"], workingDirectory: "/tmp")
        request.clientVersion = "1.1.6"
        XCTAssertThrowsError(try request.validate(forHostVersion: "1.1.12")) { error in
            XCTAssertTrue(error.localizedDescription.contains("client is 1.1.6"))
            XCTAssertTrue(error.localizedDescription.contains("notescli onboard"))
        }

        request.clientVersion = "1.1.12"
        request.protocolVersion = 1
        XCTAssertThrowsError(try request.validate(forHostVersion: "1.1.12")) { error in
            XCTAssertTrue(error.localizedDescription.contains("notescli onboard"))
        }
    }

    func testPolicyKeepsPathBearingAndManagementCommandsLocal() {
        XCTAssertTrue(CapabilityHostPolicy.allows(["show", "note-id", "--json"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["mcp", "serve", "--http"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["permissions"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["collaboration", "activity", "note-id", "--limit", "10", "--json"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["ocr", "note-id", "--json"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["ocr", "set", "note-id", "--attachment", "image-id", "--text", "words"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["image-labels", "set", "note-id", "--attachment", "image-id", "--clear"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["attachment", "delete", "note-id", "image-id"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["attachment", "markup", "inspect", "note-id", "image-id"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["attachment", "markup", "list", "note-id", "image-id"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["attachment", "markup", "add", "note-id", "image-id", "rectangle"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["attachment", "markup", "remove", "note-id", "image-id", "annotation-id"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["attachment", "markup", "copy", "note-id", "image-id", "source-note", "source-image"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["attachment", "markup", "clear", "note-id", "image-id"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["attachment", "markup", "set", "note-id", "image-id", "/tmp/markup.archive"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["attachment", "markup", "export", "note-id", "image-id", "/tmp/markup.archive"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["attachment", "markup", "render", "note-id", "image-id", "/tmp/markup.png"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["map", "add", "note-id", "https://maps.apple.com/?q=Apple+Park"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["scan", "filter", "note-id", "gallery-id", "page-id", "color"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["scan", "state", "note-id", "gallery-id", "page-id"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["scan", "rotate", "note-id", "gallery-id", "page-id", "left"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["scan", "move", "note-id", "gallery-id", "page-id", "1"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["scan", "delete", "note-id", "gallery-id", "page-id"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["camera", "devices", "--json"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["camera", "photo", "note-id", "--device", "camera-id"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["camera", "scan", "note-id", "--count", "2"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["camera", "photo", "note-id", "--source-image", "/tmp/input.png"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["recording", "clear-summary", "note-id", "recording-id"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["recording", "add", "note-id", "/tmp/audio.m4a"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["recording", "create", "--folder", "Notes"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["settings", "default-style", "--json"]))
        for name in ["show", "view", "query-date-grouping", "auto-format-markdown", "dark-backgrounds", "show-note-count"] {
            XCTAssertTrue(CapabilityHostPolicy.allows(["settings", name, "--json"]), name)
        }
        XCTAssertTrue(CapabilityHostPolicy.allows([]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["--json", "--no-recent"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["doctor", "--for-agent", "--json"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["doctor", "--json"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["unknown-command"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["export", "--output", "/tmp/notes"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["watch", "--exec", "touch /tmp/escaped"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["watch", "--exec=touch /tmp/escaped"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["add", "Report"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["add", "Report", "--body", "safe text"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["add", "Report", "--stdin"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["add", "--file", "/tmp/body.md"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["add", "Title", "--attach", "/tmp/private.pdf"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["attachments", "note", "--save=/tmp/private"]))
        XCTAssertTrue(CapabilityHostPolicy.allows([
            "attachments", "note", "--password-stdin", "--save=/tmp/private"
        ]))
        XCTAssertFalse(CapabilityHostPolicy.allows([
            "attachments", "note", "--password-stdin", "--save=/tmp/private", "--preview=/tmp/preview"
        ]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["write-markdown", "note", "--file=/tmp/private.md"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["native-attachment", "file", "note", "--path=/tmp/private"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["mcp", "install", "--client", "codex"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["scan", "add", "note", "/tmp/page.png"]))
    }

    func testOwnerOnlySocketForwardsArgumentsAndStandardDescriptors() throws {
        let root = URL(fileURLWithPath: "/tmp/nch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("host.sock")
        let handled = expectation(description: "handled")
        let server = CapabilityHostServer(socketURL: socket) { request, descriptors, connection in
            XCTAssertEqual(request.arguments, ["list", "--json"])
            _ = "forwarded\n".withCString { write(descriptors[1], $0, strlen($0)) }
            descriptors.forEach { close($0) }
            CapabilityHostServer.reply(CapabilityHostReply(exitCode: 7), socket: connection)
            close(connection)
            handled.fulfill()
        }
        try server.start()
        defer { server.stop() }
        var metadata = stat()
        XCTAssertEqual(lstat(socket.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)

        var output = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&output), 0)
        let input = open("/dev/null", O_RDONLY)
        let error = open("/dev/null", O_WRONLY)
        let status = try CapabilityHostClient.run(
            arguments: ["list", "--json"],
            socketURL: socket,
            descriptors: [input, output[1], error]
        )
        close(input); close(output[1]); close(error)
        XCTAssertEqual(status, 7)
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = read(output[0], &bytes, bytes.count)
        close(output[0])
        XCTAssertEqual(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self), "forwarded\n")
        wait(for: [handled], timeout: 2)
    }

    func testDuplicateStartKeepsOriginalSocket() throws {
        let root = URL(fileURLWithPath: "/tmp/nch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("host.sock")
        let active = CapabilityHostServer(socketURL: socket) { _, descriptors, connection in
            descriptors.forEach { close($0) }
            CapabilityHostServer.reply(CapabilityHostReply(exitCode: 0), socket: connection)
            close(connection)
        }
        try active.start()
        defer { active.stop() }
        do {
            let duplicate = CapabilityHostServer(socketURL: socket) { _, _, _ in XCTFail("Duplicate host received a request") }
            XCTAssertThrowsError(try duplicate.start())
        }
        XCTAssertTrue(CapabilityHostClient.isAvailable(socketURL: socket))
        XCTAssertEqual(try CapabilityHostClient.capture(arguments: ["list"], socketURL: socket,
                                                         replyTimeoutSeconds: 2).exitCode, 0)
    }

    func testLargeRequestIsReadAcrossMultipleSocketReceives() throws {
        let root = URL(fileURLWithPath: "/tmp/nch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("host.sock")
        let body = String(repeating: "x", count: 96 * 1024)
        let handled = expectation(description: "large request handled")
        let server = CapabilityHostServer(socketURL: socket) { request, descriptors, connection in
            XCTAssertEqual(request.arguments, ["add", "Report", "--body", body])
            descriptors.forEach { close($0) }
            CapabilityHostServer.reply(CapabilityHostReply(exitCode: 0), socket: connection)
            close(connection)
            handled.fulfill()
        }
        try server.start()
        defer { server.stop() }
        let null = open("/dev/null", O_RDWR)
        defer { close(null) }
        XCTAssertEqual(try CapabilityHostClient.run(arguments: ["add", "Report", "--body", body],
                                                    socketURL: socket, descriptors: [null, null, null]), 0)
        wait(for: [handled], timeout: 2)
    }
}
