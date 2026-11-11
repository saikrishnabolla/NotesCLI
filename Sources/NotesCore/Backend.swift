import Foundation

public struct NoteQuery: Sendable {
    public var folder: String?          // folder id, name, or "A > B" path
    public var account: String?
    public var text: String?            // substring/fuzzy match on title and body
    public var includeDeleted = false
    public var pinnedOnly = false
    public var tag: String?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var limit: Int?
    public init(folder: String? = nil, account: String? = nil, text: String? = nil, includeDeleted: Bool = false,
                pinnedOnly: Bool = false, tag: String? = nil, modifiedAfter: Date? = nil, modifiedBefore: Date? = nil, limit: Int? = nil) {
        self.folder = folder; self.account = account; self.text = text; self.includeDeleted = includeDeleted
        self.pinnedOnly = pinnedOnly; self.tag = tag; self.modifiedAfter = modifiedAfter; self.modifiedBefore = modifiedBefore; self.limit = limit
    }
}

/// Read side. Implemented by NotesStore (NoteStore.sqlite, read-only).
public protocol NotesReading: Sendable {
    func accounts() throws -> [Account]
    func folders(account: String?) throws -> [Folder]
    func notes(_ query: NoteQuery) throws -> [NoteSummary]
    /// Accepts a uuid, x-coredata id, or exact title (title must be unique).
    func note(_ ref: String) throws -> Note
    func tags() throws -> [String: Int]
}

public enum WriteOutcome: String, Codable, Sendable { case verified, unverified, unknown }

public struct WriteResult: Codable, Sendable {
    public var outcome: WriteOutcome
    public var noteID: NoteID?
    public var folderID: String?
    public var message: String?
    public init(outcome: WriteOutcome, noteID: NoteID? = nil, folderID: String? = nil, message: String? = nil) {
        self.outcome = outcome; self.noteID = noteID; self.folderID = folderID; self.message = message
    }
}

/// Write side. Implemented by NotesAutomation (Notes.app scripting). Body input is Markdown.
public protocol NotesWriting: Sendable {
    func createNote(title: String, markdown: String, folder: String?) throws -> WriteResult
    func appendToNote(_ ref: String, markdown: String) throws -> WriteResult
    func replaceBody(_ ref: String, markdown: String) throws -> WriteResult
    func renameNote(_ ref: String, title: String) throws -> WriteResult
    func moveNote(_ ref: String, toFolder: String) throws -> WriteResult
    /// Moves to Recently Deleted; never hard-deletes.
    func deleteNote(_ ref: String) throws -> WriteResult
    func createFolder(name: String, parent: String?, account: String?) throws -> WriteResult
    func renameFolder(_ ref: String, name: String) throws -> WriteResult
    func deleteFolder(_ ref: String) throws -> WriteResult
}

public struct NotesError: Error, Codable, Sendable, CustomStringConvertible {
    public var code: String             // stable machine code, e.g. "note_not_found", "full_disk_access_denied"
    public var message: String
    public var hint: String?
    public init(_ code: String, _ message: String, hint: String? = nil) { self.code = code; self.message = message; self.hint = hint }
    public var description: String { "\(code): \(message)" + (hint.map { " (\($0))" } ?? "") }
}
