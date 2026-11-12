import AppKit
import Foundation
import NotesCore
import PencilKit

public enum SVGLimits {
    public static let maxBytes = 5 * 1024 * 1024
    public static let maxElements = 20_000
    public static let maxPoints = 200_000
    public static let maxStrokes = 20_000
    public static let maxHatchLines = 10_000
    public static let maxCoordinate = 1_000_000.0
    public static let maxStrokeWidth = 1_000.0
    public static let maxCanvasSide = 20_000.0

    static let coordinateError = SVGDrawingError.invalid("SVG coordinates must be finite and within ±\(Int(maxCoordinate)).")
    static let widthError = SVGDrawingError.invalid("Stroke width must be finite and at most \(Int(maxStrokeWidth)).")

    static func checkCoordinate(_ value: Double) throws {
        guard value.isFinite, abs(value) <= maxCoordinate else { throw coordinateError }
    }

    static func checkWidth(_ value: Double) throws {
        guard value.isFinite, value <= maxStrokeWidth else { throw widthError }
    }
}

public enum DrawingInk: String, CaseIterable, Codable, Sendable {
    case pen, marker, pencil, monoline

    var pencilKit: PKInkingTool.InkType {
        switch self {
        case .pen: .pen
        case .marker: .marker
        case .pencil: .pencil
        case .monoline: .monoline
        }
    }
}

public enum SVGFillMode: String, CaseIterable, Codable, Sendable {
    case outline, hatch
}

public enum SVGFit: String, CaseIterable, Codable, Sendable {
    case contain, stretch
}

public struct DrawingSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct DrawingColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

public struct DrawingPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct SVGStroke: Equatable, Sendable {
    public var points: [DrawingPoint]
    public var color: DrawingColor
    public var width: Double
    public var closed: Bool

    public init(points: [DrawingPoint], color: DrawingColor, width: Double, closed: Bool) {
        self.points = points
        self.color = color
        self.width = width
        self.closed = closed
    }
}

public struct ParsedSVG: Equatable, Sendable {
    public var size: DrawingSize
    public var strokes: [SVGStroke]

    public init(size: DrawingSize, strokes: [SVGStroke]) {
        self.size = size
        self.strokes = strokes
    }
}

public struct SVGDrawingOptions: Sendable {
    public var ink: DrawingInk
    public var width: Double?
    public var color: DrawingColor?
    public var blackAndWhite: Bool
    public var size: DrawingSize?
    public var fit: SVGFit
    public var fill: SVGFillMode

    public init(ink: DrawingInk = .pen, width: Double? = nil, color: DrawingColor? = nil,
                blackAndWhite: Bool = false, size: DrawingSize? = nil,
                fit: SVGFit = .contain, fill: SVGFillMode = .outline) {
        self.ink = ink
        self.width = width
        self.color = color
        self.blackAndWhite = blackAndWhite
        self.size = size
        self.fit = fit
        self.fill = fill
    }
}

public enum SVGDrawingError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

public enum SVGDrawingConverter {
    /// Reads an SVG input file through the shared source-path check.
    public static func read(_ url: URL) throws -> Data {
        try InputFile.read(url, kind: "SVG", maxBytes: SVGLimits.maxBytes)
    }

    public static func drawing(contentsOf url: URL, options: SVGDrawingOptions = .init()) throws -> PKDrawing {
        try drawing(from: read(url), options: options)
    }

    public static func parse(_ data: Data, options: SVGDrawingOptions = .init()) throws -> ParsedSVG {
        let delegate = SVGParserDelegate(options: options)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw delegate.failure ?? SVGDrawingError.invalid(parser.parserError?.localizedDescription ?? "The SVG is invalid.")
        }
        return try delegate.result()
    }

    public static func drawing(from data: Data, options: SVGDrawingOptions = .init()) throws -> PKDrawing {
        let parsed = try parse(data, options: options)
        let strokes = parsed.strokes.compactMap { source -> PKStroke? in
            guard source.points.count >= 2 else { return nil }
            let width = max(0.1, options.width ?? source.width)
            let color = options.blackAndWhite ? DrawingColor(red: 0, green: 0, blue: 0, alpha: source.color.alpha) : (options.color ?? source.color)
            let points = source.points.enumerated().map { index, point in
                PKStrokePoint(location: CGPoint(x: point.x, y: point.y), timeOffset: Double(index) / 120,
                              size: CGSize(width: width, height: width), opacity: color.alpha,
                              force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(options.ink.pencilKit, color: color.nsColor),
                            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
        }
        guard !strokes.isEmpty else { throw SVGDrawingError.invalid("The SVG has no drawable paths.") }
        return PKDrawing(strokes: strokes)
    }

    public static func svg(from drawing: PKDrawing) -> String {
        svg(from: [drawing])
    }

    public static func svg(from drawings: [PKDrawing]) -> String {
        let combinedBounds = drawings.reduce(CGRect.null) { $0.union($1.bounds) }
        let bounds = combinedBounds.isNull || combinedBounds.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : combinedBounds
        let paths = drawings.flatMap(\.strokes).compactMap { stroke -> String? in
            let points = Array(stroke.path.interpolatedPoints(by: .distance(1)))
            guard !points.isEmpty else { return nil }
            let commands = points.enumerated().map { index, point in
                "\(index == 0 ? "M" : "L")\(number(point.location.x)) \(number(point.location.y))"
            }.joined(separator: " ")
            let color = stroke.ink.color.usingColorSpace(.deviceRGB) ?? stroke.ink.color
            let width = points.map(\.size.width).max() ?? 1
            return "<path d=\"\(commands)\" fill=\"none\" stroke=\"\(hex(color))\" stroke-opacity=\"\(number(color.alphaComponent))\" stroke-width=\"\(number(width))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        }.joined()
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(number(bounds.minX)) \(number(bounds.minY)) \(number(bounds.width)) \(number(bounds.height))\">\(paths)</svg>"
    }

    public static func png(from drawings: [PKDrawing]) throws -> Data {
        let bounds = drawings.reduce(CGRect.null) { $0.union($1.bounds) }
        guard !bounds.isEmpty, !bounds.isNull else {
            throw SVGDrawingError.invalid("The drawing has empty bounds.")
        }
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        for drawing in drawings where !drawing.bounds.isEmpty && !drawing.bounds.isNull {
            drawing.image(from: drawing.bounds, scale: 2).draw(in: NSRect(
                x: drawing.bounds.minX - bounds.minX,
                y: bounds.maxY - drawing.bounds.maxY,
                width: drawing.bounds.width,
                height: drawing.bounds.height
            ))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SVGDrawingError.invalid("Could not render the drawing as PNG.")
        }
        return data
    }

    private static func number(_ value: CGFloat) -> String {
        number(Double(value))
    }

    private static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        // Int(_:) traps outside its range, so only whole values that fit are printed as integers.
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int(rounded)) }
        return String(rounded)
    }

    private static func hex(_ color: NSColor) -> String {
        func channel(_ value: CGFloat) -> Int {
            let clamped = value.isFinite ? min(1, max(0, value)) : 0
            return Int((clamped * 255).rounded())
        }
        return String(format: "#%02x%02x%02x", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent))
    }
}

private struct SVGTransform {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0

    func applying(_ point: DrawingPoint) -> DrawingPoint {
        DrawingPoint(x: a * point.x + c * point.y + tx, y: b * point.x + d * point.y + ty)
    }

    func multiplied(by rhs: SVGTransform) -> SVGTransform {
        SVGTransform(a: a * rhs.a + c * rhs.b, b: b * rhs.a + d * rhs.b,
                     c: a * rhs.c + c * rhs.d, d: b * rhs.c + d * rhs.d,
                     tx: a * rhs.tx + c * rhs.ty + tx, ty: b * rhs.tx + d * rhs.ty + ty)
    }

    var widthScale: Double { sqrt(abs(a * d - b * c)) }
}

private struct SVGStyle {
    var stroke: DrawingColor?
    var fill = DrawingColor(red: 0, green: 0, blue: 0)
    var fillEnabled = true
    var strokeWidth = 1.0
    var opacity = 1.0
    var strokeOpacity = 1.0
    var fillOpacity = 1.0
}

private struct SVGContext {
    var transform = SVGTransform()
    var style = SVGStyle()
}

private struct SVGSubpath {
    var points: [DrawingPoint]
    var closed: Bool
}

private final class SVGParserDelegate: NSObject, XMLParserDelegate {
    let options: SVGDrawingOptions
    var contexts = [SVGContext()]
    var strokes: [SVGStroke] = []
    var viewBox: (x: Double, y: Double, width: Double, height: Double)?
    var rootWidth: Double?
    var rootHeight: Double?
    var failure: SVGDrawingError?
    private var elementCount = 0
    private var pointCount = 0
    private var hatchLineCount = 0

    init(options: SVGDrawingOptions) {
        self.options = options
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard failure == nil else { return }
        do {
            elementCount += 1
            guard elementCount <= SVGLimits.maxElements else {
                throw SVGDrawingError.invalid("The SVG has more than \(SVGLimits.maxElements) elements.")
            }
            let parent = contexts.last ?? SVGContext()
            let local = try Self.transform(attributeDict["transform"])
            let style = try Self.style(parent.style, attributes: attributeDict)
            let context = SVGContext(transform: parent.transform.multiplied(by: local), style: style)
            contexts.append(context)
            let name = elementName.lowercased()
            if name == "svg" {
                if let values = Self.numbers(attributeDict["viewBox"]), values.count == 4, values[2] > 0, values[3] > 0 {
                    viewBox = (values[0], values[1], values[2], values[3])
                }
                rootWidth = Self.length(attributeDict["width"])
                rootHeight = Self.length(attributeDict["height"])
                return
            }
            let paths = try geometry(name, attributeDict)
            let fillAllowed = !["line", "polyline"].contains(name)
            try append(paths, context: context, fillAllowed: fillAllowed)
        } catch let error as SVGDrawingError {
            failure = error
            parser.abortParsing()
        } catch {
            failure = .invalid(error.localizedDescription)
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if contexts.count > 1 { contexts.removeLast() }
    }

    func result() throws -> ParsedSVG {
        if let failure { throw failure }
        let source: (x: Double, y: Double, width: Double, height: Double)
        if let viewBox { source = viewBox }
        else if let rootWidth, let rootHeight, rootWidth > 0, rootHeight > 0 { source = (0, 0, rootWidth, rootHeight) }
        else {
            let points = strokes.flatMap(\.points)
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
                throw SVGDrawingError.invalid("The SVG has no drawable paths.")
            }
            source = (minX, minY, max(1, maxX - minX), max(1, maxY - minY))
        }
        let target = options.size ?? DrawingSize(width: source.width, height: source.height)
        guard target.width > 0, target.height > 0 else { throw SVGDrawingError.invalid("Drawing size must be positive.") }
        guard target.width <= SVGLimits.maxCanvasSide, target.height <= SVGLimits.maxCanvasSide else {
            throw SVGDrawingError.invalid("Drawing size must be at most \(Int(SVGLimits.maxCanvasSide)) × \(Int(SVGLimits.maxCanvasSide)).")
        }
        if let width = options.width { try SVGLimits.checkWidth(width) }
        let sx = target.width / source.width, sy = target.height / source.height
        let scaleX: Double, scaleY: Double, offsetX: Double, offsetY: Double
        switch options.fit {
        case .stretch:
            scaleX = sx; scaleY = sy; offsetX = 0; offsetY = 0
        case .contain:
            let scale = min(sx, sy)
            scaleX = scale; scaleY = scale
            offsetX = (target.width - source.width * scale) / 2
            offsetY = (target.height - source.height * scale) / 2
        }
        let widthScale = sqrt(abs(scaleX * scaleY))
        let mapped = try strokes.map { stroke in
            let points = try stroke.points.map { point -> DrawingPoint in
                let mapped = DrawingPoint(x: (point.x - source.x) * scaleX + offsetX, y: (point.y - source.y) * scaleY + offsetY)
                try SVGLimits.checkCoordinate(mapped.x); try SVGLimits.checkCoordinate(mapped.y)
                return mapped
            }
            let width = stroke.width * widthScale
            try SVGLimits.checkWidth(width)
            return SVGStroke(points: points, color: stroke.color, width: width, closed: stroke.closed)
        }
        return ParsedSVG(size: target, strokes: mapped)
    }

    private func geometry(_ name: String, _ attributes: [String: String]) throws -> [SVGSubpath] {
        func value(_ key: String, _ fallback: Double = 0) -> Double { Self.length(attributes[key]) ?? fallback }
        switch name {
        case "path":
            guard let data = attributes["d"], !data.isEmpty else { return [] }
            var parser = try SVGPathParser(data, pointBudget: SVGLimits.maxPoints - pointCount)
            return try parser.parse()
        case "line":
            return [SVGSubpath(points: [.init(x: value("x1"), y: value("y1")), .init(x: value("x2"), y: value("y2"))], closed: false)]
        case "polyline", "polygon":
            let numbers = Self.numbers(attributes["points"]) ?? []
            guard numbers.count >= 4, numbers.count.isMultiple(of: 2) else { return [] }
            var points = stride(from: 0, to: numbers.count, by: 2).map { DrawingPoint(x: numbers[$0], y: numbers[$0 + 1]) }
            let closed = name == "polygon"
            if closed, points.first != points.last { points.append(points[0]) }
            return [SVGSubpath(points: points, closed: closed)]
        case "rect":
            let x = value("x"), y = value("y"), width = value("width"), height = value("height")
            guard width > 0, height > 0 else { return [] }
            let radius = min(max(value("rx", value("ry")), 0), min(width, height) / 2)
            if radius == 0 {
                let points = [DrawingPoint(x: x, y: y), .init(x: x + width, y: y), .init(x: x + width, y: y + height), .init(x: x, y: y + height), .init(x: x, y: y)]
                return [SVGSubpath(points: points, closed: true)]
            }
            return [SVGSubpath(points: Self.roundedRect(x: x, y: y, width: width, height: height, radius: radius), closed: true)]
        case "circle", "ellipse":
            let cx = value("cx"), cy = value("cy")
            let rx = name == "circle" ? value("r") : value("rx")
            let ry = name == "circle" ? value("r") : value("ry")
            guard rx > 0, ry > 0 else { return [] }
            let points = (0...64).map { index -> DrawingPoint in
                let angle = Double(index) / 64 * 2 * .pi
                return DrawingPoint(x: cx + rx * cos(angle), y: cy + ry * sin(angle))
            }
            return [SVGSubpath(points: points, closed: true)]
        default:
            return []
        }
    }

    private func append(_ paths: [SVGSubpath], context: SVGContext, fillAllowed: Bool) throws {
        guard !paths.isEmpty else { return }
        let transformed = try paths.map { path in
            SVGSubpath(points: try path.points.map { point in
                let mapped = context.transform.applying(point)
                try SVGLimits.checkCoordinate(mapped.x); try SVGLimits.checkCoordinate(mapped.y)
                return mapped
            }, closed: path.closed)
        }
        let width = max(0.1, context.style.strokeWidth * context.transform.widthScale)
        try SVGLimits.checkWidth(width)
        func add(_ stroke: SVGStroke) throws {
            pointCount += stroke.points.count
            guard pointCount <= SVGLimits.maxPoints else { throw SVGDrawingError.invalid("The SVG has more than \(SVGLimits.maxPoints) points.") }
            guard strokes.count < SVGLimits.maxStrokes else { throw SVGDrawingError.invalid("The SVG has more than \(SVGLimits.maxStrokes) strokes.") }
            strokes.append(stroke)
        }
        if let color = context.style.stroke {
            let color = Self.opacity(color, context.style.opacity * context.style.strokeOpacity)
            for path in transformed where path.points.count >= 2 {
                try add(SVGStroke(points: path.points, color: color, width: width, closed: path.closed))
            }
        }
        guard fillAllowed, context.style.fillEnabled else { return }
        let color = Self.opacity(context.style.fill, context.style.opacity * context.style.fillOpacity)
        for path in transformed where path.points.count >= 3 {
            var outline = path.points
            if outline.first != outline.last, let first = outline.first { outline.append(first) }
            try add(SVGStroke(points: outline, color: color, width: width, closed: true))
            if options.fill == .hatch {
                for stroke in try Self.hatching(path.points, color: color, width: width,
                                                budget: SVGLimits.maxHatchLines - hatchLineCount) {
                    hatchLineCount += 1
                    try add(stroke)
                }
            }
        }
    }

    private static func hatching(_ polygon: [DrawingPoint], color: DrawingColor, width: Double, budget: Int) throws -> [SVGStroke] {
        guard let minY = polygon.map(\.y).min(), let maxY = polygon.map(\.y).max() else { return [] }
        let step = max(4, width * 3)
        // Coordinates are already bounded, so this count is finite; refuse before looping.
        guard (maxY - minY) / step <= Double(budget) else {
            throw SVGDrawingError.invalid("Hatch fill would draw more than \(SVGLimits.maxHatchLines) lines.")
        }
        var rows: [SVGStroke] = []
        var y = (floor(minY / step) + 1) * step
        while y < maxY {
            var intersections: [Double] = []
            for index in polygon.indices {
                let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                guard (a.y <= y && b.y > y) || (b.y <= y && a.y > y) else { continue }
                intersections.append(a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y))
            }
            intersections.sort()
            var index = 0
            while index + 1 < intersections.count {
                guard rows.count < budget else {
                    throw SVGDrawingError.invalid("Hatch fill would draw more than \(SVGLimits.maxHatchLines) lines.")
                }
                rows.append(SVGStroke(points: [.init(x: intersections[index], y: y), .init(x: intersections[index + 1], y: y)], color: color, width: width, closed: false))
                index += 2
            }
            y += step
        }
        return rows
    }

    private static func style(_ inherited: SVGStyle, attributes: [String: String]) throws -> SVGStyle {
        var result = inherited
        var values = attributes
        if let inline = attributes["style"] {
            for declaration in inline.split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if pair.count == 2 { values[pair[0]] = pair[1] }
            }
        }
        if let value = values["stroke"] {
            result.stroke = value.lowercased() == "none" ? nil : try color(value)
        }
        if let value = values["fill"] {
            result.fillEnabled = value.lowercased() != "none"
            if result.fillEnabled { result.fill = try color(value) }
        }
        if let value = length(values["stroke-width"]) { result.strokeWidth = value }
        if let value = Double(values["opacity"] ?? "") { result.opacity = inherited.opacity * value }
        if let value = Double(values["stroke-opacity"] ?? "") { result.strokeOpacity = value }
        if let value = Double(values["fill-opacity"] ?? "") { result.fillOpacity = value }
        return result
    }

    private static func color(_ value: String) throws -> DrawingColor {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named: [String: DrawingColor] = [
            "black": .init(red: 0, green: 0, blue: 0), "white": .init(red: 1, green: 1, blue: 1),
            "red": .init(red: 1, green: 0, blue: 0), "green": .init(red: 0, green: 0.5, blue: 0),
            "blue": .init(red: 0, green: 0, blue: 1), "yellow": .init(red: 1, green: 1, blue: 0),
            "gray": .init(red: 0.5, green: 0.5, blue: 0.5), "grey": .init(red: 0.5, green: 0.5, blue: 0.5),
            "orange": .init(red: 1, green: 0.647, blue: 0), "purple": .init(red: 0.5, green: 0, blue: 0.5)
        ]
        if let value = named[text] { return value }
        if text.hasPrefix("#") {
            let hex = String(text.dropFirst())
            let expanded = hex.count == 3 || hex.count == 4 ? hex.map { "\($0)\($0)" }.joined() : hex
            guard [6, 8].contains(expanded.count), let bits = UInt64(expanded, radix: 16) else {
                throw SVGDrawingError.invalid("Invalid SVG color: \(value)")
            }
            let hasAlpha = expanded.count == 8
            return DrawingColor(red: Double((bits >> (hasAlpha ? 24 : 16)) & 255) / 255,
                                green: Double((bits >> (hasAlpha ? 16 : 8)) & 255) / 255,
                                blue: Double((bits >> (hasAlpha ? 8 : 0)) & 255) / 255,
                                alpha: hasAlpha ? Double(bits & 255) / 255 : 1)
        }
        if text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") {
            let parts = text[text.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4 else { throw SVGDrawingError.invalid("Invalid SVG color: \(value)") }
            func component(_ part: String) -> Double? {
                let value = part.hasSuffix("%") ? Double(part.dropLast()).map { $0 / 100 } : Double(part).map { $0 / 255 }
                return value.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            }
            guard let red = component(parts[0]), let green = component(parts[1]), let blue = component(parts[2]) else {
                throw SVGDrawingError.invalid("Invalid SVG color: \(value)")
            }
            let alpha = parts.count == 4 ? (Double(parts[3]) ?? 1) : 1
            return DrawingColor(red: red, green: green, blue: blue, alpha: alpha.isFinite ? min(1, max(0, alpha)) : 1)
        }
        throw SVGDrawingError.invalid("Unsupported SVG color: \(value)")
    }

    private static func opacity(_ color: DrawingColor, _ value: Double) -> DrawingColor {
        let alpha = color.alpha * value
        return DrawingColor(red: color.red, green: color.green, blue: color.blue, alpha: alpha.isFinite ? max(0, min(1, alpha)) : 1)
    }

    private static func length(_ text: String?) -> Double? {
        guard let text else { return nil }
        let pattern = #"[-+]?(?:\d*\.?\d+)(?:[eE][-+]?\d+)?"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return Double(text[range])
    }

    private static func numbers(_ text: String?) -> [Double]? {
        guard let text else { return nil }
        let pattern = #"[-+]?(?:\d*\.?\d+)(?:[eE][-+]?\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).flatMap { Double(text[$0]) }
        }
    }

    private static func transform(_ text: String?) throws -> SVGTransform {
        guard let text, !text.isEmpty else { return SVGTransform() }
        let regex = try NSRegularExpression(pattern: #"([A-Za-z]+)\s*\(([^)]*)\)"#)
        var result = SVGTransform()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let nameRange = Range(match.range(at: 1), in: text), let argsRange = Range(match.range(at: 2), in: text) else { continue }
            let name = text[nameRange].lowercased(), args = numbers(String(text[argsRange])) ?? []
            let operation: SVGTransform
            switch name {
            case "matrix" where args.count == 6:
                operation = SVGTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            case "translate" where args.count == 1 || args.count == 2:
                operation = SVGTransform(tx: args[0], ty: args.count == 2 ? args[1] : 0)
            case "scale" where args.count == 1 || args.count == 2:
                operation = SVGTransform(a: args[0], d: args.count == 2 ? args[1] : args[0])
            case "rotate" where args.count == 1 || args.count == 3:
                let angle = args[0] * .pi / 180
                let rotation = SVGTransform(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle))
                if args.count == 3 {
                    operation = SVGTransform(tx: args[1], ty: args[2]).multiplied(by: rotation).multiplied(by: SVGTransform(tx: -args[1], ty: -args[2]))
                } else { operation = rotation }
            case "skewx" where args.count == 1:
                operation = SVGTransform(c: tan(args[0] * .pi / 180))
            case "skewy" where args.count == 1:
                operation = SVGTransform(b: tan(args[0] * .pi / 180))
            default:
                throw SVGDrawingError.invalid("Invalid SVG transform: \(name)")
            }
            result = result.multiplied(by: operation)
        }
        return result
    }

    private static func roundedRect(x: Double, y: Double, width: Double, height: Double, radius: Double) -> [DrawingPoint] {
        var points: [DrawingPoint] = []
        let centers = [(x + width - radius, y + radius, -Double.pi / 2),
                       (x + width - radius, y + height - radius, 0.0),
                       (x + radius, y + height - radius, Double.pi / 2),
                       (x + radius, y + radius, Double.pi)]
        for (cx, cy, start) in centers {
            for index in 0...8 {
                let angle = start + Double(index) / 8 * .pi / 2
                points.append(.init(x: cx + radius * cos(angle), y: cy + radius * sin(angle)))
            }
        }
        points.append(points[0])
        return points
    }
}

private struct SVGPathParser {
    let tokens: [String]
    var index = 0
    var command: Character?
    var current = DrawingPoint(x: 0, y: 0)
    var start = DrawingPoint(x: 0, y: 0)
    var lastCubicControl: DrawingPoint?
    var lastQuadraticControl: DrawingPoint?
    var subpaths: [SVGSubpath] = []
    var points: [DrawingPoint] = []
    let pointBudget: Int
    var pointTotal = 0

    init(_ source: String, pointBudget: Int = SVGLimits.maxPoints) throws {
        self.pointBudget = pointBudget
        let regex = try NSRegularExpression(pattern: #"[A-Za-z]|[-+]?(?:\d*\.?\d+)(?:[eE][-+]?\d+)?"#)
        tokens = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        }
    }

    mutating func parse() throws -> [SVGSubpath] {
        while index < tokens.count {
            if Self.isCommand(tokens[index]) {
                command = tokens[index].first
                index += 1
            }
            guard let raw = command else { throw SVGDrawingError.invalid("SVG path data is missing a command.") }
            let relative = raw.isLowercase
            switch raw.uppercased() {
            case "M":
                let values = try read(2), point = makePoint(values[0], values[1], relative: relative)
                finish(closed: false)
                current = point; start = point; points = [point]
                command = relative ? "l" : "L"
                clearControls()
            case "L":
                line(to: makePoint(try number(), try number(), relative: relative))
            case "H":
                let value = try number(); line(to: .init(x: relative ? current.x + value : value, y: current.y))
            case "V":
                let value = try number(); line(to: .init(x: current.x, y: relative ? current.y + value : value))
            case "C":
                let values = try read(6)
                let c1 = makePoint(values[0], values[1], relative: relative)
                let c2 = makePoint(values[2], values[3], relative: relative)
                let end = makePoint(values[4], values[5], relative: relative)
                cubic(c1, c2, end); lastCubicControl = c2; lastQuadraticControl = nil
            case "S":
                let values = try read(4)
                let c1 = lastCubicControl.map { DrawingPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = makePoint(values[0], values[1], relative: relative)
                let end = makePoint(values[2], values[3], relative: relative)
                cubic(c1, c2, end); lastCubicControl = c2; lastQuadraticControl = nil
            case "Q":
                let values = try read(4)
                let control = makePoint(values[0], values[1], relative: relative)
                let end = makePoint(values[2], values[3], relative: relative)
                quadratic(control, end); lastQuadraticControl = control; lastCubicControl = nil
            case "T":
                let values = try read(2)
                let control = lastQuadraticControl.map { DrawingPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = makePoint(values[0], values[1], relative: relative)
                quadratic(control, end); lastQuadraticControl = control; lastCubicControl = nil
            case "A":
                let values = try read(7)
                let end = makePoint(values[5], values[6], relative: relative)
                arc(rx: values[0], ry: values[1], rotation: values[2], large: values[3] != 0, sweep: values[4] != 0, end: end)
                clearControls()
            case "Z":
                if current != start { points.append(start) }
                current = start; finish(closed: true); command = nil; clearControls()
            default:
                throw SVGDrawingError.invalid("Unsupported SVG path command: \(raw)")
            }
            guard pointTotal + points.count <= pointBudget else {
                throw SVGDrawingError.invalid("The SVG has more than \(SVGLimits.maxPoints) points.")
            }
        }
        finish(closed: false)
        return subpaths
    }

    private mutating func read(_ count: Int) throws -> [Double] {
        try (0..<count).map { _ in try number() }
    }

    private mutating func number() throws -> Double {
        guard index < tokens.count, !Self.isCommand(tokens[index]), let value = Double(tokens[index]) else {
            throw SVGDrawingError.invalid("SVG path command has too few values.")
        }
        index += 1
        try SVGLimits.checkCoordinate(value)
        return value
    }

    private func makePoint(_ x: Double, _ y: Double, relative: Bool) -> DrawingPoint {
        relative ? DrawingPoint(x: current.x + x, y: current.y + y) : DrawingPoint(x: x, y: y)
    }

    private mutating func line(to point: DrawingPoint) {
        points.append(point); current = point; clearControls()
    }

    private mutating func cubic(_ c1: DrawingPoint, _ c2: DrawingPoint, _ end: DrawingPoint) {
        let origin = current
        for step in 1...16 {
            let t = Double(step) / 16, u = 1 - t
            points.append(.init(x: u * u * u * origin.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x,
                                y: u * u * u * origin.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y))
        }
        current = end
    }

    private mutating func quadratic(_ control: DrawingPoint, _ end: DrawingPoint) {
        let origin = current
        for step in 1...12 {
            let t = Double(step) / 12, u = 1 - t
            points.append(.init(x: u * u * origin.x + 2 * u * t * control.x + t * t * end.x,
                                y: u * u * origin.y + 2 * u * t * control.y + t * t * end.y))
        }
        current = end
    }

    private mutating func arc(rx inputRX: Double, ry inputRY: Double, rotation: Double,
                              large: Bool, sweep: Bool, end: DrawingPoint) {
        var rx = abs(inputRX), ry = abs(inputRY)
        guard rx > 0, ry > 0, current != end else { line(to: end); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (current.x - end.x) / 2, dy = (current.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let ratio = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if ratio > 1 { let scale = sqrt(ratio); rx *= scale; ry *= scale }
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let sign = large == sweep ? -1.0 : 1.0
        let coefficient = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
        let cx1 = coefficient * rx * y1 / ry, cy1 = coefficient * -ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (current.x + end.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (current.y + end.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            let value = acos(max(-1, min(1, length == 0 ? 1 : dot / length)))
            return ux * vy - uy * vx < 0 ? -value : value
        }
        let ux = (x1 - cx1) / rx, uy = (y1 - cy1) / ry
        let vx = (-x1 - cx1) / rx, vy = (-y1 - cy1) / ry
        let startAngle = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let steps = max(4, Int(ceil(abs(delta) / (.pi / 16))))
        for step in 1...steps {
            let theta = startAngle + delta * Double(step) / Double(steps)
            points.append(.init(x: cx + cosPhi * rx * cos(theta) - sinPhi * ry * sin(theta),
                                y: cy + sinPhi * rx * cos(theta) + cosPhi * ry * sin(theta)))
        }
        current = end
    }

    private mutating func finish(closed: Bool) {
        if points.count >= 2 { subpaths.append(SVGSubpath(points: points, closed: closed)); pointTotal += points.count }
        points = []
    }

    private mutating func clearControls() {
        lastCubicControl = nil; lastQuadraticControl = nil
    }

    private static func isCommand(_ token: String) -> Bool {
        token.count == 1 && token.first?.isLetter == true
    }
}
