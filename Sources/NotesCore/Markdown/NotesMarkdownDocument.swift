import Foundation
import Markdown

public enum NotesMarkdownParagraphKind: String, Sendable, Equatable {
    case title, heading, subheading, body, monospaced, bulleted, numbered, checklist, table, divider
}

public struct NotesMarkdownResource: Sendable, Equatable {
    public enum Presentation: String, Sendable, Equatable { case image, file }

    public var source: String
    public var alt: String
    public var title: String?
    public var presentation: Presentation

    public init(source: String, alt: String, title: String? = nil,
                presentation: Presentation = .image) {
        self.source = source
        self.alt = alt
        self.title = title
        self.presentation = presentation
    }

    public var isLocal: Bool {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        guard let scheme = URLComponents(string: value)?.scheme?.lowercased() else {
            return !value.hasPrefix("#") && !value.hasPrefix("//")
        }
        return scheme == "file"
    }
}

public struct NotesMarkdownRun: Sendable, Equatable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var strikethrough: Bool
    public var underline: Bool
    public var code: Bool
    public var superscript: Int
    public var highlight: String?
    public var link: String?
    public var resource: NotesMarkdownResource?
    public var attachmentID: String?
    public var nativeTag: String?
    public var richLinkURL: String?

    public init(text: String, bold: Bool = false, italic: Bool = false, strikethrough: Bool = false,
                underline: Bool = false, code: Bool = false, superscript: Int = 0, highlight: String? = nil,
                link: String? = nil, resource: NotesMarkdownResource? = nil, attachmentID: String? = nil,
                nativeTag: String? = nil, richLinkURL: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.underline = underline
        self.code = code
        self.superscript = superscript
        self.highlight = highlight
        self.link = link
        self.resource = resource
        self.attachmentID = attachmentID
        self.nativeTag = nativeTag
        self.richLinkURL = richLinkURL
    }
}

public struct NotesMarkdownCell: Sendable, Equatable {
    public enum Alignment: String, Sendable, Equatable { case left, center, right }
    public var runs: [NotesMarkdownRun]
    public var alignment: Alignment?
    public init(runs: [NotesMarkdownRun], alignment: Alignment? = nil) {
        self.runs = runs
        self.alignment = alignment
    }
    public var plainText: String { NotesMarkdownDocument.plainText(runs) }
}

public struct NotesMarkdownParagraph: Sendable, Equatable {
    public var kind: NotesMarkdownParagraphKind
    public var runs: [NotesMarkdownRun]
    public var indent: Int
    public var quoteDepth: Int
    public var checked: Bool?
    public var startNumber: Int?
    public var language: String?
    public var table: [[NotesMarkdownCell]]?

    public init(kind: NotesMarkdownParagraphKind, runs: [NotesMarkdownRun] = [], indent: Int = 0,
                quoteDepth: Int = 0, checked: Bool? = nil, startNumber: Int? = nil,
                language: String? = nil, table: [[NotesMarkdownCell]]? = nil) {
        self.kind = kind
        self.runs = runs
        self.indent = indent
        self.quoteDepth = quoteDepth
        self.checked = checked
        self.startNumber = startNumber
        self.language = language
        self.table = table
    }

    public var plainText: String {
        if let table { return table.map { $0.map(\.plainText).joined(separator: "\t") }.joined(separator: "\n") }
        return NotesMarkdownDocument.plainText(runs)
    }
}

public struct NotesMarkdownDocument: Sendable {
    private let blocks: [Block]
    public let paragraphs: [NotesMarkdownParagraph]
    public let hasLiteralStyledParagraphHTML: Bool

    public init(parsing source: String, diagramResource: ((String, String) -> NotesMarkdownResource?)? = nil) {
        let document = Markdown.Document(parsing: source, options: [.disableSmartOpts])
        var hasLiteralStyledParagraphHTML = false
        let blocks = document.children.flatMap {
            Self.block($0, warning: &hasLiteralStyledParagraphHTML, diagramResource: diagramResource)
        }
        self.blocks = blocks
        self.paragraphs = Self.flatten(blocks)
        self.hasLiteralStyledParagraphHTML = hasLiteralStyledParagraphHTML
    }

    public var resources: [NotesMarkdownResource] {
        var result: [NotesMarkdownResource] = []
        func collect(_ runs: [NotesMarkdownRun]) {
            for run in runs {
                guard let resource = run.resource else { continue }
                result.append(resource)
            }
        }
        for paragraph in paragraphs {
            collect(paragraph.runs)
            for row in paragraph.table ?? [] { for cell in row { collect(cell.runs) } }
        }
        return result
    }

    public var localResources: [NotesMarkdownResource] { resources.filter(\.isLocal) }

    public var requiresNativeWriter: Bool {
        !resources.isEmpty || paragraphs.contains { paragraph in
            paragraph.kind == .table || paragraph.kind == .divider || paragraph.kind == .checklist ||
                paragraph.runs.contains(where: Self.requiresNativeWriter) ||
                (paragraph.table?.flatMap { $0 }.flatMap(\.runs).contains(where: Self.requiresNativeWriter) == true)
        }
    }

    public var html: String { blocks.map(Self.html).joined(separator: "\n") }

    public static func safeLinkDestination(_ value: String) -> String? { safeURL(value) }

    public static func plainText(_ runs: [NotesMarkdownRun]) -> String {
        runs.map { run in
            if let resource = run.resource { return resource.alt.isEmpty ? "image" : resource.alt }
            return run.text
        }.joined()
    }

    static func emptyParagraphMarkdown(indent: Int, quoteDepth: Int) -> String {
        "<!-- notescli-empty-paragraph:\(max(0, indent)):\(max(0, quoteDepth)) -->"
    }

    private static func requiresNativeWriter(_ run: NotesMarkdownRun) -> Bool {
        run.resource != nil || run.attachmentID != nil || run.nativeTag != nil || run.richLinkURL != nil ||
            run.highlight != nil || run.underline || run.superscript != 0
    }
}

private extension NotesMarkdownDocument {
    indirect enum Block: Sendable {
        case paragraph([NotesMarkdownRun])
        case heading(Int, [NotesMarkdownRun])
        case quote([Block])
        case list(ordered: Bool, start: Int, items: [Item])
        case code(language: String?, value: String)
        case table([[NotesMarkdownCell]])
        case divider
        case emptyParagraph(indent: Int?, quoteDepth: Int?)
    }

    struct Item: Sendable {
        var checked: Bool?
        var blocks: [Block]
    }

    struct InlineStyle {
        var bold = false
        var italic = false
        var strikethrough = false
        var underline = false
        var code = false
        var superscript = 0
        var highlight: String?
        var link: String?
    }

    static func block(_ markup: Markup, warning: inout Bool,
                      diagramResource: ((String, String) -> NotesMarkdownResource?)?) -> [Block] {
        if let paragraph = markup as? Paragraph {
            warning = warning || containsStyledParagraphHTML(paragraph)
            return [.paragraph(inlines(paragraph))]
        }
        if let heading = markup as? Heading {
            warning = warning || containsStyledParagraphHTML(heading)
            return [.heading(heading.level, inlines(heading))]
        }
        if let quote = markup as? BlockQuote {
            return [.quote(quote.children.flatMap { block($0, warning: &warning, diagramResource: diagramResource) })]
        }
        if let list = markup as? UnorderedList {
            return [.list(ordered: false, start: 1, items: list.listItems.map {
                item($0, warning: &warning, diagramResource: diagramResource)
            })]
        }
        if let list = markup as? OrderedList {
            return [.list(ordered: true, start: Int(list.startIndex), items: list.listItems.map {
                item($0, warning: &warning, diagramResource: diagramResource)
            })]
        }
        if let code = markup as? CodeBlock {
            if let language = code.language?.lowercased(), ["mermaid", "svg", "diagram"].contains(language),
               let resource = diagramResource?(language, code.code) {
                return [.paragraph([NotesMarkdownRun(text: "", resource: resource)])]
            }
            return [.code(language: code.language, value: code.code)]
        }
        if let table = markup as? Table { return [.table(tableRows(table, warning: &warning))] }
        if markup is ThematicBreak { return [.divider] }
        if let raw = markup as? HTMLBlock {
            let value = raw.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "<!-- notescli-empty-paragraph:", suffix = " -->"
            if value.hasPrefix(prefix), value.hasSuffix(suffix) {
                let fields = value.dropFirst(prefix.count).dropLast(suffix.count).split(separator: ":")
                if fields.count == 2, let indent = Int(fields[0]), let quoteDepth = Int(fields[1]),
                   indent >= 0, quoteDepth >= 0 {
                    return [.emptyParagraph(indent: indent, quoteDepth: quoteDepth)]
                }
            }
            if let opening = value.firstIndex(of: ">"), let closing = value.lastIndex(of: "<"), opening < closing,
               paragraphTag(String(value[...opening])) != nil, isParagraphClose(String(value[closing...])),
               value[value.index(after: opening)..<closing].allSatisfy(\.isWhitespace) {
                return [.emptyParagraph(indent: nil, quoteDepth: nil)]
            }
            warning = warning || beginsStyledParagraph(value)
            return [.paragraph([NotesMarkdownRun(text: raw.rawHTML.trimmingCharacters(in: .newlines))])]
        }
        return markup.children.flatMap { block($0, warning: &warning, diagramResource: diagramResource) }
    }

    static func item(_ value: ListItem, warning: inout Bool,
                     diagramResource: ((String, String) -> NotesMarkdownResource?)?) -> Item {
        let checked: Bool?
        switch value.checkbox { case .checked?: checked = true; case .unchecked?: checked = false; case nil: checked = nil }
        return Item(checked: checked, blocks: value.children.flatMap {
            block($0, warning: &warning, diagramResource: diagramResource)
        })
    }

    static func tableRows(_ table: Table, warning: inout Bool) -> [[NotesMarkdownCell]] {
        func cells(_ markup: Markup) -> [NotesMarkdownCell] {
            markup.children.enumerated().compactMap { column, cell in
                guard let cell = cell as? Table.Cell else { return nil }
                let alignment: NotesMarkdownCell.Alignment?
                switch table.columnAlignments.indices.contains(column) ? table.columnAlignments[column] : nil {
                case .left?: alignment = .left
                case .center?: alignment = .center
                case .right?: alignment = .right
                case nil: alignment = nil
                }
                let children = Array(cell.children)
                if children.count >= 2, let first = children.first as? InlineHTML,
                   let last = children.last as? InlineHTML, isParagraphClose(last.rawHTML),
                   let tag = paragraphTag(first.rawHTML),
                   !children.dropFirst().dropLast().contains(where: containsParagraphHTML) {
                    let runs = tableCellRuns(inlines(children.dropFirst().dropLast()))
                    return NotesMarkdownCell(runs: runs, alignment: runs.isEmpty ? nil : tag.alignment ?? alignment)
                }
                warning = warning || containsStyledParagraphHTML(cell)
                return NotesMarkdownCell(runs: tableCellRuns(inlines(children[...])), alignment: alignment)
            }
        }
        var rows = [cells(table.head)]
        for row in table.body.rows { rows.append(cells(row)) }
        return rows
    }

    // Some exports flatten lists to "• First • Second". Require a leading bullet
    // so dots used as separators in ordinary prose stay as written.
    static let flattenedBulletSpace = try! NSRegularExpression(pattern: #"(?<=\S) (?=• \S)"#)

    static func tableCellRuns(_ runs: [NotesMarkdownRun]) -> [NotesMarkdownRun] {
        func isLiteralText(_ run: NotesMarkdownRun) -> Bool {
            !run.code && run.link == nil && run.resource == nil && run.attachmentID == nil &&
                run.nativeTag == nil && run.richLinkURL == nil
        }
        guard let first = runs.first, isLiteralText(first), first.text.hasPrefix("•") else { return runs }
        // Mask protected runs without shifting UTF-16 offsets or losing boundaries
        // when a separator comes immediately after a link or before styled text.
        let scan = runs.map {
            isLiteralText($0) ? $0.text : String(repeating: "\u{FFFC}", count: max(1, $0.text.utf16.count))
        }
        let text = scan.joined()
        guard text.hasPrefix("• ") else { return runs }
        let breaks = flattenedBulletSpace.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !breaks.isEmpty else { return runs }
        var offset = 0
        var nextBreak = 0
        return zip(runs, scan).map { run, scanned in
            let start = offset
            offset += scanned.utf16.count
            var local: [NSRange] = []
            while nextBreak < breaks.count, breaks[nextBreak].range.location < offset {
                local.append(NSRange(location: breaks[nextBreak].range.location - start, length: 1))
                nextBreak += 1
            }
            guard !local.isEmpty else { return run }
            let updated = NSMutableString(string: run.text)
            for range in local { updated.replaceCharacters(in: range, with: "\n") }
            var result = run
            result.text = updated as String
            return result
        }
    }

    struct ParagraphTag {
        var alignment: NotesMarkdownCell.Alignment?
    }

    static let styledParagraphTag = try! NSRegularExpression(
        pattern: #"^<p\s+style\s*=\s*(?:"([^"]*)"|'([^']*)')\s*>$"#, options: .caseInsensitive
    )

    // Only import the export layout we can represent. Never pass source CSS to Notes.
    static func paragraphTag(_ raw: String) -> ParagraphTag? {
        if raw.range(of: #"^<p\s*>$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return ParagraphTag()
        }
        guard let match = styledParagraphTag.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) ?? Range(match.range(at: 2), in: raw) else { return nil }
        var tag = ParagraphTag()
        var properties: Set<String> = []
        for declaration in raw[range].lowercased().split(separator: ";") {
            let fields = declaration.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if fields == [""] { continue }
            guard fields.count == 2, properties.insert(fields[0]).inserted else { return nil }
            switch (fields[0], fields[1]) {
            case ("text-align", let value):
                guard let alignment = NotesMarkdownCell.Alignment(rawValue: value) else { return nil }
                tag.alignment = alignment
            case ("margin", "0"): break
            default: return nil
            }
        }
        return tag
    }

    static func isParagraphClose(_ raw: String) -> Bool {
        raw.range(of: #"^</p\s*>$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func containsParagraphHTML(_ markup: Markup) -> Bool {
        if let html = markup as? InlineHTML {
            return html.rawHTML.range(of: #"^</?p(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return markup.children.contains(where: containsParagraphHTML)
    }

    static func beginsStyledParagraph(_ raw: String) -> Bool {
        raw.range(of: #"^<p\s+[^>]*\bstyle\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func containsStyledParagraphHTML(_ markup: Markup) -> Bool {
        if let html = markup as? InlineHTML { return beginsStyledParagraph(html.rawHTML) }
        return markup.children.contains(where: containsStyledParagraphHTML)
    }

    static func inlines(_ markup: Markup, style: InlineStyle = InlineStyle()) -> [NotesMarkdownRun] {
        inlines(Array(markup.children)[...], style: style)
    }

    static func inlines(_ children: ArraySlice<Markup>, style: InlineStyle = InlineStyle()) -> [NotesMarkdownRun] {
        var validHTML: [Int: HTMLAction] = [:]
        var openHTML: [(tag: String, index: Int, action: HTMLAction)] = []

        for (index, child) in children.enumerated() {
            guard let html = child as? InlineHTML, let action = htmlAction(html.rawHTML) else { continue }
            switch action {
            case .open(let tag, _):
                openHTML.append((tag, index, action))
            case .close(let tag):
                guard let open = openHTML.last, open.tag == tag else {
                    if let first = openHTML.first?.index {
                        validHTML = validHTML.filter { $0.key < first }
                    }
                    openHTML.removeAll()
                    continue
                }
                openHTML.removeLast()
                validHTML[open.index] = open.action
                validHTML[index] = action
            case .breakLine, .ignore:
                validHTML[index] = action
            }
        }
        if let first = openHTML.first?.index {
            validHTML = validHTML.filter { $0.key < first }
        }

        var current = style
        var stack: [(String, InlineStyle)] = []
        var result: [NotesMarkdownRun] = []
        for (index, child) in children.enumerated() {
            if let html = child as? InlineHTML {
                if let action = validHTML[index] {
                    switch action {
                    case .open(let tag, let apply):
                        stack.append((tag, current)); apply(&current)
                    case .close(let tag):
                        if let open = stack.last, open.0 == tag {
                            current = open.1; stack.removeLast()
                        } else { result.append(run(html.rawHTML, current)) }
                    case .breakLine: result.append(run("\n", current))
                    case .ignore: break
                    }
                } else { result.append(run(html.rawHTML, current)) }
                continue
            }
            result += inline(child, style: current)
        }
        return merged(result)
    }

    static func inline(_ markup: Markup, style: InlineStyle) -> [NotesMarkdownRun] {
        if let text = markup as? Text { return [run(text.string, style)] }
        if markup is SoftBreak { return [run(" ", style)] }
        if markup is LineBreak { return [run("\n", style)] }
        if let code = markup as? InlineCode { var next = style; next.code = true; return [run(code.code, next)] }
        if markup is Strong { var next = style; next.bold = true; return inlines(markup, style: next) }
        if markup is Emphasis { var next = style; next.italic = true; return inlines(markup, style: next) }
        if markup is Strikethrough { var next = style; next.strikethrough = true; return inlines(markup, style: next) }
        if let link = markup as? Link {
            let label = inlines(link, style: style)
            guard let destination = link.destination else { return label }
            if destination.hasPrefix("notescli-tag:") {
                let tag = String(destination.dropFirst("notescli-tag:".count))
                    .removingPercentEncoding ?? String(destination.dropFirst("notescli-tag:".count))
                guard !tag.isEmpty, !tag.contains(where: { $0.isWhitespace || $0 == "#" }) else { return label }
                return [NotesMarkdownRun(text: plainText(label), nativeTag: tag)]
            }
            if destination.hasPrefix("notescli-card:") {
                let encoded = String(destination.dropFirst("notescli-card:".count))
                guard let value = base64URLDecode(encoded), safeURL(value)?.hasPrefix("http") == true else { return label }
                return [NotesMarkdownRun(text: plainText(label), richLinkURL: value)]
            }
            if let id = attachmentID(destination) {
                return [NotesMarkdownRun(text: plainText(label), attachmentID: id)]
            }
            let resource = NotesMarkdownResource(source: destination, alt: plainText(label),
                                                 title: link.title, presentation: .file)
            if resource.isLocal { return [NotesMarkdownRun(text: "", resource: resource)] }
            guard let destination = safeURL(destination) else { return label }
            var next = style; next.link = destination
            return inlines(link, style: next)
        }
        if let image = markup as? Image {
            let alt = plainText(inlines(image, style: style)), source = image.source ?? ""
            if let id = attachmentID(source) { return [NotesMarkdownRun(text: alt, attachmentID: id)] }
            let resource = NotesMarkdownResource(source: source, alt: alt, title: image.title)
            return [NotesMarkdownRun(text: "", resource: resource)]
        }
        if let html = markup as? InlineHTML {
            if html.rawHTML.range(of: #"(?i)^<br\s*/?>$"#, options: .regularExpression) != nil { return [run("\n", style)] }
            return [run(html.rawHTML, style)]
        }
        return inlines(markup, style: style)
    }

    static func run(_ text: String, _ style: InlineStyle) -> NotesMarkdownRun {
        NotesMarkdownRun(text: text, bold: style.bold, italic: style.italic,
                         strikethrough: style.strikethrough, underline: style.underline,
                         code: style.code, superscript: style.superscript,
                         highlight: style.highlight, link: style.link)
    }

    static func merged(_ runs: [NotesMarkdownRun]) -> [NotesMarkdownRun] {
        var result: [NotesMarkdownRun] = []
        for run in runs where !run.text.isEmpty || run.resource != nil || run.attachmentID != nil {
            if var last = result.last, last.resource == nil, run.resource == nil, last.attachmentID == nil,
               run.attachmentID == nil, last.nativeTag == nil, run.nativeTag == nil,
               last.richLinkURL == nil, run.richLinkURL == nil, last.bold == run.bold, last.italic == run.italic,
               last.strikethrough == run.strikethrough, last.underline == run.underline,
               last.code == run.code, last.superscript == run.superscript,
               last.highlight == run.highlight, last.link == run.link {
                last.text += run.text; result[result.count - 1] = last
            } else { result.append(run) }
        }
        return result
    }

    enum HTMLAction {
        case open(String, (inout InlineStyle) -> Void)
        case close(String)
        case breakLine
        case ignore
    }

    static func htmlAction(_ raw: String) -> HTMLAction? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "<b>": return .open("b", { $0.bold = true })
        case "</b>": return .close("b")
        case "<strong>": return .open("strong", { $0.bold = true })
        case "</strong>": return .close("strong")
        case "<i>": return .open("i", { $0.italic = true })
        case "</i>": return .close("i")
        case "<em>": return .open("em", { $0.italic = true })
        case "</em>": return .close("em")
        case "<u>": return .open("u", { $0.underline = true })
        case "</u>": return .close("u")
        case "<sup>": return .open("sup", { $0.superscript = 1 })
        case "</sup>": return .close("sup")
        case "<sub>": return .open("sub", { $0.superscript = -1 })
        case "</sub>": return .close("sub")
        case "</mark>": return .close("mark")
        case "<br>", "<br/>", "<br />": return .breakLine
        default:
            let emptyParagraph = #"^<!--\s*notescli-empty-paragraph:\d+:\d+\s*-->$"#
            if value.range(of: emptyParagraph, options: .regularExpression) != nil { return .ignore }
            let pattern = #"^<mark\s+data-apple-notes-highlight=[\"'](purple|pink|orange|mint|blue)[\"']\s*>$"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value) else { return nil }
            let color = String(value[range])
            return .open("mark", { $0.highlight = color })
        }
    }

    static func attachmentID(_ destination: String) -> String? {
        let prefix = "notescli-attachment:"
        guard destination.lowercased().hasPrefix(prefix) else { return nil }
        let id = String(destination.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    static func base64URLDecode(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func flatten(_ blocks: [Block], indent: Int = 0, quoteDepth: Int = 0) -> [NotesMarkdownParagraph] {
        var result: [NotesMarkdownParagraph] = []
        for block in blocks {
            switch block {
            case .paragraph(let runs):
                result.append(.init(kind: .body, runs: runs, indent: indent, quoteDepth: quoteDepth))
            case .heading(let level, let runs):
                let kind: NotesMarkdownParagraphKind = level == 1 ? .title : level == 2 ? .heading : .subheading
                result.append(.init(kind: kind, runs: runs, indent: indent, quoteDepth: quoteDepth))
            case .quote(let children):
                result += flatten(children, indent: indent, quoteDepth: quoteDepth + 1)
            case .list(let ordered, let start, let items):
                for (offset, item) in items.enumerated() {
                    var flattened = flatten(item.blocks, indent: indent + 1, quoteDepth: quoteDepth)
                    if flattened.isEmpty { flattened = [.init(kind: .body, indent: indent + 1, quoteDepth: quoteDepth)] }
                    flattened[0].kind = item.checked == nil ? (ordered ? .numbered : .bulleted) : .checklist
                    flattened[0].indent = indent
                    flattened[0].checked = item.checked
                    flattened[0].startNumber = ordered ? start + offset : nil
                    result += flattened
                }
            case .code(let language, let value):
                var lines = value.components(separatedBy: "\n")
                if lines.last == "" { lines.removeLast() }
                if lines.isEmpty { lines = [""] }
                result += lines.map { .init(kind: .monospaced, runs: [NotesMarkdownRun(text: $0, code: true)],
                                            indent: indent, quoteDepth: quoteDepth, language: language) }
            case .table(let rows):
                result.append(.init(kind: .table, indent: indent, quoteDepth: quoteDepth, table: rows))
            case .divider:
                result.append(.init(kind: .divider, indent: indent, quoteDepth: quoteDepth))
            case .emptyParagraph(let savedIndent, let savedQuoteDepth):
                result.append(.init(kind: .body, indent: savedIndent ?? indent, quoteDepth: savedQuoteDepth ?? quoteDepth))
            }
        }
        return result
    }

    static func html(_ block: Block) -> String {
        switch block {
        case .paragraph(let runs): return "<p>\(html(runs))</p>"
        case .heading(let level, let runs):
            let nativeLevel = min(3, level)
            return "<h\(nativeLevel)>\(html(runs))</h\(nativeLevel)>"
        case .quote(let blocks): return "<blockquote>\(blocks.map(html).joined(separator: "\n"))</blockquote>"
        case .list(let ordered, let start, let items):
            let tag = ordered ? "ol" : "ul", start = ordered && start != 1 ? " start=\"\(start)\"" : ""
            let body = items.map { item in
                let check = item.checked.map { "<input type=\"checkbox\" disabled\($0 ? " checked" : "")> " } ?? ""
                var blocks = item.blocks
                let first: String
                if case .paragraph(let runs)? = blocks.first {
                    first = html(runs); blocks.removeFirst()
                } else { first = "" }
                return "<li>" + check + first + blocks.map(html).joined(separator: "\n") + "</li>"
            }.joined()
            return "<\(tag)\(start)>\(body)</\(tag)>"
        case .code(let language, let value):
            let kind = language.map { " class=\"language-\(escape($0))\"" } ?? ""
            let code = value.hasSuffix("\n") ? String(value.dropLast()) : value
            return "<pre><code\(kind)>\(escape(code))</code></pre>"
        case .table(let rows):
            return "<table>" + rows.enumerated().map { row, cells in
                let tag = row == 0 ? "th" : "td"
                return "<tr>" + cells.map { cell in
                    let alignment = cell.alignment.map { " style=\"text-align:\($0.rawValue)\"" } ?? ""
                    return "<\(tag)\(alignment)>\(html(cell.runs))</\(tag)>"
                }.joined() + "</tr>"
            }.joined() + "</table>"
        case .divider: return "<hr>"
        case .emptyParagraph: return "<p></p>"
        }
    }

    static func html(_ runs: [NotesMarkdownRun]) -> String {
        runs.map { run in
            if let resource = run.resource {
                let kind = resource.presentation == .image ? "image" : "attachment"
                return escape("[\(kind): \(resource.alt.isEmpty ? kind : resource.alt)]")
            }
            if run.nativeTag != nil || run.richLinkURL != nil { return escape(run.text) }
            if run.attachmentID != nil { return escape(run.text) }
            var value = escape(run.text).replacingOccurrences(of: "\n", with: "<br>")
            if run.code { value = "<code>\(value)</code>" }
            if run.bold { value = "<strong>\(value)</strong>" }
            if run.italic { value = "<em>\(value)</em>" }
            if run.strikethrough { value = "<del>\(value)</del>" }
            if run.underline { value = "<u>\(value)</u>" }
            if run.superscript != 0 { value = "<\(run.superscript > 0 ? "sup" : "sub")>\(value)</\(run.superscript > 0 ? "sup" : "sub")>" }
            if let highlight = run.highlight { value = "<mark data-apple-notes-highlight=\"\(highlight)\">\(value)</mark>" }
            if let link = safeURL(run.link) { value = "<a href=\"\(escape(link))\">\(value)</a>" }
            return value
        }.joined()
    }

    static func safeURL(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        guard let scheme = URLComponents(string: trimmed)?.scheme?.lowercased() else {
            return trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first?.contains(":") == true ? nil : trimmed
        }
        return ["http", "https", "mailto", "tel", "applenotes", "notescli-attachment", "file"].contains(scheme) ? trimmed : nil
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
