import AppKit
import Darwin
import Foundation
import NotesHost
import Security

private let teamID = "GXKRUPGJVF"

private func requirement(identifier: String) -> SecRequirement? {
    var value: SecRequirement?
    let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(identifier)\""
    guard SecRequirementCreateWithString(text as CFString, [], &value) == errSecSuccess else { return nil }
    return value
}

private func validStaticCode(_ url: URL, identifier: String) -> Bool {
    var code: SecStaticCode?
    guard let expected = requirement(identifier: identifier),
          SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
          let code else { return false }
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(code, flags, expected) == errSecSuccess
}

private func verifyOwnSignature() -> Bool {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
        return ProcessInfo.processInfo.environment["NOTESCLI_HOST_ALLOW_UNSIGNED"] == "1"
    }
    return validStaticCode(Bundle.main.bundleURL, identifier: "com.saikrishnabolla.notescli.capability-host")
}

private func bundledCLI() -> URL? {
    let candidates = [
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/notescli"),
        Bundle.main.resourceURL?.appendingPathComponent("notescli"),
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("notescli"),
    ]
    return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private func exitCode(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
}

private func trustedPeer(_ socket: Int32) -> Bool {
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
          length == MemoryLayout<audit_token_t>.size else { return false }
    let data = withUnsafeBytes(of: &token) { Data($0) }
    let attributes = [kSecGuestAttributeAudit: data as CFData] as CFDictionary
    var code: SecCode?
    guard let expected = requirement(identifier: "com.saikrishnabolla.notescli"),
          SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
          let code else { return false }
    return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), expected) == errSecSuccess
}

private func clientConnected(_ socket: Int32) -> Bool {
    var item = pollfd(fd: socket, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
    let result = poll(&item, 1, 100)
    if result == 0 { return true }
    if result < 0 { return errno == EINTR }
    if item.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return false }
    var byte: UInt8 = 0
    let count = recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
    return count != 0 && !(count < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
}

private final class ChildRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    func insert(_ pid: pid_t) { _ = lock.withLock { pids.insert(pid) } }
    func remove(_ pid: pid_t) { _ = lock.withLock { pids.remove(pid) } }
    func terminateAll() {
        let values = lock.withLock { Array(pids) }
        values.forEach { _ = kill(-$0, SIGTERM) }
        usleep(500_000)
        values.forEach { _ = kill(-$0, SIGKILL) }
    }
}

private func spawn(_ executable: URL, request: CapabilityHostRequest, descriptors: [Int32],
                   environment: [String: String]) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }
    for index in descriptors.indices {
        guard posix_spawn_file_actions_adddup2(&actions, descriptors[index], Int32(index)) == 0 else {
            throw POSIXError(.EIO)
        }
    }
    for descriptor in Set(descriptors) where descriptor > STDERR_FILENO {
        _ = posix_spawn_file_actions_addclose(&actions, descriptor)
    }
    if request.workingDirectory.hasPrefix("/") {
        let changed = request.workingDirectory.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        guard changed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: changed) ?? .EIO) }
    }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw POSIXError(.EIO) }

    let argv = ([executable.path] + request.arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    return pid
}

private func terminateAndWait(_ pid: pid_t) {
    _ = kill(-pid, SIGTERM)
    var status: Int32 = 0
    var leaderReaped = false
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if !leaderReaped {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) { leaderReaped = true }
        }
        if kill(-pid, 0) < 0, errno == ESRCH { return }
        usleep(50_000)
    }
    _ = kill(-pid, SIGKILL)
    if !leaderReaped {
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
}

guard verifyOwnSignature(), let cli = bundledCLI() else { Darwin.exit(78) }
private let children = ChildRegistry()

Darwin.signal(SIGTERM, SIG_IGN)
Darwin.signal(SIGINT, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
let terminateHost = {
    children.terminateAll()
    Darwin.exit(0)
}
termination.setEventHandler(handler: terminateHost)
interrupt.setEventHandler(handler: terminateHost)
termination.resume()
interrupt.resume()

let server = CapabilityHostServer { request, descriptors, socket in
    guard trustedPeer(socket), CapabilityHostPolicy.allows(request.arguments),
          validStaticCode(cli, identifier: "com.saikrishnabolla.notescli") else {
        descriptors.forEach { close($0) }
        CapabilityHostServer.reply(CapabilityHostReply(error: "The capability-host request was refused."), socket: socket)
        close(socket)
        return
    }
    defer { descriptors.forEach { close($0) } }
    var environment = request.environment
    for key in ["HOME", "TMPDIR", "USER", "LOGNAME"] {
        if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
    }
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    environment["NOTESCLI_HOST_ACTIVE"] = "1"
    environment["NOTESCLI_CAPABILITY_HOST"] = "direct"
    do {
        let pid = try spawn(cli, request: request, descriptors: descriptors, environment: environment)
        children.insert(pid)
        defer { children.remove(pid) }
        var connected = true
        var status: Int32 = 0
        while connected {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result < 0, errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            connected = clientConnected(socket)
        }
        if !connected { terminateAndWait(pid) }
        else { CapabilityHostServer.reply(CapabilityHostReply(exitCode: exitCode(status)), socket: socket) }
    } catch {
        CapabilityHostServer.reply(CapabilityHostReply(error: "The capability host could not run NotesCLI."), socket: socket)
    }
    close(socket)
}

do { try server.start() }
catch { Darwin.exit(78) }

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
