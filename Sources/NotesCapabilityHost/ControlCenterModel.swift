import AppKit
import Foundation

enum ReadinessLevel: String {
    case ready = "Ready"
    case limited = "Limited"
    case needsAttention = "Needs attention"

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .limited: "exclamationmark.circle.fill"
        case .needsAttention: "xmark.circle.fill"
        }
    }
}

struct PermissionStatus: Identifiable {
    let id: String
    let name: String
    var status: String
    var required: Bool

    var isGranted: Bool {
        ["authorized", "available", "granted", "full"].contains(status.lowercased())
    }
}

struct AgentStatus: Identifiable {
    let id: String
    let name: String
    var detected: Bool
    var connected: Bool
    var detail: String
}

private struct DoctorReport: Decodable {
    struct Readiness: Decodable { let ready: Bool; let blockers: [String] }
    struct Permission: Decodable { let status: String; let required: Bool }
    struct Access: Decodable {
        struct Effective: Decodable { let available: Bool; let fidelity: String }
        let effective: Effective
    }
    let readiness: Readiness
    let permissions: [String: Permission]?
    let access: Access
}

private struct MCPStatusReport: Decodable {
    let client: String
    let label: String
    let available: Bool
    let connected: Bool
    let status: String
    let configured: Bool?
    let running: Bool?
    let mounted: Bool?
    let endpoint: String?
    let readOnly: Bool?
    let writeFolders: String?

    private enum CodingKeys: String, CodingKey {
        case client, label, available, connected, status, configured, running, mounted, endpoint
        case readOnly = "read_only"
        case writeFolders = "write_folders"
    }
}

private struct OnboardingReport: Decodable {
    let complete: Bool
}

@MainActor
final class ControlCenterModel: ObservableObject {
    @Published var readiness: ReadinessLevel = .needsAttention
    @Published var readinessDetail = "Checking Notes CLI…"
    @Published var permissions: [PermissionStatus] = ControlCenterModel.defaultPermissions
    @Published var agents: [AgentStatus] = ControlCenterModel.defaultAgents
    @Published var tailscaleConnected = false
    @Published var tailscaleEndpoint: String?
    @Published var tailscaleReadOnly = true
    @Published var tailscaleWriteFolders = ""
    @Published var version = "Checking…"
    @Published var repairNeeded = false
    @Published var isRefreshing = false
    @Published var activeAction: String?
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var showUninstallConfirmation = false

    private let runner: CLIProcessRunner

    init(runner: CLIProcessRunner) {
        self.runner = runner
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        async let doctorResult = runner.run(["doctor", "--for-agent", "--json"])
        async let statusResult = runner.run(["mcp", "status", "--json"])
        async let versionResult = runner.run(["--version"])
        async let onboardResult = runner.run(["onboard", "--check-only", "--json"])

        do {
            let (doctor, status, versionResult, onboard) = try await (doctorResult, statusResult, versionResult, onboardResult)
            applyDoctor(doctor)
            applyMCPStatus(status)
            version = versionResult.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "NotesCLI", with: "Notes CLI", options: .caseInsensitive)
            if let report = try? decode(OnboardingReport.self, from: onboard.standardOutput) {
                repairNeeded = !report.complete
            } else {
                repairNeeded = true
            }
        } catch {
            readiness = .needsAttention
            readinessDetail = "Notes CLI could not check its status."
            errorMessage = concise(error.localizedDescription)
        }
    }

    func requestPermissions() async {
        await perform("permissions", success: "Permission settings opened.") {
            _ = try await runner.requireSuccess(["permissions"])
        }
    }

    func setAgent(_ agent: AgentStatus, connected: Bool) async {
        await perform("agent-\(agent.id)", success: connected ? "Connected \(agent.name)." : "Disconnected \(agent.name).") {
            let command = connected ? "install" : "uninstall"
            _ = try await runner.requireSuccess(["mcp", command, "--client", agent.id])
        }
    }

    func setTailscale(connected: Bool) async {
        await perform("tailscale", success: connected ? "Remote access is ready." : "Remote access was removed.") {
            let command = connected ? "install" : "uninstall"
            var arguments = ["mcp", command, "--client", "tailscale"]
            if connected {
                if tailscaleReadOnly {
                    arguments.append("--read-only")
                } else {
                    arguments.append(contentsOf: ["--write-folders", tailscaleWriteFolders])
                }
            }
            _ = try await runner.requireSuccess(arguments)
        }
    }

    func applyTailscaleSettings() async {
        await setTailscale(connected: true)
    }

    func repair() async {
        await perform("repair", success: "Notes CLI is repaired.") {
            _ = try await runner.requireSuccess(["onboard", "--json"])
        }
    }

    func createSampleReport() async {
        await perform("report", success: "Created the sample research report in Notes.") {
            try await createTemporaryReport()
        }
    }

    func uninstall() async {
        await perform("uninstall", success: "Notes CLI was removed.", refreshAfterward: false) {
            _ = try await runner.requireSuccess(["uninstall"])
        }
    }

    private func perform(
        _ action: String,
        success: String,
        refreshAfterward: Bool = true,
        operation: () async throws -> Void
    ) async {
        guard activeAction == nil else { return }
        activeAction = action
        errorMessage = nil
        successMessage = nil
        defer { activeAction = nil }
        do {
            try await operation()
            successMessage = success
            if refreshAfterward { await refresh() }
        } catch {
            errorMessage = concise(error.localizedDescription)
        }
    }

    private func applyDoctor(_ result: CLICommandResult) {
        guard result.exitCode == 0, let report = try? decode(DoctorReport.self, from: result.standardOutput) else {
            readiness = .needsAttention
            readinessDetail = "Run Repair to check Notes access."
            return
        }
        let resolvedPermissions = Self.defaultPermissions.map { item in
            guard let value = report.permissions?[item.id] else { return item }
            return PermissionStatus(id: item.id, name: item.name, status: value.status, required: value.required)
        }
        permissions = resolvedPermissions
        let requiredPermissionsGranted = resolvedPermissions
            .filter(\.required)
            .allSatisfy(\.isGranted)
        if report.readiness.ready,
           report.access.effective.available,
           report.access.effective.fidelity.lowercased() == "full",
           requiredPermissionsGranted {
            readiness = .ready
            readinessDetail = "Notes and connected agents are ready."
        } else if report.access.effective.available {
            readiness = .limited
            readinessDetail = report.access.effective.fidelity.lowercased() == "full"
                ? "One or more required permissions need attention."
                : "Notes CLI is available with \(report.access.effective.fidelity) access."
        } else {
            readiness = .needsAttention
            readinessDetail = report.readiness.blockers.first?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Setup needs attention."
        }
    }

    private func applyMCPStatus(_ result: CLICommandResult) {
        if result.exitCode == 0, let reports = try? decode([MCPStatusReport].self, from: result.standardOutput) {
            let byID = Dictionary(uniqueKeysWithValues: reports.map { ($0.client, $0) })
            agents = Self.defaultAgents.map { item in
                guard let value = byID[item.id] else { return detectedAgent(item) }
                return AgentStatus(id: item.id, name: item.name, detected: value.available, connected: value.connected, detail: value.status)
            }
            if let remote = byID["tailscale"] {
                tailscaleConnected = remote.connected && (remote.configured ?? true) && (remote.running ?? true) && (remote.mounted ?? true)
                tailscaleEndpoint = remote.endpoint
                if remote.configured == true {
                    tailscaleReadOnly = remote.readOnly ?? true
                    tailscaleWriteFolders = remote.writeFolders ?? ""
                }
            }
            return
        }
        agents = Self.defaultAgents.map(detectedAgent)
    }

    private func detectedAgent(_ item: AgentStatus) -> AgentStatus {
        let paths: [String]
        switch item.id {
        case "claude-code": paths = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case "claude-desktop": paths = ["/Applications/Claude.app"]
        case "codex": paths = ["/Applications/Codex.app", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        case "cursor": paths = ["/Applications/Cursor.app"]
        case "vscode": paths = ["/Applications/Visual Studio Code.app"]
        default: paths = []
        }
        var copy = item
        copy.detected = paths.contains { FileManager.default.fileExists(atPath: $0) }
        copy.detail = copy.detected ? "Not connected" : "Not detected"
        return copy
    }

    private func createTemporaryReport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-cli-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("research-overview.png")
        try Self.writeSampleImage(to: imageURL)
        let attachmentURL = directory.appendingPathComponent("sources.txt")
        try "Notes CLI sample report source list.\n".write(to: attachmentURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: attachmentURL.path)
        let markdownURL = directory.appendingPathComponent("report.md")
        let markdown = """
        # Research Brief

        ## Summary

        This report shows how an agent can turn research into a structured Apple Note. Learn more at [Apple Notes](https://support.apple.com/guide/notes/welcome/mac).

        ![Research overview](research-overview.png)

        ## Findings

        | Area | Result |
        | --- | --- |
        | Sources | Collected |
        | Evidence | Organized |
        | Follow-up | Ready |

        ## Next steps

        - [x] Collect sources
        - [x] Compare findings
        - [ ] Share the final brief

        ```svg
        <svg xmlns="http://www.w3.org/2000/svg" width="640" height="220" viewBox="0 0 640 220">
          <rect x="20" y="70" width="160" height="80" rx="16" fill="#E8F1FF" stroke="#3478F6"/>
          <rect x="240" y="70" width="160" height="80" rx="16" fill="#EAF7EE" stroke="#34A853"/>
          <rect x="460" y="70" width="160" height="80" rx="16" fill="#FFF3E0" stroke="#F29900"/>
          <path d="M180 110 H240 M400 110 H460" stroke="#666" stroke-width="3" marker-end="url(#arrow)"/>
          <defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#666"/></marker></defs>
          <text x="100" y="118" text-anchor="middle" font-family="-apple-system" font-size="20">Research</text>
          <text x="320" y="118" text-anchor="middle" font-family="-apple-system" font-size="20">Synthesize</text>
          <text x="540" y="118" text-anchor="middle" font-family="-apple-system" font-size="20">Report</text>
        </svg>
        ```

        #notes-cli #research
        """
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markdownURL.path)
        _ = try await runner.requireSuccess([
            "report", "create",
            "--json",
            "--title", "Notes CLI Sample Research Report",
            "--file", markdownURL.path,
            "--tags", "notes-cli,research",
            "--replace",
            "--attach", attachmentURL.path,
        ])
    }

    private static func writeSampleImage(to url: URL) throws {
        let size = NSSize(width: 960, height: 540)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 80, y: 90, width: 800, height: 360), xRadius: 28, yRadius: 28).fill()
        let text = "Research → Evidence → Notes"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 42, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CLIProcessError.failedToLaunch("Could not create the sample report image.")
        }
        try png.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(string.utf8))
    }

    private func concise(_ message: String) -> String {
        let productMessage = message
            .replacingOccurrences(of: "NotesCLI Capability Host", with: "Notes CLI", options: .caseInsensitive)
            .replacingOccurrences(of: "capability host", with: "Notes CLI", options: .caseInsensitive)
            .replacingOccurrences(of: "capability-host", with: "Notes CLI", options: .caseInsensitive)
            .replacingOccurrences(of: "NotesCLI", with: "Notes CLI", options: .caseInsensitive)
        let line = productMessage.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? productMessage
        return line.count > 220 ? String(line.prefix(217)) + "…" : line
    }

    private static let defaultPermissions = [
        PermissionStatus(id: "fullDiskAccess", name: "Full Disk Access", status: "Checking", required: true),
        PermissionStatus(id: "notesAutomation", name: "Notes Automation", status: "Checking", required: true),
        PermissionStatus(id: "speechRecognition", name: "Speech Recognition", status: "Checking", required: false),
        PermissionStatus(id: "camera", name: "Camera", status: "Checking", required: false),
    ]

    private static let defaultAgents = [
        AgentStatus(id: "claude-code", name: "Claude Code", detected: false, connected: false, detail: "Checking"),
        AgentStatus(id: "claude-desktop", name: "Claude Desktop", detected: false, connected: false, detail: "Checking"),
        AgentStatus(id: "codex", name: "Codex", detected: false, connected: false, detail: "Checking"),
        AgentStatus(id: "cursor", name: "Cursor", detected: false, connected: false, detail: "Checking"),
        AgentStatus(id: "vscode", name: "VS Code", detected: false, connected: false, detail: "Checking"),
    ]
}
