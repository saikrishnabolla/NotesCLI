import Foundation
import libxml2

public enum HTMLNoteImport {
    public static let uncheckedImagesWarning = "Image references were preserved but not checked or loaded."
    public struct Result: Sendable {
        public let markdown: String
        public let title: String?
        public let warnings: [String]
    }

    private enum ImportError: LocalizedError {
        case invalidInput, tooLarge, cannotParse

        var errorDescription: String? {
            switch self {
            case .invalidInput: return "HTML contains a NUL byte."
            case .tooLarge: return "HTML exceeds the 8 MiB import limit."
            case .cannotParse: return "The HTML could not be parsed."
            }
        }
    }

    public static func convert(_ html: String) throws -> Result {
        let size = html.utf8.count
        guard size <= 8 * 1_024 * 1_024 else { throw ImportError.tooLarge }
        guard !html.utf8.contains(0) else { throw ImportError.invalidInput }
        if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Result(markdown: "", title: nil, warnings: [])
        }

        // The HTML parser does not load external DTDs or expand XML entities.
        let options = HTML_PARSE_NONET.rawValue | HTML_PARSE_NODEFDTD.rawValue
            | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_IGNORE_ENC.rawValue
        guard let document = html.withCString({
            htmlReadMemory($0, Int32(size), nil, "UTF-8", Int32(options))
        }) else { throw ImportError.cannotParse }
        defer { xmlFreeDoc(document) }
        guard let root = xmlDocGetRootElement(document) else {
            return Result(markdown: "", title: nil, warnings: [])
        }

        let renderer = Renderer()
        let markdown = renderer.flow(renderer.render(root))
        return Result(markdown: markdown, title: renderer.documentTitle ?? renderer.firstHeading,
                      warnings: renderer.warnings)
    }
}

private extension HTMLNoteImport {
    typealias Node = UnsafeMutablePointer<xmlNode>

    enum Piece {
        case inline(String)
        case block(String)
    }

    final class Renderer {
        var documentTitle: String?
        var firstHeading: String?
        private(set) var warnings: [String] = []
        private var warned: Set<String> = []

        private static let containers: Set<String> = [
            "address", "article", "body", "dd", "details", "div", "dl", "dt", "figcaption",
            "figure", "header", "main", "section", "summary"
        ]
        private static let chrome: Set<String> = [
            "aside", "button", "dialog", "footer", "input", "menu", "nav", "select", "textarea"
        ]
        private static let chromeRoles: Set<String> = [
            "complementary", "contentinfo", "menu", "menubar", "navigation", "search", "toolbar"
        ]
        private static let chromeNames: Set<String> = [
            "navbar", "sidebar", "site-footer", "site-header", "skip-link", "theme-toggle", "toolbar"
        ]
        private static let widgets: Set<String> = [
            "applet", "audio", "canvas", "embed", "iframe", "object", "script", "svg", "video"
        ]

        private func warn(_ message: String) {
            if warned.insert(message).inserted { warnings.append(message) }
        }

        func render(_ node: Node, inCell: Bool = false) -> [Piece] {
            switch node.pointee.type {
            case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
                return [.inline(escape(collapse(string(node.pointee.content))))]
            case XML_ELEMENT_NODE:
                break
            default:
                return []
            }

            let tag = name(node)
            let role = attribute("role", node)?.lowercased()
            if hiddenOrChrome(node, tag: tag, role: role) { return [] }
            if Self.widgets.contains(tag) || role == "application" {
                warn("Skipped unsupported HTML content: <\(tag)>.")
                return []
            }

            switch tag {
            case "head":
                for child in children(node) where ["title", "script"].contains(name(child)) {
                    _ = render(child)
                }
                return []
            case "title":
                documentTitle = documentTitle ?? nonempty(collapse(rawText(node)))
                return []
            case "base", "link", "meta", "noscript", "source", "style", "template":
                return []
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let text = inline(contents(node, inCell: inCell)).replacingOccurrences(of: "<br>", with: " ")
                if tag == "h1" { firstHeading = firstHeading ?? nonempty(collapse(rawText(node))) }
                guard !text.isEmpty else { return [] }
                return [.block(inCell ? text : String(repeating: "#", count: Int(tag.suffix(1)) ?? 1) + " " + text)]
            case "p":
                return [.block(flow(contents(node, inCell: inCell), inCell: inCell))]
            case "br":
                return [.inline("<br>")]
            case "hr":
                return inCell ? [] : [.block("---")]
            case "strong", "b":
                return styled("**", contents(node, inCell: inCell))
            case "em", "i":
                return styled("*", contents(node, inCell: inCell))
            case "del", "s", "strike":
                return styled("~~", contents(node, inCell: inCell))
            case "a":
                let pieces = contents(node, inCell: inCell)
                guard let href = attribute("href", node), !href.isEmpty else { return pieces }
                guard let destination = destination(href, image: false) else {
                    warn("Skipped a link with an unsafe or unsupported URL.")
                    return pieces
                }
                return wrapped(pieces) { "[\($0)](\(destination))" }
            case "img":
                return [.inline(image(node))]
            case "code", "kbd", "samp":
                return [.inline(codeSpan(rawText(node), inCell: inCell))]
            case "pre":
                if inCell { return [.inline(codeSpan(rawText(node), inCell: true))] }
                return [.block(codeBlock(node))]
            case "ul", "ol":
                return [.block(list(node, ordered: tag == "ol", inCell: inCell))]
            case "blockquote":
                let quoted = flow(contents(node, inCell: inCell), inCell: inCell)
                return [.block(inCell ? quoted : quoted.components(separatedBy: "\n").map {
                    $0.isEmpty ? ">" : "> " + $0
                }.joined(separator: "\n"))]
            case "table":
                if inCell {
                    warn("Flattened a nested HTML table.")
                    return [.inline(inline(contents(node, inCell: true)))]
                }
                return [.block(table(node))]
            default:
                if tag.contains("-") { warn("Imported only the static content of <\(tag)>.") }
                let pieces = contents(node, inCell: inCell)
                return Self.containers.contains(tag) ? [.block(flow(pieces, inCell: inCell))] : pieces
            }
        }

        private func contents(_ node: Node, inCell: Bool) -> [Piece] {
            children(node).flatMap { render($0, inCell: inCell) }
        }

        private func hiddenOrChrome(_ node: Node, tag: String, role: String?) -> Bool {
            if attribute("hidden", node) != nil || attribute("aria-hidden", node)?.lowercased() == "true"
                || Self.chrome.contains(tag) || role.map(Self.chromeRoles.contains) == true {
                return true
            }
            let classes = (attribute("class", node) ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            let id = (attribute("id", node) ?? "").lowercased()
            return Self.chromeNames.contains(id) || classes.contains { Self.chromeNames.contains(String($0)) }
        }

        func flow(_ pieces: [Piece], inCell: Bool = false) -> String {
            var blocks: [String] = []
            var line = ""
            func flush() {
                let text = trim(line)
                if !text.isEmpty {
                    blocks.append(inCell ? text : escapeBlockPrefix(text))
                }
                line = ""
            }
            for piece in pieces {
                switch piece {
                case .inline(let value):
                    if line.last == " ", value.first == " " { line += value.dropFirst() }
                    else { line += value }
                case .block(let value):
                    flush()
                    if !value.isEmpty { blocks.append(value) }
                }
            }
            flush()
            return blocks.joined(separator: inCell ? "<br>" : "\n\n")
        }

        private func escapeBlockPrefix(_ text: String) -> String {
            // Don't let literal prose such as "1. example" become a Markdown block.
            if text.hasPrefix("- ") || text.hasPrefix("+ ") || text.allSatisfy({ $0 == "-" }) {
                return "\\" + text
            }
            if let prefix = text.range(of: #"^[0-9]{1,9}[.)](?= |$)"#, options: .regularExpression) {
                var result = text
                result.insert("\\", at: text.index(before: prefix.upperBound))
                return result
            }
            return text
        }

        private func inline(_ pieces: [Piece]) -> String {
            flow(pieces, inCell: true)
        }

        private func wrapped(_ pieces: [Piece], _ make: (String) -> String) -> [Piece] {
            let value = inline(pieces)
            guard !value.isEmpty else { return pieces }
            let leading: String
            if case .inline(let first)? = pieces.first, first.first == " " { leading = " " }
            else { leading = "" }
            let trailing: String
            if case .inline(let last)? = pieces.last, last.last == " " { trailing = " " }
            else { trailing = "" }
            return [.inline(leading + make(value) + trailing)]
        }

        private func styled(_ marker: String, _ pieces: [Piece]) -> [Piece] {
            wrapped(pieces) { marker + $0 + marker }
        }

        private func list(_ node: Node, ordered: Bool, inCell: Bool) -> String {
            let start = attribute("start", node).flatMap(Int.init) ?? 1
            let items = children(node).filter { name($0) == "li" }
            return items.enumerated().map { offset, item in
                let value = min(max(start, 0), 999_999_999) + offset
                let marker = ordered ? "\(min(value, 999_999_999)). " : "- "
                let pieces = contents(item, inCell: inCell)
                if inCell { return marker + inline(pieces) }
                let text = flow(pieces)
                var lines = text.components(separatedBy: "\n")
                if let first = lines.first, first.hasPrefix("- ") || first.range(of: #"^[0-9]+\. "#, options: .regularExpression) != nil {
                    lines.insert("", at: 0)
                }
                let indent = String(repeating: " ", count: marker.count)
                var result = lines.enumerated().map { index, line in
                    if index == 0 { return line.isEmpty ? trim(marker) : marker + line }
                    return line.isEmpty ? "" : indent + line
                }.joined(separator: "\n")
                if lines.count >= 3, lines[1].isEmpty,
                   lines[2].range(of: #"^\s*(?:- |[0-9]+\. )"#, options: .regularExpression) != nil,
                   let gap = result.range(of: "\n\n") {
                    result.replaceSubrange(gap, with: "\n")
                }
                return result
            }.joined(separator: inCell ? "<br>" : "\n")
        }

        private func table(_ node: Node) -> String {
            var rows: [[String]] = []
            var captions: [String] = []
            func appendRow(_ row: Node) {
                let cells = children(row).filter { ["td", "th"].contains(name($0)) }
                guard !cells.isEmpty else { return }
                var values: [String] = []
                for cell in cells {
                    let colspan = attribute("colspan", cell).flatMap(Int.init) ?? 1
                    let rowspan = attribute("rowspan", cell).flatMap(Int.init) ?? 1
                    if colspan != 1 || rowspan != 1 { warn("Flattened merged HTML table cells.") }
                    values.append(inline(contents(cell, inCell: true)))
                }
                rows.append(values)
            }
            for child in children(node) {
                switch name(child) {
                case "tr": appendRow(child)
                case "thead", "tbody", "tfoot":
                    children(child).filter { name($0) == "tr" }.forEach(appendRow)
                case "caption":
                    let caption = flow(contents(child, inCell: false))
                    if !caption.isEmpty { captions.append(caption) }
                default: break
                }
            }
            guard let width = rows.map(\.count).max() else { return captions.joined(separator: "\n\n") }
            // Bound rectangular expansion for very uneven input.
            guard width <= 256, rows.count <= 100_000 / width else {
                warn("Flattened an oversized HTML table.")
                return (captions + rows.map { $0.joined(separator: " · ") }).joined(separator: "\n\n")
            }
            rows.insert(Array(repeating: "---", count: width), at: 1)
            let markdown = rows.map { row in
                "| " + row.joined(separator: " | ") + String(repeating: " | ", count: width - row.count) + " |"
            }.joined(separator: "\n")
            return (captions + [markdown]).joined(separator: "\n\n")
        }

        private func image(_ node: Node) -> String {
            let alt = escape(trim(collapse(attribute("alt", node) ?? "")))
            guard let source = attribute("src", node), !trim(source).isEmpty else {
                warn("Skipped an image with no static src.")
                return alt
            }
            guard let url = destination(source, image: true) else {
                warn("Skipped an image with an unsafe or unsupported src.")
                return alt
            }
            warn(HTMLNoteImport.uncheckedImagesWarning)
            return "![\(alt)](\(url))"
        }

        private func destination(_ source: String, image: Bool) -> String? {
            let url = trim(source)
            let controls = CharacterSet.controlCharacters
            guard !url.isEmpty, let decoded = url.removingPercentEncoding,
                  source.rangeOfCharacter(from: controls) == nil,
                  decoded.rangeOfCharacter(from: controls) == nil,
                  !decoded.contains("\\"), let components = URLComponents(string: url) else { return nil }
            if let scheme = components.scheme?.lowercased() {
                switch scheme {
                case "http", "https":
                    guard let host = components.host, !host.isEmpty else { return nil }
                case "mailto", "tel":
                    guard !image else { return nil }
                default: return nil
                }
            } else {
                if url.hasPrefix("#") { return image ? nil : encodedDestination(url) }
                let path = trim(decoded)
                guard !path.hasPrefix("/"), !path.hasPrefix("~"),
                      !path.prefix(while: { $0 != "/" }).contains(":"),
                      !path.split(separator: "/").contains(".."),
                      !path.hasPrefix("?"), !path.hasPrefix("#") else { return nil }
            }
            return encodedDestination(url)
        }

        private func encodedDestination(_ url: String) -> String? {
            let allowed = CharacterSet.urlFragmentAllowed
                .union(CharacterSet(charactersIn: "#%[]"))
                .subtracting(CharacterSet(charactersIn: "()|"))
            return url.addingPercentEncoding(withAllowedCharacters: allowed)?
                .replacingOccurrences(of: "&", with: "&amp;")
        }

        private func codeSpan(_ source: String, inCell: Bool) -> String {
            let line = source.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            guard !line.isEmpty else { return "" }
            let fence = delimiter(for: line, minimum: 1)
            let pad = line.hasPrefix("`") || line.hasSuffix("`")
                || (line.hasPrefix(" ") && line.hasSuffix(" ") && !trim(line).isEmpty) ? " " : ""
            let code = inCell ? line.replacingOccurrences(of: "|", with: "\\|") : line
            return fence + pad + code + pad + fence
        }

        private func codeBlock(_ node: Node) -> String {
            let code = rawText(node)
            let fence = delimiter(for: code, minimum: 3)
            let language = children(node).first(where: { name($0) == "code" })
                .flatMap { attribute("class", $0) }?.split(whereSeparator: \.isWhitespace)
                .first(where: { $0.hasPrefix("language-") })?.dropFirst("language-".count)
            let info = language.flatMap { value in
                value.range(of: #"^[A-Za-z0-9_+-]{1,32}$"#, options: .regularExpression) != nil
                    ? String(value) : nil
            } ?? ""
            return fence + info + "\n" + code + (code.hasSuffix("\n") ? "" : "\n") + fence
        }

        private func delimiter(for text: String, minimum: Int) -> String {
            var longest = minimum - 1
            var run = 0
            for byte in text.utf8 {
                run = byte == 96 ? run + 1 : 0
                longest = max(longest, run)
            }
            return String(repeating: "`", count: longest + 1)
        }

        private func escape(_ text: String) -> String {
            var escaped = ""
            for character in text {
                if "\\`*_~[]!#<>|".contains(character) { escaped.append("\\") }
                if character == "&" { escaped += "&amp;" }
                else { escaped.append(character) }
            }
            return escaped
        }

        private func collapse(_ text: String) -> String {
            text.replacingOccurrences(of: #"[ \t\r\n\f]+"#, with: " ", options: .regularExpression)
        }

        private func trim(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func nonempty(_ text: String) -> String? {
            let value = trim(text)
            return value.isEmpty ? nil : value
        }

        private func string(_ value: UnsafePointer<xmlChar>?) -> String {
            value.map { String(cString: $0) } ?? ""
        }

        private func name(_ node: Node) -> String {
            node.pointee.type == XML_ELEMENT_NODE ? string(node.pointee.name) : ""
        }

        private func children(_ node: Node) -> [Node] {
            sequence(first: node.pointee.children, next: { $0?.pointee.next })
                .prefix(while: { $0 != nil }).compactMap { $0 }
        }

        private func attribute(_ key: String, _ node: Node) -> String? {
            var current = node.pointee.properties
            while let attribute = current {
                if string(attribute.pointee.name) == key {
                    var value = ""
                    var part = attribute.pointee.children
                    while let child = part {
                        if child.pointee.type == XML_TEXT_NODE { value += string(child.pointee.content) }
                        part = child.pointee.next
                    }
                    return value
                }
                current = attribute.pointee.next
            }
            return nil
        }

        private func rawText(_ node: Node) -> String {
            switch node.pointee.type {
            case XML_TEXT_NODE, XML_CDATA_SECTION_NODE: return string(node.pointee.content)
            case XML_ELEMENT_NODE:
                let tag = name(node)
                if Self.widgets.contains(tag) || ["style", "template"].contains(tag)
                    || hiddenOrChrome(node, tag: tag, role: attribute("role", node)?.lowercased()) { return "" }
                return children(node).map(rawText).joined()
            default: return ""
            }
        }
    }
}
