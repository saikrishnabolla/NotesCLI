import Foundation

public enum HTTPRequestHeadError: Error, Equatable, Sendable {
    case tooLarge
    case invalidEncoding
    case malformedRequestLine
    case unsupportedHTTPVersion
    case malformedHeader
    case duplicateHeader(String)
    case obsoleteLineFolding
    case tooManyHeaders
}

public struct HTTPHeaders: Sendable, Equatable {
    private let storage: [String: [String]]

    init(storage: [String: [String]]) {
        self.storage = storage
    }

    public func values(named name: String) -> [String] {
        storage[name.lowercased()] ?? []
    }

    public func singleValue(named name: String) -> String? {
        let values = values(named: name)
        return values.count == 1 ? values[0] : nil
    }
}

public struct HTTPRequestHead: Sendable, Equatable {
    public let method: String
    public let target: String
    public let version: String
    public let headers: HTTPHeaders
}

public enum HTTPRequestHeadParser {
    public static func parse(_ data: Data, maximumBytes: Int) throws -> HTTPRequestHead {
        guard data.count <= maximumBytes else { throw HTTPRequestHeadError.tooLarge }
        guard data.suffix(4) == Data([13, 10, 13, 10]) else {
            throw HTTPRequestHeadError.malformedHeader
        }
        guard let text = String(data: data.dropLast(4), encoding: .utf8) else {
            throw HTTPRequestHeadError.invalidEncoding
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPRequestHeadError.malformedRequestLine }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              !requestParts[0].isEmpty,
              !requestParts[1].isEmpty else {
            throw HTTPRequestHeadError.malformedRequestLine
        }
        guard requestParts[2] == "HTTP/1.1" else { throw HTTPRequestHeadError.unsupportedHTTPVersion }
        guard requestParts[0].allSatisfy(isTokenCharacter),
              requestParts[1].first == "/",
              requestParts[1].allSatisfy({
                  $0.isASCII && ($0.asciiValue ?? 0) >= 0x21 && ($0.asciiValue ?? 0) < 0x7f
              }) else {
            throw HTTPRequestHeadError.malformedRequestLine
        }

        let headerLines = lines.dropFirst()
        guard headerLines.count <= 64 else { throw HTTPRequestHeadError.tooManyHeaders }
        var headers: [String: [String]] = [:]
        for line in headerLines {
            guard let first = line.first else { throw HTTPRequestHeadError.malformedHeader }
            if first == " " || first == "\t" { throw HTTPRequestHeadError.obsoleteLineFolding }
            guard let colon = line.firstIndex(of: ":") else { throw HTTPRequestHeadError.malformedHeader }
            let namePart = line[..<colon]
            guard !namePart.isEmpty, namePart.allSatisfy(isTokenCharacter) else {
                throw HTTPRequestHeadError.malformedHeader
            }
            let valueStart = line.index(after: colon)
            let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
            guard value.unicodeScalars.allSatisfy({ scalar in
                scalar.value == 9 || (scalar.value >= 0x20 && scalar.value != 0x7f)
            }) else {
                throw HTTPRequestHeadError.malformedHeader
            }
            let name = namePart.lowercased()
            headers[name, default: []].append(value)
        }
        for name in ["content-length", "transfer-encoding"] where (headers[name]?.count ?? 0) > 1 {
            throw HTTPRequestHeadError.duplicateHeader(name)
        }
        return HTTPRequestHead(
            method: String(requestParts[0]),
            target: String(requestParts[1]),
            version: String(requestParts[2]),
            headers: HTTPHeaders(storage: headers)
        )
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        guard character.isASCII, let value = character.asciiValue else { return false }
        if (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) { return true }
        return "!#$%&'*+-.^_`|~".utf8.contains(value)
    }
}

public enum HTTPAuthorizationDecision: Equatable, Sendable {
    case allowed
    case unauthorized
    case forbiddenHost
    case forbiddenOrigin
}

public enum HTTPAuthorizationPolicyError: Error, Equatable, Sendable {
    case invalidHost(String)
    case invalidOrigin(String)
    case emptyHostAllowlist
}

public struct HTTPAuthorizationPolicy: Sendable {
    private let allowedHosts: Set<String>
    private let allowedOrigins: Set<String>

    public init(allowedHosts: Set<String>, allowedOrigins: Set<String>) throws {
        guard !allowedHosts.isEmpty else { throw HTTPAuthorizationPolicyError.emptyHostAllowlist }
        self.allowedHosts = try Set(allowedHosts.map { host in
            guard let normalized = Self.normalizedHost(host), !normalized.isEmpty else {
                throw HTTPAuthorizationPolicyError.invalidHost(host)
            }
            return normalized
        })
        self.allowedOrigins = try Set(allowedOrigins.map { origin in
            guard let normalized = Self.normalizedOrigin(origin) else {
                throw HTTPAuthorizationPolicyError.invalidOrigin(origin)
            }
            return normalized
        })
    }

    public func evaluate(_ headers: HTTPHeaders, bearerToken: String?) -> HTTPAuthorizationDecision {
        switch evaluateBoundary(headers) {
        case .allowed:
            break
        case let decision:
            return decision
        }
        guard let authorization = headers.singleValue(named: "authorization") else {
            return .unauthorized
        }
        let pieces = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard pieces.count == 2,
              pieces[0].lowercased() == "bearer",
              let bearerToken,
              !bearerToken.isEmpty else {
            return .unauthorized
        }
        return constantTimeEqual(Array(pieces[1].utf8), Array(bearerToken.utf8)) ? .allowed : .unauthorized
    }

    func evaluateBoundary(_ headers: HTTPHeaders) -> HTTPAuthorizationDecision {
        guard let rawHost = headers.singleValue(named: "host"),
              let host = Self.normalizedHost(rawHost),
              allowedHosts.contains(host) else {
            return .forbiddenHost
        }
        let origins = headers.values(named: "origin")
        if !origins.isEmpty {
            guard origins.count == 1,
                  let origin = Self.normalizedOrigin(origins[0]),
                  allowedOrigins.contains(origin) else {
                return .forbiddenOrigin
            }
        }
        return .allowed
    }

    private static func normalizedHost(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains("@"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            return nil
        }
        if value.first == "[" {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<close])
            let remainder = value[value.index(after: close)...]
            guard !host.isEmpty,
                  remainder.isEmpty || (remainder.first == ":" && remainder.dropFirst().allSatisfy(\.isNumber)) else {
                return nil
            }
            return host
        }
        let colonCount = value.filter { $0 == ":" }.count
        if colonCount == 0 { return value }
        if colonCount == 1, let colon = value.lastIndex(of: ":") {
            let port = value[value.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
            return String(value[..<colon])
        }
        return value
    }

    private static func normalizedOrigin(_ raw: String) -> String? {
        guard raw != "null", let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = components.port.flatMap { $0 == defaultPort ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    private func constantTimeEqual(_ candidate: [UInt8], _ expected: [UInt8]) -> Bool {
        var difference = UInt(candidate.count ^ expected.count)
        let count = max(candidate.count, expected.count)
        for index in 0..<count {
            let left = index < candidate.count ? candidate[index] : 0
            let right = index < expected.count ? expected[index] : 0
            difference |= UInt(left ^ right)
        }
        return difference == 0
    }
}
