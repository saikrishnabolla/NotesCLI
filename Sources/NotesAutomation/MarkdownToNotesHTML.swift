import Foundation

public struct NotesHTML: Equatable, Sendable {
    public var html: String
    public var localImagePaths: [String]
    public var downgraded: [String]
}

/// A conservative Markdown subset: raw HTML is escaped except paired <u> underline markers.
/// Underline also accepts ++text++; checkboxes are Unicode bullets, not Notes checklists.
public enum MarkdownToNotesHTML {
    public static func convert(_ markdown: String) -> NotesHTML {
        var parser = Parser()
        let html = parser.blocks(markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        return NotesHTML(html: html, localImagePaths: parser.images, downgraded: parser.downgrades.sorted())
    }

    public static func plainText(_ markdown: String) -> String { plainText(html: convert(markdown).html) }

    static func exactPlainText(html: String) -> String {
        var value = html.replacingOccurrences(
            of: "(</?\\s*(?:div|p|h[1-3]|ul|ol|li|pre|blockquote)\\b[^>]*>)\\s*\\r?\\n\\s*",
            with: "$1", options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(
            of: "<\\s*br\\s*/?>\\s*(</\\s*(?:div|p|h[1-3]|li|pre|blockquote)\\s*>)",
            with: "$1", options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(of: "<\\s*br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        for tag in ["div", "p", "h1", "h2", "h3", "li", "pre", "blockquote"] {
            value = value.replacingOccurrences(of: "<\\s*/\\s*\(tag)\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"]
        for (entity, character) in entities { value = value.replacingOccurrences(of: entity, with: character) }
        return value.replacingOccurrences(of: "\r\n", with: "\n")
    }

    public static func plainText(html: String) -> String {
        var value = html
        for tag in ["br", "/div", "/p", "/h1", "/h2", "/h3", "/li", "/pre", "/blockquote"] {
            value = value.replacingOccurrences(of: "<\\s*\(tag)\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"]
        for (entity, character) in entities { value = value.replacingOccurrences(of: entity, with: character) }
        return value.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private struct ListItem {
        var indent: Int
        var number: Int?
        var text: String
    }

    private struct Parser {
        var images: [String] = []
        var downgrades: Set<String> = []

        func listItem(_ line: String) -> ListItem? {
            let expanded = line.replacingOccurrences(of: "\t", with: "    ")
            let indent = expanded.prefix(while: { $0 == " " }).count
            let text = String(expanded.dropFirst(indent))
            if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") {
                return ListItem(indent: indent, text: String(text.dropFirst(2)))
            }
            let digits = text.prefix(while: { $0.isASCII && $0.isNumber })
            let remainder = text.dropFirst(digits.count)
            if !digits.isEmpty, remainder.hasPrefix(". ") || remainder.hasPrefix(") ") {
                return ListItem(indent: indent, number: Int(digits) ?? 1, text: String(remainder.dropFirst(2)))
            }
            return nil
        }

        mutating func blocks(_ lines: [String], depth: Int = 0) -> String {
            guard depth < 64 else { return "<div>" + MarkdownToNotesHTML.escape(lines.joined(separator: "\n")) + "</div>" }
            var result = ""
            var i = 0
            while i < lines.count {
                let line = lines[i]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { i += 1; continue }
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    let marker = String(trimmed.prefix(3))
                    i += 1
                    var code: [String] = []
                    while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                        code.append(lines[i]); i += 1
                    }
                    if i < lines.count { i += 1 }
                    result += "<pre>" + MarkdownToNotesHTML.escape(code.joined(separator: "\n")) + "</pre>"
                } else if let item = listItem(line) {
                    result += list(lines, index: &i, indent: item.indent, depth: depth)
                } else if trimmed.hasPrefix(">") {
                    var quoted: [String] = []
                    while i < lines.count {
                        let value = lines[i].trimmingCharacters(in: .whitespaces)
                        guard value.hasPrefix(">") else { break }
                        let rest = value.dropFirst()
                        quoted.append(String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)); i += 1
                    }
                    result += "<blockquote>" + blocks(quoted, depth: depth + 1) + "</blockquote>"
                } else {
                    let hashes = trimmed.prefix(while: { $0 == "#" }).count
                    if (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") {
                        let level = min(hashes, 3)
                        result += "<h\(level)>" + inline(String(trimmed.dropFirst(hashes + 1))) + "</h\(level)>"
                        i += 1
                    } else {
                        var paragraph = [inline(line)]
                        i += 1
                        while i < lines.count {
                            let next = lines[i].trimmingCharacters(in: .whitespaces)
                            if next.isEmpty || listItem(lines[i]) != nil || next.hasPrefix(">") || next.hasPrefix("#") || next.hasPrefix("```") || next.hasPrefix("~~~") { break }
                            paragraph.append(inline(lines[i])); i += 1
                        }
                        result += "<div>" + paragraph.joined(separator: "<br>") + "</div>"
                    }
                }
            }
            return result
        }

        mutating func list(_ lines: [String], index: inout Int, indent: Int, depth: Int) -> String {
            guard depth < 64, let first = listItem(lines[index]) else {
                let text = MarkdownToNotesHTML.escape(lines[index]); index += 1; return "<div>\(text)</div>"
            }
            let ordered = first.number != nil
            let tag = ordered ? "ol" : "ul"
            let start = first.number.map { $0 == 1 ? "" : " start=\"\($0)\"" } ?? ""
            var result = "<\(tag)\(start)>"
            while index < lines.count, let item = listItem(lines[index]), item.indent == indent, (item.number != nil) == ordered {
                var text = item.text
                if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                    downgrades.insert("checklist")
                    text = (text.hasPrefix("[ ]") ? "☐ " : "☑ ") + text.dropFirst(4)
                }
                result += "<li>" + inline(text)
                index += 1
                while index < lines.count, let child = listItem(lines[index]), child.indent > indent {
                    result += list(lines, index: &index, indent: child.indent, depth: depth + 1)
                }
                result += "</li>"
            }
            return result + "</\(tag)>"
        }

        mutating func inline(_ text: String, depth: Int = 0) -> String {
            guard depth < 32 else { return MarkdownToNotesHTML.escape(text) }
            var output = ""
            var cursor = text.startIndex
            while cursor < text.endIndex {
                let tail = text[cursor...]
                if tail.hasPrefix("\\"), text.index(after: cursor) < text.endIndex {
                    cursor = text.index(after: cursor)
                    output += MarkdownToNotesHTML.escape(String(text[cursor])); cursor = text.index(after: cursor); continue
                }
                if tail.hasPrefix("`") {
                    let count = tail.prefix(while: { $0 == "`" }).count
                    let marker = String(repeating: "`", count: count)
                    let begin = text.index(cursor, offsetBy: count)
                    if let end = text.range(of: marker, range: begin..<text.endIndex) {
                        output += "<tt>" + MarkdownToNotesHTML.escape(String(text[begin..<end.lowerBound])) + "</tt>"
                        cursor = end.upperBound; continue
                    }
                }
                let isImage = tail.hasPrefix("![")
                if isImage || tail.hasPrefix("[") {
                    let begin = text.index(cursor, offsetBy: isImage ? 2 : 1)
                    if let close = text.range(of: "](", range: begin..<text.endIndex),
                       let destination = destination(text, from: close.upperBound) {
                        let label = String(text[begin..<close.lowerBound])
                        let url = destination.value
                        if isImage {
                            if let local = localPath(url) { images.append(local) }
                            else { downgrades.insert("image") }
                            output += MarkdownToNotesHTML.escape("[image: \(label)]")
                        } else if safeLink(url) {
                            output += "<a href=\"" + MarkdownToNotesHTML.escape(url) + "\">" + inline(label, depth: depth + 1) + "</a>"
                        } else {
                            output += MarkdownToNotesHTML.escape(label)
                        }
                        cursor = destination.end; continue
                    }
                }
                var matched = false
                for (open, close, tag) in [("***", "***", "b><i"), ("___", "___", "b><i"), ("**", "**", "b"), ("__", "__", "b"), ("~~", "~~", "strike"), ("++", "++", "u"), ("<u>", "</u>", "u"), ("*", "*", "i"), ("_", "_", "i")] {
                    guard tail.hasPrefix(open) else { continue }
                    if open == "_" || open == "__" {
                        if cursor > text.startIndex && text[text.index(before: cursor)].isLetter { continue }
                    }
                    let begin = text.index(cursor, offsetBy: open.count)
                    if let end = closingMarker(close, in: text, from: begin), end.lowerBound > begin {
                        let closingTag = tag == "b><i" ? "i></b" : tag
                        output += "<\(tag)>" + inline(String(text[begin..<end.lowerBound]), depth: depth + 1) + "</\(closingTag)>"
                        cursor = end.upperBound; matched = true; break
                    }
                }
                if matched { continue }
                output += MarkdownToNotesHTML.escape(String(text[cursor])); cursor = text.index(after: cursor)
            }
            return output
        }

        func closingMarker(_ marker: String, in text: String, from start: String.Index) -> Range<String.Index>? {
            guard marker.first == "*" || marker.first == "_" else {
                return text.range(of: marker, range: start..<text.endIndex)
            }
            var cursor = start
            while let match = text.range(of: marker, range: cursor..<text.endIndex) {
                let run = text[match.lowerBound...].prefix(while: { $0 == marker.first! })
                let end = text.index(match.lowerBound, offsetBy: run.count)
                if marker.count == 1 && run.count % 2 == 0 {
                    cursor = end
                    continue
                }
                return text.index(end, offsetBy: -marker.count)..<end
            }
            return nil
        }

        func destination(_ text: String, from start: String.Index) -> (value: String, end: String.Index)? {
            var cursor = start
            var nesting = 0
            while cursor < text.endIndex {
                if text[cursor] == "(" { nesting += 1 }
                if text[cursor] == ")" {
                    if nesting == 0 {
                        var value = String(text[start..<cursor]).trimmingCharacters(in: .whitespaces)
                        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
                        return (value, text.index(after: cursor))
                    }
                    nesting -= 1
                }
                cursor = text.index(after: cursor)
            }
            return nil
        }

        func safeLink(_ value: String) -> Bool {
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
            guard let scheme = URL(string: value)?.scheme?.lowercased() else { return !value.hasPrefix("//") }
            return ["http", "https", "mailto", "tel", "notes"].contains(scheme)
        }

        func localPath(_ value: String) -> String? {
            guard !value.isEmpty else { return nil }
            if let url = URL(string: value), let scheme = url.scheme {
                guard scheme.lowercased() == "file", url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
                return url.path
            }
            guard !value.hasPrefix("//") else { return nil }
            return (value as NSString).expandingTildeInPath
        }
    }
}
