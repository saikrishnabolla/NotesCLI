import Foundation
import NotesCore

public enum SnapshotRestorePolicy {
    public static func nativeRequiredFeatures(_ note: Note) -> [String] {
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

    public static func requireScriptingRestoreAllowed(_ note: Note, allowDowngrade: Bool) throws {
        let features = nativeRequiredFeatures(note)
        guard allowDowngrade || features.isEmpty else {
            throw NotesError(
                "native_required",
                "This snapshot contains native-only features: \(features.joined(separator: ", ")).",
                hint: "Pass --engine native for a lossless restore, or --allow-downgrade to permit conversion."
            )
        }
    }

    private static func collect(_ runs: [AttributeRun], into features: inout Set<String>) {
        for run in runs {
            if let paragraph = run.paragraph {
                if paragraph.kind == .checklist { features.insert("checklists") }
                if paragraph.kind == .dashed { features.insert("dashed lists") }
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
        case "note-link": features.insert("links")
        case "divider": features.insert("dividers")
        case "math": features.insert("math objects")
        case "link": features.insert("link previews")
        case .some: features.insert("attachments")
        case nil:
            if value.contains("table") { features.insert("tables") }
            else if value.contains("hashtag") { features.insert("tags") }
            else if value.contains("mention") { features.insert("mentions") }
            else if value.contains("divider") { features.insert("dividers") }
            else if value.contains("math") || value.contains("calculate") || value.contains("graph") { features.insert("math objects") }
            else if value.contains("link") { features.insert("links") }
            else { features.insert("attachments") }
        }
    }
}
