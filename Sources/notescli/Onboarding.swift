import Darwin
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

    var needsFullDiskAccess: Bool { steps.contains { $0.id == "access-ready" && $0.status == "pending" } }
}

enum OnboardingInteraction {
    static func canShowPermissionGuide(json: Bool, stdinIsTTY: Bool, stdoutIsTTY: Bool,
                                       environment: [String: String]) -> Bool {
        !json && stdinIsTTY && stdoutIsTTY && environment["SSH_CONNECTION"] == nil &&
            environment["SSH_TTY"] == nil && environment["NOTESCLI_HOST_ACTIVE"] != "1"
    }
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
        let app = CapabilityHostPaths.app
        let hostSource = HostInstallation.sourceApp
        var hostInstalled = hostSource != nil && HostInstallation.isCurrentInstall
        var hostReady = hostInstalled && CapabilityHostClient.isAvailable()
        if hostSource != nil {
            if !hostInstalled || !hostReady {
                try HostInstallation.install(silent: true)
                hostInstalled = true
                hostReady = true
            }
            state.steps["host-install"] = "complete"
            state.steps["host-ready"] = "complete"
            try InstallManifest.recordFile(CapabilityHostPaths.launchAgent, category: .runtime)
            try OnboardingStore.save(state)
        }
        var status = statusReport(options: options, checkOnly: false, hostAvailable: hostSource != nil,
                                  hostInstalled: hostInstalled, hostReady: hostReady)
        if !skipPermissionGuide && status.needsFullDiskAccess {
            let installedApp = hostInstalled ? app : nil
            if OnboardingInteraction.canShowPermissionGuide(json: options.json, stdinIsTTY: isatty(STDIN_FILENO) == 1,
                stdoutIsTTY: isatty(STDOUT_FILENO) == 1, environment: ProcessInfo.processInfo.environment) {
                if let app = installedApp, hostReady, Thread.isMainThread,
                   let granted = MainActor.assumeIsolated({
                       PermissionStrip.run(app: app, openSettings: PermissionGuide.openSettings,
                                           probe: { CapabilityHostClient.notesAccessReady() == true })
                   }) {
                    if granted {
                        status = statusReport(options: options, checkOnly: false, hostAvailable: true,
                                              hostInstalled: true, hostReady: true, verifiedAccess: true)
                    } else {
                        print("Full Disk Access is still pending. Run 'notescli onboard' to resume.")
                    }
                } else {
                    PermissionGuide.openFullDiskAccess(revealing: installedApp)
                }
            } else if !options.json {
                print("Full Disk Access is still pending. Run 'notescli onboard' in Terminal to finish setup.")
            }
        } else if !options.json, status.steps.contains(where: { $0.id == "access-ready" && $0.status == "unavailable" }) {
            print("Could not check Full Disk Access. Run 'notescli host status', then retry 'notescli onboard'.")
        }
        if status.complete {
            state.steps["access-ready"] = "complete"
            try OnboardingStore.save(state)
        }
        return status
    }

    static func report(options: GlobalOptions, checkOnly: Bool) throws -> OnboardingReport {
        let hostAvailable = HostInstallation.sourceApp != nil
        let hostInstalled = hostAvailable && HostInstallation.isCurrentInstall
        return statusReport(options: options, checkOnly: checkOnly, hostAvailable: hostAvailable,
                            hostInstalled: hostInstalled, hostReady: hostInstalled && CapabilityHostClient.isAvailable())
    }

    private static func statusReport(options: GlobalOptions, checkOnly: Bool, hostAvailable: Bool, hostInstalled: Bool,
                                     hostReady: Bool, verifiedAccess: Bool = false) -> OnboardingReport {
        let access = verifiedAccess ? true : accessReady(options: options, hostAvailable: hostAvailable, hostReady: hostReady)
        let steps = [
            OnboardingStepReport(id: "host-install", status: hostAvailable ? (hostInstalled ? "complete" : "pending") : "not_available", required: hostAvailable),
            OnboardingStepReport(id: "host-ready", status: hostAvailable ? (hostReady ? "complete" : "pending") : "not_available", required: hostAvailable),
            OnboardingStepReport(id: "access-ready", status: access.map { $0 ? "complete" : "pending" } ?? "unavailable", required: true),
        ]
        return OnboardingReport(schemaVersion: 1, checkOnly: checkOnly,
                                complete: access == true && (!hostAvailable || (hostInstalled && hostReady)),
                                resumable: true, steps: steps)
    }

    private static func accessReady(options: GlobalOptions, hostAvailable: Bool, hostReady: Bool) -> Bool? {
        if (options.backend ?? ProcessInfo.processInfo.environment["NOTESCLI_BACKEND"]) == "fake" {
            return (try? options.backends().reader.accounts()) != nil
        }
        if hostAvailable {
            return hostReady ? CapabilityHostClient.notesAccessReady() : nil
        }
        return HostNotesAccess.canReadStoreHeader()
    }
}
