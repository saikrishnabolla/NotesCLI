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
    public var attachmentKinds: [String]
    public var limit: Int?
    public init(folder: String? = nil, account: String? = nil, text: String? = nil, includeDeleted: Bool = false,
                pinnedOnly: Bool = false, tag: String? = nil, modifiedAfter: Date? = nil, modifiedBefore: Date? = nil,
                limit: Int? = nil, attachmentKinds: [String] = []) {
        self.folder = folder; self.account = account; self.text = text; self.includeDeleted = includeDeleted
        self.pinnedOnly = pinnedOnly; self.tag = tag; self.modifiedAfter = modifiedAfter; self.modifiedBefore = modifiedBefore
        self.limit = limit
        self.attachmentKinds = attachmentKinds
    }
}

/// Read side. Implemented by NotesStore (NoteStore.sqlite, read-only).
public protocol NotesReading: Sendable {
    func accounts() throws -> [Account]
    func defaultLocation() throws -> DefaultNotesLocation?
    func folders(account: String?) throws -> [Folder]
    func notes(_ query: NoteQuery) throws -> [NoteSummary]
    /// Accepts a uuid, x-coredata id, short id, or exact title (title must be unique).
    func note(_ ref: String) throws -> Note
    func tags() throws -> [String: Int]
    func notes(_ query: NoteQuery, sort: NoteSort) throws -> [NoteSummary]
    func summary(_ ref: String) throws -> NoteSummary
    func attachments(_ ref: String) throws -> [Attachment]
    func rawNote(_ ref: String) throws -> RawProtobufMessage
    func backlinks(_ ref: String) throws -> [NoteSummary]
    func smartFolders(evaluate: Bool) throws -> [SmartFolderResult]
    func attachmentKindCounts() throws -> [String: Int]
}

public extension NotesReading {
    func defaultLocation() throws -> DefaultNotesLocation? {
        let accounts = try accounts()
        guard let account = accounts.first(where: \.isDefault) ?? accounts.first else { return nil }
        let folder = try folders(account: account.id).first { $0.id == account.defaultFolderID }
            ?? folders(account: account.id).first { $0.name == account.defaultFolderName }
            ?? folders(account: account.id).first { !$0.isRecentlyDeleted && !$0.isSmartFolder }
        return DefaultNotesLocation(accountID: account.id, accountName: account.name, folderID: folder?.id,
                                    folderName: folder?.name, folderPath: folder?.path ?? [])
    }
    func notes(_ query: NoteQuery, sort: NoteSort) throws -> [NoteSummary] {
        var query = query
        let limit = query.limit
        query.limit = nil
        var result = try notes(query)
        result.sort { lhs, rhs in
            switch sort {
            case .modified: return (lhs.modified ?? .distantPast, lhs.id.uuid) > (rhs.modified ?? .distantPast, rhs.id.uuid)
            case .created: return (lhs.created ?? .distantPast, lhs.id.uuid) > (rhs.created ?? .distantPast, rhs.id.uuid)
            case .opened: return (lhs.lastOpened ?? .distantPast, lhs.modified ?? .distantPast, lhs.id.uuid) > (rhs.lastOpened ?? .distantPast, rhs.modified ?? .distantPast, rhs.id.uuid)
            case .title:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id.uuid < rhs.id.uuid : order == .orderedAscending
            case .display: return (lhs.displayOrder ?? .greatestFiniteMagnitude, lhs.id.uuid) < (rhs.displayOrder ?? .greatestFiniteMagnitude, rhs.id.uuid)
            }
        }
        return Array(result.prefix(limit ?? result.count))
    }
    func summary(_ ref: String) throws -> NoteSummary {
        let notes = try notes(NoteQuery(includeDeleted: true))
        let shortRef = ref.allSatisfy(\.isNumber) ? "n\(ref)" : ref
        let ids = notes.filter {
            $0.id.uuid.caseInsensitiveCompare(ref) == .orderedSame ||
            $0.id.coreDataID?.caseInsensitiveCompare(ref) == .orderedSame ||
            $0.id.shortID?.caseInsensitiveCompare(shortRef) == .orderedSame
        }
        let matches = ids.isEmpty ? notes.filter { $0.title == ref } : ids
        guard !matches.isEmpty else { throw NotesError("note_not_found", "No note matches the reference.") }
        guard matches.count == 1 else { throw NotesError("ambiguous_note", "More than one note has this title. Use a UUID.") }
        return matches[0]
    }
    func attachments(_ ref: String) throws -> [Attachment] { try note(ref).attachments }
    func rawNote(_ ref: String) throws -> RawProtobufMessage {
        throw NotesError("unsupported_read", "Raw protobuf is not available from this backend.")
    }
    func backlinks(_ ref: String) throws -> [NoteSummary] {
        let target = try summary(ref).id.uuid
        return try notes(NoteQuery()).filter { candidate in
            guard let note = try? note(candidate.id.uuid) else { return false }
            return note.document?.runs.contains { $0.attachment?.url?.contains(target) == true } == true
        }
    }
    func smartFolders(evaluate: Bool = false) throws -> [SmartFolderResult] {
        try folders(account: nil).filter(\.isSmartFolder).map { SmartFolderResult(folder: $0, rules: []) }
    }
    func attachmentKindCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for summary in try notes(NoteQuery(includeDeleted: true)) where !summary.isLocked {
            for attachment in (try? attachments(summary.id.uuid)) ?? [] { counts[attachment.kind, default: 0] += 1 }
        }
        return counts
    }
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
    func replaceBody(_ ref: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult
    func prependToNote(_ ref: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult
    func insertUnderHeading(_ ref: String, heading: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult
    func replaceSection(_ ref: String, heading: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult
    func replaceText(_ ref: String, find: String, replacement: String, allowAttachmentLoss: Bool) throws -> WriteResult
    func moveFolder(_ ref: String, toParent: String?, account: String?) throws -> WriteResult
    func htmlBody(_ ref: String) throws -> String
}

public extension NotesWriting {
    func replaceBody(_ ref: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult {
        return try replaceBody(ref, markdown: markdown)
    }
    func prependToNote(_ ref: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult {
        throw NotesError("unsupported_operation", "This writer does not support HTML-preserving prepend.")
    }
    func insertUnderHeading(_ ref: String, heading: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult {
        throw NotesError("unsupported_operation", "This writer does not support heading insertion.")
    }
    func replaceSection(_ ref: String, heading: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult {
        throw NotesError("unsupported_operation", "This writer does not support section replacement.")
    }
    func replaceText(_ ref: String, find: String, replacement: String, allowAttachmentLoss: Bool) throws -> WriteResult {
        throw NotesError("unsupported_operation", "This writer does not support text replacement.")
    }
    func moveFolder(_ ref: String, toParent: String?, account: String?) throws -> WriteResult {
        throw NotesError("unsupported_operation", "This writer does not support folder reparenting.")
    }
    func htmlBody(_ ref: String) throws -> String {
        throw NotesError("unsupported_operation", "This writer cannot read the Notes.app HTML body.")
    }
}

public struct NotesError: Error, Codable, Sendable, CustomStringConvertible {
    public var code: String             // stable machine code, e.g. "note_not_found", "full_disk_access_denied"
    public var message: String
    public var hint: String?
    public init(_ code: String, _ message: String, hint: String? = nil) { self.code = code; self.message = message; self.hint = hint }
    public var description: String { "\(code): \(message)" + (hint.map { " (\($0))" } ?? "") }
}
