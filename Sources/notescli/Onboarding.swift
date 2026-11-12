import Foundation
import NotesAutomation
import NotesCore

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
    static func run(options: GlobalOptions, checkOnly: Bool) throws -> OnboardingReport {
        if checkOnly { return try report(options: options, checkOnly: true) }

        var state = try OnboardingStore.load()
        if !mcpReady() || state.steps["mcp-install"] != "complete" {
            for client in MCPClient.concrete {
                let result = try MCPConfiguration.install(client, readOnly: options.readOnly, allowNative: false)
                if !result.hasPrefix("skipped") {
                    try InstallManifest.recordMCPClient(client, readOnly: options.readOnly, allowNative: false)
                }
            }
            state.steps["mcp-install"] = "complete"
            try OnboardingStore.save(state)
        }

        if accessReady(options: options) {
            state.steps["access-ready"] = "complete"
            try OnboardingStore.save(state)
        } else if state.steps["permission-guide"] != "shown" {
            try PermissionGuide.run(silent: options.json)
            state.steps["permission-guide"] = "shown"
            try OnboardingStore.save(state)
        }
        return try report(options: options, checkOnly: false)
    }

    static func report(options: GlobalOptions, checkOnly: Bool) throws -> OnboardingReport {
        let state = try OnboardingStore.load()
        let clientsReady = mcpReady()
        let access = accessReady(options: options)
        let steps = [
            OnboardingStepReport(id: "mcp-install", status: clientsReady ? "complete" : "pending", required: true),
            OnboardingStepReport(id: "host-install", status: state.steps["host-install"] ?? "not_available", required: false),
            OnboardingStepReport(id: "host-ready", status: state.steps["host-ready"] ?? "not_available", required: false),
            OnboardingStepReport(id: "access-ready", status: access ? "complete" : "pending", required: true),
        ]
        return OnboardingReport(schemaVersion: 1, checkOnly: checkOnly,
                                complete: clientsReady && access, resumable: true, steps: steps)
    }

    private static func mcpReady() -> Bool {
        MCPClient.concrete.allSatisfy {
            let status = MCPConfiguration.status($0)
            return status == "installed" || status.hasPrefix("unavailable")
        }
    }

    private static func accessReady(options: GlobalOptions) -> Bool {
        if (options.backend ?? ProcessInfo.processInfo.environment["NOTESCLI_BACKEND"]) == "fake" {
            return (try? options.backends().reader.accounts()) != nil
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
        if let handle = try? FileHandle(forReadingFrom: path) {
            defer { try? handle.close() }
            if (try? handle.read(upToCount: 16)) != nil { return true }
        }
        return (try? ScriptingNotesReader().accounts()) != nil
    }
}
