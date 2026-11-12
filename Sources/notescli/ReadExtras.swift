import AppKit
import ArgumentParser
import Foundation
import NotesCore
import NotesIndex
import NotesStore

struct IndexStatusOutput: Encodable {
    var index: NotesIndexStatus
    var job: NotesIndexJobStatus
}

let supportedAttachmentKinds = Set(["image", "audio", "pdf", "scan", "drawing", "table", "checklist", "link", "file"])
func parseAttachmentKinds(_ values: [String]) throws -> [String] {
    let result = values.flatMap { $0.split(separator: "|").map { String($0).lowercased() } }
    guard result.allSatisfy(supportedAttachmentKinds.contains) else {
        throw NotesError("invalid_attachment_kind", "Use image, audio, pdf, scan, drawing, table, checklist, link, or file.")
    }
    return result
}

struct NotePage: Encodable {
    var notes: [NoteSummary]
    var nextCursor: String?
}
struct SearchHitPage: Encodable { var hits: [NotesSearchHit]; var nextCursor: String? }

enum ReadCursorPaging {
    static func payload(_ note: NoteSummary, sort: NoteSort) -> StableCursorPayload {
        let key: String
        let secondary: String?
        switch sort {
        case .modified: key = String(note.modified?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude); secondary = nil
        case .created: key = String(note.created?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude); secondary = nil
        case .opened: key = String(note.lastOpened?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude); secondary = String(note.modified?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude)
        case .title: key = note.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")); secondary = nil
        case .display: key = String(note.displayOrder ?? Double.greatestFiniteMagnitude); secondary = nil
        }
        return StableCursorPayload(sort: sort.rawValue, key: key, secondary: secondary, id: note.id.uuid)
    }

    static func page(_ notes: [NoteSummary], sort: NoteSort, cursor: String?, limit: Int?) throws -> NotePage {
        var values = notes
        if let cursor {
            let cursorPayload = try StableCursor.decode(cursor)
            guard cursorPayload.sort == sort.rawValue else { throw NotesError("invalid_cursor", "The cursor uses a different sort order.") }
            values = values.filter { follows(payload($0, sort: sort), cursorPayload) }
        }
        let count = limit ?? values.count
        let selected = Array(values.prefix(count))
        let next = selected.count < values.count ? try selected.last.map { try StableCursor.encode(payload($0, sort: sort)) } : nil
        return NotePage(notes: selected, nextCursor: next)
    }

    static func searchPage(_ hits: [NotesSearchHit], cursor: String?, limit: Int?) throws -> SearchHitPage {
        func payload(_ hit: NotesSearchHit) -> StableCursorPayload {
            StableCursorPayload(sort: "search", key: String(hit.score), secondary: String(hit.modified?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude), id: hit.noteID)
        }
        var values = hits
        if let cursor {
            let decoded = try StableCursor.decode(cursor)
            guard decoded.sort == "search" else { throw NotesError("invalid_cursor", "The cursor is not a search cursor.") }
            values = values.filter { hit in
                let value = payload(hit), score = Double(value.key) ?? 0, oldScore = Double(decoded.key) ?? 0
                let modified = Double(value.secondary ?? "") ?? 0, oldModified = Double(decoded.secondary ?? "") ?? 0
                return score < oldScore || (score == oldScore && (modified < oldModified || (modified == oldModified && value.id < decoded.id)))
            }
        }
        let selected = Array(values.prefix(limit ?? values.count))
        let next = selected.count < values.count ? try selected.last.map { try StableCursor.encode(payload($0)) } : nil
        return SearchHitPage(hits: selected, nextCursor: next)
    }

    static func fuzzyPage(_ ranked: [(summary: NoteSummary, score: Int)], cursor: String?, limit: Int?) throws -> NotePage {
        func payload(_ value: (summary: NoteSummary, score: Int)) -> StableCursorPayload {
            StableCursorPayload(sort: "fuzzy", key: String(value.score), id: value.summary.id.uuid)
        }
        var values = ranked
        if let cursor {
            let decoded = try StableCursor.decode(cursor)
            guard decoded.sort == "fuzzy" else { throw NotesError("invalid_cursor", "The cursor is not a fuzzy-search cursor.") }
            values = values.filter { value in
                let score = value.score, oldScore = Int(decoded.key) ?? 0
                return score < oldScore || (score == oldScore && value.summary.id.uuid > decoded.id)
            }
        }
        let selected = Array(values.prefix(limit ?? values.count))
        let next = selected.count < values.count ? try selected.last.map { try StableCursor.encode(payload($0)) } : nil
        return NotePage(notes: selected.map(\.summary), nextCursor: next)
    }

    private static func follows(_ candidate: StableCursorPayload, _ cursor: StableCursorPayload) -> Bool {
        switch NoteSort(rawValue: cursor.sort) ?? .modified {
        case .modified, .created:
            let left = Double(candidate.key) ?? 0, right = Double(cursor.key) ?? 0
            return left < right || (left == right && candidate.id < cursor.id)
        case .opened:
            let left = Double(candidate.key) ?? 0, right = Double(cursor.key) ?? 0
            let leftSecondary = Double(candidate.secondary ?? "") ?? 0, rightSecondary = Double(cursor.secondary ?? "") ?? 0
            return left < right || (left == right && (leftSecondary < rightSecondary || (leftSecondary == rightSecondary && candidate.id < cursor.id)))
        case .title:
            return candidate.key > cursor.key || (candidate.key == cursor.key && candidate.id > cursor.id)
        case .display:
            let left = Double(candidate.key) ?? 0, right = Double(cursor.key) ?? 0
            return left > right || (left == right && candidate.id > cursor.id)
        }
    }
}

struct AnchorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "anchor", subcommands: [AnchorAdd.self, AnchorList.self, AnchorResolve.self, AnchorPrune.self])
}
struct AnchorAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add")
    @OptionGroup var options: GlobalOptions
    @Argument var note: String
    @Option var heading: String?
    @Option var offset: Int?
    func validate() throws { guard (heading != nil) != (offset != nil) else { throw ValidationError("Choose one of --heading or --offset.") } }
    func run() throws {
        let reader = try options.backends().reader
        let value = try ParagraphAnchorStore().add(note: reader.note(note), heading: heading, offset: offset)
        if options.json { try Output.json(value) } else { Output.table(["ID", "NOTE", "OFFSET"], [[value.id, value.noteShortID ?? value.noteID, String(value.originalOffset)]]) }
    }
}
struct AnchorList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var options: GlobalOptions
    @Argument var note: String?
    func run() throws {
        let values = try ParagraphAnchorStore().list(noteRef: note)
        if options.json { try Output.json(values) }
        else { Output.table(["ID", "NOTE", "OFFSET", "HEADING"], values.map { [$0.id, $0.noteShortID ?? $0.noteID, String($0.currentOffset ?? $0.originalOffset), $0.heading ?? ""] }) }
    }
}
struct AnchorResolve: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resolve")
    @OptionGroup var options: GlobalOptions
    @Argument var id: String
    func run() throws {
        let value = try ParagraphAnchorStore().resolve(id, reader: options.backends().reader)
        if options.json { try Output.json(value) }
        else { Output.table(["ID", "NOTE", "OFFSET", "LENGTH", "RELOCATED"], [[value.anchor.id, value.anchor.noteShortID ?? value.anchor.noteID, String(value.offset), String(value.length), String(value.relocated)]]) }
    }
}
struct AnchorPrune: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune")
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let count = try ParagraphAnchorStore().prune(reader: options.backends().reader)
        if options.json { try Output.json(["pruned": count]) } else { Output.table(["PRUNED"], [[String(count)]]) }
    }
}

struct WaitSyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wait-sync")
    @OptionGroup var options: GlobalOptions
    @Argument var note: String
    @Option var timeout: Double = 30
    func validate() throws { guard timeout >= 0 else { throw ValidationError("--timeout must be nonnegative.") } }
    func run() throws {
        let resolved = try options.backends().reader.summary(note)
        let value = try NotesSyncWaiter.wait(for: resolved.id.uuid, timeout: timeout)
        if options.json { try Output.json(value) }
        else { Output.table(["NOTE", "STATUS", "SECONDS"], [[resolved.id.shortID ?? resolved.id.uuid, value.status, String(format: "%.2f", value.elapsed)]]) }
        if value.status != "synced" { throw NotesError("sync_timeout", "The note was not acknowledged before the timeout.") }
    }
}

enum TableReadFormat: String, ExpressibleByArgument { case markdown, json, csv }
struct ReadTableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "table", subcommands: [TableShow.self, TableCreate.self, TableSet.self, TableFormatCell.self, TableAddRow.self, TableAddColumn.self, TableRemoveRow.self, TableRemoveColumn.self, TableConvertToText.self])
}
struct TableShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show")
    @OptionGroup var options: GlobalOptions
    @Argument var note: String
    @Option var attachment: String?
    @Option var format: TableReadFormat = .markdown
    @Flag(help: "Return decoded text and attribute runs for every cell as JSON.") var rich = false
    func run() throws {
        let value = try options.backends().reader.note(note)
        guard let tables = value.document?.tables, !tables.isEmpty else { throw NotesError("table_not_found", "The note has no decoded table.") }
        if rich {
            let cells = value.document?.tableCells ?? [:]
            if let attachment {
                guard let selected = cells[attachment] else { throw NotesError("table_not_found", "No rich table matches the attachment id.") }
                try Output.json([attachment: selected])
            } else { try Output.json(cells) }
            return
        }
        let selected: [(String, [[String]])]
        if let attachment {
            guard let rows = tables[attachment] else { throw NotesError("table_not_found", "No table matches the attachment id.") }
            selected = [(attachment, rows)]
        } else if tables.count == 1 { selected = [tables.first!] }
        else { selected = tables.sorted { $0.key < $1.key } }
        if options.json || format == .json { try Output.json(Dictionary(uniqueKeysWithValues: selected)); return }
        let chunks = selected.map { id, rows -> String in
            switch format {
            case .json: return ""
            case .csv: return rows.map { $0.map(csv).joined(separator: ",") }.joined(separator: "\n")
            case .markdown:
                guard let first = rows.first else { return "" }
                func row(_ cells: [String]) -> String { "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }.joined(separator: " | ") + " |" }
                return ([row(first), "| " + first.map { _ in "---" }.joined(separator: " | ") + " |"] + rows.dropFirst().map(row)).joined(separator: "\n")
            }
        }
        if !options.quiet { print(chunks.joined(separator: "\n\n")) }
    }
    private func csv(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

enum ReadOpen {
    static func account(_ account: Account) throws { try select(kind: "account", id: account.id, name: account.name) }
    static func folder(_ folder: Folder) throws { try select(kind: "folder", id: folder.coreDataID ?? folder.id, name: folder.name) }
    private static func select(kind: String, id: String, name: String) throws {
        let source = #"function run(argv){const n=Application('com.apple.Notes');n.activate();const k=argv[0],id=argv[1],name=argv[2];const xs=k==='account'?n.accounts():n.folders();const x=xs.find(v=>String(v.id())===id)||xs.find(v=>String(v.name())===name);if(!x)throw new Error('not found');n.show(x);}"#
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source, kind, id, name]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NotesError("open_failed", "Notes could not select the item.") }
    }
    static func attachment(_ attachment: Attachment, reveal: Bool) throws {
        guard let path = attachment.filePath ?? attachment.fallbackRasterPath else { throw NotesError("attachment_unavailable", "The attachment file is not downloaded.") }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = reveal ? ["-R", path] : [path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NotesError("open_failed", "The attachment could not be opened.") }
    }
}
