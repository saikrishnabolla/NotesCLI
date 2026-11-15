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
    private static let maximumOutputPixels = 100_000_000
    private static let maximumOutputDimension = 20_000

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
        guard turns.allSatisfy({ $0 > 0.000_001 }) || turns.allSatisfy({ $0 < -0.000_001 }) else {
            throw NotesError("unsafe_scan_geometry", "Scan corners must form one convex, non-intersecting quadrilateral.")
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
        guard !candidates.isEmpty else {
            throw NotesError("scan_edges_not_found", "No document rectangle was detected in the image.")
        }
        let valid = try candidates.map { candidate -> (ScanEdgeCandidate, Double) in
            try validate(candidate.crop)
            return (candidate, area(candidate.crop))
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.confidence != $1.0.confidence { return $0.0.confidence > $1.0.confidence }
            return sortKey($0.0.crop).lexicographicallyPrecedes(sortKey($1.0.crop))
        }
        if valid.count > 1,
           valid[1].1 / valid[0].1 >= 0.8,
           abs(valid[0].0.confidence - valid[1].0.confidence) <= 0.1 {
            throw NotesError("ambiguous_scan_edges", "More than one comparable document rectangle was detected.")
        }
        return valid[0].0.crop
    }

    public static func detectCrop(at url: URL) throws -> ScanCrop {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NotesError("invalid_scan_image", "The scan page is not a readable image.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        let request = VNDetectRectanglesRequest()
        request.revision = VNDetectRectanglesRequestRevision1
        request.minimumAspectRatio = 0.1
        request.maximumAspectRatio = 1
        request.minimumSize = 0.15
        request.minimumConfidence = 0.7
        request.quadratureTolerance = 30
        request.maximumObservations = 8
        do {
            try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
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
        guard let source = CGImageSourceCreateWithURL(page.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NotesError("invalid_scan_image", "The scan page is not a readable image: \(page.sourceName)")
        }
        let crop = try detectCrop(at: page.url)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        let data = try correctedPNG(image: oriented, crop: crop)
        let stem = URL(fileURLWithPath: page.sourceName).deletingPathExtension().lastPathComponent
        return try FrozenAttachmentInput(data: data, suggestedName: stem + "-corrected.png")
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

    private static func sortKey(_ crop: ScanCrop) -> [Double] {
        [crop.topLeft.x, crop.topLeft.y, crop.topRight.x, crop.topRight.y,
         crop.bottomRight.x, crop.bottomRight.y, crop.bottomLeft.x, crop.bottomLeft.y]
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }
}
