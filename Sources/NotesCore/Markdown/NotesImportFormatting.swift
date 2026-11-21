import Foundation
import Markdown

/// Import source preparation. Edits use CommonMark ranges, never cross a list,
/// quote, or fenced code boundary, and do not fetch documents or images.
public struct NotesImportFormatting {
    public let title: String?
    public let markdown: String
    public let assetFiles: [URL]
    public let warnings: [String]

    public init(_ source: String, relativeTo base: URL, allowedRoot: URL, attachmentLimit: Int,
                recognizedAsPlainText: Bool = false) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let source = recognizedAsPlainText ? normalized.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: #"([[:punct:]])"#, with: #"\\$1"#, options: .regularExpression)
        }.joined(separator: "\n") : normalized
        let bytes = Array(source.utf8)
        let starts = [0] + bytes.indices.filter { bytes[$0] == 10 }.map { $0 + 1 }
        let parsed = Document(parsing: source, options: [.disableSmartOpts])
        let blocks = Array(parsed.children)
        let root = allowedRoot.standardizedFileURL.resolvingSymlinksInPath().path
        var edits: [(Range<Int>, String)] = []
        var warnings: [String] = []
        var assets: [URL] = []

        func offset(_ point: SourceLocation) -> Int? {
            guard point.line > 0, starts.indices.contains(point.line - 1) else { return nil }
            let start = starts[point.line - 1]
            let result = start + point.column - 1
            let end = point.line < starts.count ? starts[point.line] : bytes.count
            return result >= start && result <= end ? result : nil
        }
        func sourceRange(_ node: any Markup) -> Range<Int>? {
            guard let range = node.range, let lo = offset(range.lowerBound),
                  let hi = offset(range.upperBound), lo < hi else { return nil }
            return lo..<hi
        }
        func escaped(_ label: String) -> String {
            label.replacingOccurrences(of: #"([\\\[\]*_`~<>|])"#, with: #"\\$1"#, options: .regularExpression)
        }
        func file(for value: String) -> URL? {
            guard !value.hasPrefix("//"), !value.hasPrefix("~"), !value.hasPrefix("/") else { return nil }
            let url: URL
            if let scheme = URLComponents(string: value)?.scheme {
                guard scheme.lowercased() == "file", let fileURL = URL(string: value), fileURL.isFileURL,
                      [nil, "", "localhost"].contains(fileURL.host) else { return nil }
                url = fileURL
            } else {
                url = base.appendingPathComponent(value.removingPercentEncoding ?? value)
            }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
            return resolved
        }
        func visit(_ node: any Markup, inTable: Bool = false) {
            let inTable = inTable || node is Table
            let image = node as? Image
            let link = node as? Link
            if let destination = image?.source ?? link?.destination, let range = sourceRange(node) {
                let label = escaped(image?.plainText ?? link?.plainText ?? "")
                let display = label.isEmpty ? (image != nil ? "Image" : "Attachment") : label
                let scheme = URLComponents(string: destination)?.scheme?.lowercased()
                let isRemote = scheme == "http" || scheme == "https"
                let isLocal = NotesMarkdownResource(source: destination, alt: "").isLocal
                if scheme?.hasPrefix("notescli-") == true {
                    edits.append((range, display))
                    warnings.append("Internal Notes CLI markers from external files were not applied.")
                    return
                }
                if (image != nil || isLocal) && !destination.hasPrefix("#") {
                    if !inTable, isLocal, let url = file(for: destination),
                       let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                       attributes.isRegularFile == true, (1...attachmentLimit).contains(attributes.fileSize ?? 0),
                       (try? InputFile.validated(url, kind: "attachment", maxBytes: attachmentLimit)) != nil {
                        assets.append(url)
                        edits.append((range, "\(image != nil ? "!" : "")[\(display)](<\(url.absoluteString)>)"))
                    } else if isRemote, image != nil, !destination.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }) {
                        edits.append((range, "[\(display)](<\(destination)>)"))
                        warnings.append("Remote images are kept as links, not downloaded.")
                    } else {
                        edits.append((range, display))
                        warnings.append(inTable ? "Files inside table cells are not embedded."
                            : "A linked file was missing, outside the import folder, or too large: \(display).")
                    }
                    return
                }
            }
            for child in node.children { visit(child, inTable: inTable) }
        }

        var title: String?
        var firstBody = 0
        if let heading = blocks.first as? Heading, heading.level == 1, let range = heading.range {
            title = heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            firstBody = 1
            let start = starts[range.lowerBound.line - 1]
            let end = range.upperBound.line < starts.count ? starts[range.upperBound.line] : bytes.count
            edits.append((start..<end, ""))
        }
        var previous: (node: any Markup, range: SourceRange)?
        for node in blocks.dropFirst(firstBody) {
            visit(node)
            guard let range = node.range else { continue }
            if let prior = previous, range.lowerBound.line > prior.range.upperBound.line,
               !(prior.node is Heading), let start = starts.indices.contains(range.lowerBound.line - 1)
                    ? starts[range.lowerBound.line - 1] : nil,
               (range.lowerBound.line > prior.range.upperBound.line + 1 || node is Heading),
               !Self.isSpacer(prior.node), !Self.isSpacer(node) {
                edits.append((start..<start, "\n\n<!-- notescli-empty-paragraph:0:0 -->\n\n"))
            }
            // The separate note title already exists. A later H1 is a section.
            if let heading = node as? Heading, heading.level == 1, let start = offset(range.lowerBound),
               bytes.indices.contains(start), bytes[start] == 35 {
                edits.append((start..<(start + 1), "##"))
            }
            previous = (node, range)
        }
        var revised = bytes
        for (range, text) in edits.sorted(by: {
            $0.0.lowerBound != $1.0.lowerBound ? $0.0.lowerBound > $1.0.lowerBound : $0.0.upperBound > $1.0.upperBound
        }) {
            revised.replaceSubrange(range, with: text.utf8)
        }
        let markdown = String(decoding: revised, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let document = NotesMarkdownDocument(parsing: markdown)
        for paragraph in document.paragraphs {
            if let table = paragraph.table,
               (table.first?.count ?? 0) >= 5 || (table.first?.count ?? 0) >= 3 && table.joined().contains(where: { $0.plainText.count > 140 }) {
                warnings.append("A wide table may require horizontal scrolling in Notes.")
            }
        }
        self.title = title?.isEmpty == false ? title : nil
        self.markdown = markdown
        self.assetFiles = assets
        self.warnings = Array(Set(warnings)).sorted()
    }

    private static func isSpacer(_ node: any Markup) -> Bool {
        (node as? HTMLBlock)?.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("<!-- notescli-empty-paragraph:") == true
    }
}
