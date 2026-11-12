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
    static let configuration = CommandConfiguration(commandName: "status")
    private struct Report: Codable {
        var installed: Bool
        var running: Bool
        var app: String
        var socket: String
    }

    @OptionGroup var options: GlobalOptions
    func run() throws {
        let value = Report(installed: FileManager.default.fileExists(atPath: CapabilityHostPaths.app.path),
                           running: CapabilityHostClient.isAvailable(), app: CapabilityHostPaths.app.path,
                           socket: CapabilityHostPaths.socket.path)
        if options.json { try Output.json(value) }
        else {
            Output.table(["CHECK", "RESULT"], [
                ["app", value.app], ["installed", value.installed ? "yes" : "no"],
                ["running", value.running ? "yes" : "no"], ["socket", value.socket],
            ])
        }
    }
}

enum HostInstallation {
    private static let teamID = "GXKRUPGJVF"
    static var sourceApp: URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let root = executable.deletingLastPathComponent()
        let candidates = [
            root.appendingPathComponent("NotesCLI Capability Host.app", isDirectory: true),
            root.deletingLastPathComponent().appendingPathComponent("libexec/NotesCLI Capability Host.app", isDirectory: true),
            CapabilityHostPaths.app,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var requiresInstallOrUpgrade: Bool {
        guard let source = sourceApp else { return false }
        guard FileManager.default.fileExists(atPath: CapabilityHostPaths.app.path),
              validSignature(CapabilityHostPaths.app) else { return true }
        return bundleVersion(source) != bundleVersion(CapabilityHostPaths.app)
    }

    private static func bundleVersion(_ app: URL) -> [String] {
        guard let bundle = Bundle(url: app) else { return [] }
        return ["CFBundleShortVersionString", "CFBundleVersion"].map {
            bundle.object(forInfoDictionaryKey: $0) as? String ?? ""
        }
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

    static func validSignature(_ app: URL) -> Bool {
        func check(_ url: URL, identifier: String) -> Bool {
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(identifier)\""
            var requirement: SecRequirement?
            var code: SecStaticCode?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  let requirement,
                  SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                  let code else { return false }
            let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
            return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        }
        let cli = app.appendingPathComponent("Contents/Helpers/notescli")
        return check(app, identifier: "com.saikrishnabolla.notescli.capability-host") &&
            check(cli, identifier: "com.saikrishnabolla.notescli")
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

    static func install(silent: Bool = false) throws {
        guard let source = sourceApp else {
            throw NotesError("host_app_missing", "The release does not contain NotesCLI Capability Host.app.")
        }
        let fileManager = FileManager.default
        let appDirectory = CapabilityHostPaths.app.deletingLastPathComponent()
        try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let staged = appDirectory
            .appendingPathComponent(".NotesCLI Capability Host-\(UUID().uuidString).app")
        let appBackup = appDirectory
            .appendingPathComponent(".NotesCLI Capability Host.backup-\(UUID().uuidString).app")
        let launchAgentDirectory = CapabilityHostPaths.launchAgent.deletingLastPathComponent()
        let launchAgentBackup = launchAgentDirectory
            .appendingPathComponent(".com.saikrishnabolla.notescli.capability-host.backup-\(UUID().uuidString).plist")
        let hadApp = fileManager.fileExists(atPath: CapabilityHostPaths.app.path)
        let hadLaunchAgent = fileManager.fileExists(atPath: CapabilityHostPaths.launchAgent.path)
        var mutationBegan = false

        func removeIfPresent(_ url: URL) {
            if fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
        }
        func serviceLoaded() -> Bool {
            launchctl(["print", "gui/\(getuid())/com.saikrishnabolla.notescli.capability-host"]) == 0
        }
        func waitUntilUnloaded() -> Bool {
            for _ in 0..<20 {
                if !serviceLoaded() { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return !serviceLoaded()
        }
        func waitUntilReady() -> Bool {
            for _ in 0..<40 {
                if CapabilityHostClient.isAvailable() { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return CapabilityHostClient.isAvailable()
        }

        do {
            try fileManager.copyItem(at: source, to: staged)
            guard validSignature(staged) else {
                throw NotesError("invalid_host_signature", "The capability host is not signed by the NotesCLI developer team.")
            }
            try fileManager.createDirectory(at: launchAgentDirectory, withIntermediateDirectories: true)
            if hadApp { try fileManager.copyItem(at: CapabilityHostPaths.app, to: appBackup) }
            if hadLaunchAgent { try fileManager.copyItem(at: CapabilityHostPaths.launchAgent, to: launchAgentBackup) }

            if serviceLoaded() {
                guard launchctl(["bootout", "gui/\(getuid())", CapabilityHostPaths.launchAgent.path]) == 0 else {
                    throw NotesError("host_stop_failed", "The current capability host could not be stopped safely.")
                }
                mutationBegan = true
                guard waitUntilUnloaded() else {
                    throw NotesError("host_stop_failed", "The current capability host did not stop before replacement.")
                }
            } else {
                mutationBegan = true
            }

            removeIfPresent(CapabilityHostPaths.socket)
            removeIfPresent(CapabilityHostPaths.app)
            try fileManager.moveItem(at: staged, to: CapabilityHostPaths.app)
            try launchAgentData().write(to: CapabilityHostPaths.launchAgent, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CapabilityHostPaths.launchAgent.path)
            guard launchctl(["bootstrap", "gui/\(getuid())", CapabilityHostPaths.launchAgent.path]) == 0 else {
                throw NotesError("host_start_failed", "The capability host was installed but launchd could not start it.")
            }
            _ = launchctl(["kickstart", "-k", "gui/\(getuid())/com.saikrishnabolla.notescli.capability-host"])
            guard waitUntilReady() else {
                throw NotesError("host_start_failed", "The capability host was installed but its private socket did not become ready.")
            }

            removeIfPresent(appBackup)
            removeIfPresent(launchAgentBackup)
            if !silent { print("Installed NotesCLI Capability Host at \(CapabilityHostPaths.app.path)") }
        } catch {
            let installError = error
            removeIfPresent(staged)
            guard mutationBegan else {
                removeIfPresent(appBackup)
                removeIfPresent(launchAgentBackup)
                throw installError
            }

            _ = launchctl(["bootout", "gui/\(getuid())", CapabilityHostPaths.launchAgent.path])
            _ = waitUntilUnloaded()
            removeIfPresent(CapabilityHostPaths.socket)
            removeIfPresent(CapabilityHostPaths.app)
            removeIfPresent(CapabilityHostPaths.launchAgent)
            do {
                if hadApp { try fileManager.moveItem(at: appBackup, to: CapabilityHostPaths.app) }
                if hadLaunchAgent { try fileManager.moveItem(at: launchAgentBackup, to: CapabilityHostPaths.launchAgent) }
                if hadApp, hadLaunchAgent {
                    guard launchctl(["bootstrap", "gui/\(getuid())", CapabilityHostPaths.launchAgent.path]) == 0 else {
                        throw NotesError("host_rollback_failed", "The previous capability host could not be restored in launchd.")
                    }
                    _ = launchctl(["kickstart", "-k", "gui/\(getuid())/com.saikrishnabolla.notescli.capability-host"])
                    guard waitUntilReady() else {
                        throw NotesError("host_rollback_failed", "The previous capability host was restored but its private socket did not become ready.")
                    }
                }
            } catch {
                throw NotesError("host_rollback_failed",
                                 "Capability-host replacement failed (\(installError)). Restoring the previous host also failed (\(error)).")
            }
            throw installError
        }
    }

    static func uninstall() throws {
        _ = launchctl(["bootout", "gui/\(getuid())", CapabilityHostPaths.launchAgent.path])
        for target in [CapabilityHostPaths.launchAgent, CapabilityHostPaths.app]
            where FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        if FileManager.default.fileExists(atPath: CapabilityHostPaths.socket.path) {
            try? FileManager.default.removeItem(at: CapabilityHostPaths.socket)
        }
    }
}

struct HostInstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install")
    func run() throws { try HostInstallation.install() }
}

struct HostRestart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart")
    func run() throws {
        guard HostInstallation.launchctl(["kickstart", "-k", "gui/\(getuid())/com.saikrishnabolla.notescli.capability-host"]) == 0 else {
            throw NotesError("host_restart_failed", "The capability host is not installed or could not restart.")
        }
    }
}

struct HostUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall")
    @Flag var dryRun = false
    func run() throws {
        let targets = [CapabilityHostPaths.launchAgent, CapabilityHostPaths.app]
        if dryRun { targets.forEach { print($0.path) }; return }
        try HostInstallation.uninstall()
    }
}
