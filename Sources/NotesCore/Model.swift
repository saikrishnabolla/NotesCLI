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
    public var smartFolderQuery: String?
    public init(id: String, name: String, accountID: String, parentID: String?, path: [String],
                isSmartFolder: Bool, isRecentlyDeleted: Bool, noteCount: Int, smartFolderQuery: String? = nil) {
        self.id = id; self.name = name; self.accountID = accountID; self.parentID = parentID
        self.path = path; self.isSmartFolder = isSmartFolder; self.isRecentlyDeleted = isRecentlyDeleted; self.noteCount = noteCount
        self.smartFolderQuery = smartFolderQuery
    }
}

public enum NoteSort: String, Codable, Sendable, CaseIterable { case modified, created, opened, title, display }

public struct NoteParticipant: Codable, Sendable, Hashable {
    public var participantID: String?
    public var userID: String?
    public var displayName: String?
    public init(participantID: String? = nil, userID: String? = nil, displayName: String? = nil) {
        self.participantID = participantID; self.userID = userID; self.displayName = displayName
    }
}

public struct NoteSyncState: Codable, Sendable, Hashable {
    public var needsInitialFetch: Bool?
    public var needsFetch: Bool?
    public var needsFetchAssets: Bool?
    public var needsSave: Bool?
    public var hasChanges: Bool?
    public var versionOutOfDate: Bool?
    public var cloudState: Int?
    public var lastSyncDate: Date?
    public init(needsInitialFetch: Bool? = nil, needsFetch: Bool? = nil, needsFetchAssets: Bool? = nil,
                needsSave: Bool? = nil, hasChanges: Bool? = nil, versionOutOfDate: Bool? = nil,
                cloudState: Int? = nil, lastSyncDate: Date? = nil) {
        self.needsInitialFetch = needsInitialFetch; self.needsFetch = needsFetch; self.needsFetchAssets = needsFetchAssets
        self.needsSave = needsSave; self.hasChanges = hasChanges
        self.versionOutOfDate = versionOutOfDate; self.cloudState = cloudState; self.lastSyncDate = lastSyncDate
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
    public var hasChecklistInProgress: Bool?
    public var attachmentCount: Int
    public var tags: [String]
    public var lastOpened: Date?
    public var displayOrder: Double?
    public var isShared: Bool?
    public var participants: [NoteParticipant]?
    public var syncState: NoteSyncState?
    public var isSystemPaper: Bool?
    public var deepLink: String?
    public init(id: NoteID, title: String, snippet: String, folderID: String?, folderPath: [String], accountID: String,
                created: Date?, modified: Date?, isPinned: Bool, isLocked: Bool, isDeleted: Bool,
                hasChecklist: Bool, attachmentCount: Int, tags: [String], hasChecklistInProgress: Bool? = nil, lastOpened: Date? = nil,
                displayOrder: Double? = nil, isShared: Bool? = nil, participants: [NoteParticipant]? = nil,
                syncState: NoteSyncState? = nil, isSystemPaper: Bool? = nil, deepLink: String? = nil) {
        self.id = id; self.title = title; self.snippet = snippet; self.folderID = folderID; self.folderPath = folderPath
        self.accountID = accountID; self.created = created; self.modified = modified; self.isPinned = isPinned
        self.isLocked = isLocked; self.isDeleted = isDeleted; self.hasChecklist = hasChecklist
        self.hasChecklistInProgress = hasChecklistInProgress; self.attachmentCount = attachmentCount; self.tags = tags
        self.lastOpened = lastOpened; self.displayOrder = displayOrder; self.isShared = isShared
        self.participants = participants; self.syncState = syncState; self.isSystemPaper = isSystemPaper
        self.deepLink = deepLink ?? "applenotes://showNote?identifier=\(id.uuid)"
    }
}

public struct TranscriptWord: Codable, Sendable, Hashable {
    public var text: String
    public var start: Double?
    public var duration: Double?
    public var speaker: String?
    public var fragment: Int?
    public init(text: String, start: Double? = nil, duration: Double? = nil, speaker: String? = nil, fragment: Int? = nil) {
        self.text = text; self.start = start; self.duration = duration; self.speaker = speaker; self.fragment = fragment
    }
}

public struct RecordingMetadata: Codable, Sendable, Hashable {
    public var summary: String?
    public var topLineSummary: String?
    public var localSpeakerHandle: String?
    public var remoteSpeakerHandle: String?
    public var callType: Int?
    public var isCallRecording: Bool?
    public var startTime: Date?
    public init(summary: String? = nil, topLineSummary: String? = nil, localSpeakerHandle: String? = nil,
                remoteSpeakerHandle: String? = nil, callType: Int? = nil, isCallRecording: Bool? = nil, startTime: Date? = nil) {
        self.summary = summary; self.topLineSummary = topLineSummary; self.localSpeakerHandle = localSpeakerHandle
        self.remoteSpeakerHandle = remoteSpeakerHandle; self.callType = callType
        self.isCallRecording = isCallRecording; self.startTime = startTime
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
    public var handwritingText: String?
    public var additionalIndexableText: String?
    public var imageClassification: String?
    public var imageSummary: String?
    public var pdfText: String?
    public var transcriptText: String?
    public var transcriptWords: [TranscriptWord]?
    public var recording: RecordingMetadata?
    public var duration: Double?
    public var childAttachmentIDs: [String]?
    public var pageImagePaths: [String]?
    public var fallbackRasterPath: String?
    public var displayText: String?
    public var participantID: String?
    public var targetNoteID: String?
    public var mathExpression: String?
    public var mathResult: String?
    public var graphExpression: String?
    public var isDivider: Bool?
    public init(id: String, typeUTI: String, filename: String? = nil, filePath: String? = nil,
                title: String? = nil, url: String? = nil, ocrText: String? = nil,
                handwritingText: String? = nil, additionalIndexableText: String? = nil,
                imageClassification: String? = nil, imageSummary: String? = nil, pdfText: String? = nil,
                transcriptText: String? = nil, transcriptWords: [TranscriptWord]? = nil,
                recording: RecordingMetadata? = nil, duration: Double? = nil,
                childAttachmentIDs: [String]? = nil, pageImagePaths: [String]? = nil,
                fallbackRasterPath: String? = nil, displayText: String? = nil,
                participantID: String? = nil, targetNoteID: String? = nil,
                mathExpression: String? = nil, mathResult: String? = nil,
                graphExpression: String? = nil, isDivider: Bool? = nil) {
        self.id = id; self.typeUTI = typeUTI; self.filename = filename; self.filePath = filePath
        self.title = title; self.url = url; self.ocrText = ocrText
        self.handwritingText = handwritingText; self.additionalIndexableText = additionalIndexableText
        self.imageClassification = imageClassification; self.imageSummary = imageSummary; self.pdfText = pdfText
        self.transcriptText = transcriptText; self.transcriptWords = transcriptWords; self.recording = recording
        self.duration = duration; self.childAttachmentIDs = childAttachmentIDs; self.pageImagePaths = pageImagePaths
        self.fallbackRasterPath = fallbackRasterPath; self.displayText = displayText
        self.participantID = participantID; self.targetNoteID = targetNoteID
        self.mathExpression = mathExpression; self.mathResult = mathResult
        self.graphExpression = graphExpression; self.isDivider = isDivider
    }

    public var kind: String {
        let value = typeUTI.lowercased()
        if value.contains("audio") || value.contains("mpeg-4-audio") || value == "public.mp3" { return "audio" }
        if value.contains("pdf") { return "pdf" }
        if value.contains("gallery") || value.contains("scan") { return "scan" }
        if value.contains("drawing") || value.contains("paper") { return "drawing" }
        if value.contains("image") || value.contains("jpeg") || value.contains("png") || value.contains("heic") { return "image" }
        if value.contains("url") || url != nil { return "link" }
        if value.contains("table") { return "table" }
        if value.contains("hashtag") { return "hashtag" }
        if value.contains("mention") { return "mention" }
        if value.contains("link") { return "note-link" }
        if value.contains("divider") { return "divider" }
        if value.contains("math") || value.contains("calculate") || value.contains("graph") || mathResult != nil { return "math" }
        return "attachment"
    }

    public var searchableText: String {
        [ocrText, handwritingText, additionalIndexableText, imageClassification, imageSummary,
         pdfText, transcriptText, recording?.summary, recording?.topLineSummary, displayText,
         mathExpression, mathResult, graphExpression].compactMap { $0 }.joined(separator: "\n")
    }
}

public struct SmartFolderResult: Codable, Sendable, Hashable {
    public var folder: Folder
    public var rules: [String]
    public var unsupportedRules: [String]
    public var matchingNoteIDs: [String]?
    public init(folder: Folder, rules: [String], unsupportedRules: [String] = [], matchingNoteIDs: [String]? = nil) {
        self.folder = folder; self.rules = rules; self.unsupportedRules = unsupportedRules; self.matchingNoteIDs = matchingNoteIDs
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
