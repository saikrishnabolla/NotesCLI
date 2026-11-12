import CoreData
import Foundation
import NotesNativeObjC
import NotesCore

/// Removes a note that a failed native create left behind.
/// Notes saves some steps on its own (adding media saves the note), so a rollback cannot always undo a new note.
struct CreatedNoteCleanup {
    /// True while the note exists outside Recently Deleted.
    var isPresent: (NSManagedObjectContext, String) throws -> Bool
    /// Moves the note to Recently Deleted.
    var remove: (NSManagedObjectContext, String) throws -> Void

    /// Throws `failure` when nothing was kept. Otherwise moves the note to Recently Deleted and returns
    /// `rolled_back`, or `unknown` when the note could not be removed.
    func clean(_ noteID: String, after failure: NotesError, operationID: String?,
               context: NSManagedObjectContext) throws -> WriteResult {
        let reason = "Creating the note failed (\(failure.code): \(failure.message))."
        func unknown(_ detail: String) -> WriteResult {
            WriteResult(outcome: .unknown, noteID: NoteID(uuid: noteID),
                        message: "\(reason) The partly created note \(noteID) could not be moved to Recently Deleted: \(detail) Delete it before retrying.",
                        operationID: operationID)
        }
        let kept: Bool
        do { kept = try isPresent(context, noteID) } catch { return unknown(String(describing: error)) }
        guard kept else { throw failure }
        do { try remove(context, noteID) } catch { return unknown(String(describing: error)) }
        do {
            if try isPresent(context, noteID) { return unknown("the note is still outside Recently Deleted.") }
        } catch {
            return unknown(String(describing: error))
        }
        return WriteResult(outcome: .rolledBack, noteID: NoteID(uuid: noteID),
                           message: "\(reason) The partly created note \(noteID) was moved to Recently Deleted.",
                           operationID: operationID)
    }
}

extension CreatedNoteCleanup {
    /// Checks the Notes store and moves the note to its account's Recently Deleted folder through Notes.app.
    static var notes: CreatedNoteCleanup { CreatedNoteCleanup(isPresent: { context, noteID in
        guard let note = try storedNote(noteID, in: context) else { return false }
        if NCNotesRuntime.value(forKey: "markedForDeletion", of: note) as? Bool == true { return false }
        if let folder = NCNotesRuntime.value(forKey: "folder", of: note) as? NSManagedObject,
           (NCNotesRuntime.value(forKey: "folderType", of: folder) as? NSNumber)?.intValue == 1 { return false }
        return true
    }, remove: { context, noteID in
        try TestFault.check("cleanup")
        guard let note = try storedNote(noteID, in: context) else { return }
        // Deleting a note Notes has not uploaded yet purges it, skipping Recently Deleted. Moving it there keeps it recoverable.
        guard let folder = NCNotesRuntime.value(forKey: "folder", of: note) as? NSManagedObject,
              let account = NCNotesRuntime.value(forKey: "account", of: folder) as? NSManagedObject,
              let trash = NCNotesRuntime.value(forKey: "trashFolder", of: account) as? NSManagedObject else {
            throw NotesError("rollback_failed", "Notes exposes no Recently Deleted folder for the note's account.")
        }
        let script = "on run argv\ntell application \"Notes\" to move note id (item 1 of argv) to folder id (item 2 of argv)\nend run"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--", note.objectID.uriRepresentation().absoluteString,
                             trash.objectID.uriRepresentation().absoluteString]
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 20) == .timedOut {
            process.terminate()
            throw NotesError("rollback_failed", "Notes.app did not move the note within 20 seconds.")
        }
        guard process.terminationStatus == 0 else {
            throw NotesError("rollback_failed", String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }) }

    /// Reads the note from the store, not from cached values, so changes Notes.app made are visible.
    private static func storedNote(_ noteID: String, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        context.stalenessInterval = 0
        context.refreshAllObjects()
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICNote")
        request.predicate = NSPredicate(format: "identifier == %@", noteID)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}

/// Debug builds fail on purpose at a named step when `NOTESCLI_TEST_FAULT` lists it, for rollback tests.
enum TestFault {
    static func check(_ point: String) throws {
        #if DEBUG
        let points = (ProcessInfo.processInfo.environment["NOTESCLI_TEST_FAULT"] ?? "").split(separator: ",").map(String.init)
        if points.contains(point) { throw NotesError("test_fault", "Injected failure at \(point).") }
        #endif
    }
}
