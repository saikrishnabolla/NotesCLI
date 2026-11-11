import Foundation
import NotesCore

public struct SnapshotInfo: Codable, Sendable, Equatable {
    public var id: String
    public var noteID: String
    public var created: Date
    public var title: String
    public var folderPath: [String]
    public var directory: URL
}

public struct NoteSnapshot: Codable, Sendable {
    public var info: SnapshotInfo
    public var note: Note
    public var markdown: String
}

public struct SnapshotStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL = NotesSafetyPaths.snapshots) { self.rootURL = rootURL }

    @discardableResult
    public func save(_ note: Note, now: Date = Date()) throws -> SnapshotInfo {
        let noteDirectory = rootURL.appendingPathComponent(note.summary.id.uuid, isDirectory: true)
        let base = Self.snapshotID(now)
        var id = base, suffix = 1
        while FileManager.default.fileExists(atPath: noteDirectory.appendingPathComponent(id).path) {
            id = "\(base)-\(suffix)"; suffix += 1
        }
        let directory = noteDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = SnapshotInfo(id: id, noteID: note.summary.id.uuid, created: now, title: note.summary.title,
                                folderPath: note.summary.folderPath, directory: directory)
        let markdown = note.document?.markdown(attachments: note.attachments) ?? ""
        let snapshot = NoteSnapshot(info: info, note: note, markdown: markdown)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: directory.appendingPathComponent("note.json"), options: .atomic)
        try markdown.write(to: directory.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        return info
    }

    public func history(_ noteID: String) throws -> [SnapshotInfo] {
        let directory = rootURL.appendingPathComponent(noteID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
            .compactMap { try? decode($0).info }
            .sorted { $0.created > $1.created }
    }

    public func load(_ noteID: String, snapshot: String? = nil) throws -> NoteSnapshot {
        let info: SnapshotInfo
        if let snapshot {
            guard snapshot.range(of: #"^\d{8}T\d{6}\.\d{3}Z(?:-\d+)?$"#, options: .regularExpression) != nil else {
                throw NotesError("snapshot_not_found", "Snapshot \(snapshot) was not found.")
            }
            let directory = rootURL.appendingPathComponent(noteID, isDirectory: true).appendingPathComponent(snapshot, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { throw NotesError("snapshot_not_found", "Snapshot \(snapshot) was not found.") }
            info = try decode(directory).info
        } else {
            guard let latest = try history(noteID).first else { throw NotesError("snapshot_not_found", "No snapshot exists for this note.") }
            info = latest
        }
        return try decode(info.directory)
    }

    private func decode(_ directory: URL) throws -> NoteSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(NoteSnapshot.self, from: Data(contentsOf: directory.appendingPathComponent("note.json"))) }
        catch { throw NotesError("invalid_snapshot", "Snapshot \(directory.lastPathComponent) is unreadable.") }
    }

    private static func snapshotID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }
}
