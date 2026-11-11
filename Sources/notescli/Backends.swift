import Foundation
import NotesCore
import NotesStore
import NotesAutomation

struct Backends {
    let reader: any NotesReading
    let writer: () throws -> any NotesWriting
    let openNote: (NoteID) throws -> Void

    static func make(_ name: String?) throws -> Backends {
        let name = name ?? ProcessInfo.processInfo.environment["NOTESCLI_BACKEND"] ?? "default"
        if name == "fake" {
            let fake = InMemoryNotes.sample()
            return Backends(reader: fake, writer: { fake }, openNote: { _ in })
        }
        guard name == "default" else { throw NotesError("invalid_backend", "Unknown backend: \(name)") }
        let reader = try makeReader()
        return Backends(reader: reader, writer: { try makeWriter(reader: reader) }, openNote: openInNotes)
    }
}

func makeReader() throws -> any NotesReading {
    try SQLiteNotesStore()
}

/// Real writer: refs resolve through the reader to x-coredata ids, and every write
/// that names a note is read back from a fresh snapshot before it counts as verified.
func makeWriter(reader: any NotesReading) throws -> any NotesWriting {
    let started = Date()
    return ScriptingNotesWriter(
        resolver: { ref in
            if ref.hasPrefix("x-coredata://") { return ref }
            return try reader.note(ref).summary.id.coreDataID
        },
        verifier: { result in
            guard let id = result.noteID?.coreDataID ?? result.noteID.map(\.uuid), !id.isEmpty else { return .unverified }
            // Notes saves to its database asynchronously; poll fresh snapshots for up to ~5 seconds.
            for attempt in 0..<10 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
                guard let fresh = try? SQLiteNotesStore(refresh: true),
                      let note = try? fresh.note(id) else { continue }
                if note.summary.isDeleted { return .verified }
                if let modified = note.summary.modified, modified >= started.addingTimeInterval(-2) { return .verified }
            }
            return .unverified
        })
}

func openInNotes(_ id: NoteID) throws {
    try ScriptingNotesWriter().showInNotes(id.coreDataID ?? id.uuid)
}
