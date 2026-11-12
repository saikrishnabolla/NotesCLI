import Foundation

public enum MCPToolExposureProfile: Sendable {
    case local
    case remote
}

public enum MCPProtocol {
    public static let modernVersion = "2026-07-28"
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let supportedVersions = [modernVersion] + legacyVersions
    public static let protocolVersionKey = "io.modelcontextprotocol/protocolVersion"
    public static let clientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    public static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
    public static let appsExtension = "io.modelcontextprotocol/ui"
    public static let appsMIMEType = "text/html;profile=mcp-app"
    public static let widgetURI = "ui://notescli/notes-v1.html"
    public static let unsupportedVersionError = -32022
    public static let listTTL = 30_000

    static func isValidRequestID(_ value: Any) -> Bool {
        if value is String { return true }
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return false }
        let value = number.doubleValue
        return value.isFinite && value.rounded() == value
    }

    public static func supportsApps(_ capabilities: [String: Any]) -> Bool {
        guard let extensions = capabilities["extensions"] as? [String: Any],
              let ui = extensions[appsExtension] as? [String: Any],
              let mimeTypes = ui["mimeTypes"] as? [Any] else { return false }
        return mimeTypes.contains { value in
            guard let mime = value as? String else { return false }
            return isAppsMIMEType(mime)
        }
    }

    private static func isAppsMIMEType(_ value: String) -> Bool {
        let pieces = value.split(separator: ";", omittingEmptySubsequences: true)
        guard let first = pieces.first else { return false }
        let media = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard media == "text/html" else { return false }
        let pairs = pieces.dropFirst().compactMap { piece -> (String, String)? in
            let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
            return (key, value)
        }
        let parameters = pairs.reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
        return parameters["profile"] == "mcp-app"
    }
}

public final class MCPRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    fileprivate func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private enum MCPRequestIdentifier: Hashable {
    case string(String)
    case number(String)

    init?(_ value: Any) {
        if let value = value as? String {
            self = .string(value)
            return
        }
        guard MCPProtocol.isValidRequestID(value), let value = value as? NSNumber else { return nil }
        self = .number(value.stringValue)
    }
}

public final class MCPConnection: @unchecked Sendable {
    public let id: UUID
    private let lock = NSLock()
    private var legacyVersion = MCPProtocol.legacyVersions[0]
    private var legacyCapabilities: [String: Any] = [:]
    private var active: [MCPRequestIdentifier: MCPRequestCancellation] = [:]

    public init(id: UUID = UUID()) { self.id = id }

    func legacyState() -> (version: String, capabilities: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        return (legacyVersion, legacyCapabilities)
    }

    func updateLegacy(version: String, capabilities: [String: Any]) {
        lock.lock()
        legacyVersion = version
        legacyCapabilities = capabilities
        lock.unlock()
    }

    func reserve(_ requestID: Any) -> MCPRequestCancellation? {
        guard let key = MCPRequestIdentifier(requestID) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard active[key] == nil else { return nil }
        let cancellation = MCPRequestCancellation()
        active[key] = cancellation
        return cancellation
    }

    func cancel(_ requestID: Any) {
        guard let key = MCPRequestIdentifier(requestID) else { return }
        lock.lock()
        let cancellation = active[key]
        lock.unlock()
        cancellation?.cancel()
    }

    func release(_ requestID: Any, cancellation: MCPRequestCancellation) {
        guard let key = MCPRequestIdentifier(requestID) else { return }
        lock.lock()
        if active[key] === cancellation { active.removeValue(forKey: key) }
        lock.unlock()
    }
}

final class MCPPreparedRequest: @unchecked Sendable {
    let id: Any
    let method: String
    let params: [String: Any]
    let cancellation: MCPRequestCancellation

    init(id: Any, method: String, params: [String: Any], cancellation: MCPRequestCancellation) {
        self.id = id
        self.method = method
        self.params = params
        self.cancellation = cancellation
    }
}

struct MCPRequestContext {
    enum Era { case modern, legacy }
    let era: Era
    let version: String
    let apps: Bool
    let legacyAliases: Bool
    let capabilities: [String: Any]
    let cancellation: MCPRequestCancellation
}

struct MCPRPCError: Error, @unchecked Sendable {
    let code: Int
    let message: String
    let data: [String: Any]?
}

struct MCPRequestCancelled: Error {}

final class MCPOutputWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(_ handle: FileHandle) { self.handle = handle }

    func send(_ value: [String: Any]?) {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return }
        lock.lock()
        handle.write(data)
        handle.write(Data([0x0a]))
        lock.unlock()
    }
}

final class MCPExecutionGate: @unchecked Sendable {
    enum Access { case read, write }

    private let condition = NSCondition()
    private var readers = 0
    private var writer = false
    private var waitingWriters = 0

    func acquire(_ access: Access, cancellation: MCPRequestCancellation) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        switch access {
        case .read:
            while writer || waitingWriters > 0 {
                if cancellation.isCancelled { return false }
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            guard !cancellation.isCancelled else { return false }
            readers += 1
        case .write:
            waitingWriters += 1
            defer { waitingWriters -= 1 }
            while writer || readers > 0 {
                if cancellation.isCancelled { return false }
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            guard !cancellation.isCancelled else { return false }
            writer = true
        }
        return true
    }

    func release(_ access: Access) {
        condition.lock()
        switch access {
        case .read: readers -= 1
        case .write: writer = false
        }
        condition.broadcast()
        condition.unlock()
    }
}
