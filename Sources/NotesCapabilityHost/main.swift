import AppKit
import Darwin
import Foundation
import NotesHost
import Security

private func verifyOwnSignature() -> Bool {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
        return ProcessInfo.processInfo.environment["NOTESCLI_HOST_ALLOW_UNSIGNED"] == "1"
    }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
          let code else { return false }
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
}

private func bundledCLI() -> URL? {
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent("notescli"),
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("notescli"),
    ]
    return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private func exitCode(_ process: Process) -> Int32 {
    process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
}

guard verifyOwnSignature(), let cli = bundledCLI() else { Darwin.exit(78) }

let server = CapabilityHostServer { request, descriptors, socket in
    let process = Process()
    process.executableURL = cli
    process.arguments = request.arguments
    if request.workingDirectory.hasPrefix("/") {
        process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory, isDirectory: true)
    }
    process.standardInput = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
    process.standardOutput = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    process.standardError = FileHandle(fileDescriptor: descriptors[2], closeOnDealloc: true)
    var environment = ProcessInfo.processInfo.environment
    environment["NOTESCLI_HOST_ACTIVE"] = "1"
    environment["NOTESCLI_CAPABILITY_HOST"] = "direct"
    process.environment = environment
    do {
        try process.run()
        process.waitUntilExit()
        CapabilityHostServer.reply(CapabilityHostReply(exitCode: exitCode(process)), socket: socket)
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
