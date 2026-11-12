public enum NativeOnlyFeatures {
    public static func detect(in note: Note) -> [String] {
        var features: Set<String> = []
        if let document = note.document {
            collect(document.runs, into: &features)
            if let tables = document.tableCells {
                for rows in tables.values {
                    for cells in rows {
                        for cell in cells { collect(cell.runs, into: &features) }
                    }
                }
            }
            if document.tables?.isEmpty == false { features.insert("tables") }
        }
        for attachment in note.attachments { collect(typeUTI: attachment.typeUTI, kind: attachment.kind, into: &features) }
        return features.sorted()
    }

    private static func collect(_ runs: [AttributeRun], into features: inout Set<String>) {
        for run in runs {
            if let paragraph = run.paragraph {
                if paragraph.kind == .checklist { features.insert("checklists") }
                if paragraph.kind == .dashed { features.insert("dashed lists") }
                if paragraph.kind == .blockquote { features.insert("block quotes") }
                if paragraph.startNumber != nil { features.insert("numbered list starts") }
                if paragraph.blockQuoteLevel != nil { features.insert("block quote levels") }
                if paragraph.indent != 0 { features.insert("indentation") }
                if paragraph.alignment != nil { features.insert("alignment") }
                if paragraph.writingDirection != nil { features.insert("writing direction") }
                if paragraph.collapsed == true { features.insert("collapsible headings") }
            }
            if run.font.name != nil { features.insert("font family") }
            if run.font.pointSize != nil { features.insert("font size") }
            if run.font.superscript > 0 { features.insert("superscript") }
            if run.font.superscript < 0 { features.insert("subscript") }
            if run.link != nil { features.insert("links") }
            if run.color != nil { features.insert("text color") }
            if run.highlight != nil { features.insert("highlights") }
            if let attachment = run.attachment { collect(typeUTI: attachment.typeUTI, kind: nil, into: &features) }
        }
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
