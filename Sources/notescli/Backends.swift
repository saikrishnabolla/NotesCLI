import Foundation
import NotesCore
import NotesStore
import NotesAutomation
import NotesNative
import NotesSafety
import NotesSync

struct Backends {
    let reader: any NotesReading
    let writer: () throws -> any NotesWriting
    let openNote: (NoteID) throws -> Void
    let isFake: Bool
    let fidelity: NotesReadFidelity
    let unavailableFields: [String]

    static func make(_ name: String?, live: Bool = false) throws -> Backends {
        let name = name ?? ProcessInfo.processInfo.environment["NOTESCLI_BACKEND"] ?? "default"
        if name == "fake" {
            let fake = InMemoryNotes.sample()
            return Backends(reader: fake, writer: { fake }, openNote: { _ in }, isFake: true,
                            fidelity: .full, unavailableFields: [])
        }
        guard name == "default" else { throw NotesError("invalid_backend", "Unknown backend: \(name)") }
        do {
            let reader = try makeReader(live: live)
            return Backends(reader: reader, writer: { try makeWriter(reader: reader) }, openNote: openInNotes,
                            isFake: false, fidelity: .full, unavailableFields: [])
        } catch let error as NotesError where error.code == "full_disk_access_denied" {
            let reader = ScriptingNotesReader()
            return Backends(reader: reader, writer: { try makeWriter(reader: reader) }, openNote: openInNotes,
                            isFake: false, fidelity: reader.fidelity, unavailableFields: reader.unavailableFields)
        }
    }
}

func makeReader(live: Bool = false) throws -> any NotesReading {
    if live { return try LiveSQLiteNotesStore() }
    return try SQLiteNotesStore()
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
        verifier: verifier.verify,
        noteReader: { try SQLiteNotesStore(refresh: true).note($0) })
}

final class NativeBodyWriter: NotesWriting, LosslessAttachmentWriting, @unchecked Sendable {
    let supportsLosslessAttachmentRoundTrip = true
    private let base: any NotesWriting
    private let allowShared: Bool

    init(base: any NotesWriting, allowShared: Bool) {
        self.base = base
        self.allowShared = allowShared
    }

    func createNote(title: String, markdown: String, folder: String?) throws -> WriteResult {
        try base.createNote(title: title, markdown: markdown, folder: folder)
    }
    func appendToNote(_ ref: String, markdown: String) throws -> WriteResult {
        try NativeNotesWriter().appendMarkdown(ref, markdown: markdown, allowShared: allowShared).writeResult
    }
    func replaceBody(_ ref: String, markdown: String) throws -> WriteResult {
        try NativeNotesWriter().writeMarkdown(ref, markdown: markdown, dryRun: false, backup: false,
                                              allowShared: allowShared).writeResult
    }
    func replaceBody(_ ref: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult {
        try replaceBody(ref, markdown: markdown)
    }
    func prependToNote(_ ref: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult {
        try NativeNotesWriter().prependMarkdown(ref, markdown: markdown, allowShared: allowShared).writeResult
    }
    func insertUnderHeading(_ ref: String, heading: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult {
        try NativeNotesWriter().insertMarkdown(ref, underHeading: heading, markdown: markdown,
                                               allowShared: allowShared).writeResult
    }
    func replaceSection(_ ref: String, heading: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult {
        try NativeNotesWriter().replaceSection(ref, heading: heading, markdown: markdown,
                                               allowShared: allowShared).writeResult
    }
    func replaceText(_ ref: String, find: String, replacement: String, allowAttachmentLoss: Bool) throws -> WriteResult {
        try NativeNotesWriter().replaceText(ref, find: find, replacement: replacement,
                                            allowShared: allowShared).writeResult
    }
    func renameNote(_ ref: String, title: String) throws -> WriteResult { try base.renameNote(ref, title: title) }
    func moveNote(_ ref: String, toFolder: String) throws -> WriteResult { try base.moveNote(ref, toFolder: toFolder) }
    func deleteNote(_ ref: String) throws -> WriteResult { try base.deleteNote(ref) }
    func createFolder(name: String, parent: String?, account: String?) throws -> WriteResult {
        try base.createFolder(name: name, parent: parent, account: account)
    }
    func renameFolder(_ ref: String, name: String) throws -> WriteResult { try base.renameFolder(ref, name: name) }
    func deleteFolder(_ ref: String) throws -> WriteResult { try base.deleteFolder(ref) }
    func moveFolder(_ ref: String, toParent: String?, account: String?) throws -> WriteResult {
        try base.moveFolder(ref, toParent: toParent, account: account)
    }
    func htmlBody(_ ref: String) throws -> String { try base.htmlBody(ref) }
}

func bodyRewriteWriter(options: GlobalOptions, allowDowngrade: Bool, allowShared: Bool,
                       backend: Backends) throws -> any NotesWriting {
    let base = try backend.writer()
    if options.resolvedEngine == .native, !backend.isFake {
        return NativeBodyWriter(base: base, allowShared: allowShared)
    }
    return ScriptingRewriteGuard(writer: base, reader: backend.reader, allowDowngrade: allowDowngrade)
}

func openInNotes(_ id: NoteID) throws {
    try ScriptingNotesWriter().showInNotes(id.coreDataID ?? id.uuid)
}
