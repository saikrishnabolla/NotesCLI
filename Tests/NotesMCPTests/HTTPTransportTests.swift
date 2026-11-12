import Darwin
import Foundation
import XCTest
@testable import NotesMCP

final class HTTPTransportTests: XCTestCase, @unchecked Sendable {
    func testRequestHeadParserNormalizesHeadersAndRejectsAmbiguousFraming() throws {
        let parsed = try HTTPRequestHeadParser.parse(Data(
            "POST /mcp HTTP/1.1\r\nHost: localhost:7777\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 2\r\n\r\n".utf8
        ), maximumBytes: 1_024)

        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.target, "/mcp")
        XCTAssertEqual(parsed.headers.singleValue(named: "host"), "localhost:7777")

        XCTAssertThrowsError(try HTTPRequestHeadParser.parse(Data(
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n".utf8
        ), maximumBytes: 1_024)) { error in
            XCTAssertEqual(error as? HTTPRequestHeadError, .duplicateHeader("content-length"))
        }

        XCTAssertThrowsError(try HTTPRequestHeadParser.parse(Data(
            "POST / HTTP/1.1\r\nHost: localhost\r\n Folded: no\r\n\r\n".utf8
        ), maximumBytes: 1_024)) { error in
            XCTAssertEqual(error as? HTTPRequestHeadError, .obsoleteLineFolding)
        }
    }

    func testAuthorizationPolicyUsesExactTypedAllowlists() throws {
        let policy = try HTTPAuthorizationPolicy(
            allowedHosts: ["127.0.0.1", "localhost", "notes-mac.example.ts.net"],
            allowedOrigins: ["https://notes-mac.example.ts.net"]
        )
        let allowed = try HTTPRequestHeadParser.parse(Data(
            "POST / HTTP/1.1\r\nHost: notes-mac.example.ts.net\r\nOrigin: https://notes-mac.example.ts.net\r\nAuthorization: Bearer correct horse battery staple\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n".utf8
        ), maximumBytes: 2_048)
        XCTAssertEqual(policy.evaluate(allowed.headers, bearerToken: "correct horse battery staple"), .allowed)

        for request in [
            "POST / HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer correct horse battery staple\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nOrigin: https://evil.example\r\nAuthorization: Bearer correct horse battery staple\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer wrong\r\n\r\n",
        ] {
            let head = try HTTPRequestHeadParser.parse(Data(request.utf8), maximumBytes: 2_048)
            XCTAssertNotEqual(policy.evaluate(head.headers, bearerToken: "correct horse battery staple"), .allowed)
        }
        let missingAuthorization = try HTTPRequestHeadParser.parse(Data(
            "POST / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8
        ), maximumBytes: 2_048)
        XCTAssertEqual(missingAuthorization.headers.singleValue(named: "host"), "localhost")
        XCTAssertEqual(policy.evaluate(missingAuthorization.headers, bearerToken: "correct horse battery staple"), .unauthorized)
    }

    func testRealLoopbackListenerServesHealthAndAuthorizedJSONRPC() throws {
        let server = try makeServer { request in
            ["jsonrpc": "2.0", "id": request["id"] ?? NSNull(), "result": ["ok": true]]
        }
        let endpoint = try server.start()
        defer { server.stop() }

        XCTAssertEqual(endpoint.host, "127.0.0.1")
        let health = try exchange(port: endpoint.port, request:
            "GET /notescli/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(health.hasPrefix("HTTP/1.1 200"), health)
        XCTAssertTrue(health.contains("\"transport\":\"streamable-http\""), health)

        let body = modernBody(id: 7, method: "ping")
        let response = try exchange(port: endpoint.port, request: authorizedRequest(body: body, method: "ping"))
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
        XCTAssertTrue(response.contains("MCP-Protocol-Version: 2026-07-28"), response)
        XCTAssertTrue(response.contains("\"id\":7"), response)
        XCTAssertTrue(response.contains("\"ok\":true"), response)
    }

    func testUnauthorizedRequestIsRejectedBeforeDeclaredBodyIsRead() throws {
        let server = try makeServer(headerTimeout: 1, bodyTimeout: 2) { _ in
            XCTFail("Unauthorized request reached handler")
            return nil
        }
        let endpoint = try server.start()
        defer { server.stop() }

        let started = Date()
        let response = try exchange(port: endpoint.port, request:
            "POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer wrong\r\nContent-Type: application/json\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.75)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 401"), response)
        XCTAssertTrue(response.contains("\"message\":\"Unauthorized\""), response)
        XCTAssertFalse(response.contains("wrong"), response)
        XCTAssertFalse(response.contains("test-token"), response)
    }

    func testRealListenerRejectsBadOriginUnsupportedMediaAndOversizedBody() throws {
        let server = try makeServer(maximumBodyBytes: 64) { _ in
            XCTFail("Rejected request reached handler")
            return nil
        }
        let endpoint = try server.start()
        defer { server.stop() }

        let badOrigin = try exchange(port: endpoint.port, request:
            "POST / HTTP/1.1\r\nHost: localhost\r\nOrigin: https://evil.example\r\nAuthorization: Bearer test-token\r\nContent-Type: application/json\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(badOrigin.hasPrefix("HTTP/1.1 403"), badOrigin)

        let nullOrigin = try exchange(port: endpoint.port, request:
            "POST / HTTP/1.1\r\nHost: localhost\r\nOrigin: null\r\nAuthorization: Bearer test-token\r\nContent-Type: application/json\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(nullOrigin.hasPrefix("HTTP/1.1 403"), nullOrigin)

        let unsupported = try exchange(port: endpoint.port, request:
            "POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test-token\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(unsupported.hasPrefix("HTTP/1.1 415"), unsupported)

        let oversized = try exchange(port: endpoint.port, request:
            "POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test-token\r\nContent-Type: application/json\r\nContent-Length: 65\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(oversized.hasPrefix("HTTP/1.1 413"), oversized)

        let chunked = try exchange(port: endpoint.port, request:
            "POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test-token\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(chunked.hasPrefix("HTTP/1.1 400"), chunked)
    }

    func testRealListenerReturnsJSONErrorsForMalformedRequestsAndTimesOutSlowHeaders() throws {
        let server = try makeServer(headerTimeout: 0.15) { _ in nil }
        let endpoint = try server.start()
        defer { server.stop() }

        let invalidJSON = "{"
        let malformed = try exchange(port: endpoint.port, request:
            "POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test-token\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: 1\r\nConnection: close\r\n\r\n\(invalidJSON)")
        XCTAssertTrue(malformed.hasPrefix("HTTP/1.1 400"), malformed)
        XCTAssertTrue(malformed.contains("\"code\":-32700"), malformed)

        let timedOut = try exchange(port: endpoint.port, request: "POST / HTTP/1.1\r\nHost: local", shutdownWrite: false)
        XCTAssertTrue(timedOut.hasPrefix("HTTP/1.1 408"), timedOut)
    }

    func testRealListenerBoundsConcurrentConnections() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = try makeServer(maximumConcurrentConnections: 1) { request in
            if request["method"] as? String == "slow" {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            return ["jsonrpc": "2.0", "id": request["id"] ?? NSNull(), "result": [:]]
        }
        let endpoint = try server.start()
        defer {
            release.signal()
            server.stop()
        }

        let firstDone = expectation(description: "first request completes")
        DispatchQueue.global().async {
            let body = self.modernBody(id: 1, method: "slow")
            _ = try? self.exchange(port: endpoint.port, request: self.authorizedRequest(body: body, method: "slow"))
            firstDone.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        let busyBody = modernBody(id: 2, method: "ping")
        let busy = try exchange(port: endpoint.port, request: authorizedRequest(body: busyBody, method: "ping"))
        XCTAssertTrue(busy.hasPrefix("HTTP/1.1 503"), busy)
        release.signal()
        wait(for: [firstDone], timeout: 2)
    }

    func testTokenProviderIsReadForEveryRequestSoRotationRevokesImmediately() throws {
        let tokens = TokenBox("first-token")
        let server = try makeServer(tokenProvider: { tokens.value }) { request in
            ["jsonrpc": "2.0", "id": request["id"] ?? NSNull(), "result": [:]]
        }
        let endpoint = try server.start()
        defer { server.stop() }

        let body = modernBody(id: 1, method: "ping")
        let first = try exchange(port: endpoint.port, request: authorizedRequest(body: body, method: "ping", token: "first-token"))
        XCTAssertTrue(first.hasPrefix("HTTP/1.1 200"), first)

        tokens.value = "second-token"
        let revoked = try exchange(port: endpoint.port, request: authorizedRequest(body: body, method: "ping", token: "first-token"))
        XCTAssertTrue(revoked.hasPrefix("HTTP/1.1 401"), revoked)
        let rotated = try exchange(port: endpoint.port, request: authorizedRequest(body: body, method: "ping", token: "second-token"))
        XCTAssertTrue(rotated.hasPrefix("HTTP/1.1 200"), rotated)
    }

    func testModernTransportNegotiationHeaderMatchingAndNotifications() throws {
        let calls = LockedCounter()
        let server = try makeServer { request in
            calls.increment()
            return ["jsonrpc": "2.0", "id": request["id"] ?? NSNull(), "result": [:]]
        }
        let endpoint = try server.start()
        defer { server.stop() }

        let body = modernBody(id: 1, method: "tools/call", name: "get_note")
        let missingEvents = try exchange(port: endpoint.port, request: authorizedRequest(
            body: body,
            method: "tools/call",
            name: "get_note",
            accept: "application/json"
        ))
        XCTAssertTrue(missingEvents.hasPrefix("HTTP/1.1 406"), missingEvents)

        let zeroQuality = try exchange(port: endpoint.port, request: authorizedRequest(
            body: body,
            method: "tools/call",
            name: "get_note",
            accept: "application/json, text/event-stream;q=0.0000"
        ))
        XCTAssertTrue(zeroQuality.hasPrefix("HTTP/1.1 406"), zeroQuality)

        let mismatched = try exchange(port: endpoint.port, request: authorizedRequest(
            body: body,
            method: "tools/call",
            name: "other"
        ))
        XCTAssertTrue(mismatched.hasPrefix("HTTP/1.1 400"), mismatched)
        XCTAssertTrue(mismatched.contains("\"code\":-32020"), mismatched)

        let notificationBody = modernBody(id: nil, method: "notifications/initialized")
        let notification = try exchange(port: endpoint.port, request: authorizedRequest(
            body: notificationBody,
            method: "notifications/initialized"
        ))
        XCTAssertTrue(notification.hasPrefix("HTTP/1.1 202"), notification)
        XCTAssertTrue(notification.contains("Content-Length: 0"), notification)
        XCTAssertTrue(notification.contains("MCP-Protocol-Version: 2026-07-28"), notification)

        let removedGET = try exchange(port: endpoint.port, request:
            "GET /notescli HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test-token\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(removedGET.hasPrefix("HTTP/1.1 405"), removedGET)
        XCTAssertEqual(calls.value, 1)
    }

    func testDefaultBodyLimitIsFourMiBAndHostIsMandatory() throws {
        let configuration = try HTTPMCPServer.Configuration(
            tokenProvider: { "token" },
            allowedHosts: ["localhost"],
            allowedOrigins: []
        )
        XCTAssertEqual(configuration.maximumBodyBytes, 4 * 1_024 * 1_024)

        let policy = try HTTPAuthorizationPolicy(allowedHosts: ["localhost"], allowedOrigins: [])
        let missingHost = try HTTPRequestHeadParser.parse(Data(
            "POST / HTTP/1.1\r\nAuthorization: Bearer token\r\n\r\n".utf8
        ), maximumBytes: 1_024)
        XCTAssertEqual(policy.evaluate(missingHost.headers, bearerToken: "token"), .forbiddenHost)
    }

    func testLifecycleIsIdempotentAndSupportsRestart() throws {
        let server = try makeServer { request in
            ["jsonrpc": "2.0", "id": request["id"] ?? NSNull(), "result": [:]]
        }
        let first = try server.start()
        XCTAssertEqual(try server.start(), first)
        XCTAssertEqual(server.localEndpoint, first)
        server.stop()
        XCTAssertNil(server.localEndpoint)

        let restarted = try server.start()
        defer { server.stop() }
        let body = modernBody(id: 1, method: "ping")
        let response = try exchange(port: restarted.port, request: authorizedRequest(body: body, method: "ping"))
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
    }

    func testBodyReadTimeoutAndHeaderLimitAreEnforced() throws {
        let timeoutServer = try makeServer(bodyTimeout: 0.15) { _ in
            XCTFail("Incomplete body reached handler")
            return nil
        }
        let timeoutEndpoint = try timeoutServer.start()
        let partial = try exchange(port: timeoutEndpoint.port, request:
            "POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test-token\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: 5\r\nConnection: close\r\n\r\n{", shutdownWrite: false)
        timeoutServer.stop()
        XCTAssertTrue(partial.hasPrefix("HTTP/1.1 408"), partial)

        let headerServer = try makeServer(maximumHeaderBytes: 256) { _ in nil }
        let headerEndpoint = try headerServer.start()
        defer { headerServer.stop() }
        let oversizedHeader = try exchange(port: headerEndpoint.port, request:
            "POST / HTTP/1.1\r\nHost: localhost\r\nX-Fill: \(String(repeating: "a", count: 300))\r\n")
        XCTAssertTrue(oversizedHeader.hasPrefix("HTTP/1.1 431"), oversizedHeader)
    }

    private func makeServer(
        headerTimeout: TimeInterval = 1,
        bodyTimeout: TimeInterval = 1,
        maximumBodyBytes: Int = 1_024,
        maximumHeaderBytes: Int = 4_096,
        maximumConcurrentConnections: Int = 4,
        tokenProvider: @escaping HTTPMCPServer.TokenProvider = { "test-token" },
        handler: @escaping HTTPMCPServer.Handler
    ) throws -> HTTPMCPServer {
        let configuration = try HTTPMCPServer.Configuration(
            port: 0,
            tokenProvider: tokenProvider,
            allowedHosts: ["localhost", "127.0.0.1"],
            allowedOrigins: ["https://notes-mac.example.ts.net"],
            maximumHeaderBytes: maximumHeaderBytes,
            maximumBodyBytes: maximumBodyBytes,
            headerTimeout: headerTimeout,
            bodyTimeout: bodyTimeout,
            maximumConcurrentConnections: maximumConcurrentConnections
        )
        return HTTPMCPServer(configuration: configuration, handler: handler)
    }

    private func modernBody(id: Int?, method: String, name: String? = nil) -> String {
        var params: [String: Any] = [
            "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"],
        ]
        if let name { params[method == "resources/read" ? "uri" : "name"] = name }
        var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { request["id"] = id }
        let data = try! JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func authorizedRequest(body: String, method: String, name: String? = nil, token: String = "test-token", accept: String = "application/json, text/event-stream") -> String {
        var headers = "POST /notescli HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nAccept: \(accept)\r\nMCP-Protocol-Version: 2026-07-28\r\nMcp-Method: \(method)\r\n"
        if let name { headers += "Mcp-Name: \(name)\r\n" }
        return headers + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private func exchange(port: UInt16, request: String, shutdownWrite: Bool = true) throws -> String {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let bytes = Array(request.utf8)
        try bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                sent += count
            }
        }
        if shutdownWrite { Darwin.shutdown(descriptor, SHUT_WR) }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                response.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return String(decoding: response, as: UTF8.self)
    }
}

private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String

    init(_ value: String) { storedValue = value }

    var value: String {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
