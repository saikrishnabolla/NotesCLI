import CoreServices
import Foundation
import NotesCore

public struct NoteEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case created, modified, deleted }
    public var kind: Kind
    public var noteID: String
    public var title: String
    public var folder: [String]
    public var modified: Date?

    public init(kind: Kind, noteID: String, title: String, folder: [String], modified: Date?) {
        self.kind = kind; self.noteID = noteID; self.title = title; self.folder = folder; self.modified = modified
    }
}

public final class NoteEventPoller {
    private struct Snapshot: Equatable {
        var title: String
        var folder: [String]
        var modified: Date?
    }
    private let makeReader: @Sendable () throws -> any NotesReading
    private let folder: String?
    private var previous: [String: Snapshot]?

    public init(reader: any NotesReading, folder: String? = nil) {
        self.makeReader = { reader }; self.folder = folder
    }

    public init(makeReader: @escaping @Sendable () throws -> any NotesReading, folder: String? = nil) {
        self.makeReader = makeReader; self.folder = folder
    }

    public func poll() throws -> [NoteEvent] {
        let summaries = try makeReader().notes(NoteQuery(folder: folder))
        let current = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id.uuid, Snapshot(title: $0.title, folder: $0.folderPath, modified: $0.modified)) })
        guard let previous else { self.previous = current; return [] }
        var events: [NoteEvent] = []
        for summary in summaries {
            let value = current[summary.id.uuid]!
            if let old = previous[summary.id.uuid] {
                if old != value { events.append(NoteEvent(kind: .modified, noteID: summary.id.uuid, title: summary.title, folder: summary.folderPath, modified: summary.modified)) }
            } else { events.append(NoteEvent(kind: .created, noteID: summary.id.uuid, title: summary.title, folder: summary.folderPath, modified: summary.modified)) }
        }
        for (id, old) in previous where current[id] == nil {
            events.append(NoteEvent(kind: .deleted, noteID: id, title: old.title, folder: old.folder, modified: old.modified))
        }
        self.previous = current
        return events.sorted { ($0.modified ?? .distantPast, $0.noteID) < ($1.modified ?? .distantPast, $1.noteID) }
    }
}

public final class NotesDatabaseWakeup: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var stream: FSEventStreamRef?
    private var retainedSelf: Unmanaged<NotesDatabaseWakeup>?

    public init(walURL: URL) {
        retainedSelf = Unmanaged.passRetained(self)
        var context = FSEventStreamContext(version: 0, info: retainedSelf?.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<NotesDatabaseWakeup>.fromOpaque(info).takeUnretainedValue().semaphore.signal()
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                     [walURL.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     0.2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "notescli.notes-wal"))
            FSEventStreamStart(stream)
        }
    }

    public func wait(timeout: TimeInterval) {
        _ = semaphore.wait(timeout: .now() + max(0.05, timeout))
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
        retainedSelf?.release()
    }
}
