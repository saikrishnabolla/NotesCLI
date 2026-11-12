import CryptoKit
import Foundation
import NotesCore
import SQLite3

public enum JournalOutcome: String, Codable, Sendable { case started, verified, unverified, unknown, failed }

public enum JournalRestoreAction: Sendable, Equatable {
    case checklistAutoSort(enabled: Bool)
    case folderSort(folderID: String, order: String, direction: String)
    case defaultAccount(identifier: String)
    case smartFolderQuery(folderID: String, queryJSON: String)
}

public struct JournalEntry: Codable, Sendable {
    public var id: String
    public var operation: String
    public var argumentsHash: String
    public var arguments: Data
    public var idempotencyKey: String?
    public var started: Date
    public var outcome: JournalOutcome
    public var noteID: String?
    public var result: WriteResult?
    public var message: String?

    public var stableDispatchIdentity: String? {
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              let identity = object["stable_id"] as? String, !identity.isEmpty else { return nil }
        return identity
    }

    public func restoreAction() throws -> JournalRestoreAction? {
        guard let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw NotesError("invalid_journal", "The journal arguments are unreadable.")
        }
        func string(_ key: String) -> String? { object[key] as? String }
        func required(_ key: String) throws -> String {
            guard let value = string(key), !value.isEmpty else {
                throw NotesError("journal_preimage_missing", "Journal operation \(id) has no \(key) preimage.")
            }
            return value
        }
        switch operation {
        case "checklistAutoSort", "checklist_auto_sort":
            let enabled: Bool?
            if let value = object["previous_enabled"] as? Bool { enabled = value }
            else if let value = string("previous_enabled") { enabled = Bool(value) }
            else { enabled = nil }
            guard let enabled else { throw NotesError("journal_preimage_missing", "Journal operation \(id) has no previous_enabled preimage.") }
            return .checklistAutoSort(enabled: enabled)
        case "folderSort", "set_folder_sort":
            return .folderSort(folderID: try required("stable_id"), order: try required("previous_by"),
                               direction: try required("previous_direction"))
        case "setDefaultAccount", "set_default_account":
            return .defaultAccount(identifier: try required("previous_account_id"))
        case "smartFolderEditRules", "smartFolderEditTyped", "smart_folder_edit_rules", "smart_folder_edit_typed":
            return .smartFolderQuery(folderID: try required("stable_id"), queryJSON: try required("previous_query_json"))
        default: return nil
        }
    }
}

public struct JournalBegin: Sendable {
    public var entry: JournalEntry
    public var replayed: Bool
}

public final class WriteJournal: @unchecked Sendable {
    private let database: OpaquePointer
    private let lock = NSLock()

    public init(url: URL = NotesSafetyPaths.journal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else { throw NotesError("journal_unavailable", "Could not open the write journal.") }
        database = handle
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA busy_timeout=5000")
            try execute("CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, operation TEXT NOT NULL, arguments_hash TEXT NOT NULL, arguments BLOB NOT NULL, idempotency_key TEXT UNIQUE, started REAL NOT NULL, outcome TEXT NOT NULL, note_id TEXT, result BLOB, message TEXT)")
            try execute("CREATE INDEX IF NOT EXISTS operations_started ON operations(started DESC)")
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func begin(operation: String, arguments: Data, idempotencyKey: String? = nil, now: Date = Date()) throws -> JournalBegin {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let hash = Self.hash(arguments)
                if let idempotencyKey, let existing = try entry(key: idempotencyKey) {
                    guard existing.operation == operation, existing.argumentsHash == hash else {
                        throw NotesError("idempotency_conflict", "The idempotency key was already used with different arguments.")
                    }
                    try execute("COMMIT")
                    return JournalBegin(entry: existing, replayed: true)
                }
                let item = JournalEntry(id: UUID().uuidString, operation: operation, argumentsHash: hash, arguments: arguments,
                                        idempotencyKey: idempotencyKey, started: now, outcome: .started)
                var statement: OpaquePointer?
                try prepare("INSERT INTO operations(id,operation,arguments_hash,arguments,idempotency_key,started,outcome) VALUES(?,?,?,?,?,?,?)", &statement)
                defer { sqlite3_finalize(statement) }
                bind(item.id, 1, statement); bind(operation, 2, statement); bind(hash, 3, statement)
                _ = arguments.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), Self.transient) }
                bind(idempotencyKey, 5, statement); sqlite3_bind_double(statement, 6, now.timeIntervalSince1970); bind(item.outcome.rawValue, 7, statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError("Could not start the journal entry.") }
                try execute("COMMIT")
                return JournalBegin(entry: item, replayed: false)
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func finish(_ id: String, outcome: JournalOutcome, noteID: String? = nil, result: WriteResult? = nil, message: String? = nil) throws {
        try lock.withLock {
            var statement: OpaquePointer?
            try prepare("UPDATE operations SET outcome=?, note_id=?, result=?, message=? WHERE id=?", &statement)
            defer { sqlite3_finalize(statement) }
            bind(outcome.rawValue, 1, statement); bind(noteID, 2, statement)
            if let result {
                let data = try JSONEncoder().encode(result)
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), Self.transient) }
            } else { sqlite3_bind_null(statement, 3) }
            bind(message, 4, statement); bind(id, 5, statement)
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw NotesError("journal_not_found", "Journal entry \(id) was not found.") }
        }
    }

    public func list(limit: Int = 100) throws -> [JournalEntry] {
        try lock.withLock {
            var statement: OpaquePointer?
            try prepare("SELECT id,operation,arguments_hash,arguments,idempotency_key,started,outcome,note_id,result,message FROM operations ORDER BY started DESC LIMIT ?", &statement)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(0, limit)))
            var items: [JournalEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW { items.append(try decode(statement)) }
            return items
        }
    }

    public func unresolved() throws -> [JournalEntry] { try list(limit: Int(Int32.max)).filter { $0.outcome == .unknown || $0.outcome == .started } }

    public func entry(id: String) throws -> JournalEntry? {
        try lock.withLock {
            var statement: OpaquePointer?
            try prepare("SELECT id,operation,arguments_hash,arguments,idempotency_key,started,outcome,note_id,result,message FROM operations WHERE id=?", &statement)
            defer { sqlite3_finalize(statement) }
            bind(id, 1, statement)
            return sqlite3_step(statement) == SQLITE_ROW ? try decode(statement) : nil
        }
    }

    private func entry(key: String) throws -> JournalEntry? {
        var statement: OpaquePointer?
        try prepare("SELECT id,operation,arguments_hash,arguments,idempotency_key,started,outcome,note_id,result,message FROM operations WHERE idempotency_key=?", &statement)
        defer { sqlite3_finalize(statement) }
        bind(key, 1, statement)
        return sqlite3_step(statement) == SQLITE_ROW ? try decode(statement) : nil
    }

    private func decode(_ statement: OpaquePointer?) throws -> JournalEntry {
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        func data(_ column: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
        guard let id = text(0), let operation = text(1), let hash = text(2), let arguments = data(3),
              let rawOutcome = text(6), let outcome = JournalOutcome(rawValue: rawOutcome) else { throw NotesError("invalid_journal", "A journal row is unreadable.") }
        let result = try data(8).map { try JSONDecoder().decode(WriteResult.self, from: $0) }
        return JournalEntry(id: id, operation: operation, argumentsHash: hash, arguments: arguments, idempotencyKey: text(4),
                            started: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)), outcome: outcome,
                            noteID: text(7), result: result, message: text(9))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError("Could not initialize the write journal.") }
    }

    private func prepare(_ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError("Could not prepare the write journal.") }
    }

    private func bind(_ value: String?, _ index: Int32, _ statement: OpaquePointer?) {
        if let value { sqlite3_bind_text(statement, index, value, -1, Self.transient) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func sqliteError(_ message: String) -> NotesError {
        NotesError("journal_unavailable", message + " " + String(cString: sqlite3_errmsg(database)))
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
