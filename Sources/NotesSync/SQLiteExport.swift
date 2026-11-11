import Foundation
import NotesCore
import SQLite3

enum SQLiteExport {
    static func write(to url: URL, accounts: [Account], folders: [Folder], notes: [Note]) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = database else { throw NotesSyncError.externalTool("Could not create SQLite export.") }
        defer { sqlite3_close(db) }
        try execute(db, "PRAGMA foreign_keys=ON; BEGIN; CREATE TABLE accounts(id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL); CREATE TABLE folders(id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), parent_id TEXT, name TEXT NOT NULL, path TEXT NOT NULL); CREATE TABLE notes(id TEXT PRIMARY KEY, core_data_id TEXT, account_id TEXT NOT NULL REFERENCES accounts(id), folder_id TEXT, title TEXT NOT NULL, body_markdown TEXT, created TEXT, modified TEXT, locked INTEGER NOT NULL, deleted INTEGER NOT NULL); CREATE TABLE attachments(id TEXT NOT NULL, note_id TEXT NOT NULL REFERENCES notes(id), type_uti TEXT NOT NULL, filename TEXT, file_path TEXT, title TEXT, url TEXT, ocr_text TEXT, PRIMARY KEY(id,note_id)); CREATE TABLE tags(note_id TEXT NOT NULL REFERENCES notes(id), tag TEXT NOT NULL, PRIMARY KEY(note_id,tag));")
        do {
            for account in accounts { try insert(db, "INSERT INTO accounts VALUES(?,?,?)", [account.id, account.name, account.kind]) }
            for folder in folders { try insert(db, "INSERT INTO folders VALUES(?,?,?,?,?)", [folder.id, folder.accountID, folder.parentID, folder.name, folder.path.joined(separator: " > ")]) }
            let iso = ISO8601DateFormatter()
            for note in notes {
                let summary = note.summary
                try insert(db, "INSERT INTO notes VALUES(?,?,?,?,?,?,?,?,?,?)", [summary.id.uuid, summary.id.coreDataID, summary.accountID, summary.folderID, summary.title, note.document.map { NoteRenderer.markdown($0, attachments: note.attachments) }, summary.created.map(iso.string), summary.modified.map(iso.string), summary.isLocked ? 1 : 0, summary.isDeleted ? 1 : 0])
                for attachment in note.attachments {
                    try insert(db, "INSERT INTO attachments VALUES(?,?,?,?,?,?,?,?)", [attachment.id, summary.id.uuid, attachment.typeUTI, attachment.filename, attachment.filePath, attachment.title, attachment.url, attachment.ocrText])
                }
                for tag in summary.tags { try insert(db, "INSERT INTO tags VALUES(?,?)", [summary.id.uuid, tag]) }
            }
            try execute(db, "COMMIT;")
        } catch {
            try? execute(db, "ROLLBACK;")
            throw error
        }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "SQLite export failed."
            sqlite3_free(message); throw NotesSyncError.externalTool(text)
        }
    }

    private static func insert(_ db: OpaquePointer, _ sql: String, _ values: [Any?]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NotesSyncError.externalTool(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            if let value = value as? String {
                sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            } else if let value = value as? Int {
                sqlite3_bind_int64(statement, position, sqlite3_int64(value))
            } else { sqlite3_bind_null(statement, position) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NotesSyncError.externalTool(String(cString: sqlite3_errmsg(db))) }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
