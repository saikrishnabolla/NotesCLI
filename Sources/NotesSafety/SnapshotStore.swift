import CryptoKit
import Darwin
import AVFoundation
import Foundation
import NotesCore
import UniformTypeIdentifiers

public struct SnapshotInfo: Codable, Sendable, Equatable {
    public var id: String
    public var noteID: String
    public var created: Date
    public var title: String
    public var folderPath: [String]
    public var directory: URL
    public var restorable: Bool

    public init(id: String, noteID: String, created: Date, title: String, folderPath: [String], directory: URL, restorable: Bool) {
        self.id = id; self.noteID = noteID; self.created = created; self.title = title
        self.folderPath = folderPath; self.directory = directory; self.restorable = restorable
    }

    private enum CodingKeys: String, CodingKey { case id, noteID, created, title, folderPath, directory, restorable }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); noteID = try values.decode(String.self, forKey: .noteID)
        created = try values.decode(Date.self, forKey: .created); title = try values.decode(String.self, forKey: .title)
        folderPath = try values.decode([String].self, forKey: .folderPath); directory = try values.decode(URL.self, forKey: .directory)
        restorable = try values.decodeIfPresent(Bool.self, forKey: .restorable) ?? true
    }
}

public struct NoteSnapshot: Sendable {
    public var formatVersion: Int?
    public var info: SnapshotInfo
    public var note: Note
    public var markdown: String
    public var attachmentArchive: SnapshotAttachmentArchive?

    public init(formatVersion: Int? = nil, info: SnapshotInfo, note: Note, markdown: String,
                attachmentArchive: SnapshotAttachmentArchive? = nil) {
        self.formatVersion = formatVersion
        self.info = info
        self.note = note
        self.markdown = markdown
        self.attachmentArchive = attachmentArchive
    }

}

private struct PersistedSnapshot: Codable, Sendable {
    var formatVersion: Int?
    var recordingIntegerSemanticsVersion: Int?
    var info: SnapshotInfo
    var note: Note
    var markdown: String
}

private struct SnapshotFileIntegrity: Codable, Sendable, Equatable {
    var byteCount: Int
    var sha256: String
}

private struct SnapshotIntegrityManifest: Codable, Sendable {
    var formatVersion: Int
    var algorithm: String
    var snapshotID: String
    var noteID: String
    var files: [String: SnapshotFileIntegrity]
}

private enum SnapshotArchiveSkip: Error {
    case reason(String)
}

public struct SnapshotStore: Sendable {
    public let rootURL: URL
    public let attachmentRoots: [URL]

    private static let currentFormatVersion = 3
    private static let archiveFormatVersion = 1
    private static let manifestName = "integrity.json"
    private static let archiveName = "attachments.json"
    private static let v2RequiredFiles = ["note.json", "note.md"]
    private static let v3RequiredFiles = ["note.json", "note.md", "attachments.json"]
    private static let maxAttachmentBytes = 200 * 1024 * 1024
    private static let maxSnapshotAttachmentBytes = 1024 * 1024 * 1024

    public init(rootURL: URL = NotesSafetyPaths.snapshots, attachmentRoots: [URL]? = nil) {
        self.rootURL = rootURL
        self.attachmentRoots = attachmentRoots ?? [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes", isDirectory: true)]
    }

    @discardableResult
    public func save(_ note: Note, now: Date = Date(), drawingPayloads: [String: Data] = [:],
                     paperBundlePayloads: [String: Data] = [:],
                     linkPayloads: [String: SnapshotLinkPayload] = [:],
                     scanMarkupPayloads: [String: Data] = [:]) throws -> SnapshotInfo {
        let fileManager = FileManager.default
        let noteDirectory = rootURL.appendingPathComponent(note.summary.id.uuid, isDirectory: true)
        try fileManager.createDirectory(at: noteDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let (id, claim) = try Self.claimSnapshotID(Self.snapshotID(now), in: noteDirectory)
        defer { try? fileManager.removeItem(at: claim) }
        let directory = noteDirectory.appendingPathComponent(id, isDirectory: true)
        let staging = noteDirectory.appendingPathComponent(".\(id)-\(UUID().uuidString).tmp", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: staging) }

        let info = SnapshotInfo(id: id, noteID: note.summary.id.uuid, created: now, title: note.summary.title,
                                folderPath: note.summary.folderPath, directory: directory,
                                restorable: note.document != nil)
        let markdown = note.document?.markdown(attachments: note.attachments) ?? ""
        let archive = try archiveAttachments(note.attachments, drawingPayloads: drawingPayloads,
                                             paperBundlePayloads: paperBundlePayloads,
                                             linkPayloads: linkPayloads,
                                             scanMarkupPayloads: scanMarkupPayloads, in: staging)
        let persisted = PersistedSnapshot(formatVersion: Self.currentFormatVersion,
                                          recordingIntegerSemanticsVersion: 1, info: info,
                                          note: Self.withoutRuntimePaths(note), markdown: markdown)
        let noteData = try Self.encoder().encode(persisted)
        let markdownData = Data(markdown.utf8)
        let archiveData = try Self.encoder().encode(archive)
        var files = [
            "note.json": Self.integrity(for: noteData),
            "note.md": Self.integrity(for: markdownData),
            Self.archiveName: Self.integrity(for: archiveData),
        ]
        for material in archive.attachments where material.archived {
            let hash = material.blobSHA256!
            files["blobs/\(hash)"] = SnapshotFileIntegrity(byteCount: material.byteCount!, sha256: hash)
        }
        for material in archive.attachments where material.paperBundleArchived {
            let hash = material.paperBundleSHA256!
            files["blobs/\(hash)"] = SnapshotFileIntegrity(
                byteCount: material.paperBundleByteCount!, sha256: hash
            )
        }
        for material in archive.attachments {
            if let hash = material.synapseSHA256, let bytes = material.synapseByteCount {
                files["blobs/\(hash)"] = SnapshotFileIntegrity(byteCount: bytes, sha256: hash)
            }
            if let hash = material.linkMetadataSHA256, let bytes = material.linkMetadataByteCount {
                files["blobs/\(hash)"] = SnapshotFileIntegrity(byteCount: bytes, sha256: hash)
            }
        }
        for material in archive.attachments {
            if let hash = material.scanMarkupSHA256, let bytes = material.scanMarkupByteCount {
                files["blobs/\(hash)"] = SnapshotFileIntegrity(byteCount: bytes, sha256: hash)
            }
        }
        let manifest = SnapshotIntegrityManifest(
            formatVersion: Self.currentFormatVersion,
            algorithm: "SHA-256",
            snapshotID: id,
            noteID: note.summary.id.uuid,
            files: files
        )
        try Self.write(noteData, named: "note.json", in: staging)
        try Self.write(markdownData, named: "note.md", in: staging)
        try Self.write(archiveData, named: Self.archiveName, in: staging)
        try Self.write(try Self.encoder().encode(manifest), named: Self.manifestName, in: staging)
        try fileManager.moveItem(at: staging, to: directory)
        return info
    }

    private func archiveAttachments(_ attachments: [Attachment], drawingPayloads: [String: Data],
                                    paperBundlePayloads: [String: Data],
                                    linkPayloads: [String: SnapshotLinkPayload],
                                    scanMarkupPayloads: [String: Data],
                                    in staging: URL) throws -> SnapshotAttachmentArchive {
        let fileManager = FileManager.default
        let blobs = staging.appendingPathComponent("blobs", isDirectory: true)
        try fileManager.createDirectory(at: blobs, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        let allowedRoots = attachmentRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        var materials: [SnapshotAttachmentMaterial] = []
        var seenIDs: Set<String> = []
        var archivedHashes: Set<String> = []
        var archivedBytes = 0

        func archive(_ data: Data) throws -> SnapshotFileIntegrity {
            let integrity = Self.integrity(for: data)
            guard integrity.byteCount > 0, integrity.byteCount <= Self.maxAttachmentBytes else {
                throw SnapshotArchiveSkip.reason("attachment_size_limit")
            }
            if !archivedHashes.contains(integrity.sha256),
               archivedBytes + integrity.byteCount > Self.maxSnapshotAttachmentBytes {
                throw SnapshotArchiveSkip.reason("snapshot_size_limit")
            }
            let destination = blobs.appendingPathComponent(integrity.sha256)
            if !fileManager.fileExists(atPath: destination.path) {
                let temporary = blobs.appendingPathComponent(".\(UUID().uuidString).tmp")
                defer { try? fileManager.removeItem(at: temporary) }
                try data.write(to: temporary, options: .withoutOverwriting)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                try fileManager.moveItem(at: temporary, to: destination)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                archivedBytes += integrity.byteCount
                archivedHashes.insert(integrity.sha256)
            }
            return integrity
        }

        func addPaperBundle(_ material: inout SnapshotAttachmentMaterial,
                            attachment: Attachment) throws {
            guard let payload = paperBundlePayloads[attachment.id] else { return }
            guard attachment.typeUTI.lowercased().contains("paper") else {
                throw NotesError("invalid_snapshot_attachment", "A Paper bundle was supplied for non-Paper attachment \(attachment.id).")
            }
            let integrity = try archive(payload)
            material.paperBundleSHA256 = integrity.sha256
            material.paperBundleByteCount = integrity.byteCount
        }

        func addLinkPayload(_ material: inout SnapshotAttachmentMaterial,
                            attachment: Attachment) throws {
            guard let payload = linkPayloads[attachment.id] else { return }
            guard attachment.url != nil || (attachment.synapseDataBytes ?? 0) > 0 ||
                    (attachment.linkPreviewMetadataBytes ?? 0) > 0 else {
                throw NotesError("invalid_snapshot_attachment", "Private link data was supplied for a non-link attachment \(attachment.id).")
            }
            if let data = payload.synapseData {
                let integrity = try archive(data)
                material.synapseSHA256 = integrity.sha256
                material.synapseByteCount = integrity.byteCount
            }
            if let data = payload.linkPresentationMetadata {
                let integrity = try archive(data)
                material.linkMetadataSHA256 = integrity.sha256
                material.linkMetadataByteCount = integrity.byteCount
            }
            guard material.synapseSHA256 != nil || material.linkMetadataSHA256 != nil else {
                throw NotesError("invalid_snapshot_attachment", "Private link data for \(attachment.id) was empty.")
            }
        }

        func validateMarkup(_ attachment: Attachment) throws {
            let type = UTType(attachment.typeUTI)
            guard type?.conforms(to: .image) == true || type?.conforms(to: .pdf) == true else {
                throw NotesError("invalid_snapshot_attachment", "Markup was supplied for unsupported attachment type \(attachment.id).")
            }
            guard attachment.scanHasMarkup == true || (attachment.markupDataBytes ?? 0) > 0 else {
                throw NotesError("invalid_snapshot_attachment", "Markup was supplied for an attachment without saved markup state \(attachment.id).")
            }
        }

        func unavailable(_ attachment: Attachment, parentID: String?, reason: String) throws {
            var material = SnapshotAttachmentMaterial(
                id: attachment.id, typeUTI: attachment.typeUTI, filename: attachment.filename,
                title: attachment.title, parentID: parentID, unavailableReason: reason
            )
            try addPaperBundle(&material, attachment: attachment)
            try addLinkPayload(&material, attachment: attachment)
            if let markup = scanMarkupPayloads[attachment.id] {
                try validateMarkup(attachment)
                let integrity = try archive(markup)
                material.scanMarkupSHA256 = integrity.sha256
                material.scanMarkupByteCount = integrity.byteCount
            }
            materials.append(material)
        }

        func addScanMarkup(_ material: inout SnapshotAttachmentMaterial,
                           attachment: Attachment, parentID: String?) throws {
            guard let payload = scanMarkupPayloads[attachment.id] else { return }
            try validateMarkup(attachment)
            let integrity = try archive(payload)
            material.scanMarkupSHA256 = integrity.sha256
            material.scanMarkupByteCount = integrity.byteCount
        }

        func collect(_ attachment: Attachment, parentID: String?) throws {
            guard seenIDs.insert(attachment.id).inserted else {
                throw NotesError("invalid_snapshot_attachment", "Attachment \(attachment.id) appears more than once in the note graph.")
            }
            if let payload = drawingPayloads[attachment.id] {
                guard attachment.kind == "drawing" else {
                    throw NotesError("invalid_snapshot_attachment", "A native drawing payload was supplied for non-drawing attachment \(attachment.id).")
                }
                do {
                    let integrity = try archive(payload)
                    let lowerType = attachment.typeUTI.lowercased()
                    let payloadKind: String
                    if lowerType.contains("sketch") ||
                        (lowerType.contains("drawing") && !lowerType.contains("paper")) {
                        payloadKind = "legacy-drawing-v1"
                    } else if let array = try? JSONSerialization.jsonObject(with: payload) as? [Any],
                              array.first is [Any] {
                        payloadKind = "paper-canvases-v1"
                    } else {
                        payloadKind = "paper-strokes-v1"
                    }
                    var material = SnapshotAttachmentMaterial(
                        id: attachment.id, typeUTI: attachment.typeUTI, filename: attachment.filename,
                        title: attachment.title, parentID: parentID, blobSHA256: integrity.sha256,
                        byteCount: integrity.byteCount, payloadKind: payloadKind
                    )
                    try addPaperBundle(&material, attachment: attachment)
                    try addLinkPayload(&material, attachment: attachment)
                    try addScanMarkup(&material, attachment: attachment, parentID: parentID)
                    materials.append(material)
                } catch SnapshotArchiveSkip.reason(let reason) {
                    try unavailable(attachment, parentID: parentID, reason: reason)
                }
                for child in attachment.childAttachments ?? [] { try collect(child, parentID: attachment.id) }
                return
            }
            guard let path = attachment.filePath, !path.isEmpty else {
                try unavailable(attachment, parentID: parentID, reason: "not_downloaded")
                for child in attachment.childAttachments ?? [] { try collect(child, parentID: attachment.id) }
                return
            }
            let source = URL(fileURLWithPath: path).standardizedFileURL
            let resolvedParent = source.deletingLastPathComponent().resolvingSymlinksInPath()
            let insideAllowedRoot = allowedRoots.contains { root in
                resolvedParent.path == root.path || resolvedParent.path.hasPrefix(root.path + "/")
            }
            guard insideAllowedRoot else {
                try unavailable(attachment, parentID: parentID, reason: "outside_notes_container")
                for child in attachment.childAttachments ?? [] { try collect(child, parentID: attachment.id) }
                return
            }
            do {
                let copied = try Self.readArchiveSource(source, allowedRoots: allowedRoots)
                let integrity = try archive(copied)
                var material = SnapshotAttachmentMaterial(
                    id: attachment.id, typeUTI: attachment.typeUTI, filename: attachment.filename,
                    title: attachment.title, parentID: parentID, blobSHA256: integrity.sha256,
                    byteCount: integrity.byteCount,
                    mediaDuration: attachment.kind == "audio" ? Self.audioDuration(source) : nil
                )
                try addPaperBundle(&material, attachment: attachment)
                try addLinkPayload(&material, attachment: attachment)
                try addScanMarkup(&material, attachment: attachment, parentID: parentID)
                materials.append(material)
            } catch SnapshotArchiveSkip.reason(let reason) {
                try unavailable(attachment, parentID: parentID, reason: reason)
            } catch {
                try unavailable(attachment, parentID: parentID, reason: "unreadable")
            }
            for child in attachment.childAttachments ?? [] { try collect(child, parentID: attachment.id) }
        }

        for attachment in attachments { try collect(attachment, parentID: nil) }
        guard Set(drawingPayloads.keys).isSubset(of: seenIDs) else {
            throw NotesError("invalid_snapshot_attachment", "A native drawing payload did not match an attachment in the note.")
        }
        guard Set(paperBundlePayloads.keys).isSubset(of: seenIDs) else {
            throw NotesError("invalid_snapshot_attachment", "A native Paper bundle did not match an attachment in the note.")
        }
        guard Set(linkPayloads.keys).isSubset(of: seenIDs) else {
            throw NotesError("invalid_snapshot_attachment", "Private link data did not match an attachment in the note.")
        }
        guard Set(scanMarkupPayloads.keys).isSubset(of: seenIDs) else {
            throw NotesError("invalid_snapshot_attachment", "A scan markup payload did not match an attachment in the note.")
        }
        return SnapshotAttachmentArchive(formatVersion: Self.archiveFormatVersion, attachments: materials)
    }

    private static func audioDuration(_ source: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: source), file.processingFormat.sampleRate > 0 else { return nil }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return duration.isFinite && duration > 0 && duration <= TranscriptLimits.maxSeconds ? duration : nil
    }

    private static func readArchiveSource(_ source: URL, allowedRoots: [URL]) throws -> Data {
        var pathMetadata = stat()
        guard lstat(source.path, &pathMetadata) == 0 else {
            throw SnapshotArchiveSkip.reason("unreadable")
        }
        guard pathMetadata.st_mode & S_IFMT != S_IFLNK else {
            throw SnapshotArchiveSkip.reason("symbolic_link")
        }
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SnapshotArchiveSkip.reason(errno == ELOOP ? "symbolic_link" : "unreadable")
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw SnapshotArchiveSkip.reason("unreadable")
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw SnapshotArchiveSkip.reason("not_regular_file")
        }
        guard before.st_size > 0 else {
            throw SnapshotArchiveSkip.reason("empty_file")
        }
        guard before.st_size <= maxAttachmentBytes else {
            throw SnapshotArchiveSkip.reason("file_too_large")
        }
        var actualPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &actualPath) != -1 else {
            throw SnapshotArchiveSkip.reason("unreadable")
        }
        let path = String(decoding: actualPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let actual = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard allowedRoots.contains(where: { root in
            actual.path == root.path || actual.path.hasPrefix(root.path + "/")
        }) else {
            throw SnapshotArchiveSkip.reason("outside_notes_container")
        }
        let size = Int(before.st_size)
        var data = Data(count: size)
        let count = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < size {
                let readCount = Darwin.read(descriptor, base.advanced(by: offset), size - offset)
                if readCount < 0 {
                    if errno == EINTR { continue }
                    throw SnapshotArchiveSkip.reason("unreadable")
                }
                if readCount == 0 { break }
                offset += readCount
            }
            return offset
        }
        var after = stat()
        guard count == size, fstat(descriptor, &after) == 0,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw SnapshotArchiveSkip.reason("source_changed")
        }
        return data
    }

    public func history(_ noteID: String) throws -> [SnapshotInfo] {
        try snapshotDirectories(noteID).map { try decode($0).info }.sorted { $0.created > $1.created }
    }

    public func latestSnapshot(_ noteID: String, notAfter date: Date) throws -> SnapshotInfo? {
        try history(noteID).first { $0.created <= date }
    }

    public func load(_ noteID: String, snapshot: String? = nil) throws -> NoteSnapshot {
        let directory: URL
        if let snapshot {
            guard Self.isSnapshotID(snapshot) else {
                throw NotesError("snapshot_not_found", "Snapshot \(snapshot) was not found.")
            }
            directory = rootURL.appendingPathComponent(noteID, isDirectory: true)
                .appendingPathComponent(snapshot, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw NotesError("snapshot_not_found", "Snapshot \(snapshot) was not found.")
            }
        } else {
            guard let latest = try snapshotDirectories(noteID).sorted(by: Self.newestDirectoryFirst).first else {
                throw NotesError("snapshot_not_found", "No snapshot exists for this note.")
            }
            directory = latest
        }
        return try decode(directory, expectedNoteID: noteID)
    }

    public func loadRestorable(_ noteID: String, snapshot: String? = nil) throws -> NoteSnapshot {
        let value = try load(noteID, snapshot: snapshot)
        try requireRestoreMaterial(value)
        guard value.info.restorable, value.note.document != nil else {
            throw NotesError("snapshot_not_restorable", "This snapshot has no readable note body to restore.")
        }
        return value
    }

    public func restoreMaterial(for snapshot: NoteSnapshot) throws -> SnapshotRestoreMaterial? {
        guard snapshot.formatVersion == Self.currentFormatVersion,
              let archive = snapshot.attachmentArchive else { return nil }
        try validateArchive(archive, for: snapshot.note, directory: snapshot.info.directory)
        return SnapshotRestoreMaterial(
            archive: archive,
            blobs: SnapshotDirectoryBlobSource(directory: snapshot.info.directory)
        )
    }

    private func snapshotDirectories(_ noteID: String) throws -> [URL] {
        let directory = rootURL.appendingPathComponent(noteID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.hasDirectoryPath && Self.isSnapshotID($0.lastPathComponent) }
    }

    private func decode(_ directory: URL, expectedNoteID: String? = nil) throws -> NoteSnapshot {
        let noteURL = directory.appendingPathComponent("note.json")
        guard FileManager.default.fileExists(atPath: noteURL.path) else {
            throw NotesError("snapshot_material_missing", "Snapshot \(directory.lastPathComponent) is missing note.json.")
        }
        let noteData: Data
        let snapshot: NoteSnapshot
        do {
            noteData = try packageData(named: "note.json", in: directory)
            let persisted = try Self.decoder().decode(PersistedSnapshot.self, from: noteData)
            let note = persisted.recordingIntegerSemanticsVersion == nil
                ? Self.migratingLegacyRecordingIntegers(in: persisted.note)
                : persisted.note
            snapshot = NoteSnapshot(formatVersion: persisted.formatVersion, info: persisted.info,
                                    note: note, markdown: persisted.markdown)
        } catch let error as NotesError {
            throw error
        } catch {
            throw NotesError("invalid_snapshot", "Snapshot \(directory.lastPathComponent) is unreadable.")
        }

        guard snapshot.info.id == directory.lastPathComponent,
              snapshot.info.noteID == directory.deletingLastPathComponent().lastPathComponent,
              snapshot.note.summary.id.uuid == snapshot.info.noteID,
              expectedNoteID == nil || snapshot.info.noteID == expectedNoteID else {
            throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) does not match its note or directory identity.")
        }

        if let version = snapshot.formatVersion {
            guard version == 2 || version == Self.currentFormatVersion else {
                throw NotesError("unsupported_snapshot", "Snapshot \(directory.lastPathComponent) uses unsupported format version \(version).")
            }
            let archive = try verifyManifest(in: directory, snapshot: snapshot, noteData: noteData, version: version)
            var normalized = snapshot
            normalized.info.directory = directory
            normalized.attachmentArchive = archive
            return normalized
        }

        var normalized = snapshot
        normalized.info.directory = directory
        return normalized
    }

    private func verifyManifest(in directory: URL, snapshot: NoteSnapshot, noteData: Data,
                                version: Int) throws -> SnapshotAttachmentArchive? {
        let manifestURL = directory.appendingPathComponent(Self.manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw NotesError("snapshot_material_missing", "Snapshot \(directory.lastPathComponent) is missing \(Self.manifestName).")
        }
        let manifest: SnapshotIntegrityManifest
        do {
            manifest = try Self.decoder().decode(
                SnapshotIntegrityManifest.self,
                from: packageData(named: Self.manifestName, in: directory)
            )
        } catch let error as NotesError {
            throw error
        } catch {
            throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has an unreadable integrity manifest.")
        }
        guard manifest.formatVersion == version,
              manifest.algorithm == "SHA-256",
              manifest.snapshotID == snapshot.info.id,
              manifest.noteID == snapshot.info.noteID else {
            throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has invalid integrity metadata.")
        }

        if version == 2 {
            guard Set(manifest.files.keys) == Set(Self.v2RequiredFiles) else {
                throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has invalid integrity metadata.")
            }
            try verifyPackageLayout(in: directory, expectedFiles: Set(Self.v2RequiredFiles))
            try verifyFiles(Self.v2RequiredFiles, manifest: manifest, directory: directory, noteData: noteData)
            return nil
        }

        try verifyFiles(Self.v3RequiredFiles, manifest: manifest, directory: directory, noteData: noteData)
        let archiveData: Data
        do { archiveData = try packageData(named: Self.archiveName, in: directory) }
        catch let error as NotesError { throw error }
        catch { throw NotesError("snapshot_material_missing", "Snapshot \(directory.lastPathComponent) could not read \(Self.archiveName).") }
        let archive: SnapshotAttachmentArchive
        do { archive = try Self.decoder().decode(SnapshotAttachmentArchive.self, from: archiveData) }
        catch { throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has unreadable attachment metadata.") }
        guard archive.formatVersion == Self.archiveFormatVersion else {
            throw NotesError("unsupported_snapshot", "Snapshot \(directory.lastPathComponent) uses an unsupported attachment archive.")
        }
        try validateArchive(archive, for: snapshot.note, directory: directory)
        let blobNames = Set(archive.attachments.flatMap { material in
            [material.blobSHA256, material.paperBundleSHA256, material.synapseSHA256,
             material.linkMetadataSHA256, material.scanMarkupSHA256]
                .compactMap { $0.map { "blobs/\($0)" } }
        })
        let expectedNames = Set(Self.v3RequiredFiles).union(blobNames)
        guard Set(manifest.files.keys) == expectedNames else {
            throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has unexpected or missing archived files.")
        }
        try verifyPackageLayout(in: directory, expectedFiles: expectedNames, allowBlobsDirectory: true)
        for material in archive.attachments where material.archived {
            let name = "blobs/\(material.blobSHA256!)"
            guard manifest.files[name]?.byteCount == material.byteCount else {
                throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has conflicting attachment sizes.")
            }
        }
        for material in archive.attachments where material.paperBundleArchived {
            let name = "blobs/\(material.paperBundleSHA256!)"
            guard manifest.files[name]?.byteCount == material.paperBundleByteCount else {
                throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has conflicting Paper bundle sizes.")
            }
        }
        for material in archive.attachments {
            if let hash = material.synapseSHA256 {
                guard manifest.files["blobs/\(hash)"]?.byteCount == material.synapseByteCount else {
                    throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has conflicting Synapse data sizes.")
                }
            }
            if let hash = material.linkMetadataSHA256 {
                guard manifest.files["blobs/\(hash)"]?.byteCount == material.linkMetadataByteCount else {
                    throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has conflicting link metadata sizes.")
                }
            }
        }
        for material in archive.attachments where material.scanMarkupSHA256 != nil {
            let name = "blobs/\(material.scanMarkupSHA256!)"
            guard manifest.files[name]?.byteCount == material.scanMarkupByteCount else {
                throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has conflicting scan markup sizes.")
            }
        }
        return archive
    }

    private func verifyPackageLayout(in directory: URL, expectedFiles: Set<String>,
                                     allowBlobsDirectory: Bool = false) throws {
        let fileManager = FileManager.default
        let topLevel = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        let expectedTopLevel = Set(expectedFiles.compactMap { name in
            name.contains("/") ? nil : name
        }).union([Self.manifestName])
        let expectsBlobs = allowBlobsDirectory
        let actualTopLevel = Set(topLevel.map(\.lastPathComponent))
        let requiredTopLevel = expectedTopLevel.union(expectsBlobs ? ["blobs"] : [])
        guard requiredTopLevel.isSubset(of: actualTopLevel) else {
            throw NotesError("snapshot_material_missing", "Snapshot \(directory.lastPathComponent) is missing a required package entry.")
        }
        guard actualTopLevel == requiredTopLevel else {
            throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) contains unexpected or missing package entries.")
        }

        for url in topLevel {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) contains a symbolic link.")
            }
            if url.lastPathComponent == "blobs" {
                guard expectsBlobs, values.isDirectory == true else {
                    throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has an invalid blob directory.")
                }
            } else if values.isRegularFile != true {
                throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) contains a non-file package entry.")
            }
        }

        guard expectsBlobs else { return }
        let blobDirectory = directory.appendingPathComponent("blobs", isDirectory: true)
        let blobs = try fileManager.contentsOfDirectory(
            at: blobDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let expectedBlobNames = Set(expectedFiles.compactMap { name -> String? in
            guard name.hasPrefix("blobs/") else { return nil }
            return String(name.dropFirst("blobs/".count))
        })
        let actualBlobNames = Set(blobs.map(\.lastPathComponent))
        guard actualBlobNames.isSubset(of: expectedBlobNames) else {
            throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) contains unexpected attachment blobs.")
        }
        for blob in blobs {
            let values = try blob.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) contains an invalid attachment blob.")
            }
        }
    }

    private func verifyFiles(_ names: [String], manifest: SnapshotIntegrityManifest,
                             directory: URL, noteData: Data) throws {
        for name in names {
            let data: Data
            if name == "note.json" {
                data = noteData
            } else {
                do { data = try packageData(named: name, in: directory) }
                catch let error as NotesError { throw error }
                catch { throw NotesError("snapshot_material_missing", "Snapshot \(directory.lastPathComponent) could not read \(name).") }
            }
            guard let expected = manifest.files[name], expected == Self.integrity(for: data) else {
                throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) failed its SHA-256 integrity check for \(name).")
            }
        }
    }

    private func packageData(named name: String, in directory: URL) throws -> Data {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) contains an invalid package path.")
        }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw NotesError("snapshot_material_missing", "Snapshot \(directory.lastPathComponent) is unavailable.")
        }
        defer { close(directoryDescriptor) }
        let descriptor = openat(directoryDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno == ENOENT ? "snapshot_material_missing" : "snapshot_integrity_failed"
            throw NotesError(code, "Snapshot \(directory.lastPathComponent) could not open \(name).")
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              UInt64(before.st_size) <= UInt64(Int.max) else {
            throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) contains an invalid file for \(name).")
        }
        let size = Int(before.st_size)
        var data = Data(count: size)
        let count = try data.withUnsafeMutableBytes { buffer -> Int in
            guard size > 0, let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < size {
                let readCount = Darwin.read(descriptor, base.advanced(by: offset), size - offset)
                if readCount < 0 {
                    if errno == EINTR { continue }
                    throw NotesError("snapshot_material_missing", "Snapshot \(directory.lastPathComponent) could not read \(name).")
                }
                if readCount == 0 { break }
                offset += readCount
            }
            return offset
        }
        var after = stat()
        guard count == size, fstat(descriptor, &after) == 0,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) changed while reading \(name).")
        }
        return data
    }

    private func validateArchive(_ archive: SnapshotAttachmentArchive, for note: Note, directory: URL) throws {
        var expected: [String: (typeUTI: String, parentID: String?, isAudio: Bool,
                                hasMarkup: Bool, hasLinkData: Bool)] = [:]
        func collect(_ attachment: Attachment, parentID: String?) throws {
            guard expected[attachment.id] == nil else {
                throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) repeats an attachment identifier.")
            }
            expected[attachment.id] = (
                attachment.typeUTI,
                parentID,
                attachment.kind == "audio",
                attachment.scanHasMarkup == true || (attachment.markupDataBytes ?? 0) > 0,
                attachment.url != nil || (attachment.synapseDataBytes ?? 0) > 0 ||
                    (attachment.linkPreviewMetadataBytes ?? 0) > 0
            )
            for child in attachment.childAttachments ?? [] { try collect(child, parentID: attachment.id) }
        }
        for attachment in note.attachments { try collect(attachment, parentID: nil) }
        guard archive.attachments.count == expected.count else {
            throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has incomplete attachment metadata.")
        }
        var seen: Set<String> = []
        for material in archive.attachments {
            guard seen.insert(material.id).inserted,
                  let saved = expected[material.id], saved.typeUTI == material.typeUTI,
                  saved.parentID == material.parentID else {
                throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has mismatched attachment metadata.")
            }
            if material.archived {
                guard let hash = material.blobSHA256,
                      hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                      let bytes = material.byteCount, bytes > 0, bytes <= Self.maxAttachmentBytes,
                      material.unavailableReason == nil else {
                    throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has invalid attachment archive metadata.")
                }
                if let payloadKind = material.payloadKind {
                    let lowerType = material.typeUTI.lowercased()
                    let validPaper = payloadKind == "paper-strokes-v1" && lowerType.contains("paper")
                    let validPaperCanvases = payloadKind == "paper-canvases-v1" && lowerType.contains("paper") &&
                        material.paperBundleSHA256 != nil && material.paperBundleByteCount != nil
                    let validLegacy = payloadKind == "legacy-drawing-v1" &&
                        (lowerType.contains("sketch") || (lowerType.contains("drawing") && !lowerType.contains("paper")))
                    guard validPaper || validPaperCanvases || validLegacy else {
                        throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has an invalid native attachment payload.")
                    }
                }
            } else {
                guard material.blobSHA256 == nil, material.byteCount == nil,
                      material.mediaDuration == nil, material.payloadKind == nil,
                      material.unavailableReason?.isEmpty == false else {
                    throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has invalid unavailable attachment metadata.")
                }
            }
            if let mediaDuration = material.mediaDuration {
                guard material.archived, saved.isAudio,
                      mediaDuration.isFinite, mediaDuration > 0,
                      mediaDuration <= TranscriptLimits.maxSeconds else {
                    throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has an invalid archived media duration.")
                }
            }
            if material.paperBundleSHA256 != nil || material.paperBundleByteCount != nil {
                guard let hash = material.paperBundleSHA256,
                      hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                      let bytes = material.paperBundleByteCount, bytes > 0, bytes <= Self.maxAttachmentBytes,
                      material.typeUTI.lowercased().contains("paper") else {
                    throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has invalid Paper bundle metadata.")
                }
            }
            if material.synapseSHA256 != nil || material.synapseByteCount != nil {
                guard let hash = material.synapseSHA256,
                      hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                      let bytes = material.synapseByteCount, bytes > 0, bytes <= Self.maxAttachmentBytes,
                      saved.hasLinkData else {
                    throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has invalid Synapse data metadata.")
                }
            }
            if material.linkMetadataSHA256 != nil || material.linkMetadataByteCount != nil {
                guard let hash = material.linkMetadataSHA256,
                      hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                      let bytes = material.linkMetadataByteCount, bytes > 0, bytes <= Self.maxAttachmentBytes,
                      saved.hasLinkData else {
                    throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has invalid link metadata.")
                }
            }
            if material.scanMarkupSHA256 != nil || material.scanMarkupByteCount != nil {
                guard let hash = material.scanMarkupSHA256,
                      hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                      let bytes = material.scanMarkupByteCount, bytes > 0, bytes <= Self.maxAttachmentBytes,
                      saved.hasMarkup else {
                    throw NotesError("snapshot_integrity_failed", "Snapshot \(directory.lastPathComponent) has invalid scan markup metadata.")
                }
            }
        }
    }

    private func requireRestoreMaterial(_ snapshot: NoteSnapshot) throws {
        let markdownData: Data
        do { markdownData = try packageData(named: "note.md", in: snapshot.info.directory) }
        catch let error as NotesError { throw error }
        catch { throw NotesError("snapshot_material_missing", "Snapshot \(snapshot.info.id) could not read note.md.") }
        guard String(data: markdownData, encoding: .utf8) == snapshot.markdown else {
            throw NotesError("snapshot_integrity_failed", "Snapshot \(snapshot.info.id) has conflicting JSON and Markdown content.")
        }
    }

    private static func write(_ data: Data, named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func claimSnapshotID(_ base: String, in directory: URL) throws -> (String, URL) {
        var suffix = 0
        while true {
            let id = suffix == 0 ? base : "\(base)-\(suffix)"
            let claim = directory.appendingPathComponent(".\(id).claim")
            let descriptor = open(claim.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if descriptor >= 0 {
                close(descriptor)
                if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(id).path) {
                    return (id, claim)
                }
                try? FileManager.default.removeItem(at: claim)
            } else if errno != EEXIST {
                throw NotesError("snapshot_write_failed", "Could not reserve a snapshot identifier.")
            }
            suffix += 1
        }
    }

    private static func withoutRuntimePaths(_ note: Note) -> Note {
        func scrub(_ value: Attachment) -> Attachment {
            var value = value
            value.filePath = nil
            value.pageImagePaths = nil
            value.fallbackRasterPath = nil
            value.childAttachments = value.childAttachments?.map(scrub)
            return value
        }
        var note = note
        note.attachments = note.attachments.map(scrub)
        return note
    }

    private static func migratingLegacyRecordingIntegers(in note: Note) -> Note {
        func zigZag(_ raw: Int) -> Int { (raw >> 1) ^ -(raw & 1) }
        func migrate(_ attachment: Attachment) -> Attachment {
            var attachment = attachment
            if var metadata = attachment.recording {
                metadata.summaryVersion = metadata.summaryVersion.map(zigZag)
                metadata.callType = metadata.callType.map(zigZag)
                attachment.recording = metadata
            }
            attachment.recordingFragments = attachment.recordingFragments?.map { fragment in
                var fragment = fragment
                fragment.transcriptVersion = fragment.transcriptVersion.map(zigZag)
                return fragment
            }
            attachment.childAttachments = attachment.childAttachments?.map(migrate)
            return attachment
        }
        var note = note
        note.attachments = note.attachments.map(migrate)
        return note
    }

    private static func integrity(for data: Data) -> SnapshotFileIntegrity {
        SnapshotFileIntegrity(byteCount: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let milliseconds = try? value.decode(Double.self) {
                return Date(timeIntervalSince1970: milliseconds / 1_000)
            }
            let string = try value.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = wholeSeconds.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "The snapshot contains an invalid date.")
        }
        return decoder
    }

    private static func isSnapshotID(_ value: String) -> Bool {
        value.range(of: #"^\d{8}T\d{6}\.\d{3}Z(?:-\d+)?$"#, options: .regularExpression) != nil
    }

    private static func newestDirectoryFirst(_ left: URL, _ right: URL) -> Bool {
        let lhs = snapshotIDParts(left.lastPathComponent)
        let rhs = snapshotIDParts(right.lastPathComponent)
        return lhs.base == rhs.base ? lhs.suffix > rhs.suffix : lhs.base > rhs.base
    }

    private static func snapshotIDParts(_ value: String) -> (base: String, suffix: Int) {
        let parts = value.split(separator: "-", maxSplits: 1)
        return (String(parts[0]), parts.count == 2 ? Int(parts[1]) ?? 0 : 0)
    }

    private static func snapshotID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }
}

private struct SnapshotDirectoryBlobSource: SnapshotBlobSource {
    let directory: URL

    func verifiedData(sha256: String, byteCount: Int) throws -> Data {
        guard sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              byteCount > 0, byteCount <= FrozenSnapshotLimits.maxAttachmentBytes else {
            throw NotesError("snapshot_integrity_failed", "The archived attachment metadata is invalid.")
        }
        let packageDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard packageDescriptor >= 0 else {
            throw NotesError("snapshot_material_missing", "The snapshot package is unavailable.")
        }
        defer { close(packageDescriptor) }
        let blobDirectoryDescriptor = openat(packageDescriptor, "blobs", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard blobDirectoryDescriptor >= 0 else {
            throw NotesError("snapshot_material_missing", "The snapshot blob directory is unavailable.")
        }
        defer { close(blobDirectoryDescriptor) }
        let descriptor = openat(blobDirectoryDescriptor, sha256, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw NotesError("snapshot_material_missing", "Archived attachment \(sha256) is unavailable.")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size == byteCount else {
            throw NotesError("snapshot_integrity_failed", "Archived attachment \(sha256) is not the expected regular file.")
        }
        var data = Data(count: byteCount)
        let readCount = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < byteCount {
                let count = Darwin.read(descriptor, base.advanced(by: offset), byteCount - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NotesError("snapshot_material_missing", "Archived attachment \(sha256) could not be read.")
                }
                if count == 0 { break }
                offset += count
            }
            return offset
        }
        var after = stat()
        guard readCount == byteCount, fstat(descriptor, &after) == 0,
              after.st_size == metadata.st_size,
              after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == metadata.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == metadata.st_ctimespec.tv_nsec,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw NotesError("snapshot_integrity_failed", "Archived attachment \(sha256) failed its SHA-256 check.")
        }
        return data
    }
}

private enum FrozenSnapshotLimits {
    static let maxAttachmentBytes = 200 * 1024 * 1024
}

public enum SnapshotLineDiff {
    public static func unified(snapshot: String, current: String, context: Int = 3) -> String {
        let oldLines = lines(snapshot)
        let newLines = lines(current)
        guard oldLines != newLines else { return "No changes" }

        let difference = newLines.difference(from: oldLines)
        var removals: Set<Int> = []
        var insertions: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }

        var operations: [Operation] = []
        var oldIndex = 0
        var newIndex = 0
        var oldLine = 1
        var newLine = 1
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removals.contains(oldIndex) {
                operations.append(Operation(kind: .delete, line: oldLines[oldIndex], oldLine: oldLine, newLine: newLine))
                oldIndex += 1; oldLine += 1
            } else if newIndex < newLines.count, insertions.contains(newIndex) {
                operations.append(Operation(kind: .insert, line: newLines[newIndex], oldLine: oldLine, newLine: newLine))
                newIndex += 1; newLine += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                operations.append(Operation(kind: .equal, line: oldLines[oldIndex], oldLine: oldLine, newLine: newLine))
                oldIndex += 1; newIndex += 1; oldLine += 1; newLine += 1
            } else if oldIndex < oldLines.count {
                operations.append(Operation(kind: .delete, line: oldLines[oldIndex], oldLine: oldLine, newLine: newLine))
                oldIndex += 1; oldLine += 1
            } else {
                operations.append(Operation(kind: .insert, line: newLines[newIndex], oldLine: oldLine, newLine: newLine))
                newIndex += 1; newLine += 1
            }
        }

        let context = max(0, context)
        let changes = operations.indices.filter { operations[$0].kind != .equal }
        var hunks: [Range<Int>] = []
        for change in changes {
            let proposed = max(operations.startIndex, change - context)..<min(operations.endIndex, change + context + 1)
            if let last = hunks.last, proposed.lowerBound <= last.upperBound {
                hunks[hunks.count - 1] = last.lowerBound..<max(last.upperBound, proposed.upperBound)
            } else {
                hunks.append(proposed)
            }
        }

        var output = ["--- snapshot", "+++ current"]
        for hunk in hunks {
            let slice = operations[hunk]
            let oldCount = slice.count { $0.kind != .insert }
            let newCount = slice.count { $0.kind != .delete }
            let first = operations[hunk.lowerBound]
            let oldStart = oldCount == 0 ? max(0, first.oldLine - 1) : slice.first { $0.kind != .insert }!.oldLine
            let newStart = newCount == 0 ? max(0, first.newLine - 1) : slice.first { $0.kind != .delete }!.newLine
            output.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            for operation in slice {
                output.append(operation.kind.prefix + operation.line.text)
                if !operation.line.hasTerminator { output.append("\\ No newline at end of file") }
            }
        }
        return output.joined(separator: "\n")
    }

    private struct Line: Equatable {
        var text: String
        var hasTerminator: Bool
    }

    private enum OperationKind {
        case equal, delete, insert

        var prefix: String {
            switch self {
            case .equal: return " "
            case .delete: return "-"
            case .insert: return "+"
            }
        }
    }

    private struct Operation {
        var kind: OperationKind
        var line: Line
        var oldLine: Int
        var newLine: Int
    }

    private static func lines(_ value: String) -> [Line] {
        guard !value.isEmpty else { return [] }
        var components = value.components(separatedBy: "\n")
        let endsWithNewline = value.hasSuffix("\n")
        if endsWithNewline { components.removeLast() }
        return components.enumerated().map { index, text in
            Line(text: text, hasTerminator: endsWithNewline || index < components.count - 1)
        }
    }
}
