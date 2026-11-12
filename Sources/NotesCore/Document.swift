import Foundation

/// A decoded Notes body: the plain string plus attribute runs, as Notes stores it.
/// Offsets and lengths count UTF-16 code units, matching Notes' own storage.
public struct NoteDocument: Codable, Sendable, Equatable {
    public var text: String
    public var tables: [String: [[String]]]?
    public var tableCells: [String: [[TableCellDocument]]]?
    public var collapsedParagraphIDs: [String]?
    public var runs: [AttributeRun]
    public init(text: String, runs: [AttributeRun], collapsedParagraphIDs: [String]? = nil) {
        self.text = text; self.runs = runs; self.collapsedParagraphIDs = collapsedParagraphIDs
    }

    public mutating func applyCollapsedParagraphIDs(_ ids: [String]) {
        collapsedParagraphIDs = ids
        let collapsed = Set(ids.map { $0.uppercased() })
        for index in runs.indices {
            guard let paragraph = runs[index].paragraph,
                  paragraph.kind == .heading || paragraph.kind == .subheading,
                  let id = paragraph.id else { continue }
            runs[index].paragraph?.collapsed = collapsed.contains(id.uppercased())
        }
    }
}

public struct TableCellDocument: Codable, Sendable, Equatable {
    public var text: String
    public var runs: [AttributeRun]
    public init(text: String, runs: [AttributeRun]) { self.text = text; self.runs = runs }
    public var document: NoteDocument { NoteDocument(text: text, runs: runs) }
}

public enum HighlightColor: String, Codable, Sendable, Equatable, CaseIterable {
    case purple, pink, orange, mint, blue

    public init?(notesValue: Int) {
        guard (1...5).contains(notesValue) else { return nil }
        self = Self.allCases[notesValue - 1]
    }

    public var notesValue: Int { Self.allCases.firstIndex(of: self)! + 1 }
}

public struct AttributeRun: Codable, Sendable, Equatable {
    public var length: Int
    public var paragraph: ParagraphStyle?
    public var font: FontStyle
    public var link: String?
    public var color: String?          // "#RRGGBB"
    public var highlight: HighlightColor?
    public var attachment: InlineRef?
    public init(length: Int, paragraph: ParagraphStyle? = nil, font: FontStyle = FontStyle(),
                link: String? = nil, color: String? = nil, highlight: HighlightColor? = nil, attachment: InlineRef? = nil) {
        self.length = length; self.paragraph = paragraph; self.font = font
        self.link = link; self.color = color; self.highlight = highlight; self.attachment = attachment
    }
}

public struct ParagraphStyle: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case body, title, heading, subheading, monospaced, bulleted, dashed, numbered, checklist, blockquote
    }
    public var kind: Kind
    public var alignment: Int?
    public var writingDirection: Int?  // 0 left-to-right, 1 right-to-left
    public var blockQuoteLevel: Int?
    public var indent: Int
    public var checked: Bool?         // checklist items only
    public var checklistID: String?   // stable item id from Notes
    public var startNumber: Int?      // numbered lists
    public var id: String?             // paragraph UUID
    public var collapsed: Bool?        // headings and subheadings
    public init(kind: Kind, indent: Int = 0, checked: Bool? = nil, checklistID: String? = nil, startNumber: Int? = nil) {
        self.kind = kind; self.indent = indent; self.checked = checked; self.checklistID = checklistID; self.startNumber = startNumber
    }
}

public struct FontStyle: Codable, Sendable, Equatable {
    public var name: String?
    public var pointSize: Float?
    public var bold = false, italic = false, underline = false, strikethrough = false
    public var superscript = 0          // >0 superscript, <0 subscript
    public init(bold: Bool = false, italic: Bool = false, underline: Bool = false, strikethrough: Bool = false, superscript: Int = 0) {
        self.bold = bold; self.italic = italic; self.underline = underline; self.strikethrough = strikethrough; self.superscript = superscript
    }
}

/// Points from a run (the U+FFFC character) to an attachment, hashtag, mention, or note link.
public struct InlineRef: Codable, Sendable, Equatable {
    public var id: String
    public var typeUTI: String
    public var displayText: String?
    public var url: String?
    public init(id: String, typeUTI: String) { self.id = id; self.typeUTI = typeUTI }
}

public struct NoteOutlineNode: Codable, Sendable, Equatable {
    public var title: String
    public var level: Int
    public var offset: Int
    public var length: Int
    public var children: [NoteOutlineNode]
    public init(title: String, level: Int, offset: Int, length: Int, children: [NoteOutlineNode] = []) {
        self.title = title; self.level = level; self.offset = offset; self.length = length; self.children = children
    }
}

public extension NoteDocument {
    func outline() -> [NoteOutlineNode] {
        let source = text as NSString
        var headings: [NoteOutlineNode] = []
        var offset = 0
        for run in runs {
            let length = min(max(0, run.length), max(0, source.length - offset))
            defer { offset += length }
            guard let kind = run.paragraph?.kind, [.title, .heading, .subheading].contains(kind), length > 0 else { continue }
            let range = NSRange(location: offset, length: length)
            let raw = source.substring(with: range)
            let title = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let level = kind == .title ? 1 : kind == .heading ? 2 : 3
            headings.append(NoteOutlineNode(title: title, level: level, offset: offset, length: title.utf16.count))
        }
        var roots: [NoteOutlineNode] = []
        func append(_ node: NoteOutlineNode, to nodes: inout [NoteOutlineNode]) {
            guard let last = nodes.indices.last, nodes[last].level < node.level else { nodes.append(node); return }
            append(node, to: &nodes[last].children)
        }
        for heading in headings { append(heading, to: &roots) }
        return roots
    }
}
