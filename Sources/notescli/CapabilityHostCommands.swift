import ArgumentParser
import Darwin
import Foundation
import NotesCore
import NotesHost

struct HostCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host",
        abstract: "Manage the signed Notes CLI app.",
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

enum CapabilityHostRouting {
    static func usesHost(backend: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                         needsUpgrade: () -> Bool = { HostInstallation.requiresInstallOrUpgrade },
                         isAvailable: () -> Bool = { CapabilityHostClient.isAvailable() }) -> Bool {
        guard backend != "fake", environment["NOTESCLI_HOST_ACTIVE"] != "1" else { return false }
        switch CapabilityHostRoute(rawValue: environment["NOTESCLI_CAPABILITY_HOST"] ?? "auto") ?? .auto {
        case .direct: return false
        case .force: return true
        case .auto: return !needsUpgrade() && isAvailable()
        }
    }
}

enum HostInstallation {
    private static let teamID = "GXKRUPGJVF"
    static var sourceApp: URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let root = executable.deletingLastPathComponent()
        let candidates = [
            root.appendingPathComponent("Notes CLI.app", isDirectory: true),
            root.appendingPathComponent("NotesCLI Capability Host.app", isDirectory: true),
            root.deletingLastPathComponent().appendingPathComponent("libexec/Notes CLI.app", isDirectory: true),
            root.deletingLastPathComponent().appendingPathComponent("libexec/NotesCLI Capability Host.app", isDirectory: true),
            CapabilityHostPaths.app,
            CapabilityHostPaths.legacyApp,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var requiresInstallOrUpgrade: Bool {
        sourceApp != nil && !isCurrentInstall
    }

    static var isCurrentInstall: Bool {
        isCurrentInstall(at: CapabilityHostPaths.app, packagedSource: sourceApp)
    }

    static func isCurrentInstall(at app: URL, packagedSource: URL?,
                                 validate: (URL) -> Bool = validSignature,
                                 identity: (URL) -> Data? = signingIdentity) -> Bool {
        guard bundleVersion(app) == [notesCLIVersion, notesCLIVersion], validate(app) else { return false }
        guard let packagedSource,
              packagedSource.resolvingSymlinksInPath() != app.resolvingSymlinksInPath() else { return true }
        let helper = "Contents/Helpers/notescli"
        return [(app, packagedSource), (app.appendingPathComponent(helper), packagedSource.appendingPathComponent(helper))]
            .allSatisfy { installed, packaged in
                guard let installedCode = identity(installed) else { return false }
                return installedCode == identity(packaged)
            }
    }

    private static func signingIdentity(_ url: URL) -> Data? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoUnique as String] as? Data
    }

    private static func bundleVersion(_ app: URL) -> [String] {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return ["CFBundleShortVersionString", "CFBundleVersion"].map { values[$0] as? String ?? "" }
    }

    static func launchAgentData() throws -> Data {
        let executable = CapabilityHostPaths.app.appendingPathComponent("Contents/MacOS/Notes CLI").path
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
            throw NotesError("host_app_missing", "The release does not contain Notes CLI.app.")
        }
        let fileManager = FileManager.default
        let appDirectory = CapabilityHostPaths.app.deletingLastPathComponent()
        try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let staged = appDirectory
            .appendingPathComponent(".Notes CLI-\(UUID().uuidString).app")
        let appBackup = appDirectory
            .appendingPathComponent(".Notes CLI.backup-\(UUID().uuidString).app")
        let legacyAppBackup = appDirectory
            .appendingPathComponent(".Notes CLI.legacy-backup-\(UUID().uuidString).app")
        let launchAgentDirectory = CapabilityHostPaths.launchAgent.deletingLastPathComponent()
        let launchAgentBackup = launchAgentDirectory
            .appendingPathComponent(".com.saikrishnabolla.notescli.capability-host.backup-\(UUID().uuidString).plist")
        let hadApp = fileManager.fileExists(atPath: CapabilityHostPaths.app.path)
        let hadLegacyApp = fileManager.fileExists(atPath: CapabilityHostPaths.legacyApp.path)
        let hadLaunchAgent = fileManager.fileExists(atPath: CapabilityHostPaths.launchAgent.path)
        var mutationBegan = false
        var migratingEditor = false

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
        func waitUntilReady(attempts: Int = 40) -> Bool {
            for _ in 0..<attempts {
                if CapabilityHostClient.isAvailable() { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return CapabilityHostClient.isAvailable()
        }

        func waitForBootstrappedHost() -> Bool {
            // The generated LaunchAgent already uses RunAtLoad. Don't kill and
            // relaunch the process that may already be verifying its signature.
            if waitUntilReady(attempts: 5) { return true }
            _ = launchctl(["kickstart", "gui/\(getuid())/com.saikrishnabolla.notescli.capability-host"])
            return waitUntilReady()
        }

        do {
            try fileManager.copyItem(at: source, to: staged)
            guard validSignature(staged) else {
                throw NotesError("invalid_host_signature", "Notes CLI is not signed by the expected developer team.")
            }
            try fileManager.createDirectory(at: launchAgentDirectory, withIntermediateDirectories: true)
            if hadApp { try fileManager.copyItem(at: CapabilityHostPaths.app, to: appBackup) }
            if hadLegacyApp { try fileManager.copyItem(at: CapabilityHostPaths.legacyApp, to: legacyAppBackup) }
            if hadLaunchAgent { try fileManager.copyItem(at: CapabilityHostPaths.launchAgent, to: launchAgentBackup) }

            if serviceLoaded() {
                guard launchctl(["bootout", "gui/\(getuid())", CapabilityHostPaths.launchAgent.path]) == 0 else {
                    throw NotesError("host_stop_failed", "The current Notes CLI app could not be stopped safely.")
                }
                mutationBegan = true
                guard waitUntilUnloaded() else {
                    throw NotesError("host_stop_failed", "Notes CLI did not stop before replacement.")
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
                throw NotesError("host_start_failed", "Notes CLI was installed, but macOS could not start it.")
            }
            guard waitForBootstrappedHost() else {
                throw NotesError("host_start_failed", "Notes CLI was installed, but it did not become ready.")
            }

            if hadLegacyApp { try fileManager.removeItem(at: CapabilityHostPaths.legacyApp) }
            if NotesCLIApplication.supportsEmbeddedEditor(at: CapabilityHostPaths.app) {
                migratingEditor = true
                try EditorLogin.local.migrateIfNeeded()
            }
            removeIfPresent(appBackup)
            removeIfPresent(legacyAppBackup)
            removeIfPresent(launchAgentBackup)
            if !silent { print("Installed Notes CLI at \(CapabilityHostPaths.app.path)") }
        } catch {
            let installError = error
            removeIfPresent(staged)
            guard mutationBegan else {
                removeIfPresent(appBackup)
                removeIfPresent(legacyAppBackup)
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
                if hadLegacyApp {
                    removeIfPresent(CapabilityHostPaths.legacyApp)
                    try fileManager.moveItem(at: legacyAppBackup, to: CapabilityHostPaths.legacyApp)
                }
                if hadLaunchAgent { try fileManager.moveItem(at: launchAgentBackup, to: CapabilityHostPaths.launchAgent) }
                if (hadApp || hadLegacyApp), hadLaunchAgent {
                    guard launchctl(["bootstrap", "gui/\(getuid())", CapabilityHostPaths.launchAgent.path]) == 0 else {
                        throw NotesError("host_rollback_failed", "The previous Notes CLI app could not be restored in macOS.")
                    }
                    guard waitForBootstrappedHost() else {
                        throw NotesError("host_rollback_failed", "The previous Notes CLI app was restored, but it did not become ready.")
                    }
                }
                if migratingEditor { try EditorLogin.local.restartLegacyAfterAppRollback() }
            } catch {
                throw NotesError("host_rollback_failed",
                                 "Replacing Notes CLI failed (\(installError)). Restoring the previous app also failed (\(error)).")
            }
            throw installError
        }
    }

    static func uninstall() throws {
        try EditorLogin.local.disable()
        _ = launchctl(["bootout", "gui/\(getuid())", CapabilityHostPaths.launchAgent.path])
        for target in [CapabilityHostPaths.launchAgent, CapabilityHostPaths.app, CapabilityHostPaths.legacyApp]
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
            throw NotesError("host_restart_failed", "Notes CLI is not installed or could not restart.")
        }
    }
}

struct HostUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall")
    @Flag var dryRun = false
    func run() throws {
        let targets = [CapabilityHostPaths.launchAgent, CapabilityHostPaths.app, CapabilityHostPaths.legacyApp]
        if dryRun {
            if try EditorLogin.local.isEnabled() { print(EditorLogin.local.plist.path) }
            targets.forEach { print($0.path) }; return
        }
        try HostInstallation.uninstall()
    }
}
