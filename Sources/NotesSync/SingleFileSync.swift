import Foundation
import NotesCore

public struct FileSyncReport: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case pull, push, updateLocal, conflict, unchanged, refused, pending }
    public var action: Action
    public var noteID: String
    public var path: String
    public var changed: Bool
    public var conflicts: Int
    public var refusedAttachments: Bool
    public var message: String

    public init(action: Action, noteID: String, path: String, changed: Bool, conflicts: Int = 0,
                refusedAttachments: Bool = false, message: String) {
        self.action = action; self.noteID = noteID; self.path = path; self.changed = changed
        self.conflicts = conflicts; self.refusedAttachments = refusedAttachments; self.message = message
    }
}

private struct FileSyncState: Codable {
    var version = 1
    var noteID: String
    var base: String
    var hash: String
    var pendingHash: String?
    var conflicted: Bool?
}

public final class SingleFileSync {
    private let reader: any NotesReading
    private let writer: (any NotesWriting)?
    private let fileManager: FileManager

    public init(reader: any NotesReading, writer: (any NotesWriting)?, fileManager: FileManager = .default) {
        self.reader = reader; self.writer = writer; self.fileManager = fileManager
    }

    public func pull(note reference: String, to path: URL, dryRun: Bool = false) throws -> FileSyncReport {
        let note = try reader.note(reference)
        guard !note.summary.isLocked, note.document != nil else { throw NotesSyncError.invalidState("The note body is unavailable.") }
        let noteID = note.summary.id.uuid
        let remote = markdown(note), remoteHash = StableHash.hex(remote)
        let sidecar = sidecarURL(for: path)
        let state = try loadState(sidecar)
        if let state, state.noteID != noteID { throw NotesSyncError.invalidState("The file sidecar belongs to another note.") }

        guard fileManager.fileExists(atPath: path.path), let state else {
            if !dryRun {
                try write(MarkdownFile(noteID: noteID, title: note.summary.title, modified: note.summary.modified, body: remote), to: path)
                try save(FileSyncState(noteID: noteID, base: remote, hash: remoteHash), to: sidecar)
            }
            return report(.pull, noteID, path, changed: true, "Write the Notes copy to the Markdown file.")
        }

        let localFile = MarkdownFile.parse(try String(contentsOf: path, encoding: .utf8), fallbackTitle: path.deletingPathExtension().lastPathComponent)
        if let id = localFile.noteID, id != noteID { throw NotesSyncError.invalidState("The file notes-id does not match the requested note.") }
        let localHash = StableHash.hex(localFile.body)
        let localChanged = localHash != state.hash, remoteChanged = remoteHash != state.hash
        if !localChanged && !remoteChanged { return report(.unchanged, noteID, path, changed: false, "The file and note are unchanged.") }
        if localChanged && !remoteChanged { return report(.unchanged, noteID, path, changed: false, "Keep the local edit; Notes has not changed.") }

        var output = remote
        if localChanged && remoteChanged {
            let merge = Diff3.merge(base: state.base, local: localFile.body, remote: remote)
            output = merge.text
            if merge.hadConflicts {
                if !dryRun {
                    try write(MarkdownFile(noteID: noteID, title: localFile.title, modified: note.summary.modified, body: output), to: path)
                    try save(FileSyncState(noteID: noteID, base: remote, hash: remoteHash), to: sidecar)
                }
                return report(.conflict, noteID, path, changed: true, conflicts: 1,
                              "Both copies changed the same lines; conflict markers were written locally.")
            }
        }
        if !dryRun {
            try write(MarkdownFile(noteID: noteID, title: note.summary.title, modified: note.summary.modified, body: output), to: path)
            try save(FileSyncState(noteID: noteID, base: remote, hash: remoteHash), to: sidecar)
        }
        return report(.pull, noteID, path, changed: true, "Apply the Notes changes to the Markdown file.")
    }

    public func push(from path: URL, dryRun: Bool = false) throws -> FileSyncReport {
        let localFile = try localFile(at: path)
        guard let noteID = localFile.noteID else { throw NotesSyncError.invalidState("The Markdown file must contain notes-id front matter.") }
        let note = try reader.note(noteID)
        guard !note.summary.isLocked, note.document != nil else { throw NotesSyncError.invalidState("The note body is unavailable.") }
        let sidecar = sidecarURL(for: path)
        var state = try loadState(sidecar) ?? FileSyncState(noteID: noteID, base: markdown(note), hash: StableHash.hex(markdown(note)))
        guard state.noteID == noteID else { throw NotesSyncError.invalidState("The file sidecar belongs to another note.") }
        let remote = markdown(note), remoteHash = StableHash.hex(remote)

        if let pending = state.pendingHash {
            if pending == remoteHash {
                state.pendingHash = nil; state.base = remote; state.hash = remoteHash
                if !dryRun { try save(state, to: sidecar) }
            } else {
                throw NotesSyncError.writeUnknown("A prior file push still has an unknown outcome. No write was retried.")
            }
        }
        let localHash = StableHash.hex(localFile.body)
        let localChanged = localHash != state.hash, remoteChanged = remoteHash != state.hash
        if state.conflicted == true && localFile.body.contains("<<<<<<< LOCAL") {
            return report(.conflict, noteID, path, changed: false, conflicts: 1,
                          remoteChanged ? "The conflict is unresolved and Notes changed again." : "Resolve the existing conflict markers before pushing.")
        }
        if !localChanged && !remoteChanged {
            if !dryRun { try save(state, to: sidecar) }
            return report(.unchanged, noteID, path, changed: false, "The file and note are unchanged.")
        }
        if hasAttachments(note), (writer as? any LosslessAttachmentWriting)?.supportsLosslessAttachmentRoundTrip != true {
            return report(.refused, noteID, path, changed: false, refusedAttachments: true,
                          "Refused: replacing the body would lose attachments.")
        }

        var merged = localFile.body
        if remoteChanged {
            if localChanged {
                let result = Diff3.merge(base: state.base, local: localFile.body, remote: remote)
                merged = result.text
                if result.hadConflicts {
                    if !dryRun {
                        try write(MarkdownFile(noteID: noteID, title: localFile.title, modified: note.summary.modified, body: merged), to: path)
                        state.base = remote; state.hash = remoteHash; state.conflicted = true
                        try save(state, to: sidecar)
                    }
                    return report(.conflict, noteID, path, changed: true, conflicts: 1,
                                  "Both copies changed the same lines; conflict markers were written locally.")
                }
            } else {
                if !dryRun {
                    try write(MarkdownFile(noteID: noteID, title: note.summary.title, modified: note.summary.modified, body: remote), to: path)
                    state.base = remote; state.hash = remoteHash; try save(state, to: sidecar)
                }
                return report(.updateLocal, noteID, path, changed: true, "Notes changed; update the local file before pushing.")
            }
        }
        if dryRun { return report(.push, noteID, path, changed: true, "Push the merged Markdown body to Notes.") }
        guard let writer else { throw NotesSyncError.invalidState("A writer is required for file push.") }
        let result = try writer.replaceBody(noteID, markdown: merged)
        if result.outcome == .unknown {
            state.pendingHash = StableHash.hex(merged)
            try save(state, to: sidecar)
            throw NotesSyncError.writeUnknown("The outcome of file push is unknown. Read both sides before retrying.")
        }
        guard result.outcome == .verified else { throw NotesSyncError.invalidState("The file push was not verified.") }
        if merged != localFile.body {
            try write(MarkdownFile(noteID: noteID, title: localFile.title, modified: Date(), body: merged), to: path)
        }
        state.base = merged; state.hash = StableHash.hex(merged); state.pendingHash = nil; state.conflicted = false
        try save(state, to: sidecar)
        return report(.push, noteID, path, changed: true, "Pushed the Markdown body to Notes.")
    }

    public func diff(_ path: URL) throws -> FileSyncReport {
        let local = try localFile(at: path)
        guard let noteID = local.noteID else { throw NotesSyncError.invalidState("The Markdown file must contain notes-id front matter.") }
        let note = try reader.note(noteID), remote = markdown(note)
        guard let state = try loadState(sidecarURL(for: path)) else {
            return report(.pending, noteID, path, changed: local.body != remote, "No merge base exists; pull or push once to create it.")
        }
        if state.conflicted == true && local.body.contains("<<<<<<< LOCAL") {
            return report(.conflict, noteID, path, changed: false, conflicts: 1,
                          "Resolve the existing conflict markers before pushing.")
        }
        let localChanged = StableHash.hex(local.body) != state.hash
        let remoteChanged = StableHash.hex(remote) != state.hash
        if !localChanged && !remoteChanged { return report(.unchanged, noteID, path, changed: false, "The file and note are unchanged.") }
        if localChanged && remoteChanged {
            let merge = Diff3.merge(base: state.base, local: local.body, remote: remote)
            return report(merge.hadConflicts ? .conflict : .push, noteID, path, changed: true,
                          conflicts: merge.hadConflicts ? 1 : 0,
                          merge.hadConflicts ? "Both copies changed the same lines." : "Both copies changed and merge cleanly.")
        }
        return report(localChanged ? .push : .updateLocal, noteID, path, changed: true,
                      localChanged ? "Only the local file changed." : "Only Notes changed.")
    }

    private func report(_ action: FileSyncReport.Action, _ noteID: String, _ path: URL, changed: Bool,
                        conflicts: Int = 0, refusedAttachments: Bool = false, _ message: String) -> FileSyncReport {
        FileSyncReport(action: action, noteID: noteID, path: path.path, changed: changed, conflicts: conflicts,
                       refusedAttachments: refusedAttachments, message: message)
    }

    private func markdown(_ note: Note) -> String { note.document.map { NoteRenderer.markdown($0, attachments: note.attachments) } ?? "" }
    private func hasAttachments(_ note: Note) -> Bool { note.summary.attachmentCount > 0 || !note.attachments.isEmpty }

    private func localFile(at path: URL) throws -> MarkdownFile {
        guard fileManager.fileExists(atPath: path.path) else { throw NotesSyncError.invalidState("Markdown file not found: \(path.path)") }
        return MarkdownFile.parse(try String(contentsOf: path, encoding: .utf8), fallbackTitle: path.deletingPathExtension().lastPathComponent)
    }

    private func sidecarURL(for path: URL) -> URL {
        path.deletingLastPathComponent().appendingPathComponent(".notescli", isDirectory: true)
            .appendingPathComponent(SafePath.component(path.lastPathComponent) + ".json")
    }

    private func loadState(_ url: URL) throws -> FileSyncState? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(FileSyncState.self, from: Data(contentsOf: url))
    }

    private func save(_ state: FileSyncState, to url: URL) throws {
        try fileManager.createPrivateDirectory(at: url.deletingLastPathComponent())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func write(_ file: MarkdownFile, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(file.rendered().utf8).write(to: url, options: .atomic)
    }
}
