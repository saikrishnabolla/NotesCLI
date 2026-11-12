import Foundation

public enum DiagramDrawingSource {
    public static func paperCompatibleSVG(_ data: Data) throws -> Data {
        guard var text = String(data: data, encoding: .utf8) else {
            throw DiagramError.renderFailed("Diagram source must be UTF-8.")
        }
        text = try replacing(#"(?is)<defs\b[^>]*>.*?</defs\s*>"#, in: text, with: "")
        text = try replacing(#"(?i)\b(fill|stroke)\s*=\s*([\"'])\s*url\([^)]*\)\s*\2"#,
                             in: text, with: #"$1="none""#)
        return Data(text.utf8)
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) throws -> String {
        let expression = try NSRegularExpression(pattern: pattern)
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                    withTemplate: replacement)
    }
}
