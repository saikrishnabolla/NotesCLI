import AppKit
import CoreGraphics
import Foundation
import WebKit

/// Renders untrusted SVG or HTML with JavaScript off, no base URL, a strict Content Security Policy,
/// every non-data resource blocked, and one deadline for the whole render.
public final class DiagramRenderer {
    public static let defaultTimeout: TimeInterval = 30
    /// Inline styles and data: images and fonts only. Installed system fonts need no fetch.
    static let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline' data:; font-src data:"

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = DiagramRenderer.defaultTimeout) {
        self.timeout = timeout
    }

    public func render(file: URL, options: DiagramRenderOptions) throws -> RenderedDiagram {
        let source = try DiagramSource(file: file)
        let timeout = self.timeout
        if !Thread.isMainThread {
            let result = DiagramRenderResult()
            RunLoop.main.perform {
                result.complete(Result {
                    try Self.renderOnMainThread(source: source, options: options, timeout: timeout)
                })
            }
            return try result.wait(timeout: timeout + 1)
        }
        return try Self.renderOnMainThread(source: source, options: options, timeout: timeout)
    }

    private static func renderOnMainThread(source: DiagramSource, options: DiagramRenderOptions,
                                           timeout: TimeInterval) throws -> RenderedDiagram {
        return try MainActor.assumeIsolated {
            try WebKitDiagramRenderer(timeout: timeout).render(source: source, options: options)
        }
    }

    /// Inserts the CSP meta element before any content that could load a resource.
    static func isolatedHTML(_ html: String) -> String {
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"
        let prologue = #"^\x{FEFF}?(?:\s|<!--.*?-->)*(?:<!doctype[^>]*>)?"#
        guard let expression = try? NSRegularExpression(pattern: prologue, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range, in: html) else { return meta + html }
        return String(html[..<range.upperBound]) + meta + String(html[range.upperBound...])
    }
}

private final class DiagramRenderResult: @unchecked Sendable {
    private let completed = DispatchSemaphore(value: 0)
    private var result: Result<RenderedDiagram, Error>?

    func complete(_ result: Result<RenderedDiagram, Error>) {
        self.result = result
        completed.signal()
    }

    func wait(timeout: TimeInterval) throws -> RenderedDiagram {
        guard completed.wait(timeout: .now() + timeout) == .success else {
            throw DiagramError.renderFailed("Diagram rendering timed out.")
        }
        return try result!.get()
    }
}

@MainActor
private final class WebKitDiagramRenderer: NSObject, WKNavigationDelegate {
    private static let blockEverythingButData = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
    """
    private let timeout: TimeInterval
    private let deadline: Date
    private var navigationFinished = false
    private var navigationError: Error?
    private var initialNavigationAllowed = false

    init(timeout: TimeInterval) {
        self.timeout = timeout
        self.deadline = Date().addingTimeInterval(timeout)
    }

    func render(source: DiagramSource, options: DiagramRenderOptions) throws -> RenderedDiagram {
        guard let text = String(data: source.data, encoding: .utf8) else {
            throw DiagramError.renderFailed("Diagram source must be UTF-8.")
        }
        let ruleDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-diagram-rules-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: ruleDirectory) }
        let rules = try compileRules(in: ruleDirectory)

        let configuration = WKWebViewConfiguration()
        configuration.preferences.shouldPrintBackgrounds = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 8192, height: 8192), configuration: configuration)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)

        let html = DiagramRenderer.isolatedHTML(source.mediaType == "image/svg+xml" ? Self.wrap(svg: text) : text)
        webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        try wait(seconds: 20) { navigationFinished }
        if let navigationError { throw DiagramError.renderFailed("WebKit could not load the diagram: \(navigationError.localizedDescription)") }

        let bounds = try contentBounds(webView: webView, options: options)
        guard bounds.width <= webView.bounds.width, bounds.height <= webView.bounds.height else {
            throw DiagramError.renderFailed("The diagram exceeds the 8192 pixel render limit.")
        }
        let pdf = try pdf(webView: webView, rect: bounds.rect)
        let pixelSize = try DiagramGeometry.outputPixelSize(contentWidth: bounds.width, contentHeight: bounds.height,
                                                            displayWidth: options.width, scale: options.scale)
        let png = try rasterize(pdf: pdf, size: pixelSize, fill: fillColor(bounds.background, options: options))
        let embedded = try DiagramSourceMetadata.embed(source: source.data, filename: source.filename,
                                                       mediaType: source.mediaType, in: png)
        return RenderedDiagram(png: embedded, source: source, pixelSize: pixelSize)
    }

    private func compileRules(in directory: URL) throws -> WKContentRuleList {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let store = WKContentRuleListStore(url: directory) else {
            throw DiagramError.renderFailed("WebKit could not create the diagram content blocker.")
        }
        var result: Result<WKContentRuleList, Error>?
        store.compileContentRuleList(forIdentifier: "notescli-diagram", encodedContentRuleList: Self.blockEverythingButData) { list, error in
            if let list { result = .success(list) }
            else { result = .failure(error ?? DiagramError.renderFailed("WebKit returned no content blocker.")) }
        }
        try wait(seconds: 10) { result != nil }
        do { return try result!.get() }
        catch { throw DiagramError.renderFailed("WebKit could not compile the diagram content blocker: \(error.localizedDescription)") }
    }

    /// Only the initial about:blank load may navigate; links, refreshes, frames, and form posts are cancelled.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let initial = !initialNavigationAllowed && navigationAction.targetFrame?.isMainFrame == true &&
            navigationAction.request.url?.absoluteString == "about:blank"
        if initial { initialNavigationAllowed = true }
        decisionHandler(initial ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationFinished = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationError = error
        navigationFinished = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationError = error
        navigationFinished = true
    }

    private struct Bounds {
        let rect: CGRect
        let background: String
        var width: Double { rect.width }
        var height: Double { rect.height }
    }

    private func contentBounds(webView: WKWebView, options: DiagramRenderOptions) throws -> Bounds {
        let backgroundRule = options.background == .auto ? "" : "html,body{background:transparent!important;}"
        let script = """
        (async () => {
          document.documentElement.classList.toggle('dark', \(options.dark ? "true" : "false"));
          document.documentElement.dataset.theme = \(options.dark ? "'dark'" : "'light'");
          document.documentElement.style.colorScheme = \(options.dark ? "'dark'" : "'light'");
          const style = document.createElement('style');
          style.textContent = `\(backgroundRule)`;
          document.head.appendChild(style);
          const standalone = document.body.dataset.notescliStandaloneSvg === 'true'
            ? document.body.querySelector(':scope > svg:only-child') : null;
          const box = standalone && standalone.viewBox && standalone.viewBox.baseVal;
          if (box && box.width > 0 && box.height > 0 &&
              !standalone.hasAttribute('width') && !standalone.hasAttribute('height')) {
            standalone.setAttribute('width', String(box.width));
            standalone.setAttribute('height', String(box.height));
          }
          if (document.fonts && document.fonts.ready) {
            await Promise.race([document.fonts.ready, new Promise(resolve => setTimeout(resolve, 8000))]);
          }
          await new Promise(resolve => setTimeout(resolve, 50));
          const visible = Array.from(document.body.children).filter(node => {
            const style = getComputedStyle(node);
            const rect = node.getBoundingClientRect();
            return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
          });
          const nodes = visible.length ? visible : [document.documentElement];
          const elementCount = document.querySelectorAll('body *').length;
          const rects = nodes.map(node => node.getBoundingClientRect());
          const left = Math.min(...rects.map(rect => rect.left));
          const top = Math.min(...rects.map(rect => rect.top));
          const right = Math.max(...rects.map(rect => rect.right));
          const bottom = Math.max(...rects.map(rect => rect.bottom));
          const bodyBackground = getComputedStyle(document.body).backgroundColor;
          const rootBackground = getComputedStyle(document.documentElement).backgroundColor;
          return {left, top, right, bottom, canvasWidth: document.documentElement.scrollWidth,
                  canvasHeight: document.documentElement.scrollHeight, elementCount,
                  background: bodyBackground === 'rgba(0, 0, 0, 0)' ? rootBackground : bodyBackground};
        })()
        """
        let value = try javaScript(webView: webView, script: script)
        if let count = ((value as? [String: Any])?["elementCount"] as? NSNumber)?.intValue, count > DiagramLimits.maxElements {
            throw DiagramError.renderFailed("The diagram has \(count) elements; the limit is \(DiagramLimits.maxElements).")
        }
        guard let object = value as? [String: Any],
              let left = (object["left"] as? NSNumber)?.doubleValue,
              let top = (object["top"] as? NSNumber)?.doubleValue,
              let right = (object["right"] as? NSNumber)?.doubleValue,
              let bottom = (object["bottom"] as? NSNumber)?.doubleValue,
              let canvasWidth = (object["canvasWidth"] as? NSNumber)?.doubleValue,
              let canvasHeight = (object["canvasHeight"] as? NSNumber)?.doubleValue else {
            throw DiagramError.renderFailed("WebKit found no visible diagram content.")
        }
        let crop = try DiagramGeometry.cropRect(left: left, top: top, right: right, bottom: bottom,
                                                canvasWidth: canvasWidth, canvasHeight: canvasHeight, padding: 2)
        return Bounds(rect: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height),
                      background: object["background"] as? String ?? "")
    }

    private func javaScript(webView: WKWebView, script: String) throws -> Any? {
        var result: Result<Any?, Error>?
        // The measuring script runs in an isolated client world; page scripts are disabled.
        webView.callAsyncJavaScript("return await " + script, arguments: [:], in: nil, in: .defaultClient, completionHandler: { value in
            result = value.map { Optional($0) }
        })
        try wait(seconds: 12) { result != nil }
        return try result!.get()
    }

    private func pdf(webView: WKWebView, rect: CGRect) throws -> Data {
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        configuration.allowTransparentBackground = true
        var result: Result<Data, Error>?
        webView.createPDF(configuration: configuration) { value in result = value }
        try wait(seconds: 20) { result != nil }
        return try result!.get()
    }

    /// Waits for one step, never past the whole render's deadline.
    private func wait(seconds: TimeInterval, condition: () -> Bool) throws {
        let stepDeadline = min(deadline, Date().addingTimeInterval(seconds))
        while !condition(), Date() < stepDeadline {
            RunLoop.current.run(mode: .default, before: min(stepDeadline, Date().addingTimeInterval(0.01)))
        }
        guard condition() else {
            if Date() >= deadline {
                throw DiagramError.renderFailed("Diagram rendering timed out after \(Self.seconds(timeout)) seconds.")
            }
            throw DiagramError.renderFailed("Diagram rendering timed out.")
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func rasterize(pdf: Data, size: DiagramPixelSize, fill: NSColor?) throws -> Data {
        guard let provider = CGDataProvider(data: pdf as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DiagramError.renderFailed("Could not rasterize the WebKit PDF.")
        }
        let target = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.clear(target)
        if let fill { context.setFillColor(fill.cgColor); context.fill(target) }
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        let pageBox = page.getBoxRect(.mediaBox)
        let transform = try DiagramGeometry.pdfTransform(pageWidth: pageBox.width, pageHeight: pageBox.height,
                                                         pixelWidth: size.width, pixelHeight: size.height)
        context.translateBy(x: transform.x - pageBox.minX * transform.scale,
                            y: transform.y - pageBox.minY * transform.scale)
        context.scaleBy(x: transform.scale, y: transform.scale)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw DiagramError.renderFailed("Could not create the diagram image.") }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw DiagramError.renderFailed("Could not encode the diagram PNG.")
        }
        return png
    }

    private func fillColor(_ css: String, options: DiagramRenderOptions) -> NSColor? {
        if options.background == .transparent { return nil }
        if options.background == .white { return .white }
        if let parsed = Self.color(css), parsed.alphaComponent > 0 { return parsed }
        return options.dark ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1) : .white
    }

    private static func color(_ css: String) -> NSColor? {
        let numbers = css.split { !$0.isNumber && $0 != "." }.compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }
        let alpha = numbers.count > 3 ? numbers[3] : 1
        return NSColor(srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: alpha)
    }

    private static func wrap(svg: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;width:max-content;height:max-content;overflow:visible}
        body{display:block}svg{display:block}
        </style></head><body data-notescli-standalone-svg="true">\(svg)</body></html>
        """
    }
}
