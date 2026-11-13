import Foundation

public enum NativeOnlyFeatures {
    public static func detect(in note: Note) -> [String] {
        var features: Set<String> = []
        if let document = note.document {
            collect(document.runs, text: document.text, noteTitle: note.summary.title, into: &features)
            if let tables = document.tableCells {
                for rows in tables.values {
                    for cells in rows {
                        for cell in cells { collect(cell.runs, text: cell.text, noteTitle: nil, into: &features) }
                    }
                }
            }
            if document.tables?.isEmpty == false { features.insert("tables") }
        }
        for attachment in note.attachments { collect(typeUTI: attachment.typeUTI, kind: attachment.kind, into: &features) }
        return features.sorted()
    }

    private static func collect(_ runs: [AttributeRun], text: String, noteTitle: String?, into features: inout Set<String>) {
        let source = text as NSString
        var offset = 0
        for run in runs {
            let length = min(max(0, run.length), max(0, source.length - offset))
            let runText = length > 0 ? source.substring(with: NSRange(location: offset, length: length)) : ""
            let isDefaultTitleRun = runText.trimmingCharacters(in: .newlines) == noteTitle
            offset += length
            if let paragraph = run.paragraph {
                if paragraph.kind == .checklist { features.insert("checklists") }
                if paragraph.kind == .dashed { features.insert("dashed lists") }
                if paragraph.kind == .blockquote { features.insert("block quotes") }
                if paragraph.startNumber != nil { features.insert("numbered list starts") }
                if paragraph.blockQuoteLevel != nil { features.insert("block quote levels") }
                if paragraph.indent != 0 { features.insert("indentation") }
                if paragraph.alignment != nil { features.insert("alignment") }
                if hasCustomWritingDirection(paragraph.writingDirection) { features.insert("writing direction") }
                if paragraph.collapsed == true { features.insert("collapsible headings") }
            }
            for feature in customFontFeatures(run.font, isDefaultTitleRun: isDefaultTitleRun) { features.insert(feature) }
            if run.font.superscript > 0 { features.insert("superscript") }
            if run.font.superscript < 0 { features.insert("subscript") }
            if run.link != nil { features.insert("links") }
            if run.color != nil { features.insert("text color") }
            if run.highlight != nil { features.insert("highlights") }
            if let attachment = run.attachment { collect(typeUTI: attachment.typeUTI, kind: nil, into: &features) }
        }
    }

    package static func hasCustomWritingDirection(_ direction: Int?) -> Bool {
        direction != nil && direction != 0
    }

    package static func customFontFeatures(_ font: FontStyle, isDefaultTitleRun: Bool) -> [String] {
        let usesNotesSystemFont = font.name == nil || font.name?.hasPrefix(".AppleSystemUIFont") == true
        var features: [String] = []
        if font.name != nil, !usesNotesSystemFont { features.append("font family") }
        if let pointSize = font.pointSize {
            let isNotesStyleSize = usesNotesSystemFont && isDefaultTitleRun && font.bold && !font.italic
                && !font.underline && !font.strikethrough && font.superscript == 0 && abs(24 - pointSize) < 0.01
            if !isNotesStyleSize { features.append("font size") }
        }
        return features
    }

    private static func collect(typeUTI: String, kind: String?, into features: inout Set<String>) {
        let value = typeUTI.lowercased()
        switch kind {
        case "table": features.insert("tables")
        case "hashtag": features.insert("tags")
        case "mention": features.insert("mentions")
        case "note-link": features.insert("links to notes")
        case "divider": features.insert("dividers")
        case "math": features.insert("math objects")
        case "link": features.insert("link previews")
        case .some: features.insert("attachments")
        case nil:
            if value.contains("table") { features.insert("tables") }
            else if value.contains("hashtag") { features.insert("tags") }
            else if value.contains("mention") { features.insert("mentions") }
            else if value.contains("inlinetextattachment.link") { features.insert("links to notes") }
            else if value.contains("divider") { features.insert("dividers") }
            else if value.contains("math") || value.contains("calculate") || value.contains("graph") { features.insert("math objects") }
            else if value.contains("link") { features.insert("links") }
            else { features.insert("attachments") }
        }
    }
}
