import Foundation
import NotesCore

/// A long-lived reader that replaces its immutable snapshot when Notes changes on disk.
public final class LiveSQLiteNotesStore: NotesReading, @unchecked Sendable {
    private let databaseURL: URL
    private let groupContainerURL: URL?
    private let lock = NSLock()
    private var fingerprint: [String]
    private var store: SQLiteNotesStore

    public init(databaseURL: URL = SQLiteNotesStore.defaultDatabaseURL, groupContainerURL: URL? = nil) throws {
        self.databaseURL = databaseURL
        self.groupContainerURL = groupContainerURL
        fingerprint = try Self.fingerprint(databaseURL)
        store = try SQLiteNotesStore(databaseURL: databaseURL, groupContainerURL: groupContainerURL, refresh: true)
    }

    private static func fingerprint(_ databaseURL: URL) throws -> [String] {
        let fileManager = FileManager.default
        return try ["", "-wal"].map { suffix in
            let path = databaseURL.path + suffix
            guard fileManager.fileExists(atPath: path) else { return "missing" }
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate.bitPattern ?? 0
            return "\(inode):\(size):\(modified)"
        }
    }

    private func current() throws -> SQLiteNotesStore {
        try lock.withLock {
            let observed = try Self.fingerprint(databaseURL)
            if observed != fingerprint {
                store = try SQLiteNotesStore(databaseURL: databaseURL, groupContainerURL: groupContainerURL, refresh: true)
                // Record the fingerprint observed before loading. If Notes changed while
                // the snapshot loaded, the next call refreshes once more instead of
                // treating an older snapshot as current.
                fingerprint = observed
            }
            return store
        }
    }

    public func accounts() throws -> [Account] { try current().accounts() }
    public func defaultLocation() throws -> DefaultNotesLocation? { try current().defaultLocation() }
    public func folders(account: String?) throws -> [Folder] { try current().folders(account: account) }
    public func notes(_ query: NoteQuery) throws -> [NoteSummary] { try current().notes(query) }
    public func notes(_ query: NoteQuery, sort: NoteSort) throws -> [NoteSummary] { try current().notes(query, sort: sort) }
    public func note(_ ref: String) throws -> Note { try current().note(ref) }
    public func summary(_ ref: String) throws -> NoteSummary { try current().summary(ref) }
    public func tags() throws -> [String: Int] { try current().tags() }
    public func attachments(_ ref: String) throws -> [Attachment] { try current().attachments(ref) }
    public func rawNote(_ ref: String) throws -> RawProtobufMessage { try current().rawNote(ref) }
    public func backlinks(_ ref: String) throws -> [NoteSummary] { try current().backlinks(ref) }
    public func smartFolders(evaluate: Bool) throws -> [SmartFolderResult] { try current().smartFolders(evaluate: evaluate) }
    public func attachmentKindCounts() throws -> [String: Int] { try current().attachmentKindCounts() }
}
