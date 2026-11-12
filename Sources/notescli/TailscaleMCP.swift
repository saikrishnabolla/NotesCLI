import Foundation
import NotesCore
import NotesHost
import NotesSafety
import Security

struct MCPHTTPConfiguration: Codable {
    static let currentVersion = 2
    static let legacyVersion = 1
    var version: Int
    var host = "127.0.0.1"
    var port = 7362
    var path = "/notescli"
    var token: String
    var tailscaleHostname: String
    var tailscaleIPs: [String]
    var readOnly: Bool
    var allowNative: Bool
    var writeFolders: String?

    private enum CodingKeys: String, CodingKey {
        case version, host, port, path, token, tailscaleHostname, tailscaleIPs, readOnly, allowNative, writeFolders
    }

    init(token: String, tailscaleHostname: String, tailscaleIPs: [String], readOnly: Bool, allowNative: Bool,
         writeFolders: String? = nil) {
        let normalizedWriteFolders = writeFolders?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveWriteFolders = normalizedWriteFolders?.isEmpty == false ? normalizedWriteFolders : nil
        version = effectiveWriteFolders == nil ? Self.legacyVersion : Self.currentVersion
        self.token = token
        self.tailscaleHostname = tailscaleHostname
        self.tailscaleIPs = tailscaleIPs
        self.readOnly = readOnly
        self.allowNative = allowNative
        self.writeFolders = effectiveWriteFolders
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? Self.legacyVersion
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 7362
        path = try values.decodeIfPresent(String.self, forKey: .path) ?? "/notescli"
        token = try values.decode(String.self, forKey: .token)
        tailscaleHostname = try values.decode(String.self, forKey: .tailscaleHostname)
        tailscaleIPs = try values.decodeIfPresent([String].self, forKey: .tailscaleIPs) ?? []
        readOnly = try values.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        allowNative = try values.decodeIfPresent(Bool.self, forKey: .allowNative) ?? false
        writeFolders = try values.decodeIfPresent(String.self, forKey: .writeFolders)
    }

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
        let configuredAllowlist = WriteAllowlist(value.writeFolders)
        let hasValidWriteFolders = value.writeFolders == nil || (
            value.writeFolders?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && configuredAllowlist.isValid
        )
        guard [MCPHTTPConfiguration.legacyVersion, MCPHTTPConfiguration.currentVersion].contains(value.version),
              value.version != MCPHTTPConfiguration.legacyVersion || value.writeFolders == nil,
              hasValidWriteFolders,
              value.host == "127.0.0.1", (1...65535).contains(value.port),
              value.path == "/notescli", value.token.utf8.count >= 32,
              !value.tailscaleHostname.isEmpty else {
            throw NotesError("invalid_http_config", "The NotesCLI MCP HTTP configuration is invalid.")
        }
        return value
    }

    static func install(executable: String, readOnly: Bool, allowNative: Bool,
                        writeFolders: String?) throws -> MCPHTTPConfiguration {
        guard CapabilityHostClient.isAvailable() else {
            throw NotesError("capability_host_required", "Install and start NotesCLI Capability Host before publishing MCP.",
                             hint: "Run 'notescli onboard'.")
        }
        let tailscale = try tailscaleStatus()
        let existingConfiguration = try? loadConfiguration()
        let expectedTarget = "http://127.0.0.1:\(existingConfiguration?.port ?? 7362)"
        let previousRoute = try routeTarget(binary: tailscale.binary, path: "/notescli")
        if let target = previousRoute, target != expectedTarget {
            throw NotesError("tailscale_route_not_owned", "Refusing to replace a Tailscale /notescli route that points somewhere else.")
        }
        let previousConfigData = try? Data(contentsOf: MCPHTTPPaths.config)
        let previousAgentData = try? Data(contentsOf: MCPHTTPPaths.launchAgent)
        let previousAgentRunning = launchctl(["print", "gui/\(getuid())/\(label)"]).status == 0
        var config: MCPHTTPConfiguration
        if let existingConfiguration { config = existingConfiguration }
        else {
            config = MCPHTTPConfiguration(token: try newToken(), tailscaleHostname: tailscale.hostname,
                                          tailscaleIPs: tailscale.ips, readOnly: readOnly, allowNative: allowNative,
                                          writeFolders: writeFolders)
        }
        config.tailscaleHostname = tailscale.hostname
        config.tailscaleIPs = tailscale.ips
        config.readOnly = readOnly
        config.allowNative = allowNative
        if let writeFolders {
            if writeFolders.isEmpty {
                config.writeFolders = nil
            } else {
                let normalized = writeFolders.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, WriteAllowlist(normalized).isValid else {
                    throw NotesError("invalid_write_folders", "The Tailscale write-folder ceiling is invalid.")
                }
                config.writeFolders = normalized
            }
            config.version = config.writeFolders == nil ? MCPHTTPConfiguration.legacyVersion : MCPHTTPConfiguration.currentVersion
        }
        do {
            try save(config)
            try installLaunchAgent(executable: stableExecutable(executable))
            try waitForHealth("http://127.0.0.1:\(config.port)/health", code: "http_service_failed")
            let result = run(tailscale.binary, ["serve", "--bg", "--https=443", "--set-path=\(config.path)", "http://127.0.0.1:\(config.port)"],
                             environment: ["TAILSCALE_BE_CLI": "1"])
            guard result.status == 0 else {
                throw NotesError("tailscale_serve_failed", result.output.isEmpty ? "Tailscale could not publish the NotesCLI endpoint." : result.output)
            }
            guard try routeTarget(binary: tailscale.binary, path: config.path) == "http://127.0.0.1:\(config.port)" else {
                throw NotesError("tailscale_route_mismatch", "Tailscale did not install the expected NotesCLI route.")
            }
            try waitForHealth(config.endpoint + "/health", code: "tailscale_endpoint_unhealthy")
            return config
        } catch {
            let installError = error
            do {
                try rollbackInstall(binary: tailscale.binary, config: config, previousRoute: previousRoute,
                                    previousConfigData: previousConfigData, previousAgentData: previousAgentData,
                                    previousAgentRunning: previousAgentRunning)
            } catch {
                throw NotesError("tailscale_rollback_failed",
                                 "Tailscale MCP setup failed (\(installError)). Restoring the previous setup also failed (\(error)).")
            }
            throw installError
        }
    }

    static func uninstall(keepConfig: Bool = false) throws -> String {
        let config = try? loadConfiguration()
        var result = "removed"
        if let binary = tailscaleBinary() {
            let path = config?.path ?? "/notescli"
            let expected = "http://127.0.0.1:\(config?.port ?? 7362)"
            if let target = try routeTarget(binary: binary, path: path) {
                if target == expected {
                    let removal = run(binary, ["serve", "--https=443", "--set-path=\(path)", "off"], environment: ["TAILSCALE_BE_CLI": "1"])
                    if removal.status != 0, !removal.output.lowercased().contains("not found") {
                        throw NotesError("tailscale_serve_failed", removal.output.isEmpty ? "Tailscale could not remove the NotesCLI endpoint." : removal.output)
                    }
                    guard try routeTarget(binary: binary, path: path) == nil else {
                        throw NotesError("tailscale_route_mismatch", "Tailscale did not remove the NotesCLI route.")
                    }
                } else {
                    result = "kept foreign route"
                }
            }
        }
        _ = launchctl(["bootout", "gui/\(getuid())", MCPHTTPPaths.launchAgent.path])
        if FileManager.default.fileExists(atPath: MCPHTTPPaths.launchAgent.path) {
            try FileManager.default.removeItem(at: MCPHTTPPaths.launchAgent)
        }
        if !keepConfig, FileManager.default.fileExists(atPath: MCPHTTPPaths.config.path) {
            try FileManager.default.removeItem(at: MCPHTTPPaths.config)
        }
        return result
    }

    static func rotateToken() throws {
        var config = try loadConfiguration()
        config.token = try newToken()
        try save(config)
    }

    static func endpointStatus() -> [String: Any] {
        let config = try? loadConfiguration()
        let job = launchctl(["print", "gui/\(getuid())/\(label)"])
        let mounted = config.map { value in
            guard let binary = tailscaleBinary(), let target = try? routeTarget(binary: binary, path: value.path) else {
                return false
            }
            return target == "http://127.0.0.1:\(value.port)"
        } ?? false
        return [
            "configured": config != nil,
            "running": job.status == 0,
            "mounted": mounted,
            "endpoint": config?.endpoint ?? NSNull(),
            "read_only": config?.readOnly ?? false,
            "allow_native": config?.allowNative ?? false,
            "write_folders": config?.writeFolders ?? NSNull(),
        ]
    }

    private static func save(_ config: MCPHTTPConfiguration) throws {
        try FileManager.default.createDirectory(at: MCPHTTPPaths.config.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(config) + Data("\n".utf8)
        try data.write(to: MCPHTTPPaths.config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: MCPHTTPPaths.config.path)
    }

    private static func rollbackInstall(binary: String, config: MCPHTTPConfiguration, previousRoute: String?,
                                        previousConfigData: Data?, previousAgentData: Data?,
                                        previousAgentRunning: Bool) throws {
        let domain = "gui/\(getuid())"
        _ = launchctl(["bootout", domain, MCPHTTPPaths.launchAgent.path])
        for _ in 0..<20 {
            if launchctl(["print", "\(domain)/\(label)"]).status != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard launchctl(["print", "\(domain)/\(label)"]).status != 0 else {
            throw NotesError("tailscale_rollback_failed", "The replacement MCP service did not stop during rollback.")
        }
        if let previousConfigData {
            try previousConfigData.write(to: MCPHTTPPaths.config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: MCPHTTPPaths.config.path)
        } else {
            try? FileManager.default.removeItem(at: MCPHTTPPaths.config)
        }
        if let previousAgentData {
            try previousAgentData.write(to: MCPHTTPPaths.launchAgent, options: .atomic)
            if previousAgentRunning {
                let restored = launchctl(["bootstrap", domain, MCPHTTPPaths.launchAgent.path])
                guard restored.status == 0 else {
                    throw NotesError("tailscale_rollback_failed", restored.output.isEmpty ?
                                     "The previous MCP service could not be restarted." : restored.output)
                }
                if let previousConfigData,
                   let previous = try? JSONDecoder().decode(MCPHTTPConfiguration.self, from: previousConfigData) {
                    try waitForHealth("http://127.0.0.1:\(previous.port)/health", code: "tailscale_rollback_failed")
                }
            }
        } else {
            try? FileManager.default.removeItem(at: MCPHTTPPaths.launchAgent)
        }
        if let previousRoute {
            let restored = run(binary, ["serve", "--bg", "--https=443", "--set-path=\(config.path)", previousRoute],
                               environment: ["TAILSCALE_BE_CLI": "1"])
            guard restored.status == 0, try routeTarget(binary: binary, path: config.path) == previousRoute else {
                throw NotesError("tailscale_rollback_failed", restored.output.isEmpty ?
                                 "The previous Tailscale route could not be restored." : restored.output)
            }
        } else if try routeTarget(binary: binary, path: config.path) == "http://127.0.0.1:\(config.port)" {
            let removed = run(binary, ["serve", "--https=443", "--set-path=\(config.path)", "off"],
                              environment: ["TAILSCALE_BE_CLI": "1"])
            guard removed.status == 0, try routeTarget(binary: binary, path: config.path) == nil else {
                throw NotesError("tailscale_rollback_failed", removed.output.isEmpty ?
                                 "The failed Tailscale route could not be removed." : removed.output)
            }
        }
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
            "EnvironmentVariables": ["NO_COLOR": "1", "NOTESCLI_CAPABILITY_HOST": "force"],
            "StandardOutPath": MCPHTTPPaths.log.path,
            "StandardErrorPath": MCPHTTPPaths.log.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: MCPHTTPPaths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: MCPHTTPPaths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: MCPHTTPPaths.launchAgent, options: .atomic)
        let domain = "gui/\(getuid())"
        _ = launchctl(["bootout", domain, MCPHTTPPaths.launchAgent.path])
        for _ in 0..<20 {
            if launchctl(["print", "\(domain)/\(label)"]).status != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
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

    private static func waitForHealth(_ url: String, code: String) throws {
        var last = ""
        for _ in 0..<20 {
            let result = run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--max-time", "2", url])
            if result.status == 0 { return }
            last = result.output
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw NotesError(code, last.isEmpty ? "The NotesCLI MCP endpoint did not become healthy." : last)
    }

    private static func tailscaleBinary() -> String? {
        for path in ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            where FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }

    private static func routeTarget(binary: String, path: String) throws -> String? {
        let serve = run(binary, ["serve", "status", "--json"], environment: ["TAILSCALE_BE_CLI": "1"])
        guard serve.status == 0 else {
            throw NotesError("tailscale_status_failed", serve.output.isEmpty ?
                             "Tailscale Serve status could not be read." : serve.output)
        }
        guard let data = serve.output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotesError("tailscale_status_invalid", "Tailscale Serve returned invalid JSON.")
        }
        guard let rawWeb = root["Web"] else { return nil }
        guard let web = rawWeb as? [String: Any] else {
            throw NotesError("tailscale_status_invalid", "Tailscale Serve returned an invalid Web map.")
        }
        for value in web.values {
            guard let site = value as? [String: Any] else {
                throw NotesError("tailscale_status_invalid", "Tailscale Serve returned an invalid site entry.")
            }
            guard let rawHandlers = site["Handlers"], let handlers = rawHandlers as? [String: Any] else {
                throw NotesError("tailscale_status_invalid", "Tailscale Serve returned an invalid Handlers map.")
            }
            guard let rawHandler = handlers[path] else { continue }
            guard let handler = rawHandler as? [String: Any], let proxy = handler["Proxy"] as? String else {
                throw NotesError("tailscale_status_invalid", "The Tailscale /notescli route has an unsupported handler.")
            }
            return proxy
        }
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
