import AppKit
import CoreGraphics
import Foundation
import WebKit

public final class DiagramRenderer {
    public init() {}

    public func render(file: URL, options: DiagramRenderOptions) throws -> RenderedDiagram {
        let source = try DiagramSource(file: file)
        guard Thread.isMainThread else {
            throw DiagramError.renderFailed("Diagram rendering must run on the main thread.")
        }
        return try MainActor.assumeIsolated {
            try WebKitDiagramRenderer().render(source: source, baseURL: file.deletingLastPathComponent(), options: options)
        }
    }
}

@MainActor
private final class WebKitDiagramRenderer: NSObject, WKNavigationDelegate {
    private var navigationFinished = false
    private var navigationError: Error?

    func render(source: DiagramSource, baseURL: URL, options: DiagramRenderOptions) throws -> RenderedDiagram {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.shouldPrintBackgrounds = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 8192, height: 8192), configuration: configuration)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)

        guard let text = String(data: source.data, encoding: .utf8) else {
            throw DiagramError.renderFailed("Diagram source must be UTF-8.")
        }
        let html = source.mediaType == "image/svg+xml" ? Self.wrap(svg: text) : text
        webView.loadHTMLString(html, baseURL: baseURL)
        try wait(timeout: 20) { navigationFinished }
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
          const rects = nodes.map(node => node.getBoundingClientRect());
          const left = Math.min(...rects.map(rect => rect.left));
          const top = Math.min(...rects.map(rect => rect.top));
          const right = Math.max(...rects.map(rect => rect.right));
          const bottom = Math.max(...rects.map(rect => rect.bottom));
          const bodyBackground = getComputedStyle(document.body).backgroundColor;
          const rootBackground = getComputedStyle(document.documentElement).backgroundColor;
          return {left, top, right, bottom, canvasWidth: document.documentElement.scrollWidth,
                  canvasHeight: document.documentElement.scrollHeight,
                  background: bodyBackground === 'rgba(0, 0, 0, 0)' ? rootBackground : bodyBackground};
        })()
        """
        let value = try javaScript(webView: webView, script: script)
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
        webView.callAsyncJavaScript("return await " + script, arguments: [:], in: nil, in: .page, completionHandler: { value in
            result = value.map { Optional($0) }
        })
        try wait(timeout: 12) { result != nil }
        return try result!.get()
    }

    private func pdf(webView: WKWebView, rect: CGRect) throws -> Data {
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        configuration.allowTransparentBackground = true
        var result: Result<Data, Error>?
        webView.createPDF(configuration: configuration) { value in result = value }
        try wait(timeout: 20) { result != nil }
        return try result!.get()
    }

    private func wait(timeout: TimeInterval, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard condition() else { throw DiagramError.renderFailed("Diagram rendering timed out.") }
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
        </style></head><body>\(svg)</body></html>
        """
    }
}
