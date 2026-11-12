import AppKit
import Foundation
import Network
import NotesCore
import XCTest
@testable import NotesDiagrams

/// Untrusted diagram HTML must render without JavaScript, file access, or network access.
/// XCTest runs these on the main thread outside a dispatch block, as the CLI does, so WebKit callbacks arrive.
final class RendererIsolationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func render(_ html: String, width: Int = 40, renderer: DiagramRenderer = DiagramRenderer()) throws -> RenderedDiagram {
        let file = root.appendingPathComponent("diagram-\(UUID().uuidString).html")
        try Data(html.utf8).write(to: file)
        return try renderer.render(file: file, options: DiagramRenderOptions(width: width, scale: 2, background: .white))
    }

    /// The strongest channel at the centre pixel. Color management shifts exact values, not the dominant channel.
    private func centerColor(_ png: Data) throws -> String {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let channels = [("red", color.redComponent), ("green", color.greenComponent), ("blue", color.blueComponent)]
        let sorted = channels.sorted { $0.1 > $1.1 }
        return sorted[0].1 - sorted[1].1 > 0.5 ? sorted[0].0 : "mixed"
    }

    func testDiagramJavaScriptDoesNotRun() throws {
        let rendered = try render("""
        <!doctype html><html><body style="margin:0">
        <div id="box" style="width:40px;height:40px;background:#0000ff"></div>
        <script>document.getElementById('box').style.background = '#ff0000'</script>
        </body></html>
        """)
        XCTAssertEqual(try centerColor(rendered.png), "blue")
    }

    func testDiagramCannotFetchNetworkOrFileResources() throws {
        let server = try RequestCounter()
        defer { server.stop() }
        try Data("div{background:#ff0000 !important}".utf8).write(to: root.appendingPathComponent("local.css"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("red.png"))
        let rendered = try render("""
        <!doctype html><html><head><link rel="stylesheet" href="local.css">
        <link rel="stylesheet" href="http://127.0.0.1:\(server.port)/style.css"></head>
        <body style="margin:0">
        <div style="width:40px;height:40px;background:#00ff00 url(http://127.0.0.1:\(server.port)/background.png)"></div>
        <img src="http://127.0.0.1:\(server.port)/image.png" width="1" height="1">
        <img src="red.png" width="1" height="1"><iframe src="http://127.0.0.1:\(server.port)/frame.html" width="1" height="1"></iframe>
        </body></html>
        """)
        XCTAssertEqual(try centerColor(rendered.png), "green")
        XCTAssertEqual(server.paths, [])
    }

    func testDiagramRenderHonoursTimeout() throws {
        XCTAssertThrowsError(try render("<div style=\"width:40px;height:40px;background:#000\"></div>",
                                        renderer: DiagramRenderer(timeout: 0.000_001))) { error in
            XCTAssertEqual(error as? DiagramError, .renderFailed("Diagram rendering timed out after 0.000001 seconds."))
        }
    }

    func testDiagramWithTooManyElementsIsRefused() throws {
        let html = "<!doctype html><html><head></head><body>" + String(repeating: "<i></i>", count: 50_001) + "</body></html>"
        XCTAssertThrowsError(try render(html)) { error in
            XCTAssertEqual(error as? DiagramError, .renderFailed("The diagram has 50001 elements; the limit is 50000."))
        }
    }

    func testInlineDataFontsAndSystemFontsStillRender() throws {
        let font = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Zapfino.ttf")).base64EncodedString()
        func page(_ family: String, _ face: String = "") -> String {
            "<!doctype html><html><head><style>\(face)body{margin:0}span{display:inline-block;font:40px \(family)}</style></head><body><span>Hamburgefonts</span></body></html>"
        }
        let dataFont = try render(page("Inline", "@font-face{font-family:Inline;src:url(data:font/ttf;base64,\(font))}"), width: 400)
        let systemFont = try render(page("Zapfino"), width: 400)
        let fallback = try render(page("NoSuchFontFamily, Times"), width: 400)
        XCTAssertEqual(dataFont.pixelSize, systemFont.pixelSize)
        XCTAssertGreaterThan(dataFont.pixelSize.height, fallback.pixelSize.height * 2)
    }
}

/// A loopback HTTP listener that records every request path it receives.
private final class RequestCounter: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "notescli.test.requests")
    private let lock = NSLock()
    private var received: [String] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw NSError(domain: "RequestCounter", code: 1)
        }
        self.port = port
    }

    var paths: [String] { lock.withLock { received } }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
            self?.lock.withLock { self?.received.append(path) }
            let body = "body{background:red}"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/css\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
