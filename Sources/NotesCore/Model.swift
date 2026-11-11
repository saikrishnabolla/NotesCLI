import Foundation

/// Stable note identity. `uuid` is Notes' ZIDENTIFIER and survives syncs;
/// `coreDataID` (x-coredata://...) is what Notes.app scripting uses.
public struct NoteID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var uuid: String
    public var coreDataID: String?
    public init(uuid: String, coreDataID: String? = nil) { self.uuid = uuid; self.coreDataID = coreDataID }
    public var description: String { uuid }
}

public struct Account: Codable, Sendable, Hashable {
    public var id: String          // ZIDENTIFIER
    public var name: String
    public var kind: String        // "icloud", "local", "imap", "exchange", "unknown"
    public init(id: String, name: String, kind: String) { self.id = id; self.name = name; self.kind = kind }
}

public struct Folder: Codable, Sendable, Hashable {
    public var id: String          // ZIDENTIFIER
    public var name: String
    public var accountID: String
    public var parentID: String?
    public var path: [String]      // names from the account root, e.g. ["Work", "Archive"]
    public var isSmartFolder: Bool
    public var isRecentlyDeleted: Bool
    public var noteCount: Int
    public init(id: String, name: String, accountID: String, parentID: String?, path: [String],
                isSmartFolder: Bool, isRecentlyDeleted: Bool, noteCount: Int) {
        self.id = id; self.name = name; self.accountID = accountID; self.parentID = parentID
        self.path = path; self.isSmartFolder = isSmartFolder; self.isRecentlyDeleted = isRecentlyDeleted; self.noteCount = noteCount
    }
}

/// Note metadata, cheap to list.
public struct NoteSummary: Codable, Sendable, Hashable {
    public var id: NoteID
    public var title: String
    public var snippet: String
    public var folderID: String?
    public var folderPath: [String]
    public var accountID: String
    public var created: Date?
    public var modified: Date?
    public var isPinned: Bool
    public var isLocked: Bool        // password protected; body unreadable
    public var isDeleted: Bool       // in Recently Deleted
    public var hasChecklist: Bool
    public var attachmentCount: Int
    public var tags: [String]
    public init(id: NoteID, title: String, snippet: String, folderID: String?, folderPath: [String], accountID: String,
                created: Date?, modified: Date?, isPinned: Bool, isLocked: Bool, isDeleted: Bool,
                hasChecklist: Bool, attachmentCount: Int, tags: [String]) {
        self.id = id; self.title = title; self.snippet = snippet; self.folderID = folderID; self.folderPath = folderPath
        self.accountID = accountID; self.created = created; self.modified = modified; self.isPinned = isPinned
        self.isLocked = isLocked; self.isDeleted = isDeleted; self.hasChecklist = hasChecklist
        self.attachmentCount = attachmentCount; self.tags = tags
    }
}

public struct Attachment: Codable, Sendable, Hashable {
    public var id: String            // ZIDENTIFIER of the ICAttachment
    public var typeUTI: String       // e.g. public.jpeg, com.apple.notes.table, com.apple.paper
    public var filename: String?
    public var filePath: String?     // resolved on-disk media path, nil if not downloaded
    public var title: String?
    public var url: String?          // for link previews
    public var ocrText: String?      // text Notes already recognized (scans, images)
    public init(id: String, typeUTI: String, filename: String? = nil, filePath: String? = nil,
                title: String? = nil, url: String? = nil, ocrText: String? = nil) {
        self.id = id; self.typeUTI = typeUTI; self.filename = filename; self.filePath = filePath
        self.title = title; self.url = url; self.ocrText = ocrText
    }
}

public struct Note: Codable, Sendable {
    public var summary: NoteSummary
    public var document: NoteDocument?   // nil when locked
    public var attachments: [Attachment]
    public init(summary: NoteSummary, document: NoteDocument?, attachments: [Attachment]) {
        self.summary = summary; self.document = document; self.attachments = attachments
    }
}
