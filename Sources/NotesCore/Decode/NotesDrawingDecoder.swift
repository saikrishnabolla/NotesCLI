import Foundation

public enum NotesDrawingDecoder {
    public static func svg(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<svg") { return text }
            if let object = try? JSONSerialization.jsonObject(with: data), let strokes = strokes(in: object), !strokes.isEmpty {
                return render(strokes)
            }
        }
        if let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let strokes = strokes(in: object), !strokes.isEmpty { return render(strokes) }
        return nil
    }

    private static func strokes(in value: Any) -> [[CGPoint]]? {
        if let dictionary = value as? [String: Any] {
            for key in ["strokes", "PKStrokes", "points", "path"] {
                if let candidate = dictionary[key] { let result = strokeArray(candidate); if !result.isEmpty { return result } }
            }
            for candidate in dictionary.values {
                if let result = strokes(in: candidate), !result.isEmpty { return result }
            }
        } else if let array = value as? [Any] {
            let result = strokeArray(array); if !result.isEmpty { return result }
            for candidate in array { if let result = strokes(in: candidate), !result.isEmpty { return result } }
        }
        return nil
    }

    private static func strokeArray(_ value: Any) -> [[CGPoint]] {
        guard let array = value as? [Any] else { return [] }
        if let points = points(array), points.count > 1 { return [points] }
        return array.compactMap { item in
            if let dictionary = item as? [String: Any] {
                for key in ["points", "path", "controlPoints"] {
                    if let array = dictionary[key] as? [Any], let points = points(array), points.count > 1 { return points }
                }
            }
            if let array = item as? [Any], let points = points(array), points.count > 1 { return points }
            return nil
        }
    }

    private static func points(_ values: [Any]) -> [CGPoint]? {
        let output = values.compactMap(point)
        return output.count == values.count ? output : nil
    }

    private static func point(_ value: Any) -> CGPoint? {
        if let dictionary = value as? [String: Any], let x = number(dictionary["x"]), let y = number(dictionary["y"]) {
            return CGPoint(x: x, y: y)
        }
        if let values = value as? [Any], values.count >= 2, let x = number(values[0]), let y = number(values[1]) {
            return CGPoint(x: x, y: y)
        }
        if let text = value as? String {
            let numbers = text.split { !"-+.0123456789eE".contains($0) }.compactMap { Double($0) }
            if numbers.count >= 2 { return CGPoint(x: numbers[0], y: numbers[1]) }
        }
        return nil
    }
    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) }

    private static func render(_ strokes: [[CGPoint]]) -> String {
        let points = strokes.flatMap { $0 }
        let minX = points.map(\.x).min() ?? 0, minY = points.map(\.y).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1, maxY = points.map(\.y).max() ?? 1
        let width = max(1, maxX - minX), height = max(1, maxY - minY)
        let paths = strokes.map { stroke in
            let commands = stroke.enumerated().map { index, point in
                "\(index == 0 ? "M" : "L")\(format(point.x)) \(format(point.y))"
            }.joined(separator: " ")
            return "<path d=\"\(commands)\" fill=\"none\" stroke=\"currentColor\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        }.joined()
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(format(minX)) \(format(minY)) \(format(width)) \(format(height))\">\(paths)</svg>"
    }
    private static func format(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }
}
