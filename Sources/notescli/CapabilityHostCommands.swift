import ArgumentParser
import Darwin
import Foundation
import NotesCore
import NotesHost

struct HostCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host",
        abstract: "Manage the signed capability host.",
        subcommands: [HostInstall.self, HostStatus.self, HostRestart.self, HostUninstall.self]
    )
}

struct HostStatus: ParsableCommand {
    @Flag var json = false
    func run() throws {
        let value: [String: Any] = [
            "installed": FileManager.default.fileExists(atPath: CapabilityHostPaths.app.path),
            "running": CapabilityHostClient.isAvailable(),
            "app": CapabilityHostPaths.app.path,
            "socket": CapabilityHostPaths.socket.path,
        ]
        if json { try Output.json(value) }
        else { Output.table(["CHECK", "RESULT"], value.keys.sorted().map { [$0, String(describing: value[$0]!)] }) }
    }
}

enum HostInstallation {
    static var sourceApp: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let root = executable.deletingLastPathComponent()
        let candidates = [
            root.appendingPathComponent("NotesCLI Capability Host.app", isDirectory: true),
            root.deletingLastPathComponent().appendingPathComponent("libexec/NotesCLI Capability Host.app", isDirectory: true),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func launchAgentData() throws -> Data {
        let executable = CapabilityHostPaths.app.appendingPathComponent("Contents/MacOS/NotesCLI Capability Host").path
        let object: [String: Any] = [
            "Label": "com.saikrishnabolla.notescli.capability-host",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "LimitLoadToSessionType": "Aqua",
            "Umask": 63,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    @discardableResult static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return 1 }
    }
}

struct HostInstall: ParsableCommand {
    func run() throws {
        guard let source = HostInstallation.sourceApp else {
            throw NotesError("host_app_missing", "The release does not contain NotesCLI Capability Host.app.")
        }
        try FileManager.default.createDirectory(at: CapabilityHostPaths.app.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = CapabilityHostPaths.app.deletingLastPathComponent()
            .appendingPathComponent(".NotesCLI Capability Host-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: source, to: staged)
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", staged.path]
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw NotesError("invalid_host_signature", "The capability host signature is invalid.")
        }
        _ = HostInstallation.launchctl(["bootout", "gui/\(getuid())", CapabilityHostPaths.launchAgent.path])
        if FileManager.default.fileExists(atPath: CapabilityHostPaths.app.path) {
            let backup = CapabilityHostPaths.app.deletingLastPathComponent()
                .appendingPathComponent(".NotesCLI Capability Host.backup-\(UUID().uuidString).app")
            try FileManager.default.moveItem(at: CapabilityHostPaths.app, to: backup)
            do {
                try FileManager.default.moveItem(at: staged, to: CapabilityHostPaths.app)
                try FileManager.default.removeItem(at: backup)
            } catch {
                try? FileManager.default.moveItem(at: backup, to: CapabilityHostPaths.app)
                throw error
            }
        } else {
            try FileManager.default.moveItem(at: staged, to: CapabilityHostPaths.app)
        }
        try FileManager.default.createDirectory(at: CapabilityHostPaths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HostInstallation.launchAgentData().write(to: CapabilityHostPaths.launchAgent, options: .atomic)
        guard HostInstallation.launchctl(["bootstrap", "gui/\(getuid())", CapabilityHostPaths.launchAgent.path]) == 0 else {
            throw NotesError("host_start_failed", "The capability host was installed but launchd could not start it.")
        }
        _ = HostInstallation.launchctl(["kickstart", "-k", "gui/\(getuid())/com.saikrishnabolla.notescli.capability-host"])
        print("Installed NotesCLI Capability Host at \(CapabilityHostPaths.app.path)")
    }
}

struct HostRestart: ParsableCommand {
    func run() throws {
        guard HostInstallation.launchctl(["kickstart", "-k", "gui/\(getuid())/com.saikrishnabolla.notescli.capability-host"]) == 0 else {
            throw NotesError("host_restart_failed", "The capability host is not installed or could not restart.")
        }
    }
}

struct HostUninstall: ParsableCommand {
    @Flag var dryRun = false
    func run() throws {
        let targets = [CapabilityHostPaths.launchAgent, CapabilityHostPaths.app]
        if dryRun { targets.forEach { print($0.path) }; return }
        _ = HostInstallation.launchctl(["bootout", "gui/\(getuid())", CapabilityHostPaths.launchAgent.path])
        for target in targets where FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        if FileManager.default.fileExists(atPath: CapabilityHostPaths.socket.path) {
            try? FileManager.default.removeItem(at: CapabilityHostPaths.socket)
        }
    }
}
