import Foundation
import NotesCore

package struct EditorTemplate: Codable, Equatable, Sendable {
    package let id: UUID
    package let title: String
    package let folder: [String]
}

package struct EditorTemplatePayload: Codable, Equatable, Sendable {
    package let text: String
    package let markdown: String?
    package var richText: EditorTemplateRichText? = nil
}

package struct EditorTemplateStore {
    private let reader: any NotesReading

    package init(reader: any NotesReading) { self.reader = reader }

    private func destination(_ id: UUID) throws -> NoteSummary {
        let note = try reader.summary("id:" + id.uuidString)
        guard UUID(uuidString: note.id.uuid) == id, !note.accountID.isEmpty, !note.isLocked, !note.isDeleted else {
            throw NotesError("template_destination_unavailable", "The active note is not available for template insertion.")
        }
        return note
    }

    private func folders(_ destination: NoteSummary) throws -> [Folder] {
        try reader.folders(account: destination.accountID).filter {
            $0.accountID == destination.accountID && !$0.isRecentlyDeleted && !$0.isSmartFolder &&
                $0.name.compare("Templates", options: [.caseInsensitive]) == .orderedSame
        }
    }

    package func catalog(destination id: UUID) throws -> [EditorTemplate] {
        let note = try destination(id)
        var templates: [EditorTemplate] = []
        for folder in try folders(note) {
            for row in try reader.notes(NoteQuery(folder: folder.id, account: note.accountID)) {
                guard row.accountID == note.accountID, row.folderID == folder.id, !row.isLocked, !row.isDeleted,
                      !row.title.isEmpty, let key = UUID(uuidString: row.id.uuid), key != id else { continue }
                templates.append(EditorTemplate(id: key, title: row.title, folder: folder.path))
            }
        }
        return templates.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    package func render(source: UUID, destination id: UUID) throws -> EditorTemplatePayload {
        let target = try destination(id)
        guard source != id else { throw NotesError("template_source_unavailable", "Choose a different note as the template.") }
        let ref = "id:" + source.uuidString
        let eligibleFolders = try folders(target).map(\.id)
        func eligible(_ row: NoteSummary) -> Bool {
            guard let folderID = row.folderID else { return false }
            return UUID(uuidString: row.id.uuid) == source && row.accountID == target.accountID
                && !row.isDeleted && !row.isLocked && eligibleFolders.contains(folderID)
        }
        let unavailable = NotesError("template_source_unavailable", "The source is not in a Templates folder in this account.")
        guard try eligible(reader.summary(ref)) else {
            throw unavailable
        }
        let sourceNote = try reader.note(ref)
        guard eligible(sourceNote.summary) else { throw unavailable }
        return try Self.payload(sourceNote)
    }

    package static func payload(_ source: Note, date: Date = Date(), locale: Locale = .current,
                        timeZone: TimeZone = .current) throws -> EditorTemplatePayload {
        let unavailable = NotesError("template_source_unavailable", "The template body is unavailable.")
        guard let document = source.document else { throw unavailable }
        guard document.text.utf16.count <= 64_000 else {
            throw NotesError("template_too_large", "Use a template with at most 64,000 UTF-16 code units.")
        }
        let hasRuns = !document.runs.isEmpty
        let total = document.text.utf16.count
        var cursor = 0
        var entries: [(range: NSRange, run: AttributeRun)] = []
        for run in document.runs {
            guard run.length >= 0, run.length <= total - cursor else { throw unavailable }
            entries.append((NSRange(location: cursor, length: run.length), run))
            cursor += run.length
        }
        if hasRuns && cursor != total { throw unavailable }
        if !hasRuns { entries = [(NSRange(location: 0, length: total), AttributeRun(length: total))] }
        let text = document.text
        let firstEnd = text.firstIndex(where: \.isNewline) ?? text.endIndex
        let firstLine = String(text[..<firstEnd])
        let isTitle = entries.first(where: { $0.range.length > 0 })?.run.paragraph?.kind == .title
            || firstLine == source.summary.title
        let bodyIndex = isTitle ? (firstEnd == text.endIndex ? firstEnd : text.index(after: firstEnd)) : text.startIndex
        let start = text[..<bodyIndex].utf16.count
        guard start < total else { throw NotesError("template_empty", "The template has no body below its title.") }
        let ns = text as NSString
        let body = NSRange(location: start, length: total - start)
        let pattern = try NSRegularExpression(pattern: #"(?<![\p{L}\p{M}\p{N}_@\\])@(?:today|date)(?![\p{L}\p{M}\p{N}_])"#)
        let matches = pattern.matches(in: text, range: body)
        let protectedRuns = entries.filter { _, run in run.link != nil || run.paragraph?.kind == .monospaced }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let links = matches.isEmpty ? [] : detector.matches(in: text, range: body)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        let dateText = formatter.string(from: date)
        var output = ""
        var runs: [AttributeRun] = []
        var entry = 0
        func append(_ value: String, as original: AttributeRun) {
            guard !value.isEmpty else { return }
            var run = original
            run.length = value.utf16.count
            output += value
            runs.append(run)
        }
        func appendOriginal(from lower: Int, to upper: Int) {
            while entry < entries.count && entries[entry].range.location < upper {
                let (range, run) = entries[entry]
                let clipped = NSIntersectionRange(range, NSRange(location: lower, length: upper - lower))
                if clipped.length > 0 { append(ns.substring(with: clipped), as: run) }
                if NSMaxRange(range) <= upper { entry += 1 } else { break }
            }
        }
        var consumed = start
        var protectedIndex = 0
        var linkIndex = 0
        for match in matches {
            let token = match.range
            while protectedIndex < protectedRuns.count, NSMaxRange(protectedRuns[protectedIndex].range) <= token.location {
                protectedIndex += 1
            }
            while linkIndex < links.count, NSMaxRange(links[linkIndex].range) <= token.location {
                linkIndex += 1
            }
            if protectedIndex < protectedRuns.count, NSIntersectionRange(protectedRuns[protectedIndex].range, token).length > 0 {
                continue
            }
            if linkIndex < links.count, NSIntersectionRange(links[linkIndex].range, token).length > 0 { continue }
            appendOriginal(from: consumed, to: match.range.location)
            while entry < entries.count && NSMaxRange(entries[entry].range) <= match.range.location { entry += 1 }
            if entry < entries.count { append(dateText, as: entries[entry].run) }
            consumed = NSMaxRange(match.range)
        }
        appendOriginal(from: consumed, to: total)
        let expanded = NoteDocument(text: output, runs: runs)
        if !source.attachments.isEmpty || document.text.contains("\u{fffc}") || document.runs.contains(where: { $0.attachment != nil }) {
            return EditorTemplatePayload(text: output, markdown: nil,
                                         richText: try EditorTemplateRichText.make(expanded, attachments: source.attachments))
        }
        let rich = runs.contains {
            $0.paragraph.map { $0.kind != .body || $0.indent != 0 || $0.alignment != nil || $0.writingDirection != nil } == true
                || $0.font != FontStyle() || $0.link != nil || $0.color != nil || $0.highlight != nil
        }
        let richText = rich ? EditorTemplateRichText.styledText(expanded) : nil
        // Notes' Markdown importer cannot represent all of the original style.
        let markdown = rich && !runs.contains(where: EditorTemplateRichText.RunStyle.needsRichPaste)
            ? NoteRenderer.markdown(expanded) : nil
        return EditorTemplatePayload(text: output, markdown: markdown, richText: richText)
    }
}
