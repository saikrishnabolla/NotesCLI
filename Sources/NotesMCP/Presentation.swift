import Foundation
import NotesCore

public enum NotePresentation {
    private struct Piece {
        var text: String
        var run: AttributeRun
    }

    public static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: json(value), options: [.fragmentsAllowed]) }
    public static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func canMergeInline(_ left: Piece, _ right: Piece) -> Bool {
        !left.text.contains("\n") && !right.text.contains("\n") &&
        left.run.attachment == nil && right.run.attachment == nil &&
        left.run.paragraph == right.run.paragraph && left.run.font == right.run.font &&
        left.run.link == right.run.link && left.run.color == right.run.color
    }
    private static func highlighted(_ pieces: [Piece], html: Bool) -> String {
        var groups: [(HighlightColor?, String)] = []
        for piece in pieces {
            let text = html ? escapeHTML(piece.text) : piece.text
            if let last = groups.indices.last, groups[last].0 == piece.run.highlight { groups[last].1 += text }
            else { groups.append((piece.run.highlight, text)) }
        }
        let colors: [HighlightColor: String] = [.purple: "#BA55D333", .pink: "#D5000044", .orange: "#FF6F0022", .mint: "#289C8ECC", .blue: "#2196F3"]
        return groups.map { highlight, text in
            guard let highlight else { return text }
            if html { return "<mark data-apple-notes-highlight=\"\(highlight.rawValue)\" style=\"background-color:\(colors[highlight]!)\">\(text)</mark>" }
            return "<mark data-apple-notes-highlight=\"\(highlight.rawValue)\">\(text)</mark>"
        }.joined()
    }
    private static func inline(_ pieces: [Piece], html: Bool) -> String {
        guard let run = pieces.first?.run else { return "" }
        var value = highlighted(pieces, html: html)
        if html {
            if run.font.bold { value = "<strong>\(value)</strong>" }
            if run.font.italic { value = "<em>\(value)</em>" }
            if run.font.strikethrough { value = "<del>\(value)</del>" }
            if run.font.underline { value = "<u>\(value)</u>" }
            if let link = run.link { value = "<a href=\"\(escapeHTML(link))\">\(value)</a>" }
        } else {
            if run.font.bold { value = "**\(value)**" }
            if run.font.italic { value = "*\(value)*" }
            if run.font.strikethrough { value = "~~\(value)~~" }
            if let link = run.link { value = "[\(value)](\(link))" }
        }
        return value
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
        let attachmentMap = Dictionary(uniqueKeysWithValues: note.attachments.map { ($0.id, $0) })
        let ns = doc.text as NSString
        var offset = 0, pieces: [Piece] = []
        for run in doc.runs {
            let length = min(max(0, run.length), ns.length - offset)
            var part = ns.substring(with: NSRange(location: offset, length: length)); offset += length
            if run.attachment != nil && !attachments { part = part.replacingOccurrences(of: "\u{fffc}", with: "") }
            if attachments, let ref = run.attachment, ref.typeUTI.lowercased().contains("mention") {
                let attachment = attachmentMap[ref.id]
                let identity = [attachment?.participantName ?? ref.displayText, attachment?.participantEmail, attachment?.participantUserID]
                    .compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ")
                let mention = "@" + (identity.isEmpty ? ref.id : identity)
                part = part.replacingOccurrences(of: "\u{fffc}", with: mention)
            }
            pieces.append(Piece(text: part, run: run))
        }
        var body = "", pieceIndex = 0
        while pieceIndex < pieces.count {
            var group = [pieces[pieceIndex]]
            while pieceIndex + group.count < pieces.count,
                  canMergeInline(group.last!, pieces[pieceIndex + group.count]) {
                group.append(pieces[pieceIndex + group.count])
            }
            pieceIndex += group.count
            let run = group[0].run
            var part = group.map(\.text).joined()
            if format == "html" {
                part = inline(group, html: true)
            } else if format == "markdown" {
                let trailingNewlines = String(part.reversed().prefix { $0 == "\n" || $0 == "\r" }.reversed())
                part.removeLast(trailingNewlines.count)
                var paragraphs = part.components(separatedBy: "\n").map { paragraph in
                    inline([Piece(text: paragraph, run: run)], html: false)
                }
                if group.count > 1 { paragraphs = [inline(group, html: false)] }
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
                    let blockPrefix = String(repeating: "  ", count: max(0, p.indent)) + prefix
                    for index in paragraphs.indices where index > 0 || body.isEmpty || body.hasSuffix("\n") {
                        paragraphs[index] = blockPrefix + paragraphs[index]
                    }
                }
                part = paragraphs.joined(separator: "\n") + trailingNewlines
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

    public static func relativeDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let interval = now.timeIntervalSince(date)
        if interval >= 0, interval < 60 { return "just now" }
        if interval >= 60, interval < 3_600 { return "\(Int(interval / 60))m ago" }
        if interval >= 3_600, interval < 86_400, calendar.isDate(date, inSameDayAs: now) { return "\(Int(interval / 3_600))h ago" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let startOfToday = calendar.startOfDay(for: now)
        if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           date >= startOfYesterday, date < startOfToday { return "yesterday \(formatter.string(from: date))" }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo, date <= now {
            formatter.dateFormat = "EEE HH:mm"
            return formatter.string(from: date).lowercased()
        }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
