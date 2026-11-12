import Foundation
import NotesCore

public struct FreshWriteVerifier: Sendable {
    public typealias ReaderFactory = @Sendable () throws -> any NotesReading
    public typealias FolderReader = @Sendable () throws -> [ScriptingFolder]
    public typealias DeletionReader = @Sendable (String) throws -> Bool
    private let attempts: Int
    private let interval: TimeInterval
    private let freshReader: ReaderFactory
    private let activeFolders: FolderReader?
    private let deletionReader: DeletionReader?

    public init(attempts: Int = 10, interval: TimeInterval = 0.5, freshReader: @escaping ReaderFactory,
                activeFolders: FolderReader? = nil, deletionReader: DeletionReader? = nil) {
        self.attempts = max(1, attempts); self.interval = max(0, interval); self.freshReader = freshReader
        self.activeFolders = activeFolders
        self.deletionReader = deletionReader
    }

    public func verify(_ request: WriteVerificationRequest) -> WriteVerificationResult {
        var lastMismatch: String?
        var readSnapshot = false
        var resolvedNoteID: NoteID?
        var resolvedFolderID: String?
        for attempt in 0..<attempts {
            if attempt > 0 && interval > 0 { Thread.sleep(forTimeInterval: interval) }
            do {
                let reader = try freshReader()
                readSnapshot = true
                let check = try inspect(request, reader: reader)
                resolvedNoteID = check.noteID ?? resolvedNoteID
                resolvedFolderID = check.folderID ?? resolvedFolderID
                if check.mismatch == nil {
                    return WriteVerificationResult(outcome: .verified, noteID: check.noteID, folderID: check.folderID)
                }
                lastMismatch = check.mismatch
            } catch {
                lastMismatch = "fresh snapshot could not resolve the written object"
            }
        }
        return WriteVerificationResult(outcome: readSnapshot ? .unverified : .unknown,
            noteID: resolvedNoteID, folderID: resolvedFolderID,
            mismatch: lastMismatch ?? "fresh snapshot was unavailable before the verification timeout")
    }

    private func inspect(_ request: WriteVerificationRequest, reader: any NotesReading) throws -> WriteVerificationResult {
        switch request.operation {
        case .createNote, .appendToNote, .replaceBody, .renameNote, .moveNote, .deleteNote,
             .prependToNote, .insertUnderHeading, .replaceSection, .replaceText:
            let stableID = request.result.noteID?.uuid
            guard let ref = stableID?.isEmpty == false ? stableID : request.result.noteID?.coreDataID, !ref.isEmpty else {
                return WriteVerificationResult(outcome: .unverified, mismatch: "write returned no note identity")
            }
            let note = try reader.note(ref)
            let mismatch = noteMismatch(request, note: note)
            return WriteVerificationResult(outcome: mismatch == nil ? .verified : .unverified, noteID: note.summary.id, mismatch: mismatch)
        case .createFolder, .renameFolder, .moveFolder:
            let folders = try reader.folders(account: request.account)
            guard let path = request.expectedFolderPath else {
                return WriteVerificationResult(outcome: .unverified, mismatch: "write returned no target folder path")
            }
            if let activeFolders {
                let active = try activeFolders()
                guard let folder = active.first(where: {
                    ($0.id == request.result.folderID) || equalPath($0.path, path)
                }) else {
                    return WriteVerificationResult(outcome: .unverified, mismatch: "folder was not active at the expected path")
                }
                guard folders.contains(where: { equalPath($0.path, path) }) else {
                    return WriteVerificationResult(outcome: .unverified, mismatch: "folder was not present in the fresh store snapshot")
                }
                return WriteVerificationResult(outcome: .verified, folderID: folder.id)
            }
            guard let folder = folders.first(where: { equalPath($0.path, path) }) else {
                return WriteVerificationResult(outcome: .unverified, mismatch: "folder was not present at the expected path")
            }
            return WriteVerificationResult(outcome: .verified, folderID: folder.id)
        case .deleteFolder:
            if let activeFolders, let folderID = request.result.folderID {
                let active = try activeFolders()
                return active.contains(where: { $0.id == folderID })
                    ? WriteVerificationResult(outcome: .unverified, mismatch: "folder still exists")
                    : WriteVerificationResult(outcome: .verified, folderID: folderID)
            }
            let folders = try reader.folders(account: request.account)
            if let path = request.expectedFolderPath, folders.contains(where: { equalPath($0.path, path) }) {
                return WriteVerificationResult(outcome: .unverified, mismatch: "folder still exists at \(path.joined(separator: " > "))")
            }
            return WriteVerificationResult(outcome: .verified)
        }
    }

    private func noteMismatch(_ request: WriteVerificationRequest, note: Note) -> String? {
        switch request.operation {
        case .createNote:
            if note.summary.title != request.title { return "title is \(note.summary.title.debugDescription), expected \((request.title ?? "").debugDescription)" }
            if let path = request.expectedFolderPath, !equalPath(note.summary.folderPath, path) { return "folder path is \(note.summary.folderPath.joined(separator: " > "))" }
            return expectedBodyMismatch(request, note: note)
        case .appendToNote:
            guard request.bodyBefore != nil else { return "write did not capture the pre-append body" }
            return expectedBodyMismatch(request, note: note)
        case .replaceBody:
            return expectedBodyMismatch(request, note: note)
        case .prependToNote, .insertUnderHeading, .replaceSection, .replaceText:
            return expectedBodyMismatch(request, note: note)
        case .renameNote:
            return note.summary.title == request.title ? nil : "title is \(note.summary.title.debugDescription), expected \((request.title ?? "").debugDescription)"
        case .moveNote:
            guard let path = request.expectedFolderPath else { return "write returned no target folder path" }
            return equalPath(note.summary.folderPath, path) ? nil : "folder path is \(note.summary.folderPath.joined(separator: " > ")), expected \(path.joined(separator: " > "))"
        case .deleteNote:
            if note.summary.isDeleted { return nil }
            if let coreDataID = request.result.noteID?.coreDataID,
               let deletionReader, (try? deletionReader(coreDataID)) == true { return nil }
            return "note is not in Recently Deleted"
        default: return "unsupported note verification"
        }
    }

    private func expectedBodyMismatch(_ request: WriteVerificationRequest, note: Note) -> String? {
        guard let expected = request.expectedBody else { return "write did not capture the exact expected body" }
        if let mismatch = bodyMismatch(note, expected: expected, includesTitle: request.expectedBodyIncludesTitle) { return mismatch }
        if let before = request.nativeFeaturesBefore {
            let after = NativeOnlyFeatures.detect(in: note)
            if before != after {
                return "native-only features changed: before \(before.isEmpty ? "none" : before.joined(separator: ", ")); after \(after.isEmpty ? "none" : after.joined(separator: ", "))"
            }
        }
        return nil
    }

    private func bodyMismatch(_ note: Note, expected: String, includesTitle: Bool = false) -> String? {
        guard let document = note.document else { return "note body is unavailable" }
        let expected = canonicalNewlines(expected)
        var actual = canonicalNewlines(document.plainText(attachments: note.attachments))
        let title = canonicalNewlines(note.summary.title)
        if !includesTitle {
            if actual == title { actual = "" }
            else if actual.hasPrefix(title + "\n") { actual.removeFirst(title.count + 1) }
        }
        return actual == expected ? nil : "body text did not exactly match the expected text"
    }

    private func canonicalNewlines(_ value: String) -> String { value.replacingOccurrences(of: "\r\n", with: "\n") }

    private func equalPath(_ left: [String], _ right: [String]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy {
            $0.precomposedStringWithCanonicalMapping.caseInsensitiveCompare($1.precomposedStringWithCanonicalMapping) == .orderedSame
        }
    }
}
