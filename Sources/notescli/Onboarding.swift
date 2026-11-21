import Foundation
import NotesCore
import NotesHost

struct OnboardingState: Codable {
    var schemaVersion = 1
    /// String keys let host-install and host-ready be added without changing the saved-state shape.
    var steps: [String: String] = [:]
}

struct OnboardingStepReport: Codable, Equatable {
    var id: String
    var status: String
    var required: Bool
}

struct OnboardingReport: Codable {
    var schemaVersion: Int
    var checkOnly: Bool
    var complete: Bool
    var resumable: Bool
    var steps: [OnboardingStepReport]
}

enum OnboardingStore {
    static var url: URL { InstallManifest.applicationSupport.appendingPathComponent("onboarding.json") }

    static func load() throws -> OnboardingState {
        guard FileManager.default.fileExists(atPath: url.path) else { return OnboardingState() }
        let state = try JSONDecoder().decode(OnboardingState.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1 else {
            throw NotesError("invalid_onboarding_state", "The NotesCLI onboarding state has an unknown version.")
        }
        return state
    }

    static func save(_ state: OnboardingState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (try encoder.encode(state) + Data("\n".utf8)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try InstallManifest.recordFile(url, category: .config)
    }
}

enum Onboarding {
    static func run(options: GlobalOptions, checkOnly: Bool, skipPermissionGuide: Bool = false) throws -> OnboardingReport {
        if checkOnly { return try report(options: options, checkOnly: true) }

        var state = try OnboardingStore.load()
        if HostInstallation.sourceApp != nil {
            if HostInstallation.requiresInstallOrUpgrade || !CapabilityHostClient.isAvailable() {
                try HostInstallation.install(silent: options.json)
            }
            state.steps["host-install"] = "complete"
            state.steps["host-ready"] = CapabilityHostClient.isAvailable() ? "complete" : "pending"
            try InstallManifest.recordFile(CapabilityHostPaths.launchAgent, category: .runtime)
            try OnboardingStore.save(state)
        }
        if accessReady(options: options) {
            state.steps["access-ready"] = "complete"
            try OnboardingStore.save(state)
        } else if !skipPermissionGuide {
            try PermissionGuide.openFullDiskAccess(
                for: CapabilityHostClient.isAvailable() ? "Notes CLI" : "the app that runs notescli",
                silent: options.json
            )
        }
        return try report(options: options, checkOnly: false)
    }

    static func report(options: GlobalOptions, checkOnly: Bool) throws -> OnboardingReport {
        let access = accessReady(options: options)
        let hostAvailable = HostInstallation.sourceApp != nil || FileManager.default.fileExists(atPath: CapabilityHostPaths.app.path)
        let hostReady = CapabilityHostClient.isAvailable()
        let hostInstalled = FileManager.default.fileExists(atPath: CapabilityHostPaths.app.path) && !HostInstallation.requiresInstallOrUpgrade
        let steps = [
            OnboardingStepReport(id: "host-install", status: hostAvailable ? (hostInstalled ? "complete" : "pending") : "not_available", required: hostAvailable),
            OnboardingStepReport(id: "host-ready", status: hostAvailable ? (hostReady ? "complete" : "pending") : "not_available", required: hostAvailable),
            OnboardingStepReport(id: "access-ready", status: access ? "complete" : "pending", required: true),
        ]
        return OnboardingReport(schemaVersion: 1, checkOnly: checkOnly,
                                complete: access && (!hostAvailable || hostReady), resumable: true, steps: steps)
    }

    private static func accessReady(options: GlobalOptions) -> Bool {
        if (options.backend ?? ProcessInfo.processInfo.environment["NOTESCLI_BACKEND"]) == "fake" {
            return (try? options.backends().reader.accounts()) != nil
        }
        if CapabilityHostClient.isAvailable(),
           let captured = try? CapabilityHostClient.capture(arguments: ["doctor", "--for-agent", "--json"]),
           captured.exitCode == 0,
           let report = try? JSONDecoder().decode(AgentDoctorReport.self, from: captured.stdout) {
            return report.access.effective.available && report.access.effective.fidelity == "full"
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
        if let handle = try? FileHandle(forReadingFrom: path) {
            defer { try? handle.close() }
            if (try? handle.read(upToCount: 16)) != nil { return true }
        }
        return false
    }
}
