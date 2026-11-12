import Darwin
import Foundation
import NotesHost
import XCTest

final class CapabilityHostTests: XCTestCase {
    func testPolicyKeepsPathBearingAndManagementCommandsLocal() {
        XCTAssertTrue(CapabilityHostPolicy.allows(["show", "note-id", "--json"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["mcp", "serve", "--http"]))
        XCTAssertTrue(CapabilityHostPolicy.allows(["permissions"]))
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
        XCTAssertFalse(CapabilityHostPolicy.allows(["write-markdown", "note", "--file=/tmp/private.md"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["native-attachment", "file", "note", "--path=/tmp/private"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["mcp", "install", "--client", "codex"]))
        XCTAssertFalse(CapabilityHostPolicy.allows(["recording", "add", "note", "/tmp/audio.m4a"]))
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
