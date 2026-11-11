import Foundation

/// A decoded Notes body: the plain string plus attribute runs, as Notes stores it.
/// Offsets and lengths count UTF-16 code units, matching Notes' own storage.
public struct NoteDocument: Codable, Sendable, Equatable {
    public var text: String
    public var runs: [AttributeRun]
    public init(text: String, runs: [AttributeRun]) { self.text = text; self.runs = runs }
}

public struct AttributeRun: Codable, Sendable, Equatable {
    public var length: Int
    public var paragraph: ParagraphStyle?
    public var font: FontStyle
    public var link: String?
    public var color: String?          // "#RRGGBB"
    public var attachment: InlineRef?
    public init(length: Int, paragraph: ParagraphStyle? = nil, font: FontStyle = FontStyle(),
                link: String? = nil, color: String? = nil, attachment: InlineRef? = nil) {
        self.length = length; self.paragraph = paragraph; self.font = font
        self.link = link; self.color = color; self.attachment = attachment
    }
}

public struct ParagraphStyle: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case body, title, heading, subheading, monospaced, bulleted, dashed, numbered, checklist, blockquote
    }
    public var kind: Kind
    public var indent: Int
    public var checked: Bool?         // checklist items only
    public var checklistID: String?   // stable item id from Notes
    public var startNumber: Int?      // numbered lists
    public init(kind: Kind, indent: Int = 0, checked: Bool? = nil, checklistID: String? = nil, startNumber: Int? = nil) {
        self.kind = kind; self.indent = indent; self.checked = checked; self.checklistID = checklistID; self.startNumber = startNumber
    }
}

public struct FontStyle: Codable, Sendable, Equatable {
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
    public init(id: String, typeUTI: String) { self.id = id; self.typeUTI = typeUTI }
}
