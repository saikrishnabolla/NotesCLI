import Darwin
import Foundation
import NotesHost
import XCTest

final class CapabilityHostTests: XCTestCase {
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
}
