import Foundation

public enum DiagramError: Error, CustomStringConvertible, Equatable {
    case invalidWidth
    case invalidScale
    case invalidFileType
    case invalidPNG
    case sourceMetadataMissing
    case renderFailed(String)

    public var description: String {
        switch self {
        case .invalidWidth: return "Diagram width must be between 1 and 2400 pixels."
        case .invalidScale: return "Diagram scale must be 2 or 3."
        case .invalidFileType: return "Diagram files must use .svg, .html, or .htm."
        case .invalidPNG: return "The rendered diagram is not a valid PNG."
        case .sourceMetadataMissing: return "The image has no embedded diagram source."
        case .renderFailed(let message): return message
        }
    }
}

public enum DiagramBackground: String, CaseIterable, Sendable {
    case white
    case transparent
    case auto
}

public struct DiagramRenderOptions: Equatable, Sendable {
    public let width: Int
    public let scale: Int
    public let background: DiagramBackground
    public let dark: Bool

    public init(width: Int = 700, scale: Int = 2, background: DiagramBackground = .auto, dark: Bool = false) throws {
        guard (1...2400).contains(width) else { throw DiagramError.invalidWidth }
        guard [2, 3].contains(scale) else { throw DiagramError.invalidScale }
        self.width = width
        self.scale = scale
        self.background = background
        self.dark = dark
    }
}

public struct DiagramPixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int
}

public struct DiagramRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct DiagramPDFTransform: Equatable, Sendable {
    public let scale: Double
    public let x: Double
    public let y: Double
}

public enum DiagramGeometry {
    public static func outputPixelSize(contentWidth: Double, contentHeight: Double, displayWidth: Int, scale: Int) throws -> DiagramPixelSize {
        guard contentWidth.isFinite, contentHeight.isFinite, contentWidth > 0, contentHeight > 0 else {
            throw DiagramError.renderFailed("The diagram has no visible content bounds.")
        }
        let width = displayWidth * scale
        let height = Int((Double(width) * contentHeight / contentWidth).rounded())
        return DiagramPixelSize(width: width, height: max(1, height))
    }

    public static func cropRect(left: Double, top: Double, right: Double, bottom: Double,
                                canvasWidth: Double, canvasHeight: Double, padding: Double) throws -> DiagramRect {
        guard [left, top, right, bottom, canvasWidth, canvasHeight, padding].allSatisfy(\.isFinite),
              right > left, bottom > top, canvasWidth > 0, canvasHeight > 0, padding >= 0 else {
            throw DiagramError.renderFailed("The diagram has no visible content bounds.")
        }
        let x = max(0, floor(left - padding))
        let y = max(0, floor(top - padding))
        let endX = min(canvasWidth, ceil(right + padding))
        let endY = min(canvasHeight, ceil(bottom + padding))
        guard endX > x, endY > y else { throw DiagramError.renderFailed("The diagram has no visible content bounds.") }
        return DiagramRect(x: x, y: y, width: endX - x, height: endY - y)
    }

    public static func pdfTransform(pageWidth: Double, pageHeight: Double,
                                    pixelWidth: Int, pixelHeight: Int) throws -> DiagramPDFTransform {
        guard pageWidth.isFinite, pageHeight.isFinite, pageWidth > 0, pageHeight > 0,
              pixelWidth > 0, pixelHeight > 0 else {
            throw DiagramError.renderFailed("The PDF page has invalid bounds.")
        }
        let scale = min(Double(pixelWidth) / pageWidth, Double(pixelHeight) / pageHeight)
        return DiagramPDFTransform(scale: scale,
                                   x: (Double(pixelWidth) - pageWidth * scale) / 2,
                                   y: (Double(pixelHeight) - pageHeight * scale) / 2)
    }
}

public struct DiagramSource: Equatable, Sendable {
    public let data: Data
    public let filename: String
    public let mediaType: String

    public init(file: URL) throws {
        let ext = file.pathExtension.lowercased()
        guard ["svg", "html", "htm"].contains(ext) else { throw DiagramError.invalidFileType }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard !data.isEmpty else { throw DiagramError.renderFailed("The diagram file is empty.") }
        self.data = data
        self.filename = file.lastPathComponent
        self.mediaType = ext == "svg" ? "image/svg+xml" : "text/html"
    }

    public init(data: Data, filename: String, mediaType: String) {
        self.data = data
        self.filename = filename
        self.mediaType = mediaType
    }
}

public struct RenderedDiagram: Equatable, Sendable {
    public let png: Data
    public let source: DiagramSource
    public let pixelSize: DiagramPixelSize
}
