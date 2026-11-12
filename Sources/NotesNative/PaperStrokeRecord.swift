import AppKit
import PencilKit

/// A comparable copy of one PencilKit stroke: ink type, sRGB colour, and each point's position, width, and opacity.
/// Positions include the stroke transform, so they are in drawing coordinates.
public struct PaperStrokeRecord: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var x: Double, y: Double, width: Double, opacity: Double
        public init(x: Double, y: Double, width: Double, opacity: Double) {
            self.x = x; self.y = y; self.width = width; self.opacity = opacity
        }
    }

    public var ink: String
    public var color: [Double]
    public var points: [Point]

    public init(ink: String, color: [Double], points: [Point]) {
        self.ink = ink; self.color = color; self.points = points
    }

    public init(_ stroke: PKStroke) {
        let srgb = stroke.ink.color.usingColorSpace(.sRGB) ?? stroke.ink.color
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(ink: stroke.ink.inkType.rawValue, color: [red, green, blue, alpha].map(Double.init),
                  points: stroke.path.map { point in
                      let location = point.location.applying(stroke.transform)
                      return Point(x: location.x, y: location.y, width: point.size.width, opacity: point.opacity)
                  })
    }

    /// Every stroke in the drawings, in order.
    public static func records(_ drawings: [PKDrawing]) -> [PaperStrokeRecord] {
        drawings.flatMap(\.strokes).map(PaperStrokeRecord.init)
    }

    /// Returns nil when the read-back strokes match the expected ones within `tolerance`,
    /// or a description of the first difference.
    /// Notes moves a new drawing on its canvas, so one translation shared by every point is allowed.
    public static func mismatch(expected: [PaperStrokeRecord], actual: [PaperStrokeRecord], tolerance: Double = 0.01) -> String? {
        guard expected.count == actual.count else { return "Expected \(expected.count) strokes; read back \(actual.count)." }
        func close(_ left: Double, _ right: Double) -> Bool { abs(left - right) <= tolerance }
        let origin = (expected.first?.points.first, actual.first?.points.first)
        let dx = origin.0.flatMap { want in origin.1.map { $0.x - want.x } } ?? 0
        let dy = origin.0.flatMap { want in origin.1.map { $0.y - want.y } } ?? 0
        for (index, (want, got)) in zip(expected, actual).enumerated() {
            if want.ink != got.ink { return "Stroke \(index) uses ink \(got.ink); expected \(want.ink)." }
            if want.color.count != got.color.count || !zip(want.color, got.color).allSatisfy(close) {
                return "Stroke \(index) colour is \(got.color); expected \(want.color)."
            }
            if want.points.count != got.points.count {
                return "Stroke \(index) has \(got.points.count) points; expected \(want.points.count)."
            }
            for (pointIndex, (a, b)) in zip(want.points, got.points).enumerated() {
                if !close(a.x + dx, b.x) || !close(a.y + dy, b.y) {
                    return "Stroke \(index) point \(pointIndex) is at (\(b.x), \(b.y)); expected (\(a.x + dx), \(a.y + dy))."
                }
                if !close(a.width, b.width) { return "Stroke \(index) point \(pointIndex) width is \(b.width); expected \(a.width)." }
                if !close(a.opacity, b.opacity) {
                    return "Stroke \(index) point \(pointIndex) opacity is \(b.opacity); expected \(a.opacity)."
                }
            }
        }
        return nil
    }
}
