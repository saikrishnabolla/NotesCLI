import Foundation
import NotesCore

public struct WebClip: Sendable, Equatable {
    public var title: String
    public var markdown: String
    public init(title: String, markdown: String) { self.title = title; self.markdown = markdown }
}

public enum WebPageClipper {
    public static func fetch(_ source: URL, timeout: TimeInterval = 20, maximumBytes: Int = 10 * 1024 * 1024) throws -> WebClip {
        guard ["http", "https"].contains(source.scheme?.lowercased() ?? "") else { throw NotesError("invalid_url", "Clip accepts only HTTP and HTTPS URLs.") }
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("notescli/1.0", forHTTPHeaderField: "User-Agent")
        let box = FetchBox(), finished = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.set(data: data, response: response, error: error); finished.signal()
        }
        task.resume()
        if finished.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel(); throw NotesError("clip_timeout", "The web page fetch timed out.")
        }
        let value = box.get()
        if let error = value.error { throw NotesError("clip_fetch_failed", error.localizedDescription) }
        if let response = value.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw NotesError("clip_fetch_failed", "The web server returned HTTP \(response.statusCode).")
        }
        guard let data = value.data, data.count <= maximumBytes else { throw NotesError("clip_too_large", "The web page exceeded the \(maximumBytes)-byte limit.") }
        guard let html = String(data: data, encoding: .utf8) else { throw NotesError("invalid_encoding", "The page is not UTF-8.") }
        return extract(html, source: source)
    }

    public static func extract(_ html: String, source: URL) -> WebClip {
        func first(_ pattern: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
        let title = first(#"<title\b[^>]*>(.*?)</title>"#).map(MarkdownToNotesHTML.plainText(html:))?.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = first(#"<article\b[^>]*>(.*?)</article>"#) ?? first(#"<main\b[^>]*>(.*?)</main>"#) ?? first(#"<body\b[^>]*>(.*?)</body>"#) ?? html
        body = body.replacingOccurrences(of: #"<(script|style|nav|header|footer)\b[^>]*>.*?</\1>"#, with: "", options: [.regularExpression, .caseInsensitive])
        for level in 1...3 {
            body = body.replacingOccurrences(of: "<h\(level)\\b[^>]*>(.*?)</h\(level)>", with: String(repeating: "#", count: level) + " $1\n\n", options: [.regularExpression, .caseInsensitive])
        }
        body = body.replacingOccurrences(of: #"<a\b[^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#, with: "[$2]($1)", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"<(p|div|li|blockquote)\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"</(p|div|li|blockquote)>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        let text = MarkdownToNotesHTML.plainText(html: body)
        return WebClip(title: title?.isEmpty == false ? title! : (source.host ?? "Web clip"), markdown: "Source: \(source.absoluteString)\n\n" + text)
    }
}

private final class FetchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Data?, URLResponse?, Error?) = (nil, nil, nil)
    func set(data: Data?, response: URLResponse?, error: Error?) { lock.withLock { value = (data, response, error) } }
    func get() -> (data: Data?, response: URLResponse?, error: Error?) { lock.withLock { (value.0, value.1, value.2) } }
}
