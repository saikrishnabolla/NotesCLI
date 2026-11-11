import Foundation
import NotesCore
import NotesStore
import NotesAutomation

struct Backends {
    let reader: any NotesReading
    let writer: () throws -> any NotesWriting
    let openNote: (NoteID) throws -> Void
    let isFake: Bool

    static func make(_ name: String?) throws -> Backends {
        let name = name ?? ProcessInfo.processInfo.environment["NOTESCLI_BACKEND"] ?? "default"
        if name == "fake" {
            let fake = InMemoryNotes.sample()
            return Backends(reader: fake, writer: { fake }, openNote: { _ in }, isFake: true)
        }
        guard name == "default" else { throw NotesError("invalid_backend", "Unknown backend: \(name)") }
        let reader = try makeReader()
        return Backends(reader: reader, writer: { try makeWriter(reader: reader) }, openNote: openInNotes, isFake: false)
    }
}

func makeReader() throws -> any NotesReading {
    try SQLiteNotesStore()
}

/// Real writer: refs resolve through the reader to x-coredata ids, and every write
/// that names a note is read back from a fresh snapshot before it counts as verified.
func makeWriter(reader: any NotesReading) throws -> any NotesWriting {
    let verifier = FreshWriteVerifier(freshReader: { try SQLiteNotesStore(refresh: true) },
                                      activeFolders: { try ScriptingNotesWriter().listFoldersViaScripting() },
                                      deletionReader: { try ScriptingNotesWriter().isDeletedViaScripting($0) })
    return ScriptingNotesWriter(
        resolver: { ref in
            if ref.hasPrefix("x-coredata://") { return ref }
            return try reader.summary(ref).id.coreDataID
        },
        folderResolver: { ref in
            try SQLiteNotesStore(refresh: true).folders(account: nil)
                .first { $0.id.caseInsensitiveCompare(ref) == .orderedSame }?.coreDataID
        },
        verifier: verifier.verify)
}

func openInNotes(_ id: NoteID) throws {
    try ScriptingNotesWriter().showInNotes(id.coreDataID ?? id.uuid)
}
