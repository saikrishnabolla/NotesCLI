import CoreData
import XCTest
import NotesCore
@testable import NotesNative

private final class Calls: @unchecked Sendable { var removed: [String] = [] }

/// Fault injection for native create paths. An in-memory store stands in for Notes:
/// a saved note survives `rollback()`, as it does after Notes saves added media.
final class CreatedNoteRollbackTests: XCTestCase {
    private var context: NSManagedObjectContext!
    private var writer: NativeNotesWriter!
    private let calls = Calls()

    override func setUpWithError() throws {
        let entity = NSEntityDescription()
        entity.name = "Note"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = ["identifier", "title"].map { name in
            let attribute = NSAttributeDescription(); attribute.name = name; attribute.attributeType = .stringAttributeType
            attribute.isOptional = true; return attribute
        } + [{ let trashed = NSAttributeDescription(); trashed.name = "trashed"; trashed.attributeType = .booleanAttributeType
               trashed.defaultValue = false; return trashed }()]
        let model = NSManagedObjectModel(); model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try coordinator.addPersistentStore(type: .inMemory, at: URL(fileURLWithPath: "/dev/null"))
        context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let context = context!
        writer = NativeNotesWriter(operationID: { "operation-create" }, contextProvider: { context })
        writer.createdNoteCleanup = cleanup()
    }

    private static func stored(_ id: String, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Note")
        request.predicate = NSPredicate(format: "identifier == %@", id)
        return try context.fetch(request).first
    }

    private func cleanup(remove: ((NSManagedObjectContext, NSManagedObject) throws -> Void)? = nil) -> CreatedNoteCleanup {
        let calls = calls
        return CreatedNoteCleanup(isPresent: { context, id in
            guard let note = try Self.stored(id, in: context) else { return false }
            return note.value(forKey: "trashed") as? Bool != true
        }, remove: { context, id in
            calls.removed.append(id)
            guard let note = try Self.stored(id, in: context) else { return }
            if let remove { try remove(context, note) } else { note.setValue(true, forKey: "trashed"); try context.save() }
        })
    }

    /// Mirrors a native create path: create the note, let a step fail, and pass the failure to the rollback.
    private func create(savedByNotes: Bool, committed: Bool = false) throws -> NativeWriteResult {
        let writer = writer!
        return try writer.performWrite { context in
            var createdNoteID: String?
            do {
                let note = NSEntityDescription.insertNewObject(forEntityName: "Note", into: context)
                note.setValue("NOTE-1", forKey: "identifier")
                createdNoteID = "NOTE-1"
                if savedByNotes { try context.save() }
                if committed { writer.operation?.committed = true }
                throw NotesError("attachment_failed", "Notes could not add the file.")
            } catch {
                return try writer.rollBackCreatedNote(createdNoteID, after: error, in: context)
            }
        }
    }

    private func trashed() throws -> Bool? {
        let context = context!
        return try context.performAndWait { try Self.stored("NOTE-1", in: context)?.value(forKey: "trashed") as? Bool }
    }

    func testNoteSavedBeforeTheFailureIsMovedToRecentlyDeletedAndReportedAsRolledBack() throws {
        let result = try create(savedByNotes: true)
        XCTAssertEqual(result.writeResult.outcome, .rolledBack)
        XCTAssertEqual(result.writeResult.noteID?.uuid, "NOTE-1")
        XCTAssertEqual(result.writeResult.message,
                       "Creating the note failed (attachment_failed: Notes could not add the file.). The partly created note NOTE-1 was moved to Recently Deleted.")
        XCTAssertEqual(result.operationID, "operation-create")
        XCTAssertEqual(calls.removed, ["NOTE-1"])
        XCTAssertEqual(try trashed(), true)
    }

    func testFailedCleanupReportsUnknownWithTheNoteID() throws {
        writer.createdNoteCleanup = cleanup { _, _ in throw NotesError("rollback_failed", "Notes.app refused.") }
        let result = try create(savedByNotes: true)
        XCTAssertEqual(result.writeResult.outcome, .unknown)
        XCTAssertEqual(result.writeResult.noteID?.uuid, "NOTE-1")
        XCTAssertEqual(result.writeResult.message,
                       "Creating the note failed (attachment_failed: Notes could not add the file.). The partly created note NOTE-1 could not be moved to Recently Deleted: rollback_failed: Notes.app refused. Delete it before retrying.")
        XCTAssertEqual(try trashed(), false)
    }

    func testCleanupThatLeavesTheNoteInPlaceReportsUnknown() throws {
        writer.createdNoteCleanup = cleanup { _, _ in }
        let result = try create(savedByNotes: true)
        XCTAssertEqual(result.writeResult.outcome, .unknown)
        XCTAssertEqual(result.writeResult.message,
                       "Creating the note failed (attachment_failed: Notes could not add the file.). The partly created note NOTE-1 could not be moved to Recently Deleted: the note is still outside Recently Deleted. Delete it before retrying.")
    }

    func testUnsavedNoteIsDiscardedAndTheOriginalErrorIsThrown() throws {
        XCTAssertThrowsError(try create(savedByNotes: false)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "attachment_failed")
            XCTAssertEqual((error as? NotesError)?.message, "Notes could not add the file.")
        }
        XCTAssertEqual(calls.removed, [])
        XCTAssertNil(try trashed())
    }

    func testCommittedCreateIsNeverRolledBack() throws {
        let result = try create(savedByNotes: true, committed: true)
        XCTAssertEqual(result.writeResult.outcome, .unknown)
        XCTAssertEqual(result.writeResult.message?.hasPrefix(
            "The Core Data save committed, but follow-up failed. Do not retry. operation_id=operation-create: "), true)
        XCTAssertEqual(calls.removed, [])
        XCTAssertEqual(try trashed(), false)
    }

    func testRolledBackOutcomeEncodesAsRolledBack() throws {
        let data = try JSONEncoder().encode(WriteResult(outcome: .rolledBack, noteID: NoteID(uuid: "NOTE-1")))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: AnyHashable],
                       ["outcome": "rolled_back", "noteID": ["uuid": "NOTE-1"] as [String: AnyHashable]])
    }

    /// Every native path that creates a note must hand its failures to `rollBackCreatedNote`.
    func testEveryNativeCreatePathRollsBackItsNote() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NotesNative/NativeNotesWriter.swift"), encoding: .utf8)
        func count(_ text: String) -> Int { source.components(separatedBy: text).count - 1 }
        XCTAssertEqual(count("try NCNotesRuntime.newNote(in:"), 3)
        XCTAssertEqual(count("try NCNotesRuntime.duplicateNote("), 1)
        XCTAssertEqual(count("try rollBackCreatedNote(createdNoteID, after: error, in: context)"), 3)
        XCTAssertEqual(count("try rollBackCreatedNote(copyID, after: error, in: context)"), 1)
    }
}
