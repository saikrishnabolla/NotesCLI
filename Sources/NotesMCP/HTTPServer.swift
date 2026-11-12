import Darwin
@preconcurrency import Dispatch
import Foundation

public enum HTTPMCPConfigurationError: Error, Equatable, Sendable {
    case invalidHeaderLimit
    case invalidBodyLimit
    case invalidTimeout
    case invalidConcurrencyLimit
    case invalidSessionLimit
    case invalidSessionTTL
}

public struct HTTPMCPEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
}

public final class HTTPMCPServer: @unchecked Sendable {
    public typealias Handler = @Sendable ([String: Any]) -> [String: Any]?
    public typealias HandlerFactory = @Sendable () -> Handler
    public typealias TokenProvider = @Sendable () -> String?

    public struct Configuration: Sendable {
        public let port: UInt16
        public let maximumHeaderBytes: Int
        public let maximumBodyBytes: Int
        public let headerTimeout: TimeInterval
        public let bodyTimeout: TimeInterval
        public let maximumConcurrentConnections: Int
        public let maximumSessions: Int
        public let sessionTTL: TimeInterval
        let authorizationPolicy: HTTPAuthorizationPolicy
        let tokenProvider: TokenProvider

        public init(
            port: UInt16 = 0,
            tokenProvider: @escaping TokenProvider,
            allowedHosts: Set<String>,
            allowedOrigins: Set<String>,
            maximumHeaderBytes: Int = 16 * 1_024,
            maximumBodyBytes: Int = 4 * 1_024 * 1_024,
            headerTimeout: TimeInterval = 10,
            bodyTimeout: TimeInterval = 30,
            maximumConcurrentConnections: Int = 16,
            maximumSessions: Int = 128,
            sessionTTL: TimeInterval = 30 * 60
        ) throws {
            guard (256...65_536).contains(maximumHeaderBytes) else {
                throw HTTPMCPConfigurationError.invalidHeaderLimit
            }
            guard (1...16 * 1_024 * 1_024).contains(maximumBodyBytes) else {
                throw HTTPMCPConfigurationError.invalidBodyLimit
            }
            guard headerTimeout >= 0.05, headerTimeout <= 120,
                  bodyTimeout >= 0.05, bodyTimeout <= 120 else {
                throw HTTPMCPConfigurationError.invalidTimeout
            }
            guard (1...128).contains(maximumConcurrentConnections) else {
                throw HTTPMCPConfigurationError.invalidConcurrencyLimit
            }
            guard (1...1_024).contains(maximumSessions) else {
                throw HTTPMCPConfigurationError.invalidSessionLimit
            }
            guard sessionTTL >= 0.05, sessionTTL <= 24 * 60 * 60 else {
                throw HTTPMCPConfigurationError.invalidSessionTTL
            }
            self.port = port
            self.maximumHeaderBytes = maximumHeaderBytes
            self.maximumBodyBytes = maximumBodyBytes
            self.headerTimeout = headerTimeout
            self.bodyTimeout = bodyTimeout
            self.maximumConcurrentConnections = maximumConcurrentConnections
            self.maximumSessions = maximumSessions
            self.sessionTTL = sessionTTL
            self.authorizationPolicy = try HTTPAuthorizationPolicy(
                allowedHosts: allowedHosts,
                allowedOrigins: allowedOrigins
            )
            self.tokenProvider = tokenProvider
        }
    }

    private struct RunningState {
        let descriptor: Int32
        let source: DispatchSourceRead
        let endpoint: HTTPMCPEndpoint
        let cancelled: DispatchSemaphore
    }

    private enum ReadFailure: Error {
        case timeout
        case closed
        case system(Int32)
        case headerTooLarge
    }

    private struct Session {
        let handler: Handler
        var lastAccess: UInt64
        var activeRequests: Int
    }

    private final class ModernInvocation: @unchecked Sendable {
        let handler: Handler
        let request: [String: Any]
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var storedResponse: [String: Any]?

        init(handler: @escaping Handler, request: [String: Any]) {
            self.handler = handler
            self.request = request
        }

        func run() {
            started.signal()
            let response = handler(request)
            lock.withLock { storedResponse = response }
            finished.signal()
        }

        var response: [String: Any]? { lock.withLock { storedResponse } }

        func cancel() {
            guard let id = request["id"] else { return }
            _ = handler([
                "jsonrpc": "2.0",
                "method": "notifications/cancelled",
                "params": ["requestId": id, "reason": "HTTP client disconnected"],
            ])
        }
    }

    private let configuration: Configuration
    private let handlerFactory: HandlerFactory
    private let stateLock = NSLock()
    private let sessionLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "notescli.mcp.http.accept")
    private let connectionQueue = DispatchQueue(label: "notescli.mcp.http.connections", attributes: .concurrent)
    private let connectionSlots: DispatchSemaphore
    private var running: RunningState?
    private var activeConnections: Set<Int32> = []
    private var sessions: [String: Session] = [:]

    public init(configuration: Configuration, handlerFactory: @escaping HandlerFactory) {
        self.configuration = configuration
        self.handlerFactory = handlerFactory
        self.connectionSlots = DispatchSemaphore(value: configuration.maximumConcurrentConnections)
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() throws -> HTTPMCPEndpoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let running { return running.endpoint }

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(Self.posixCode()) }
        var shouldClose = true
        defer { if shouldClose { Darwin.close(descriptor) } }

        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(Self.posixCode())
        }
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            throw POSIXError(Self.posixCode())
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = configuration.port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw POSIXError(.EINVAL)
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(Self.posixCode()) }
        guard Darwin.listen(descriptor, Int32(configuration.maximumConcurrentConnections)) == 0 else {
            throw POSIXError(Self.posixCode())
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0 else { throw POSIXError(Self.posixCode()) }

        let endpoint = HTTPMCPEndpoint(host: "127.0.0.1", port: UInt16(bigEndian: bound.sin_port))
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        let cancelled = DispatchSemaphore(value: 0)
        source.setEventHandler { [weak self] in self?.acceptAvailableConnections() }
        source.setCancelHandler {
            Darwin.close(descriptor)
            cancelled.signal()
        }
        running = RunningState(descriptor: descriptor, source: source, endpoint: endpoint, cancelled: cancelled)
        shouldClose = false
        source.resume()
        return endpoint
    }

    public func stop() {
        stateLock.lock()
        guard let state = running else {
            stateLock.unlock()
            return
        }
        running = nil
        let connections = activeConnections
        stateLock.unlock()

        Darwin.shutdown(state.descriptor, SHUT_RDWR)
        state.source.cancel()
        for descriptor in connections { Darwin.shutdown(descriptor, SHUT_RDWR) }
        _ = state.cancelled.wait(timeout: .now() + 2)
        sessionLock.withLock { sessions.removeAll() }
    }

    public var localEndpoint: HTTPMCPEndpoint? {
        stateLock.withLock { running?.endpoint }
    }

    private func acceptAvailableConnections() {
        while true {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let descriptor = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(currentListenerDescriptor(), $0, &length)
                }
            }
            if descriptor < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            guard stateLock.withLock({ running != nil }) else {
                Darwin.close(descriptor)
                return
            }
            guard address.sin_family == sa_family_t(AF_INET),
                  address.sin_addr.s_addr == inet_addr("127.0.0.1") else {
                Darwin.close(descriptor)
                continue
            }
            var noSignal: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }

            guard connectionSlots.wait(timeout: .now()) == .success else {
                Self.sendResponse(descriptor, status: 503, body: Self.errorBody(code: -32603, message: "Server busy"))
                Darwin.shutdown(descriptor, SHUT_WR)
                Self.drainAvailableInput(descriptor, limit: configuration.maximumHeaderBytes)
                Darwin.close(descriptor)
                continue
            }
            _ = stateLock.withLock { activeConnections.insert(descriptor) }
            connectionQueue.async { [self] in
                processConnection(descriptor)
                Self.drainAvailableInput(
                    descriptor,
                    limit: configuration.maximumHeaderBytes + configuration.maximumBodyBytes
                )
                Darwin.shutdown(descriptor, SHUT_WR)
                Darwin.close(descriptor)
                _ = stateLock.withLock { activeConnections.remove(descriptor) }
                connectionSlots.signal()
            }
        }
    }

    private func currentListenerDescriptor() -> Int32 {
        stateLock.withLock { running?.descriptor ?? -1 }
    }

    private func processConnection(_ descriptor: Int32) {
        let headData: Data
        do {
            headData = try readRequestHead(descriptor)
        } catch ReadFailure.timeout {
            Self.sendResponse(descriptor, status: 408, body: Self.errorBody(code: -32600, message: "Request timeout"))
            return
        } catch ReadFailure.headerTooLarge {
            Self.sendResponse(descriptor, status: 431, body: Self.errorBody(code: -32600, message: "Request headers too large"))
            return
        } catch {
            Self.sendResponse(descriptor, status: 400, body: Self.errorBody(code: -32600, message: "Malformed request"))
            return
        }

        let head: HTTPRequestHead
        do {
            head = try HTTPRequestHeadParser.parse(headData, maximumBytes: configuration.maximumHeaderBytes)
        } catch HTTPRequestHeadError.tooLarge {
            Self.sendResponse(descriptor, status: 431, body: Self.errorBody(code: -32600, message: "Request headers too large"))
            return
        } catch {
            Self.sendResponse(descriptor, status: 400, body: Self.errorBody(code: -32600, message: "Malformed request"))
            return
        }

        let boundary = configuration.authorizationPolicy.evaluateBoundary(head.headers)
        guard boundary == .allowed else {
            Self.sendResponse(descriptor, status: 403, body: Self.errorBody(code: -32600, message: "Forbidden"))
            return
        }

        if head.method == "GET", Self.isHealthPath(Self.path(of: head.target)) {
            guard Self.declaredBodyLength(head.headers) == 0 else {
                Self.sendResponse(descriptor, status: 400, body: Self.errorBody(code: -32600, message: "Malformed request"))
                return
            }
            Self.sendResponse(descriptor, status: 200, body: Self.jsonData([
                "ok": true,
                "transport": "streamable-http",
            ]))
            return
        }

        guard Self.isMCPPath(Self.path(of: head.target)) else {
            Self.sendResponse(descriptor, status: 404, body: Self.errorBody(code: -32601, message: "Not found"))
            return
        }

        switch configuration.authorizationPolicy.evaluate(head.headers, bearerToken: configuration.tokenProvider()) {
        case .allowed:
            break
        case .unauthorized:
            Self.sendResponse(
                descriptor,
                status: 401,
                body: Self.errorBody(code: -32600, message: "Unauthorized"),
                headers: ["WWW-Authenticate": "Bearer"]
            )
            return
        case .forbiddenHost, .forbiddenOrigin:
            Self.sendResponse(descriptor, status: 403, body: Self.errorBody(code: -32600, message: "Forbidden"))
            return
        }

        guard head.method == "POST" else {
            Self.sendResponse(descriptor, status: 405, body: Self.errorBody(code: -32600, message: "Method not allowed"), headers: ["Allow": "POST"])
            return
        }
        guard head.headers.values(named: "transfer-encoding").isEmpty,
              head.headers.values(named: "expect").isEmpty else {
            Self.sendResponse(descriptor, status: 400, body: Self.errorBody(code: -32600, message: "Unsupported request framing"))
            return
        }
        guard let length = Self.contentLength(head.headers) else {
            Self.sendResponse(descriptor, status: 411, body: Self.errorBody(code: -32600, message: "Content-Length required"))
            return
        }
        guard length <= configuration.maximumBodyBytes else {
            Self.sendResponse(descriptor, status: 413, body: Self.errorBody(code: -32600, message: "Request body too large"))
            return
        }
        guard Self.isSupportedJSONContentType(head.headers.singleValue(named: "content-type")) else {
            Self.sendResponse(descriptor, status: 415, body: Self.errorBody(code: -32600, message: "Unsupported media type"))
            return
        }
        guard Self.acceptsStreamableHTTP(head.headers.singleValue(named: "accept")) else {
            Self.sendResponse(descriptor, status: 406, body: Self.errorBody(code: -32600, message: "Not acceptable"))
            return
        }

        let body: Data
        do {
            body = try readExactly(descriptor, count: length, timeout: configuration.bodyTimeout)
        } catch ReadFailure.timeout {
            Self.sendResponse(descriptor, status: 408, body: Self.errorBody(code: -32600, message: "Request timeout"))
            return
        } catch {
            Self.sendResponse(descriptor, status: 400, body: Self.errorBody(code: -32600, message: "Incomplete request body"))
            return
        }

        let request: [String: Any]
        do {
            let value = try JSONSerialization.jsonObject(with: body)
            guard let object = value as? [String: Any] else {
                Self.sendResponse(descriptor, status: 400, body: Self.errorBody(code: -32600, message: "Invalid request"))
                return
            }
            request = object
        } catch {
            Self.sendResponse(descriptor, status: 400, body: Self.errorBody(code: -32700, message: "Parse error"))
            return
        }

        guard let protocolVersion = Self.validatedProtocolVersion(head.headers, request: request) else {
            Self.sendResponse(descriptor, status: 400, body: Self.errorBody(code: -32020, message: "MCP transport headers do not match request"))
            return
        }
        let method = request["method"] as? String
        let isLegacy = protocolVersion != MCPProtocol.modernVersion
        let suppliedSessionIDs = head.headers.values(named: "mcp-session-id")
        var sessionID: String?
        let response: [String: Any]?
        if isLegacy {
            if method == "initialize" {
                guard suppliedSessionIDs.isEmpty else {
                    Self.sendResponse(descriptor, status: 400,
                                      body: Self.errorBody(code: -32020, message: "Mcp-Session-Id is not valid during initialize"))
                    return
                }
                let sessionHandler = handlerFactory()
                response = sessionHandler(request)
                if request["id"] != nil, response?["error"] == nil {
                    guard let established = storeSession(handler: sessionHandler) else {
                        Self.sendResponse(descriptor, status: 503,
                                          body: Self.errorBody(code: -32603, message: "Session capacity reached"))
                        return
                    }
                    sessionID = established
                }
            } else {
                guard suppliedSessionIDs.count == 1, !suppliedSessionIDs[0].isEmpty else {
                    Self.sendResponse(descriptor, status: 400,
                                      body: Self.errorBody(code: -32020, message: "Mcp-Session-Id is required"))
                    return
                }
                let suppliedSessionID = suppliedSessionIDs[0]
                sessionID = suppliedSessionID
                guard let sessionHandler = acquireSession(suppliedSessionID) else {
                    Self.sendResponse(descriptor, status: 404,
                                      body: Self.errorBody(code: -32021, message: "MCP session not found"))
                    return
                }
                response = sessionHandler(request)
                releaseSession(suppliedSessionID)
            }
        } else {
            let invocation = runModernRequest(handler: handlerFactory(), request: request, descriptor: descriptor)
            response = invocation.response
            if invocation.disconnected { return }
        }
        let responseVersion = ((response?["result"] as? [String: Any])?["protocolVersion"] as? String) ?? protocolVersion
        var protocolHeaders = ["MCP-Protocol-Version": responseVersion]
        if let sessionID { protocolHeaders["Mcp-Session-Id"] = sessionID }
        if request["id"] == nil {
            Self.sendResponse(descriptor, status: 202, body: nil, headers: protocolHeaders)
            return
        }
        guard let response else {
            Self.sendResponse(descriptor, status: 202, body: nil, headers: protocolHeaders)
            return
        }
        guard JSONSerialization.isValidJSONObject(response), let responseData = Self.jsonData(response) else {
            Self.sendResponse(descriptor, status: 500, body: Self.errorBody(code: -32603, message: "Internal error"), headers: protocolHeaders)
            return
        }
        Self.sendResponse(descriptor, status: Self.httpStatus(for: response), body: responseData, headers: protocolHeaders)
    }

    private func runModernRequest(handler: @escaping Handler, request: [String: Any], descriptor: Int32)
        -> (response: [String: Any]?, disconnected: Bool) {
        let invocation = ModernInvocation(handler: handler, request: request)
        DispatchQueue.global(qos: .userInitiated).async { invocation.run() }
        invocation.started.wait()
        while invocation.finished.wait(timeout: .now() + .milliseconds(20)) != .success {
            if Self.clientDisconnected(descriptor) {
                invocation.cancel()
                if invocation.finished.wait(timeout: .now() + .milliseconds(10)) != .success {
                    invocation.cancel()
                    invocation.finished.wait()
                }
                return (invocation.response, true)
            }
        }
        return (invocation.response, false)
    }

    private static func clientDisconnected(_ descriptor: Int32) -> Bool {
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = Darwin.poll(&item, 1, 0)
        guard result > 0 else { return false }
        if item.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        guard item.revents & Int16(POLLIN) != 0 else { return false }
        var byte: UInt8 = 0
        let count = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count == 0
    }

    private func storeSession(handler: @escaping Handler) -> String? {
        sessionLock.withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            removeExpiredSessions(now: now)
            if sessions.count >= configuration.maximumSessions {
                guard let oldest = sessions
                    .filter({ $0.value.activeRequests == 0 })
                    .min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { return nil }
                sessions.removeValue(forKey: oldest)
            }
            var identifier: String
            repeat { identifier = Self.randomSessionID() } while sessions[identifier] != nil
            sessions[identifier] = Session(handler: handler, lastAccess: now, activeRequests: 0)
            return identifier
        }
    }

    private func acquireSession(_ identifier: String) -> Handler? {
        sessionLock.withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            removeExpiredSessions(now: now)
            guard var session = sessions[identifier] else { return nil }
            session.lastAccess = now
            session.activeRequests += 1
            sessions[identifier] = session
            return session.handler
        }
    }

    private func releaseSession(_ identifier: String) {
        sessionLock.withLock {
            guard var session = sessions[identifier] else { return }
            session.activeRequests = max(0, session.activeRequests - 1)
            session.lastAccess = DispatchTime.now().uptimeNanoseconds
            sessions[identifier] = session
        }
    }

    private func removeExpiredSessions(now: UInt64) {
        let ttl = UInt64(configuration.sessionTTL * 1_000_000_000)
        sessions = sessions.filter { _, session in
            session.activeRequests > 0 || now < session.lastAccess || now - session.lastAccess < ttl
        }
    }

    private static func randomSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeMutableBytes { buffer in
            arc4random_buf(buffer.baseAddress, buffer.count)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func readRequestHead(_ descriptor: Int32) throws -> Data {
        let deadline = Self.deadline(after: configuration.headerTimeout)
        var head = Data()
        var currentLine = Data()
        var peekBuffer = [UInt8](repeating: 0, count: min(4_096, configuration.maximumHeaderBytes + 1))

        while true {
            try Self.waitUntilReadable(descriptor, deadline: deadline)
            let count = Darwin.recv(descriptor, &peekBuffer, peekBuffer.count, MSG_PEEK)
            if count == 0 { throw ReadFailure.closed }
            if count < 0 {
                if errno == EINTR { continue }
                throw ReadFailure.system(errno)
            }
            let bytesToConsume: Int
            if let newline = peekBuffer[..<count].firstIndex(of: 10) {
                bytesToConsume = newline + 1
            } else {
                bytesToConsume = count
            }
            let chunk = try readExactly(descriptor, count: bytesToConsume, deadline: deadline)
            head.append(chunk)
            currentLine.append(chunk)
            guard head.count <= configuration.maximumHeaderBytes else { throw ReadFailure.headerTooLarge }
            if currentLine.last == 10 {
                guard currentLine.count >= 2, currentLine[currentLine.count - 2] == 13 else {
                    throw ReadFailure.system(EINVAL)
                }
                if currentLine == Data([13, 10]) { return head }
                currentLine.removeAll(keepingCapacity: true)
            }
        }
    }

    private func readExactly(_ descriptor: Int32, count: Int, timeout: TimeInterval) throws -> Data {
        try readExactly(descriptor, count: count, deadline: Self.deadline(after: timeout))
    }

    private func readExactly(_ descriptor: Int32, count: Int, deadline: UInt64) throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { throw ReadFailure.system(ENOMEM) }
            while offset < count {
                try Self.waitUntilReadable(descriptor, deadline: deadline)
                let received = Darwin.recv(descriptor, base.advanced(by: offset), count - offset, 0)
                if received > 0 {
                    offset += received
                } else if received == 0 {
                    throw ReadFailure.closed
                } else if errno != EINTR {
                    throw ReadFailure.system(errno)
                }
            }
        }
        return result
    }

    private static func waitUntilReadable(_ descriptor: Int32, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ReadFailure.timeout }
            let remainingNanoseconds = deadline - now
            let milliseconds = Int32(min(UInt64(Int32.max), max(1, (remainingNanoseconds + 999_999) / 1_000_000)))
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&item, 1, milliseconds)
            if result > 0 {
                if item.revents & Int16(POLLIN | POLLHUP) != 0 { return }
                throw ReadFailure.system(EIO)
            }
            if result == 0 { throw ReadFailure.timeout }
            if errno != EINTR { throw ReadFailure.system(errno) }
        }
    }

    private static func deadline(after timeout: TimeInterval) -> UInt64 {
        let duration = UInt64(timeout * 1_000_000_000)
        return DispatchTime.now().uptimeNanoseconds &+ duration
    }

    private static func contentLength(_ headers: HTTPHeaders) -> Int? {
        guard let raw = headers.singleValue(named: "content-length"),
              !raw.isEmpty,
              raw.allSatisfy(\.isNumber),
              raw.count <= 10,
              let value = Int(raw),
              value >= 0 else {
            return nil
        }
        return value
    }

    private static func declaredBodyLength(_ headers: HTTPHeaders) -> Int? {
        let values = headers.values(named: "content-length")
        return values.isEmpty ? 0 : contentLength(headers)
    }

    private static func isSupportedJSONContentType(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard parts.first == "application/json" else { return false }
        if parts.count == 1 { return true }
        guard parts.count == 2 else { return false }
        return parts[1] == "charset=utf-8" || parts[1] == "charset=\"utf-8\""
    }

    private static func acceptsStreamableHTTP(_ raw: String?) -> Bool {
        guard let raw else { return false }
        var acceptsJSON = false
        var acceptsEvents = false
        for item in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = item.split(separator: ";", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard let mediaType = parts.first, !mediaType.isEmpty else { return false }
            var quality = 1.0
            for parameter in parts.dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if pair.first == "q" {
                    guard pair.count == 2, let parsed = Double(pair[1]), (0...1).contains(parsed) else {
                        return false
                    }
                    quality = parsed
                }
            }
            if quality > 0, mediaType == "application/json" { acceptsJSON = true }
            if quality > 0, mediaType == "text/event-stream" { acceptsEvents = true }
        }
        return acceptsJSON && acceptsEvents
    }

    private static func validatedProtocolVersion(_ headers: HTTPHeaders, request: [String: Any]) -> String? {
        guard let method = request["method"] as? String else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        let metadata = params["_meta"] as? [String: Any]
        let headerVersion = headers.singleValue(named: "mcp-protocol-version")

        guard let bodyVersion = metadata?[MCPProtocol.protocolVersionKey] as? String else {
            if method == "initialize" {
                guard let requested = params["protocolVersion"] as? String,
                      requested != MCPProtocol.modernVersion else { return nil }
                if let headerVersion, headerVersion != requested { return nil }
                return MCPProtocol.legacyVersions.contains(requested) ? requested : MCPProtocol.legacyVersions[0]
            }
            guard let headerVersion, MCPProtocol.legacyVersions.contains(headerVersion) else { return nil }
            if let declaredMethod = headers.singleValue(named: "mcp-method"), declaredMethod != method { return nil }
            return headerVersion
        }

        guard bodyVersion == MCPProtocol.modernVersion,
              headerVersion == bodyVersion,
              headers.singleValue(named: "mcp-method") == method else { return nil }
        let bodyName: String?
        switch method {
        case "tools/call", "prompts/get":
            bodyName = params["name"] as? String
        case "resources/read":
            bodyName = params["uri"] as? String
        default:
            bodyName = nil
        }
        if let bodyName {
            return headers.singleValue(named: "mcp-name") == bodyName ? bodyVersion : nil
        }
        return headers.values(named: "mcp-name").isEmpty ? bodyVersion : nil
    }

    private static func path(of target: String) -> String {
        String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    private static func isHealthPath(_ path: String) -> Bool {
        path == "/health" || path == "/notescli/health"
    }

    private static func isMCPPath(_ path: String) -> Bool {
        path == "/" || path == "/notescli"
    }

    private static func httpStatus(for response: [String: Any]) -> Int {
        guard let error = response["error"] as? [String: Any], let code = error["code"] as? Int else { return 200 }
        switch code {
        case -32601: return 404
        case -32700, -32600, -32602, -32020, -32021, -32022: return 400
        default: return 500
        }
    }

    private static func errorBody(code: Int, message: String) -> Data? {
        jsonData([
            "jsonrpc": "2.0",
            "id": NSNull(),
            "error": ["code": code, "message": message],
        ])
    }

    private static func jsonData(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func sendResponse(
        _ descriptor: Int32,
        status: Int,
        body: Data?,
        headers: [String: String] = [:]
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 406: reason = "Not Acceptable"
        case 408: reason = "Request Timeout"
        case 411: reason = "Length Required"
        case 413: reason = "Content Too Large"
        case 415: reason = "Unsupported Media Type"
        case 431: reason = "Request Header Fields Too Large"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n"
        for key in headers.keys.sorted() { head += "\(key): \(headers[key]!)\r\n" }
        head += "\r\n"
        var response = Data(head.utf8)
        if let body { response.append(body) }
        response.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.send(descriptor, base.advanced(by: sent), rawBuffer.count - sent, 0)
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private static func drainAvailableInput(_ descriptor: Int32, limit: Int) {
        var remaining = limit
        var buffer = [UInt8](repeating: 0, count: min(4_096, limit))
        while remaining > 0 {
            let count = Darwin.recv(descriptor, &buffer, min(buffer.count, remaining), MSG_DONTWAIT)
            if count > 0 {
                remaining -= count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private static func posixCode() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
