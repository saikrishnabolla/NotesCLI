import Foundation
import NotesCore

public protocol LosslessAttachmentWriting: NotesWriting {
    var supportsLosslessAttachmentRoundTrip: Bool { get }
}

public struct SyncOptions: Sendable {
    public var directory: URL
    public var folder: String
    public var propagateDeletes: Bool
    public var dryRun: Bool

    public init(directory: URL, folder: String, propagateDeletes: Bool = false, dryRun: Bool = false) {
        self.directory = directory; self.folder = folder
        self.propagateDeletes = propagateDeletes; self.dryRun = dryRun
    }
}

public struct SyncAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case createLocal, createNote, updateLocal, updateNote, rename, move, restore, deleteLocal, deleteNote, conflict, skip }
    public var kind: Kind
    public var noteID: String?
    public var path: String?
    public var message: String
    public init(_ kind: Kind, noteID: String? = nil, path: String? = nil, message: String) {
        self.kind = kind; self.noteID = noteID; self.path = path; self.message = message
    }
}

public struct SyncReport: Codable, Equatable, Sendable {
    public var actions: [SyncAction]
    public var conflicts: Int
    public var refusedAttachments: Int
    public init(actions: [SyncAction] = [], conflicts: Int = 0, refusedAttachments: Int = 0) {
        self.actions = actions; self.conflicts = conflicts; self.refusedAttachments = refusedAttachments
    }
}

private struct SyncState: Codable {
    struct PendingOperation: Codable, Equatable {
        enum Kind: String, Codable { case folderCreate, update, rename, move, delete }
        var kind: Kind
        var noteID: String?
        var expected: String
    }
    struct Entry: Codable {
        var path: String
        var hash: String
        var base: String
        var title: String
        var folder: [String]
        var modified: Date?
        var conflicted: Bool?
        var pendingCreate: Bool?
    }
    var version = 1
    var rootFolder: String
    var entries: [String: Entry]
    var pending: [PendingOperation]? = nil
}

private struct LocalNote {
    var url: URL
    var relativePath: String
    var markdown: MarkdownFile
}

public final class MarkdownSync {
    private let reader: any NotesReading
    private let writer: (any NotesWriting)?
    private let fileManager: FileManager

    public init(reader: any NotesReading, writer: (any NotesWriting)?, fileManager: FileManager = .default) {
        self.reader = reader; self.writer = writer; self.fileManager = fileManager
    }

    public static func syncedFolder(at directory: URL) -> String? {
        let url = directory.appendingPathComponent(".notescli-sync.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let state = try? decoder.decode(SyncState.self, from: data) else { return nil }
        return state.rootFolder
    }

    public func run(_ options: SyncOptions) throws -> SyncReport {
        let root = options.directory.standardizedFileURL.resolvingSymlinksInPath()
        if !options.dryRun { try fileManager.createPrivateDirectory(at: root) }
        let stateURL = root.appendingPathComponent(".notescli-sync.json")
        var state = try loadState(stateURL, folder: options.folder)
        let rootFolder = try resolveRoot(options.folder)
        if !options.dryRun { try reconcilePending(&state, stateURL: stateURL) }
        var oldState = state
        let remoteSummaries = try reader.notes(NoteQuery()).filter { !$0.isDeleted && $0.folderPath.starts(with: rootFolder.path) }
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteSummaries.map { ($0.id.uuid, $0) })
        var local = try scan(root)
        for (id, entry) in oldState.entries where remoteByID[id] == nil {
            let resolvedID: String?
            if let resolved = try? reader.note(id), !resolved.summary.id.uuid.isEmpty, remoteByID[resolved.summary.id.uuid] != nil {
                resolvedID = resolved.summary.id.uuid
            } else if entry.pendingCreate == true {
                let candidates = remoteSummaries.filter {
                    $0.title == entry.title && relativeFolder($0, rootFolder: rootFolder) == entry.folder
                }
                resolvedID = candidates.count == 1 ? candidates[0].id.uuid : nil
            } else { resolvedID = nil }
            guard let stableID = resolvedID else { continue }
            var stableEntry = entry; stableEntry.pendingCreate = nil
            oldState.entries.removeValue(forKey: id); oldState.entries[stableID] = stableEntry
            state.entries.removeValue(forKey: id); state.entries[stableID] = stableEntry
            if let index = local.firstIndex(where: { $0.markdown.noteID == id || $0.relativePath == entry.path }) {
                local[index].markdown.noteID = stableID
                if !options.dryRun { try write(local[index].markdown, to: local[index].url) }
            }
        }
        let pairs = local.compactMap { item in item.markdown.noteID.map { ($0, item) } }
        guard Dictionary(grouping: pairs, by: { $0.0 }).values.allSatisfy({ $0.count == 1 }) else {
            throw NotesSyncError.invalidState("Two Markdown files contain the same notes-id.")
        }
        let localByID = Dictionary(uniqueKeysWithValues: pairs)
        var report = SyncReport(), handledLocal: Set<String> = [], handledRemote: Set<String> = []
        var knownFolders = Set(try reader.folders(account: rootFolder.accountID).map { $0.path.joined(separator: " > ") })
        let lossless = (writer as? any LosslessAttachmentWriting)?.supportsLosslessAttachmentRoundTrip == true

        for (id, previous) in oldState.entries.sorted(by: { $0.key < $1.key }) {
            let remote = remoteByID[id]
            var localNote = localByID[id]
            if localNote == nil {
                let oldURL = try SafePath.child(previous.path, of: root)
                if fileManager.fileExists(atPath: oldURL.path), let text = try? String(contentsOf: oldURL, encoding: .utf8) {
                    localNote = LocalNote(url: oldURL, relativePath: previous.path,
                                          markdown: .parse(text, fallbackTitle: oldURL.deletingPathExtension().lastPathComponent))
                }
            }
            if remote != nil { handledRemote.insert(id) }
            if let localNote { handledLocal.insert(localNote.relativePath) }

            if remote == nil && localNote == nil {
                state.entries.removeValue(forKey: id)
                continue
            }
            if remote == nil, previous.pendingCreate == true {
                report.actions.append(.init(.skip, noteID: id, path: localNote?.relativePath,
                                            message: "A prior create had no verified outcome. No retry was made."))
                continue
            }
            if remote == nil, let localNote {
                if options.propagateDeletes {
                    report.actions.append(.init(.deleteLocal, noteID: id, path: localNote.relativePath, message: "Delete local file because the Notes copy was deleted."))
                    if !options.dryRun { try fileManager.removeItem(at: localNote.url); state.entries.removeValue(forKey: id) }
                } else {
                    report.actions.append(.init(.restore, noteID: id, path: localNote.relativePath, message: "Recreate the missing Notes copy."))
                    if !options.dryRun {
                        let folder = try ensureFolder(for: localNote.relativePath, rootFolder: rootFolder, options: options, report: &report, known: &knownFolders, state: &state, stateURL: stateURL)
                        let result = try requireWriter().createNote(title: localNote.markdown.title, markdown: localNote.markdown.body, folder: folder)
                        if result.outcome != .verified {
                            try stagePendingCreate(result: result, file: localNote.markdown, path: localNote.relativePath,
                                                   replacing: id, state: &state, stateURL: stateURL, root: root)
                            if result.outcome == .unknown { throw NotesSyncError.writeUnknown("The outcome of recreate note is unknown. Read both sides before retrying.") }
                            continue
                        }
                        guard let newID = resultID(result) else { throw NotesSyncError.invalidState("The writer did not return the recreated note ID.") }
                        var file = localNote.markdown; file.noteID = newID; file.modified = Date()
                        try write(file, to: localNote.url)
                        state.entries.removeValue(forKey: id)
                        state.entries[newID] = entry(file: file, path: localNote.relativePath, folder: relativeFolder(localNote.relativePath), modified: file.modified)
                    }
                }
                continue
            }
            guard let remote else { continue }
            guard let remoteNote = try readableNote(remote, report: &report) else { continue }
            if hasUnsupportedAttachments(remoteNote, summary: remote, lossless: lossless) {
                report.refusedAttachments += 1
                report.actions.append(.init(.skip, noteID: id, path: localNote?.relativePath, message: "Refused: attachments cannot be round-tripped losslessly."))
                continue
            }
            let remoteBody = markdown(remoteNote)
            if localNote == nil {
                if options.propagateDeletes {
                    report.actions.append(.init(.deleteNote, noteID: id, path: previous.path, message: "Move the Notes copy to Recently Deleted because the local file was deleted."))
                    if !options.dryRun {
                        guard try accepted(requireWriter().deleteNote(id), action: "delete note", pending: .init(kind: .delete, noteID: id, expected: ""), state: &state, stateURL: stateURL) else { continue }
                        state.entries.removeValue(forKey: id)
                    }
                } else {
                    let path = uniquePath(for: remote, rootFolder: rootFolder, occupied: Set(local.map(\.relativePath)), preferred: previous.path)
                    report.actions.append(.init(.restore, noteID: id, path: path, message: "Restore the missing local file."))
                    if !options.dryRun {
                        let file = MarkdownFile(noteID: id, title: remote.title, modified: remote.modified, body: remoteBody)
                        try write(file, to: SafePath.child(path, of: root))
                        state.entries[id] = entry(file: file, path: path, folder: relativeFolder(remote, rootFolder: rootFolder), modified: remote.modified)
                    }
                }
                continue
            }
            guard var localNote else { continue }
            let localHash = StableHash.hex(localNote.markdown.body), remoteHash = StableHash.hex(remoteBody)
            let localMetadataChanged = localNote.relativePath != previous.path || localNote.markdown.title != previous.title
            let remoteFolder = relativeFolder(remote, rootFolder: rootFolder)
            let remoteMetadataChanged = remote.title != previous.title || remoteFolder != previous.folder
            let localChanged = localHash != previous.hash
            let remoteChanged = remoteHash != previous.hash

            if previous.conflicted == true && localNote.markdown.body.contains("<<<<<<< LOCAL") {
                report.conflicts += 1
                report.actions.append(.init(.conflict, noteID: id, path: localNote.relativePath,
                                            message: remoteChanged ? "The conflict is unresolved and Notes changed again." : "Resolve the existing conflict markers before syncing."))
                continue
            }

            if localChanged && remoteChanged && localNote.markdown.body == remoteBody {
                report.actions.append(.init(.updateNote, noteID: id, path: localNote.relativePath,
                                            message: "Both copies already contain the same body; reconcile metadata only."))
                if !options.dryRun {
                    let filenameTitle = localNote.url.deletingPathExtension().lastPathComponent
                    let localTitle = localNote.markdown.title == previous.title && localNote.relativePath != previous.path ? filenameTitle : localNote.markdown.title
                    if localMetadataChanged && localTitle != remote.title {
                        guard try accepted(requireWriter().renameNote(id, title: localTitle), action: "rename note", pending: .init(kind: .rename, noteID: id, expected: localTitle), state: &state, stateURL: stateURL) else { continue }
                        localNote.markdown.title = localTitle
                    } else if remoteMetadataChanged && !localMetadataChanged { localNote.markdown.title = remote.title }
                    if localMetadataChanged && relativeFolder(localNote.relativePath) != remoteFolder {
                        let destination = try ensureFolder(for: localNote.relativePath, rootFolder: rootFolder, options: options, report: &report, known: &knownFolders, state: &state, stateURL: stateURL)
                        guard try accepted(requireWriter().moveNote(id, toFolder: destination), action: "move note", pending: .init(kind: .move, noteID: id, expected: destination), state: &state, stateURL: stateURL) else { continue }
                    }
                    localNote.markdown.modified = remote.modified
                    try write(localNote.markdown, to: localNote.url)
                    state.entries[id] = entry(file: localNote.markdown, path: localNote.relativePath,
                                              folder: localMetadataChanged ? relativeFolder(localNote.relativePath) : remoteFolder,
                                              modified: remote.modified)
                }
                continue
            }

            if localChanged && remoteChanged {
                let merged = Diff3.merge(base: previous.base, local: localNote.markdown.body, remote: remoteBody)
                if merged.hadConflicts {
                    report.conflicts += 1
                    report.actions.append(.init(.conflict, noteID: id, path: localNote.relativePath, message: "Both copies changed the same lines; conflict markers were written locally."))
                    if !options.dryRun {
                        localNote.markdown.body = merged.text; try write(localNote.markdown, to: localNote.url)
                        state.entries[id] = .init(path: localNote.relativePath, hash: remoteHash, base: remoteBody,
                                                  title: remote.title, folder: remoteFolder, modified: remote.modified, conflicted: true)
                    }
                    continue
                }
                report.actions.append(.init(.updateNote, noteID: id, path: localNote.relativePath, message: "Merge non-overlapping edits into both copies."))
                if !options.dryRun {
                    guard try accepted(requireWriter().replaceBody(id, markdown: merged.text), action: "merge note", pending: .init(kind: .update, noteID: id, expected: StableHash.hex(merged.text)), state: &state, stateURL: stateURL) else { continue }
                    localNote.markdown.body = merged.text; localNote.markdown.modified = Date(); try write(localNote.markdown, to: localNote.url)
                    state.entries[id] = entry(file: localNote.markdown, path: localNote.relativePath, folder: relativeFolder(localNote.relativePath), modified: localNote.markdown.modified)
                }
            } else if localChanged || localMetadataChanged {
                report.actions.append(.init(.updateNote, noteID: id, path: localNote.relativePath, message: "Apply the local Markdown changes to Notes."))
                if !options.dryRun {
                    if localChanged, !(try accepted(requireWriter().replaceBody(id, markdown: localNote.markdown.body), action: "update note", pending: .init(kind: .update, noteID: id, expected: StableHash.hex(localNote.markdown.body)), state: &state, stateURL: stateURL)) { continue }
                    let filenameTitle = localNote.url.deletingPathExtension().lastPathComponent
                    let localTitle = localNote.markdown.title == previous.title && localNote.relativePath != previous.path ? filenameTitle : localNote.markdown.title
                    if localTitle != remote.title {
                        guard try accepted(requireWriter().renameNote(id, title: localTitle), action: "rename note", pending: .init(kind: .rename, noteID: id, expected: localTitle), state: &state, stateURL: stateURL) else { continue }
                        localNote.markdown.title = localTitle
                    }
                    if relativeFolder(localNote.relativePath) != remoteFolder {
                        let destination = try ensureFolder(for: localNote.relativePath, rootFolder: rootFolder, options: options, report: &report, known: &knownFolders, state: &state, stateURL: stateURL)
                        guard try accepted(requireWriter().moveNote(id, toFolder: destination), action: "move note", pending: .init(kind: .move, noteID: id, expected: destination), state: &state, stateURL: stateURL) else { continue }
                    }
                    localNote.markdown.modified = Date(); try write(localNote.markdown, to: localNote.url)
                    state.entries[id] = entry(file: localNote.markdown, path: localNote.relativePath, folder: relativeFolder(localNote.relativePath), modified: localNote.markdown.modified)
                }
            } else if remoteChanged || remoteMetadataChanged {
                let path = uniquePath(for: remote, rootFolder: rootFolder, occupied: Set(local.map(\.relativePath)).subtracting([localNote.relativePath]), preferred: nil)
                report.actions.append(.init(.updateLocal, noteID: id, path: path, message: "Apply the Notes changes to the local Markdown file."))
                if !options.dryRun {
                    let file = MarkdownFile(noteID: id, title: remote.title, modified: remote.modified, body: remoteBody)
                    let target = try SafePath.child(path, of: root)
                    try write(file, to: target)
                    if target != localNote.url, fileManager.fileExists(atPath: localNote.url.path) { try fileManager.removeItem(at: localNote.url) }
                    state.entries[id] = entry(file: file, path: path, folder: remoteFolder, modified: remote.modified)
                }
            }
        }

        for summary in remoteSummaries where !handledRemote.contains(summary.id.uuid) {
            guard let note = try readableNote(summary, report: &report) else { continue }
            if hasUnsupportedAttachments(note, summary: summary, lossless: lossless) {
                report.refusedAttachments += 1
                report.actions.append(.init(.skip, noteID: summary.id.uuid, message: "Refused: attachments cannot be round-tripped losslessly."))
                continue
            }
            let path = uniquePath(for: summary, rootFolder: rootFolder, occupied: Set(local.map(\.relativePath))
                .union(state.entries.values.map(\.path)), preferred: nil)
            report.actions.append(.init(.createLocal, noteID: summary.id.uuid, path: path, message: "Create a Markdown file for the Notes copy."))
            if !options.dryRun {
                let file = MarkdownFile(noteID: summary.id.uuid, title: summary.title, modified: summary.modified, body: markdown(note))
                try write(file, to: SafePath.child(path, of: root))
                state.entries[summary.id.uuid] = entry(file: file, path: path, folder: relativeFolder(summary, rootFolder: rootFolder), modified: summary.modified)
            }
        }

        local = try scan(root)
        for item in local where item.markdown.noteID == nil && !handledLocal.contains(item.relativePath) {
            report.actions.append(.init(.createNote, path: item.relativePath, message: "Create a Notes copy for the new Markdown file."))
            if !options.dryRun {
                let folder = try ensureFolder(for: item.relativePath, rootFolder: rootFolder, options: options, report: &report, known: &knownFolders, state: &state, stateURL: stateURL)
                let title = item.markdown.title.isEmpty ? item.url.deletingPathExtension().lastPathComponent : item.markdown.title
                let result = try requireWriter().createNote(title: title, markdown: item.markdown.body, folder: folder)
                if result.outcome != .verified {
                    try stagePendingCreate(result: result, file: item.markdown, path: item.relativePath,
                                           replacing: nil, state: &state, stateURL: stateURL, root: root)
                    if result.outcome == .unknown { throw NotesSyncError.writeUnknown("The outcome of create note is unknown. Read both sides before retrying.") }
                    continue
                }
                guard let id = resultID(result) else { continue }
                var file = item.markdown; file.noteID = id; file.title = title; file.modified = Date()
                try write(file, to: item.url)
                state.entries[id] = entry(file: file, path: item.relativePath, folder: relativeFolder(item.relativePath), modified: file.modified)
            }
        }

        if !options.dryRun { try saveState(state, to: stateURL) }
        return report
    }

    private func resolveRoot(_ reference: String) throws -> Folder {
        let matches = try reader.folders(account: nil).filter {
            $0.id == reference || $0.name == reference || $0.path.joined(separator: " > ") == reference
        }
        guard matches.count == 1 else {
            throw NotesSyncError.invalidState(matches.isEmpty ? "Sync folder not found: \(reference)" : "Sync folder is ambiguous: \(reference)")
        }
        return matches[0]
    }

    private func loadState(_ url: URL, folder: String) throws -> SyncState {
        guard fileManager.fileExists(atPath: url.path) else { return SyncState(rootFolder: folder, entries: [:]) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(SyncState.self, from: Data(contentsOf: url))
        guard state.rootFolder == folder else { throw NotesSyncError.invalidState("This directory is already synced with \(state.rootFolder).") }
        return state
    }

    private func saveState(_ state: SyncState, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func scan(_ root: URL) throws -> [LocalNote] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var notes: [LocalNote] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" && !url.lastPathComponent.contains(".conflict-") {
            guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            let resolved = url.resolvingSymlinksInPath()
            let rootComponents = root.resolvingSymlinksInPath().pathComponents
            let components = resolved.pathComponents
            guard components.starts(with: rootComponents) else { throw NotesSyncError.invalidPath(url.path) }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            let text = try InputFile.readText(resolved, kind: "Markdown file", maxBytes: InputFile.maxTextBytes)
            notes.append(LocalNote(url: resolved, relativePath: relative, markdown: .parse(text, fallbackTitle: resolved.deletingPathExtension().lastPathComponent)))
        }
        return notes.sorted { $0.relativePath < $1.relativePath }
    }

    private func write(_ file: MarkdownFile, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(file.rendered().utf8).write(to: url, options: .atomic)
    }

    private func markdown(_ note: Note) -> String { note.document.map { NoteRenderer.markdown($0, attachments: note.attachments) } ?? "" }
    private func entry(file: MarkdownFile, path: String, folder: [String], modified: Date?) -> SyncState.Entry {
        .init(path: path, hash: StableHash.hex(file.body), base: file.body, title: file.title, folder: folder,
              modified: modified, conflicted: nil, pendingCreate: nil)
    }
    private func relativeFolder(_ path: String) -> [String] { Array(path.split(separator: "/").dropLast().map(String.init)) }
    private func relativeFolder(_ summary: NoteSummary, rootFolder: Folder) -> [String] { Array(summary.folderPath.dropFirst(rootFolder.path.count)) }

    private func uniquePath(for summary: NoteSummary, rootFolder: Folder, occupied: Set<String>, preferred: String?) -> String {
        if let preferred { return preferred }
        let folder = relativeFolder(summary, rootFolder: rootFolder).map { SafePath.component($0) }
        let stem = SafePath.component(summary.title)
        var path = (folder + [stem + ".md"]).joined(separator: "/")
        if occupied.contains(path) { path = (folder + [stem + "--" + SafePath.component(summary.id.uuid, limit: 24) + ".md"]).joined(separator: "/") }
        return path
    }

    private func ensureFolder(for relativePath: String, rootFolder: Folder, options: SyncOptions, report: inout SyncReport,
                              known: inout Set<String>, state: inout SyncState, stateURL: URL) throws -> String {
        let parts = relativeFolder(relativePath)
        var parent = rootFolder.path.joined(separator: " > ")
        for part in parts {
            let path = parent + " > " + part
            if !known.contains(path) {
                report.actions.append(.init(.move, path: relativePath, message: "Create Notes folder \(path)."))
                if !options.dryRun {
                    guard try accepted(requireWriter().createFolder(name: part, parent: parent, account: rootFolder.accountID),
                                       action: "create folder", pending: .init(kind: .folderCreate, noteID: nil, expected: path),
                                       state: &state, stateURL: stateURL) else { break }
                }
                known.insert(path)
            }
            parent = path
        }
        return parent
    }

    private func hasUnsupportedAttachments(_ note: Note, summary: NoteSummary, lossless: Bool) -> Bool {
        !lossless && (summary.attachmentCount > 0 || !note.attachments.isEmpty)
    }

    private func readableNote(_ summary: NoteSummary, report: inout SyncReport) throws -> Note? {
        if summary.isLocked {
            report.actions.append(.init(.skip, noteID: summary.id.uuid, message: "Refused: the note is locked."))
            return nil
        }
        do {
            let note = try reader.note(summary.id.uuid)
            guard note.document != nil else {
                report.actions.append(.init(.skip, noteID: summary.id.uuid, message: "Refused: the note body is not downloaded."))
                return nil
            }
            return note
        } catch let error as NotesError where error.code == "body_unavailable" {
            report.actions.append(.init(.skip, noteID: summary.id.uuid, message: "Refused: the note body is not downloaded."))
            return nil
        }
    }

    private func requireWriter() throws -> any NotesWriting {
        guard let writer else { throw NotesSyncError.invalidState("A writer is required for this sync action.") }
        return writer
    }

    private func accepted(_ result: WriteResult, action: String, pending: SyncState.PendingOperation,
                          state: inout SyncState, stateURL: URL) throws -> Bool {
        if result.outcome == .unknown {
            var operations = state.pending ?? []
            operations.append(pending)
            state.pending = operations
            try saveState(state, to: stateURL)
            throw NotesSyncError.writeUnknown("The outcome of \(action) is unknown. Read both sides before retrying.")
        }
        return result.outcome == .verified
    }

    private func reconcilePending(_ state: inout SyncState, stateURL: URL) throws {
        guard let pending = state.pending, !pending.isEmpty else { return }
        let folders = try reader.folders(account: nil)
        var unresolved: [SyncState.PendingOperation] = []
        for operation in pending {
            let applied: Bool
            switch operation.kind {
            case .folderCreate:
                applied = folders.contains { $0.path.joined(separator: " > ") == operation.expected }
            case .update:
                applied = operation.noteID.flatMap { try? reader.note($0) }
                    .map { StableHash.hex(markdown($0)) == operation.expected } ?? false
            case .rename:
                applied = operation.noteID.flatMap { try? reader.note($0) }?.summary.title == operation.expected
            case .move:
                applied = operation.noteID.flatMap { try? reader.note($0) }?.summary.folderPath.joined(separator: " > ") == operation.expected
            case .delete:
                guard let id = operation.noteID else { applied = false; break }
                do { applied = try reader.summary(id).isDeleted }
                catch let error as NotesError { applied = error.code == "note_not_found" }
                catch { applied = false }
            }
            if !applied { unresolved.append(operation) }
        }
        state.pending = unresolved.isEmpty ? nil : unresolved
        try saveState(state, to: stateURL)
        if !unresolved.isEmpty {
            throw NotesSyncError.writeUnknown("A prior sync write still has an unknown outcome. No write was retried.")
        }
    }

    private func resultID(_ result: WriteResult) -> String? {
        if let uuid = result.noteID?.uuid, !uuid.isEmpty { return uuid }
        return result.noteID?.coreDataID
    }

    private func stagePendingCreate(result: WriteResult, file: MarkdownFile, path: String, replacing oldID: String?,
                                    state: inout SyncState, stateURL: URL, root: URL) throws {
        let pendingID = resultID(result) ?? "pending:" + UUID().uuidString
        var pendingFile = file; pendingFile.noteID = pendingID
        if let oldID { state.entries.removeValue(forKey: oldID) }
        var pendingEntry = entry(file: pendingFile, path: path, folder: relativeFolder(path), modified: pendingFile.modified)
        pendingEntry.pendingCreate = true
        state.entries[pendingID] = pendingEntry
        try write(pendingFile, to: SafePath.child(path, of: root))
        try saveState(state, to: stateURL)
    }
}
