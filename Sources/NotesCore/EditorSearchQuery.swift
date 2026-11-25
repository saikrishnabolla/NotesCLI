import Foundation

public struct EditorSearchMatch: Codable, Equatable, Sendable {
    public let id: String
    public let excerpt: String?

    public init(id: String, excerpt: String? = nil) {
        self.id = id
        self.excerpt = excerpt
    }
}

public struct EditorSearchQuery: Sendable {
    public let text: String
    private let terms: [String]

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1024, !trimmed.utf8.contains(0) else { return nil }
        self.text = trimmed
        terms = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func identity(_ note: NoteSummary) -> String { note.id.coreDataID ?? note.id.uuid }

    public func matches(_ note: NoteSummary, titleOnly: Bool = false, body: () -> String? = { nil }) -> Bool {
        match(note, titleOnly: titleOnly, body: body) != nil
    }

    public func match(_ note: NoteSummary, titleOnly: Bool = false, body: () -> String? = { nil }) -> EditorSearchMatch? {
        guard !note.isDeleted else { return nil }
        let id = Self.identity(note)
        let metadata = titleOnly ? note.title : ([note.title] + note.folderPath).joined(separator: " ")
        let remaining = terms.filter { !contains($0, in: metadata) }
        if remaining.isEmpty { return .init(id: id) }
        guard !titleOnly, !note.isLocked, let body = body() else { return nil }
        let hits = remaining.compactMap { range(of: $0, in: body) }
        guard hits.count == remaining.count, let first = hits.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        var bodyStart = body.startIndex
        if let titleEnd = body.firstIndex(where: \.isNewline), titleEnd < first.lowerBound,
           body[..<titleEnd] == note.title {
            bodyStart = body.index(after: titleEnd)
        }
        let start = body.index(first.lowerBound, offsetBy: -40, limitedBy: bodyStart) ?? bodyStart
        let end = body.index(first.lowerBound, offsetBy: 120, limitedBy: body.endIndex) ?? body.endIndex
        let context = body[start..<end].split { $0.isWhitespace || $0 == "\u{fffc}" }.joined(separator: " ")
        guard !context.isEmpty, context.utf8.count <= 1024 else { return .init(id: id) }
        return .init(id: id, excerpt: (start == bodyStart ? "" : "…") + context + (end == body.endIndex ? "" : "…"))
    }

    public func highlightRanges(in excerpt: String) -> [Range<String.Index>] {
        Set(terms).flatMap { term -> [Range<String.Index>] in
            var ranges: [Range<String.Index>] = []
            var start = excerpt.startIndex
            while start < excerpt.endIndex, let hit = range(of: term, in: excerpt, limit: start..<excerpt.endIndex) {
                guard !hit.isEmpty else { break }
                ranges.append(hit)
                start = hit.upperBound
            }
            return ranges
        }
    }

    private func contains(_ term: String, in text: String) -> Bool {
        range(of: term, in: text) != nil
    }

    private func range(of term: String, in text: String, limit: Range<String.Index>? = nil) -> Range<String.Index>? {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: limit)
    }
}
