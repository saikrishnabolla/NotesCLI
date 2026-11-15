import Foundation
import NotesCore

public struct NotesHTML: Equatable, Sendable {
    public var html: String
    public var localImagePaths: [String]
    public var downgraded: [String]
}

/// CommonMark and GFM rendered as safe HTML for Notes.app scripting.
public enum MarkdownToNotesHTML {
    public static func convert(_ markdown: String) -> NotesHTML {
        let document = NotesMarkdownDocument(parsing: markdown)
        let paths = document.localResources.compactMap { resource -> String? in
            if let url = URL(string: resource.source), url.isFileURL { return url.path }
            guard URLComponents(string: resource.source)?.scheme == nil else { return nil }
            return (resource.source as NSString).expandingTildeInPath
        }
        var downgraded: Set<String> = []
        if !document.resources.isEmpty { downgraded.insert("image") }
        if document.paragraphs.contains(where: { $0.kind == .checklist }) { downgraded.insert("checklist") }
        if document.paragraphs.contains(where: { $0.kind == .table }) { downgraded.insert("table") }
        if document.paragraphs.contains(where: { $0.kind == .divider }) { downgraded.insert("divider") }
        return NotesHTML(html: document.html, localImagePaths: paths, downgraded: downgraded.sorted())
    }

    public static func plainText(_ markdown: String) -> String { plainText(html: convert(markdown).html) }

    static func exactPlainText(html: String) -> String {
        var value = html.replacingOccurrences(
            of: "(</?\\s*(?:div|p|h[1-6]|ul|ol|li|pre|blockquote|table|thead|tbody|tr|td|th)\\b[^>]*>)\\s*\\r?\\n\\s*",
            with: "$1", options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(
            of: "<\\s*br\\s*/?>\\s*(</\\s*(?:div|p|h[1-6]|li|pre|blockquote|td|th)\\s*>)",
            with: "$1", options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(of: "<\\s*br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: "<\\s*/\\s*(?:td|th)\\s*>", with: "\t", options: [.regularExpression, .caseInsensitive])
        for tag in ["div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "pre", "blockquote", "tr"] {
            value = value.replacingOccurrences(of: "<\\s*/\\s*\(tag)\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(value).replacingOccurrences(of: "\r\n", with: "\n")
    }

    public static func plainText(html: String) -> String {
        var value = html
        value = value.replacingOccurrences(of: "<\\s*/\\s*(?:td|th)\\s*>", with: "\t", options: [.regularExpression, .caseInsensitive])
        for tag in ["br", "/div", "/p", "/h1", "/h2", "/h3", "/h4", "/h5", "/h6", "/li", "/pre", "/blockquote", "/tr"] {
            value = value.replacingOccurrences(of: "<\\s*\(tag)\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(value).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func decodeEntities(_ value: String) -> String {
        var value = value
        for (entity, character) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"] {
            value = value.replacingOccurrences(of: entity, with: character)
        }
        return value
    }
}
