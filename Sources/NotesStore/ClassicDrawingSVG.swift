import Foundation
import PencilKit

enum ClassicDrawingSVG {
    static func decode(_ data: Data) -> String? {
        guard let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return nil }
        let bounds = drawing.bounds.isNull || drawing.bounds.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : drawing.bounds
        let paths = drawing.strokes.compactMap { stroke -> String? in
            let points = Array(stroke.path.interpolatedPoints(by: .distance(1)))
            guard !points.isEmpty else { return nil }
            let commands = points.enumerated().map { index, point in
                "\(index == 0 ? "M" : "L")\(number(point.location.x)) \(number(point.location.y))"
            }.joined(separator: " ")
            let color = stroke.ink.color.usingColorSpace(.deviceRGB) ?? stroke.ink.color
            return "<path d=\"\(commands)\" fill=\"none\" stroke=\"rgb(\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255)))\" stroke-width=\"\(number(points.map(\.size.width).max() ?? 1))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        }.joined()
        guard !paths.isEmpty else { return nil }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(number(bounds.minX)) \(number(bounds.minY)) \(number(max(1, bounds.width))) \(number(max(1, bounds.height)))\">\(paths)</svg>"
    }
    private static func number(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }
}
