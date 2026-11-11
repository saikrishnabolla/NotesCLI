import Foundation

public struct MarkdownFile: Equatable, Sendable {
    public var noteID: String?
    public var title: String
    public var modified: Date?
    public var body: String

    public init(noteID: String?, title: String, modified: Date?, body: String) {
        self.noteID = noteID
        self.title = title
        self.modified = modified
        self.body = body
    }

    public static func parse(_ text: String, fallbackTitle: String) -> MarkdownFile {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return MarkdownFile(noteID: nil, title: fallbackTitle, modified: nil, body: text)
        }
        let header = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        var values: [String: String] = [:]
        for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            values[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        func scalar(_ key: String) -> String? {
            guard let raw = values[key], !raw.isEmpty, raw != "null" else { return nil }
            if raw.hasPrefix("\"") || raw.hasPrefix("[") {
                return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) as? String
            }
            return raw
        }
        let bodyStart = text.index(end.upperBound, offsetBy: 0)
        return MarkdownFile(noteID: scalar("notes-id"), title: scalar("title") ?? fallbackTitle,
                            modified: scalar("modified").flatMap(ISO8601DateFormatter().date),
                            body: String(text[bodyStart...]))
    }

    public func rendered() -> String {
        let encoder = JSONEncoder()
        func quoted(_ value: String) -> String {
            String(decoding: (try? encoder.encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
        let date = modified.map { ISO8601DateFormatter().string(from: $0) } ?? "null"
        let id = noteID.map(quoted) ?? "null"
        return "---\nnotes-id: \(id)\ntitle: \(quoted(title))\nmodified: \(date)\n---\n" + body
    }
}
