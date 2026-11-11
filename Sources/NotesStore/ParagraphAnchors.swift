import Foundation
import SQLite3
import NotesCore

private let anchorTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ParagraphAnchor: Codable, Sendable, Hashable {
    public var id: String
    public var noteID: String
    public var noteShortID: String?
    public var heading: String?
    public var originalOffset: Int
    public var currentOffset: Int?
    public var createdAt: Date
}

public struct AnchorResolution: Codable, Sendable, Hashable {
    public var anchor: ParagraphAnchor
    public var offset: Int
    public var length: Int
    public var relocated: Bool
}

public final class ParagraphAnchorStore: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotesCLI/anchors.sqlite")
    }
    private let url: URL
    private let lock = NSLock()

    public init(url: URL = ParagraphAnchorStore.defaultURL) { self.url = url }

    public func add(note: Note, heading: String? = nil, offset: Int? = nil) throws -> ParagraphAnchor {
        guard (heading != nil) != (offset != nil) else { throw NotesError("invalid_anchor", "Choose one of heading or offset.") }
        guard let document = note.document else { throw NotesError("note_locked", "The note body is unavailable.") }
        let selectedOffset: Int
        if let heading {
            let matches = Self.flatten(document.outline()).filter { $0.title.caseInsensitiveCompare(heading) == .orderedSame }
            guard !matches.isEmpty else { throw NotesError("heading_not_found", "No heading matches the anchor.") }
            guard matches.count == 1 else { throw NotesError("ambiguous_heading", "More than one heading matches the anchor.") }
            selectedOffset = matches[0].offset
        } else {
            selectedOffset = offset!
        }
        let paragraph = try Self.paragraph(in: document.text, containing: selectedOffset)
        let anchor = ParagraphAnchor(id: "a-" + UUID().uuidString.lowercased(), noteID: note.summary.id.uuid,
                                     noteShortID: note.summary.id.shortID, heading: heading,
                                     originalOffset: paragraph.offset, currentOffset: paragraph.offset, createdAt: Date())
        lock.lock(); defer { lock.unlock() }
        let db = try open(); defer { sqlite3_close(db) }
        try run(db, "INSERT INTO anchors(id,note_id,note_short_id,heading,original_offset,current_offset,fingerprint,text,created_at) VALUES(?,?,?,?,?,?,?,?,?)", [
            anchor.id, anchor.noteID, anchor.noteShortID, anchor.heading, String(anchor.originalOffset), String(paragraph.offset),
            Self.fingerprint(paragraph.text), Self.normalized(paragraph.text), String(anchor.createdAt.timeIntervalSince1970)
        ])
        return anchor
    }

    public func list(noteRef: String? = nil) throws -> [ParagraphAnchor] {
        lock.lock(); defer { lock.unlock() }
        let db = try open(); defer { sqlite3_close(db) }
        let rows = try query(db, "SELECT id,note_id,note_short_id,heading,original_offset,current_offset,created_at FROM anchors ORDER BY created_at,id", [])
        let shortRef = noteRef.map { $0.allSatisfy(\.isNumber) ? "n\($0)" : $0 }
        return rows.compactMap(Self.anchor).filter { anchor in
            guard let noteRef, let shortRef else { return true }
            return anchor.noteID.caseInsensitiveCompare(noteRef) == .orderedSame || anchor.noteShortID?.caseInsensitiveCompare(shortRef) == .orderedSame
        }
    }

    public func resolve(_ id: String, reader: any NotesReading) throws -> AnchorResolution {
        lock.lock(); defer { lock.unlock() }
        let db = try open(); defer { sqlite3_close(db) }
        guard let row = try query(db, "SELECT * FROM anchors WHERE id=?", [id]).first,
              let anchor = Self.anchor(row), let stored = row["text"], let fingerprint = row["fingerprint"] else {
            throw NotesError("anchor_not_found", "No anchor matches the reference.")
        }
        let note = try reader.note(anchor.noteID)
        guard let text = note.document?.text else { throw NotesError("note_locked", "The note body is unavailable.") }
        let paragraphs = Self.paragraphs(text)
        let exact = paragraphs.filter { Self.fingerprint($0.text) == fingerprint && Self.normalized($0.text) == stored }
        let preferred = anchor.currentOffset ?? anchor.originalOffset
        let exactMatch = exact.min { abs($0.offset - preferred) < abs($1.offset - preferred) }
        let scored: [(paragraph: Paragraph, score: Double)] = paragraphs.map {
            ($0, Self.similarity(stored, Self.normalized($0.text)))
        }.filter { $0.score >= 0.55 }
        let fuzzyMatch = scored.sorted {
            $0.score == $1.score
                ? abs($0.paragraph.offset - preferred) < abs($1.paragraph.offset - preferred)
                : $0.score > $1.score
        }.first?.paragraph
        let match = exactMatch ?? fuzzyMatch
        guard let match else { throw NotesError("anchor_unresolved", "The anchored paragraph could not be found after the note changed.") }
        try run(db, "UPDATE anchors SET current_offset=? WHERE id=?", [String(match.offset), id])
        var updated = anchor; updated.currentOffset = match.offset
        return AnchorResolution(anchor: updated, offset: match.offset, length: match.length, relocated: match.offset != anchor.originalOffset)
    }

    @discardableResult
    public func prune(reader: any NotesReading) throws -> Int {
        let anchors = try list()
        var removed = 0
        for anchor in anchors {
            do { _ = try resolve(anchor.id, reader: reader) }
            catch let error as NotesError where ["note_not_found", "anchor_unresolved"].contains(error.code) {
                lock.lock(); defer { lock.unlock() }
                let db = try open(); defer { sqlite3_close(db) }
                try run(db, "DELETE FROM anchors WHERE id=?", [anchor.id]); removed += 1
            }
        }
        return removed
    }

    private func open() throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { throw NotesError("anchor_store_failed", "Cannot open the anchor database.") }
        guard sqlite3_exec(db, "PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS anchors(id TEXT PRIMARY KEY,note_id TEXT NOT NULL,note_short_id TEXT,heading TEXT,original_offset INTEGER NOT NULL,current_offset INTEGER,fingerprint TEXT NOT NULL,text TEXT NOT NULL,created_at REAL NOT NULL);", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); throw NotesError("anchor_store_failed", "Cannot prepare the anchor database.")
        }
        return db
    }

    private func run(_ db: OpaquePointer, _ sql: String, _ values: [String?]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NotesError("anchor_store_failed", "Cannot prepare an anchor operation.") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            if let value { sqlite3_bind_text(statement, Int32(index + 1), value, -1, anchorTransient) }
            else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NotesError("anchor_store_failed", "Cannot save the anchor operation.") }
    }

    private func query(_ db: OpaquePointer, _ sql: String, _ values: [String?]) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NotesError("anchor_store_failed", "Cannot prepare an anchor query.") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            if let value { sqlite3_bind_text(statement, Int32(index + 1), value, -1, anchorTransient) }
            else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
        var output: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, column) != SQLITE_NULL {
                if let value = sqlite3_column_text(statement, column) {
                    row[String(cString: sqlite3_column_name(statement, column))] = String(cString: value)
                }
            }
            output.append(row)
        }
        return output
    }

    private static func anchor(_ row: [String: String]) -> ParagraphAnchor? {
        guard let id = row["id"], let noteID = row["note_id"], let original = row["original_offset"].flatMap(Int.init),
              let created = row["created_at"].flatMap(Double.init) else { return nil }
        return ParagraphAnchor(id: id, noteID: noteID, noteShortID: row["note_short_id"], heading: row["heading"],
                               originalOffset: original, currentOffset: row["current_offset"].flatMap(Int.init),
                               createdAt: Date(timeIntervalSince1970: created))
    }

    private struct Paragraph { var offset: Int; var length: Int; var text: String }
    private static func paragraphs(_ text: String) -> [Paragraph] {
        let source = text as NSString
        var output: [Paragraph] = [], start = 0
        for line in text.components(separatedBy: "\n") {
            let length = line.utf16.count
            output.append(Paragraph(offset: start, length: length, text: source.substring(with: NSRange(location: start, length: length))))
            start += length + 1
        }
        return output
    }
    private static func paragraph(in text: String, containing offset: Int) throws -> Paragraph {
        guard offset >= 0, offset <= text.utf16.count else { throw NotesError("invalid_offset", "The UTF-16 offset is outside the note.") }
        return paragraphs(text).first { offset >= $0.offset && offset <= $0.offset + $0.length }
            ?? Paragraph(offset: text.utf16.count, length: 0, text: "")
    }
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func fingerprint(_ text: String) -> String {
        normalized(text).utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }.description
    }
    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(lhs.split(separator: " ")), right = Set(rhs.split(separator: " "))
        if left.isEmpty && right.isEmpty { return 1 }
        return Double(left.intersection(right).count) / Double(max(1, left.union(right).count))
    }
    private static func flatten(_ nodes: [NoteOutlineNode]) -> [NoteOutlineNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }
}
