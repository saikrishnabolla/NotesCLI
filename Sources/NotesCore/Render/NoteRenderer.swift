import Foundation

public enum NoteRenderer {
    public static func markdown(_ document: NoteDocument, attachments: [Attachment] = []) -> String {
        render(document, attachments: attachments, format: .markdown)
    }
    public static func plainText(_ document: NoteDocument, attachments: [Attachment] = []) -> String {
        render(document, attachments: attachments, format: .plain)
    }
    public static func html(_ document: NoteDocument, attachments: [Attachment] = []) -> String {
        render(document, attachments: attachments, format: .html)
    }
    private enum Format { case markdown, plain, html }
    private struct Line {
        var text: String
        var style: ParagraphStyle
        var raw: String
    }
    private struct InlinePiece {
        var text: String
        var run: AttributeRun
    }
    private static func render(_ document: NoteDocument, attachments: [Attachment], format: Format) -> String {
        let source = document.text as NSString
        var ranges: [(NSRange, AttributeRun)] = [], offset = 0
        for run in document.runs {
            guard run.length >= 0, run.length <= source.length - offset else { break }
            ranges.append((NSRange(location: offset, length: run.length), run)); offset += run.length
        }
        var attachmentMap: [String: Attachment] = [:]
        for a in attachments { attachmentMap[a.id] = a }
        var lines: [Line] = [], start = 0, runIndex = 0
        let rawLines = document.text.components(separatedBy: "\n")
        for (lineIndex, raw) in rawLines.enumerated() {
            // A terminal newline closes the last paragraph; it is not another empty paragraph.
            if lineIndex == rawLines.count - 1 && raw.isEmpty && lineIndex > 0 { break }
            let length = raw.utf16.count, end = start + length
            while runIndex < ranges.count && NSMaxRange(ranges[runIndex].0) <= start { runIndex += 1 }
            var style: ParagraphStyle?, result = "", cursor = start, i = runIndex, pieces: [InlinePiece] = []
            func flushPieces() {
                guard !pieces.isEmpty else { return }
                result += mergedInline(pieces, document, attachmentMap, format, code: style?.kind == .monospaced)
                pieces.removeAll(keepingCapacity: true)
            }
            while i < ranges.count && ranges[i].0.location <= end {
                let (range, run) = ranges[i]
                if style == nil, NSMaxRange(range) > start { style = run.paragraph }
                let lower = max(start, range.location), upper = min(end, NSMaxRange(range))
                if lower < upper {
                    if cursor < lower {
                        flushPieces()
                        result += escaped(source.substring(with: NSRange(location: cursor, length: lower - cursor)), format)
                    }
                    let segment = source.substring(with: NSRange(location: lower, length: upper - lower))
                    if let last = pieces.last, !canMergeInline(last.run, run) { flushPieces() }
                    pieces.append(InlinePiece(text: segment, run: run))
                    cursor = upper
                }
                i += 1
            }
            flushPieces()
            if cursor < end { result += escaped(source.substring(with: NSRange(location: cursor, length: end - cursor)), format) }
            lines.append(Line(text: result, style: style ?? ParagraphStyle(kind: .body), raw: raw))
            start = end + 1
        }
        if format == .plain { return lines.map(\.text).joined(separator: "\n") + (document.text.hasSuffix("\n") ? "\n" : "") }
        if format == .html { return htmlBlocks(lines) }
        var output: [String] = [], numbers: [Int: Int] = [:], i = 0
        while i < lines.count {
            let line = lines[i], p = line.style
            let indent = String(repeating: "    ", count: min(100, max(0, p.indent)))
            let quote = String(repeating: "> ", count: min(100, max(p.kind == .blockquote ? 1 : 0, p.blockQuoteLevel ?? 0)))
            if p.kind == .monospaced {
                var content: [String] = []
                while i < lines.count && lines[i].style.kind == .monospaced { content.append(lines[i].raw); i += 1 }
                let longest = content.joined(separator: "\n").components(separatedBy: CharacterSet(charactersIn: "`").inverted).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: max(3, longest + 1))
                output += [quote + fence] + content.map { quote + $0 } + [quote + fence]
                continue
            }
            var prefix = ""
            switch p.kind {
            case .title: prefix = "# "
            case .heading: prefix = "## "
            case .subheading: prefix = "### "
            case .bulleted, .dashed: prefix = indent + "- "
            case .checklist: prefix = indent + (p.checked == true ? "- [x] " : "- [ ] ")
            case .numbered:
                let number = p.startNumber ?? numbers[p.indent] ?? 1
                prefix = indent + "\(number). "; numbers[p.indent] = number + 1
                numbers = numbers.filter { $0.key <= p.indent }
            default: break
            }
            if p.kind != .numbered { numbers = numbers.filter { $0.key < p.indent } }
            let text = p.kind == .body || p.kind == .blockquote ? escapeBlockStart(line.text) : line.text
            output.append(quote + prefix + text); i += 1
        }
        return output.joined(separator: "\n") + (document.text.hasSuffix("\n") ? "\n" : "")
    }
    private static func escapeBlockStart(_ text: String) -> String {
        let whitespace = text.prefix(while: { $0 == " " })
        guard whitespace.count < 4 else { return text }
        let content = String(text.dropFirst(whitespace.count))
        if content.hasPrefix("- ") || content.hasPrefix("+ ") { return whitespace + "\\" + content }
        let hashes = content.prefix(while: { $0 == "#" })
        if (1...6).contains(hashes.count), content.dropFirst(hashes.count).first == " " { return whitespace + "\\" + content }
        let digits = content.prefix(while: \.isNumber), rest = content.dropFirst(digits.count)
        if !digits.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") { return whitespace + digits + "\\" + rest }
        return text
    }
    private static func escaped(_ text: String, _ format: Format) -> String {
        switch format {
        case .plain: return text
        case .html: return text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        case .markdown:
            return text.reduce(into: "") { result, character in
                if "\\`*_{}[]<>|".contains(character) { result.append("\\") }; result.append(character)
            }
        }
    }
    private static func destination(_ url: String) -> String {
        url.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "()<>\" \n\r\t"))) ?? ""
    }
    private static func safeURL(_ url: String) -> String {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.rangeOfCharacter(from: .controlCharacters) == nil else { return "" }
        guard let scheme = URLComponents(string: value)?.scheme?.lowercased() else {
            // A malformed scheme must not become an executable browser URL after normalization.
            let firstComponent = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return firstComponent.contains(":") ? "" : value
        }
        return ["http", "https", "mailto", "tel", "applenotes", "notescli-attachment", "file"].contains(scheme) ? value : ""
    }
    private static func canMergeInline(_ left: AttributeRun, _ right: AttributeRun) -> Bool {
        left.attachment == nil && right.attachment == nil && left.font == right.font && left.link == right.link &&
        left.color == right.color && left.paragraph == right.paragraph
    }
    private static func mergedInline(_ pieces: [InlinePiece], _ document: NoteDocument, _ attachments: [String: Attachment],
                                     _ format: Format, code: Bool) -> String {
        guard pieces.count > 1, format != .plain, !code, let run = pieces.first?.run else {
            return pieces.map { inline($0.text, $0.run, document, attachments, format, code: code) }.joined()
        }
        var leading = "", trailing = "", values = pieces
        if format == .markdown {
            leading = String(values[0].text.prefix(while: \.isWhitespace))
            values[0].text.removeFirst(leading.count)
            trailing = String(values[values.count - 1].text.reversed().prefix(while: \.isWhitespace).reversed())
            values[values.count - 1].text.removeLast(trailing.count)
        }
        var result = values.map { piece -> String in
            var value = escaped(piece.text, format)
            if let highlight = piece.run.highlight {
                if format == .markdown {
                    value = "<mark data-apple-notes-highlight=\"\(highlight.rawValue)\">\(value)</mark>"
                } else {
                    let colors: [HighlightColor: String] = [.purple: "#BA55D333", .pink: "#D5000044", .orange: "#FF6F0022", .mint: "#289C8ECC", .blue: "#2196F3"]
                    value = "<mark data-apple-notes-highlight=\"\(highlight.rawValue)\" style=\"background-color:\(colors[highlight]!)\">\(value)</mark>"
                }
            }
            return value
        }.joined()
        let font = run.font
        if format == .markdown {
            if font.bold { result = "**\(result)**" }
            if font.italic { result = "*\(result)*" }
            if font.strikethrough { result = "~~\(result)~~" }
            if font.underline { result = "<u>\(result)</u>" }
            if font.superscript != 0 { result = "<\(font.superscript > 0 ? "sup" : "sub")>\(result)</\(font.superscript > 0 ? "sup" : "sub")>" }
            if let link = run.link { result = "[\(result)](\(destination(safeURL(link))))" }
        } else {
            for (enabled, tag) in [(font.bold, "strong"), (font.italic, "em"), (font.strikethrough, "del"), (font.underline, "u"), (font.superscript > 0, "sup"), (font.superscript < 0, "sub")] where enabled {
                result = "<\(tag)>\(result)</\(tag)>"
            }
            if let color = run.color, color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil { result = "<span style=\"color:\(color)\">\(result)</span>" }
            if let link = run.link { result = "<a href=\"\(escaped(safeURL(link), .html))\">\(result)</a>" }
        }
        return leading + result + trailing
    }
    private static func inline(_ text: String, _ run: AttributeRun, _ document: NoteDocument, _ attachments: [String: Attachment], _ format: Format, code: Bool) -> String {
        var leading = "", trailing = "", content = text
        if format == .markdown && !code {
            leading = String(content.prefix(while: \.isWhitespace))
            content.removeFirst(leading.count)
            trailing = String(content.reversed().prefix(while: \.isWhitespace).reversed())
            content.removeLast(trailing.count)
            if content.isEmpty { return text }
        }
        var result = escaped(content, format)
        if let ref = run.attachment {
            let replacement = attachment(ref, document, attachments[ref.id], format)
            result = result.replacingOccurrences(of: "\u{fffc}", with: replacement)
        }
        if format == .plain || code { return result }
        let font = run.font
        if format == .markdown {
            if font.bold { result = "**\(result)**" }
            if font.italic { result = "*\(result)*" }
            if font.strikethrough { result = "~~\(result)~~" }
            if font.underline { result = "<u>\(result)</u>" }
            if font.superscript != 0 { let tag = font.superscript > 0 ? "sup" : "sub"; result = "<\(tag)>\(result)</\(tag)>" }
            if let highlight = run.highlight { result = "<mark data-apple-notes-highlight=\"\(highlight.rawValue)\">\(result)</mark>" }
            if let link = run.link { result = "[\(result)](\(destination(safeURL(link))))" }
        } else {
            for (enabled, tag) in [(font.bold, "strong"), (font.italic, "em"), (font.strikethrough, "del"), (font.underline, "u"), (font.superscript > 0, "sup"), (font.superscript < 0, "sub")] where enabled { result = "<\(tag)>\(result)</\(tag)>" }
            if let color = run.color, color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil { result = "<span style=\"color:\(color)\">\(result)</span>" }
            if let highlight = run.highlight {
                let colors: [HighlightColor: String] = [.purple: "#BA55D333", .pink: "#D5000044", .orange: "#FF6F0022", .mint: "#289C8ECC", .blue: "#2196F3"]
                result = "<mark data-apple-notes-highlight=\"\(highlight.rawValue)\" style=\"background-color:\(colors[highlight]!)\">\(result)</mark>"
            }
            if let link = run.link { result = "<a href=\"\(escaped(safeURL(link), .html))\">\(result)</a>" }
        }
        return leading + result + trailing
    }
    private static func attachment(_ ref: InlineRef, _ document: NoteDocument, _ a: Attachment?, _ format: Format) -> String {
        if let rows = document.tables?[ref.id], let first = rows.first {
            let richRows = document.tableCells?[ref.id]
            func richCell(_ row: Int, _ column: Int) -> TableCellDocument? {
                guard let richRows, richRows.indices.contains(row), richRows[row].indices.contains(column) else { return nil }
                return richRows[row][column]
            }
            switch format {
            case .plain: return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            case .html:
                return "<table>" + rows.enumerated().map { row, cells in "<tr>" + cells.enumerated().map { column, value in
                    var rendered = richCell(row, column)?.document.html() ?? escaped(value, .html).replacingOccurrences(of: "\n", with: "<br>")
                    if rendered.hasPrefix("<p>"), rendered.hasSuffix("</p>") {
                        rendered = String(rendered.dropFirst(3).dropLast(4)).replacingOccurrences(of: "</p>\n<p>", with: "<br>")
                    }
                    return "<td>\(rendered)</td>"
                }.joined() + "</tr>" }.joined() + "</table>"
            case .markdown:
                func escapePipes(_ value: String) -> String {
                    var result = "", backslashes = 0
                    for character in value {
                        if character == "|", backslashes.isMultiple(of: 2) { result.append("\\") }
                        result.append(character)
                        backslashes = character == "\\" ? backslashes + 1 : 0
                    }
                    return result
                }
                func row(_ index: Int, _ cells: [String]) -> String {
                    "| " + cells.enumerated().map { column, value in
                        escapePipes(richCell(index, column)?.document.markdown() ?? escaped(value, .markdown)).replacingOccurrences(of: "\n", with: "<br>")
                    }.joined(separator: " | ") + " |"
                }
                return ([row(0, first), "| " + first.map { _ in "---" }.joined(separator: " | ") + " |"] + rows.dropFirst().enumerated().map { row($0.offset + 1, $0.element) }).joined(separator: "\n")
            }
        }
        let uti = ref.typeUTI.lowercased()
        if a?.isDivider == true || uti.contains("divider") { return format == .html ? "<hr>" : "---" }
        if let svg = a?.drawingSVG {
            switch format { case .plain: return "SVG drawing"; case .markdown, .html: return svg }
        }
        if uti.contains("hashtag") || uti.contains("mention") {
            let prefix = uti.contains("hashtag") ? "#" : "@"
            let identity = [a?.participantName, a?.participantEmail, a?.participantUserID].compactMap { $0 }.joined(separator: " · ")
            let label = identity.isEmpty ? (ref.displayText ?? a?.title ?? ref.id) : identity
            let display = label.hasPrefix(prefix) ? label : prefix + label
            if format == .markdown { return "[\(escaped(display, .markdown))](notescli-attachment:\(ref.id))" }
            return escaped(display, format)
        }
        let title = ref.displayText ?? a?.title ?? a?.filename ?? "attachment: \(ref.typeUTI)"
        let url = ref.url ?? a?.url ?? a?.filePath ?? "notescli-attachment:\(ref.id)"
        let timing = a?.transcriptWords?.map { word in
            let time = word.start.map { String(format: "%.2fs", $0) }
            return [time.map { "[\($0)]" }, word.speaker.map { "\($0):" }, word.text].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: " ") ?? ""
        let call = a?.recording.map { recording in
            [recording.isCallRecording.map { "call=\($0)" }, recording.callType.map { "type=\($0)" },
             recording.localSpeakerHandle.map { "local=\($0)" }, recording.remoteSpeakerHandle.map { "remote=\($0)" },
             recording.startTime.map { "started=\(ISO8601DateFormatter().string(from: $0))" }].compactMap { $0 }.joined(separator: ", ")
        } ?? ""
        let details: [(String, String)] = [
            ("Transcript", a?.transcriptText ?? ""), ("Recording summary", a?.recording?.summary ?? a?.recording?.topLineSummary ?? ""),
            ("Word timing", timing), ("Call metadata", call), ("PDF text", a?.pdfText ?? ""),
            ("Recognized text", a?.ocrText ?? ""), ("Handwriting", a?.handwritingText ?? ""),
            ("Additional text", a?.additionalIndexableText ?? ""), ("Image labels", a?.imageClassification ?? ""),
            ("Image summary", a?.imageSummary ?? ""), ("Math expression", a?.mathExpression ?? ""),
            ("Math result", a?.mathResult ?? ""), ("Graph expression", a?.graphExpression ?? "")
        ].filter { !$0.1.isEmpty }
        let pages = a?.pageImagePaths ?? []
        if format == .plain {
            return ([title] + pages.enumerated().map { "Page \($0.offset + 1): \($0.element)" } + details.map { "\($0.0): \($0.1)" }).joined(separator: "\n")
        }
        let image = a?.filePath != nil && (uti.contains("image") || ["public.jpeg", "public.png", "public.heic", "com.compuserve.gif", "public.tiff"].contains(uti) || a?.kind == "drawing" || a?.kind == "scan")
        if format == .markdown {
            let base = pages.isEmpty
                ? "\(image ? "!" : "")[\(escaped(title, .markdown))](\(destination(safeURL(url))))"
                : pages.enumerated().map { "![\(escaped(title, .markdown)) page \($0.offset + 1)](\(destination(safeURL($0.element))))" }.joined(separator: "\n")
            return base + details.map { "\n\n**\(escaped($0.0, .markdown)):** \(escaped($0.1, .markdown))" }.joined()
        }
        let base = pages.isEmpty
            ? (image ? "<img src=\"\(escaped(safeURL(url), .html))\" alt=\"\(escaped(title, .html))\">" : "<a href=\"\(escaped(safeURL(url), .html))\">\(escaped(title, .html))</a>")
            : pages.enumerated().map { "<img src=\"\(escaped(safeURL($0.element), .html))\" alt=\"\(escaped(title, .html)) page \($0.offset + 1)\">" }.joined()
        return base + details.map { "<p><strong>\(escaped($0.0, .html)):</strong> \(escaped($0.1, .html))</p>" }.joined()
    }
    private static func htmlBlocks(_ lines: [Line]) -> String {
        func listKind(_ line: Line) -> String? {
            switch line.style.kind { case .numbered: return "ol"; case .bulleted, .dashed, .checklist: return "ul"; default: return nil }
        }
        var i = 0
        func list(_ depth: Int) -> String {
            guard i < lines.count, let kind = listKind(lines[i]) else { return "" }
            let start = kind == "ol" ? " start=\"\(lines[i].style.startNumber ?? 1)\"" : ""
            var result = "<\(kind)\(start)>"
            while i < lines.count && lines[i].style.indent >= depth && listKind(lines[i]) != nil {
                if lines[i].style.indent == depth && listKind(lines[i]) != kind { break }
                let line = lines[i]; i += 1
                let check = line.style.kind == .checklist ? "<input type=\"checkbox\" disabled\(line.style.checked == true ? " checked" : "")> " : ""
                let value = kind == "ol" ? line.style.startNumber.map { " value=\"\($0)\"" } ?? "" : ""
                result += "<li\(value)>" + check + line.text
                while i < lines.count && lines[i].style.indent > depth && listKind(lines[i]) != nil { result += list(lines[i].style.indent) }
                result += "</li>"
            }
            return result + "</\(kind)>"
        }
        var blocks: [String] = []
        while i < lines.count {
            let line = lines[i], p = line.style
            var block: String
            if listKind(line) != nil { block = list(p.indent) }
            else if p.kind == .monospaced {
                var code: [String] = []
                while i < lines.count && lines[i].style.kind == .monospaced { code.append(escaped(lines[i].raw, .html)); i += 1 }
                block = "<pre><code>" + code.joined(separator: "\n") + "</code></pre>"
            } else {
                let tag: String
                switch p.kind { case .title: tag = "h1"; case .heading: tag = "h2"; case .subheading: tag = "h3"; default: tag = "p" }
                let alignment = p.alignment.flatMap { [0: "left", 1: "center", 2: "right", 3: "justify"][$0] }.map { " style=\"text-align:\($0)\"" } ?? ""
                block = line.text.hasPrefix("<table>") ? line.text : "<\(tag)\(alignment)>\(line.text)</\(tag)>"; i += 1
            }
            let quotes = min(100, max(p.kind == .blockquote ? 1 : 0, p.blockQuoteLevel ?? 0))
            for _ in 0..<quotes { block = "<blockquote>" + block + "</blockquote>" }
            blocks.append(block)
        }
        return blocks.joined(separator: "\n")
    }
}

public extension NoteDocument {
    func markdown(attachments: [Attachment] = []) -> String { NoteRenderer.markdown(self, attachments: attachments) }
    func plainText(attachments: [Attachment] = []) -> String { NoteRenderer.plainText(self, attachments: attachments) }
    func html(attachments: [Attachment] = []) -> String { NoteRenderer.html(self, attachments: attachments) }
}
