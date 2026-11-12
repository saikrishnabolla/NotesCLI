import Darwin
import Foundation

public enum CapabilityHostRoute: String, Sendable {
    case auto
    case force
    case direct
}

public enum CapabilityHostPaths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotesCLI", isDirectory: true)
    }

    public static var socket: URL { supportDirectory.appendingPathComponent("capability-host.sock") }
    public static var app: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/NotesCLI Capability Host.app", isDirectory: true)
    }
    public static var launchAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.saikrishnabolla.notescli.capability-host.plist")
    }
}

public struct CapabilityHostRequest: Codable, Sendable {
    public static let currentProtocol = 1
    public var protocolVersion: Int
    public var arguments: [String]
    public var workingDirectory: String

    public init(arguments: [String], workingDirectory: String) {
        protocolVersion = Self.currentProtocol
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public struct CapabilityHostReply: Codable, Sendable {
    public var protocolVersion: Int
    public var exitCode: Int32?
    public var error: String?

    public init(exitCode: Int32? = nil, error: String? = nil) {
        protocolVersion = CapabilityHostRequest.currentProtocol
        self.exitCode = exitCode
        self.error = error
    }
}

public enum CapabilityHostError: Error, LocalizedError {
    case unavailable(String)
    case protocolFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .protocolFailure(let message): return message
        }
    }
}

private func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else {
        throw CapabilityHostError.protocolFailure("The capability-host socket path is too long.")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
            path.withCString { source in strcpy(buffer, source) }
        }
    }
    return address
}

private func closeDescriptors(_ descriptors: [Int32]) {
    for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
}

private func alignedControlSize(_ size: Int) -> Int { (size + 3) & ~3 }
private var controlHeaderSize: Int { alignedControlSize(MemoryLayout<cmsghdr>.size) }

public enum CapabilityHostClient {
    public static func isAvailable(socketURL: URL = CapabilityHostPaths.socket) -> Bool {
        var metadata = stat()
        guard lstat(socketURL.path, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFSOCK
            && metadata.st_uid == getuid()
            && metadata.st_mode & 0o077 == 0
        else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, var address = try? socketAddress(socketURL.path) else { return false }
        defer { close(descriptor) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    public static func run(arguments: [String], socketURL: URL = CapabilityHostPaths.socket,
                           descriptors: [Int32] = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]) throws -> Int32 {
        guard descriptors.count == 3 else { throw CapabilityHostError.protocolFailure("Three standard descriptors are required.") }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CapabilityHostError.unavailable("Could not create the capability-host socket.") }
        defer { close(descriptor) }
        var address = try socketAddress(socketURL.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw CapabilityHostError.unavailable("NotesCLI Capability Host is not available. Run 'notescli onboard' to repair it.")
        }
        var data = try JSONEncoder().encode(CapabilityHostRequest(
            arguments: arguments,
            workingDirectory: FileManager.default.currentDirectoryPath
        ))
        data.append(0x0a)
        try sendRequest(data, descriptors: descriptors, socket: descriptor)
        let response = try readReply(socket: descriptor)
        guard response.protocolVersion == CapabilityHostRequest.currentProtocol else {
            throw CapabilityHostError.protocolFailure("The capability-host protocol does not match this NotesCLI version.")
        }
        if let error = response.error { throw CapabilityHostError.protocolFailure(error) }
        guard let exitCode = response.exitCode else {
            throw CapabilityHostError.protocolFailure("The capability host returned no exit status.")
        }
        return exitCode
    }

    private static func sendRequest(_ data: Data, descriptors: [Int32], socket: Int32) throws {
        let payloadSize = MemoryLayout<Int32>.size * descriptors.count
        let controlSize = controlHeaderSize + alignedControlSize(payloadSize)
        var control = [UInt8](repeating: 0, count: controlSize)
        let sent = data.withUnsafeBytes { bytes -> Int in
            var vector = iovec(iov_base: UnsafeMutableRawPointer(mutating: bytes.baseAddress), iov_len: bytes.count)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                control.withUnsafeMutableBytes { controlBytes -> Int in
                    guard let base = controlBytes.baseAddress else { return -1 }
                    let header = base.assumingMemoryBound(to: cmsghdr.self)
                    header.pointee.cmsg_level = SOL_SOCKET
                    header.pointee.cmsg_type = SCM_RIGHTS
                    header.pointee.cmsg_len = socklen_t(controlHeaderSize + payloadSize)
                    let payload = base.advanced(by: controlHeaderSize)
                    descriptors.withUnsafeBytes { source in
                        if let sourceAddress = source.baseAddress { memcpy(payload, sourceAddress, source.count) }
                    }
                    var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
                                         msg_control: base, msg_controllen: socklen_t(controlBytes.count), msg_flags: 0)
                    return sendmsg(socket, &message, 0)
                }
            }
        }
        guard sent == data.count else {
            throw CapabilityHostError.unavailable("Could not send the command to the capability host.")
        }
    }

    private static func readReply(socket: Int32) throws -> CapabilityHostReply {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 64 * 1024 {
            let count = recv(socket, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw CapabilityHostError.unavailable("The capability host disconnected.")
            }
            data.append(contentsOf: buffer.prefix(count))
            if data.contains(0x0a) { break }
        }
        guard let newline = data.firstIndex(of: 0x0a) else {
            throw CapabilityHostError.protocolFailure("The capability host returned an invalid reply.")
        }
        return try JSONDecoder().decode(CapabilityHostReply.self, from: Data(data[..<newline]))
    }
}

public final class CapabilityHostServer: @unchecked Sendable {
    public typealias Launcher = @Sendable (CapabilityHostRequest, [Int32], Int32) -> Void
    private let socketURL: URL
    private let launcher: Launcher
    private let queue = DispatchQueue(label: "com.saikrishnabolla.notescli.capability-host", attributes: .concurrent)
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    public init(socketURL: URL = CapabilityHostPaths.socket, launcher: @escaping Launcher) {
        self.socketURL = socketURL
        self.launcher = launcher
    }

    deinit { stop() }

    public func start() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if FileManager.default.fileExists(atPath: socketURL.path) {
            if CapabilityHostClient.isAvailable(socketURL: socketURL) {
                throw CapabilityHostError.unavailable("Another NotesCLI Capability Host is already running.")
            }
            try FileManager.default.removeItem(at: socketURL)
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CapabilityHostError.unavailable("Could not create the capability-host listener.") }
        var address = try socketAddress(socketURL.path)
        let didBind = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard didBind == 0, chmod(socketURL.path, 0o600) == 0, listen(listener, 32) == 0 else {
            let message = String(cString: strerror(errno))
            stop()
            throw CapabilityHostError.unavailable("Could not start the capability host: \(message)")
        }
        let newSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        newSource.setEventHandler { [weak self] in self?.acceptConnections() }
        newSource.setCancelHandler { [weak self] in
            guard let self, self.listener >= 0 else { return }
            close(self.listener)
            self.listener = -1
        }
        source = newSource
        newSource.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 { close(listener); listener = -1 }
        if FileManager.default.fileExists(atPath: socketURL.path) { try? FileManager.default.removeItem(at: socketURL) }
    }

    private func acceptConnections() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            queue.async { [launcher] in
                do {
                    let (request, descriptors) = try Self.receiveRequest(socket: client)
                    launcher(request, descriptors, client)
                } catch {
                    Self.reply(CapabilityHostReply(error: error.localizedDescription), socket: client)
                    close(client)
                }
            }
        }
    }

    private static func receiveRequest(socket: Int32) throws -> (CapabilityHostRequest, [Int32]) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0, uid == getuid() else {
            throw CapabilityHostError.protocolFailure("The capability-host client has the wrong owner.")
        }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let controlSize = controlHeaderSize + alignedControlSize(MemoryLayout<Int32>.size * 3)
        var control = [UInt8](repeating: 0, count: controlSize)
        let received: (Int, Int) = bytes.withUnsafeMutableBytes { body in
            var vector = iovec(iov_base: body.baseAddress, iov_len: body.count)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                control.withUnsafeMutableBytes { ancillary in
                    var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
                                         msg_control: ancillary.baseAddress, msg_controllen: socklen_t(ancillary.count), msg_flags: 0)
                    let count = recvmsg(socket, &message, 0)
                    return (count, Int(message.msg_controllen))
                }
            }
        }
        let count = received.0
        guard count > 0, let newline = bytes.prefix(count).firstIndex(of: 0x0a) else {
            throw CapabilityHostError.protocolFailure("The capability-host request is invalid.")
        }
        var descriptors: [Int32] = []
        control.withUnsafeMutableBytes { ancillary in
            guard received.1 >= MemoryLayout<cmsghdr>.size, let base = ancillary.baseAddress else { return }
            let header = base.assumingMemoryBound(to: cmsghdr.self)
            if header.pointee.cmsg_level == SOL_SOCKET, header.pointee.cmsg_type == SCM_RIGHTS,
               Int(header.pointee.cmsg_len) >= controlHeaderSize + MemoryLayout<Int32>.size * 3 {
                let payload = UnsafeRawPointer(base).advanced(by: controlHeaderSize)
                descriptors = Array(UnsafeBufferPointer(start: payload.assumingMemoryBound(to: Int32.self), count: 3))
            }
        }
        guard descriptors.count == 3 else {
            closeDescriptors(descriptors)
            throw CapabilityHostError.protocolFailure("The capability-host request is missing standard descriptors.")
        }
        do {
            let request = try JSONDecoder().decode(CapabilityHostRequest.self, from: Data(bytes[..<newline]))
            guard request.protocolVersion == CapabilityHostRequest.currentProtocol,
                  request.arguments.count <= 512,
                  request.arguments.allSatisfy({ $0.utf8.count <= 64 * 1024 }) else {
                throw CapabilityHostError.protocolFailure("The capability-host request is not supported.")
            }
            return (request, descriptors)
        } catch {
            closeDescriptors(descriptors)
            throw error
        }
    }

    public static func reply(_ reply: CapabilityHostReply, socket: Int32) {
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(0x0a)
        data.withUnsafeBytes { pointer in
            _ = send(socket, pointer.baseAddress, pointer.count, MSG_NOSIGNAL)
        }
    }
}
