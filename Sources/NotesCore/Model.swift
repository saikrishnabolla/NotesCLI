import Foundation

/// Stable note identity. `uuid` is Notes' ZIDENTIFIER and survives syncs;
/// `coreDataID` (x-coredata://...) is what Notes.app scripting uses.
public struct NoteID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var uuid: String
    public var coreDataID: String?
    public var shortID: String?
    public init(uuid: String, coreDataID: String? = nil, shortID: String? = nil) {
        self.uuid = uuid; self.coreDataID = coreDataID; self.shortID = shortID
    }
    public var description: String { uuid }
}

public enum NoteReference {
    /// How a note reference string is read.
    public enum Form: Equatable, Sendable {
        /// `id:VALUE` or `nN`: identifiers and note numbers only, never titles.
        case identifier(value: String, number: Int?)
        /// `title:TEXT`: exact titles only.
        case title(String)
        /// `#N` or `N`: a note number, an identifier, or an exact title.
        case numberOrTitle(Int)
        /// Anything else: a UUID, Core Data ID, or exact title.
        case text(String)
    }

    public static func parse(_ ref: String) -> Form {
        if let range = ref.range(of: "title:", options: [.anchored, .caseInsensitive]) {
            return .title(String(ref[range.upperBound...]))
        }
        if let range = ref.range(of: "id:", options: [.anchored, .caseInsensitive]) {
            let value = String(ref[range.upperBound...])
            return .identifier(value: value, number: digits(value))
        }
        if ref.count > 1, ref.first?.lowercased() == "n", let number = digits(ref.dropFirst()) {
            return .identifier(value: ref, number: number)
        }
        if ref.hasPrefix("#"), let number = digits(ref.dropFirst()) { return .numberOrTitle(number) }
        if let number = digits(ref) { return .numberOrTitle(number) }
        return .text(ref)
    }

    /// Resolves `ref` to exactly one candidate. A reference that matches one note by number or ID
    /// and a different note by title fails with `ambiguous_reference` instead of picking one.
    public static func resolve<Candidate>(
        _ ref: String,
        identifiers: (String) throws -> [Candidate],
        number: (Int) throws -> [Candidate],
        title: (String) throws -> [Candidate],
        key: (Candidate) -> String,
        describe: (Candidate) -> String
    ) throws -> Candidate {
        var labeled: [(Candidate, String)] = []
        var seen: Set<String> = []
        func add(_ candidates: [Candidate], _ label: String) {
            let ordered = candidates.sorted { describe($0).compare(describe($1), options: .numeric) == .orderedAscending }
            for candidate in ordered where seen.insert(key(candidate)).inserted { labeled.append((candidate, label)) }
        }
        var conflictHint: String?
        switch parse(ref) {
        case .title(let text):
            add(try title(text), "title")
        case .identifier(let value, let numeric):
            add(try identifiers(value), "id")
            if let numeric { add(try number(numeric), "number") }
        case .numberOrTitle(let value):
            add(try identifiers(ref), "id")
            add(try number(value), "number")
            add(try title(ref), "title")
            conflictHint = "Use id:\(value) for the note number or title:\(ref) for the exact title."
        case .text(let text):
            add(try identifiers(text), "id")
            add(try title(text), "title")
            conflictHint = "Use id:\(ref) for the identifier or title:\(ref) for the exact title."
        }
        guard !labeled.isEmpty else { throw NotesError("note_not_found", "No note matches the reference.") }
        guard labeled.count > 1 else { return labeled[0].0 }
        let listed = labeled.map { "\(describe($0.0)) (\($0.1))" }.joined(separator: ", ")
        let message = "Reference \"\(ref)\" matches more than one note: \(listed)."
        let mixesTitleAndID = labeled.contains { $0.1 == "title" } && labeled.contains { $0.1 != "title" }
        if mixesTitleAndID, let conflictHint { throw NotesError("ambiguous_reference", message, hint: conflictHint) }
        throw NotesError("ambiguous_note", message, hint: "Use id:N, a UUID, or title:TEXT.")
    }

    /// `#N` as listed by NotesCLI, then the UUID, then the quoted title.
    public static func describe(number: Int?, uuid: String, title: String) -> String {
        [number.map { "#\($0)" }, uuid, "\"\(title)\""].compactMap { $0 }.joined(separator: " ")
    }

    public static func explicitNumber(_ ref: String) -> Int? {
        if ref.hasPrefix("#") { return digits(ref.dropFirst()) }
        if ref.count > 1, ref.first?.lowercased() == "n" { return digits(ref.dropFirst()) }
        return nil
    }

    public static func number(fromShortID shortID: String?) -> Int? {
        guard let shortID else { return nil }
        return explicitNumber(shortID)
    }

    private static func digits<S: StringProtocol>(_ text: S) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }
}

public struct Account: Codable, Sendable, Hashable {
    public var id: String          // ZIDENTIFIER
    public var name: String
    public var kind: String        // "icloud", "local", "imap", "exchange", "unknown"
    public var isDefault: Bool
    public var defaultFolderID: String?
    public var defaultFolderName: String?
    public init(id: String, name: String, kind: String, isDefault: Bool = false,
                defaultFolderID: String? = nil, defaultFolderName: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.isDefault = isDefault
        self.defaultFolderID = defaultFolderID; self.defaultFolderName = defaultFolderName
    }
}

public struct DefaultNotesLocation: Codable, Sendable, Hashable {
    public var accountID: String
    public var accountName: String
    public var folderID: String?
    public var folderName: String?
    public var folderPath: [String]
    public init(accountID: String, accountName: String, folderID: String? = nil,
                folderName: String? = nil, folderPath: [String] = []) {
        self.accountID = accountID; self.accountName = accountName; self.folderID = folderID
        self.folderName = folderName; self.folderPath = folderPath
    }
}

public struct StableCursorPayload: Codable, Sendable, Hashable {
    public var sort: String
    public var key: String
    public var secondary: String?
    public var id: String
    public init(sort: String, key: String, secondary: String? = nil, id: String) {
        self.sort = sort; self.key = key; self.secondary = secondary; self.id = id
    }
}

public enum StableCursor {
    public static func encode(_ payload: StableCursorPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ value: String) throws -> StableCursorPayload {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let payload = try? JSONDecoder().decode(StableCursorPayload.self, from: data) else {
            throw NotesError("invalid_cursor", "The cursor is invalid.")
        }
        return payload
    }
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
    /// x-coredata://.../ICFolder/pN — the id Notes.app scripting understands.
    public var coreDataID: String?
    public init(id: String, name: String, accountID: String, parentID: String?, path: [String],
                isSmartFolder: Bool, isRecentlyDeleted: Bool, noteCount: Int, smartFolderQuery: String? = nil, coreDataID: String? = nil) {
        self.id = id; self.name = name; self.accountID = accountID; self.parentID = parentID
        self.path = path; self.isSmartFolder = isSmartFolder; self.isRecentlyDeleted = isRecentlyDeleted; self.noteCount = noteCount
        self.smartFolderQuery = smartFolderQuery; self.coreDataID = coreDataID
    }
}

public enum NoteSort: String, Codable, Sendable, CaseIterable { case modified, created, opened, title, display }

public struct NoteParticipant: Codable, Sendable, Hashable {
    public var participantID: String?
    public var userID: String?
    public var displayName: String?
    public var email: String?
    public init(participantID: String? = nil, userID: String? = nil, displayName: String? = nil, email: String? = nil) {
        self.participantID = participantID; self.userID = userID; self.displayName = displayName; self.email = email
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
    public var currentLocalVersion: Int?
    public var latestVersionSyncedToCloud: Int?
    public var isInCloud: Bool?
    public init(needsInitialFetch: Bool? = nil, needsFetch: Bool? = nil, needsFetchAssets: Bool? = nil,
                needsSave: Bool? = nil, hasChanges: Bool? = nil, versionOutOfDate: Bool? = nil,
                cloudState: Int? = nil, lastSyncDate: Date? = nil, currentLocalVersion: Int? = nil,
                latestVersionSyncedToCloud: Int? = nil, isInCloud: Bool? = nil) {
        self.needsInitialFetch = needsInitialFetch; self.needsFetch = needsFetch; self.needsFetchAssets = needsFetchAssets
        self.needsSave = needsSave; self.hasChanges = hasChanges
        self.versionOutOfDate = versionOutOfDate; self.cloudState = cloudState; self.lastSyncDate = lastSyncDate
        self.currentLocalVersion = currentLocalVersion; self.latestVersionSyncedToCloud = latestVersionSyncedToCloud
        self.isInCloud = isInCloud
    }
}

/// Note metadata, cheap to list.
public struct NoteSummary: Codable, Sendable, Hashable {
    public var id: NoteID
    public var number: Int?
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
                syncState: NoteSyncState? = nil, isSystemPaper: Bool? = nil, deepLink: String? = nil, number: Int? = nil) {
        self.id = id; self.number = number ?? NoteReference.number(fromShortID: id.shortID)
        self.title = title; self.snippet = snippet; self.folderID = folderID; self.folderPath = folderPath
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
    public var childAttachments: [Attachment]?
    public var pageImagePaths: [String]?
    public var fallbackRasterPath: String?
    public var displayText: String?
    public var participantID: String?
    public var participantName: String?
    public var participantEmail: String?
    public var participantUserID: String?
    public var targetNoteID: String?
    public var mathExpression: String?
    public var mathResult: String?
    public var graphExpression: String?
    public var isDivider: Bool?
    public var drawingSVG: String?
    public init(id: String, typeUTI: String, filename: String? = nil, filePath: String? = nil,
                title: String? = nil, url: String? = nil, ocrText: String? = nil,
                handwritingText: String? = nil, additionalIndexableText: String? = nil,
                imageClassification: String? = nil, imageSummary: String? = nil, pdfText: String? = nil,
                transcriptText: String? = nil, transcriptWords: [TranscriptWord]? = nil,
                recording: RecordingMetadata? = nil, duration: Double? = nil,
                childAttachmentIDs: [String]? = nil, childAttachments: [Attachment]? = nil,
                pageImagePaths: [String]? = nil,
                fallbackRasterPath: String? = nil, displayText: String? = nil,
                participantID: String? = nil, participantName: String? = nil,
                participantEmail: String? = nil, participantUserID: String? = nil, targetNoteID: String? = nil,
                mathExpression: String? = nil, mathResult: String? = nil,
                graphExpression: String? = nil, isDivider: Bool? = nil, drawingSVG: String? = nil) {
        self.id = id; self.typeUTI = typeUTI; self.filename = filename; self.filePath = filePath
        self.title = title; self.url = url; self.ocrText = ocrText
        self.handwritingText = handwritingText; self.additionalIndexableText = additionalIndexableText
        self.imageClassification = imageClassification; self.imageSummary = imageSummary; self.pdfText = pdfText
        self.transcriptText = transcriptText; self.transcriptWords = transcriptWords; self.recording = recording
        self.duration = duration; self.childAttachmentIDs = childAttachmentIDs; self.childAttachments = childAttachments
        self.pageImagePaths = pageImagePaths
        self.fallbackRasterPath = fallbackRasterPath; self.displayText = displayText
        self.participantID = participantID; self.participantName = participantName
        self.participantEmail = participantEmail; self.participantUserID = participantUserID
        self.targetNoteID = targetNoteID
        self.mathExpression = mathExpression; self.mathResult = mathResult
        self.graphExpression = graphExpression; self.isDivider = isDivider; self.drawingSVG = drawingSVG
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
        return "file"
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
