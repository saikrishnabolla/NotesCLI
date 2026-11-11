import Foundation
import NotesCore

public enum NotePresentation {
    public static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: json(value), options: [.fragmentsAllowed]) }
    public static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    public static func render(_ note: Note, format: String, attachments: Bool = true) throws -> String {
        if format == "json" {
            var n = note
            if !attachments {
                n.attachments = []
                if var document = n.document {
                    document.runs = document.runs.map { run in
                        var run = run; run.attachment = nil; return run
                    }
                    n.document = document
                }
            }
            return String(decoding: try json(n), as: UTF8.self)
        }
        guard ["markdown", "text", "html"].contains(format) else { throw NotesError("invalid_format", "Use markdown, text, html, or json.") }
        guard let doc = note.document else { return format == "html" ? "<p>[Locked note]</p>" : "[Locked note]" }
        let ns = doc.text as NSString
        var offset = 0, body = ""
        for run in doc.runs {
            let length = min(max(0, run.length), ns.length - offset)
            var part = ns.substring(with: NSRange(location: offset, length: length)); offset += length
            if run.attachment != nil && !attachments { part = part.replacingOccurrences(of: "\u{fffc}", with: "") }
            if format == "html" {
                part = escapeHTML(part)
                if run.font.bold { part = "<strong>\(part)</strong>" }
                if run.font.italic { part = "<em>\(part)</em>" }
                if run.font.strikethrough { part = "<del>\(part)</del>" }
                if run.font.underline { part = "<u>\(part)</u>" }
                if let link = run.link { part = "<a href=\"\(escapeHTML(link))\">\(part)</a>" }
            } else if format == "markdown" {
                let trailingNewlines = String(part.reversed().prefix { $0 == "\n" || $0 == "\r" }.reversed())
                part.removeLast(trailingNewlines.count)
                if run.font.bold { part = "**\(part)**" }
                if run.font.italic { part = "*\(part)*" }
                if run.font.strikethrough { part = "~~\(part)~~" }
                if let link = run.link { part = "[\(part)](\(link))" }
                if let p = run.paragraph {
                    let prefix: String
                    switch p.kind {
                    case .title: prefix = "# "
                    case .heading: prefix = "## "
                    case .subheading: prefix = "### "
                    case .bulleted, .dashed: prefix = "- "
                    case .numbered: prefix = "\(p.startNumber ?? 1). "
                    case .checklist: prefix = p.checked == true ? "- [x] " : "- [ ] "
                    case .blockquote: prefix = "> "
                    default: prefix = ""
                    }
                    if body.isEmpty || body.hasSuffix("\n") { part = String(repeating: "  ", count: max(0, p.indent)) + prefix + part }
                }
                part += trailingNewlines
            }
            body += part
        }
        if offset < ns.length {
            let rest = ns.substring(from: offset); body += format == "html" ? escapeHTML(rest) : rest
        }
        if !attachments { body = body.replacingOccurrences(of: "\u{fffc}", with: "") }
        if format == "html" { body = "<div>" + body.replacingOccurrences(of: "\n", with: "<br>\n") + "</div>" }
        if attachments {
            for a in note.attachments {
                let label = a.filename ?? a.title ?? a.id
                let location = a.filePath.map { path in
                    if path.hasPrefix("/") { return URL(fileURLWithPath: path).absoluteString }
                    var allowed = CharacterSet.urlPathAllowed
                    allowed.remove(charactersIn: "%?#<>")
                    return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
                } ?? a.url
                if format == "html" { body += "\n<p>" + (location.map { "<a href=\"\(escapeHTML($0))\">\(escapeHTML(label))</a>" } ?? escapeHTML(label + " [not downloaded]")) + "</p>" }
                else if format == "markdown" { body += "\n" + (location.map { "[\(label)](<\($0)>)" } ?? "[\(label): not downloaded]") }
                else { body += "\n\(label): \(location ?? "not downloaded")" }
            }
        }
        return body
    }

    public static func date(_ input: String, now: Date = Date(), calendar: Calendar = .current) throws -> Date {
        if input == "today" { return calendar.startOfDay(for: now) }
        if input == "yesterday", let d = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) { return d }
        if input.hasSuffix("d"), let days = Int(input.dropLast()), days >= 0,
           let d = calendar.date(byAdding: .day, value: -days, to: now) { return d }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: input) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: input) { return d }
        let simple = DateFormatter(); simple.locale = Locale(identifier: "en_US_POSIX"); simple.dateFormat = "yyyy-MM-dd"; simple.isLenient = false
        if let d = simple.date(from: input), simple.string(from: d) == input { return d }
        throw NotesError("invalid_date", "Invalid date: \(input). Use ISO 8601, today, yesterday, or 7d.")
    }
}
