import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import NotesCore
import UniformTypeIdentifiers
import Vision

struct ScanEdgeCandidate: Sendable {
    var crop: ScanCrop
    var confidence: Float
}

public enum ScanCorrection {
    private static let minimumArea = 0.01
    private static let minimumEdgeLength = 0.02
    private static let minimumCandidateConfidence: Float = 0.7
    private static let maximumInputPixels = 40_000_000
    private static let maximumTotalInputPixels = 100_000_000
    private static let maximumOutputPixels = 100_000_000
    private static let maximumOutputDimension = 20_000

    private struct ImageMetadata {
        var width: Int
        var height: Int
        var pixels: Int { width * height }
    }

    static func scanCrop(visionTopLeft: CGPoint, visionTopRight: CGPoint,
                         visionBottomRight: CGPoint, visionBottomLeft: CGPoint) -> ScanCrop {
        func point(_ value: CGPoint) -> ScanPoint {
            ScanPoint(x: value.x, y: 1 - value.y)
        }
        return ScanCrop(bottomLeft: point(visionBottomLeft), bottomRight: point(visionBottomRight),
                        topLeft: point(visionTopLeft), topRight: point(visionTopRight))
    }

    public static func validate(_ crop: ScanCrop) throws {
        let points = [crop.topLeft, crop.topRight, crop.bottomRight, crop.bottomLeft]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                                  (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw NotesError("unsafe_scan_geometry", "Scan corners must be finite normalized coordinates.")
        }
        func cross(_ a: ScanPoint, _ b: ScanPoint, _ c: ScanPoint) -> Double {
            (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        let turns = points.indices.map { cross(points[$0], points[($0 + 1) % 4], points[($0 + 2) % 4]) }
        guard turns.allSatisfy({ $0 > 0.000_001 }) else {
            throw NotesError("unsafe_scan_geometry", "Scan corners must use top-left, top-right, bottom-right, bottom-left winding and form one convex quadrilateral.")
        }
        let edges = points.indices.map { index -> Double in
            let next = points[(index + 1) % 4]
            return hypot(next.x - points[index].x, next.y - points[index].y)
        }
        guard edges.allSatisfy({ $0 >= minimumEdgeLength }), area(crop) >= minimumArea else {
            throw NotesError("unsafe_scan_geometry", "The detected scan rectangle is too small for safe correction.")
        }
    }

    static func selectCandidate(_ candidates: [ScanEdgeCandidate]) throws -> ScanCrop {
        let valid = candidates.compactMap { candidate -> (ScanEdgeCandidate, Double)? in
            guard candidate.confidence >= minimumCandidateConfidence,
                  (try? validate(candidate.crop)) != nil else { return nil }
            return (candidate, area(candidate.crop))
        }.sorted {
            if $0.0.confidence != $1.0.confidence { return $0.0.confidence > $1.0.confidence }
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return sortKey($0.0.crop).lexicographicallyPrecedes(sortKey($1.0.crop))
        }
        var distinct: [(ScanEdgeCandidate, Double)] = []
        for candidate in valid where !distinct.contains(where: { nearDuplicate($0.0.crop, candidate.0.crop) }) {
            distinct.append(candidate)
        }
        guard let selected = distinct.first else {
            throw NotesError("scan_edges_not_found", "No safe document rectangle was detected in the image.")
        }
        guard distinct.count == 1 else {
            throw NotesError("ambiguous_scan_edges", "More than one plausible document rectangle was detected.")
        }
        return selected.0.crop
    }

    public static func detectCrop(at url: URL) throws -> ScanCrop {
        let source = try imageSource(at: url)
        _ = try metadata(source: source, requireUpOrientation: true)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NotesError("invalid_scan_image", "The scan page is not a readable image.")
        }
        let request = VNDetectRectanglesRequest()
        request.revision = VNDetectRectanglesRequestRevision1
        request.minimumAspectRatio = 0.1
        request.maximumAspectRatio = 1
        request.minimumSize = 0.15
        request.minimumConfidence = minimumCandidateConfidence
        request.quadratureTolerance = 30
        request.maximumObservations = 8
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        } catch {
            throw NotesError("scan_edge_detection_failed", "Vision could not inspect the scan image.")
        }
        let candidates = (request.results ?? []).map {
            ScanEdgeCandidate(crop: scanCrop(visionTopLeft: $0.topLeft, visionTopRight: $0.topRight,
                                             visionBottomRight: $0.bottomRight, visionBottomLeft: $0.bottomLeft),
                              confidence: $0.confidence)
        }
        return try selectCandidate(candidates)
    }

    public static func correctedPage(_ page: FrozenAttachmentInput) throws -> FrozenAttachmentInput {
        let source = try imageSource(at: page.url)
        _ = try metadata(source: source, requireUpOrientation: true)
        let crop = try detectCrop(at: page.url)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NotesError("invalid_scan_image", "The scan page is not a readable image: \(page.sourceName)")
        }
        let data = try correctedPNG(image: CIImage(cgImage: image), crop: crop)
        let stem = URL(fileURLWithPath: page.sourceName).deletingPathExtension().lastPathComponent
        return try FrozenAttachmentInput(data: data, suggestedName: stem + "-corrected.png")
    }

    public static func validateImages(at urls: [URL], requireUpOrientation: Bool) throws {
        var pixels: [Int] = []
        pixels.reserveCapacity(urls.count)
        for url in urls {
            let source = try imageSource(at: url)
            pixels.append(try metadata(source: source, requireUpOrientation: requireUpOrientation).pixels)
        }
        try validatePixelTotal(pixels)
    }

    public static func validateImageData(_ data: Data, requireUpOrientation: Bool) throws -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw NotesError("invalid_scan_image_metadata", "The scan page does not contain readable image metadata.")
        }
        return try metadata(source: source, requireUpOrientation: requireUpOrientation).pixels
    }

    static func validateMetadata(width: Int, height: Int, orientation: UInt32,
                                 requireUpOrientation: Bool) throws {
        guard width > 0, height > 0 else {
            throw NotesError("invalid_scan_image_metadata", "The scan image has invalid pixel dimensions.")
        }
        guard width <= maximumOutputDimension, height <= maximumOutputDimension,
              width <= maximumInputPixels / height else {
            throw NotesError("scan_image_too_large", "Each scan image is limited to 40,000,000 pixels and 20,000 pixels per dimension.")
        }
        if requireUpOrientation && orientation != CGImagePropertyOrientation.up.rawValue {
            throw NotesError("scan_exif_orientation_unsupported", "Perspective correction requires EXIF orientation 1 (.up); normalize the image first.")
        }
    }

    public static func validatePixelTotal(_ pixels: [Int]) throws {
        var total = 0
        for count in pixels {
            guard count >= 0, count <= maximumTotalInputPixels,
                  total <= maximumTotalInputPixels - count else {
                throw NotesError("scan_total_pixels_too_large", "Scan inputs are limited to 100,000,000 pixels per request.")
            }
            total += count
        }
    }

    static func correctedPNG(image: CGImage, crop: ScanCrop) throws -> Data {
        try validate(crop)
        return try correctedPNG(image: CIImage(cgImage: image), crop: crop)
    }

    private static func correctedPNG(image: CIImage, crop: ScanCrop) throws -> Data {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else {
            throw NotesError("invalid_scan_image", "The scan image has invalid pixel dimensions.")
        }
        func point(_ value: ScanPoint) -> CGPoint {
            CGPoint(x: extent.minX + value.x * extent.width,
                    y: extent.minY + (1 - value.y) * extent.height)
        }
        let topLeft = point(crop.topLeft), topRight = point(crop.topRight)
        let bottomRight = point(crop.bottomRight), bottomLeft = point(crop.bottomLeft)
        let width = max(1, Int(max(distance(topLeft, topRight), distance(bottomLeft, bottomRight)).rounded()))
        let height = max(1, Int(max(distance(topLeft, bottomLeft), distance(topRight, bottomRight)).rounded()))
        guard width <= maximumOutputDimension, height <= maximumOutputDimension,
              width <= maximumOutputPixels / height else {
            throw NotesError("scan_correction_too_large", "The corrected scan would exceed the safe pixel limit.")
        }

        let identity = crop == ScanCrop(
            bottomLeft: ScanPoint(x: 0, y: 1), bottomRight: ScanPoint(x: 1, y: 1),
            topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1, y: 0)
        )
        let output: CIImage
        if identity {
            output = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        } else {
            guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
                throw NotesError("scan_correction_unavailable", "Core Image perspective correction is unavailable.")
            }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
            filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
            filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
            filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
            guard let corrected = filter.outputImage, corrected.extent.width > 0, corrected.extent.height > 0 else {
                throw NotesError("scan_correction_failed", "Core Image could not render the detected rectangle.")
            }
            let normalized = corrected.transformed(by: CGAffineTransform(
                translationX: -corrected.extent.minX, y: -corrected.extent.minY))
            output = normalized.transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / corrected.extent.width,
                y: CGFloat(height) / corrected.extent.height))
        }
        let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        guard let rendered = context.createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            throw NotesError("scan_correction_failed", "Core Image did not produce corrected pixels.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw NotesError("scan_correction_failed", "The corrected scan could not be encoded.")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NotesError("scan_correction_failed", "The corrected scan could not be encoded.")
        }
        return data as Data
    }

    private static func area(_ crop: ScanCrop) -> Double {
        let points = [crop.topLeft, crop.topRight, crop.bottomRight, crop.bottomLeft]
        return abs(points.indices.reduce(0) { sum, index in
            let next = points[(index + 1) % points.count]
            return sum + points[index].x * next.y - next.x * points[index].y
        }) / 2
    }

    private static func imageSource(at url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NotesError("invalid_scan_image_metadata", "The scan page does not contain readable image metadata.")
        }
        return source
    }

    private static func metadata(source: CGImageSource, requireUpOrientation: Bool) throws -> ImageMetadata {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw NotesError("invalid_scan_image_metadata", "The scan page does not contain readable image dimensions.")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        try validateMetadata(width: width, height: height, orientation: orientation,
                             requireUpOrientation: requireUpOrientation)
        return ImageMetadata(width: width, height: height)
    }

    private static func nearDuplicate(_ lhs: ScanCrop, _ rhs: ScanCrop) -> Bool {
        zip(sortKey(lhs), sortKey(rhs)).allSatisfy { abs($0 - $1) <= 0.02 }
    }

    private static func sortKey(_ crop: ScanCrop) -> [Double] {
        [crop.topLeft.x, crop.topLeft.y, crop.topRight.x, crop.topRight.y,
         crop.bottomRight.x, crop.bottomRight.y, crop.bottomLeft.x, crop.bottomLeft.y]
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }
}
