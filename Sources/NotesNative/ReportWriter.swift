import Foundation
import Darwin
import ImageIO
import NotesCore
import NotesDiagrams
import NotesStore
import UniformTypeIdentifiers

public struct ReportElementCounts: Codable, Equatable, Sendable {
    public var headings = 0
    public var tables = 0
    public var links = 0
    public var richLinks = 0
    public var images = 0
    public var remoteImages = 0
    public var diagrams = 0
    public var tags = 0
    public var checklists = 0
    public var attachments = 0
    public var citations = 0
    public var dividers = 0

    public init() {}
}

struct ReportMarkdownPlan {
    var markdown: String
    var requested: ReportElementCounts
}

enum ReportMarkdownPreprocessor {
    typealias ImageDownloader = (URL) throws -> URL
    typealias DiagramRenderer = (_ language: String, _ source: String) throws -> URL

    static func prepare(title: String, markdown source: String, tags: [String],
                        downloadImage: ImageDownloader,
                        renderDiagram: DiagramRenderer,
                        stageLocalResource: (String) throws -> URL = { value in
                            if let url = URL(string: value), url.isFileURL { return url }
                            return URL(fileURLWithPath: value)
                        }) throws -> ReportMarkdownPlan {
        var requested = ReportElementCounts()
        var markdown = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        markdown = stripDuplicateTitle(title, from: markdown)
        markdown = try replaceDiagramFences(in: markdown, requested: &requested, render: renderDiagram)
        markdown = try replaceRemoteImages(in: markdown, requested: &requested, download: downloadImage)
        markdown = rewriteFootnotes(in: markdown, requested: &requested)
        markdown = rewriteBareURLs(in: markdown, requested: &requested)
        markdown = rewriteTags(in: markdown, requested: &requested)

        let normalizedTags = try tags.map(normalizedTag)
        if !normalizedTags.isEmpty {
            let markers = normalizedTags.map { "[#\($0)](notescli-tag:\(percentEncode($0)))" }.joined(separator: " ")
            markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + markers
            requested.tags += normalizedTags.count
        }
        markdown = markdown.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let localResources = NotesMarkdownDocument(parsing: markdown).localResources
        for resource in localResources {
            let staged = try stageLocalResource(resource.source)
            markdown = replaceResource(resource.source, with: staged.absoluteString, in: markdown)
        }
        markdown = addReportSpacing(to: markdown)
        let document = NotesMarkdownDocument(parsing: markdown)
        requested.headings = document.paragraphs.filter { [.heading, .subheading].contains($0.kind) }.count
        requested.tables = document.paragraphs.filter { $0.kind == .table }.count
        requested.checklists = document.paragraphs.filter { $0.kind == .checklist }.count
        requested.dividers = document.paragraphs.filter { $0.kind == .divider }.count
        requested.images += document.resources.filter { $0.presentation == .image }.count - requested.diagrams - requested.remoteImages
        requested.attachments = document.resources.filter { $0.presentation == .file }.count
        requested.links = document.paragraphs.flatMap(\.runs).filter { $0.link != nil }.count +
            document.paragraphs.flatMap { $0.table ?? [] }.flatMap { $0 }.flatMap(\.runs).filter { $0.link != nil }.count
        return ReportMarkdownPlan(markdown: markdown, requested: requested)
    }

    private static func stripDuplicateTitle(_ title: String, from markdown: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        let line = lines[first].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("# "), String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) == title else {
            return markdown
        }
        lines.remove(at: first)
        if lines.indices.contains(first), lines[first].trimmingCharacters(in: .whitespaces).isEmpty { lines.remove(at: first) }
        return lines.joined(separator: "\n")
    }

    private static func replaceDiagramFences(in markdown: String, requested: inout ReportElementCounts,
                                             render: DiagramRenderer) throws -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = [], index = 0
        while index < lines.count {
            let opening = lines[index].trimmingCharacters(in: .whitespaces)
            guard opening.hasPrefix("```") else { output.append(lines[index]); index += 1; continue }
            let info = String(opening.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let language: String?
            switch info.split(whereSeparator: \Character.isWhitespace).map(String.init) {
            case ["svg"]: language = "svg"
            case ["html", "diagram"]: language = "html"
            case ["mermaid"]: language = "mermaid"
            default: language = nil
            }
            guard let language else {
                output.append(lines[index]); index += 1; continue
            }
            var end = index + 1
            while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces) != "```" { end += 1 }
            guard end < lines.count else {
                throw NotesError("invalid_report_diagram", "The \(language) diagram fence is not closed.")
            }
            guard language != "mermaid" else {
                throw NotesError("unsupported_report_diagram",
                                 "Mermaid report fences are not supported without a bundled renderer.",
                                 hint: "Use a self-contained SVG or HTML fence so the report can render offline.")
            }
            let source = lines[(index + 1)..<end].joined(separator: "\n")
            let file = try render(language, source)
            requested.diagrams += 1
            requested.images += 1
            output.append("![Diagram \(requested.diagrams)](<\(file.absoluteString)>)")
            index = end + 1
        }
        return output.joined(separator: "\n")
    }

    private static func replaceRemoteImages(in markdown: String, requested: inout ReportElementCounts,
                                            download: ImageDownloader) throws -> String {
        var insecure = false
        _ = mapProse(in: markdown) { prose in
            if prose.range(of: #"!\[[^\]]*\]\((?:<)?http://"#, options: .regularExpression) != nil {
                insecure = true
            }
            return prose
        }
        if insecure {
            throw NotesError("insecure_remote_image", "Remote report images must use HTTPS.")
        }
        let expression = try NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\((?:<)?(https://[^\s)>]+)(?:>)?(?:\s+\"[^\"]*\")?\)"#,
            options: [.caseInsensitive]
        )
        var thrown: Error?
        let rewritten = mapProse(in: markdown) { prose in
            guard thrown == nil else { return prose }
            var result = prose
            let matches = expression.matches(in: prose, range: NSRange(prose.startIndex..., in: prose))
            for match in matches.reversed() {
                guard let whole = Range(match.range(at: 0), in: result),
                      let altRange = Range(match.range(at: 1), in: result),
                      let urlRange = Range(match.range(at: 2), in: result),
                      let url = URL(string: String(result[urlRange])) else {
                    thrown = NotesError("invalid_remote_image", "A remote report image URL is invalid.")
                    return prose
                }
                do {
                    let local = try download(url)
                    requested.remoteImages += 1
                    requested.images += 1
                    result.replaceSubrange(whole, with: "![\(result[altRange])](<\(local.absoluteString)>)")
                } catch {
                    thrown = error
                    return prose
                }
            }
            return result
        }
        if let thrown { throw thrown }
        return rewritten
    }

    private static func rewriteFootnotes(in markdown: String, requested: inout ReportElementCounts) -> String {
        let definition = try! NSRegularExpression(pattern: #"^\[\^([^\]]+)\]:\s*(.+)$"#)
        var definitions: [(String, String)] = [], body: [String] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = definition.firstMatch(in: line, range: range),
                  let idRange = Range(match.range(at: 1), in: line),
                  let textRange = Range(match.range(at: 2), in: line) else {
                body.append(line); continue
            }
            definitions.append((String(line[idRange]), String(line[textRange])))
        }
        guard !definitions.isEmpty else { return markdown }
        var text = body.joined(separator: "\n")
        for (id, _) in definitions {
            let token = "[^\(id)]"
            let count = text.components(separatedBy: token).count - 1
            if count > 0 {
                text = text.replacingOccurrences(of: token, with: "<sup>[\(id)]</sup>")
                requested.citations += count
            }
        }
        let citations = definitions.map { "\($0.0). \($0.1)" }.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## Citations\n\n" + citations
    }

    private static func rewriteBareURLs(in markdown: String, requested: inout ReportElementCounts) -> String {
        mapProse(in: markdown) { prose in
            let value = prose.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: value), url.absoluteString == value,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
                return prose
            }
            requested.richLinks += 1
            let encoded = Data(value.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let leading = prose.prefix { $0.isWhitespace }
            let trailing = prose.reversed().prefix { $0.isWhitespace }.reversed()
            return leading + "[\(url.host ?? value)](notescli-card:\(encoded))" + trailing
        }
    }

    private static func rewriteTags(in markdown: String, requested: inout ReportElementCounts) -> String {
        let expression = try! NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_/#])#([\p{L}_][\p{L}\p{N}_-]*)(?![\p{L}\p{N}_-])"#
        )
        let urlExpression = try! NSRegularExpression(
            pattern: #"(?i)\b(?:https?://|www\.)[^\s<>()\[\]{}]+"#
        )
        return mapProse(in: markdown, skipLine: { isMarkdownHeading($0) }) { prose in
            var result = prose
            let matches = expression.matches(in: prose, range: NSRange(prose.startIndex..., in: prose))
            let urlRanges = urlExpression.matches(in: prose, range: NSRange(prose.startIndex..., in: prose))
                .map(\.range)
            for match in matches.reversed() {
                guard !urlRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                guard let whole = Range(match.range(at: 0), in: result),
                      let tagRange = Range(match.range(at: 1), in: result) else { continue }
                let tag = String(result[tagRange])
                result.replaceSubrange(whole, with: "[#\(tag)](notescli-tag:\(percentEncode(tag)))")
                requested.tags += 1
            }
            return result
        }
    }

    private static func normalizedTag(_ value: String) throws -> String {
        let tag = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard !tag.isEmpty, !tag.contains(where: { $0.isWhitespace || $0 == "#" }) else {
            throw NotesError("invalid_tag", "A report tag must be one word without #.")
        }
        return tag
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func replaceResource(_ source: String, with replacement: String, in markdown: String) -> String {
        mapProse(in: markdown) { prose in
            prose.replacingOccurrences(of: "(\(source))", with: "(<\(replacement)>)")
                .replacingOccurrences(of: "(<\(source)>)", with: "(<\(replacement)>)")
                .replacingOccurrences(of: "(\(source) \"", with: "(<\(replacement)> \"")
        }
    }

    private static func mapProse(in markdown: String, skipLine: (String) -> Bool = { _ in false },
                                 transform: (String) -> String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fence: String?
        return lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                if trimmed == current { fence = nil }
                return line
            }
            if let opening = fenceDelimiter(trimmed) {
                fence = opening
                return line
            }
            guard !skipLine(line) else { return line }
            return mapInlineProse(in: line, transform: transform)
        }.joined(separator: "\n")
    }

    private static func fenceDelimiter(_ trimmed: String) -> String? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        return count >= 3 ? String(repeating: first, count: count) : nil
    }

    private static func mapInlineProse(in line: String, transform: (String) -> String) -> String {
        var output = "", cursor = line.startIndex
        while cursor < line.endIndex, let opening = line[cursor...].firstIndex(of: "`") {
            let runEnd = line[opening...].firstIndex(where: { $0 != "`" }) ?? line.endIndex
            let delimiter = String(line[opening..<runEnd])
            guard let closing = line[runEnd...].range(of: delimiter)?.lowerBound else { break }
            let closingEnd = line.index(closing, offsetBy: delimiter.count)
            output += transform(String(line[cursor..<opening]))
            output += line[opening..<closingEnd]
            cursor = closingEnd
        }
        output += transform(String(line[cursor...]))
        return output
    }

    private static func isMarkdownHeading(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .range(of: #"^#{1,6}(?:\s|$)"#, options: .regularExpression) != nil
    }

    private static func addReportSpacing(to markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let marker = "<!-- notescli-empty-paragraph:0:0 -->"
        var output: [String] = []
        var insideFence = false
        var seenHeading = false

        func previousContentLine() -> String? {
            output.reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }

        func appendSpacer() {
            guard previousContentLine() != marker else { return }
            if output.last?.isEmpty == false { output.append("") }
            output.append(marker)
            output.append("")
        }

        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let fence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            if fence {
                output.append(line)
                insideFence.toggle()
                continue
            }
            if !insideFence {
                let heading = isReportHeading(trimmed)
                let table = isTableStart(lines: lines, at: index)
                let checklist = isChecklistStart(line)
                let previous = previousContentLine()
                if heading {
                    if seenHeading { appendSpacer() }
                    seenHeading = true
                } else if table, previous.map(isParagraphLine) == true {
                    appendSpacer()
                } else if checklist, previous.map(isTableRow) == true {
                    appendSpacer()
                }
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private static func isReportHeading(_ line: String) -> Bool {
        line.range(of: #"^#{2,6}\s+\S"#, options: .regularExpression) != nil
    }

    private static func isTableStart(lines: [String], at index: Int) -> Bool {
        guard lines.indices.contains(index + 1), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        var delimiter = lines[index + 1].trimmingCharacters(in: .whitespaces)
        if delimiter.hasPrefix("|") { delimiter.removeFirst() }
        if delimiter.hasSuffix("|") { delimiter.removeLast() }
        let cells = delimiter.split(separator: "|", omittingEmptySubsequences: false)
        return !cells.isEmpty && cells.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces)
                .range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    private static func isChecklistStart(_ line: String) -> Bool {
        line.range(of: #"^\s{0,3}[-+*]\s+\[[ xX]\]\s+"#, options: .regularExpression) != nil
    }

    private static func isTableRow(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("|") && value.hasSuffix("|")
    }

    private static func isParagraphLine(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "<!-- notescli-empty-paragraph:0:0 -->",
              !isReportHeading(value), !isTableRow(value), !isChecklistStart(value),
              !value.hasPrefix("# "), !value.hasPrefix("- "), !value.hasPrefix("* "),
              !value.hasPrefix("+ "), !value.hasPrefix(">"), value != "---", value != "***" else {
            return false
        }
        return true
    }
}

public struct NativeReportRequest: Sendable {
    public var title: String
    public var markdown: String
    public var assetBaseDirectory: URL
    public var folder: String?
    public var tags: [String]
    public var attachments: [String]
    public var replace: Bool
    public var allowShared: Bool

    public init(title: String, markdown: String, assetBaseDirectory: URL, folder: String? = nil,
                tags: [String] = [], attachments: [String] = [], replace: Bool = false,
                allowShared: Bool = false) {
        self.title = title
        self.markdown = markdown
        self.assetBaseDirectory = assetBaseDirectory
        self.folder = folder
        self.tags = tags
        self.attachments = attachments
        self.replace = replace
        self.allowShared = allowShared
    }
}

public struct NativeReportResult: Codable, Sendable {
    public var requested: ReportElementCounts
    public var written: ReportElementCounts
    public var degraded: [String]
    public var noteID: String
    public var noteLink: String
    public var replacedNoteID: String?
    public var write: NativeWriteResult
}

public struct ReportTargetResolution: Sendable {
    public var folder: Folder
    public var existing: [Note]

    public init(folder: Folder, existing: [Note]) {
        self.folder = folder
        self.existing = existing
    }
}

enum ReportReplacementDecision: Equatable {
    case complete
    case rollbackNewReport
    case ambiguousKeepNewReport

    init(deleteOutcome: WriteOutcome) {
        switch deleteOutcome {
        case .verified: self = .complete
        case .unknown: self = .ambiguousKeepNewReport
        case .unverified, .rolledBack: self = .rollbackNewReport
        }
    }
}

public final class NotesReportWriter: @unchecked Sendable {
    private let writer: NativeNotesWriter

    public init(writer: NativeNotesWriter = NativeNotesWriter()) {
        self.writer = writer
    }

    public func create(_ request: NativeReportRequest) throws -> NativeReportResult {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NotesError("invalid_title", "A report title is required.") }
        let target = try Self.resolveTarget(title: title, folder: request.folder, replacing: request.replace,
                                            reader: SQLiteNotesStore(refresh: true))
        let existing = target.existing
        if !existing.isEmpty, !request.replace {
            throw NotesError("report_exists", "A note named \(title) already exists.",
                             hint: "Pass --replace, or set replace=true, to replace it without leaving an active duplicate.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-report-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let downloader = SafeReportDownloader(directory: directory)
        let stager = ReportAssetStager(directory: directory, baseDirectory: request.assetBaseDirectory)
        var diagramIndex = 0
        let plan = try ReportMarkdownPreprocessor.prepare(
            title: title, markdown: request.markdown, tags: request.tags,
            downloadImage: { try downloader.download($0, kind: .image) },
            renderDiagram: { language, source in
                diagramIndex += 1
                let sourceURL = directory.appendingPathComponent("diagram-source-\(diagramIndex).\(language)")
                let outputURL = directory.appendingPathComponent("notescli-report-diagram-\(diagramIndex).png")
                guard let data = source.data(using: .utf8), data.count <= DiagramLimits.maxSourceBytes else {
                    throw NotesError("diagram_too_large", "A report diagram exceeds the \(DiagramLimits.maxSourceBytes)-byte limit.")
                }
                try data.write(to: sourceURL, options: [.atomic])
                do {
                    let options = try DiagramRenderOptions(width: 700, scale: 2, background: .auto, dark: false)
                    let rendered = try NotesDiagrams.DiagramRenderer().render(file: sourceURL, options: options)
                    try rendered.png.write(to: outputURL, options: [.atomic])
                    return outputURL
                } catch let error as DiagramError {
                    throw NotesError("diagram_render_failed", error.description)
                }
            },
            stageLocalResource: { try stager.stage($0) }
        )

        let trailing = try request.attachments.enumerated().map { index, value -> FrozenAttachmentInput in
            let source: URL
            if let url = URL(string: value), url.scheme != nil {
                guard url.scheme?.lowercased() == "https" else {
                    throw NotesError("insecure_remote_attachment", "Remote report attachments must use HTTPS.")
                }
                source = try downloader.download(url, kind: .attachment(index + 1))
            } else {
                let expanded = NSString(string: value).expandingTildeInPath
                let local = NSString(string: expanded).isAbsolutePath
                    ? URL(fileURLWithPath: expanded).standardizedFileURL
                    : URL(fileURLWithPath: expanded, relativeTo: request.assetBaseDirectory).standardizedFileURL
                source = try stager.stage(local)
            }
            return try FrozenAttachmentInput(file: source)
        }

        let created = try writer.createNote(
            title: title,
            input: NativeMarkdownInput(source: plan.markdown,
                                       assetBaseDirectory: request.assetBaseDirectory,
                                       trailingAttachments: trailing),
            folder: target.folder.id,
            allowShared: request.allowShared
        )
        guard let noteID = created.write.writeResult.noteID?.uuid else {
            throw NotesError("report_create_failed", created.write.writeResult.message ?? "The report returned no note identifier.")
        }
        do {
            guard created.write.writeResult.outcome == .verified else {
                throw NotesError("report_not_verified", created.write.writeResult.message ?? "Native report creation was not verified.")
            }
            let note = try SQLiteNotesStore(refresh: true).note(noteID)
            var requested = plan.requested
            requested.attachments += trailing.count
            let written = reportCounts(note)
            let mismatches = countMismatches(requested: requested, written: written)
            guard mismatches.isEmpty else {
                throw NotesError("report_verification_failed",
                                 "Native report readback did not match: \(mismatches.joined(separator: ", ")).")
            }
            var replacedID: String?
            if let old = existing.first {
                let deleted = try writer.deleteNote(old.summary.id.uuid, allowShared: request.allowShared)
                switch ReportReplacementDecision(deleteOutcome: deleted.writeResult.outcome) {
                case .complete:
                    replacedID = old.summary.id.uuid
                case .ambiguousKeepNewReport:
                    var ambiguous = created.write
                    ambiguous.writeResult.outcome = .unknown
                    ambiguous.writeResult.message = "The new report was verified, but deletion of old note \(old.summary.id.uuid) has an unknown outcome. The new report \(noteID) was kept; do not retry until both notes are inspected."
                    return NativeReportResult(
                        requested: requested, written: written,
                        degraded: ["old report deletion outcome unknown"], noteID: noteID,
                        noteLink: note.summary.deepLink ?? "applenotes://showNote?identifier=\(noteID)",
                        replacedNoteID: nil, write: ambiguous
                    )
                case .rollbackNewReport:
                    throw NotesError("report_replace_failed", "The new report was verified, but the old report could not be removed.")
                }
            }
            return NativeReportResult(
                requested: requested, written: written, degraded: [], noteID: noteID,
                noteLink: note.summary.deepLink ?? "applenotes://showNote?identifier=\(noteID)",
                replacedNoteID: replacedID, write: created.write
            )
        } catch {
            do {
                let cleanup = try writer.deleteNote(noteID, allowShared: request.allowShared)
                guard cleanup.writeResult.outcome == .verified else {
                    throw NotesError("report_rollback_failed",
                                     "Report creation failed and the partial note could not be removed: \(error.localizedDescription)")
                }
            } catch let cleanup as NotesError where cleanup.code == "report_rollback_failed" { throw cleanup }
            catch {
                throw NotesError("report_rollback_failed",
                                 "Report creation failed and the partial note could not be removed: \(error.localizedDescription)")
            }
            throw error
        }
    }

    public static func resolveTarget(title: String, folder reference: String?, replacing: Bool = false,
                                     reader: any NotesReading) throws -> ReportTargetResolution {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NotesError("invalid_title", "A report title is required.") }
        let folders = try reader.folders(account: nil).filter { !$0.isSmartFolder && !$0.isRecentlyDeleted }
        let matches: [Folder]
        if let reference {
            matches = folders.filter {
                $0.id.caseInsensitiveCompare(reference) == .orderedSame ||
                    $0.coreDataID?.caseInsensitiveCompare(reference) == .orderedSame ||
                    $0.name == reference || $0.path.joined(separator: " > ") == reference
            }
        } else {
            guard let location = try reader.defaultLocation() else {
                throw NotesError("folder_not_found", "The default Notes folder could not be resolved.")
            }
            matches = folders.filter { candidate in
                candidate.accountID == location.accountID &&
                    (location.folderID.map { folderID in
                        candidate.id.caseInsensitiveCompare(folderID) == .orderedSame
                    } ?? false)
            }
            if matches.isEmpty, let name = location.folderName {
                let named = folders.filter { $0.accountID == location.accountID && $0.name == name }
                guard named.count == 1 else {
                    throw NotesError(named.isEmpty ? "folder_not_found" : "ambiguous_folder",
                                     "The default Notes folder could not be resolved uniquely.")
                }
                return try resolvedTarget(title: title, folder: named[0], replacing: replacing, reader: reader)
            }
        }
        guard matches.count == 1 else {
            throw NotesError(matches.isEmpty ? "folder_not_found" : "ambiguous_folder",
                             "The report target folder must resolve uniquely.")
        }
        return try resolvedTarget(title: title, folder: matches[0], replacing: replacing, reader: reader)
    }

    private static func resolvedTarget(title: String, folder: Folder, replacing: Bool,
                                       reader: any NotesReading) throws -> ReportTargetResolution {
        let summaries = try reader.notes(NoteQuery(folder: folder.id, account: folder.accountID)).filter {
            $0.folderID == folder.id && $0.accountID == folder.accountID && $0.title == title && !$0.isDeleted
        }
        guard summaries.count <= 1 else {
            throw NotesError("ambiguous_report", "More than one note named \(title) already exists in the target folder.")
        }
        if replacing, summaries.isEmpty {
            throw NotesError("report_not_found", "No note named \(title) exists in the target folder to replace.")
        }
        return ReportTargetResolution(folder: folder, existing: try summaries.map { try reader.note($0.id.uuid) })
    }

    private func reportCounts(_ note: Note) -> ReportElementCounts {
        var counts = ReportElementCounts()
        let document = note.document
        let paragraphRuns = document?.runs.compactMap(\.paragraph) ?? []
        func uniqueParagraphs(_ kinds: Set<ParagraphStyle.Kind>) -> Int {
            let selected = paragraphRuns.filter { kinds.contains($0.kind) }
            let ids = Set(selected.compactMap(\.id))
            return ids.isEmpty ? selected.count : ids.count
        }
        counts.headings = uniqueParagraphs([.heading, .subheading])
        counts.tables = note.attachments.filter { $0.kind == "table" }.count
        counts.richLinks = note.attachments.filter { $0.kind == "link" }.count
        counts.images = note.attachments.filter { $0.kind == "image" }.count
        counts.remoteImages = note.attachments.filter { $0.filename?.hasPrefix("notescli-report-remote-") == true }.count
        counts.diagrams = note.attachments.filter { $0.filename?.hasPrefix("notescli-report-diagram-") == true }.count
        counts.tags = document?.runs.filter { $0.attachment?.typeUTI.lowercased().contains("hashtag") == true }.count ?? 0
        counts.checklists = uniqueParagraphs([.checklist])
        counts.attachments = note.attachments.filter { ["file", "pdf", "audio"].contains($0.kind) }.count
        counts.citations = document?.runs.filter { $0.font.superscript > 0 }.count ?? 0
        counts.dividers = note.attachments.filter { $0.isDivider == true || $0.kind == "divider" }.count
        counts.links = (document?.runs.filter { $0.link != nil }.count ?? 0) +
            (document?.tableCells?.values.flatMap { $0 }.flatMap { $0 }.flatMap(\.runs)
                .filter { $0.link != nil }.count ?? 0)
        return counts
    }

    private func countMismatches(requested: ReportElementCounts, written: ReportElementCounts) -> [String] {
        let pairs: [(String, Int, Int)] = [
            ("headings", requested.headings, written.headings), ("tables", requested.tables, written.tables),
            ("links", requested.links, written.links), ("rich links", requested.richLinks, written.richLinks),
            ("images", requested.images, written.images), ("remote images", requested.remoteImages, written.remoteImages),
            ("diagrams", requested.diagrams, written.diagrams), ("tags", requested.tags, written.tags),
            ("checklists", requested.checklists, written.checklists),
            ("attachments", requested.attachments, written.attachments),
            ("citations", requested.citations, written.citations), ("dividers", requested.dividers, written.dividers),
        ]
        return pairs.compactMap { name, expected, actual in expected == actual ? nil : "\(name) \(actual)/\(expected)" }
    }
}

private struct ReportAssetStager {
    let directory: URL
    let baseDirectory: URL

    func stage(_ value: String) throws -> URL {
        if let url = URL(string: value), url.isFileURL { return try stage(url) }
        let decoded = value.removingPercentEncoding ?? value
        let expanded = NSString(string: decoded).expandingTildeInPath
        let source = NSString(string: expanded).isAbsolutePath
            ? URL(fileURLWithPath: expanded).standardizedFileURL
            : URL(fileURLWithPath: expanded, relativeTo: baseDirectory).standardizedFileURL
        return try stage(source)
    }

    func stage(_ source: URL) throws -> URL {
        let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
        if resolved.path.hasPrefix(directory.path + "/") { return resolved }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: resolved.path) else {
            throw NotesError("invalid_file", "A report attachment is not a readable regular file.")
        }
        guard (values.fileSize ?? 0) <= FrozenAttachmentInput.maxBytes else {
            throw NotesError("attachment_too_large", "Attachments are limited to 200 MB.")
        }
        let data = try Data(contentsOf: resolved, options: .mappedIfSafe)
        guard !data.isEmpty else { throw NotesError("empty_attachment", "A report attachment has no bytes.") }
        let name = resolved.lastPathComponent.isEmpty ? "attachment.bin" : resolved.lastPathComponent
        let output = directory.appendingPathComponent("notescli-report-local-\(UUID().uuidString)-\(name)")
        try data.write(to: output, options: [.atomic])
        return output
    }
}

final class SafeReportDownloader: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    enum Kind { case image, attachment(Int) }

    private let directory: URL
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var failure: NotesError?
    private var finished = DispatchSemaphore(value: 0)
    private var maximumBytes = 0
    private var allowedPeers: [String: Set<String>] = [:]
    private var metricsValidated = false

    init(directory: URL) { self.directory = directory }

    func download(_ url: URL, kind: Kind) throws -> URL {
        let initialPeers = try Self.validatedAddresses(url)
        lock.withLock {
            data = Data(); response = nil; failure = nil; finished = DispatchSemaphore(value: 0)
            maximumBytes = kind.maximumBytes
            allowedPeers = [Self.originKey(url): initialPeers]
            metricsValidated = false
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("notescli/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        task.resume()
        guard finished.wait(timeout: .now() + 31) == .success else {
            task.cancel(); session.invalidateAndCancel()
            throw NotesError("remote_download_timeout", "The remote report asset timed out.")
        }
        session.finishTasksAndInvalidate()
        let value = lock.withLock { (data, response, failure) }
        if let failure = value.2 { throw failure }
        guard let response = value.1, (200..<300).contains(response.statusCode), !value.0.isEmpty else {
            throw NotesError("remote_download_failed", "The remote report asset returned no usable data.")
        }
        let mime = response.mimeType?.lowercased() ?? "application/octet-stream"
        if case .image = kind {
            guard mime.hasPrefix("image/"), let source = CGImageSourceCreateWithData(value.0 as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue > 0, height.intValue > 0, width.intValue <= 10_000, height.intValue <= 10_000,
                  width.int64Value * height.int64Value <= 50_000_000 else {
                throw NotesError("invalid_remote_image", "A remote report image failed type or dimension validation.")
            }
        } else if !Self.allowsAttachmentMIME(mime) {
            throw NotesError("unsafe_remote_attachment", "The remote attachment type \(mime) is not allowed.")
        }
        let suggested = Self.safeName(response.suggestedFilename)
        let ext = (suggested as NSString).pathExtension.isEmpty ? Self.extensionForMIME(mime) : (suggested as NSString).pathExtension
        let stem: String
        switch kind { case .image: stem = "notescli-report-remote-\(UUID().uuidString)"
        case .attachment(let index): stem = "notescli-report-attachment-\(index)" }
        let output = directory.appendingPathComponent(ext.isEmpty ? stem : stem + "." + ext)
        try value.0.write(to: output, options: [.atomic])
        return output
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, let url = http.url else {
                throw NotesError("remote_download_failed", "The remote asset returned a non-HTTP response.")
            }
            try Self.validateURLShape(url)
            guard lock.withLock({ allowedPeers[Self.originKey(url)] != nil }) else {
                throw NotesError("unsafe_remote_url", "The remote response did not match a validated destination.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw NotesError("remote_download_failed", "The remote server returned HTTP \(http.statusCode).")
            }
            let maximum = lock.withLock { maximumBytes }
            guard response.expectedContentLength < 0 || response.expectedContentLength <= maximum else {
                throw NotesError("remote_asset_too_large", "The remote report asset exceeds the \(maximum)-byte limit.")
            }
            lock.withLock { self.response = http }
            completionHandler(.allow)
        } catch {
            lock.withLock { failure = error as? NotesError ?? NotesError("remote_download_failed", error.localizedDescription) }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard failure == nil else { return true }
            guard Self.canAppend(
                currentCount: data.count,
                incomingCount: chunk.count,
                maximumBytes: maximumBytes
            ) else {
                failure = NotesError("remote_asset_too_large", "The remote report asset exceeds the \(maximumBytes)-byte limit.")
                return true
            }
            data.append(chunk)
            return false
        }
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url else { completionHandler(nil); return }
        do {
            let peers = try Self.validatedAddresses(url)
            lock.withLock { allowedPeers[Self.originKey(url)] = peers }
            completionHandler(request)
        }
        catch {
            lock.withLock { failure = error as? NotesError ?? NotesError("unsafe_remote_url", error.localizedDescription) }
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        do {
            guard !metrics.transactionMetrics.isEmpty else {
                throw NotesError("unsafe_remote_url", "The remote connection did not expose peer-address evidence.")
            }
            for transaction in metrics.transactionMetrics {
                guard let url = transaction.request.url,
                      let peer = transaction.remoteAddress else {
                    throw NotesError("unsafe_remote_url", "The remote connection did not expose its peer address.")
                }
                let allowed = lock.withLock { allowedPeers[Self.originKey(url)] }
                guard let allowed else {
                    throw NotesError("unsafe_remote_url", "The remote connection used an unvalidated redirect destination.")
                }
                try Self.requirePeerAddress(peer, allowed: allowed)
            }
            lock.withLock { metricsValidated = true }
        } catch {
            lock.withLock {
                failure = error as? NotesError ?? NotesError("unsafe_remote_url", error.localizedDescription)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            if let error, failure == nil { failure = NotesError("remote_download_failed", error.localizedDescription) }
            if error == nil, failure == nil, !metricsValidated {
                failure = NotesError("unsafe_remote_url", "The remote connection could not be matched to a validated peer address.")
            }
        }
        finished.signal()
    }

    private static let blockedMIME: Set<String> = [
        "application/x-mach-binary", "application/x-msdownload", "application/x-executable",
        "application/x-sh", "application/javascript", "text/javascript"
    ]

    static func canAppend(currentCount: Int, incomingCount: Int, maximumBytes: Int) -> Bool {
        currentCount >= 0 && incomingCount >= 0 && maximumBytes >= 0 &&
            incomingCount <= maximumBytes && currentCount <= maximumBytes - incomingCount
    }

    static func allowsAttachmentMIME(_ mime: String) -> Bool {
        !blockedMIME.contains(mime.lowercased())
    }

    static func validate(_ url: URL) throws {
        _ = try validatedAddresses(url)
    }

    static func validatedAddresses(_ url: URL) throws -> Set<String> {
        try validateURLShape(url)
        let host = url.host!
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &addresses) == 0, let first = addresses else {
            throw NotesError("remote_host_unresolved", "The remote report asset host could not be resolved.")
        }
        defer { freeaddrinfo(first) }
        var result: Set<String> = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let value = cursor {
            guard !isPrivate(value.pointee), let canonical = canonicalAddress(value.pointee) else {
                throw NotesError("unsafe_remote_url", "Remote report assets cannot resolve to a private or local address.")
            }
            result.insert(canonical)
            cursor = value.pointee.ai_next
        }
        guard !result.isEmpty else {
            throw NotesError("remote_host_unresolved", "The remote report asset host returned no usable address.")
        }
        return result
    }

    private static func validateURLShape(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw NotesError("unsafe_remote_url", "Remote report assets require an HTTPS URL without credentials or a nonstandard port.")
        }
        let lower = host.lowercased()
        guard lower != "localhost", !lower.hasSuffix(".localhost"), !lower.hasSuffix(".local") else {
            throw NotesError("unsafe_remote_url", "Remote report assets cannot use a local host.")
        }
    }

    private static func isPrivate(_ info: addrinfo) -> Bool {
        guard let address = info.ai_addr else { return true }
        if info.ai_family == AF_INET {
            let socket = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            let value = UInt32(bigEndian: socket.sin_addr.s_addr)
            let a = UInt8((value >> 24) & 0xff), b = UInt8((value >> 16) & 0xff)
            return a == 0 || a == 10 || a == 127 || (a == 169 && b == 254) ||
                (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) ||
                (a == 100 && (64...127).contains(b)) || a >= 224
        }
        if info.ai_family == AF_INET6 {
            let socket = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee
            let bytes = withUnsafeBytes(of: socket.sin6_addr) { Array($0) }
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let unspecified = bytes.allSatisfy { $0 == 0 }
            let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            let compatible = bytes.prefix(12).allSatisfy { $0 == 0 } && !loopback && !unspecified
            return loopback || unspecified || (bytes[0] & 0xfe) == 0xfc ||
                (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) || bytes[0] == 0xff ||
                mapped || compatible
        }
        return true
    }

    static func requirePeerAddress(_ peer: String, allowed: Set<String>) throws {
        guard let canonical = canonicalAddress(peer), allowed.contains(canonical) else {
            throw NotesError("unsafe_remote_url", "The remote connection peer did not match the validated DNS result.")
        }
    }

    private static func canonicalAddress(_ info: addrinfo) -> String? {
        guard let address = info.ai_addr else { return nil }
        return canonicalAddress(address, family: info.ai_family)
    }

    private static func canonicalAddress(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<end])
        } else if host.filter({ $0 == ":" }).count == 1, host.contains("."),
                  let separator = host.lastIndex(of: ":") {
            host = String(host[..<separator])
        }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            var socket = sockaddr_in()
            socket.sin_family = sa_family_t(AF_INET)
            socket.sin_addr = ipv4
            return withUnsafePointer(to: &socket) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { canonicalAddress($0, family: AF_INET) }
            }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            var socket = sockaddr_in6()
            socket.sin6_family = sa_family_t(AF_INET6)
            socket.sin6_addr = ipv6
            return withUnsafePointer(to: &socket) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { canonicalAddress($0, family: AF_INET6) }
            }
        }
        return nil
    }

    private static func canonicalAddress(_ address: UnsafePointer<sockaddr>, family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length: socklen_t = family == AF_INET ? socklen_t(MemoryLayout<sockaddr_in>.size)
            : socklen_t(MemoryLayout<sockaddr_in6>.size)
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private static func originKey(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        return "https://\(host):\(url.port ?? 443)"
    }

    private static func safeName(_ value: String?) -> String {
        let name = (value ?? "asset").split(separator: "/").last.map(String.init) ?? "asset"
        return name.filter { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    private static func extensionForMIME(_ mime: String) -> String {
        UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
    }
}

extension SafeReportDownloader.Kind {
    var maximumBytes: Int {
        switch self { case .image: 12 * 1024 * 1024; case .attachment: 25 * 1024 * 1024 }
    }
}
