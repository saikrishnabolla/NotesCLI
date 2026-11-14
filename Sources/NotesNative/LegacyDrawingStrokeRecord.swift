import Foundation
import NotesCore

public struct LegacyDrawingStrokeRecord: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var radius: Double
        public var opacity: Double
        public var azimuth: Double
        public var edgeWidth: Double
        public var aspectRatio: Double
        public var timestamp: Double

        public init(x: Double, y: Double, radius: Double, opacity: Double = 1,
                    azimuth: Double = 0, edgeWidth: Double = 1,
                    aspectRatio: Double = 1, timestamp: Double) {
            self.x = x; self.y = y; self.radius = radius; self.opacity = opacity
            self.azimuth = azimuth; self.edgeWidth = edgeWidth
            self.aspectRatio = aspectRatio; self.timestamp = timestamp
        }
    }

    public var color: [Double]
    public var points: [Point]

    public init(color: [Double], points: [Point]) {
        self.color = color; self.points = points
    }

    public init(_ stroke: PaperStrokeRecord) {
        color = stroke.color
        points = stroke.points.enumerated().map { index, point in
            Point(x: point.x, y: point.y, radius: point.width, opacity: point.opacity,
                  timestamp: Double(index) / 120)
        }
    }

    public static func validate(_ records: [LegacyDrawingStrokeRecord]) throws {
        guard !records.isEmpty, records.count <= 100_000 else {
            throw NotesError("invalid_legacy_drawing_snapshot", "The saved legacy drawing has no safe stroke set.")
        }
        var pointCount = 0
        for record in records {
            pointCount += record.points.count
            guard record.color.count == 4,
                  record.color.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  record.points.count >= 2, record.points.count <= 100_000,
                  pointCount <= 1_000_000,
                  record.points.allSatisfy({ point in
                      point.x.isFinite && point.y.isFinite && point.radius.isFinite && point.radius > 0 &&
                          point.opacity.isFinite && (0...1).contains(point.opacity) &&
                          point.azimuth.isFinite && point.edgeWidth.isFinite && point.edgeWidth >= 0 &&
                          point.aspectRatio.isFinite && point.aspectRatio > 0 && point.timestamp.isFinite
                  }) else {
                throw NotesError("invalid_legacy_drawing_snapshot", "The saved legacy drawing stroke data is invalid.")
            }
        }
    }

    public static func mismatch(expected: [LegacyDrawingStrokeRecord], actual: [LegacyDrawingStrokeRecord],
                                tolerance: Double = 0.01) -> String? {
        guard expected.count == actual.count else {
            return "Expected \(expected.count) strokes; read back \(actual.count)."
        }
        func close(_ left: Double, _ right: Double) -> Bool { abs(left - right) <= tolerance }
        let origin = (expected.first?.points.first, actual.first?.points.first)
        let dx = origin.0.flatMap { want in origin.1.map { $0.x - want.x } } ?? 0
        let dy = origin.0.flatMap { want in origin.1.map { $0.y - want.y } } ?? 0
        for (strokeIndex, pair) in zip(expected, actual).enumerated() {
            let want = pair.0, got = pair.1
            if want.color.count != got.color.count || !zip(want.color, got.color).allSatisfy(close) {
                return "Stroke \(strokeIndex) colour changed."
            }
            guard want.points.count == got.points.count else {
                return "Stroke \(strokeIndex) point count changed."
            }
            for (pointIndex, pointPair) in zip(want.points, got.points).enumerated() {
                let a = pointPair.0, b = pointPair.1
                if !close(a.x + dx, b.x) || !close(a.y + dy, b.y) ||
                    !close(a.radius, b.radius) || !close(a.opacity, b.opacity) ||
                    !close(a.azimuth, b.azimuth) || !close(a.edgeWidth, b.edgeWidth) ||
                    !close(a.aspectRatio, b.aspectRatio) {
                    return "Stroke \(strokeIndex) point \(pointIndex) changed."
                }
            }
        }
        return nil
    }
}
