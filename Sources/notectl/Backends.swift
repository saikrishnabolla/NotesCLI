import Foundation
import NotesCore

struct Backends {
    let reader: any NotesReading
    let writer: () throws -> any NotesWriting
    let openNote: (NoteID) throws -> Void

    static func make(_ name: String?) throws -> Backends {
        let name = name ?? ProcessInfo.processInfo.environment["NOTECTL_BACKEND"] ?? "default"
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
    throw NotesError("not_wired", "The Notes reader has not been wired in. Use --backend fake.")
}
func makeWriter(reader: any NotesReading) throws -> any NotesWriting {
    throw NotesError("not_wired", "The Notes writer has not been wired in. Use --backend fake.")
}
func openInNotes(_ id: NoteID) throws {
    throw NotesError("not_wired", "Opening Notes.app has not been wired in. Use --backend fake.")
}
