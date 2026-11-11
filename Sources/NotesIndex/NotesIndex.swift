import Foundation
import SQLite3
import NotesCore

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct NotesIndexStatus: Codable, Sendable {
    public var path: String
    public var noteCount: Int
    public var fileSize: Int64
    public var lastIndexed: Date?
}

public struct NotesSearchHit: Codable, Sendable {
    public var noteID: String
    public var title: String
    public var folder: String
    public var snippet: String
    public var highlights: [String]
    public var score: Double
    public var modified: Date?
}

public final class LocalNotesIndex: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/NotesCLI/index.sqlite")
    }
    private let url: URL
    private let lock = NSLock()

    public init(url: URL = LocalNotesIndex.defaultURL) { self.url = url }

    @discardableResult
    public func update(from reader: any NotesReading, rebuild: Bool = false) throws -> NotesIndexStatus {
        lock.lock(); defer { lock.unlock() }
        let db = try open(rebuild: rebuild); defer { sqlite3_close(db) }
        let summaries = try reader.notes(NoteQuery(includeDeleted: false))
        let existing = try rows(db, "SELECT id, fingerprint FROM notes").reduce(into: [String: String]()) { result, row in
            if let id = row["id"], let fingerprint = row["fingerprint"] { result[id] = fingerprint }
        }
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let current = Set(summaries.map { $0.id.uuid })
            for stale in Set(existing.keys).subtracting(current) {
                try run(db, "DELETE FROM notes WHERE id = ?", [.text(stale)])
                try run(db, "DELETE FROM notes_fts WHERE id = ?", [.text(stale)])
            }
            for summary in summaries {
                let fingerprint = Self.fingerprint(summary)
                if existing[summary.id.uuid] == fingerprint { continue }
                let note = try? reader.note(summary.id.uuid)
                let attachments = (try? reader.attachments(summary.id.uuid)) ?? note?.attachments ?? []
                let body = note?.document?.plainText(attachments: attachments) ?? summary.snippet
                let ocr = attachments.compactMap { [$0.ocrText, $0.additionalIndexableText, $0.imageClassification, $0.imageSummary].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n")
                let handwriting = attachments.compactMap(\.handwritingText).joined(separator: "\n")
                let transcript = attachments.compactMap { [$0.transcriptText, $0.recording?.summary, $0.recording?.topLineSummary].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n")
                let pdf = attachments.compactMap(\.pdfText).joined(separator: "\n")
                let kinds = Array(Set(attachments.map(\.kind) + (attachments.isEmpty ? [] : ["attachment"]) + (summary.hasChecklist ? ["checklist"] : []))).sorted().joined(separator: ",")
                let folder = summary.folderPath.joined(separator: " > ")
                try run(db, "INSERT OR REPLACE INTO notes(id,fingerprint,title,body,folder,tags,kinds,created,modified,pinned,locked,ocr,handwriting,transcript,pdf) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    .text(summary.id.uuid), .text(fingerprint), .text(summary.title), .text(body), .text(folder), .text(summary.tags.joined(separator: " ")), .text(kinds),
                    .double(summary.created?.timeIntervalSince1970), .double(summary.modified?.timeIntervalSince1970), .integer(summary.isPinned ? 1 : 0), .integer(summary.isLocked ? 1 : 0),
                    .text(ocr), .text(handwriting), .text(transcript), .text(pdf)
                ])
                try run(db, "DELETE FROM notes_fts WHERE id = ?", [.text(summary.id.uuid)])
                try run(db, "INSERT INTO notes_fts(id,title,body,ocr,handwriting,transcript,pdf,tags) VALUES(?,?,?,?,?,?,?,?)", [
                    .text(summary.id.uuid), .text(summary.title), .text(body), .text(ocr), .text(handwriting), .text(transcript), .text(pdf), .text(summary.tags.joined(separator: " "))
                ])
            }
            try run(db, "INSERT OR REPLACE INTO metadata(key,value) VALUES('last_indexed',?)", [.text(String(Date().timeIntervalSince1970))])
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK"); throw error
        }
        return try status(db)
    }

    public func status() throws -> NotesIndexStatus {
        lock.lock(); defer { lock.unlock() }
        let db = try open(rebuild: false); defer { sqlite3_close(db) }
        return try status(db)
    }

    public func search(_ query: String, folder: String? = nil, limit: Int = 50, now: Date = Date()) throws -> [NotesSearchHit] {
        guard limit >= 0 else { throw NotesError("invalid_limit", "The limit must be zero or greater.") }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NotesError("invalid_query", "The search query is empty.") }
        lock.lock(); defer { lock.unlock() }
        let db = try open(rebuild: false); defer { sqlite3_close(db) }
        var parser = try QueryParser(query)
        let expression = try parser.parse()
        var values: [Value] = []
        var whereSQL = try compile(expression, values: &values, now: now)
        if let folder, !folder.isEmpty { whereSQL = "(\(whereSQL)) AND folder LIKE ? COLLATE NOCASE"; values.append(.text("%\(folder)%")) }
        let sql = "SELECT id,title,body,folder,tags,kinds,modified,ocr,handwriting,transcript,pdf FROM notes WHERE \(whereSQL) LIMIT 5000"
        var found = try queryRows(db, sql, values)
        let terms = expression.terms
        var typo = false
        if found.isEmpty, expression.isPlainText {
            let fuzzySQL = "SELECT id,title,body,folder,tags,kinds,modified,ocr,handwriting,transcript,pdf FROM notes" + (folder?.isEmpty == false ? " WHERE folder LIKE ? COLLATE NOCASE" : "") + " LIMIT 5000"
            let fuzzyValues: [Value] = folder?.isEmpty == false ? [.text("%\(folder!)%")] : []
            found = try queryRows(db, fuzzySQL, fuzzyValues)
                .filter { Self.fuzzyMatch(terms, in: [$0["title"], $0["body"], $0["tags"]].compactMap { $0 }.joined(separator: " ")) }
            typo = true
        }
        let hits = found.map { row -> NotesSearchHit in
            let title = row["title"] ?? "", body = [row["body"], row["ocr"], row["handwriting"], row["transcript"], row["pdf"]].compactMap { $0 }.joined(separator: "\n")
            let titleMatches = terms.reduce(0) { $0 + Self.occurrences($1, in: title) }
            let bodyMatches = terms.reduce(0) { $0 + Self.occurrences($1, in: body) }
            let score = typo ? 1 : Double(titleMatches * 100 + bodyMatches * 10 + terms.count)
            let snippet = Self.snippet(body.isEmpty ? title : body, terms: terms)
            return NotesSearchHit(noteID: row["id"] ?? "", title: title, folder: row["folder"] ?? "", snippet: snippet.plain,
                                  highlights: snippet.highlights, score: score,
                                  modified: row["modified"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
        }.sorted { ($0.score, $0.modified ?? .distantPast, $0.noteID) > ($1.score, $1.modified ?? .distantPast, $1.noteID) }
        return Array(hits.prefix(limit))
    }

    private func open(rebuild: Bool) throws -> OpaquePointer {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if rebuild {
            for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw NotesError("index_open_failed", "Cannot open the Notes search index.")
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON")
            try exec(db, "CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS notes(id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,folder TEXT NOT NULL,tags TEXT NOT NULL,kinds TEXT NOT NULL,created REAL,modified REAL,pinned INTEGER NOT NULL,locked INTEGER NOT NULL,ocr TEXT NOT NULL,handwriting TEXT NOT NULL,transcript TEXT NOT NULL,pdf TEXT NOT NULL); CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(id UNINDEXED,title,body,ocr,handwriting,transcript,pdf,tags,tokenize='unicode61 remove_diacritics 2')")
        } catch { sqlite3_close(db); throw error }
        return db
    }

    private func status(_ db: OpaquePointer) throws -> NotesIndexStatus {
        let count = Int(try scalar(db, "SELECT count(*) FROM notes") ?? "0") ?? 0
        let indexed = try scalar(db, "SELECT value FROM metadata WHERE key='last_indexed'").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let size = [url.path, url.path + "-wal", url.path + "-shm"].reduce(Int64(0)) { total, path in
            total + (((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0)
        }
        return NotesIndexStatus(path: url.path, noteCount: count, fileSize: size, lastIndexed: indexed)
    }

    private static func fingerprint(_ summary: NoteSummary) -> String {
        [String(summary.modified?.timeIntervalSince1970 ?? 0), summary.title, summary.snippet,
         summary.folderPath.joined(separator: "/"), summary.tags.joined(separator: ","), String(summary.isPinned),
         String(summary.isLocked), String(summary.attachmentCount), String(summary.syncState?.needsInitialFetch ?? false),
         String(summary.syncState?.needsFetch ?? false)].joined(separator: "|")
    }
}

private extension LocalNotesIndex {
    enum Value { case text(String), integer(Int64), double(Double?) }
    func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NotesError("index_sql_failed", "The Notes search index operation failed.") }
    }
    func run(_ db: OpaquePointer, _ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NotesError("index_sql_failed", "The Notes search index query failed.") }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { bind(value, to: statement, at: Int32(offset + 1)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NotesError("index_sql_failed", "The Notes search index update failed.") }
    }
    func scalar(_ db: OpaquePointer, _ sql: String) throws -> String? { try rows(db, sql).first?.values.first ?? nil }
    func rows(_ db: OpaquePointer, _ sql: String) throws -> [[String: String]] { try queryRows(db, sql, []) }
    func queryRows(_ db: OpaquePointer, _ sql: String, _ values: [Value]) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NotesError("invalid_query", "The search query could not be prepared.") }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { bind(value, to: statement, at: Int32(offset + 1)) }
        var output: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, index) != SQLITE_NULL {
                let key = String(cString: sqlite3_column_name(statement, index))
                if let text = sqlite3_column_text(statement, index) { row[key] = String(cString: text) }
            }
            output.append(row)
        }
        return output
    }
    func bind(_ value: Value, to statement: OpaquePointer, at index: Int32) {
        switch value {
        case .text(let value): sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        case .integer(let value): sqlite3_bind_int64(statement, index, value)
        case .double(let value): if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
        }
    }
}

private indirect enum QueryExpression {
    case predicate(String?, String, String?)
    case and(QueryExpression, QueryExpression), or(QueryExpression, QueryExpression), not(QueryExpression)
    var terms: [String] {
        switch self { case .predicate(let field, let value, _): return ["folder", "has", "created", "modified", "pinned", "locked"].contains(field ?? "") ? [] : [value]
        case .and(let a, let b), .or(let a, let b): return a.terms + b.terms; case .not: return [] }
    }
    var isPlainText: Bool {
        switch self {
        case .predicate(nil, _, nil): return true
        case .and(let left, let right): return left.isPlainText && right.isPlainText
        default: return false
        }
    }
}

private struct QueryParser {
    private enum Token { case value(String), phrase(String), left, right, and, or, not }
    private var tokens: [Token] = []
    private var position = 0
    init(_ source: String) throws {
        var current = "", quoted = false, index = source.startIndex
        func emit(_ phrase: Bool = false) {
            guard !current.isEmpty else { return }
            let upper = current.uppercased()
            if !phrase && upper == "AND" { tokens.append(.and) }
            else if !phrase && upper == "OR" { tokens.append(.or) }
            else if !phrase && upper == "NOT" { tokens.append(.not) }
            else { tokens.append(phrase ? .phrase(current) : .value(current)) }
            current = ""
        }
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" { if quoted { emit(true) }; quoted.toggle() }
            else if quoted { current.append(character) }
            else if character == "(" || character == ")" { emit(); tokens.append(character == "(" ? .left : .right) }
            else if character.isWhitespace { emit() }
            else { current.append(character) }
            index = source.index(after: index)
        }
        guard !quoted else { throw NotesError("invalid_query", "The query has an unterminated quote.") }
        emit()
    }
    mutating func parse() throws -> QueryExpression {
        let expression = try parseOr()
        guard position == tokens.count else { throw NotesError("invalid_query", "Unexpected search query token.") }
        return expression
    }
    private mutating func parseOr() throws -> QueryExpression {
        var result = try parseAnd()
        while position < tokens.count, case .or = tokens[position] { position += 1; result = .or(result, try parseAnd()) }
        return result
    }
    private mutating func parseAnd() throws -> QueryExpression {
        var result = try parseUnary()
        while position < tokens.count {
            if case .or = tokens[position] { break }
            if case .right = tokens[position] { break }
            if case .and = tokens[position] { position += 1 }
            result = .and(result, try parseUnary())
        }
        return result
    }
    private mutating func parseUnary() throws -> QueryExpression {
        guard position < tokens.count else { throw NotesError("invalid_query", "The query ends unexpectedly.") }
        if case .not = tokens[position] { position += 1; return .not(try parseUnary()) }
        if case .left = tokens[position] {
            position += 1; let value = try parseOr()
            guard position < tokens.count, case .right = tokens[position] else { throw NotesError("invalid_query", "The query has an unmatched parenthesis.") }
            position += 1; return value
        }
        let token = tokens[position]; position += 1
        let raw: String, phrase: Bool
        switch token { case .value(let value): raw = value; phrase = false; case .phrase(let value): raw = value; phrase = true; default: throw NotesError("invalid_query", "Expected a search term.") }
        if let colon = raw.firstIndex(of: ":") {
            let field = String(raw[..<colon]).lowercased(), rest = String(raw[raw.index(after: colon)...])
            guard !rest.isEmpty else { throw NotesError("invalid_query", "A field predicate is missing its value.") }
            let comparison = rest.first.map(String.init).flatMap { [">", "<", "="].contains($0) ? $0 : nil }
            return .predicate(field, comparison == nil ? rest : String(rest.dropFirst()), comparison)
        }
        return .predicate(nil, raw, phrase ? "phrase" : nil)
    }
}

private extension LocalNotesIndex {
    func compile(_ expression: QueryExpression, values: inout [Value], now: Date) throws -> String {
        switch expression {
        case .and(let a, let b): return "(\(try compile(a, values: &values, now: now)) AND \(try compile(b, values: &values, now: now)))"
        case .or(let a, let b): return "(\(try compile(a, values: &values, now: now)) OR \(try compile(b, values: &values, now: now)))"
        case .not(let value): return "NOT (\(try compile(value, values: &values, now: now)))"
        case .predicate(let field, let value, let comparison):
            if field == nil || field == "title" || field == "tag" {
                let column = field == "title" ? "title:" : field == "tag" ? "tags:" : ""
                values.append(.text(column + "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""))
                return "id IN (SELECT id FROM notes_fts WHERE notes_fts MATCH ?)"
            }
            switch field {
            case "folder": values.append(.text("%\(value)%")); return "folder LIKE ? COLLATE NOCASE"
            case "has":
                let options = value.split(separator: "|").map(String.init)
                guard !options.isEmpty else { throw NotesError("invalid_query", "has: needs an attachment kind.") }
                values += options.map { .text("%,\($0.lowercased()),%") }
                return "(" + options.map { _ in "(',' || kinds || ',') LIKE ?" }.joined(separator: " OR ") + ")"
            case "pinned", "locked":
                guard ["true", "false"].contains(value.lowercased()) else { throw NotesError("invalid_query", "\(field!) must be true or false.") }
                values.append(.integer(value.lowercased() == "true" ? 1 : 0)); return "\(field!) = ?"
            case "created", "modified":
                let date: Date
                if value.hasSuffix("d"), let days = Double(value.dropLast()) { date = now.addingTimeInterval(-days * 86_400) }
                else {
                    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
                    guard let parsed = formatter.date(from: value) else { throw NotesError("invalid_query", "Invalid date predicate: \(value)") }
                    date = parsed
                }
                let op: String
                if value.hasSuffix("d") { op = comparison == "<" ? ">" : comparison == ">" ? "<" : ">=" }
                else { op = comparison ?? "=" }
                values.append(.double(date.timeIntervalSince1970)); return "\(field!) \(op) ?"
            default: throw NotesError("invalid_query", "Unknown search field: \(field ?? "")")
            }
        }
    }

    static func occurrences(_ term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }; var count = 0, range = text.startIndex..<text.endIndex
        while let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: range) { count += 1; range = found.upperBound..<text.endIndex }
        return count
    }
    static func snippet(_ text: String, terms: [String]) -> (plain: String, highlights: [String]) {
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        let found = terms.compactMap { flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.min { $0.lowerBound < $1.lowerBound }
        let start = found.flatMap { flat.index($0.lowerBound, offsetBy: -50, limitedBy: flat.startIndex) } ?? flat.startIndex
        let end = found.flatMap { flat.index($0.upperBound, offsetBy: 100, limitedBy: flat.endIndex) } ?? flat.index(flat.startIndex, offsetBy: min(150, flat.count))
        let plain = (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
        return (String(plain), terms.filter { flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil })
    }
    static func fuzzyMatch(_ terms: [String], in text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return terms.allSatisfy { term in words.contains { distance(term.lowercased(), $0) <= (term.count >= 6 ? 2 : 1) } }
    }
    static func distance(_ a: String, _ b: String) -> Int {
        let left = Array(a), right = Array(b); var previous = Array(0...right.count)
        for (i, x) in left.enumerated() { var current = [i + 1] + Array(repeating: 0, count: right.count); for (j, y) in right.enumerated() { current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1)) }; previous = current }
        return previous[right.count]
    }
}
