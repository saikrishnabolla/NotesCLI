import Foundation
import NotesCore
import NotesSafety
import Security

struct MCPHTTPConfiguration: Codable {
    static let currentVersion = 1
    var version = currentVersion
    var host = "127.0.0.1"
    var port = 7362
    var path = "/notescli"
    var token: String
    var tailscaleHostname: String
    var tailscaleIPs: [String]
    var allowNative: Bool

    var endpoint: String { "https://\(tailscaleHostname)\(path)" }
    var allowedHosts: Set<String> {
        Set(["127.0.0.1", "localhost", tailscaleHostname.lowercased()] + tailscaleIPs.map { $0.lowercased() })
    }
    var allowedOrigins: Set<String> { ["https://\(tailscaleHostname.lowercased())"] }
}

enum MCPHTTPPaths {
    static var config: URL { NotesSafetyPaths.applicationSupport.appendingPathComponent("mcp-http.json") }
    static var launchAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.saikrishnabolla.notescli.mcp-http.plist")
    }
    static var log: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/notescli-mcp-http.log")
    }
}

enum TailscaleMCP {
    static let label = "com.saikrishnabolla.notescli.mcp-http"

    struct CommandResult {
        var status: Int32
        var output: String
    }

    static func loadConfiguration() throws -> MCPHTTPConfiguration {
        let data = try Data(contentsOf: MCPHTTPPaths.config)
        let value = try JSONDecoder().decode(MCPHTTPConfiguration.self, from: data)
        guard value.version == MCPHTTPConfiguration.currentVersion,
              value.host == "127.0.0.1", (1...65535).contains(value.port),
              value.path == "/notescli", value.token.utf8.count >= 32,
              !value.tailscaleHostname.isEmpty else {
            throw NotesError("invalid_http_config", "The NotesCLI MCP HTTP configuration is invalid.")
        }
        return value
    }

    static func install(executable: String, allowNative: Bool) throws -> MCPHTTPConfiguration {
        let tailscale = try tailscaleStatus()
        var config = (try? loadConfiguration()) ?? MCPHTTPConfiguration(
            token: try newToken(),
            tailscaleHostname: tailscale.hostname,
            tailscaleIPs: tailscale.ips,
            allowNative: allowNative
        )
        config.tailscaleHostname = tailscale.hostname
        config.tailscaleIPs = tailscale.ips
        config.allowNative = allowNative
        try save(config)
        try installLaunchAgent(executable: stableExecutable(executable))
        let result = run(tailscale.binary, ["serve", "--bg", "--https=443", "--set-path=\(config.path)", "http://127.0.0.1:\(config.port)"],
                         environment: ["TAILSCALE_BE_CLI": "1"])
        guard result.status == 0 else {
            throw NotesError("tailscale_serve_failed", result.output.isEmpty ? "Tailscale could not publish the NotesCLI endpoint." : result.output)
        }
        return config
    }

    static func uninstall() throws {
        if let binary = tailscaleBinary() {
            let result = run(binary, ["serve", "--https=443", "--set-path=/notescli", "off"], environment: ["TAILSCALE_BE_CLI": "1"])
            if result.status != 0, !result.output.lowercased().contains("not found") {
                throw NotesError("tailscale_serve_failed", result.output.isEmpty ? "Tailscale could not remove the NotesCLI endpoint." : result.output)
            }
        }
        _ = launchctl(["bootout", "gui/\(getuid())", MCPHTTPPaths.launchAgent.path])
        if FileManager.default.fileExists(atPath: MCPHTTPPaths.launchAgent.path) {
            try FileManager.default.removeItem(at: MCPHTTPPaths.launchAgent)
        }
    }

    static func rotateToken() throws {
        var config = try loadConfiguration()
        config.token = try newToken()
        try save(config)
    }

    static func endpointStatus() -> [String: Any] {
        let config = try? loadConfiguration()
        let job = launchctl(["print", "gui/\(getuid())/\(label)"])
        let serve = tailscaleBinary().map { run($0, ["serve", "status", "--json"], environment: ["TAILSCALE_BE_CLI": "1"]) }
        let mounted: Bool
        if let serve, serve.status == 0, let data = serve.output.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let web = root["Web"] as? [String: Any] {
            mounted = web.values.contains { value in
                guard let site = value as? [String: Any], let handlers = site["Handlers"] as? [String: Any] else { return false }
                return handlers["/notescli"] != nil
            }
        } else { mounted = false }
        return [
            "configured": config != nil,
            "running": job.status == 0,
            "mounted": mounted,
            "endpoint": config?.endpoint ?? NSNull(),
            "allow_native": config?.allowNative ?? false,
        ]
    }

    private static func save(_ config: MCPHTTPConfiguration) throws {
        try FileManager.default.createDirectory(at: MCPHTTPPaths.config.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(config) + Data("\n".utf8)
        try data.write(to: MCPHTTPPaths.config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: MCPHTTPPaths.config.path)
    }

    private static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NotesError("token_generation_failed", "Could not create the MCP bearer token.")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func stableExecutable(_ executable: String) -> String {
        for path in ["/opt/homebrew/bin/notescli", "/usr/local/bin/notescli"]
            where FileManager.default.isExecutableFile(atPath: path) { return path }
        return executable
    }

    private static func installLaunchAgent(executable: String) throws {
        let object: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "mcp", "serve", "--http"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Background",
            "EnvironmentVariables": ["NO_COLOR": "1"],
            "StandardOutPath": MCPHTTPPaths.log.path,
            "StandardErrorPath": MCPHTTPPaths.log.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: MCPHTTPPaths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: MCPHTTPPaths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: MCPHTTPPaths.launchAgent, options: .atomic)
        let domain = "gui/\(getuid())"
        _ = launchctl(["bootout", domain, MCPHTTPPaths.launchAgent.path])
        let result = launchctl(["bootstrap", domain, MCPHTTPPaths.launchAgent.path])
        guard result.status == 0 else {
            throw NotesError("http_service_failed", result.output.isEmpty ? "launchd could not start the NotesCLI MCP endpoint." : result.output)
        }
    }

    private struct TailnetStatus {
        var binary: String
        var hostname: String
        var ips: [String]
    }

    private static func tailscaleStatus() throws -> TailnetStatus {
        guard let binary = tailscaleBinary() else { throw NotesError("tailscale_missing", "Tailscale is not installed.") }
        let result = run(binary, ["status", "--json"], environment: ["TAILSCALE_BE_CLI": "1"])
        guard result.status == 0, let data = result.output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = root["Self"] as? [String: Any] else {
            throw NotesError("tailscale_unavailable", "Tailscale is installed but is not connected.")
        }
        let hostname = (node["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !hostname.isEmpty else { throw NotesError("tailscale_dns_missing", "Tailscale MagicDNS is not available for this Mac.") }
        return TailnetStatus(binary: binary, hostname: hostname, ips: node["TailscaleIPs"] as? [String] ?? [])
    }

    private static func tailscaleBinary() -> String? {
        for path in ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            where FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }

    private static func launchctl(_ arguments: [String]) -> CommandResult {
        run("/bin/launchctl", arguments)
    }

    private static func run(_ executable: String, _ arguments: [String], environment extra: [String: String] = [:]) -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus,
                                 output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return CommandResult(status: 1, output: error.localizedDescription)
        }
    }
}
