import AppKit
import AVFoundation
import CoreData
import CryptoKit
import Darwin
import Dispatch
import Foundation
import ImageIO
import NotesCore
import NotesNativeObjC
import NotesStore
import PDFKit
import PencilKit

fileprivate struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

fileprivate struct PaperCleanupScope {
    let accountID: String
    let rootURL: URL
    let bundleNamesBefore: Set<String>
}

fileprivate struct PaperCleanupCandidate {
    let identifier: String
    let accountID: String
    let rootURL: URL
    let fileURLs: [URL]
}

final class NativeWriteLease {
    private static let processLock = NSRecursiveLock()
    private let descriptor: Int32
    private var active = true

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(directory suppliedDirectory: URL? = nil, timeout: TimeInterval = 30) throws -> NativeWriteLease {
        let started = DispatchTime.now().uptimeNanoseconds
        guard processLock.lock(before: Date(timeIntervalSinceNow: timeout)) else {
            throw NotesError("native_write_busy", "Another native Notes write did not finish within 30 seconds.")
        }
        do {
            let directory = suppliedDirectory ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/NotesCLI", isDirectory: true)
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
                throw NotesError("native_write_lock_failed", "Could not create the native write lock directory.")
            }
            let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard directoryDescriptor >= 0 else {
                throw NotesError("native_write_lock_failed", "Could not open the native write lock directory.")
            }
            defer { close(directoryDescriptor) }
            var directoryMetadata = stat()
            guard fstat(directoryDescriptor, &directoryMetadata) == 0,
                  directoryMetadata.st_mode & S_IFMT == S_IFDIR,
                  directoryMetadata.st_uid == geteuid(),
                  fchmod(directoryDescriptor, 0o700) == 0 else {
                throw NotesError("native_write_lock_failed", "The native write lock directory is unsafe.")
            }
            let descriptor = openat(directoryDescriptor, "native-write.lock",
                                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw NotesError("native_write_lock_failed", "Could not open the native write lock.")
            }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                  fchmod(descriptor, 0o600) == 0 else {
                close(descriptor)
                throw NotesError("native_write_lock_failed", "The native write lock file is unsafe.")
            }
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                if errno == EINTR { continue }
                if errno == EWOULDBLOCK {
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                    if elapsed < timeout {
                        usleep(50_000)
                        continue
                    }
                    close(descriptor)
                    throw NotesError("native_write_busy", "Another native Notes write did not finish within 30 seconds.")
                }
                close(descriptor)
                throw NotesError("native_write_lock_failed", "Could not acquire the native write lock.")
            }
            return NativeWriteLease(descriptor: descriptor)
        } catch {
            processLock.unlock()
            throw error
        }
    }

    func release() {
        guard active else { return }
        active = false
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        Self.processLock.unlock()
    }

    deinit { release() }
}

enum NativeDeleteVerification {
    static func isDeleted(markedForDeletion: Bool, folderType: Int?) -> Bool {
        !markedForDeletion && folderType == 1
    }
}

enum NativeBodyIntegrity {
    static func validate(serialized data: Data, expectedText: String) throws {
        let decoded: NoteDocument
        do { decoded = try NotesDecoder.decode(data) }
        catch {
            throw NotesError(
                "native_body_inconsistent",
                "Notes generated an invalid body. The Core Data save was refused."
            )
        }
        guard decoded.text == expectedText else {
            throw NotesError(
                "native_body_inconsistent",
                "Notes generated stale body text. The Core Data save was refused."
            )
        }
    }
}

public final class NativeNotesWriter: NotesNativeWriting {
    fileprivate let lock = NSRecursiveLock()
    struct Operation {
        let id: String
        var committed = false
        var noteID: String?
        var folderID: String?
        var attachmentID: String?
        var attachmentType: String?
        var attachmentPosition: Int?
        var childAttachmentIDs: [String] = []
    }
    var operation: Operation?
    var createdNoteCleanup = CreatedNoteCleanup.notes
    fileprivate let operationID: () -> String
    fileprivate let contextProvider: () throws -> NSManagedObjectContext
    fileprivate let serializesProductionWrites: Bool

    public convenience init() {
        self.init(operationID: { UUID().uuidString.lowercased() },
                  contextProvider: { try NCNotesRuntime.sharedContext() },
                  serializesProductionWrites: true)
    }
    init(operationID: @escaping () -> String, contextProvider: @escaping () throws -> NSManagedObjectContext,
         serializesProductionWrites: Bool = false) {
        self.operationID = operationID
        self.contextProvider = contextProvider
        self.serializesProductionWrites = serializesProductionWrites
    }

    fileprivate func writeLease() throws -> NativeWriteLease? {
        try serializesProductionWrites ? NativeWriteLease.acquire() : nil
    }

    public func doctor() -> NativeDoctorReport {
        let raw = NCNotesRuntime.doctor()
        let classRows = raw["classes"] as? [String: [String: Any]] ?? [:]
        let classes = classRows.mapValues { row in
            NativeClassReport(resolved: row["resolved"] as? Bool ?? false,
                              selectors: row["selectors"] as? [String: Bool] ?? [:])
        }
        return NativeDoctorReport(frameworkLoaded: raw["frameworkLoaded"] as? Bool ?? false,
                                  frameworkPath: raw["frameworkPath"] as? String ?? "",
                                  macOS: raw["macOS"] as? String ?? "",
                                  missing: raw["missing"] as? [String] ?? [],
                                  error: raw["error"] as? String,
                                  classes: classes)
    }

    fileprivate func context() throws -> NSManagedObjectContext {
        do { return try contextProvider() }
        catch { throw nativeError(error) }
    }

    fileprivate func performContext<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let context = try context()
        return try withoutActuallyEscaping(body) { body in
            let body = UnsafeSendableBox(value: body)
            return try context.performAndWait { try body.value(context) }
        }
    }

    fileprivate func performRead<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try performContext(body)
    }

    fileprivate func prepareOperationContext(_ context: NSManagedObjectContext) {
        context.automaticallyMergesChangesFromParent = true
        context.reset()
    }

    fileprivate func requireUndoState<T: Equatable>(_ current: T, expected: T?, label: String) throws {
        guard expected == nil || current == expected else {
            throw NotesError("undo_conflict", "\(label) changed after the recorded operation; refusing to overwrite the newer value.")
        }
    }

    fileprivate func requireUndoIdentifier(_ current: String, expected: String?, label: String) throws {
        guard expected == nil || current.caseInsensitiveCompare(expected!) == .orderedSame else {
            throw NotesError("undo_conflict", "\(label) changed after the recorded operation; refusing to overwrite the newer value.")
        }
    }

    func performWrite(_ body: (NSManagedObjectContext) throws -> NativeWriteResult) throws -> NativeWriteResult {
        let lease = try writeLease(); defer { lease?.release() }
        lock.lock(); defer { lock.unlock() }
        precondition(operation == nil)
        operation = Operation(id: operationID())
        defer { operation = nil }
        do {
            return try performContext { context in
                prepareOperationContext(context)
                return try body(context)
            }
        } catch {
            guard let operation, operation.committed else { throw error }
            return NativeWriteResult(
                writeResult: WriteResult(
                    outcome: .unknown,
                    noteID: operation.noteID.map { NoteID(uuid: $0) },
                    folderID: operation.folderID,
                    message: "The Core Data save committed, but follow-up failed. Do not retry. operation_id=\(operation.id): \(String(describing: error))",
                    operationID: operation.id
                ),
                verification: NativeVerification(nativeReadback: [:], sqliteReadback: nil),
                operationID: operation.id
            )
        }
    }

    func performWriteWithFreshReadback<Receipt>(
        transaction: (NSManagedObjectContext) throws -> Receipt,
        readback: (NSManagedObjectContext, Receipt) throws -> NativeWriteResult
    ) throws -> NativeWriteResult {
        let lease = try writeLease(); defer { lease?.release() }
        lock.lock(); defer { lock.unlock() }
        precondition(operation == nil)
        operation = Operation(id: operationID())
        defer { operation = nil }
        do {
            let receipt = try performContext { context in
                prepareOperationContext(context)
                return try transaction(context)
            }
            return try performContext { context in
                prepareOperationContext(context)
                return try readback(context, receipt)
            }
        } catch {
            guard let operation, operation.committed else { throw error }
            return NativeWriteResult(
                writeResult: WriteResult(
                    outcome: .unknown,
                    noteID: operation.noteID.map { NoteID(uuid: $0) },
                    folderID: operation.folderID,
                    message: "The Core Data save committed, but follow-up failed. Do not retry. operation_id=\(operation.id): \(String(describing: error))",
                    operationID: operation.id
                ),
                verification: NativeVerification(nativeReadback: [:], sqliteReadback: nil),
                operationID: operation.id
            )
        }
    }

    fileprivate func performAttachmentWrite(_ body: (NSManagedObjectContext) throws -> NativeAttachmentResult) throws -> NativeAttachmentResult {
        let lease = try writeLease(); defer { lease?.release() }
        lock.lock(); defer { lock.unlock() }
        precondition(operation == nil)
        operation = Operation(id: operationID())
        defer { operation = nil }
        do {
            return try performContext { context in
                prepareOperationContext(context)
                return try body(context)
            }
        } catch {
            guard let operation, operation.committed else { throw error }
            let write = NativeWriteResult(
                writeResult: WriteResult(
                    outcome: .unknown,
                    noteID: operation.noteID.map { NoteID(uuid: $0) },
                    message: "The Core Data save committed, but follow-up failed. Do not retry. operation_id=\(operation.id): \(String(describing: error))",
                    operationID: operation.id
                ),
                verification: NativeVerification(nativeReadback: [:], sqliteReadback: nil),
                operationID: operation.id
            )
            return NativeAttachmentResult(attachmentID: operation.attachmentID ?? "", typeUTI: operation.attachmentType ?? "public.data",
                                          position: operation.attachmentPosition ?? 0, write: write)
        }
    }

    fileprivate func performRecordingWrite(duration: Double,
                                            _ body: (NSManagedObjectContext) throws -> NativeRecordingResult) throws -> NativeRecordingResult {
        let lease = try writeLease(); defer { lease?.release() }
        lock.lock(); defer { lock.unlock() }
        precondition(operation == nil)
        operation = Operation(id: operationID())
        defer { operation = nil }
        do {
            return try performContext { context in
                prepareOperationContext(context)
                return try body(context)
            }
        } catch {
            guard let operation, operation.committed else { throw error }
            let write = NativeWriteResult(
                writeResult: WriteResult(
                    outcome: .unknown,
                    noteID: operation.noteID.map { NoteID(uuid: $0) },
                    message: "The Core Data save committed, but follow-up failed. Do not retry. operation_id=\(operation.id): \(String(describing: error))",
                    operationID: operation.id
                ),
                verification: NativeVerification(nativeReadback: [:], sqliteReadback: nil),
                operationID: operation.id
            )
            return NativeRecordingResult(attachmentID: operation.attachmentID ?? "", childAttachmentIDs: [],
                                         duration: duration, transcriptSegments: 0, write: write)
        }
    }

    fileprivate func performScanWrite<Receipt>(
        transaction: (NSManagedObjectContext) throws -> Receipt,
        readback: (NSManagedObjectContext, Receipt) throws -> NativeScanResult
    ) throws -> NativeScanResult {
        let lease = try writeLease(); defer { lease?.release() }
        lock.lock(); defer { lock.unlock() }
        precondition(operation == nil)
        operation = Operation(id: operationID())
        defer { operation = nil }
        do {
            let receipt = try performContext { context in
                prepareOperationContext(context)
                return try transaction(context)
            }
            return try performContext { context in
                prepareOperationContext(context)
                return try readback(context, receipt)
            }
        } catch {
            guard let operation, operation.committed else { throw error }
            let detail = (error as? NotesError)?.message ?? error.localizedDescription
            let write = NativeWriteResult(
                writeResult: WriteResult(
                    outcome: .unknown,
                    noteID: operation.noteID.map { NoteID(uuid: $0) },
                    message: "The scan may have committed, but follow-up failed. Do not retry. operation_id=\(operation.id): \(detail)",
                    operationID: operation.id
                ),
                verification: NativeVerification(nativeReadback: [:], sqliteReadback: nil),
                operationID: operation.id
            )
            return NativeScanResult(attachmentID: operation.attachmentID ?? "",
                                    pageAttachmentIDs: operation.childAttachmentIDs,
                                    position: operation.attachmentPosition ?? 0,
                                    write: write)
        }
    }

    fileprivate func nativeError(_ error: Error) -> NotesError {
        let text = error.localizedDescription
        if text.contains("required selector missing") || text.contains("required class missing") ||
            text.contains("cannot load NotesShared") || text.contains("cannot load NotesUI") ||
            text.contains("required selectors missing") || text.contains("unrecognized selector") || text.contains("doesNotRecognizeSelector") {
            return NotesError("native_unavailable", text, hint: "Use the AppleScript command when it supports this write, or run notescli native-doctor --json.")
        }
        return NotesError("native_write_failed", text)
    }

    fileprivate func value(_ object: AnyObject?, _ key: String) -> Any? {
        guard let object else { return nil }
        return NCNotesRuntime.value(forKey: key, of: object)
    }

    fileprivate func require(_ selectors: [String], of object: AnyObject) throws {
        do { try NCNotesRuntime.requireSelectors(selectors, of: object) }
        catch { throw nativeError(error) }
    }

    fileprivate func fetch(_ entity: String, predicate: NSPredicate, in context: NSManagedObjectContext, limit: Int? = nil) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate
        if let limit { request.fetchLimit = limit }
        do { return try context.fetch(request) }
        catch { throw NotesError("native_read_failed", "Could not read \(entity): \(error.localizedDescription)") }
    }

    fileprivate func note(_ ref: String, in context: NSManagedObjectContext) throws -> NSManagedObject {
        if ref.hasPrefix("x-coredata://"), let url = URL(string: ref),
           let objectID = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
           let object = try? context.existingObject(with: objectID), object.entity.name == "ICNote" { return object }
        func primaryKeyNote(_ number: Int) -> NSManagedObject? {
            guard let coordinator = context.persistentStoreCoordinator else { return nil }
            for store in coordinator.persistentStores {
                guard let uuid = coordinator.metadata(for: store)[NSStoreUUIDKey] as? String,
                      let url = URL(string: "x-coredata://\(uuid)/ICNote/p\(number)"),
                      let objectID = coordinator.managedObjectID(forURIRepresentation: url),
                      let object = try? context.existingObject(with: objectID), object.entity.name == "ICNote" else { continue }
                return object
            }
            return nil
        }
        func number(of object: NSManagedObject) -> Int? {
            let last = object.objectID.uriRepresentation().lastPathComponent
            guard last.hasPrefix("p") else { return nil }
            return Int(last.dropFirst())
        }
        return try NoteReference.resolve(ref, identifiers: { value in
            try fetch("ICNote", predicate: NSPredicate(format: "identifier ==[c] %@", value), in: context)
        }, number: { value in primaryKeyNote(value).map { [$0] } ?? [] },
        title: { value in
            try fetch("ICNote", predicate: NSPredicate(format: "title == %@ AND markedForDeletion == NO", value), in: context)
        }, key: { $0.objectID.uriRepresentation().absoluteString },
        describe: { object in
            NoteReference.describe(number: number(of: object), uuid: object.value(forKey: "identifier") as? String ?? "",
                                   title: object.value(forKey: "title") as? String ?? "")
        })
    }

    fileprivate func folder(_ ref: String, in context: NSManagedObjectContext) throws -> NSManagedObject {
        if ref.hasPrefix("x-coredata://"), let url = URL(string: ref),
           let objectID = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
           let object = try? context.existingObject(with: objectID), object.entity.name == "ICFolder",
           value(object, "markedForDeletion") as? Bool != true { return object }
        var rows = try fetch("ICFolder", predicate: NSPredicate(format: "identifier ==[c] %@ AND markedForDeletion == NO", ref), in: context)
        if rows.isEmpty { rows = try fetch("ICFolder", predicate: NSPredicate(format: "title == %@ AND markedForDeletion == NO", ref), in: context) }
        guard !rows.isEmpty else { throw NotesError("folder_not_found", "No folder matches the reference.") }
        guard rows.count == 1 else { throw NotesError("ambiguous_folder", "More than one folder has this name. Use its identifier.") }
        return rows[0]
    }

    fileprivate func id(_ object: NSManagedObject) -> String { value(object, "identifier") as? String ?? object.objectID.uriRepresentation().absoluteString }
    fileprivate func title(_ note: NSManagedObject) -> String { value(note, "title") as? String ?? "" }
    fileprivate func isShared(_ object: NSManagedObject) -> Bool {
        if value(object, "serverShareData") != nil { return true }
        if let owner = value(object, "zoneOwnerName") as? String, owner != "__defaultOwner__" { return true }
        if let folder = value(object, "folder") as? NSManagedObject { return isSharedFolder(folder) }
        return false
    }
    fileprivate func isSharedFolder(_ folder: NSManagedObject) -> Bool {
        var current: NSManagedObject? = folder
        while let item = current {
            if value(item, "serverShareData") != nil { return true }
            if let owner = value(item, "zoneOwnerName") as? String, owner != "__defaultOwner__" { return true }
            current = value(item, "parent") as? NSManagedObject
        }
        return false
    }

    fileprivate func guardWritable(_ note: NSManagedObject, allowShared: Bool, allowTrash: Bool = false) throws {
        try require(["isPasswordProtected", "markedForDeletion", "folder", "serverShareData", "zoneOwnerName", "isSharedReadOnly"], of: note)
        if value(note, "isPasswordProtected") as? Bool == true { throw NotesError("note_locked", "Locked notes cannot be changed.") }
        if !allowTrash, value(note, "markedForDeletion") as? Bool == true { throw NotesError("note_deleted", "The note is marked for deletion.") }
        if let folder = value(note, "folder") as? NSManagedObject {
            try guardFolderSelectors(folder)
        }
        if !allowTrash, let folder = value(note, "folder") as? NSManagedObject, value(folder, "folderType") as? Int == 1 {
            throw NotesError("note_in_trash", "Restore the note before changing its contents.")
        }
        if isShared(note) {
            try NativeSharedWriteGuard.require(isShared: true, allowShared: allowShared,
                                               isReadOnly: value(note, "isSharedReadOnly") as? Bool)
        }
    }

    fileprivate func guardWritableFolder(_ folder: NSManagedObject, allowShared: Bool) throws {
        try guardFolderSelectors(folder)
        var current: NSManagedObject? = folder, sharedRole: Bool?
        while let item = current {
            if value(item, "serverShareData") != nil
                || (value(item, "zoneOwnerName") as? String).map({ $0 != "__defaultOwner__" }) == true {
                sharedRole = value(item, "isSharedReadOnly") as? Bool
                break
            }
            current = value(item, "parent") as? NSManagedObject
        }
        try NativeSharedWriteGuard.require(isShared: isSharedFolder(folder), allowShared: allowShared, isReadOnly: sharedRole)
    }

    fileprivate func requireQuickNoteAccount(_ accountID: String) throws {
        guard let account = try SQLiteNotesStore(refresh: true).accounts().first(where: {
            $0.id.caseInsensitiveCompare(accountID) == .orderedSame
        }) else {
            throw NotesError("account_not_found", "The Quick Note account was not found.")
        }
        guard account.kind == "icloud" else {
            throw NotesError("quick_note_requires_icloud", "Quick Notes require an iCloud Notes account.")
        }
    }

    fileprivate func guardFolderSelectors(_ folder: NSManagedObject) throws {
        var current: NSManagedObject? = folder
        while let item = current {
            try require(["folderType", "serverShareData", "zoneOwnerName", "parent", "account"], of: item)
            current = value(item, "parent") as? NSManagedObject
        }
    }

    fileprivate func refreshIfStale(_ note: NSManagedObject, protectsBody: Bool = true) throws {
        try require(["identifier", "modificationDate"], of: note)
        guard let context = note.managedObjectContext else { throw NotesError("native_read_failed", "The note is detached from its native context.") }
        let noteID = id(note)
        let loadedDate = value(note, "modificationDate") as? Date
        let snapshot: NoteSummary
        do { snapshot = try SQLiteNotesStore(refresh: true).summary(noteID) }
        catch { throw NotesError("native_read_failed", "Could not compare the note with a fresh snapshot: \(error.localizedDescription)") }
        guard loadedDate != snapshot.modified else { return }
        let loadedBody = protectsBody ? try body(note) : nil
        context.refresh(note, mergeChanges: false)
        try NativeStaleGuard.validate(
            loadedDate: loadedDate,
            snapshotDate: snapshot.modified,
            refreshedDate: value(note, "modificationDate") as? Date,
            loadedTarget: loadedBody,
            refreshedTarget: loadedBody == nil ? nil : try body(note)
        )
    }

    fileprivate func body(_ note: NSManagedObject) throws -> NSAttributedString {
        do { return try NCNotesRuntime.body(of: note) }
        catch { throw nativeError(error) }
    }
    fileprivate func valid(_ range: UTF16Range, length: Int, allowEmpty: Bool = true) throws -> NSRange {
        guard range.location >= 0, range.length >= 0, range.location <= length, range.length <= length - range.location,
              allowEmpty || range.length > 0 else { throw NotesError("invalid_range", "The UTF-16 range is outside the note.") }
        return NSRange(location: range.location, length: range.length)
    }

    fileprivate func paragraphRanges(_ text: NSString) -> [NSRange] {
        if text.length == 0 { return [NSRange(location: 0, length: 0)] }
        var result: [NSRange] = [], start = 0
        while start <= text.length {
            let found = text.range(of: "\n", options: [], range: NSRange(location: start, length: text.length - start))
            if found.location == NSNotFound { result.append(NSRange(location: start, length: text.length - start)); break }
            result.append(NSRange(location: start, length: found.location - start)); start = found.location + 1
            if start == text.length { break }
        }
        return result
    }

    fileprivate func checklist(_ note: NSManagedObject) throws -> [ChecklistItem] {
        let attributed = try body(note), text = attributed.string as NSString
        return paragraphRanges(text).enumerated().compactMap { index, range in
            guard attributed.length > 0 else { return nil }
            let probe = min(range.location, attributed.length - 1)
            guard let style = attributed.attribute(NSAttributedString.Key("TTStyle"), at: probe, effectiveRange: nil) as AnyObject?,
                  value(style, "style") as? Int == 103 else { return nil }
            let done = ((value(style, "todo") as AnyObject?).flatMap { value($0, "done") as? Bool }) ?? false
            return ChecklistItem(index: index, text: text.substring(with: range), done: done,
                                 range: UTF16Range(location: range.location, length: range.length))
        }
    }

    public func checklistItems(_ ref: String) throws -> [ChecklistItem] {
        try performRead { context in try checklist(note(ref, in: context)) }
    }
    public func checklistAutoSortEnabled() -> Bool { NCNotesRuntime.checklistAutoSortEnabled() }
    public func setChecklistAutoSort(_ enabled: Bool) throws -> NativeWriteResult {
        try setChecklistAutoSort(enabled, expectedCurrent: nil)
    }
    public func setChecklistAutoSort(_ enabled: Bool, expectedCurrent: Bool?) throws -> NativeWriteResult {
        try performWrite { _ in
            try requireUndoState(NCNotesRuntime.checklistAutoSortEnabled(), expected: expectedCurrent,
                                 label: "Checklist auto-sort")
            do { try NCNotesRuntime.setChecklistAutoSort(enabled); operation?.committed = true }
            catch let error as NotesError { throw error }
            catch { throw nativeError(error) }
            let readback = NCNotesRuntime.checklistAutoSortEnabled()
            return globalResult(native: ["enabled": String(readback)], nativeVerified: readback == enabled)
        }
    }

    fileprivate func validateBodiesBeforeSave(_ notes: [NSManagedObject]) throws {
        for note in notes where value(note, "isPasswordProtected") as? Bool != true {
            guard let noteData = value(note, "noteData") as? NSManagedObject else { continue }
#if DEBUG
            if ProcessInfo.processInfo.environment["NOTESCLI_TEST_CORRUPT_PENDING_BODY"] == id(note) {
                noteData.setValue(Data([0xff]), forKey: "data")
            }
#endif
            guard noteData.changedValues().keys.contains("data"),
                  let pendingData = value(noteData, "data") as? Data,
                  !pendingData.isEmpty else { continue }
            try NativeBodyIntegrity.validate(serialized: pendingData, expectedText: try body(note).string)
        }
    }

    fileprivate func save(_ context: NSManagedObjectContext, notes: [NSManagedObject]) throws {
        do {
            try validateBodiesBeforeSave(notes)
            try NCNotesRuntime.save(context)
        } catch let error as NotesError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw nativeError(error)
        }
        operation?.committed = true
        operation?.noteID = notes.first.map(id)
        for note in notes { try sync(note) }
        context.refreshAllObjects()
    }

    /// The catch step of every path that creates a note and then adds content. Rolls back unsaved changes and
    /// rethrows when nothing was kept. When Notes already saved the new note, moves it to Recently Deleted and
    /// returns `rolled_back`, or `unknown` with the note ID when that fails.
    func rollBackCreatedNote(_ noteID: String?, after error: Error, in context: NSManagedObjectContext) throws -> NativeWriteResult {
        context.rollback()
        let failure = (error as? NotesError) ?? nativeError(error)
        guard let noteID, operation?.committed != true else { throw failure }
        let result = try createdNoteCleanup.clean(noteID, after: failure, operationID: operation?.id, context: context)
        return NativeWriteResult(writeResult: result, verification: NativeVerification(nativeReadback: [:], sqliteReadback: nil),
                                 operationID: operation?.id)
    }

    fileprivate func sync(_ note: NSManagedObject) throws {
        guard let folder = value(note, "folder") as? NSManagedObject else { throw NotesError("native_sync_failed", "The note has no folder.") }
        let script = "on run argv\ntell application \"Notes\" to move note id (item 1 of argv) to folder id (item 2 of argv)\nend run"
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--", note.objectID.uriRepresentation().absoluteString, folder.objectID.uriRepresentation().absoluteString]
        let stderr = Pipe(); process.standardOutput = FileHandle.nullDevice; process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            if finished.wait(timeout: .now() + 20) == .timedOut {
                process.terminate()
                throw NotesError("native_sync_failed", "Saved locally, but the Notes.app save nudge timed out.")
            }
        }
        catch { throw NotesError("native_sync_failed", "Saved locally, but Notes.app could not be asked to sync: \(error.localizedDescription)") }
        guard process.terminationStatus == 0 else {
            let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NotesError("native_sync_failed", "Saved locally, but Notes.app did not accept the sync request: \(text)")
        }
    }

    fileprivate func result(_ noteID: String?, native: [String: String], nativeVerified: Bool = true,
                            sqlite: ((Note) -> [String: String]?)? = nil, message: String? = nil,
                            mismatch: String? = nil) -> NativeWriteResult {
        var sqliteEvidence: [String: String]?
        var sqliteReadSucceeded = sqlite == nil
        var sqliteError: Error?
        if let noteID, let sqlite {
            for attempt in 0..<12 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
                do {
                    let note = try SQLiteNotesStore(refresh: true).note(noteID)
                    sqliteReadSucceeded = true
                    if let evidence = sqlite(note) { sqliteEvidence = evidence; break }
                } catch { sqliteError = error }
            }
        }
        if !sqliteReadSucceeded {
            let id = operation?.id
            return NativeWriteResult(
                writeResult: WriteResult(outcome: .unknown, noteID: noteID.map { NoteID(uuid: $0) },
                                         message: "The save committed, but readback failed. Do not retry. operation_id=\(id ?? "unknown"): \(sqliteError.map(String.init(describing:)) ?? "unknown error")",
                                         operationID: id),
                verification: NativeVerification(nativeReadback: native, sqliteReadback: nil), operationID: id
            )
        }
        let verified = nativeVerified && !native.isEmpty && (sqlite == nil || sqliteEvidence != nil)
        let resultMessage = verified ? message : (mismatch ?? message ?? "Readback did not match the requested change.")
        return NativeWriteResult(writeResult: WriteResult(outcome: verified ? .verified : .unverified,
                                                           noteID: noteID.map { NoteID(uuid: $0) }, message: resultMessage,
                                                           operationID: operation?.id),
                                 verification: NativeVerification(nativeReadback: native, sqliteReadback: sqliteEvidence),
                                 operationID: operation?.id)
    }

    fileprivate func globalResult(native: [String: String], nativeVerified: Bool = true,
                                  folderID: String? = nil, sqlite: (() throws -> [String: String]?)? = nil,
                                  message: String? = nil) -> NativeWriteResult {
        var sqliteEvidence: [String: String]?
        var sqliteReadSucceeded = sqlite == nil
        var sqliteError: Error?
        if let sqlite {
            for attempt in 0..<12 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
                do {
                    sqliteReadSucceeded = true
                    if let evidence = try sqlite() { sqliteEvidence = evidence }
                } catch { sqliteError = error }
                if sqliteEvidence != nil { break }
            }
        }
        if !sqliteReadSucceeded {
            let id = operation?.id
            return NativeWriteResult(
                writeResult: WriteResult(outcome: .unknown, folderID: folderID,
                                         message: "The save committed, but readback failed. Do not retry. operation_id=\(id ?? "unknown"): \(sqliteError.map(String.init(describing:)) ?? "unknown error")",
                                         operationID: id),
                verification: NativeVerification(nativeReadback: native, sqliteReadback: nil), operationID: id
            )
        }
        let verified = nativeVerified && !native.isEmpty && (sqlite == nil || sqliteEvidence != nil)
        return NativeWriteResult(writeResult: WriteResult(outcome: verified ? .verified : .unverified, folderID: folderID,
                                                           message: verified ? message : (message ?? "Readback did not match the requested change."),
                                                           operationID: operation?.id),
                                 verification: NativeVerification(nativeReadback: native, sqliteReadback: sqliteEvidence),
                                 operationID: operation?.id)
    }

    fileprivate func mutateBody(_ ref: String, context: NSManagedObjectContext, allowShared: Bool, edit: (NSManagedObject, NCBodyEditor, NSAttributedString) throws -> Void) throws -> (NSManagedObject, NSAttributedString) {
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
        do {
            let editor = try NCBodyEditor(note: note), original = editor.original
            try edit(note, editor, original)
            try editor.finish(); try save(context, notes: [note])
            let refreshed = try self.note(id(note), in: context)
            return (refreshed, try body(refreshed))
        } catch let error as NotesError { context.rollback(); throw error }
        catch { context.rollback(); throw nativeError(error) }
    }

    public func insertChecklist(_ ref: String, text: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        guard !text.contains("\n") else { throw NotesError("invalid_checklist_text", "A checklist item must be one line.") }
        var insertedLocation = 0
        let (note, _) = try mutateBody(ref, context: context, allowShared: allowShared) { _, editor, original in
            let at = position ?? original.length; guard (0...original.length).contains(at) else { throw NotesError("invalid_range", "Position exceeds the note length.") }
            let style = try NCNotesRuntime.paragraphStyle(103, indent: 0, quote: 0, checked: 0, basedOn: nil)
            let prefix = at > 0 && (original.string as NSString).character(at: at - 1) != 10 ? "\n" : ""
            insertedLocation = at + (prefix as NSString).length
            let item = NSAttributedString(string: prefix + text, attributes: [NSAttributedString.Key("TTStyle"): style])
            try editor.begin(["insert"]); try editor.insert(item, at: UInt(at))
        }
        let items = try checklist(note)
        let inserted = items.filter { $0.range.location == insertedLocation && $0.text == text && !$0.done }.count == 1
        return result(id(note), native: ["checklistCount": "\(items.count)", "location": "\(insertedLocation)", "inserted": "\(inserted)"],
                      nativeVerified: inserted,
                      sqlite: { n in
            guard let document = n.document else { return nil }
            let runs = Self.documentRuns(document, in: UTF16Range(location: insertedLocation, length: (text as NSString).length))
            guard !runs.isEmpty,
                  NativeVerificationRules.exactText(document.text, text: text, location: insertedLocation),
                  runs.allSatisfy({ $0.paragraph?.kind == .checklist && $0.paragraph?.checked != true }) else { return nil }
            return ["location": "\(insertedLocation)", "done": "false"]
        }, mismatch: "The inserted checklist item did not match at UTF-16 location \(insertedLocation) with done=false.")
        }
    }

    fileprivate struct ChecklistWriteReceipt {
        let noteID: String
        let selected: [ChecklistItem]
        let expectedDone: Bool
    }

    fileprivate func setChecklist(_ ref: String, context: NSManagedObjectContext, allowShared: Bool, select: ([ChecklistItem]) throws -> Set<Int>, done: Bool?) throws -> ChecklistWriteReceipt {
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
        let before = try checklist(note), chosen = try select(before)
        guard !chosen.isEmpty else { throw NotesError("checklist_item_not_found", "No checklist item matched.") }
        let selected = before.filter { chosen.contains($0.index) }
        do {
            let editor = try NCBodyEditor(note: note), original = editor.original; try editor.begin(["attributes"])
            for item in before where chosen.contains(item.index) {
                let range = NSRange(location: item.range.location, length: max(1, item.range.length))
                let probe = min(range.location, max(0, original.length - 1)); let attrs = original.attributes(at: probe, effectiveRange: nil)
                let old = attrs[NSAttributedString.Key("TTStyle")] as AnyObject?
                let style = try NCNotesRuntime.paragraphStyle(103, indent: value(old, "indent") as? Int ?? 0, quote: value(old, "blockQuoteLevel") as? Int ?? 0,
                                                              checked: (done ?? !item.done) ? 1 : 0, basedOn: old)
                var updated = attrs; updated[NSAttributedString.Key("TTStyle")] = style
                try editor.setAttributes(updated, range: range)
            }
            try editor.finish(); try save(context, notes: [note])
        } catch let error as NotesError { context.rollback(); throw error } catch { context.rollback(); throw nativeError(error) }
        let expected = done ?? !before.first(where: { chosen.contains($0.index) })!.done
        return ChecklistWriteReceipt(noteID: id(note), selected: selected, expectedDone: expected)
    }

    fileprivate func verifyChecklist(_ receipt: ChecklistWriteReceipt, context: NSManagedObjectContext) throws -> NativeWriteResult {
        var after: [ChecklistItem] = []
        var nativeMatches = false
        for attempt in 0..<12 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
            context.refreshAllObjects()
            after = try checklist(try self.note(receipt.noteID, in: context))
            nativeMatches = receipt.selected.allSatisfy {
                NativeVerificationRules.checklistItem(after, expected: $0, done: receipt.expectedDone)
            }
            if nativeMatches { break }
        }
        let states = after.map { $0.done ? "1" : "0" }.joined(separator: ",")
        return result(receipt.noteID, native: ["doneFlags": states], nativeVerified: nativeMatches, sqlite: { note in
            guard let document = note.document,
                  receipt.selected.allSatisfy({ item in
                      let range = UTF16Range(location: item.range.location, length: max(1, item.range.length))
                      let runs = Self.documentRuns(document, in: range)
                      return NativeVerificationRules.exactText(document.text, text: item.text, location: item.range.location) &&
                          !runs.isEmpty && runs.allSatisfy {
                              $0.paragraph?.kind == .checklist && $0.paragraph?.checked == receipt.expectedDone
                          }
                  }) else { return nil }
            return ["selectedCount": "\(receipt.selected.count)", "done": "\(receipt.expectedDone)"]
        }, mismatch: "The selected checklist item did not have done=\(receipt.expectedDone) after exact readback; flags=\(states).")
    }

    public func toggleChecklist(_ ref: String, selection: ChecklistSelection, done: Bool?, allowShared: Bool) throws -> NativeWriteResult {
        try performWriteWithFreshReadback(transaction: { context in
            try setChecklist(ref, context: context, allowShared: allowShared, select: { items in
                switch selection {
                case .index(let index): return Set(items.filter { $0.index == index }.map(\.index))
                case .text(let text):
                    let matches = items.filter { $0.text == text }; guard matches.count <= 1 else { throw NotesError("ambiguous_checklist_item", "More than one checklist item has that text. Use --index.") }
                    return Set(matches.map(\.index))
                }
            }, done: done)
        }, readback: { context, receipt in try verifyChecklist(receipt, context: context) })
    }
    public func setAllChecklist(_ ref: String, done: Bool, allowShared: Bool) throws -> NativeWriteResult {
        try performWriteWithFreshReadback(
            transaction: { context in try setChecklist(ref, context: context, allowShared: allowShared, select: { Set($0.map(\.index)) }, done: done) },
            readback: { context, receipt in try verifyChecklist(receipt, context: context) }
        )
    }
    public func deleteCompleted(_ ref: String, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
        let items = try checklist(note).filter(\.done); guard !items.isEmpty else { return result(id(note), native: ["deleted": "0"], sqlite: nil, message: "No completed items.") }
        do {
            let editor = try NCBodyEditor(note: note), text = editor.original.string as NSString; try editor.begin(["delete"])
            let paragraphs = paragraphRanges(text)
            for item in items.sorted(by: { $0.range.location > $1.range.location }) {
                guard let p = paragraphs.firstIndex(where: { $0.location == item.range.location }) else { continue }
                let range: NSRange
                if p < paragraphs.count - 1 { range = NSRange(location: paragraphs[p].location, length: paragraphs[p + 1].location - paragraphs[p].location) }
                else if p > 0 { range = NSRange(location: NSMaxRange(paragraphs[p - 1]), length: NSMaxRange(paragraphs[p]) - NSMaxRange(paragraphs[p - 1])) }
                else { range = paragraphs[p] }
                try editor.delete(range)
            }
            try editor.finish(); try save(context, notes: [note])
        } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let left = try checklist(try self.note(id(note), in: context))
        return result(id(note), native: ["deleted": "\(items.count)", "remainingCompleted": "\(left.filter(\.done).count)"],
                      sqlite: { n in n.document?.runs.contains(where: { $0.paragraph?.kind == .checklist && $0.paragraph?.checked == true }) == false ? ["remainingCompleted": "0"] : nil })
        }
    }

    public func setPinned(_ ref: String, pinned: Bool, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note, protectsBody: false)
        do { try NCNotesRuntime.setPinned(pinned, note: note); try save(context, notes: [note]) } catch { context.rollback(); throw nativeError(error) }
        let fresh = try self.note(id(note), in: context), state = value(fresh, "isPinned") as? Bool == true
        return result(id(note), native: ["pinned": "\(state)"], nativeVerified: state == pinned,
                      sqlite: { $0.summary.isPinned == pinned ? ["pinned": "\(pinned)"] : nil })
        }
    }

    public func setQuickNote(_ ref: String, enabled: Bool, allowShared: Bool) throws -> NativeWriteResult {
        try setQuickNote(ref, enabled: enabled, expectedCurrent: nil, allowShared: allowShared)
    }

    public func setQuickNote(_ ref: String, enabled: Bool, expectedCurrent: Bool?, allowShared: Bool) throws -> NativeWriteResult {
        try requireQuickNoteAccount(try SQLiteNotesStore(refresh: true).summary(ref).accountID)
        return try performWrite { context in
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note, protectsBody: false)
        try requireUndoState(value(note, "isSystemPaper") as? Bool == true, expected: expectedCurrent,
                             label: "Quick Note state")
        do { try NCNotesRuntime.setSystemPaper(enabled, note: note); try save(context, notes: [note]) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let fresh = try self.note(id(note), in: context), state = value(fresh, "isSystemPaper") as? Bool
        return result(id(note), native: ["isSystemPaper": String(state == true)], nativeVerified: state == enabled,
                      sqlite: { $0.summary.isSystemPaper == enabled ? ["isSystemPaper": String(enabled)] : nil },
                      mismatch: "The persisted Quick Note state did not match.")
        }
    }

    fileprivate func normalizedTag(_ tag: String) throws -> String {
        let value = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0 == "#" }) else { throw NotesError("invalid_tag", "A tag must be one word without #.") }
        return value
    }

    fileprivate func attachmentMarkers(_ body: NSAttributedString) -> [(NSRange, AnyObject, String, String)] {
        var rows: [(NSRange, AnyObject, String, String)] = []
        body.enumerateAttribute(NSAttributedString.Key("NSAttachment"), in: NSRange(location: 0, length: body.length)) { value, range, _ in
            guard let marker = value as AnyObject?, let markerID = NCNotesRuntime.markerID(marker), let type = NCNotesRuntime.markerType(marker) else { return }
            rows.append((range, marker, markerID, type))
        }
        return rows
    }

    fileprivate func insertMarker(_ editor: NCBodyEditor, original: NSAttributedString, id: String, type: String, position: Int?) throws {
        let at = position ?? original.length; guard (0...original.length).contains(at) else { throw NotesError("invalid_range", "Position exceeds the note length.") }
        let marker = try NCNotesRuntime.attachmentMarker(id: id, type: type)
        let style = try NCNotesRuntime.paragraphStyle(3, indent: 0, quote: 0, checked: -1, basedOn: nil)
        try editor.begin(["insert"]); try editor.insert(NSAttributedString(string: "\u{fffc}", attributes: [.init("TTStyle"): style, .init("NSAttachment"): marker]), at: UInt(at))
    }

    public func addTag(_ ref: String, tag: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let name = try normalizedTag(tag), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
        do {
            let editor = try NCBodyEditor(note: note); try editor.prepare(["insert"])
            let attachmentID = try NCNotesRuntime.makeTag(name, in: note)
            try insertMarker(editor, original: editor.original, id: attachmentID, type: "com.apple.notes.inlinetextattachment.hashtag", position: position)
            try editor.finish()
            try validateBodiesBeforeSave([note])
            try NCNotesRuntime.save(context); operation?.committed = true; operation?.noteID = id(note)
            if let attachment = try fetch("ICInlineAttachment", predicate: NSPredicate(format: "identifier == %@", attachmentID), in: context, limit: 1).first { try NCNotesRuntime.reviveTagAttachment(attachment) }
            _ = try hashtag(name, context: context)
            try save(context, notes: [note])
        } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        return result(id(note), native: ["tag": name], sqlite: { $0.summary.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? ["tag": name] : nil })
        }
    }

    fileprivate func inlineMatches(_ note: NSManagedObject, type: String, label: String?) throws -> [(NSManagedObject, NSRange)] {
        let attributed = try body(note)
        guard let context = note.managedObjectContext else { throw NotesError("native_read_failed", "The note is detached from its native context.") }
        var result: [(NSManagedObject, NSRange)] = []
        for marker in attachmentMarkers(attributed) where marker.3 == type {
            guard let object = try fetch("ICInlineAttachment", predicate: NSPredicate(format: "identifier == %@", marker.2), in: context, limit: 1).first else { continue }
            let alt = (value(object, "altText") as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            if label == nil || alt.caseInsensitiveCompare(label!) == .orderedSame { result.append((object, marker.0)) }
        }
        return result
    }

    public func removeTag(_ ref: String, tag: String, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let name = try normalizedTag(tag), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
        let matches = try inlineMatches(note, type: "com.apple.notes.inlinetextattachment.hashtag", label: name)
        guard !matches.isEmpty else { throw NotesError("tag_not_found", "The note does not contain that native tag.") }
        do { let editor = try NCBodyEditor(note: note); try editor.begin(["delete"]); for row in matches.sorted(by: { $0.1.location > $1.1.location }) { try editor.delete(row.1); try NCNotesRuntime.markForDeletion(row.0) }; try editor.finish(); try save(context, notes: [note]) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        return result(id(note), native: ["removed": name], sqlite: { !$0.summary.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? ["removed": name] : nil })
        }
    }

    fileprivate func hashtag(_ name: String, context: NSManagedObjectContext) throws -> NSManagedObject {
        var rows = try fetch("ICHashtag", predicate: NSPredicate(value: true), in: context).filter { tag in
            return tag.entity.attributesByName.keys.compactMap { value(tag, $0) as? String }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
                .contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        if rows.isEmpty {
            let tagged = (try? SQLiteNotesStore(refresh: true).notes(NoteQuery(tag: name))) ?? []
            for summary in tagged {
                guard let taggedNote = try? note(summary.id.uuid, in: context) else { continue }
                for (attachment, _) in try inlineMatches(taggedNote, type: "com.apple.notes.inlinetextattachment.hashtag", label: nil) {
                    for (key, relationship) in attachment.entity.relationshipsByName where relationship.destinationEntity?.name == "ICHashtag" {
                        if let object = value(attachment, key) as? NSManagedObject { rows.append(object) }
                        else if let objects = value(attachment, key) as? Set<NSManagedObject> { rows += objects }
                    }
                }
            }
        }
        if rows.isEmpty {
            let inline = try fetch("ICInlineAttachment", predicate: NSPredicate(value: true), in: context).filter { attachment in
                guard value(attachment, "markedForDeletion") as? Bool != true,
                      value(attachment, "typeUTI") as? String == "com.apple.notes.inlinetextattachment.hashtag" else { return false }
                return [value(attachment, "altText") as? String, value(attachment, "displayText") as? String,
                        value(attachment, "standardizedContent") as? String]
                    .compactMap { $0?.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
                    .contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            rows = inline.flatMap { attachment in
                attachment.entity.relationshipsByName.compactMap { key, relationship -> [NSManagedObject]? in
                    guard relationship.destinationEntity?.name == "ICHashtag" else { return nil }
                    if let object = value(attachment, key) as? NSManagedObject { return [object] }
                    if let objects = value(attachment, key) as? Set<NSManagedObject> { return Array(objects) }
                    return nil
                }
            }.flatMap { $0 }
        }
        guard !rows.isEmpty else { throw NotesError("tag_not_found", "No native tag matches.") }
        let standardized = Set(rows.compactMap { (value($0, "standardizedContent") as? String)?.lowercased() })
        guard standardized.count <= 1 else { throw NotesError("ambiguous_tag", "Several native tags match.") }
        if value(rows[0], "markedForDeletion") as? Bool == true { try NCNotesRuntime.unmarkForDeletion(rows[0]) }
        return rows[0]
    }
    fileprivate func tagUses(_ name: String, context: NSManagedObjectContext) throws -> [(NSManagedObject, NSManagedObject, NSRange)] {
        var result: [(NSManagedObject, NSManagedObject, NSRange)] = []
        let attachments = try fetch("ICInlineAttachment", predicate: NSPredicate(format: "altText ==[c] %@ OR altText ==[c] %@", name, "#" + name), in: context)
        for attachment in attachments where value(attachment, "markedForDeletion") as? Bool != true {
            guard value(attachment, "typeUTI") as? String == "com.apple.notes.inlinetextattachment.hashtag",
                  let note = value(attachment, "note") as? NSManagedObject,
                  value(note, "markedForDeletion") as? Bool != true else { continue }
            if value(note, "isPasswordProtected") as? Bool == true {
                throw NotesError("note_locked", "A matching tag is in a locked note; nothing changed.")
            }
            let attachmentID = id(attachment)
            guard let range = attachmentMarkers(try body(note)).first(where: { $0.2 == attachmentID })?.0 else { continue }
            result.append((note, attachment, range))
        }
        return result
    }

    public func renameTag(_ tag: String, to: String, expectedCount: Int, allowShared: Bool = false) throws -> NativeWriteResult {
        try performWrite { context in
        let old = try normalizedTag(tag), new = try normalizedTag(to), uses = try tagUses(old, context: context)
        guard uses.count == expectedCount else { throw NotesError("expected_count_mismatch", "Tag is used by \(uses.count) notes/items, not \(expectedCount).") }
        for note in Dictionary(grouping: uses, by: { id($0.0) }).values.compactMap({ $0.first?.0 }) {
            try guardWritable(note, allowShared: allowShared)
        }
        for note in Dictionary(grouping: uses, by: { id($0.0) }).values.compactMap({ $0.first?.0 }) { try refreshIfStale(note) }
        do { try NCNotesRuntime.renameTag(try hashtag(old, context: context), to: new); try save(context, notes: Array(Dictionary(grouping: uses, by: { id($0.0) }).values.compactMap { $0.first?.0 })) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let oldUses = try tagUses(old, context: context), newUses = try tagUses(new, context: context)
        return globalResult(native: ["renamed": old, "to": new, "count": "\(newUses.count)"], nativeVerified: oldUses.isEmpty && newUses.count == uses.count,
                            sqlite: {
            let tags = try SQLiteNotesStore(refresh: true).tags()
            guard !tags.keys.contains(where: { $0.caseInsensitiveCompare(old) == .orderedSame }),
                  tags.keys.contains(where: { $0.caseInsensitiveCompare(new) == .orderedSame }) else { return nil }
            return ["renamed": old, "to": new]
        })
        }
    }

    public func deleteTag(_ tag: String, expectedCount: Int, allowShared: Bool = false) throws -> NativeWriteResult {
        try performWrite { context in
        let name = try normalizedTag(tag), uses = try tagUses(name, context: context)
        guard uses.count == expectedCount else { throw NotesError("expected_count_mismatch", "Tag is used \(uses.count) times, not \(expectedCount).") }
        let grouped = Dictionary(grouping: uses, by: { id($0.0) })
        for note in grouped.values.compactMap({ $0.first?.0 }) { try guardWritable(note, allowShared: allowShared); try refreshIfStale(note) }
        do {
            for rows in grouped.values { guard let note = rows.first?.0 else { continue }; let editor = try NCBodyEditor(note: note); try editor.begin(["delete"]); for row in rows.sorted(by: { $0.2.location > $1.2.location }) { try editor.delete(row.2); try NCNotesRuntime.markForDeletion(row.1) }; try editor.finish() }
            try save(context, notes: grouped.values.compactMap { $0.first?.0 })
        } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let remaining = try tagUses(name, context: context)
        return globalResult(native: ["deletedTag": name, "count": "\(uses.count)"], nativeVerified: remaining.isEmpty,
                            sqlite: {
            let tags = try SQLiteNotesStore(refresh: true).tags()
            guard !tags.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            return ["deletedTag": name]
        })
        }
    }

    private func paragraphLinkTarget(_ rawID: String, in target: NSManagedObject) throws -> (id: UUID, name: String?) {
        try paragraphLinkTarget(rawID, in: body(target), requireLinkableStyle: true)
    }

    private func paragraphLinkTarget(_ rawID: String, in targetBody: NSAttributedString,
                                     requireLinkableStyle: Bool) throws -> (id: UUID, name: String?) {
        guard let paragraphID = UUID(uuidString: rawID) else {
            throw NotesError("invalid_paragraph_id", "Paragraph ID must be a UUID.")
        }
        let source = targetBody.string as NSString
        var ranges: [NSRange] = []
        var linkableRanges: [NSRange] = []
        var seen: Set<String> = []
        var seenLinkable: Set<String> = []
        targetBody.enumerateAttribute(.init("TTStyle"), in: NSRange(location: 0, length: targetBody.length)) { raw, range, _ in
            guard let raw = raw as AnyObject?,
                  let found = value(raw, "uuid") as? UUID,
                  found.uuidString.caseInsensitiveCompare(paragraphID.uuidString) == .orderedSame else { return }
            var cursor = range.location
            let limit = NSMaxRange(range)
            while cursor < limit {
                let paragraphRange = source.paragraphRange(for: NSRange(location: cursor, length: 0))
                let key = "\(paragraphRange.location):\(paragraphRange.length)"
                if seen.insert(key).inserted { ranges.append(paragraphRange) }
                if (!requireLinkableStyle || value(raw, "supportsSectionLinks") as? Bool == true),
                   seenLinkable.insert(key).inserted {
                    linkableRanges.append(paragraphRange)
                }
                let next = NSMaxRange(paragraphRange)
                guard next > cursor else { break }
                cursor = next
            }
        }
        guard ranges.count == 1, let range = ranges.first else {
            let missing = ranges.isEmpty
            throw NotesError(missing ? "paragraph_not_found" : "ambiguous_paragraph_id", missing
                ? "The target note has no paragraph with ID \(paragraphID.uuidString)."
                : "The target note uses paragraph ID \(paragraphID.uuidString) more than once.")
        }
        guard linkableRanges.count == 1 else {
            throw NotesError("paragraph_not_linkable", "The target paragraph is not a linkable heading or subheading.")
        }
        let name = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return (paragraphID, name.isEmpty ? nil : name)
    }

    func paragraphLinkTarget(_ rawID: String, in document: NoteDocument) throws -> (id: UUID, name: String?) {
        guard let paragraphID = UUID(uuidString: rawID) else {
            throw NotesError("invalid_paragraph_id", "Paragraph ID must be a UUID.")
        }
        let source = document.text as NSString
        var offset = 0
        var ranges: [NSRange] = []
        var linkableRanges: [NSRange] = []
        var seen: Set<String> = []
        var seenLinkable: Set<String> = []
        for run in document.runs {
            defer { offset += run.length }
            guard run.length >= 0, offset + run.length <= source.length,
                  run.paragraph?.id?.caseInsensitiveCompare(paragraphID.uuidString) == .orderedSame else { continue }
            let range = source.paragraphRange(for: NSRange(location: offset, length: 0))
            let key = "\(range.location):\(range.length)"
            if seen.insert(key).inserted { ranges.append(range) }
            if let kind = run.paragraph?.kind, [.heading, .subheading].contains(kind),
               seenLinkable.insert(key).inserted {
                linkableRanges.append(range)
            }
        }
        guard ranges.count == 1, let range = ranges.first else {
            let missing = ranges.isEmpty
            throw NotesError(missing ? "paragraph_not_found" : "ambiguous_paragraph_id", missing
                ? "The saved note has no paragraph with ID \(paragraphID.uuidString)."
                : "The saved note uses paragraph ID \(paragraphID.uuidString) more than once.")
        }
        guard linkableRanges.count == 1 else {
            throw NotesError("paragraph_not_linkable", "The saved target paragraph is not a linkable heading or subheading.")
        }
        let name = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return (paragraphID, name.isEmpty ? nil : name)
    }

    public func insertNoteLink(_ ref: String, target: String, text: String?, paragraphID: String? = nil,
                               paragraphName: String? = nil, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let source = try note(ref, in: context), destination = try note(target, in: context); try guardWritable(source, allowShared: allowShared); try refreshIfStale(source)
        if paragraphID == nil {
            guard paragraphName == nil else { throw NotesError("invalid_paragraph_name", "paragraph_name requires paragraph_id.") }
            guard id(source) != id(destination) else { throw NotesError("invalid_note_link", "A note can link to itself only when paragraph_id is provided.") }
        }
        let paragraph = try paragraphID.map { try paragraphLinkTarget($0, in: destination) }
        let resolvedParagraphName = paragraphName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if paragraphName != nil && resolvedParagraphName?.isEmpty != false {
            throw NotesError("invalid_paragraph_name", "Paragraph name cannot be empty.")
        }
        var attachmentID = ""
        do {
            let editor = try NCBodyEditor(note: source); try editor.prepare(["insert"])
            if let paragraph {
                attachmentID = try NCNotesRuntime.makeParagraphLink(
                    to: destination, paragraphName: resolvedParagraphName ?? paragraph.name,
                    paragraphID: paragraph.id, from: source, text: text ?? "", parent: nil
                )
            } else {
                attachmentID = try NCNotesRuntime.makeNoteLink(to: destination, from: source,
                                                               text: text ?? title(destination))
            }
            try insertMarker(editor, original: editor.original, id: attachmentID,
                             type: "com.apple.notes.inlinetextattachment.link", position: position)
            try editor.finish(); try save(context, notes: [source])
        }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let read = try linkRows(source)
        let destinationID = id(destination)
        let expectedParagraphID = paragraph?.id.uuidString
        var native = ["target": destinationID, "linkCount": "\(read.count)", "attachmentID": attachmentID]
        if let expectedParagraphID { native["paragraphID"] = expectedParagraphID }
        return result(id(source), native: native,
                      nativeVerified: NativeVerificationRules.exactLink(read, attachmentID: attachmentID,
                                                                         targetID: destinationID,
                                                                         paragraphID: expectedParagraphID), sqlite: { n in
            guard let found = n.attachments.first(where: { $0.id == attachmentID }),
                  found.targetNoteID?.caseInsensitiveCompare(destinationID) == .orderedSame,
                  (expectedParagraphID == nil && found.targetParagraphID == nil ||
                   expectedParagraphID != nil && found.targetParagraphID?.caseInsensitiveCompare(expectedParagraphID!) == .orderedSame) else { return nil }
            var values = ["target": destinationID, "attachmentID": attachmentID]
            if let expectedParagraphID { values["paragraphID"] = expectedParagraphID }
            return values
        }, mismatch: "Attachment \(attachmentID) did not preserve its exact note and paragraph target.")
        }
    }

    fileprivate enum InlineObjectRequest {
        case divider
        case math(String)
        case mention(text: String, userRecordName: String)
    }

    fileprivate func insertInlineObject(_ ref: String, request: InlineObjectRequest, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
        var resolvedRequest = request
        if case .mention = resolvedRequest {
            guard isShared(note) else { throw NotesError("mention_requires_shared_note", "Mentions are supported only in shared notes.") }
            guard allowShared else { throw NotesError("shared_write_refused", "Creating a mention changes a shared note. Pass --allow-shared.") }
        }
        if case .mention(let text, let requestedIdentity) = resolvedRequest {
            let summary = try SQLiteNotesStore(refresh: true).summary(id(note))
            let allIdentity: String?
            if requestedIdentity.caseInsensitiveCompare("all") == .orderedSame ||
                requestedIdentity.caseInsensitiveCompare("@all") == .orderedSame {
                do { allIdentity = try NCNotesRuntime.allMentionUserRecordName() }
                catch { throw nativeError(error) }
            } else {
                allIdentity = nil
            }
            let identity = try NativeMentionTarget.resolve(requestedIdentity,
                                                           participants: summary.participants ?? [],
                                                           allIdentity: allIdentity)
            resolvedRequest = .mention(text: text, userRecordName: identity)
        }
        var attachmentID = "", kind: NSString?
        do {
            let editor = try NCBodyEditor(note: note); try editor.prepare(["insert"])
            switch resolvedRequest {
            case .divider: attachmentID = try NCNotesRuntime.makeDivider(in: note, type: &kind)
            case .math(let expression):
                guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NotesError("invalid_math_expression", "Math expression cannot be empty.") }
                attachmentID = try NCNotesRuntime.makeMathExpression(expression, in: note, type: &kind)
            case .mention(let text, let userRecordName):
                guard !text.isEmpty, !userRecordName.isEmpty else { throw NotesError("invalid_mention", "Mention text and user record name are required.") }
                attachmentID = try NCNotesRuntime.makeMention(text, userRecordName: userRecordName, in: note, type: &kind)
            }
            try insertMarker(editor, original: editor.original, id: attachmentID, type: kind as String? ?? "public.data", position: position)
            try editor.finish(); try save(context, notes: [note])
        } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let fresh = try self.note(id(note), in: context), placements = attachmentMarkers(try body(fresh)).filter { $0.2 == attachmentID }
        return result(id(note), native: ["attachmentID": attachmentID, "type": kind as String? ?? ""], nativeVerified: placements.count == 1,
                      sqlite: { decoded in
            guard let attachment = decoded.attachments.first(where: { $0.id == attachmentID }) else { return nil }
            switch resolvedRequest {
            case .divider: return attachment.isDivider == true ? ["attachmentID": attachmentID, "type": attachment.typeUTI] : nil
            case .math(let expression): return attachment.mathExpression == expression || attachment.graphExpression == expression ? ["attachmentID": attachmentID, "expression": expression] : nil
            case .mention(_, let userRecordName): return attachment.participantUserID == userRecordName || attachment.participantID == userRecordName ? ["attachmentID": attachmentID, "userRecordName": userRecordName] : nil
            }
        }, mismatch: "Inline attachment \(attachmentID) did not match after insertion.")
        }
    }

    public func insertDivider(_ ref: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try insertInlineObject(ref, request: .divider, position: position, allowShared: allowShared)
    }
    public func insertMathExpression(_ ref: String, expression: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try insertInlineObject(ref, request: .math(expression), position: position, allowShared: allowShared)
    }
    public func evaluateMath(_ expression: String) throws -> NativeCalculation {
        do {
            let value = try NCNotesRuntime.evaluateMathExpression(expression)
            guard let source = value["expression"],
                  let formatted = value["formattedExpression"],
                  let result = value["result"],
                  let rendered = value["renderedText"] else {
                throw NotesError("invalid_math_result", "Notes returned an incomplete math result.")
            }
            return NativeCalculation(expression: source, formattedExpression: formatted,
                                     result: result, renderedText: rendered)
        } catch let error as NotesError {
            throw error
        } catch {
            throw NotesError("math_evaluation_failed", error.localizedDescription)
        }
    }
    public func insertMathResult(_ ref: String, expression: String, position: Int?, allowShared: Bool) throws -> NativeMathResult {
        let calculation = try evaluateMath(expression)
        var insertionPosition = 0
        let write = try performWrite { context in
            let expected = calculation.renderedText as NSString
            let (note, after) = try mutateBody(ref, context: context, allowShared: allowShared) { _, editor, original in
                insertionPosition = position ?? original.length
                guard (0...original.length).contains(insertionPosition) else {
                    throw NotesError("invalid_range", "Position exceeds note length.")
                }
                try editor.begin(["insert"])
                try editor.insert(NSAttributedString(string: calculation.renderedText), at: UInt(insertionPosition))
            }
            let nativeExact = NativeVerificationRules.exactText(after.string, text: calculation.renderedText,
                                                                location: insertionPosition)
            return result(id(note), native: ["expression": calculation.expression,
                                             "result": calculation.result,
                                             "renderedText": calculation.renderedText,
                                             "location": "\(insertionPosition)"],
                          nativeVerified: nativeExact, sqlite: { decoded in
                guard let value = decoded.document?.text as NSString?,
                      insertionPosition + expected.length <= value.length,
                      value.substring(with: NSRange(location: insertionPosition, length: expected.length)) == calculation.renderedText else {
                    return nil
                }
                return ["expression": calculation.expression, "result": calculation.result,
                        "renderedText": calculation.renderedText, "location": "\(insertionPosition)"]
            }, mismatch: "Expected the evaluated math text at UTF-16 location \(insertionPosition).")
        }
        return NativeMathResult(calculation: calculation, position: insertionPosition, write: write)
    }
    public func insertMention(_ ref: String, text: String, userRecordName: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try insertInlineObject(ref, request: .mention(text: text, userRecordName: userRecordName), position: position, allowShared: allowShared)
    }

    fileprivate func linkRows(_ source: NSManagedObject) throws -> [NativeNoteLink] {
        guard let context = source.managedObjectContext else { throw NotesError("native_read_failed", "The note is detached from its native context.") }
        return try inlineMatches(source, type: "com.apple.notes.inlinetextattachment.link", label: nil).map { attachment, range in
            let token = value(attachment, "tokenContentIdentifier") as? String ?? ""
            let components = URLComponents(string: token)
            let queryID = components?.queryItems?.first(where: {
                $0.name.caseInsensitiveCompare("identifier") == .orderedSame
            })?.value
            let match = token.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, options: .regularExpression)
            let candidate = queryID ?? match.map { String(token[$0]) }
            let target = try candidate.flatMap { try fetch("ICNote", predicate: NSPredicate(format: "identifier ==[c] %@", $0), in: context, limit: 1).first.map(id) } ?? token
            let paragraphID = components?.queryItems?.first(where: {
                $0.name.caseInsensitiveCompare("paragraphID") == .orderedSame
            })?.value
            let label = value(attachment, "altText") as? String ?? ""
            return NativeNoteLink(sourceID: id(source), targetID: target, targetParagraphID: paragraphID,
                                  targetParagraphName: nil, text: label,
                                  attachmentID: id(attachment), range: UTF16Range(location: range.location, length: range.length))
        }
    }
    public func links(_ ref: String) throws -> [NativeNoteLink] { try performRead { c in try linkRows(note(ref, in: c)) } }
    public func backlinks(_ ref: String) throws -> [NativeNoteLink] {
        try performRead { context in
        let target = id(try note(ref, in: context))
        let attachments = try fetch("ICInlineAttachment", predicate: NSPredicate(format: "tokenContentIdentifier CONTAINS[c] %@", target), in: context)
        return try attachments.compactMap { attachment in
            guard value(attachment, "markedForDeletion") as? Bool != true,
                  value(attachment, "typeUTI") as? String == "com.apple.notes.inlinetextattachment.link",
                  let source = value(attachment, "note") as? NSManagedObject,
                  value(source, "markedForDeletion") as? Bool != true else { return nil }
            let attachmentID = id(attachment)
            guard let range = attachmentMarkers(try body(source)).first(where: { $0.2 == attachmentID })?.0 else { return nil }
            let token = value(attachment, "tokenContentIdentifier") as? String ?? ""
            let paragraphID = URLComponents(string: token)?.queryItems?.first(where: {
                $0.name.caseInsensitiveCompare("paragraphID") == .orderedSame
            })?.value
            let label = value(attachment, "altText") as? String ?? ""
            return NativeNoteLink(sourceID: id(source), targetID: target, targetParagraphID: paragraphID,
                                  targetParagraphName: nil, text: label,
                                  attachmentID: attachmentID, range: UTF16Range(location: range.location, length: range.length))
        }
        }
    }

    /// Read-only export of stored collaboration activity. Never saves; discards any in-memory
    /// state the NotesShared getters create while decoding.
    public func collaborationActivity(_ ref: String,
                                      limits: CollaborationActivityLimits = CollaborationActivityLimits()) throws -> CollaborationActivityExport {
        try performRead { context in
            let target = try note(ref, in: context)
            let wasDirty = target.hasChanges
            defer { if !wasDirty, target.hasChanges { context.refresh(target, mergeChanges: false) } }
            let reader = CollaborationActivityRuntimeReader(
                value: { object, key in NCNotesRuntime.value(forKey: key, of: object) },
                responds: { object, key in (object as? NSObject)?.responds(to: NSSelectorFromString(key)) ?? false },
                className: { object in String(cString: object_getClassName(object)) })
            return CollaborationActivityExporter.export(noteID: id(target), title: title(target),
                                                        raw: try reader.read(note: target), limits: limits)
        }
    }

    public func insertText(_ ref: String, text: String, position: Int, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let expected = text as NSString
        let (note, after) = try mutateBody(ref, context: context, allowShared: allowShared) { _, editor, original in guard (0...original.length).contains(position) else { throw NotesError("invalid_range", "Position exceeds note length.") }; try editor.begin(["insert"]); try editor.insert(NSAttributedString(string: text), at: UInt(position)) }
        let nativeExact = NativeVerificationRules.exactText(after.string, text: text, location: position)
        return result(id(note), native: ["length": "\(after.length)", "location": "\(position)", "text": text], nativeVerified: nativeExact, sqlite: { note in
            guard let value = note.document?.text as NSString?, position + expected.length <= value.length,
                  value.substring(with: NSRange(location: position, length: expected.length)) == text else { return nil }
            return ["location": "\(position)", "text": text]
        }, mismatch: "Expected the inserted text at UTF-16 location \(position).")
        }
    }
    public func deleteRange(_ ref: String, range: UTF16Range, allowShared: Bool) throws -> NativeWriteResult { try replaceRange(ref, range: range, text: "", allowShared: allowShared) }
    public func replaceRange(_ ref: String, range: UTF16Range, text: String, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let expected = text as NSString
        let (note, after) = try mutateBody(ref, context: context, allowShared: allowShared) { _, editor, original in
            let target = try self.valid(range, length: original.length)
            try editor.begin(["replace"])
            try editor.replace(target, with: NSAttributedString(string: text))
        }
        let nativeExact = NativeVerificationRules.exactText(after.string, text: text, location: range.location)
        return result(id(note), native: ["length": "\(after.length)", "location": "\(range.location)", "text": text], nativeVerified: nativeExact, sqlite: { note in
            guard let value = note.document?.text as NSString?, range.location + expected.length <= value.length,
                  value.substring(with: NSRange(location: range.location, length: expected.length)) == text else { return nil }
            return ["location": "\(range.location)", "text": text]
        }, mismatch: "Expected the replacement text at UTF-16 location \(range.location).")
        }
    }
    public func searchOffsets(_ ref: String, text: String, caseInsensitive: Bool) throws -> [UTF16Range] {
        try performRead { c in guard !text.isEmpty else { return [] }; let source = try body(note(ref, in: c)).string as NSString
        var rows: [UTF16Range] = [], start = 0
        while start <= source.length { let found = source.range(of: text, options: caseInsensitive ? [.caseInsensitive, .diacriticInsensitive] : [], range: NSRange(location: start, length: source.length - start)); if found.location == NSNotFound { break }; rows.append(UTF16Range(location: found.location, length: found.length)); start = NSMaxRange(found) }
        return rows }
    }

    public func setParagraphStyle(_ ref: String, range: UTF16Range, style: NativeParagraphStyle, indent: Int?,
                                  alignment: NativeParagraphAlignment? = nil, writingDirection: NativeWritingDirection? = nil,
                                  collapsed: Bool? = nil, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let (note, after) = try mutateBody(ref, context: context, allowShared: allowShared) { note, editor, original in
            let target = try self.valid(range, length: original.length, allowEmpty: false)
            var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
            original.enumerateAttributes(in: target) { attrs, run, _ in runs.append((run, attrs)) }
            var writes: [(NSRange, [NSAttributedString.Key: Any])] = []
            var paragraphIDs: [String] = []
            for (run, attrs) in runs {
                var copy = attrs; let old = attrs[.init("TTStyle")] as AnyObject?
                if let old { try self.require(["indent", "blockQuoteLevel"], of: old) }
                let made = try NCNotesRuntime.paragraphStyle(style.number, indent: indent ?? (self.value(old, "indent") as? Int ?? 0), quote: style == .blockquote ? 1 : (self.value(old, "blockQuoteLevel") as? Int ?? 0), checked: style == .checklist ? 0 : -1, basedOn: old)
                if let alignment {
                    try self.require(["setAlignment:"], of: made as AnyObject)
                    try NCNotesRuntime.setValue(alignment.value, forKey: "alignment", of: made as AnyObject)
                }
                if let writingDirection {
                    try self.require(["setWritingDirection:"], of: made as AnyObject)
                    try NCNotesRuntime.setValue(writingDirection.value, forKey: "writingDirection", of: made as AnyObject)
                }
                if collapsed != nil {
                    try self.require(["uuid", "supportsSectionLinks"], of: made as AnyObject)
                    if self.value(made as AnyObject, "supportsSectionLinks") as? Bool == true,
                       let uuid = self.value(made as AnyObject, "uuid") as? UUID { paragraphIDs.append(uuid.uuidString) }
                }
                copy[.init("TTStyle")] = made
                writes.append((run, copy))
            }
            if let collapsed {
                guard !paragraphIDs.isEmpty else { throw NotesError("not_collapsible", "The selected range has no collapsible heading or subheading.") }
                try self.require(["outlineState", "setOutlineStateData:", "outlineStateData"], of: note)
                let state = self.value(note, "outlineState") as AnyObject?
                if let state { try self.require(["collapsedUUIDStrings"], of: state) }
                var ids = Set((state.flatMap { self.value($0, "collapsedUUIDStrings") as? [String] }) ?? [])
                for id in paragraphIDs { if collapsed { ids.insert(id) } else { ids.remove(id) } }
                let data = try NCNotesRuntime.outlineStateData(collapsedUUIDStrings: ids.sorted())
                try NCNotesRuntime.setValue(data, forKey: "outlineStateData", of: note)
            }
            try editor.begin(["attributes"]); for row in writes { try editor.setAttributes(row.1, range: row.0) }
        }
        let target = try valid(range, length: after.length, allowEmpty: false)
        var nativeMatches = true
        after.enumerateAttribute(.init("TTStyle"), in: target) { raw, _, _ in
            guard let raw = raw as AnyObject? else { nativeMatches = false; return }
            let styleMatches = style == .blockquote ? (value(raw, "style") as? Int == 3 && (value(raw, "blockQuoteLevel") as? Int ?? 0) > 0) : value(raw, "style") as? Int == style.number
            let indentMatches = indent.map { value(raw, "indent") as? Int == $0 } ?? true
            let alignmentMatches = alignment.map { value(raw, "alignment") as? Int == $0.value } ?? true
            let directionMatches = writingDirection.map { value(raw, "writingDirection") as? Int == $0.value } ?? true
            nativeMatches = nativeMatches && styleMatches && indentMatches && alignmentMatches && directionMatches
        }
        if let collapsed {
            try require(["outlineStateData"], of: note)
            guard let data = value(note, "outlineStateData") as? Data else { nativeMatches = false; return result(id(note), native: [:], nativeVerified: false) }
            let ids = Set(try NotesOutlineDecoder.decode(data))
            let selectedIDs = after.attribute(.init("TTStyle"), at: target.location, effectiveRange: nil).flatMap { value($0 as AnyObject, "uuid") as? UUID }.map { [$0.uuidString] } ?? []
            nativeMatches = nativeMatches && !selectedIDs.isEmpty && selectedIDs.allSatisfy { ids.contains($0) == collapsed }
        }
        return result(id(note), native: ["style": style.rawValue, "location": "\(range.location)", "length": "\(range.length)"], nativeVerified: nativeMatches,
                      sqlite: { n in
            guard let document = n.document else { return nil }
            let runs = Self.documentRuns(document, in: range)
            guard !runs.isEmpty, runs.allSatisfy({ run in
                run.paragraph?.kind.rawValue == style.rawValue &&
                (indent == nil || run.paragraph?.indent == indent) &&
                (alignment == nil || run.paragraph?.alignment == alignment?.value) &&
                (writingDirection == nil || run.paragraph?.writingDirection == writingDirection?.value) &&
                (collapsed == nil || run.paragraph?.collapsed == collapsed)
            }) else { return nil }
            return ["style": style.rawValue, "location": "\(range.location)", "length": "\(range.length)"]
        })
        }
    }

    public func setInlineFormat(_ ref: String, range: UTF16Range, format: InlineFormat, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        if let superscript = format.superscript, !(-1...1).contains(superscript) { throw NotesError("invalid_superscript", "Superscript must be -1, 0, or 1.") }
        if let size = format.fontSize, !size.isFinite || size <= 0 { throw NotesError("invalid_font_size", "Font size must be a positive number.") }
        if let name = format.fontName, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw NotesError("invalid_font_name", "Font name cannot be empty.") }
        let requestedColor = try format.color.map(Self.color)
        let (note, after) = try mutateBody(ref, context: context, allowShared: allowShared) { _, editor, original in
            let target = try self.valid(range, length: original.length, allowEmpty: false)
            var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
            original.enumerateAttributes(in: target) { attrs, run, _ in runs.append((run, attrs)) }
            var writes: [(NSRange, [NSAttributedString.Key: Any])] = []
            for (run, attrs) in runs {
                var copy = attrs, hints = copy[.init("TTHints")] as? Int ?? 0
                if let bold = format.bold { hints = bold ? hints | 1 : hints & ~1 }; if let italic = format.italic { hints = italic ? hints | 2 : hints & ~2 }; copy[.init("TTHints")] = hints == 0 ? nil : hints
                if let underline = format.underline { copy[.init("TTUnderline")] = underline ? 1 : nil }; if let strike = format.strike { copy[.init("TTStrikethrough")] = strike ? 1 : nil }
                if format.clearLink { copy[.init("NSLink")] = nil } else if let link = format.link { copy[.init("NSLink")] = URL(string: link) ?? link }
                if format.clearColor { copy[.init("TTColor")] = nil } else if let requestedColor { copy[.init("TTColor")] = requestedColor }
                if let superscript = format.superscript { copy[.init("NSSuperScript")] = superscript == 0 ? nil : superscript }
                if format.clearHighlight { copy[.init("TTEmphasis")] = nil } else if let highlight = format.highlight { copy[.init("TTEmphasis")] = highlight.notesValue }
                let oldFont = copy[.init("ICTTFont")] as AnyObject?
                if format.fontName != nil || format.fontSize != nil || (oldFont != nil && (format.bold != nil || format.italic != nil)) {
                    if let oldFont { try self.require(["fontName", "pointSize", "fontHints"], of: oldFont) }
                    copy[.init("ICTTFont")] = try NCNotesRuntime.font(name: format.fontName, size: format.fontSize.map(NSNumber.init(value:)), hints: hints, basedOn: oldFont)
                }
                writes.append((run, copy))
            }
            try editor.begin(["attributes"]); for row in writes { try editor.setAttributes(row.1, range: row.0) }
        }
        let target = try valid(range, length: after.length, allowEmpty: false)
        var attributeRows: [[NSAttributedString.Key: Any]] = []
        after.enumerateAttributes(in: target) { attrs, _, _ in attributeRows.append(attrs) }
        let nativeMatches = try attributeRows.allSatisfy { try Self.matches($0, format: format) }
        return result(id(note), native: ["formatted": "true", "location": "\(range.location)", "length": "\(range.length)"], nativeVerified: nativeMatches,
                      sqlite: { n in
            guard let document = n.document else { return nil }
            guard NativeVerificationRules.exactRuns(document, range: range, match: { Self.matches($0, format: format) }) else { return nil }
            return ["formatted": "true", "location": "\(range.location)", "length": "\(range.length)"]
        })
        }
    }

    fileprivate static func documentRuns(_ document: NoteDocument, in range: UTF16Range) -> [AttributeRun] {
        var offset = 0, rows: [AttributeRun] = []
        let end = range.location + range.length
        for run in document.runs {
            let runEnd = offset + run.length
            if offset < end && runEnd > range.location { rows.append(run) }
            offset = runEnd
        }
        return rows
    }
    fileprivate static func matches(_ attrs: [NSAttributedString.Key: Any], format: InlineFormat) throws -> Bool {
        let hints = attrs[.init("TTHints")] as? Int ?? 0
        if let bold = format.bold, (hints & 1 != 0) != bold { return false }
        if let italic = format.italic, (hints & 2 != 0) != italic { return false }
        if let underline = format.underline, (attrs[.init("TTUnderline")] as? NSNumber)?.boolValue != underline { return false }
        if let strike = format.strike, (attrs[.init("TTStrikethrough")] as? NSNumber)?.boolValue != strike { return false }
        let link = attrs[.init("NSLink")].map { ($0 as? URL)?.absoluteString ?? String(describing: $0) }
        if format.clearLink, link != nil { return false }
        if let expected = format.link, link != expected { return false }
        if format.clearColor, attrs[.init("TTColor")] != nil { return false }
        if format.color != nil, attrs[.init("TTColor")] == nil { return false }
        if let superscript = format.superscript, (attrs[.init("NSSuperScript")] as? NSNumber)?.intValue ?? 0 != superscript { return false }
        if format.clearHighlight, attrs[.init("TTEmphasis")] != nil { return false }
        if let highlight = format.highlight, (attrs[.init("TTEmphasis")] as? NSNumber)?.intValue != highlight.notesValue { return false }
        if format.fontName != nil || format.fontSize != nil {
            guard let font = attrs[.init("ICTTFont")] as AnyObject? else { return false }
            try NCNotesRuntime.requireSelectors(["fontName", "pointSize"], of: font)
            if let name = format.fontName, NCNotesRuntime.value(forKey: "fontName", of: font) as? String != name { return false }
            if let size = format.fontSize, abs((NCNotesRuntime.value(forKey: "pointSize", of: font) as? Double ?? 0) - size) > 0.001 { return false }
        }
        return true
    }
    fileprivate static func matches(_ run: AttributeRun, format: InlineFormat) -> Bool {
        if let value = format.bold, run.font.bold != value { return false }
        if let value = format.italic, run.font.italic != value { return false }
        if let value = format.underline, run.font.underline != value { return false }
        if let value = format.strike, run.font.strikethrough != value { return false }
        if format.clearLink, run.link != nil { return false }
        if let value = format.link, run.link != value { return false }
        if format.clearColor, run.color != nil { return false }
        if let value = format.color, run.color?.caseInsensitiveCompare(value.hasPrefix("#") ? value : "#" + value) != .orderedSame { return false }
        if let value = format.superscript, run.font.superscript != value { return false }
        if format.clearHighlight, run.highlight != nil { return false }
        if let value = format.highlight, run.highlight != value { return false }
        if let value = format.fontName, run.font.name != value { return false }
        if let value = format.fontSize, abs(Double(run.font.pointSize ?? 0) - value) > 0.001 { return false }
        return true
    }
    fileprivate static func color(_ text: String) throws -> CGColor {
        let value = text.trimmingCharacters(in: CharacterSet(charactersIn: "#")); guard value.count == 6, let rgb = Int(value, radix: 16) else { throw NotesError("invalid_color", "Use a six-digit hex color.") }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1).cgColor
    }

    public func insertFile(_ ref: String, file: URL, position: Int?, imageView: String?, allowShared: Bool) throws -> NativeAttachmentResult {
        try insertFrozenFile(ref, frozen: FrozenAttachmentInput(file: file), position: position, imageView: imageView, allowShared: allowShared)
    }

    public func insertDrawing(_ ref: String, drawing: PKDrawing, position: Int?, allowShared: Bool) throws -> NativeAttachmentResult {
        let expectedStrokes = PaperStrokeRecord.records([drawing])
        guard !expectedStrokes.isEmpty else { throw NotesError("invalid_drawing", "The drawing has no strokes.") }
        return try performAttachmentWrite { context in
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note)
            var attachmentID = "", kind: NSString?, at = 0
            do {
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["insert"])
                at = position ?? editor.original.length
                attachmentID = try NCNotesRuntime.addSystemPaperDrawing(drawing as AnyObject, to: note, type: &kind)
                operation?.attachmentID = attachmentID
                operation?.attachmentType = kind as String? ?? "com.apple.notes.paper"
                operation?.attachmentPosition = at
                try insertMarker(editor, original: editor.original, id: attachmentID,
                                 type: kind as String? ?? "com.apple.notes.paper", position: position)
                try editor.finish()
                try save(context, notes: [note])
            } catch {
                context.rollback()
                throw (error as? NotesError) ?? nativeError(error)
            }
            let fresh = try self.note(id(note), in: context)
            let placements = attachmentMarkers(try body(fresh)).filter { $0.2 == attachmentID }.count
            let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@", attachmentID), in: context, limit: 1).first
            let decodedStrokes = try attachment.map(readBackStrokes) ?? []
            let decodedStrokeCount = decodedStrokes.count
            let strokeMismatch = PaperStrokeRecord.mismatch(expected: expectedStrokes, actual: decodedStrokes)
            let type = kind as String? ?? "com.apple.notes.paper"
            let native = ["attachmentID": attachmentID, "typeUTI": type, "placements": String(placements),
                          "strokeCount": String(decodedStrokeCount), "strokes": strokeMismatch ?? "match"]
            let write = result(id(note), native: native,
                               nativeVerified: placements == 1 && strokeMismatch == nil,
                               sqlite: { note in
                guard note.attachments.filter({ $0.id == attachmentID && $0.typeUTI == type }).count == 1 else { return nil }
                return ["attachmentID": attachmentID, "typeUTI": type, "placements": "1",
                        "strokeCount": String(decodedStrokeCount)]
            }, mismatch: "The Paper attachment or its editable strokes did not match the input drawing.")
            return NativeAttachmentResult(attachmentID: attachmentID, typeUTI: type, position: at, write: write)
        }
    }

    public func insertLegacyDrawing(_ ref: String, records: [LegacyDrawingStrokeRecord], position: Int?,
                                    allowShared: Bool) throws -> NativeAttachmentResult {
        try LegacyDrawingStrokeRecord.validate(records)
        let data = try JSONEncoder().encode(records)
        return try performAttachmentWrite { context in
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note)
            var attachmentID = "", kind: NSString?, at = 0
            do {
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["insert"])
                at = position ?? editor.original.length
                attachmentID = try NCNotesRuntime.addLegacyDrawing(strokesData: data, to: note, type: &kind)
                operation?.attachmentID = attachmentID
                operation?.attachmentType = kind as String? ?? "com.apple.notes.sketch"
                operation?.attachmentPosition = at
                try insertMarker(editor, original: editor.original, id: attachmentID,
                                 type: kind as String? ?? "com.apple.notes.sketch", position: position)
                try editor.finish()
                try save(context, notes: [note])
            } catch {
                context.rollback()
                throw (error as? NotesError) ?? nativeError(error)
            }
            let fresh = try self.note(id(note), in: context)
            let placements = attachmentMarkers(try body(fresh)).filter { $0.2 == attachmentID }.count
            let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@", attachmentID),
                                       in: context, limit: 1).first
            let decoded = try attachment.map { try readBackLegacyStrokes($0, identifier: attachmentID) } ?? []
            let mismatch = LegacyDrawingStrokeRecord.mismatch(expected: records, actual: decoded)
            let type = kind as String? ?? "com.apple.notes.sketch"
            let native = ["attachmentID": attachmentID, "typeUTI": type, "placements": String(placements),
                          "strokeCount": String(decoded.count), "strokes": mismatch ?? "match"]
            let write = result(id(note), native: native,
                               nativeVerified: placements == 1 && type == "com.apple.notes.sketch" && mismatch == nil,
                               sqlite: { note in
                guard note.attachments.filter({ $0.id == attachmentID && $0.typeUTI == type }).count == 1 else { return nil }
                return ["attachmentID": attachmentID, "typeUTI": type, "placements": "1",
                        "strokeCount": String(decoded.count)]
            }, mismatch: "The legacy Notes sketch or its editable strokes did not match the input drawing.")
            return NativeAttachmentResult(attachmentID: attachmentID, typeUTI: type, position: at, write: write)
        }
    }

    fileprivate func storedAttachmentHash(noteID: String, attachmentID: String, expected: String) -> String? {
        for attempt in 0..<12 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
            func find(_ id: String, in attachments: [Attachment]) -> Attachment? {
                for attachment in attachments {
                    if attachment.id == id { return attachment }
                    if let found = find(id, in: attachment.childAttachments ?? []) { return found }
                }
                return nil
            }
            guard let attachments = try? SQLiteNotesStore(refresh: true).attachments(noteID),
                  let attachment = find(attachmentID, in: attachments),
                  let path = attachment.filePath,
                  let hash = try? FrozenAttachmentInput.hash(file: URL(fileURLWithPath: path)) else { continue }
            if hash == expected { return hash }
        }
        return nil
    }

    private func stagedAttachmentHash(_ attachment: NSManagedObject, expected: String) throws -> String {
        let url: URL
        do { url = try NCNotesRuntime.mediaFileURL(for: attachment) }
        catch {
            throw NotesError(
                "snapshot_attachment_bytes_unavailable",
                "Notes did not expose the staged attachment bytes before save: \(error.localizedDescription)"
            )
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NotesError("snapshot_attachment_bytes_unavailable", "The staged attachment file does not exist before save.")
        }
        let actual = try FrozenAttachmentInput.hash(file: url)
        guard actual == expected else {
            throw NotesError("snapshot_attachment_hash_mismatch", "The staged attachment bytes do not match the snapshot; the restore was rolled back.")
        }
        return actual
    }

    private func corruptStagedAttachmentIfRequested(_ attachment: NSManagedObject, savedID: String) throws {
        #if DEBUG
        let requested = Set((ProcessInfo.processInfo.environment["NOTESCLI_TEST_CORRUPT_STAGED_RESTORE"] ?? "")
            .split(separator: ",").map(String.init))
        guard requested.contains(savedID) else { return }
        let url = try NCNotesRuntime.mediaFileURL(for: attachment)
        try Data("notescli-corrupt-staged-restore".utf8).write(to: url, options: .atomic)
        #endif
    }

    public func insertFrozenFile(_ ref: String, frozen: FrozenAttachmentInput, position: Int?, imageView: String?, allowShared: Bool) throws -> NativeAttachmentResult {
        try performAttachmentWrite { context in
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
        var attachmentID = "", kind: NSString?, at = 0
        do {
            let editor = try NCBodyEditor(note: note); try editor.prepare(["insert"]); at = position ?? editor.original.length
            if imageView != nil { try NCNotesRuntime.requireInstanceSelectors(["setPreferredViewSize:"], className: "ICAttachment") }
            attachmentID = try NCNotesRuntime.addFile(frozen.url, to: note, title: frozen.sourceName, type: &kind)
            operation?.attachmentID = attachmentID
            operation?.attachmentType = kind as String? ?? "public.data"
            operation?.attachmentPosition = at
            guard let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@", attachmentID), in: context, limit: 1).first else { throw NotesError("attachment_not_found", "Notes created no attachment record.") }
            if let imageView { guard ["small", "large"].contains(imageView) else { throw NotesError("invalid_image_view", "Use small or large.") }; try NCNotesRuntime.setPreferredImageSize(imageView, attachment: attachment) }
            try insertMarker(editor, original: editor.original, id: attachmentID, type: kind as String? ?? "public.data", position: position); try editor.finish(); try save(context, notes: [note])
        } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let count = attachmentMarkers(try body(try self.note(id(note), in: context))).filter { $0.2 == attachmentID }.count
        let stored = storedAttachmentHash(noteID: id(note), attachmentID: attachmentID, expected: frozen.sha256)
        let native = ["attachmentID": attachmentID, "placements": "\(count)", "sourceSHA256": frozen.sha256, "storedSHA256": stored ?? ""]
        let write = result(id(note), native: native,
                           nativeVerified: NativeVerificationRules.attachment(Array(repeating: attachmentID, count: count), id: attachmentID) && stored == frozen.sha256,
                           sqlite: { n in
            NativeVerificationRules.attachment(n.attachments.map(\.id), id: attachmentID) && stored == frozen.sha256
                ? ["attachmentID": attachmentID, "placements": "1", "storedSHA256": stored!] : nil
        }, mismatch: "Attachment \(attachmentID) was not present exactly once with the frozen input bytes.")
        return NativeAttachmentResult(attachmentID: attachmentID, typeUTI: kind as String? ?? "public.data", position: at,
                                      sourceSHA256: frozen.sha256, storedSHA256: stored, write: write)
        }
    }

    struct ScanPageEvidence: Sendable {
        var width: Int
        var height: Int
        var samples: [UInt8]
        var rasterSHA256: String

        func visuallyMatches(_ other: ScanPageEvidence) -> Bool {
            guard width == other.width, height == other.height, samples.count == other.samples.count else { return false }
            if rasterSHA256 == other.rasterSHA256 { return true }
            guard samples.count == 256 * 256 * 4 else { return false }
            var totalDifference = 0
            var changedPixels = 0
            var blockDifferences = [Int](repeating: 0, count: 64 * 64)
            for pixel in 0..<(256 * 256) {
                let offset = pixel * 4
                let red = abs(Int(samples[offset]) - Int(other.samples[offset]))
                let green = abs(Int(samples[offset + 1]) - Int(other.samples[offset + 1]))
                let blue = abs(Int(samples[offset + 2]) - Int(other.samples[offset + 2]))
                let difference = red + green + blue
                totalDifference += difference
                if max(red, green, blue) > 24 { changedPixels += 1 }
                let x = pixel % 256
                let y = pixel / 256
                blockDifferences[(y / 4) * 64 + (x / 4)] += difference
            }
            let channelCount = 256 * 256 * 3
            let averageDifference = Double(totalDifference) / Double(channelCount)
            let maximumBlockAverage = Double(blockDifferences.max() ?? 0) / Double(4 * 4 * 3)
            return averageDifference <= 3.0 &&
                changedPixels <= (256 * 256) / 500 &&
                maximumBlockAverage <= 18.0
        }
    }

    private struct ScanReceipt: Sendable {
        var noteID: String
        var attachmentID: String
        var pageAttachmentIDs: [String]
        var pageTypeUTIs: [String]
        var position: Int
        var sourcePages: [ScanPageEvidence]
        var existingPageIDs: [String] = []
    }

    public static let maximumScanPages = 100
    public static let maximumScanBytes = 200 * 1024 * 1024

    private static func scanPageEvidence(_ page: FrozenAttachmentInput) throws -> ScanPageEvidence {
        try scanPageEvidence(url: page.url, name: page.sourceName)
    }

    static func scanPageEvidence(url: URL, name: String) throws -> ScanPageEvidence {
        guard let image = NSImage(contentsOf: url),
              !image.representations.contains(where: { $0 is NSPDFImageRep }),
              let representation = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NotesError("invalid_scan_image", "Every scan page must be a readable image: \(name)")
        }
        return try rasterEvidence(representation, width: representation.width,
                                  height: representation.height, name: name)
    }

    private static func rasterEvidence(_ representation: CGImage, width: Int, height: Int,
                                       name: String) throws -> ScanPageEvidence {
        var samples = [UInt8](repeating: 0, count: 256 * 256 * 4)
        let rendered = samples.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(data: base, width: 256, height: 256, bitsPerComponent: 8,
                                          bytesPerRow: 256 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.interpolationQuality = .high
            context.draw(representation, in: CGRect(x: 0, y: 0, width: 256, height: 256))
            return true
        }
        guard rendered else { throw NotesError("invalid_scan_image", "The scan page could not be sampled: \(name)") }
        let hash = SHA256.hash(data: Data(samples)).map { String(format: "%02x", $0) }.joined()
        return ScanPageEvidence(width: width, height: height,
                                samples: samples, rasterSHA256: hash)
    }

    private static func pdfPageEvidence(_ url: URL) throws -> [ScanPageEvidence] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw NotesError("snapshot_integrity_failed", "The saved Paper fallback PDF is unreadable.")
        }
        return try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else {
                throw NotesError("snapshot_integrity_failed", "The saved Paper fallback PDF has a missing page.")
            }
            let bounds = page.bounds(for: .mediaBox)
            let thumbnail = page.thumbnail(of: NSSize(width: 512, height: 512), for: .mediaBox)
            guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw NotesError("snapshot_integrity_failed", "A Paper fallback PDF page could not be rendered.")
            }
            let aspect = bounds.height == 0 ? 0 : bounds.width / bounds.height
            return try rasterEvidence(image, width: Int((aspect * 10_000).rounded()),
                                      height: 10_000, name: "Paper page \(index + 1)")
        }
    }

    static func validateScanInputs(_ pages: [FrozenAttachmentInput]) throws {
        guard (1...maximumScanPages).contains(pages.count) else {
            throw NotesError("invalid_scan_page_count", "A scanned document requires between 1 and \(maximumScanPages) image pages.")
        }
        guard pages.reduce(0, { $0 + $1.byteCount }) <= maximumScanBytes else {
            throw NotesError("scan_too_large", "Scanned documents are limited to 200 MB across all pages.")
        }
        _ = try pages.map(scanPageEvidence)
    }

    public func insertScan(_ ref: String, pages: [FrozenAttachmentInput], position: Int?, allowShared: Bool) throws -> NativeScanResult {
        try Self.validateScanInputs(pages)
        let sourcePages = try pages.map(Self.scanPageEvidence)
        let preparation: NCPreparedScan
        do { preparation = try NCNotesRuntime.prepareScan(imageURLs: pages.map(\.url)) }
        catch { throw nativeError(error) }
        defer { preparation.invalidate() }
        do { try NCNotesRuntime.validateScanPopulation(preparation) }
        catch { throw nativeError(error) }

        return try performScanWrite(transaction: { context in
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note)
            let noteID = id(note)
            let attachmentID = UUID().uuidString.lowercased()
            var at = 0
            do {
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["insert"])
                at = position ?? editor.original.length
                guard (0...editor.original.length).contains(at) else {
                    throw NotesError("invalid_range", "Position exceeds the note length.")
                }
                let gallery = try NCNotesRuntime.newScanGallery(in: note, identifier: attachmentID)
                let type = value(gallery, "typeUTI") as? String ?? ""
                guard type == "com.apple.notes.gallery" else {
                    throw NotesError("scan_gallery_invalid", "Notes created an unexpected scan container type: \(type)")
                }
                operation?.noteID = noteID
                operation?.attachmentID = attachmentID
                operation?.attachmentType = type
                operation?.attachmentPosition = at
                try insertMarker(editor, original: editor.original, id: attachmentID, type: type, position: position)
                try editor.finish()
                try validateBodiesBeforeSave([note])

                // The gallery utility saves the Core Data context internally. Everything after this line
                // must be treated as committed even when the helper throws or returns partial data.
                operation?.committed = true
                let populated = try NCNotesRuntime.populateScanGallery(gallery, preparation: preparation, context: context)
                guard let pageIDs = populated["pageIDs"] as? [String],
                      let pageTypes = populated["pageTypes"] as? [String],
                      pageIDs.count == pages.count, pageTypes.count == pages.count else {
                    throw NotesError("scan_incomplete", "Notes did not create every scanned document page.")
                }
                operation?.childAttachmentIDs = pageIDs
                try save(context, notes: [note])
                return ScanReceipt(noteID: noteID, attachmentID: attachmentID,
                                   pageAttachmentIDs: pageIDs, pageTypeUTIs: pageTypes,
                                   position: at, sourcePages: sourcePages)
            } catch {
                context.rollback()
                throw (error as? NotesError) ?? nativeError(error)
            }
        }, readback: { context, receipt in
            let fresh = try self.note(receipt.noteID, in: context)
            let markers = attachmentMarkers(try body(fresh)).filter { $0.2 == receipt.attachmentID }
            let parents = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@ AND note == %@", receipt.attachmentID, fresh), in: context)
            let children = try fetch("ICAttachment", predicate: NSPredicate(format: "parentAttachment.identifier == %@", receipt.attachmentID), in: context)
            let nativeChildIDs = children.map(id)
            let nativePageOrder: [String]
            if let parent = parents.first {
                do { nativePageOrder = try NCNotesRuntime.galleryPageIdentifiers(in: parent) }
                catch { throw nativeError(error) }
            } else { nativePageOrder = [] }
            let parentType = parents.first.flatMap { value($0, "typeUTI") as? String } ?? ""
            let parentDeleted = parents.first.flatMap { value($0, "markedForDeletion") as? Bool } ?? true
            let expectedPageOrder = receipt.existingPageIDs + receipt.pageAttachmentIDs
            let nativeVerified = markers.count == 1 && markers.first?.3 == "com.apple.notes.gallery" &&
                parents.count == 1 && parentType == "com.apple.notes.gallery" && !parentDeleted &&
                Set(nativeChildIDs) == Set(expectedPageOrder) &&
                nativePageOrder == expectedPageOrder && nativeChildIDs.count == expectedPageOrder.count
            let native = ["attachmentID": receipt.attachmentID,
                          "typeUTI": parentType,
                          "placements": String(markers.count),
                          "pageIDs": receipt.pageAttachmentIDs.joined(separator: ","),
                          "storedPageOrder": nativePageOrder.joined(separator: ","),
                          "pageCount": String(nativeChildIDs.count)]
            let write = result(receipt.noteID, native: native, nativeVerified: nativeVerified, sqlite: { storedNote in
                guard let gallery = storedNote.attachments.first(where: { $0.id == receipt.attachmentID }),
                      gallery.typeUTI == "com.apple.notes.gallery",
                      gallery.childAttachmentIDs == expectedPageOrder,
                      let children = gallery.childAttachments,
                      children.count == expectedPageOrder.count else { return nil }
                let childrenByID = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })
                let orderedChildren = receipt.pageAttachmentIDs.compactMap { childrenByID[$0] }
                guard orderedChildren.count == receipt.pageAttachmentIDs.count,
                      orderedChildren.map(\.typeUTI) == receipt.pageTypeUTIs else { return nil }
                let storedPages = orderedChildren.compactMap { child -> ScanPageEvidence? in
                    guard let path = child.filePath else { return nil }
                    return try? Self.scanPageEvidence(url: URL(fileURLWithPath: path), name: child.filename ?? child.id)
                }
                guard storedPages.count == receipt.sourcePages.count,
                      zip(storedPages, receipt.sourcePages).allSatisfy({ $0.visuallyMatches($1) }) else { return nil }
                return ["attachmentID": receipt.attachmentID,
                        "pageIDs": receipt.pageAttachmentIDs.joined(separator: ","),
                        "pageCount": String(orderedChildren.count), "pages": "decoded_and_matched"]
            }, mismatch: "The scanned document structure or page order did not match after readback.")
            return NativeScanResult(attachmentID: receipt.attachmentID,
                                    pageAttachmentIDs: receipt.pageAttachmentIDs,
                                    position: receipt.position,
                                    write: write)
        })
    }

    public func appendScanPages(_ ref: String, attachmentID: String, pages: [FrozenAttachmentInput],
                                expectedPageIDs: [String]? = nil, allowShared: Bool) throws -> NativeScanResult {
        try Self.validateScanInputs(pages)
        let sourcePages = try pages.map(Self.scanPageEvidence)
        let preparation: NCPreparedScan
        do { preparation = try NCNotesRuntime.prepareScan(imageURLs: pages.map(\.url)) }
        catch { throw nativeError(error) }
        defer { preparation.invalidate() }
        do { try NCNotesRuntime.validateScanPopulation(preparation) }
        catch { throw nativeError(error) }

        return try performScanWrite(transaction: { context in
            let target = try note(ref, in: context)
            try guardWritable(target, allowShared: allowShared)
            guard let gallery = try fetch("ICAttachment", predicate: NSPredicate(
                format: "identifier == %@ AND note == %@ AND markedForDeletion == NO", attachmentID, target),
                in: context, limit: 1).first,
                  value(gallery, "typeUTI") as? String == "com.apple.notes.gallery" else {
                throw NotesError("scan_not_found", "No scanned document matches the attachment ID in this note.")
            }
            let before = try NCNotesRuntime.galleryPageIdentifiers(in: gallery)
            if let expectedPageIDs, before != expectedPageIDs {
                throw NotesError("scan_state_conflict", "The scanned document changed after its preimage was read.")
            }
            operation?.noteID = id(target)
            operation?.attachmentID = attachmentID
            operation?.attachmentType = "com.apple.notes.gallery"
            operation?.attachmentPosition = 0
            operation?.committed = true
            let populated: [String: Any]
            do { populated = try NCNotesRuntime.populateScanGallery(gallery, preparation: preparation, context: context) }
            catch { throw nativeError(error) }
            guard let pageIDs = populated["pageIDs"] as? [String],
                  let pageTypes = populated["pageTypes"] as? [String],
                  pageIDs.count == pages.count, pageTypes.count == pages.count else {
                throw NotesError("scan_incomplete", "Notes did not append every scanned document page.")
            }
            operation?.childAttachmentIDs = pageIDs
            try save(context, notes: [target])
            return ScanReceipt(noteID: id(target), attachmentID: attachmentID,
                               pageAttachmentIDs: pageIDs, pageTypeUTIs: pageTypes,
                               position: before.count, sourcePages: sourcePages,
                               existingPageIDs: before)
        }, readback: { context, receipt in
            let fresh = try self.note(receipt.noteID, in: context)
            let markers = attachmentMarkers(try body(fresh)).filter { $0.2 == receipt.attachmentID }
            let parents = try fetch("ICAttachment", predicate: NSPredicate(
                format: "identifier == %@ AND note == %@", receipt.attachmentID, fresh), in: context)
            let children = try fetch("ICAttachment", predicate: NSPredicate(
                format: "parentAttachment.identifier == %@", receipt.attachmentID), in: context)
            let nativeChildIDs = children.map(id)
            let nativePageOrder = try parents.first.map { try NCNotesRuntime.galleryPageIdentifiers(in: $0) } ?? []
            let expectedOrder = receipt.existingPageIDs + receipt.pageAttachmentIDs
            let nativeVerified = markers.count == 1 && parents.count == 1 &&
                Set(nativeChildIDs) == Set(expectedOrder) && nativePageOrder == expectedOrder
            let native = ["attachmentID": receipt.attachmentID,
                          "pageIDs": receipt.pageAttachmentIDs.joined(separator: ","),
                          "storedPageOrder": nativePageOrder.joined(separator: ","),
                          "pageCount": String(nativeChildIDs.count)]
            let write = result(receipt.noteID, native: native, nativeVerified: nativeVerified, sqlite: { storedNote in
                guard let gallery = storedNote.attachments.first(where: { $0.id == receipt.attachmentID }),
                      gallery.childAttachmentIDs == expectedOrder,
                      let children = gallery.childAttachments else { return nil }
                let childrenByID = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })
                let added = receipt.pageAttachmentIDs.compactMap { childrenByID[$0] }
                guard added.count == receipt.pageAttachmentIDs.count,
                      added.map(\.typeUTI) == receipt.pageTypeUTIs else { return nil }
                let storedPages = added.compactMap { child -> ScanPageEvidence? in
                    guard let path = child.filePath else { return nil }
                    return try? Self.scanPageEvidence(url: URL(fileURLWithPath: path), name: child.filename ?? child.id)
                }
                guard storedPages.count == receipt.sourcePages.count,
                      zip(storedPages, receipt.sourcePages).allSatisfy({ $0.visuallyMatches($1) }) else { return nil }
                return ["attachmentID": receipt.attachmentID,
                        "pageIDs": receipt.pageAttachmentIDs.joined(separator: ","),
                        "pageCount": String(expectedOrder.count), "pages": "decoded_and_matched"]
            }, mismatch: "The appended scan pages or page order did not match after readback.")
            return NativeScanResult(attachmentID: receipt.attachmentID,
                                    pageAttachmentIDs: receipt.pageAttachmentIDs,
                                    position: receipt.position, write: write)
        })
    }

    fileprivate func scanPageState(_ ref: String, attachmentID: String, pageID: String,
                                   in context: NSManagedObjectContext) throws -> NativeScanPageState {
        let target = try note(ref, in: context)
        let galleries = try fetch("ICAttachment", predicate: NSPredicate(
            format: "identifier == %@ AND note == %@ AND markedForDeletion == NO", attachmentID, target), in: context)
        guard galleries.count == 1, let gallery = galleries.first,
              value(gallery, "typeUTI") as? String == "com.apple.notes.gallery" else {
            throw NotesError("scan_not_found", "No scanned document matches the attachment ID in this note.")
        }
        let pages = try fetch("ICAttachment", predicate: NSPredicate(
            format: "identifier == %@ AND parentAttachment == %@ AND markedForDeletion == NO", pageID, gallery), in: context)
        guard pages.count == 1, let page = pages.first else {
            throw NotesError("scan_page_not_found", "No page with that ID belongs to the scanned document.")
        }
        let order: [String]
        do { order = try NCNotesRuntime.galleryPageIdentifiers(in: gallery) }
        catch { throw nativeError(error) }
        guard order.contains(pageID) else { throw NotesError("scan_page_not_found", "The page is absent from the gallery order.") }
        let filterValue = (value(page, "imageFilterType") as? NSNumber)?.intValue ?? 0
        let orientationValue = (value(page, "orientation") as? NSNumber)?.intValue ?? 0
        guard let filter = NativeScanFilter(value: filterValue),
              let orientation = NativeScanOrientation(value: orientationValue) else {
            throw NotesError("unsupported_scan_state", "Notes returned an unknown scan filter or orientation.")
        }
        func number(_ key: String) -> Double? { (value(page, key) as? NSNumber)?.doubleValue }
        let crop: ScanCrop?
        var pixelWidth: Double?
        var pixelHeight: Double?
        if let fileURL = value(page, "fileURL") as? URL,
           let size = Self.scanImagePixelSize(fileURL) {
            pixelWidth = size.width
            pixelHeight = size.height
        }
        if let blx = number("croppingQuadBottomLeftX"), let bly = number("croppingQuadBottomLeftY"),
           let brx = number("croppingQuadBottomRightX"), let bry = number("croppingQuadBottomRightY"),
           let tlx = number("croppingQuadTopLeftX"), let tly = number("croppingQuadTopLeftY"),
           let trx = number("croppingQuadTopRightX"), let tryValue = number("croppingQuadTopRightY") {
            let stored = Self.decodedScanCrop(bottomLeft: ScanPoint(x: blx, y: bly),
                                              bottomRight: ScanPoint(x: brx, y: bry),
                                              topLeft: ScanPoint(x: tlx, y: tly),
                                              topRight: ScanPoint(x: trx, y: tryValue))
            if let stored {
                guard let normalized = Self.normalizedScanCrop(stored, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
                    throw NotesError("unsupported_scan_crop", "The stored scan crop cannot be mapped to the page image dimensions.")
                }
                crop = normalized
            } else { crop = nil }
        } else { crop = nil }
        let hasMarkup = (value(page, "markupModelData") as? Data)?.isEmpty == false
        let hasEmbeddedMarkup = (value(page, "hasMarkupData") as? NSNumber)?.boolValue ?? false
        return NativeScanPageState(noteID: id(target), attachmentID: attachmentID, pageID: pageID,
                                   pageIDs: order, filter: filter, orientation: orientation,
                                   crop: crop, hasMarkup: hasMarkup, hasEmbeddedMarkup: hasEmbeddedMarkup)
    }

    static func decodedScanCrop(bottomLeft: ScanPoint, bottomRight: ScanPoint,
                                topLeft: ScanPoint, topRight: ScanPoint) -> ScanCrop? {
        let values = [bottomLeft.x, bottomLeft.y, bottomRight.x, bottomRight.y,
                      topLeft.x, topLeft.y, topRight.x, topRight.y]
        guard !values.allSatisfy({ $0 == 0 }) else { return nil }
        return ScanCrop(bottomLeft: bottomLeft, bottomRight: bottomRight,
                        topLeft: topLeft, topRight: topRight)
    }

    static func normalizedScanCrop(_ crop: ScanCrop, pixelWidth: Double?, pixelHeight: Double?) -> ScanCrop? {
        let points = [crop.bottomLeft, crop.bottomRight, crop.topLeft, crop.topRight]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }) else { return nil }
        if points.allSatisfy({ $0.x <= 1 && $0.y <= 1 }) { return crop }
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0,
              points.allSatisfy({ $0.x <= pixelWidth && $0.y <= pixelHeight }) else { return nil }
        func point(_ value: ScanPoint) -> ScanPoint {
            ScanPoint(x: value.x / pixelWidth, y: value.y / pixelHeight)
        }
        return ScanCrop(bottomLeft: point(crop.bottomLeft), bottomRight: point(crop.bottomRight),
                        topLeft: point(crop.topLeft), topRight: point(crop.topRight))
    }

    fileprivate static func scanImagePixelSize(_ url: URL) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (Double(image.width), Double(image.height))
    }

    public func scanPageState(_ ref: String, attachmentID: String, pageID: String) throws -> NativeScanPageState {
        try performRead { try scanPageState(ref, attachmentID: attachmentID, pageID: pageID, in: $0) }
    }

    fileprivate enum ScanEdit {
        case filter(NativeScanFilter)
        case orientation(NativeScanOrientation)
        case crop(ScanCrop)
        case move(Int)
    }

    fileprivate enum ScanExpectation {
        case filter(NativeScanFilter)
        case orientation(NativeScanOrientation)
        case crop(ScanCrop)
        case pageIDs([String])
    }

    fileprivate func editScan(_ ref: String, attachmentID: String, pageID: String,
                              edit: ScanEdit, expected: ScanExpectation?, allowShared: Bool) throws -> NativeWriteResult {
        do { try NCNotesRuntime.validateScanEditing() } catch { throw nativeError(error) }
        return try performWrite { context in
            let before = try scanPageState(ref, attachmentID: attachmentID, pageID: pageID, in: context)
            let expectationMatches: Bool
            switch expected {
            case .filter(let value): expectationMatches = before.filter == value
            case .orientation(let value): expectationMatches = before.orientation == value
            case .crop(let value): expectationMatches = NativeVerificationRules.sameScanCrop(before.crop, value)
            case .pageIDs(let value): expectationMatches = before.pageIDs == value
            case nil: expectationMatches = true
            }
            guard expectationMatches else {
                throw NotesError("scan_state_conflict", "The scanned document changed after its preimage was read.")
            }
            let target = try note(before.noteID, in: context)
            try guardWritable(target, allowShared: allowShared)
            guard let gallery = try fetch("ICAttachment", predicate: NSPredicate(
                format: "identifier == %@ AND note == %@ AND markedForDeletion == NO", attachmentID, target), in: context, limit: 1).first else {
                throw NotesError("scan_not_found", "The scanned document disappeared before editing.")
            }
            if case .move(let index) = edit, !(0..<before.pageIDs.count).contains(index) {
                throw NotesError("invalid_scan_page_index", "Destination index must be between 0 and \(before.pageIDs.count - 1).")
            }
            if case .crop = edit {
                guard before.orientation == .upright else {
                    throw NotesError("scan_crop_rotated_unproven", "Crop is refused for rotated pages until Notes' orientation transform is proven.")
                }
                guard !before.hasMarkup, !before.hasEmbeddedMarkup else {
                    throw NotesError("scan_crop_markup_unproven", "Crop is refused for marked-up pages until markup alignment is proven.")
                }
                guard before.crop != nil else {
                    throw NotesError("scan_crop_unavailable", "The scanned page has no restorable crop quadrilateral.")
                }
            }
            operation?.noteID = before.noteID
            operation?.attachmentID = attachmentID
            operation?.attachmentType = "com.apple.notes.gallery"
            do {
                switch edit {
                case .filter(let filter):
                    try NCNotesRuntime.applyScanFilter(Int16(filter.value), pageIdentifier: pageID, gallery: gallery)
                case .orientation(let orientation):
                    try NCNotesRuntime.setScanOrientation(orientation.value, pageIdentifier: pageID, gallery: gallery)
                case .crop(let crop):
                    try NCNotesRuntime.setScanCrop(
                        bottomLeftX: crop.bottomLeft.x, bottomLeftY: crop.bottomLeft.y,
                        bottomRightX: crop.bottomRight.x, bottomRightY: crop.bottomRight.y,
                        topLeftX: crop.topLeft.x, topLeftY: crop.topLeft.y,
                        topRightX: crop.topRight.x, topRightY: crop.topRight.y,
                        pageIdentifier: pageID, gallery: gallery)
                case .move(let index):
                    try NCNotesRuntime.moveScanPage(pageID, toIndex: UInt(index), gallery: gallery)
                }
                guard !context.hasChanges else {
                    context.rollback()
                    throw NotesError("scan_edit_not_committed", "Notes left the scanned-document edit unsaved; the change was rolled back.")
                }
                operation?.committed = true
            } catch {
                let mutationError = error
                do {
                    if context.hasChanges { context.rollback() }
                    context.refreshAllObjects()
                    let current = try scanPageState(before.noteID, attachmentID: attachmentID, pageID: pageID, in: context)
                    operation?.committed = current != before
                } catch {
                    // If readback itself fails, retain the conservative do-not-retry outcome.
                    operation?.committed = true
                }
                throw nativeError(mutationError)
            }
            context.refreshAllObjects()
            let after = try scanPageState(before.noteID, attachmentID: attachmentID, pageID: pageID, in: context)
            func cropText(_ value: ScanCrop?) -> String {
                guard let value else { return "" }
                return "\(value.bottomLeft.x),\(value.bottomLeft.y);\(value.bottomRight.x),\(value.bottomRight.y);\(value.topLeft.x),\(value.topLeft.y);\(value.topRight.x),\(value.topRight.y)"
            }
            let nativeVerified: Bool
            var native = ["attachmentID": attachmentID, "pageID": pageID,
                          "pageOrder": after.pageIDs.joined(separator: ","),
                          "filter": after.filter.rawValue, "orientation": after.orientation.rawValue,
                          "crop": cropText(after.crop)]
            switch edit {
            case .filter(let filter): nativeVerified = after.filter == filter
            case .orientation(let orientation): nativeVerified = after.orientation == orientation
            case .crop(let crop): nativeVerified = NativeVerificationRules.sameScanCrop(after.crop, crop)
            case .move(let index):
                nativeVerified = after.pageIDs.indices.contains(index) && after.pageIDs[index] == pageID
                native["index"] = String(index)
            }
            return result(before.noteID, native: native, nativeVerified: nativeVerified, sqlite: { decoded in
                guard let gallery = decoded.attachments.first(where: { $0.id == attachmentID }),
                      let children = gallery.childAttachments,
                      let page = children.first(where: { $0.id == pageID }) else { return nil }
                switch edit {
                case .filter(let filter): guard page.scanFilter == filter.value else { return nil }
                case .orientation(let orientation): guard page.scanOrientation == orientation.value else { return nil }
                case .crop(let crop):
                    let size = page.filePath.flatMap { Self.scanImagePixelSize(URL(fileURLWithPath: $0)) }
                    guard let stored = page.scanCrop,
                          let normalized = Self.normalizedScanCrop(stored, pixelWidth: size?.width, pixelHeight: size?.height),
                          NativeVerificationRules.sameScanCrop(normalized, crop) else { return nil }
                case .move(let index):
                    guard let order = gallery.childAttachmentIDs, order.indices.contains(index), order[index] == pageID else { return nil }
                }
                return ["attachmentID": attachmentID, "pageID": pageID,
                        "pageOrder": (gallery.childAttachmentIDs ?? []).joined(separator: ","),
                        "filter": String(page.scanFilter ?? -1), "orientation": String(page.scanOrientation ?? -1),
                        "crop": cropText(page.scanCrop)]
            }, mismatch: "The scanned document edit did not match after readback.")
        }
    }

    public func setScanFilter(_ ref: String, attachmentID: String, pageID: String,
                              filter: NativeScanFilter, expectedCurrent: NativeScanFilter? = nil,
                              allowShared: Bool) throws -> NativeWriteResult {
        try editScan(ref, attachmentID: attachmentID, pageID: pageID, edit: .filter(filter),
                     expected: expectedCurrent.map(ScanExpectation.filter), allowShared: allowShared)
    }

    public func setScanOrientation(_ ref: String, attachmentID: String, pageID: String,
                                   orientation: NativeScanOrientation, expectedCurrent: NativeScanOrientation? = nil,
                                   allowShared: Bool) throws -> NativeWriteResult {
        try editScan(ref, attachmentID: attachmentID, pageID: pageID, edit: .orientation(orientation),
                     expected: expectedCurrent.map(ScanExpectation.orientation), allowShared: allowShared)
    }

    public func setScanMarkupData(_ ref: String, attachmentID: String, pageID: String,
                                  data: Data, embedded: Bool = false,
                                  allowShared: Bool) throws -> NativeWriteResult {
        guard !data.isEmpty, data.count <= 50 * 1024 * 1024 else {
            throw NotesError("invalid_scan_markup", "Scan markup data must be between 1 byte and 50 MB.")
        }
        let expectedHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try performWrite { context in
            let before = try scanPageState(ref, attachmentID: attachmentID, pageID: pageID, in: context)
            let target = try note(before.noteID, in: context)
            try guardWritable(target, allowShared: allowShared)
            guard let gallery = try fetch("ICAttachment", predicate: NSPredicate(
                format: "identifier == %@ AND note == %@ AND markedForDeletion == NO", attachmentID, target
            ), in: context, limit: 1).first else {
                throw NotesError("scan_not_found", "The scanned document disappeared before editing.")
            }
            operation?.noteID = before.noteID
            operation?.attachmentID = attachmentID
            operation?.attachmentType = "com.apple.notes.gallery"
            do {
                try NCNotesRuntime.setScanMarkupData(data, pageIdentifier: pageID, gallery: gallery)
                guard !context.hasChanges else {
                    context.rollback()
                    throw NotesError("scan_edit_not_committed", "Notes left the scan markup edit unsaved; the change was rolled back.")
                }
                guard let page = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND parentAttachment == %@", pageID, gallery),
                    in: context,
                    limit: 1
                ).first else {
                    throw NotesError("scan_page_not_found", "The scan page disappeared after applying markup.")
                }
                try NCNotesRuntime.setValue(embedded, forKey: "hasMarkupData", of: page)
                try NCNotesRuntime.updateChangeCount(of: page, reason: "Changed scan markup embedding")
                try save(context, notes: [target])
                operation?.committed = true
            } catch {
                if context.hasChanges { context.rollback() }
                throw nativeError(error)
            }
            context.refreshAllObjects()
            let after = try scanPageState(before.noteID, attachmentID: attachmentID, pageID: pageID, in: context)
            return result(before.noteID,
                          native: ["attachmentID": attachmentID, "pageID": pageID,
                                   "hasMarkup": String(after.hasMarkup), "sha256": expectedHash],
                          nativeVerified: after.hasMarkup && after.hasEmbeddedMarkup == embedded,
                          sqlite: { decoded in
                guard decoded.attachments.first(where: { $0.id == attachmentID })?
                    .childAttachments?.first(where: { $0.id == pageID })?.scanHasMarkup == true,
                      let stored = try? SQLiteNotesStore(refresh: true).scanMarkupPayloads(decoded.summary.id.uuid)[pageID],
                      decoded.attachments.first(where: { $0.id == attachmentID })?
                        .childAttachments?.first(where: { $0.id == pageID })?.scanHasEmbeddedMarkup == embedded,
                      SHA256.hash(data: stored).map({ String(format: "%02x", $0) }).joined() == expectedHash else {
                    return nil
                }
                return ["attachmentID": attachmentID, "pageID": pageID,
                        "hasMarkup": "true", "embedded": String(embedded), "sha256": expectedHash]
            }, mismatch: "The scan markup did not match after readback.")
        }
    }

    private func attachmentMarkupObject(_ attachmentID: String, note: NSManagedObject,
                                        in context: NSManagedObjectContext,
                                        forMutation: Bool = false) throws -> NSManagedObject {
        let matches = try fetch(
            "ICAttachment",
            predicate: NSPredicate(format: "identifier ==[c] %@ AND note == %@ AND markedForDeletion == NO",
                                   attachmentID, note),
            in: context
        )
        guard !matches.isEmpty else {
            throw NotesError("attachment_not_found", "No live attachment matches \(attachmentID).")
        }
        guard matches.count == 1 else {
            throw NotesError("ambiguous_attachment", "More than one attachment matches \(attachmentID).")
        }
        let attachment = matches[0]
        var selectors = ["identifier", "typeUTI", "markupModelData", "hasMarkupData"]
        if forMutation {
            selectors += ["setMarkupModelData:", "setHasMarkupData:", "updateChangeCountWithReason:"]
        }
        try require(selectors, of: attachment)
        let type = value(attachment, "typeUTI") as? String ?? ""
        guard AttachmentMarkupPolicy.supports(type) else {
            throw NotesError("markup_unsupported", "Editable attachment markup is limited to images and PDFs.")
        }
        return attachment
    }

    private func attachmentMarkupExport(_ ref: String, attachmentID: String,
                                        in context: NSManagedObjectContext) throws -> NativeAttachmentMarkupExport {
        let note = try note(ref, in: context)
        let attachment = try attachmentMarkupObject(attachmentID, note: note, in: context)
        let data = value(attachment, "markupModelData") as? Data ?? Data()
        guard data.count <= FrozenAttachmentMarkup.maximumBytes else {
            throw NotesError("attachment_markup_too_large", "Attachment markup is limited to 50 MB.")
        }
        let hash = data.isEmpty ? nil : SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let metadata = NativeAttachmentMarkupMetadata(
            noteID: id(note), attachmentID: id(attachment),
            typeUTI: value(attachment, "typeUTI") as? String ?? "",
            hasMarkup: !data.isEmpty, byteCount: data.count, sha256: hash,
            embedded: (value(attachment, "hasMarkupData") as? NSNumber)?.boolValue ?? false,
            recognized: !data.isEmpty && FrozenAttachmentMarkup.isKnownArchive(data)
        )
        return NativeAttachmentMarkupExport(metadata: metadata, data: data)
    }

    public func attachmentMarkupMetadata(_ ref: String, attachmentID: String) throws -> NativeAttachmentMarkupMetadata {
        try performRead { try attachmentMarkupExport(ref, attachmentID: attachmentID, in: $0).metadata }
    }

    public func attachmentMarkupData(_ ref: String, attachmentID: String) throws -> NativeAttachmentMarkupExport {
        let value = try performRead { try attachmentMarkupExport(ref, attachmentID: attachmentID, in: $0) }
        guard value.metadata.hasMarkup else {
            throw NotesError("attachment_markup_not_found", "The attachment has no editable markup payload.")
        }
        return value
    }

    private func mutateAttachmentMarkup(_ ref: String, attachmentID: String,
                                        payload: FrozenAttachmentMarkup?, embedded: Bool,
                                        allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
            let target = try note(ref, in: context)
            try guardWritable(target, allowShared: allowShared)
            let attachment = try attachmentMarkupObject(attachmentID, note: target, in: context, forMutation: true)
            let canonicalAttachmentID = id(attachment)
            operation?.noteID = id(target)
            operation?.attachmentID = canonicalAttachmentID
            operation?.attachmentType = value(attachment, "typeUTI") as? String
            do {
                try NCNotesRuntime.setValue(payload?.data, forKey: "markupModelData", of: attachment)
                try NCNotesRuntime.setValue(payload == nil ? false : embedded, forKey: "hasMarkupData", of: attachment)
                try NCNotesRuntime.updateChangeCount(of: attachment,
                                                     reason: payload == nil ? "Cleared editable markup" : "Changed editable markup")
                try save(context, notes: [target])
            } catch {
                context.rollback()
                throw nativeError(error)
            }
            let fresh = try self.note(id(target), in: context)
            let storedAttachment = try attachmentMarkupObject(canonicalAttachmentID, note: fresh, in: context)
            let stored = value(storedAttachment, "markupModelData") as? Data
            let storedEmbedded = (value(storedAttachment, "hasMarkupData") as? NSNumber)?.boolValue ?? false
            let storedHash = stored.flatMap { data in
                data.isEmpty ? nil : SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            let expectedHash = payload?.sha256
            let cleared = stored?.isEmpty != false && !storedEmbedded
            let native = ["attachmentID": id(storedAttachment),
                          "sha256": storedHash ?? "", "embedded": String(storedEmbedded),
                          "hasMarkup": String(stored?.isEmpty == false)]
            return result(
                id(target), native: native,
                nativeVerified: payload == nil ? cleared : storedHash == expectedHash && storedEmbedded == embedded,
                sqlite: { decoded in
                    let actual = decoded.attachments.first { $0.id.caseInsensitiveCompare(canonicalAttachmentID) == .orderedSame }
                    let sqlitePayload = try? SQLiteNotesStore(refresh: true)
                        .scanMarkupPayloads(decoded.summary.id.uuid)[canonicalAttachmentID]
                    if payload == nil {
                        guard let actual,
                              (actual.markupDataBytes ?? 0) == 0,
                              actual.hasEmbeddedMarkup != true,
                              sqlitePayload == nil else { return nil }
                        return ["attachmentID": canonicalAttachmentID, "sha256": "", "embedded": "false", "hasMarkup": "false"]
                    }
                    guard actual?.markupDataBytes == payload?.byteCount,
                          actual?.hasEmbeddedMarkup == embedded,
                          let sqlitePayload else { return nil }
                    let hash = SHA256.hash(data: sqlitePayload).map { String(format: "%02x", $0) }.joined()
                    return hash == expectedHash
                        ? ["attachmentID": canonicalAttachmentID, "sha256": hash,
                           "embedded": String(embedded), "hasMarkup": "true"] : nil
                },
                mismatch: payload == nil
                    ? "The editable attachment markup remained after clear readback."
                    : "The editable attachment markup did not match after readback."
            )
        }
    }

    public func setAttachmentMarkupData(_ ref: String, attachmentID: String, data: Data,
                                        embedded: Bool, allowShared: Bool) throws -> NativeWriteResult {
        try setAttachmentMarkup(ref, attachmentID: attachmentID,
                                payload: FrozenAttachmentMarkup(data: data), embedded: embedded,
                                allowShared: allowShared)
    }

    public func setAttachmentMarkup(_ ref: String, attachmentID: String,
                                    payload: FrozenAttachmentMarkup, embedded: Bool,
                                    allowShared: Bool) throws -> NativeWriteResult {
        try mutateAttachmentMarkup(ref, attachmentID: attachmentID, payload: payload,
                                   embedded: embedded, allowShared: allowShared)
    }

    public func copyAttachmentMarkup(_ ref: String, attachmentID: String,
                                     sourceRef: String, sourceAttachmentID: String,
                                     allowShared: Bool) throws -> NativeWriteResult {
        let source = try attachmentMarkupData(sourceRef, attachmentID: sourceAttachmentID)
        let payload = try FrozenAttachmentMarkup(data: source.data)
        return try mutateAttachmentMarkup(ref, attachmentID: attachmentID, payload: payload,
                                          embedded: source.metadata.embedded, allowShared: allowShared)
    }

    public func clearAttachmentMarkup(_ ref: String, attachmentID: String,
                                      allowShared: Bool) throws -> NativeWriteResult {
        try mutateAttachmentMarkup(ref, attachmentID: attachmentID, payload: nil,
                                   embedded: false, allowShared: allowShared)
    }

    public func setScanCrop(_ ref: String, attachmentID: String, pageID: String,
                            crop: ScanCrop, expectedCurrent: ScanCrop? = nil,
                            allowShared: Bool) throws -> NativeWriteResult {
        try editScan(ref, attachmentID: attachmentID, pageID: pageID, edit: .crop(crop),
                     expected: expectedCurrent.map(ScanExpectation.crop), allowShared: allowShared)
    }

    public func moveScanPage(_ ref: String, attachmentID: String, pageID: String,
                             toIndex: Int, expectedPageIDs: [String]? = nil,
                             allowShared: Bool) throws -> NativeWriteResult {
        try editScan(ref, attachmentID: attachmentID, pageID: pageID, edit: .move(toIndex),
                     expected: expectedPageIDs.map(ScanExpectation.pageIDs), allowShared: allowShared)
    }

    public func deleteScanPage(_ ref: String, attachmentID: String, pageID: String,
                               expectedPageIDs: [String]? = nil,
                               allowShared: Bool) throws -> NativeWriteResult {
        do { try NCNotesRuntime.validateScanEditing() } catch { throw nativeError(error) }
        return try performWrite { context in
            let before = try scanPageState(ref, attachmentID: attachmentID, pageID: pageID, in: context)
            if let expectedPageIDs, before.pageIDs != expectedPageIDs {
                throw NotesError("scan_state_conflict", "The scanned document changed after its preimage was read.")
            }
            guard before.pageIDs.count > 1 else {
                throw NotesError("scan_last_page_refused", "Refusing to delete the only page in a scanned document.")
            }
            let target = try note(before.noteID, in: context)
            try guardWritable(target, allowShared: allowShared)
            guard let gallery = try fetch("ICAttachment", predicate: NSPredicate(
                format: "identifier == %@ AND note == %@ AND markedForDeletion == NO", attachmentID, target), in: context, limit: 1).first else {
                throw NotesError("scan_not_found", "The scanned document disappeared before editing.")
            }
            operation?.noteID = before.noteID
            operation?.attachmentID = attachmentID
            operation?.attachmentType = "com.apple.notes.gallery"
            do {
                try NCNotesRuntime.deleteScanPage(pageID, gallery: gallery)
                guard !context.hasChanges else {
                    context.rollback()
                    throw NotesError("scan_edit_not_committed", "Notes left the page deletion unsaved; the change was rolled back.")
                }
                operation?.committed = true
            } catch {
                let mutationError = error
                do {
                    if context.hasChanges { context.rollback() }
                    context.refreshAllObjects()
                    let order = try NCNotesRuntime.galleryPageIdentifiers(in: gallery)
                    operation?.committed = order != before.pageIDs
                } catch {
                    operation?.committed = true
                }
                throw nativeError(mutationError)
            }
            context.refreshAllObjects()
            let order = try NCNotesRuntime.galleryPageIdentifiers(in: gallery)
            let expectedOrder = before.pageIDs.filter { $0 != pageID }
            return result(before.noteID,
                          native: ["attachmentID": attachmentID, "pageID": pageID,
                                   "pageOrder": order.joined(separator: ",")],
                          nativeVerified: order == expectedOrder,
                          sqlite: { decoded in
                guard let decodedGallery = decoded.attachments.first(where: { $0.id == attachmentID }),
                      decodedGallery.childAttachmentIDs == expectedOrder else { return nil }
                return ["attachmentID": attachmentID, "pageID": pageID,
                        "pageOrder": expectedOrder.joined(separator: ",")]
            }, mismatch: "The scanned document page was not deleted after readback.")
        }
    }

    public func restoreScanPage(_ ref: String, attachmentID: String, pageID: String, toIndex: Int,
                                expectedPageIDs: [String]? = nil,
                                allowShared: Bool) throws -> NativeWriteResult {
        do { try NCNotesRuntime.validateScanEditing() } catch { throw nativeError(error) }
        return try performWrite { context in
            let target = try note(ref, in: context)
            try guardWritable(target, allowShared: allowShared)
            guard let gallery = try fetch("ICAttachment", predicate: NSPredicate(
                format: "identifier == %@ AND note == %@ AND markedForDeletion == NO", attachmentID, target), in: context, limit: 1).first else {
                throw NotesError("scan_not_found", "The scanned document disappeared before restoring its page.")
            }
            let order = try NCNotesRuntime.galleryPageIdentifiers(in: gallery)
            if let expectedPageIDs, order != expectedPageIDs {
                throw NotesError("scan_state_conflict", "The scanned document changed after its preimage was read.")
            }
            guard (0...order.count).contains(toIndex) else {
                throw NotesError("invalid_scan_page_index", "Restore index must be between 0 and \(order.count).")
            }
            let candidates = try fetch("ICAttachment", predicate: NSPredicate(
                format: "identifier == %@ AND note == %@", pageID, target), in: context)
            guard candidates.count == 1, let page = candidates.first,
                  value(page, "parentAttachment") == nil ||
                    (value(page, "markedForDeletion") as? NSNumber)?.boolValue == true else {
                throw NotesError("scan_deleted_page_not_found", "The deleted scanned-document page is no longer restorable.")
            }
            let noteID = id(target)
            operation?.noteID = noteID
            operation?.attachmentID = attachmentID
            operation?.attachmentType = "com.apple.notes.gallery"
            do {
                try NCNotesRuntime.undeleteScanPage(page, pageIdentifier: pageID,
                                                    toIndex: UInt(toIndex), gallery: gallery)
                guard !context.hasChanges else {
                    context.rollback()
                    throw NotesError("scan_edit_not_committed", "Notes left the page restore unsaved; the change was rolled back.")
                }
                operation?.committed = true
            } catch {
                let mutationError = error
                do {
                    if context.hasChanges { context.rollback() }
                    context.refreshAllObjects()
                    let current = try NCNotesRuntime.galleryPageIdentifiers(in: gallery)
                    operation?.committed = current != order
                } catch {
                    operation?.committed = true
                }
                throw nativeError(mutationError)
            }
            context.refreshAllObjects()
            guard let refreshedGallery = try fetch("ICAttachment", predicate: NSPredicate(
                format: "identifier == %@ AND note == %@ AND markedForDeletion == NO", attachmentID, target),
                in: context, limit: 1).first else {
                throw NotesError("scan_not_found", "The scanned document disappeared after restoring its page.")
            }
            var restoredOrder = try NCNotesRuntime.galleryPageIdentifiers(in: refreshedGallery)
            guard let restoredIndex = restoredOrder.firstIndex(of: pageID) else {
                let stillDeleted = try fetch("ICAttachment", predicate: NSPredicate(
                    format: "identifier == %@ AND note == %@ AND markedForDeletion == YES", pageID, target),
                    in: context, limit: 1).first != nil
                if stillDeleted { operation?.committed = false }
                throw NotesError("scan_restore_failed", "Notes did not restore the scanned document page.")
            }
            if restoredIndex != toIndex {
                do {
                    try NCNotesRuntime.moveScanPage(pageID, toIndex: UInt(toIndex), gallery: refreshedGallery)
                    operation?.committed = true
                } catch {
                    throw nativeError(error)
                }
                context.refreshAllObjects()
                restoredOrder = try NCNotesRuntime.galleryPageIdentifiers(in: refreshedGallery)
            }
            let after = try scanPageState(noteID, attachmentID: attachmentID, pageID: pageID, in: context)
            var expectedOrder = order
            expectedOrder.insert(pageID, at: toIndex)
            return result(noteID,
                          native: ["attachmentID": attachmentID, "pageID": pageID,
                                   "pageOrder": after.pageIDs.joined(separator: ",")],
                          nativeVerified: after.pageIDs == expectedOrder,
                          sqlite: { decoded in
                guard let decodedGallery = decoded.attachments.first(where: { $0.id == attachmentID }),
                      decodedGallery.childAttachmentIDs == expectedOrder else { return nil }
                return ["attachmentID": attachmentID, "pageID": pageID,
                        "pageOrder": expectedOrder.joined(separator: ",")]
            }, mismatch: "The scanned document page was not restored at its prior position.")
        }
    }

    public func deleteScanPages(_ ref: String, attachmentID: String, pageIDs: [String],
                                expectedPageIDs: [String]? = nil,
                                allowShared: Bool) throws -> NativeWriteResult {
        guard !pageIDs.isEmpty, Set(pageIDs).count == pageIDs.count else {
            throw NotesError("invalid_scan_pages", "Provide one or more unique scanned-document page IDs.")
        }
        do { try NCNotesRuntime.validateScanEditing() } catch { throw nativeError(error) }
        return try performWrite { context in
            let target = try note(ref, in: context)
            try guardWritable(target, allowShared: allowShared)
            guard let gallery = try fetch("ICAttachment", predicate: NSPredicate(
                format: "identifier == %@ AND note == %@ AND markedForDeletion == NO", attachmentID, target),
                in: context, limit: 1).first else {
                throw NotesError("scan_not_found", "The scanned document disappeared before editing.")
            }
            let before = try NCNotesRuntime.galleryPageIdentifiers(in: gallery)
            if let expectedPageIDs, before != expectedPageIDs {
                throw NotesError("scan_state_conflict", "The scanned document changed after its preimage was read.")
            }
            guard Set(pageIDs).isSubset(of: Set(before)), before.count > pageIDs.count else {
                throw NotesError("invalid_scan_pages", "The requested pages are absent or would empty the scanned document.")
            }
            let expectedOrder = before.filter { !Set(pageIDs).contains($0) }
            operation?.noteID = id(target)
            operation?.attachmentID = attachmentID
            operation?.attachmentType = "com.apple.notes.gallery"
            do {
                try NCNotesRuntime.deleteScanPages(pageIDs, gallery: gallery)
                guard !context.hasChanges else {
                    context.rollback()
                    throw NotesError("scan_edit_not_committed", "Notes left the page deletion unsaved; the change was rolled back.")
                }
                operation?.committed = true
            } catch {
                let mutationError = error
                do {
                    if context.hasChanges { context.rollback() }
                    context.refreshAllObjects()
                    operation?.committed = try NCNotesRuntime.galleryPageIdentifiers(in: gallery) != before
                } catch {
                    operation?.committed = true
                }
                throw nativeError(mutationError)
            }
            context.refreshAllObjects()
            let order = try NCNotesRuntime.galleryPageIdentifiers(in: gallery)
            return result(id(target),
                          native: ["attachmentID": attachmentID, "pageIDs": pageIDs.joined(separator: ","),
                                   "pageOrder": order.joined(separator: ",")],
                          nativeVerified: order == expectedOrder,
                          sqlite: { decoded in
                guard let decodedGallery = decoded.attachments.first(where: { $0.id == attachmentID }),
                      decodedGallery.childAttachmentIDs == expectedOrder else { return nil }
                return ["attachmentID": attachmentID, "pageIDs": pageIDs.joined(separator: ","),
                        "pageOrder": expectedOrder.joined(separator: ",")]
            }, mismatch: "The appended scanned-document pages were not removed after readback.")
        }
    }

    fileprivate func destinationFolder(_ ref: String?, in context: NSManagedObjectContext) throws -> NSManagedObject {
        if let ref, !ref.isEmpty {
            if ref.contains(">") {
                let path = ref.split(separator: ">").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let matches = try SQLiteNotesStore(refresh: true).folders(account: nil).filter { $0.path == path }
                guard matches.count == 1 else { throw NotesError(matches.isEmpty ? "folder_not_found" : "ambiguous_folder", "Folder must resolve uniquely.") }
                return try folder(matches[0].id, in: context)
            }
            return try folder(ref, in: context)
        }
        let folderID = try NativeDestinationResolver.folderID(try SQLiteNotesStore(refresh: true).defaultLocation())
        return try folder(folderID, in: context)
    }

    private func readBackStrokes(_ attachment: NSManagedObject) throws -> [PaperStrokeRecord] {
        PaperStrokeRecord.records(try readBackDrawingCanvases(attachment).map {
            try PaperStrokeRecord.drawing($0)
        })
    }

    private func readBackDrawingCanvases(_ attachment: NSManagedObject) throws -> [[PaperStrokeRecord]] {
        try NCNotesRuntime.systemPaperDrawings(for: attachment).map { value in
            guard let drawing = value as? PKDrawing else { throw NotesError("drawing_decode_failed", "Notes returned an unknown Paper drawing object.") }
            return PaperStrokeRecord.records([drawing])
        }
    }

    private func legacyDrawingPayload(_ attachment: NSManagedObject, identifier: String) throws -> Data {
        if let executable = legacyDrawingHelperExecutable() {
            return try freshLegacyDrawingPayload(identifier: identifier, executable: executable)
        }
        return try NCNotesRuntime.legacyDrawingStrokes(for: attachment)
    }

    private func legacyDrawingHelperExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let supplied = environment["NOTESCLI_LEGACY_HELPER"], !supplied.isEmpty {
            let value = URL(fileURLWithPath: supplied)
            return FileManager.default.isExecutableFile(atPath: value.path) ? value : nil
        }
        guard let current = Bundle.main.executableURL,
              ["notescli", "notectl"].contains(current.lastPathComponent),
              FileManager.default.isExecutableFile(atPath: current.path) else { return nil }
        return current
    }

    private func freshLegacyDrawingPayload(identifier: String, executable: URL) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-legacy-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("strokes.json")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["__legacy-drawing-read", identifier, output.path]
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["NOTESCLI_CAPABILITY_HOST"] = "direct"
        childEnvironment.removeValue(forKey: "NOTESCLI_HOST_ACTIVE")
        process.environment = childEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            if finished.wait(timeout: .now() + 20) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + 1)
                }
                throw NotesError("drawing_decode_failed", "The isolated Notes drawing reader timed out.")
            }
        } catch {
            if let error = error as? NotesError { throw error }
            throw NotesError("drawing_decode_failed", "The isolated Notes drawing reader could not start.")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue > 0, byteCount.intValue <= 256 * 1024 * 1024 else {
            throw NotesError("drawing_decode_failed", "The isolated Notes drawing reader returned no safe stroke data.")
        }
        return try Data(contentsOf: output, options: [.mappedIfSafe])
    }

    private func readBackLegacyStrokes(_ attachment: NSManagedObject, identifier: String) throws -> [LegacyDrawingStrokeRecord] {
        let data = try legacyDrawingPayload(attachment, identifier: identifier)
        let records = try JSONDecoder().decode([LegacyDrawingStrokeRecord].self, from: data)
        try LegacyDrawingStrokeRecord.validate(records)
        return records
    }

    public func createDrawingNote(title: String, folder folderRef: String?, drawing: PKDrawing,
                                  allowShared: Bool) throws -> NativeCreateResult {
        let expectedStrokes = PaperStrokeRecord.records([drawing])
        guard !expectedStrokes.isEmpty else { throw NotesError("invalid_drawing", "The drawing has no strokes.") }
        var createdAttachmentID = ""
        let write = try performWrite { context in
            let destination = try destinationFolder(folderRef, in: context)
            try guardWritableFolder(destination, allowShared: allowShared)
            var noteID = "", attachmentID = "", type = "com.apple.notes.paper", createdNoteID: String?
            do {
                let note = try NCNotesRuntime.newNote(in: destination)
                createdNoteID = id(note)
                try NCNotesRuntime.setValue(title, forKey: "title", of: note)
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["insert"])
                let built = try MarkdownNativeWriter(owner: self).attributed(markdown: "# " + title, note: note,
                    context: context, editor: editor, existing: [:]).0
                var kind: NSString?
                attachmentID = try NCNotesRuntime.addSystemPaperDrawing(drawing as AnyObject, to: note, type: &kind)
                try TestFault.check("after_attachment")
                createdAttachmentID = attachmentID
                type = kind as String? ?? type
                let marker = try NCNotesRuntime.attachmentMarker(id: attachmentID, type: type)
                if built.length > 0 { built.append(NSAttributedString(string: "\n")) }
                built.append(NSAttributedString(string: "\u{fffc}", attributes: [.init("NSAttachment"): marker]))
                try editor.begin(["insert"])
                try editor.insert(built, at: 0)
                try editor.finish()
                operation?.attachmentID = attachmentID
                operation?.attachmentType = type
                operation?.attachmentPosition = max(0, built.length - 1)
                try TestFault.check("before_save")
                try save(context, notes: [note])
                noteID = id(note)
            } catch {
                createdAttachmentID = ""
                return try rollBackCreatedNote(createdNoteID, after: error, in: context)
            }
            let fresh = try self.note(noteID, in: context)
            let placements = attachmentMarkers(try body(fresh)).filter { $0.2 == attachmentID }.count
            let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, fresh), in: context, limit: 1).first
            let decodedStrokes = try attachment.map(readBackStrokes) ?? []
            let decodedStrokeCount = decodedStrokes.count
            let strokeMismatch = PaperStrokeRecord.mismatch(expected: expectedStrokes, actual: decodedStrokes)
            return result(noteID, native: ["title": title, "attachmentID": attachmentID, "typeUTI": type,
                                           "placements": String(placements), "strokeCount": String(decodedStrokeCount),
                                           "strokes": strokeMismatch ?? "match"],
                          nativeVerified: placements == 1 && strokeMismatch == nil,
                          sqlite: { note in
                guard note.summary.title == title,
                      note.attachments.filter({ $0.id == attachmentID && $0.typeUTI == type }).count == 1 else { return nil }
                return ["title": title, "attachmentID": attachmentID, "typeUTI": type,
                        "placements": "1", "strokeCount": String(decodedStrokeCount)]
            }, mismatch: "The created note or its editable Paper drawing did not match.")
        }
        return NativeCreateResult(attachmentIDs: createdAttachmentID.isEmpty ? [] : [createdAttachmentID],
                                  attachmentSHA256: [:], write: write)
    }

    private static func flattenAttachments(_ attachments: [Attachment]) -> [Attachment] {
        attachments.flatMap { [$0] + flattenAttachments($0.childAttachments ?? []) }
    }

    private func handwritingResult(_ payload: [String: Any], attachmentID: String,
                                   persisted: Bool, write: NativeWriteResult? = nil) throws -> NativeHandwritingResult {
        guard let text = payload["text"] as? String,
              let raw = payload["raw"] as? String,
              let model = payload["model"] as? String,
              let score = payload["score"] as? NSNumber,
              let strokes = payload["strokes"] as? NSNumber,
              let points = payload["points"] as? NSNumber else {
            throw NotesError("handwriting_recognition_failed", "Apple Notes returned an invalid handwriting result.")
        }
        return NativeHandwritingResult(
            attachmentID: attachmentID, text: text, rawText: raw, modelText: model,
            score: score.doubleValue, strokeCount: strokes.intValue, pointCount: points.intValue,
            persisted: persisted, write: write
        )
    }

    public func recognizeHandwriting(_ ref: String, attachmentID: String,
                                     locale: String = "en-US") throws -> NativeHandwritingResult {
        try performRead { context in
            let note = try note(ref, in: context)
            guard let attachment = try fetch(
                "ICAttachment",
                predicate: NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, note),
                in: context,
                limit: 1
            ).first else {
                throw NotesError("attachment_not_found", "No attachment matches \(attachmentID) in this note.")
            }
            do {
                let payload = try NCNotesRuntime.recognizeHandwriting(in: attachment, locale: locale)
                return try handwritingResult(payload, attachmentID: attachmentID, persisted: false)
            } catch let error as NotesError {
                throw error
            } catch {
                throw nativeError(error)
            }
        }
    }

    public func recognizeAndPersistHandwriting(_ ref: String, attachmentID: String,
                                               locale: String = "en-US",
                                               allowShared: Bool) throws -> NativeHandwritingResult {
        var recognition: NativeHandwritingResult?
        let write = try performWrite { context in
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note)
            guard let attachment = try fetch(
                "ICAttachment",
                predicate: NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, note),
                in: context,
                limit: 1
            ).first else {
                throw NotesError("attachment_not_found", "No attachment matches \(attachmentID) in this note.")
            }
            do {
                let payload = try NCNotesRuntime.recognizeHandwriting(in: attachment, locale: locale)
                let value = try handwritingResult(payload, attachmentID: attachmentID, persisted: true)
                guard !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NotesError("handwriting_not_recognized", "Apple Notes did not recognize text in this drawing.")
                }
                _ = try NCNotesRuntime.setHandwritingSummary(value.text, attachment: attachment)
                try save(context, notes: [note])
                recognition = value
            } catch let error as NotesError {
                context.rollback()
                throw error
            } catch {
                context.rollback()
                throw nativeError(error)
            }
            let fresh = try self.note(id(note), in: context)
            guard let freshAttachment = try fetch(
                "ICAttachment",
                predicate: NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, fresh),
                in: context,
                limit: 1
            ).first, let value = recognition else {
                throw NotesError("handwriting_persist_failed", "The handwriting attachment disappeared after save.")
            }
            let nativeSummary = self.value(freshAttachment, "handwritingSummary") as? String
            return result(id(note),
                          native: ["attachmentID": attachmentID, "handwriting": nativeSummary ?? ""],
                          nativeVerified: nativeSummary == value.text,
                          sqlite: { decoded in
                guard let stored = Self.flattenAttachments(decoded.attachments).first(where: { $0.id == attachmentID }),
                      stored.handwritingText == value.text else { return nil }
                return ["attachmentID": attachmentID, "handwriting": value.text]
            }, mismatch: "The recognized handwriting was not persisted exactly.")
        }
        guard var recognition else {
            throw NotesError("handwriting_recognition_failed", "Apple Notes returned no handwriting result.")
        }
        recognition.write = write
        return recognition
    }

    public func setHandwritingSummary(_ ref: String, attachmentID: String, summary: String?,
                                      allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note)
            guard let attachment = try fetch(
                "ICAttachment",
                predicate: NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, note),
                in: context,
                limit: 1
            ).first else {
                throw NotesError("attachment_not_found", "No attachment matches \(attachmentID) in this note.")
            }
            do {
                _ = try NCNotesRuntime.setHandwritingSummary(summary, attachment: attachment)
                try save(context, notes: [note])
            } catch {
                context.rollback()
                throw (error as? NotesError) ?? nativeError(error)
            }
            let expected = summary ?? ""
            let fresh = try self.note(id(note), in: context)
            let freshAttachment = try fetch(
                "ICAttachment",
                predicate: NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, fresh),
                in: context,
                limit: 1
            ).first
            let nativeSummary = freshAttachment.flatMap { self.value($0, "handwritingSummary") as? String } ?? ""
            return result(id(note), native: ["attachmentID": attachmentID, "handwriting": nativeSummary],
                          nativeVerified: nativeSummary == expected,
                          sqlite: { decoded in
                guard let stored = Self.flattenAttachments(decoded.attachments).first(where: { $0.id == attachmentID }),
                      (stored.handwritingText ?? "") == expected else { return nil }
                return ["attachmentID": attachmentID, "handwriting": stored.handwritingText ?? ""]
            }, mismatch: "The handwriting summary was not updated exactly.")
        }
    }

    private enum ImageMetadataField {
        case ocr, labels

        var summaryKey: String {
            switch self { case .ocr: "ocrSummary"; case .labels: "imageClassificationSummary" }
        }
        var versionKey: String {
            switch self { case .ocr: "ocrSummaryVersion"; case .labels: "imageClassificationSummaryVersion" }
        }
        var evidenceKey: String {
            switch self { case .ocr: "ocr"; case .labels: "imageLabels" }
        }
        var mismatch: String {
            switch self {
            case .ocr: "The OCR summary or its version was not updated exactly."
            case .labels: "The image-classification summary or its version was not updated exactly."
            }
        }
    }

    public func setOCRSummary(_ ref: String, attachmentID: String, summary: String?,
                              allowShared: Bool) throws -> NativeWriteResult {
        try setImageMetadataSummary(ref, attachmentID: attachmentID, summary: summary,
                                    field: .ocr, allowShared: allowShared)
    }

    public func setImageClassificationSummary(_ ref: String, attachmentID: String, summary: String?,
                                               allowShared: Bool) throws -> NativeWriteResult {
        try setImageMetadataSummary(ref, attachmentID: attachmentID, summary: summary,
                                    field: .labels, allowShared: allowShared)
    }

    private func setImageMetadataSummary(_ ref: String, attachmentID: String, summary: String?,
                                         field: ImageMetadataField, allowShared: Bool) throws -> NativeWriteResult {
        try performWriteWithFreshReadback(transaction: { context in
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note)
            guard let attachment = try fetch(
                "ICAttachment",
                predicate: NSPredicate(format: "identifier == %@ AND note == %@ AND markedForDeletion == NO", attachmentID, note),
                in: context,
                limit: 1
            ).first else {
                throw NotesError("attachment_not_found", "No attachment matches \(attachmentID) in this note.")
            }
            try NativeImageMetadata.requireActive(
                markedForDeletion: (value(attachment, "markedForDeletion") as? NSNumber)?.boolValue == true,
                attachmentID: attachmentID
            )
            let typeUTI = value(attachment, "typeUTI") as? String ?? ""
            try NativeImageMetadata.requireImage(typeUTI: typeUTI, attachmentID: attachmentID)
            do {
                switch field {
                case .ocr: _ = try NCNotesRuntime.setOCRSummary(summary, version: summary == nil ? 0 : 1, attachment: attachment)
                case .labels: _ = try NCNotesRuntime.setImageClassificationSummary(summary, version: summary == nil ? 0 : 4, attachment: attachment)
                }
                try save(context, notes: [note])
            } catch {
                context.rollback()
                throw (error as? NotesError) ?? nativeError(error)
            }
            return id(note)
        }, readback: { context, noteID in
            let fresh = try note(noteID, in: context)
            guard let attachment = try fetch(
                "ICAttachment",
                predicate: NSPredicate(format: "identifier == %@ AND note == %@ AND markedForDeletion == NO", attachmentID, fresh),
                in: context,
                limit: 1
            ).first else {
                throw NotesError("image_metadata_readback_failed", "The image attachment disappeared after save.")
            }
            let nativeSummary = value(attachment, field.summaryKey) as? String
            let nativeVersion = (value(attachment, field.versionKey) as? NSNumber)?.intValue ?? 0
            let nativeMatches = nativeSummary == summary &&
                NativeImageMetadata.versionMatches(summary: summary, version: nativeVersion)
            return result(noteID,
                          native: ["attachmentID": attachmentID,
                                   field.evidenceKey: nativeSummary ?? "",
                                   "version": String(nativeVersion)],
                          nativeVerified: nativeMatches,
                          sqlite: { decoded in
                guard let stored = Self.flattenAttachments(decoded.attachments).first(where: { $0.id == attachmentID }) else {
                    return nil
                }
                let sqliteSummary: String?
                let sqliteVersion: Int
                switch field {
                case .ocr:
                    sqliteSummary = stored.ocrText
                    sqliteVersion = stored.ocrSummaryVersion ?? 0
                case .labels:
                    sqliteSummary = stored.imageClassification
                    sqliteVersion = stored.imageClassificationSummaryVersion ?? 0
                }
                guard sqliteSummary == summary, sqliteVersion == nativeVersion,
                      NativeImageMetadata.versionMatches(summary: summary, version: sqliteVersion) else { return nil }
                return ["attachmentID": attachmentID, field.evidenceKey: sqliteSummary ?? "",
                        "version": String(sqliteVersion)]
            }, mismatch: field.mismatch)
        })
    }

    public func regenerateFallbackPDF(_ ref: String, attachmentID: String,
                                      allowShared: Bool) throws -> NativeFallbackPDFResult {
        var byteCount = 0
        var path = ""
        let write = try performWrite { context in
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note)
            guard let attachment = try fetch(
                "ICAttachment",
                predicate: NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, note),
                in: context,
                limit: 1
            ).first else {
                throw NotesError("attachment_not_found", "No attachment matches \(attachmentID) in this note.")
            }
            do {
                let payload = try NCNotesRuntime.regenerateFallbackPDF(for: attachment)
                guard let bytes = payload["byteCount"] as? NSNumber,
                      let output = payload["url"] as? String,
                      bytes.intValue > 0, !output.isEmpty else {
                    throw NotesError("fallback_pdf_failed", "Apple Notes returned no fallback PDF evidence.")
                }
                byteCount = bytes.intValue
                path = output
                try save(context, notes: [note])
            } catch let error as NotesError {
                context.rollback()
                throw error
            } catch {
                context.rollback()
                throw nativeError(error)
            }
            let isPDF = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe).prefix(5)) == Data("%PDF-".utf8)
            return result(id(note), native: ["attachmentID": attachmentID, "byteCount": String(byteCount), "path": path],
                          nativeVerified: byteCount > 0 && FileManager.default.fileExists(atPath: path) && isPDF,
                          sqlite: { decoded in
                guard Self.flattenAttachments(decoded.attachments).contains(where: { $0.id == attachmentID }) else { return nil }
                return ["attachmentID": attachmentID, "byteCount": String(byteCount)]
            }, mismatch: "Apple Notes did not retain a readable fallback PDF.")
        }
        return NativeFallbackPDFResult(attachmentID: attachmentID, byteCount: byteCount, path: path, write: write)
    }

    public func insertPaperDocument(_ ref: String, frozen: FrozenAttachmentInput, subtype: String,
                                    position: Int?, allowShared: Bool) throws -> NativeAttachmentResult {
        let normalized = subtype.lowercased()
        guard normalized == "pdf" || normalized == "scan" else {
            throw NotesError("invalid_paper_subtype", "Paper document subtype must be pdf or scan.")
        }
        return try performAttachmentWrite { context in
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note)
            var attachmentID = "", kind: NSString?, at = 0
            do {
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["insert"])
                at = position ?? editor.original.length
                let requestedID = UUID().uuidString.lowercased()
                attachmentID = try NCNotesRuntime.addPaperDocument(
                    at: frozen.url,
                    subtype: normalized,
                    identifier: requestedID,
                    to: note,
                    type: &kind
                )
                guard attachmentID.caseInsensitiveCompare(requestedID) == .orderedSame else {
                    throw NotesError("paper_identifier_mismatch", "Notes returned a different Paper identifier.")
                }
                let type = kind as String? ?? ""
                operation?.attachmentID = attachmentID
                operation?.attachmentType = type
                operation?.attachmentPosition = at
                try insertMarker(editor, original: editor.original, id: attachmentID, type: type, position: position)
                try editor.finish()
                try save(context, notes: [note])
            } catch {
                context.rollback()
                throw (error as? NotesError) ?? nativeError(error)
            }
            let type = kind as String? ?? ""
            let expectedType = normalized == "pdf" ? "com.apple.paper.doc.pdf" : "com.apple.paper.doc.scan"
            let fresh = try self.note(id(note), in: context)
            let placements = attachmentMarkers(try body(fresh)).filter { $0.2 == attachmentID && $0.3 == type }.count
            let exists = try fetch(
                "ICAttachment",
                predicate: NSPredicate(format: "identifier == %@ AND note == %@ AND typeUTI == %@", attachmentID, fresh, type),
                in: context,
                limit: 1
            ).count == 1
            let write = result(id(note),
                               native: ["attachmentID": attachmentID, "typeUTI": type, "placements": String(placements)],
                               nativeVerified: exists && placements == 1 && type == expectedType,
                               sqlite: { decoded in
                guard Self.flattenAttachments(decoded.attachments).contains(where: {
                    $0.id == attachmentID && $0.typeUTI == expectedType
                }) else { return nil }
                return ["attachmentID": attachmentID, "typeUTI": expectedType, "placements": "1"]
            }, mismatch: "The native Paper document did not match after readback.")
            return NativeAttachmentResult(attachmentID: attachmentID, typeUTI: type, position: at,
                                          sourceSHA256: frozen.sha256, storedSHA256: nil, write: write)
        }
    }

    public func paperDrawings(_ ref: String, attachmentID: String? = nil) throws -> [NativePaperAttachment] {
        try performRead { context in
            let note = try note(ref, in: context)
            let markers = attachmentMarkers(try body(note)).filter { marker in
                let lower = marker.3.lowercased()
                return (attachmentID == nil || marker.2.caseInsensitiveCompare(attachmentID!) == .orderedSame) &&
                    (lower.contains("paper") || lower.contains("drawing"))
            }
            guard !markers.isEmpty else { throw NotesError("drawing_not_found", "The note has no matching editable drawing.") }
            var result: [NativePaperAttachment] = []
            for marker in markers {
                guard let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@ AND note == %@", marker.2, note), in: context, limit: 1).first else { continue }
                let drawings = try NCNotesRuntime.systemPaperDrawings(for: attachment).map { value -> PKDrawing in
                    guard let drawing = value as? PKDrawing else { throw NotesError("drawing_decode_failed", "Notes returned an unknown Paper drawing object.") }
                    return drawing
                }
                if !drawings.isEmpty {
                    result.append(NativePaperAttachment(attachmentID: marker.2, typeUTI: marker.3, drawings: drawings))
                }
            }
            guard !result.isEmpty else { throw NotesError("drawing_unavailable", "Notes returned no editable stroke data for the drawing.") }
            return result
        }
    }

    public func snapshotDrawingPayloads(_ ref: String) throws -> [String: Data] {
        try performRead { context in
            let note = try note(ref, in: context)
            let markers = attachmentMarkers(try body(note)).filter {
                let lower = $0.3.lowercased()
                return (lower.contains("paper") && !lower.contains("paper.doc")) ||
                    lower.contains("drawing") || lower.contains("sketch")
            }
            var payloads: [String: Data] = [:]
            for marker in markers {
                guard let attachment = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", marker.2, note),
                    in: context,
                    limit: 1
                ).first else {
                    throw NotesError("drawing_unavailable", "Drawing \(marker.2) has no native attachment row.")
                }
                let lowerType = marker.3.lowercased()
                if lowerType.contains("sketch") || (lowerType.contains("drawing") && !lowerType.contains("paper")) {
                    let data = try legacyDrawingPayload(attachment, identifier: marker.2)
                    let records = try JSONDecoder().decode([LegacyDrawingStrokeRecord].self, from: data)
                    try LegacyDrawingStrokeRecord.validate(records)
                    payloads[marker.2] = data
                    continue
                }
                let drawings = try NCNotesRuntime.systemPaperDrawings(for: attachment).map { value -> PKDrawing in
                    guard let drawing = value as? PKDrawing else {
                        throw NotesError("drawing_decode_failed", "Notes returned an unknown Paper drawing object.")
                    }
                    return drawing
                }
                guard !drawings.isEmpty else {
                    throw NotesError("drawing_snapshot_failed", "Drawing \(marker.2) contains no editable canvases.")
                }
                let data = drawings.count == 1
                    ? try JSONEncoder().encode(PaperStrokeRecord.records(drawings))
                    : try JSONEncoder().encode(drawings.map { PaperStrokeRecord.records([$0]) })
                guard !data.isEmpty else {
                    throw NotesError("drawing_snapshot_failed", "Drawing \(marker.2) produced an empty PencilKit archive.")
                }
                payloads[marker.2] = data
            }
            return payloads
        }
    }

    public func snapshotPaperBundlePayloads(_ ref: String) throws -> [String: Data] {
        try performRead { context in
            let note = try note(ref, in: context)
            let markers = attachmentMarkers(try body(note)).filter { $0.3.lowercased().contains("paper") }
            var payloads: [String: Data] = [:]
            for marker in markers {
                guard let attachment = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", marker.2, note),
                    in: context,
                    limit: 1
                ).first else {
                    throw NotesError("paper_bundle_unavailable", "Paper attachment \(marker.2) has no native attachment row.")
                }
                let archive = try NCNotesRuntime.archivePaperBundle(for: attachment)
                guard !archive.isEmpty else {
                    throw NotesError("paper_bundle_snapshot_failed", "Paper attachment \(marker.2) produced an empty native archive.")
                }
                payloads[marker.2] = archive
            }
            return payloads
        }
    }

#if DEBUG
    func paperFileURLsForTesting(_ ref: String, identifier: String) throws -> [URL] {
        try performRead { context in
            let note = try note(ref, in: context)
            let account = try paperAccount(note)
            return try NCNotesRuntime.paperFileURLs(identifier: identifier, account: account.object)
                .map(Self.canonicalPaperURL)
        }
    }

    func paperBundleNamesForTesting(_ ref: String) throws -> Set<String> {
        try performRead { context in
            let note = try note(ref, in: context)
            let account = try paperAccount(note)
            let root = Self.canonicalPaperURL(try NCNotesRuntime.paperBundlesDirectoryURL(account: account.object))
            return Set(((try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).map(\.lastPathComponent))
        }
    }
#endif

    public func snapshotLinkPayloads(_ ref: String) throws -> [String: SnapshotLinkPayload] {
        try performRead { context in
            let note = try note(ref, in: context)
            let markers = attachmentMarkers(try body(note))
            var payloads: [String: SnapshotLinkPayload] = [:]
            for marker in markers {
                guard let attachment = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", marker.2, note),
                    in: context,
                    limit: 1
                ).first else { continue }
                let synapse = value(attachment, "synapseData") as? Data
                let metadata = value(attachment, "linkPresentationArchivedMetadata") as? Data
                guard synapse?.isEmpty == false || metadata?.isEmpty == false else { continue }
                payloads[marker.2] = SnapshotLinkPayload(
                    synapseData: synapse?.isEmpty == false ? synapse : nil,
                    linkPresentationMetadata: metadata?.isEmpty == false ? metadata : nil
                )
            }
            return payloads
        }
    }

    public func createNote(title: String, markdown: String, folder folderRef: String?, attachments: [FrozenAttachmentInput], allowShared: Bool) throws -> NativeCreateResult {
        try createNote(title: title, markdown: markdown, folder: folderRef, attachments: attachments,
                       systemPaper: false, allowShared: allowShared)
    }

    public func createQuickNote(title: String, markdown: String, folder folderRef: String?, allowShared: Bool) throws -> NativeCreateResult {
        try createNote(title: title, markdown: markdown, folder: folderRef, attachments: [],
                       systemPaper: true, allowShared: allowShared)
    }

    private func createNote(title: String, markdown: String, folder folderRef: String?, attachments: [FrozenAttachmentInput],
                            systemPaper: Bool, allowShared: Bool) throws -> NativeCreateResult {
        let write = try performWrite { context in
            let destination = try destinationFolder(folderRef, in: context)
            try guardWritableFolder(destination, allowShared: allowShared)
            if systemPaper {
                guard let account = value(destination, "account") as? NSManagedObject else {
                    throw NotesError("account_not_found", "The Quick Note folder has no account.")
                }
                try require(["identifier"], of: account)
                guard let accountID = value(account, "identifier") as? String, !accountID.isEmpty else {
                    throw NotesError("account_not_found", "The Quick Note account has no identifier.")
                }
                try requireQuickNoteAccount(accountID)
            }
            var noteID = "", attachmentIDs: [String] = [], createdNoteID: String?
            do {
                let note = try NCNotesRuntime.newNote(in: destination)
                createdNoteID = id(note)
                try NCNotesRuntime.setValue(title, forKey: "title", of: note)
                if systemPaper { try NCNotesRuntime.setSystemPaper(true, note: note) }
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["insert"])
                let source = "# " + title + (markdown.isEmpty ? "" : "\n" + markdown)
                let built = try MarkdownNativeWriter(owner: self).attributed(markdown: source, note: note, context: context,
                                                                                 editor: editor, existing: [:]).0
                for frozen in attachments {
                    var kind: NSString?
                    let attachmentID = try NCNotesRuntime.addFile(frozen.url, to: note, title: frozen.sourceName, type: &kind)
                    try TestFault.check("after_attachment")
                    let marker = try NCNotesRuntime.attachmentMarker(id: attachmentID, type: kind as String? ?? "public.data")
                    if built.length > 0 { built.append(NSAttributedString(string: "\n")) }
                    built.append(NSAttributedString(string: "\u{fffc}", attributes: [.init("NSAttachment"): marker]))
                    attachmentIDs.append(attachmentID)
                }
                try editor.begin(["insert"])
                try editor.insert(built, at: 0)
                try editor.finish()
                try TestFault.check("before_save")
                try save(context, notes: [note])
                noteID = id(note)
            } catch { return try rollBackCreatedNote(createdNoteID, after: error, in: context) }
            var hashes: [String: String] = [:]
            for (index, attachmentID) in attachmentIDs.enumerated() {
                if let hash = storedAttachmentHash(noteID: noteID, attachmentID: attachmentID, expected: attachments[index].sha256) {
                    hashes[attachmentID] = hash
                }
            }
            let nativeSystemPaper = value(try self.note(noteID, in: context), "isSystemPaper") as? Bool == true
            return result(noteID, native: ["title": title, "attachments": "\(attachmentIDs.count)", "hashes": "\(hashes.count)",
                                                   "isSystemPaper": String(nativeSystemPaper)],
                          nativeVerified: attachmentIDs.count == attachments.count && hashes.count == attachments.count &&
                              (!systemPaper || nativeSystemPaper),
                          sqlite: { note in
                guard note.summary.title == title,
                      Set(attachmentIDs).isSubset(of: Set(note.attachments.map(\.id))),
                      hashes.count == attachments.count,
                      !systemPaper || note.summary.isSystemPaper == true else { return nil }
                return ["title": note.summary.title, "attachments": "\(attachmentIDs.count)", "hashes": "\(hashes.count)",
                        "isSystemPaper": String(note.summary.isSystemPaper == true)]
            }, mismatch: "The created note or frozen attachment bytes did not match.")
        }
        guard write.writeResult.outcome != .rolledBack else {
            return NativeCreateResult(attachmentIDs: [], attachmentSHA256: [:], write: write)
        }
        let noteID = write.writeResult.noteID?.uuid ?? ""
        let note = try? SQLiteNotesStore(refresh: true).note(noteID)
        let ids = note?.attachments.map(\.id) ?? []
        var hashes: [String: String] = [:]
        for attachment in note?.attachments ?? [] {
            if let path = attachment.filePath, let hash = try? FrozenAttachmentInput.hash(file: URL(fileURLWithPath: path)) { hashes[attachment.id] = hash }
        }
        return NativeCreateResult(attachmentIDs: ids, attachmentSHA256: hashes, write: write)
    }

    public func insertURL(_ ref: String, url: URL, card: Bool, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw NotesError("invalid_url", "Use an http or https URL.") }
            let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
            var attachmentID: String?
            do {
                let editor = try NCBodyEditor(note: note); try editor.prepare(["insert"])
                let at = position ?? editor.original.length
                guard (0...editor.original.length).contains(at) else { throw NotesError("invalid_range", "Position exceeds the note length.") }
                if card {
                    var kind: NSString?
                    let id = try NCNotesRuntime.addURL(url, to: note, type: &kind)
                    attachmentID = id
                    try insertMarker(editor, original: editor.original, id: id, type: kind as String? ?? "public.url", position: position)
                } else {
                    let linked = NSAttributedString(string: url.absoluteString, attributes: [.init("NSLink"): url])
                    try editor.begin(["insert"]); try editor.insert(linked, at: UInt(at))
                }
                try editor.finish(); try save(context, notes: [note])
            } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
            let nativeBody = try body(try self.note(id(note), in: context))
            let nativeOK = attachmentID.map { id in attachmentMarkers(nativeBody).filter { $0.2 == id }.count == 1 } ?? nativeBody.string.contains(url.absoluteString)
            return result(id(note), native: ["url": url.absoluteString, "card": String(card), "attachmentID": attachmentID ?? ""], nativeVerified: nativeOK,
                          sqlite: { note in
                if let attachmentID {
                    return note.attachments.filter { $0.id == attachmentID && $0.url == url.absoluteString && $0.typeUTI.lowercased().contains("url") }.count == 1
                        ? ["url": url.absoluteString, "attachmentID": attachmentID] : nil
                }
                return note.document?.text.contains(url.absoluteString) == true ? ["url": url.absoluteString] : nil
            }, mismatch: card ? "The URL preview card was not present exactly once." : "The URL link was not found after the write.")
        }
    }

    public func insertSynapseLink(_ ref: String, url: URL, title: String,
                                  position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil else {
                throw NotesError("invalid_url", "Use an absolute http or https URL without embedded credentials.")
            }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { throw NotesError("invalid_shared_link", "Title cannot be empty.") }
            let sourceIdentifier: String
            do { sourceIdentifier = try NCNotesRuntime.synapseWebSourceIdentifier() }
            catch { throw nativeError(error) }
            let sourceName = "NotesCLI"
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note)
            var attachmentID = "", kind = ""
            do {
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["insert"])
                let at = position ?? editor.original.length
                guard (0...editor.original.length).contains(at) else {
                    throw NotesError("invalid_range", "Position exceeds the note length.")
                }
                var nativeKind: NSString?
                attachmentID = try NCNotesRuntime.addSynapseLink(url, title: cleanTitle, to: note, type: &nativeKind)
                guard let nativeKind = nativeKind as String?, !nativeKind.isEmpty else {
                    throw NotesError("native_write_failed", "Notes created a shared link without an attachment type.")
                }
                kind = nativeKind
                try insertMarker(editor, original: editor.original, id: attachmentID, type: kind, position: position)
                try editor.finish()
                try save(context, notes: [note])
            } catch {
                context.rollback()
                throw (error as? NotesError) ?? nativeError(error)
            }
            guard let attachment = try fetch("ICAttachment", predicate: NSPredicate(
                format: "identifier == %@ AND note == %@ AND markedForDeletion == NO", attachmentID, note),
                in: context, limit: 1).first else {
                throw NotesError("native_verification_failed", "The shared-link attachment disappeared after save.")
            }
            let info: [String: Any]
            do { info = try NCNotesRuntime.synapseLinkInfo(for: attachment) }
            catch { throw nativeError(error) }
            let nativeVerified = info["url"] as? String == url.absoluteString &&
                info["title"] as? String == cleanTitle && info["sourceIdentifier"] as? String == sourceIdentifier &&
                info["sourceName"] as? String == sourceName && ((info["dataBytes"] as? NSNumber)?.intValue ?? 0) > 0
            let markerCount = attachmentMarkers(try body(try self.note(id(note), in: context)))
                .filter { $0.2 == attachmentID && $0.3 == kind }.count
            return result(id(note), native: ["url": url.absoluteString, "title": cleanTitle,
                                             "attachmentID": attachmentID, "typeUTI": kind,
                                             "markerCount": String(markerCount)],
                          nativeVerified: nativeVerified && markerCount == 1,
                          sqlite: { stored in
                guard let value = stored.attachments.first(where: {
                    $0.id == attachmentID && $0.typeUTI == kind && ($0.synapseDataBytes ?? 0) > 0
                }), stored.document?.runs.filter({
                    $0.attachment?.id == attachmentID && $0.attachment?.typeUTI == kind
                }).count == 1 else { return nil }
                return ["attachmentID": value.id, "typeUTI": value.typeUTI, "url": value.url ?? "",
                        "synapseDataBytes": String(value.synapseDataBytes ?? 0),
                        "linkPreviewMetadataBytes": String(value.linkPreviewMetadataBytes ?? 0)]
            }, mismatch: "The native shared-link attachment did not match its Synapse content item.")
        }
    }

    public func insertMap(_ ref: String, url: URL, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
            try NativeMapURL.validate(url)
            let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
            var attachmentID = "", mapEvidence: [String: Any] = [:]
            do {
                let editor = try NCBodyEditor(note: note); try editor.prepare(["insert"])
                let at = position ?? editor.original.length
                guard (0...editor.original.length).contains(at) else { throw NotesError("invalid_range", "Position exceeds the note length.") }
                var kind: NSString?
                attachmentID = try NCNotesRuntime.addURL(url, to: note, type: &kind)
                guard let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, note), in: context, limit: 1).first else {
                    throw NotesError("attachment_not_found", "Notes did not return the created map attachment.")
                }
                mapEvidence = try NCNotesRuntime.addLocation(toMapAttachment: attachment)
                guard mapEvidence["model"] as? String == "ICAttachmentMapModel",
                      mapEvidence["hasLocation"] as? Bool == true else {
                    throw NotesError("map_metadata_missing", "Notes created a URL card without native map metadata.")
                }
                try insertMarker(editor, original: editor.original, id: attachmentID,
                                 type: kind as String? ?? "public.url", position: position)
                try editor.finish(); try save(context, notes: [note])
            } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
            let nativeBody = try body(try self.note(id(note), in: context))
            let nativeOK = attachmentMarkers(nativeBody).filter { $0.2 == attachmentID }.count == 1
            return result(id(note), native: ["url": url.absoluteString, "attachmentID": attachmentID,
                                             "model": mapEvidence["model"] as? String ?? "",
                                             "hasLocation": String(mapEvidence["hasLocation"] as? Bool == true)],
                          nativeVerified: nativeOK && mapEvidence["hasLocation"] as? Bool == true,
                          sqlite: { storedNote in
                guard storedNote.attachments.contains(where: { $0.id == attachmentID && $0.url == url.absoluteString }),
                      (try? SQLiteNotesStore(refresh: true).attachmentHasStoredLocation(note: storedNote.summary.id.uuid,
                                                                                       attachmentID: attachmentID)) == true else { return nil }
                return ["attachmentID": attachmentID, "url": url.absoluteString, "location": "stored"]
            }, mismatch: "The Apple Maps card or its stored location did not match after readback.")
        }
    }

    public func deleteAttachment(_ ref: String, attachmentID: String, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
        let markers = attachmentMarkers(try body(note)).filter { $0.2 == attachmentID }; guard markers.count == 1 else { throw NotesError("attachment_placement_mismatch", "Attachment must have exactly one placement; found \(markers.count).") }
        guard let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, note), in: context, limit: 1).first else { throw NotesError("attachment_not_found", "Attachment does not belong to this note.") }
        do { let editor = try NCBodyEditor(note: note); try editor.begin(["delete"]); try editor.delete(markers[0].0); try NCNotesRuntime.markForDeletion(attachment); try editor.finish(); try save(context, notes: [note]) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let placements = attachmentMarkers(try body(try self.note(id(note), in: context))).filter { $0.2 == attachmentID }.count
        return result(id(note), native: ["deletedAttachment": attachmentID, "placements": "\(placements)"], nativeVerified: placements == 0,
                      sqlite: { !$0.attachments.contains(where: { $0.id == attachmentID }) ? ["deletedAttachment": attachmentID] : nil },
                      mismatch: "Attachment \(attachmentID) was still present after deletion.")
        }
    }

    fileprivate func table(_ attachmentID: String, note: NSManagedObject, context: NSManagedObjectContext) throws -> NSManagedObject {
        guard let item = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@ AND note == %@ AND typeUTI == %@", attachmentID, note, "com.apple.notes.table"), in: context, limit: 1).first else { throw NotesError("table_not_found", "No table attachment matches this note.") }; return item
    }
    fileprivate func tableRows(_ attachment: NSManagedObject) throws -> [[String]] {
        let editor = try NCTableEditor(attachment: attachment)
        let rows = try editor.rowCount().intValue, columns = try editor.columnCount().intValue
        return try (0..<rows).map { r in try (0..<columns).map { c in try editor.text(column: c, row: r) } }
    }
    public func createTable(_ ref: String, rows: [[String]], position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let width = rows.map(\.count).max() ?? 0; guard !rows.isEmpty, width > 0 else { throw NotesError("invalid_table", "A table needs at least one cell.") }
        let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }, note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
        var tableID = ""
        do {
            try NCNotesRuntime.requireInstanceSelectors(["attachmentModel", "updateChangeCountWithReason:"], className: "ICAttachment")
            try NCNotesRuntime.requireInstanceSelectors(["table", "setMergeableDataDirty:", "writeMergeableData"], className: "ICAttachmentTableModel")
            try NCNotesRuntime.requireInstanceSelectors(["rowCount", "columnCount", "stringForColumnIndex:rowIndex:", "identifierForColumnAtIndex:", "identifierForRowAtIndex:", "mergeableStringForColumnID:rowID:", "setAttributedString:columnIndex:rowIndex:"], className: "ICTable")
            let editor = try NCBodyEditor(note: note); try editor.prepare(["insert"]); tableID = try editor.addTable(padded.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }.joined(separator: "\n")); try insertMarker(editor, original: editor.original, id: tableID, type: "com.apple.notes.table", position: position); try editor.finish(); try save(context, notes: [note]); let attachment = try table(tableID, note: try self.note(id(note), in: context), context: context); if try tableRows(attachment) != padded { let edit = try NCTableEditor(attachment: attachment), style = try NCNotesRuntime.paragraphStyle(3, indent: 0, quote: 0, checked: -1, basedOn: nil); for r in padded.indices { for c in padded[r].indices { try edit.setCell(column: c, row: r, text: padded[r][c], style: style) } }; try edit.save(); try save(context, notes: [note]) }
        }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let nativeRows = try tableRows(try table(tableID, note: try self.note(id(note), in: context), context: context))
        return result(id(note), native: ["tableID": tableID, "rows": "\(nativeRows.count)", "columns": "\(nativeRows.first?.count ?? 0)"], nativeVerified: NativeVerificationRules.exactTable(nativeRows, expected: padded), sqlite: { NativeVerificationRules.exactTable($0.document?.tables?[tableID], expected: padded) ? ["tableID": tableID, "rows": "\(padded.count)", "columns": "\(width)"] : nil }, mismatch: "Table \(tableID) cells did not match the requested rows.")
        }
    }
    public func editTable(_ ref: String, attachmentID: String, row: Int, column: Int, text: String, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note); let attachment = try table(attachmentID, note: note, context: context)
        var expectedRows = try tableRows(attachment)
        guard row >= 0, row < expectedRows.count, column >= 0, column < (expectedRows.first?.count ?? 0) else { throw NotesError("invalid_table_cell", "Cell is outside the table.") }
        expectedRows[row][column] = text
        do { let editor = try NCTableEditor(attachment: attachment); let style = try NCNotesRuntime.paragraphStyle(3, indent: 0, quote: 0, checked: -1, basedOn: nil); try editor.setCell(column: column, row: row, text: text, style: style); try editor.save(); try save(context, notes: [note]) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let nativeRows = try tableRows(try table(attachmentID, note: try self.note(id(note), in: context), context: context))
        return result(id(note), native: ["tableID": attachmentID, "cell": "\(row),\(column)", "text": text],
                      nativeVerified: NativeVerificationRules.exactTable(nativeRows, expected: expectedRows),
                      sqlite: { NativeVerificationRules.exactTable($0.document?.tables?[attachmentID], expected: expectedRows) ? ["cell": "\(row),\(column)", "text": text] : nil },
                      mismatch: "Table \(attachmentID) cells did not match after editing \(row),\(column).")
        }
    }
    public func formatTableCell(_ ref: String, attachmentID: String, row: Int, column: Int, range: UTF16Range, format: InlineFormat, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        if let superscript = format.superscript, !(-1...1).contains(superscript) { throw NotesError("invalid_superscript", "Superscript must be -1, 0, or 1.") }
        if let size = format.fontSize, !size.isFinite || size <= 0 { throw NotesError("invalid_font_size", "Font size must be a positive number.") }
        let requestedColor = try format.color.map(Self.color)
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
        let attachment = try table(attachmentID, note: note, context: context), editor = try NCTableEditor(attachment: attachment)
        let rows = try editor.rowCount().intValue, columns = try editor.columnCount().intValue
        guard row >= 0, row < rows, column >= 0, column < columns else { throw NotesError("invalid_table_cell", "Cell is outside the table.") }
        let original = try editor.attributedText(column: column, row: row), target = try valid(range, length: original.length, allowEmpty: false)
        let updated = NSMutableAttributedString(attributedString: original)
        var writes: [(NSRange, [NSAttributedString.Key: Any])] = []
        original.enumerateAttributes(in: target) { attrs, run, _ in writes.append((run, attrs)) }
        for (run, attrs) in writes {
            var copy = attrs, hints = copy[.init("TTHints")] as? Int ?? 0
            if let bold = format.bold { hints = bold ? hints | 1 : hints & ~1 }
            if let italic = format.italic { hints = italic ? hints | 2 : hints & ~2 }
            copy[.init("TTHints")] = hints == 0 ? nil : hints
            if let underline = format.underline { copy[.init("TTUnderline")] = underline ? 1 : nil }
            if let strike = format.strike { copy[.init("TTStrikethrough")] = strike ? 1 : nil }
            if format.clearLink { copy[.init("NSLink")] = nil } else if let link = format.link { copy[.init("NSLink")] = URL(string: link) ?? link }
            if format.clearColor { copy[.init("TTColor")] = nil } else if let requestedColor { copy[.init("TTColor")] = requestedColor }
            if let superscript = format.superscript { copy[.init("NSSuperScript")] = superscript == 0 ? nil : superscript }
            if format.clearHighlight { copy[.init("TTEmphasis")] = nil } else if let highlight = format.highlight { copy[.init("TTEmphasis")] = highlight.notesValue }
            let oldFont = copy[.init("ICTTFont")] as AnyObject?
            if format.fontName != nil || format.fontSize != nil || (oldFont != nil && (format.bold != nil || format.italic != nil)) {
                if let oldFont { try require(["fontName", "pointSize", "fontHints"], of: oldFont) }
                copy[.init("ICTTFont")] = try NCNotesRuntime.font(name: format.fontName, size: format.fontSize.map(NSNumber.init(value:)), hints: hints, basedOn: oldFont)
            }
            updated.setAttributes(copy, range: run)
        }
        do { try editor.setAttributedCell(column: column, row: row, text: updated); try editor.save(); try save(context, notes: [note]) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let freshEditor = try NCTableEditor(attachment: try table(attachmentID, note: try self.note(id(note), in: context), context: context))
        let readback = try freshEditor.attributedText(column: column, row: row)
        var nativeRows: [[NSAttributedString.Key: Any]] = []
        readback.enumerateAttributes(in: target) { attrs, _, _ in nativeRows.append(attrs) }
        let nativeOK = try !nativeRows.isEmpty && nativeRows.allSatisfy { try Self.matches($0, format: format) }
        return result(id(note), native: ["tableID": attachmentID, "cell": "\(row),\(column)", "location": "\(range.location)", "length": "\(range.length)"], nativeVerified: nativeOK,
                      sqlite: { decoded in
            guard let cell = decoded.document?.tableCells?[attachmentID]?[safe: row]?[safe: column] else { return nil }
            let runs = Self.documentRuns(cell.document, in: range)
            guard !runs.isEmpty, runs.allSatisfy({ Self.matches($0, format: format) }) else { return nil }
            return ["tableID": attachmentID, "cell": "\(row),\(column)"]
        }, mismatch: "Table cell formatting did not match after editing \(row),\(column).")
        }
    }
    public func resizeTable(_ ref: String, attachmentID: String, axis: String, index: Int, add: Bool, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        guard ["row", "column"].contains(axis), index >= 0 else { throw NotesError("invalid_table_resize", "Axis must be row or column and index nonnegative.") }; let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note); let attachment = try table(attachmentID, note: note, context: context)
        var expectedRows = try tableRows(attachment)
        do {
            let editor = try NCTableEditor(attachment: attachment), count = axis == "row" ? expectedRows.count : (expectedRows.first?.count ?? 0)
            guard add ? index <= count : index < count else { throw NotesError("invalid_table_resize", "Index is outside the table.") }
            if !add && count <= 1 { throw NotesError("invalid_table_resize", "A table must keep one \(axis).") }
            if axis == "row" {
                if add { expectedRows.insert(Array(repeating: "", count: expectedRows.first?.count ?? 0), at: index); try editor.insertRow(index) }
                else { expectedRows.remove(at: index); try editor.removeRow(index) }
            } else {
                for row in expectedRows.indices { if add { expectedRows[row].insert("", at: index) } else { expectedRows[row].remove(at: index) } }
                if add { try editor.insertColumn(index) } else { try editor.removeColumn(index) }
            }
            try editor.save(); try save(context, notes: [note])
        }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let rows = try tableRows(try table(attachmentID, note: try self.note(id(note), in: context), context: context))
        return result(id(note), native: ["rows": "\(rows.count)", "columns": "\(rows.first?.count ?? 0)"],
                      nativeVerified: NativeVerificationRules.exactTable(rows, expected: expectedRows),
                      sqlite: { NativeVerificationRules.exactTable($0.document?.tables?[attachmentID], expected: expectedRows) ? ["rows": "\(expectedRows.count)", "columns": "\(expectedRows.first?.count ?? 0)"] : nil },
                      mismatch: "Table \(attachmentID) cells did not match after resizing.")
        }
    }

    public func convertTableToText(_ ref: String, attachmentID: String, separator: String, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        guard separator == "tab" || separator == "comma" else { throw NotesError("invalid_separator", "Separator must be tab or comma.") }
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); try refreshIfStale(note)
        let attachment = try table(attachmentID, note: note, context: context), rows = try tableRows(attachment)
        let delimiter = separator == "tab" ? "\t" : ","
        let text = rows.map { $0.joined(separator: delimiter) }.joined(separator: "\n")
        let before = try body(note).string
        guard let marker = attachmentMarkers(try body(note)).first(where: { $0.2 == attachmentID }) else { throw NotesError("table_marker_not_found", "The table marker is missing from the note body.") }
        do {
            let editor = try NCBodyEditor(note: note); try editor.begin(["replace"])
            try editor.replace(marker.0, with: NSAttributedString(string: text))
            try NCNotesRuntime.markForDeletion(attachment); try editor.finish(); try save(context, notes: [note])
        } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let fresh = try self.note(id(note), in: context), nativeBody = try body(fresh)
        let nativeOK = attachmentMarkers(nativeBody).allSatisfy { $0.2 != attachmentID } &&
            NativeVerificationRules.exactReplacement(before: before, after: nativeBody.string, range: marker.0, text: text)
        return result(id(note), native: ["tableID": attachmentID, "text": text, "separator": separator,
                                         "length": String((nativeBody.string as NSString).length)], nativeVerified: nativeOK,
                      sqlite: { decoded in
            guard decoded.document?.tables?[attachmentID] == nil, let body = decoded.document?.text,
                  NativeVerificationRules.exactReplacement(before: before, after: body, range: marker.0, text: text) else { return nil }
            return ["tableID": attachmentID, "text": text, "length": String((body as NSString).length)]
        }, mismatch: "Table \(attachmentID) was not replaced with text exactly once.")
        }
    }

    public func duplicate(_ ref: String, title newTitle: String?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let source = try note(ref, in: context); try guardWritable(source, allowShared: allowShared); try refreshIfStale(source, protectsBody: false); guard let folder = value(source, "folder") as? NSManagedObject else { throw NotesError("folder_not_found", "The source note has no folder.") }
        var copyID: String?
        do { let copy = try NCNotesRuntime.duplicateNote(source, folder: folder); copyID = id(copy); if let newTitle { try NCNotesRuntime.setValue(newTitle, forKey: "title", of: copy) }; try save(context, notes: [copy]); let copyTitle = title(copy); return result(id(copy), native: ["duplicatedFrom": id(source), "title": copyTitle], sqlite: { $0.summary.title == copyTitle ? ["title": $0.summary.title] : nil }) }
        catch { return try rollBackCreatedNote(copyID, after: error, in: context) }
        }
    }

    public func deleteNote(_ ref: String, allowShared: Bool) throws -> NativeWriteResult {
        try performWriteWithFreshReadback(transaction: { context -> String in
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note, protectsBody: false)
            let noteID = id(note)
            guard let sourceFolder = value(note, "folder") as? NSManagedObject,
                  let account = value(sourceFolder, "account") as? NSManagedObject else {
                throw NotesError("folder_not_found", "The note has no account folder.")
            }
            let trashFolders = try fetch("ICFolder", predicate: NSPredicate(
                format: "folderType == 1 AND account == %@ AND markedForDeletion == NO", account
            ), in: context)
            guard trashFolders.count == 1, let trash = trashFolders.first else {
                throw NotesError("trash_folder_not_found", "The note account does not expose one Recently Deleted folder.")
            }
            do {
                try appleMove(note, to: trash)
            } catch {
                throw (error as? NotesError) ?? nativeError(error)
            }
            operation?.committed = true
            operation?.noteID = noteID
            return noteID
        }, readback: { context, noteID in
            let deleted = try note(noteID, in: context)
            try require(["markedForDeletion", "folder"], of: deleted)
            let markedForDeletion = value(deleted, "markedForDeletion") as? Bool == true
            let folder = value(deleted, "folder") as? NSManagedObject
            if let folder { try require(["folderType"], of: folder) }
            let folderType = folder.flatMap { value($0, "folderType") as? Int }
            let nativeDeleted = NativeDeleteVerification.isDeleted(markedForDeletion: markedForDeletion,
                                                                    folderType: folderType)
            return result(noteID,
                          native: ["markedForDeletion": String(markedForDeletion),
                                   "folderType": folderType.map(String.init) ?? ""],
                          nativeVerified: nativeDeleted,
                          sqlite: { note in
                              guard let state = try? SQLiteNotesStore(refresh: true).noteDeletionState(noteID) else { return nil }
                              return NativeDeleteVerification.isDeleted(markedForDeletion: state.markedForDeletion,
                                                                        folderType: state.folderType)
                                  ? ["deleted": "true", "markedForDeletion": "false", "folderType": "1",
                                     "folder": note.summary.folderPath.joined(separator: " > ")]
                                  : nil
                          },
                          mismatch: "The note was saved but was not verified in Recently Deleted.")
        })
    }

    fileprivate func appleMove(_ note: NSManagedObject, to folder: NSManagedObject) throws {
        let script = "on run argv\ntell application \"Notes\" to move note id (item 1 of argv) to folder id (item 2 of argv)\nend run", process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-e", script, "--", note.objectID.uriRepresentation().absoluteString, folder.objectID.uriRepresentation().absoluteString]; let errorPipe = Pipe(); process.standardError = errorPipe; process.standardOutput = FileHandle.nullDevice; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw NotesError("native_sync_failed", String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
    }
    public func restore(_ ref: String, folder destination: String?, allowShared: Bool) throws -> NativeWriteResult {
        return try performWrite { context in
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared, allowTrash: true); try refreshIfStale(note, protectsBody: false)
        let target: NSManagedObject
        if let destination { target = try folder(destination, in: context) }
        else { guard let original = ["folderBeforeDeletion", "originalFolder", "previousFolder"].compactMap({ value(note, $0) as? NSManagedObject }).first else { throw NotesError("restore_folder_required", "NotesShared exposes no original folder for this note. Pass --folder.") }; target = original }
        try guardWritableFolder(target, allowShared: allowShared)
        if value(note, "markedForDeletion") as? Bool == true {
            try NCNotesRuntime.unmarkForDeletion(note)
            try NCNotesRuntime.save(context)
            operation?.committed = true
            operation?.noteID = id(note)
        }
        try appleMove(note, to: target); operation?.committed = true; operation?.noteID = id(note)
        context.refreshAllObjects(); let restored = try self.note(id(note), in: context)
        guard let restoredFolder = value(restored, "folder") as? NSManagedObject else {
            return result(id(note), native: ["restored": "false"], nativeVerified: false,
                          sqlite: { !$0.summary.isDeleted ? ["restored": "true"] : nil }, message: "Notes.app did not expose a destination folder after the move.")
        }
        return result(id(note), native: ["folderID": id(restoredFolder), "restored": "true"], sqlite: { !$0.summary.isDeleted ? ["restored": "true"] : nil })
        }
    }
    public func moveFolder(_ ref: String, parent: String?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let moved = try folder(ref, in: context), target = try parent.map { try folder($0, in: context) }
        try guardWritableFolder(moved, allowShared: allowShared); if let target { try guardWritableFolder(target, allowShared: allowShared) }
        if let target { var current: NSManagedObject? = target; while let item = current { if item == moved { throw NotesError("invalid_folder_move", "A folder cannot move inside itself.") }; current = value(item, "parent") as? NSManagedObject } }
        guard (value(moved, "account") as? NSManagedObject) == target.flatMap({ value($0, "account") as? NSManagedObject }) || target == nil else { throw NotesError("invalid_folder_move", "Folders move only within one account.") }
        do { try NCNotesRuntime.moveFolder(moved, parent: target); try NCNotesRuntime.save(context); operation?.committed = true; operation?.folderID = id(moved) } catch { context.rollback(); throw nativeError(error) }
        context.refreshAllObjects()
        let movedID = id(moved), parentID = target.map(id)
        let nativeParentID = (value(moved, "parent") as? NSManagedObject).map(id)
        return globalResult(native: ["folderID": movedID, "parentID": parentID ?? ""], nativeVerified: nativeParentID == parentID,
                            folderID: movedID, sqlite: {
            guard let folder = try SQLiteNotesStore(refresh: true).folders(account: nil).first(where: { $0.id.caseInsensitiveCompare(movedID) == .orderedSame }),
                  folder.parentID?.lowercased() == parentID?.lowercased() else { return nil }
            return ["folderID": folder.id, "parentID": folder.parentID ?? ""]
        })
        }
    }

    public func folderSort(_ ref: String) throws -> NativeFolderSortSetting {
        try performRead { context in try folderSortSetting(folder(ref, in: context)) }
    }

    fileprivate func folderSortSetting(_ folder: NSManagedObject) throws -> NativeFolderSortSetting {
        try require(["customNoteSortType", "supportsCustomNoteSortType", "isShowingDateHeaders"], of: folder)
        guard value(folder, "supportsCustomNoteSortType") as? Bool == true else { throw NotesError("folder_sort_unsupported", "This folder does not support a custom note sort.") }
        let raw: AnyObject
        if let current = value(folder, "customNoteSortType") as AnyObject? { raw = current }
        else { raw = try NCNotesRuntime.folderSortType(order: 0, direction: 0) as AnyObject }
        try require(["order", "direction", "valueRepresentation"], of: raw)
        let orderValue = value(raw, "order") as? Int ?? 0, directionValue = value(raw, "direction") as? Int ?? 0
        let order = [0: NativeFolderSortOrder.default, 1: .modified, 2: .created, 3: .title][orderValue] ?? .default
        let direction: NativeFolderSortDirection = order == .title ? (directionValue == 0 ? .ascending : .descending) : (directionValue == 0 ? .newest : .oldest)
        return NativeFolderSortSetting(folderID: id(folder), order: order, direction: direction,
                                       valueRepresentation: value(raw, "valueRepresentation") as? Int ?? orderValue * 10 + directionValue,
                                       groupsByDate: value(folder, "isShowingDateHeaders") as? Bool ?? false)
    }

    public func setFolderSort(_ ref: String, order: NativeFolderSortOrder, direction: NativeFolderSortDirection) throws -> NativeWriteResult {
        try setFolderSort(ref, order: order, direction: direction, expectedOrder: nil, expectedDirection: nil)
    }

    public func setFolderSort(_ ref: String, order: NativeFolderSortOrder, direction: NativeFolderSortDirection,
                              expectedOrder: NativeFolderSortOrder?, expectedDirection: NativeFolderSortDirection?) throws -> NativeWriteResult {
        try performWrite { context in
            let folder = try folder(ref, in: context), folderID = id(folder)
            guard !((order == .title) != (direction == .ascending || direction == .descending)) else {
                throw NotesError("invalid_folder_sort", "Use ascending or descending for title, and newest or oldest for date sorts.")
            }
            let current = try folderSortSetting(folder)
            try requireUndoState(current.order, expected: expectedOrder, label: "Folder sort order")
            try requireUndoState(current.direction, expected: expectedDirection, label: "Folder sort direction")
            do {
                try require(["setCustomNoteSortType:", "customNoteSortType", "supportsCustomNoteSortType", "updateChangeCountWithReason:"], of: folder)
                guard value(folder, "supportsCustomNoteSortType") as? Bool == true else { throw NotesError("folder_sort_unsupported", "This folder does not support a custom note sort.") }
                let sort = try NCNotesRuntime.folderSortType(order: order.value, direction: direction.value)
                try NCNotesRuntime.setValue(sort, forKey: "customNoteSortType", of: folder)
                try NCNotesRuntime.updateChangeCount(of: folder, reason: "Changed folder sort")
                try NCNotesRuntime.save(context); operation?.committed = true; operation?.folderID = folderID; context.refreshAllObjects()
            } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
            let setting = try folderSortSetting(folder)
            return globalResult(native: ["folderID": folderID, "order": setting.order.rawValue, "direction": setting.direction.rawValue,
                                         "valueRepresentation": String(setting.valueRepresentation)],
                                nativeVerified: setting.order == order && setting.direction.value == direction.value, folderID: folderID)
        }
    }

    public func setFolderDateGrouping(_ ref: String, grouped: Bool, allowShared: Bool) throws -> NativeWriteResult {
        try setFolderDateGrouping(ref, type: grouped ? 2 : 1, expectedCurrentType: nil, allowShared: allowShared)
    }

    public func setFolderDateGrouping(_ ref: String, type: Int, allowShared: Bool) throws -> NativeWriteResult {
        try setFolderDateGrouping(ref, type: type, expectedCurrentType: nil, allowShared: allowShared)
    }

    public func setFolderDateGrouping(_ ref: String, type: Int, expectedCurrentType: Int?, allowShared: Bool) throws -> NativeWriteResult {
        guard (0...2).contains(type) else {
            throw NotesError("invalid_date_grouping", "Folder date grouping must be inherited (0), off (1), or on (2).")
        }
        return try performWrite { context in
            let folder = try folder(ref, in: context), folderID = id(folder)
            try guardWritableFolder(folder, allowShared: allowShared)
            let currentType = try SQLiteNotesStore(refresh: true).folderDateHeadersType(folderID)
            try requireUndoState(currentType, expected: expectedCurrentType, label: "Folder date grouping")
            do {
                try NCNotesRuntime.applyDateHeadersType(type, to: folder)
                try NCNotesRuntime.save(context)
                operation?.committed = true
                operation?.folderID = folderID
                context.refreshAllObjects()
            } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
            let setting = try folderSortSetting(folder)
            let grouped = type == 2
            return globalResult(native: ["folderID": folderID, "grouped": String(setting.groupsByDate),
                                         "dateHeadersType": String(type)],
                                nativeVerified: type == 0 || setting.groupsByDate == grouped, folderID: folderID,
                                sqlite: {
                let stored = try SQLiteNotesStore(refresh: true).folderDateHeadersType(folderID)
                return stored == type ? ["folderID": folderID, "dateHeadersType": String(stored)] : nil
            }, message: type == 0 ? "Restored inherited date grouping for the folder."
                : grouped ? "Grouped the folder by date." : "Turned off date grouping for the folder.")
        }
    }

    public func defaultAccountIdentifier() throws -> String {
        try performRead { _ in
            do { return try NCNotesRuntime.defaultAccountIdentifier() }
            catch { throw nativeError(error) }
        }
    }

    public func setDefaultAccount(_ identifier: String) throws -> NativeWriteResult {
        try setDefaultAccount(identifier, expectedCurrent: nil)
    }

    public func setDefaultAccount(_ identifier: String, expectedCurrent: String?) throws -> NativeWriteResult {
        try performWrite { _ in
            do {
                let current = try NCNotesRuntime.defaultAccountIdentifier()
                try requireUndoIdentifier(current, expected: expectedCurrent, label: "Default Notes account")
                try NCNotesRuntime.setDefaultAccountIdentifier(identifier); operation?.committed = true
            }
            catch let error as NotesError { throw error }
            catch { throw nativeError(error) }
            let readback: String
            do { readback = try NCNotesRuntime.defaultAccountIdentifier() }
            catch { throw nativeError(error) }
            return globalResult(native: ["accountID": readback], nativeVerified: readback.caseInsensitiveCompare(identifier) == .orderedSame)
        }
    }

    public func defaultParagraphStyle() throws -> NativeDefaultParagraphStyle {
        try performRead { _ in
            do {
                let value = try NCNotesRuntime.noteDefaultNamedStyle().intValue
                guard let style = NativeDefaultParagraphStyle(value: value) else {
                    throw NotesError("unsupported_default_style", "Notes returned unknown default paragraph style \(value).")
                }
                return style
            } catch let error as NotesError { throw error }
            catch { throw nativeError(error) }
        }
    }

    public func setDefaultParagraphStyle(_ style: NativeDefaultParagraphStyle) throws -> NativeWriteResult {
        try setDefaultParagraphStyle(style, expectedCurrent: nil)
    }

    public func setDefaultParagraphStyle(_ style: NativeDefaultParagraphStyle,
                                         expectedCurrent: NativeDefaultParagraphStyle?) throws -> NativeWriteResult {
        try performWrite { _ in
            do {
                let currentValue = try NCNotesRuntime.noteDefaultNamedStyle().intValue
                guard let current = NativeDefaultParagraphStyle(value: currentValue) else {
                    throw NotesError("unsupported_default_style", "Notes returned unknown default paragraph style \(currentValue).")
                }
                try requireUndoState(current, expected: expectedCurrent, label: "Default paragraph style")
                try NCNotesRuntime.setNoteDefaultNamedStyle(UInt(style.value))
                operation?.committed = true
            } catch let error as NotesError { throw error }
            catch { throw nativeError(error) }
            let readback: NativeDefaultParagraphStyle
            do {
                let value = try NCNotesRuntime.noteDefaultNamedStyle().intValue
                guard let decoded = NativeDefaultParagraphStyle(value: value) else {
                    throw NotesError("unsupported_default_style", "Notes returned unknown default paragraph style \(value).")
                }
                readback = decoded
            } catch let error as NotesError { throw error }
            catch { throw nativeError(error) }
            return globalResult(native: ["style": readback.rawValue, "value": String(readback.value)],
                                nativeVerified: readback == style)
        }
    }

    private static let noteTextSizes = [10, 12, 14, 18, 24]

    public func notesSettings() throws -> NativeNotesSettings {
        try performRead { _ in
            do {
                let sortValue = try NCNotesRuntime.currentNoteListSortType().intValue
                guard let sort = NativeGlobalNoteSort(value: sortValue) else {
                    throw NotesError("unsupported_global_sort", "Notes returned unknown global note sort \(sortValue).")
                }
                let dateHeaders = try NCNotesRuntime.defaultDateHeadersType().intValue
                guard [1, 2].contains(dateHeaders) else {
                    throw NotesError("unsupported_date_grouping", "Notes returned unknown global date grouping \(dateHeaders).")
                }
                let zoom = try NCNotesRuntime.globalZoomFactorIndex().intValue
                guard Self.noteTextSizes.indices.contains(zoom) else {
                    throw NotesError("unsupported_text_size", "Notes returned unknown default text size index \(zoom).")
                }
                return NativeNotesSettings(sort: sort, groupsByDate: dateHeaders == 2,
                                           defaultTextSize: Self.noteTextSizes[zoom],
                                           resumesLastQuickNote: try NCNotesRuntime.shouldResumeLastQuickNote().boolValue,
                                           autoConvertsToTags: try NCNotesRuntime.shouldAutoConvertToTag().boolValue)
            } catch let error as NotesError { throw error }
            catch { throw nativeError(error) }
        }
    }

    public func setGlobalNoteSort(_ sort: NativeGlobalNoteSort) throws -> NativeWriteResult {
        try setGlobalNoteSort(sort, expectedCurrent: nil)
    }

    public func setGlobalNoteSort(_ sort: NativeGlobalNoteSort, expectedCurrent: NativeGlobalNoteSort?) throws -> NativeWriteResult {
        try performWrite { _ in
            do {
                let raw = try NCNotesRuntime.currentNoteListSortType().intValue
                guard let current = NativeGlobalNoteSort(value: raw) else {
                    throw NotesError("unsupported_global_sort", "Notes returned unknown global note sort \(raw).")
                }
                try requireUndoState(current, expected: expectedCurrent, label: "Global note sort")
                try NCNotesRuntime.setCurrentNoteListSortType(sort.value); operation?.committed = true
            }
            catch let error as NotesError { throw error }
            catch { throw nativeError(error) }
            let readback = try notesSettings().sort
            return globalResult(native: ["sort": readback.rawValue], nativeVerified: readback == sort)
        }
    }

    public func setGlobalDateGrouping(_ enabled: Bool) throws -> NativeWriteResult {
        try setGlobalDateGrouping(enabled, expectedCurrent: nil)
    }

    public func setGlobalDateGrouping(_ enabled: Bool, expectedCurrent: Bool?) throws -> NativeWriteResult {
        try performWrite { _ in
            do {
                let current = try NCNotesRuntime.defaultDateHeadersType().intValue == 2
                try requireUndoState(current, expected: expectedCurrent, label: "Global date grouping")
                try NCNotesRuntime.setDefaultDateHeadersType(enabled ? 2 : 1); operation?.committed = true
            }
            catch let error as NotesError { throw error }
            catch { throw nativeError(error) }
            let readback = try notesSettings().groupsByDate
            return globalResult(native: ["enabled": String(readback)], nativeVerified: readback == enabled)
        }
    }

    public func setDefaultTextSize(_ points: Int) throws -> NativeWriteResult {
        try setDefaultTextSize(points, expectedCurrent: nil)
    }

    public func setDefaultTextSize(_ points: Int, expectedCurrent: Int?) throws -> NativeWriteResult {
        guard let index = Self.noteTextSizes.firstIndex(of: points) else {
            throw NotesError("invalid_text_size", "Use 10, 12, 14, 18, or 24 points.")
        }
        return try performWrite { _ in
            do {
                let currentIndex = try NCNotesRuntime.globalZoomFactorIndex().intValue
                guard Self.noteTextSizes.indices.contains(currentIndex) else {
                    throw NotesError("unsupported_text_size", "Notes returned unknown default text size index \(currentIndex).")
                }
                try requireUndoState(Self.noteTextSizes[currentIndex], expected: expectedCurrent, label: "Default text size")
                try NCNotesRuntime.setGlobalZoomFactorIndex(index); operation?.committed = true
            }
            catch let error as NotesError { throw error }
            catch { throw nativeError(error) }
            let readback = try notesSettings().defaultTextSize
            return globalResult(native: ["points": String(readback)], nativeVerified: readback == points)
        }
    }

    public func setResumeLastQuickNote(_ enabled: Bool) throws -> NativeWriteResult {
        try setResumeLastQuickNote(enabled, expectedCurrent: nil)
    }

    public func setResumeLastQuickNote(_ enabled: Bool, expectedCurrent: Bool?) throws -> NativeWriteResult {
        try performWrite { _ in
            do {
                let current = try NCNotesRuntime.shouldResumeLastQuickNote().boolValue
                try requireUndoState(current, expected: expectedCurrent, label: "Resume last Quick Note")
                try NCNotesRuntime.setShouldResumeLastQuickNote(enabled); operation?.committed = true
            }
            catch let error as NotesError { throw error }
            catch { throw nativeError(error) }
            let readback = try notesSettings().resumesLastQuickNote
            return globalResult(native: ["enabled": String(readback)], nativeVerified: readback == enabled)
        }
    }

    public func setAutoConvertToTags(_ enabled: Bool) throws -> NativeWriteResult {
        try setAutoConvertToTags(enabled, expectedCurrent: nil)
    }

    public func setAutoConvertToTags(_ enabled: Bool, expectedCurrent: Bool?) throws -> NativeWriteResult {
        try performWrite { _ in
            do {
                let current = try NCNotesRuntime.shouldAutoConvertToTag().boolValue
                try requireUndoState(current, expected: expectedCurrent, label: "Automatic tag conversion")
                try NCNotesRuntime.setShouldAutoConvertToTag(enabled); operation?.committed = true
            }
            catch let error as NotesError { throw error }
            catch { throw nativeError(error) }
            let readback = try notesSettings().autoConvertsToTags
            return globalResult(native: ["enabled": String(readback)], nativeVerified: readback == enabled)
        }
    }

    fileprivate func matchingSmartFolders(_ ref: String, in context: NSManagedObjectContext) throws -> [NSManagedObject] {
        let rows = try fetch("ICFolder", predicate: NSPredicate(format: "markedForDeletion == NO AND folderType == 2"), in: context)
        if ref.hasPrefix("x-coredata://"), let url = URL(string: ref),
           let objectID = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
           let object = try? context.existingObject(with: objectID) { return rows.filter { $0 == object } }
        let byID = rows.filter { id($0).caseInsensitiveCompare(ref) == .orderedSame }
        return byID.isEmpty ? rows.filter { (value($0, "title") as? String) == ref } : byID
    }

    public func createSmartFolder(name: String, tags: [String], matchAll: Bool) throws -> NativeWriteResult {
        try performWrite { context in
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty, !tags.isEmpty else { throw NotesError("invalid_smart_folder", "Name and at least one tag are required.") }
            let normalized = try tags.map(normalizedTag)
            let tagObjects = try normalized.map { try hashtag($0, context: context) }
            let store = try SQLiteNotesStore(refresh: true)
            let accountIDs = Set(try normalized.flatMap { try store.notes(NoteQuery(tag: $0)).map(\.accountID) })
            guard accountIDs.count == 1, let accountID = accountIDs.first else {
                throw NotesError("invalid_smart_folder", "All tags must be used in one Notes account.")
            }
            guard let account = try fetch("ICAccount", predicate: NSPredicate(format: "identifier ==[c] %@", accountID), in: context, limit: 1).first else {
                throw NotesError("account_not_found", "The tag account was not found.")
            }
            let folderID: String
            do {
                folderID = try NCNotesRuntime.createSmartFolder(cleanName, tags: tagObjects, matchAll: matchAll, account: account)
                try NCNotesRuntime.save(context); operation?.committed = true; operation?.folderID = folderID
                context.refreshAllObjects()
            } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
            let nativeFolder = try matchingSmartFolders(folderID, in: context).first
            return globalResult(native: ["folderID": folderID, "name": cleanName, "match": matchAll ? "all" : "any", "tags": tags.joined(separator: ",")],
                                nativeVerified: nativeFolder != nil, folderID: folderID, sqlite: {
                guard let folder = try SQLiteNotesStore(refresh: true).folders(account: nil).first(where: { $0.id.caseInsensitiveCompare(folderID) == .orderedSame }),
                      folder.isSmartFolder, folder.name == cleanName else { return nil }
                return ["folderID": folder.id, "name": folder.name]
            })
        }
    }

    public func renameSmartFolder(_ ref: String, name: String, expectedCount: Int) throws -> NativeWriteResult {
        try performWrite { context in
            let matches = try matchingSmartFolders(ref, in: context)
            guard matches.count == expectedCount else { throw NotesError("expected_count_mismatch", "Found \(matches.count) matching Smart Folders, not \(expectedCount).") }
            guard expectedCount == 1, let folder = matches.first else { throw NotesError("invalid_expected_count", "Smart Folder rename requires --expected-count 1.") }
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty else { throw NotesError("invalid_name", "The Smart Folder name cannot be empty.") }
            let folderID = id(folder)
            do {
                try NCNotesRuntime.renameFolder(folder, name: cleanName); try NCNotesRuntime.save(context)
                operation?.committed = true; operation?.folderID = folderID; context.refreshAllObjects()
            } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
            return globalResult(native: ["folderID": folderID, "name": cleanName],
                                nativeVerified: (value(folder, "title") as? String) == cleanName, folderID: folderID, sqlite: {
                guard let row = try SQLiteNotesStore(refresh: true).folders(account: nil).first(where: { $0.id.caseInsensitiveCompare(folderID) == .orderedSame }),
                      row.isSmartFolder, row.name == cleanName else { return nil }
                return ["folderID": row.id, "name": row.name]
            })
        }
    }

    public func smartFolderQuery(_ ref: String) throws -> String {
        try performRead { context in
            let matches = try matchingSmartFolders(ref, in: context)
            guard matches.count == 1, let query = value(matches[0], "smartFolderQueryJSON") as? String else {
                throw NotesError(matches.isEmpty ? "smart_folder_not_found" : "ambiguous_folder", "Smart Folder must resolve uniquely with a readable query.")
            }
            try SmartFolderQueryGrammar.validate(query)
            return query
        }
    }

    public func editSmartFolderRules(_ ref: String, queryJSON: String, expectedCount: Int) throws -> NativeWriteResult {
        try editSmartFolderRules(ref, queryJSON: queryJSON, expectedCount: expectedCount, expectedCurrentQuery: nil)
    }

    public func editSmartFolderRules(_ ref: String, queryJSON: String, expectedCount: Int,
                                     expectedCurrentQuery: String?) throws -> NativeWriteResult {
        try SmartFolderQueryGrammar.validate(queryJSON)
        return try performWriteWithFreshReadback(transaction: { context in
            let matches = try matchingSmartFolders(ref, in: context)
            guard matches.count == expectedCount else { throw NotesError("expected_count_mismatch", "Found \(matches.count) matching Smart Folders, not \(expectedCount).") }
            guard expectedCount == 1, let folder = matches.first else { throw NotesError("invalid_expected_count", "Smart Folder rule editing requires --expected-count 1.") }
            let folderID = id(folder)
            let currentQuery = value(folder, "smartFolderQueryJSON") as? String ?? ""
            if let expectedCurrentQuery {
                let currentRule = try SmartFolderQueryGrammar.parse(currentQuery)
                let expectedRule = try SmartFolderQueryGrammar.parse(expectedCurrentQuery)
                try requireUndoState(currentRule, expected: expectedRule, label: "Smart Folder rules")
            }
            do {
                try NCNotesRuntime.requireSelectors(["smartFolderQueryJSON", "setSmartFolderQueryJSON:", "updateChangeCountWithReason:"], of: folder)
                try NCNotesRuntime.setValue(queryJSON, forKey: "smartFolderQueryJSON", of: folder)
                try NCNotesRuntime.updateChangeCount(of: folder, reason: "Edited Smart Folder rules")
                try NCNotesRuntime.save(context); operation?.committed = true; operation?.folderID = folderID
            } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
            return folderID
        }, readback: { context, folderID in
            guard let folder = try matchingSmartFolders(folderID, in: context).first else {
                return globalResult(native: ["folderID": folderID, "queryJSON": ""], nativeVerified: false, folderID: folderID,
                                    message: "The Smart Folder was not found after refetch.")
            }
            let nativeQuery = value(folder, "smartFolderQueryJSON") as? String
            let nativeGrammarOK = nativeQuery.map { (try? SmartFolderQueryGrammar.validate($0)) != nil } ?? false
            return globalResult(native: ["folderID": folderID, "queryJSON": nativeQuery ?? ""], nativeVerified: nativeQuery == queryJSON && nativeGrammarOK, folderID: folderID,
                                sqlite: {
                guard let row = try SQLiteNotesStore(refresh: true).folders(account: nil).first(where: { $0.id.caseInsensitiveCompare(folderID) == .orderedSame }),
                      row.smartFolderQuery == queryJSON, (try? SmartFolderQueryGrammar.validate(queryJSON)) != nil else { return nil }
                return ["folderID": folderID, "queryJSON": queryJSON]
            })
        })
    }

    public func deleteSmartFolder(_ ref: String, expectedCount: Int) throws -> NativeWriteResult {
        try performWrite { context in
            let matches = try matchingSmartFolders(ref, in: context)
            guard matches.count == expectedCount else { throw NotesError("expected_count_mismatch", "Found \(matches.count) matching Smart Folders, not \(expectedCount).") }
            guard expectedCount == 1, let folder = matches.first else { throw NotesError("invalid_expected_count", "Smart Folder delete requires --expected-count 1.") }
            let folderID = id(folder)
            do {
                try NCNotesRuntime.markForDeletion(folder); try NCNotesRuntime.save(context)
                operation?.committed = true; operation?.folderID = folderID; context.refreshAllObjects()
            } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
            return globalResult(native: ["folderID": folderID, "deleted": "true"],
                                nativeVerified: value(folder, "markedForDeletion") as? Bool == true, folderID: folderID, sqlite: {
                let rows = try SQLiteNotesStore(refresh: true).folders(account: nil)
                return rows.contains(where: { $0.id.caseInsensitiveCompare(folderID) == .orderedSame && !$0.isRecentlyDeleted }) ? nil : ["folderID": folderID, "deleted": "true"]
            })
        }
    }

    public func writeMarkdown(_ ref: String, markdown: String, dryRun: Bool, backup: Bool, allowShared: Bool) throws -> NativeWriteResult {
        let before = try SQLiteNotesStore(refresh: true).note(ref)
        return try performWrite { context in
            try MarkdownNativeWriter(owner: self).write(ref: ref, markdown: markdown, dryRun: dryRun, backup: backup,
                                                        allowShared: allowShared, before: before, context: context)
        }
    }

    public func appendMarkdown(_ ref: String, markdown: String, allowShared: Bool) throws -> NativeWriteResult {
        try patchMarkdown(ref, markdown: markdown, mode: .append, allowShared: allowShared)
    }

    public func prependMarkdown(_ ref: String, markdown: String, allowShared: Bool) throws -> NativeWriteResult {
        try patchMarkdown(ref, markdown: markdown, mode: .prepend, allowShared: allowShared)
    }

    public func insertMarkdown(_ ref: String, underHeading heading: String, markdown: String, allowShared: Bool) throws -> NativeWriteResult {
        try patchMarkdown(ref, markdown: markdown, mode: .insert(heading), allowShared: allowShared)
    }

    public func replaceSection(_ ref: String, heading: String, markdown: String, allowShared: Bool) throws -> NativeWriteResult {
        try patchMarkdown(ref, markdown: markdown, mode: .section(heading), allowShared: allowShared)
    }

    public func replaceText(_ ref: String, find: String, replacement: String, allowShared: Bool) throws -> NativeWriteResult {
        guard !find.isEmpty else { throw NotesError("invalid_find", "Find text cannot be empty.") }
        let before = try SQLiteNotesStore(refresh: true).note(ref)
        return try performWrite { context in
            let (note, readback) = try mutateBody(ref, context: context, allowShared: allowShared) { _, editor, original in
                let source = original.string as NSString
                var ranges: [NSRange] = [], start = 0
                while start <= source.length {
                    let found = source.range(of: find, range: NSRange(location: start, length: source.length - start))
                    if found.location == NSNotFound { break }
                    ranges.append(found); start = NSMaxRange(found)
                }
                guard !ranges.isEmpty else { throw NotesError("text_not_found", "The requested text was not found.") }
                try editor.begin(["replace"])
                for range in ranges.reversed() {
                    var attributes: [NSAttributedString.Key: Any] = [:]
                    if original.length > 0 { attributes = original.attributes(at: min(range.location, original.length - 1), effectiveRange: nil) }
                    try editor.replace(range, with: NSAttributedString(string: replacement, attributes: attributes))
                }
            }
            let noteID = id(note), expected = (before.document?.text as NSString?)?.replacingOccurrences(of: find, with: replacement)
            return result(noteID, native: ["utf16Length": "\(readback.length)", "replacements": "all"], nativeVerified: readback.string == expected,
                          sqlite: { after in
                guard after.document?.text == expected, NativeOnlyFeatures.detect(in: after) == NativeOnlyFeatures.detect(in: before) else { return nil }
                return ["features": NativeOnlyFeatures.detect(in: after).joined(separator: ","), "utf16Length": "\(readback.length)"]
            })
        }
    }

    fileprivate enum MarkdownPatchMode { case append, prepend, insert(String), section(String) }

    private func patchMarkdown(_ ref: String, markdown: String, mode: MarkdownPatchMode, allowShared: Bool) throws -> NativeWriteResult {
        let before = try SQLiteNotesStore(refresh: true).note(ref)
        return try performWrite { context in
            try MarkdownNativeWriter(owner: self).patch(ref: ref, markdown: markdown, mode: mode, allowShared: allowShared,
                                                        expectedFeatures: NativeOnlyFeatures.detect(in: before), context: context)
        }
    }

    private struct SnapshotScanRestoreResult {
        var idMap: [String: String]
        var parentID: String
    }

    private func recreateSnapshotScan(
        _ scan: SnapshotScanRecreation,
        newParentID: String,
        note: NSManagedObject,
        context: NSManagedObjectContext,
        prepared: [String: FrozenAttachmentInput],
        restoreMaterial: SnapshotRestoreMaterial?,
        snapshotDocument: NoteDocument,
        reservedIDs: Set<String>
    ) throws -> SnapshotScanRestoreResult {
        let pages = try scan.pages.map { page -> FrozenAttachmentInput in
            guard let frozen = prepared[page.id] else {
                throw NotesError("snapshot_material_missing", "Scan page \(page.id) has no prepared snapshot blob.")
            }
            return frozen
        }
        try Self.validateScanInputs(pages)
        let preparation: NCPreparedScan
        do { preparation = try NCNotesRuntime.prepareScan(imageURLs: pages.map(\.url)) }
        catch { throw nativeError(error) }
        defer { preparation.invalidate() }
        do { try NCNotesRuntime.validateScanPopulation(preparation) }
        catch { throw nativeError(error) }

        let current = try body(note)
        let markers = attachmentMarkers(current).filter {
            $0.2 == scan.parentID || $0.2 == newParentID
        }
        guard markers.count <= 1 else {
            throw NotesError("snapshot_attachment_unavailable", "Scan \(scan.parentID) has more than one current body marker.")
        }
        var savedOffset = 0
        let savedMarkers = snapshotDocument.runs.compactMap { run -> Int? in
            defer { savedOffset += run.length }
            return run.attachment?.id == scan.parentID ? savedOffset : nil
        }
        guard savedMarkers.count == 1 else {
            throw NotesError("invalid_snapshot", "Scan \(scan.parentID) does not have exactly one saved body marker.")
        }
        let markerLocation = markers.first?.0.location ?? savedMarkers[0]
        guard markerLocation <= current.length else {
            throw NotesError("undo_conflict", "The deleted scan marker's saved position no longer exists in the note body.")
        }
        guard !reservedIDs.contains(newParentID) else {
            throw NotesError("snapshot_attachment_id_collision", "Notes reused an attachment identifier during scan restore.")
        }
        let gallery = try NCNotesRuntime.newScanGallery(in: note, identifier: newParentID)
        guard value(gallery, "typeUTI") as? String == "com.apple.notes.gallery" else {
            throw NotesError("snapshot_attachment_type_mismatch", "Notes created an unexpected scan container type.")
        }
        if markers.first?.2 != newParentID {
            let editor = try NCBodyEditor(note: note)
            try editor.prepare(markers.first == nil ? ["insert"] : ["replace"])
            let marker = try NCNotesRuntime.attachmentMarker(id: newParentID, type: "com.apple.notes.gallery")
            let replacement: NSMutableAttributedString
            if let existing = markers.first {
                replacement = NSMutableAttributedString(attributedString: current.attributedSubstring(from: existing.0))
            } else {
                let savedBody = try attributed(snapshotDocument).text
                replacement = NSMutableAttributedString(attributedString: savedBody.attributedSubstring(
                    from: NSRange(location: savedMarkers[0], length: 1)
                ))
            }
            replacement.addAttribute(.init("NSAttachment"), value: marker,
                                     range: NSRange(location: 0, length: replacement.length))
            if let existing = markers.first {
                try editor.begin(["replace"])
                try editor.replace(existing.0, with: replacement)
            } else {
                try editor.begin(["insert"])
                try editor.insert(replacement, at: UInt(markerLocation))
            }
            try editor.finish()
        }

        operation?.noteID = id(note)
        operation?.attachmentID = newParentID
        operation?.attachmentType = "com.apple.notes.gallery"
        operation?.attachmentPosition = markerLocation
        // Notes' gallery utility saves the context internally. The replacement marker is already in
        // the body, so an interrupted population leaves a visible, diagnosable partial scan.
        try validateBodiesBeforeSave([note])
        operation?.committed = true
        let populated: [String: Any]
        do { populated = try NCNotesRuntime.populateScanGallery(gallery, preparation: preparation, context: context) }
        catch { throw nativeError(error) }
        guard let newPageIDs = populated["pageIDs"] as? [String],
              let pageTypes = populated["pageTypes"] as? [String],
              newPageIDs.count == scan.pages.count,
              pageTypes.count == scan.pages.count else {
            throw NotesError("scan_incomplete", "Notes did not recreate every saved scan page.")
        }
        let allNewIDs = [newParentID] + newPageIDs
        guard Set(allNewIDs).count == allNewIDs.count,
              Set(allNewIDs).isDisjoint(with: reservedIDs),
              zip(pageTypes, scan.pages).allSatisfy({ $0 == $1.material.typeUTI }) else {
            throw NotesError("snapshot_attachment_type_mismatch", "Notes recreated the scan with conflicting IDs or page types.")
        }
        operation?.childAttachmentIDs.append(contentsOf: newPageIDs)

        if zip(scan.pages, newPageIDs).contains(where: { page, _ in
            page.filter != 0 || page.orientation != 0 || page.crop != nil || page.markupSHA256 != nil
        }) {
            do { try NCNotesRuntime.validateScanEditing() }
            catch { throw nativeError(error) }
        }
        for (page, newPageID) in zip(scan.pages, newPageIDs) {
            if let savedCrop = page.crop {
                guard let frozen = prepared[page.id],
                      let size = Self.scanImagePixelSize(frozen.url),
                      let crop = Self.normalizedScanCrop(savedCrop, pixelWidth: size.width, pixelHeight: size.height) else {
                    throw NotesError("unsupported_scan_crop", "The saved crop for scan page \(page.id) cannot be mapped to its archived image.")
                }
                try NCNotesRuntime.setScanCrop(
                    bottomLeftX: crop.bottomLeft.x, bottomLeftY: crop.bottomLeft.y,
                    bottomRightX: crop.bottomRight.x, bottomRightY: crop.bottomRight.y,
                    topLeftX: crop.topLeft.x, topLeftY: crop.topLeft.y,
                    topRightX: crop.topRight.x, topRightY: crop.topRight.y,
                    pageIdentifier: newPageID, gallery: gallery
                )
            }
            if page.filter != 0 {
                try NCNotesRuntime.applyScanFilter(Int16(page.filter), pageIdentifier: newPageID, gallery: gallery)
            }
            if page.orientation != 0 {
                try NCNotesRuntime.setScanOrientation(page.orientation, pageIdentifier: newPageID, gallery: gallery)
            }
            if let hash = page.markupSHA256, let byteCount = page.markupByteCount {
                guard let restoreMaterial else {
                    throw NotesError("snapshot_material_missing", "The scan markup package is unavailable.")
                }
                let markup = try restoreMaterial.blobs.verifiedData(sha256: hash, byteCount: byteCount)
                guard markup.count == byteCount else {
                    throw NotesError("snapshot_integrity_failed", "Scan markup for page \(page.id) failed its integrity check.")
                }
                try NCNotesRuntime.setScanMarkupData(markup, pageIdentifier: newPageID, gallery: gallery)
            }
            if page.hasEmbeddedMarkup {
                guard let restoredPage = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND parentAttachment == %@", newPageID, gallery),
                    in: context,
                    limit: 1
                ).first else {
                    throw NotesError("scan_page_not_found", "The restored scan page disappeared before embedded markup state was applied.")
                }
                try NCNotesRuntime.setValue(true, forKey: "hasMarkupData", of: restoredPage)
                try NCNotesRuntime.updateChangeCount(of: restoredPage, reason: "Restored embedded scan markup")
                try save(context, notes: [note])
            }
            guard !context.hasChanges else {
                throw NotesError("scan_edit_not_committed", "Notes left restored scan metadata unsaved.")
            }
        }
        context.refreshAllObjects()
        var idMap = [scan.parentID: newParentID]
        for (page, newPageID) in zip(scan.pages, newPageIDs) { idMap[page.id] = newPageID }
        return SnapshotScanRestoreResult(idMap: idMap, parentID: newParentID)
    }

    private func paperAccount(_ note: NSManagedObject) throws -> (object: NSManagedObject, identifier: String) {
        guard let folder = value(note, "folder") as? NSManagedObject,
              let account = value(folder, "account") as? NSManagedObject,
              let identifier = value(account, "identifier") as? String,
              !identifier.isEmpty else {
            throw NotesError("account_not_found", "The note has no account for Paper file management.")
        }
        return (account, identifier)
    }

    private static func canonicalPaperURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func paperCleanupScope(_ note: NSManagedObject) throws -> PaperCleanupScope {
        let account = try paperAccount(note)
        let root = Self.canonicalPaperURL(try NCNotesRuntime.paperBundlesDirectoryURL(account: account.object))
        let names = Set(((try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).map { $0.lastPathComponent.lowercased() })
        return PaperCleanupScope(accountID: account.identifier, rootURL: root, bundleNamesBefore: names)
    }

    private func paperCleanupCandidate(_ identifier: String, note: NSManagedObject,
                                       scope suppliedScope: PaperCleanupScope? = nil) throws -> PaperCleanupCandidate {
        guard UUID(uuidString: identifier) != nil else {
            throw NotesError("invalid_paper_identifier", "The generated Paper identifier is not a UUID.")
        }
        let account = try paperAccount(note)
        let scope = try suppliedScope ?? paperCleanupScope(note)
        guard account.identifier.caseInsensitiveCompare(scope.accountID) == .orderedSame else {
            throw NotesError("paper_cleanup_scope_mismatch", "The Paper account changed during restore.")
        }
        let currentRoot = Self.canonicalPaperURL(try NCNotesRuntime.paperBundlesDirectoryURL(account: account.object))
        guard currentRoot == scope.rootURL else {
            throw NotesError("paper_cleanup_scope_mismatch", "The Paper bundle directory changed during restore.")
        }
        let fileURLs = try NCNotesRuntime.paperFileURLs(identifier: identifier, account: account.object)
            .map(Self.canonicalPaperURL)
        guard let bundleURL = fileURLs.first,
              bundleURL.deletingLastPathComponent() == currentRoot,
              bundleURL.lastPathComponent.caseInsensitiveCompare(identifier + ".bundle") == .orderedSame else {
            throw NotesError("unsafe_paper_cleanup_path", "Notes returned an unsafe Paper bundle path.")
        }
        guard scope.bundleNamesBefore.contains(bundleURL.lastPathComponent.lowercased()) == false else {
            throw NotesError("paper_identifier_collision", "The generated Paper bundle path already existed before restore.")
        }
        return PaperCleanupCandidate(
            identifier: identifier,
            accountID: account.identifier,
            rootURL: currentRoot,
            fileURLs: fileURLs
        )
    }

    private func cleanFailedPaperRestores(_ candidates: [PaperCleanupCandidate],
                                          context: NSManagedObjectContext) -> String {
        guard !candidates.isEmpty else { return "" }
        context.reset()
        var failures: [String] = []
        var cleaned: [String] = []
        for candidate in candidates {
            do {
                guard UUID(uuidString: candidate.identifier) != nil else {
                    throw NotesError("invalid_paper_identifier", "The cleanup identifier is not a UUID.")
                }
                let rows = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@", candidate.identifier),
                    in: context,
                    limit: 2
                )
                guard rows.isEmpty else {
                    throw NotesError("paper_cleanup_refused", "A live attachment still uses the generated identifier.")
                }
                guard let account = try fetch(
                    "ICAccount",
                    predicate: NSPredicate(format: "identifier ==[c] %@", candidate.accountID),
                    in: context,
                    limit: 1
                ).first else {
                    throw NotesError("account_not_found", "The Paper account disappeared before cleanup.")
                }
                let root = Self.canonicalPaperURL(try NCNotesRuntime.paperBundlesDirectoryURL(account: account))
                guard root == candidate.rootURL else {
                    throw NotesError("paper_cleanup_scope_mismatch", "The Paper bundle directory changed before cleanup.")
                }
                let currentURLs = try NCNotesRuntime.paperFileURLs(identifier: candidate.identifier, account: account)
                    .map(Self.canonicalPaperURL)
                guard Set(currentURLs.map(\.path)) == Set(candidate.fileURLs.map(\.path)) else {
                    let before = candidate.fileURLs.map(\.path).sorted().joined(separator: ", ")
                    let after = currentURLs.map(\.path).sorted().joined(separator: ", ")
                    throw NotesError("unsafe_paper_cleanup_path", "Notes returned different Paper cleanup paths. before=[\(before)] after=[\(after)]")
                }
                guard let bundleURL = currentURLs.first,
                      bundleURL.deletingLastPathComponent() == root,
                      bundleURL.lastPathComponent.caseInsensitiveCompare(candidate.identifier + ".bundle") == .orderedSame else {
                    throw NotesError("unsafe_paper_cleanup_path", "Notes returned an unsafe Paper bundle path before cleanup.")
                }
                _ = try NCNotesRuntime.purgePaperFiles(identifier: candidate.identifier, account: account)
                let remaining = currentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
                guard remaining.isEmpty else {
                    throw NotesError(
                        "paper_cleanup_incomplete",
                        "Paper files remain after purge: \(remaining.map(\.lastPathComponent).joined(separator: ", "))."
                    )
                }
                cleaned.append(candidate.identifier)
            } catch {
                failures.append("\(candidate.identifier): \(String(describing: error))")
            }
        }
        if failures.isEmpty {
            return "Paper cleanup verified for \(cleaned.joined(separator: ", "))."
        }
        return "Paper cleanup was not fully verified. \(failures.joined(separator: " "))"
    }

    public func restoreSnapshot(_ ref: String, snapshot: Note, allowShared: Bool) throws -> NativeWriteResult {
        try restoreSnapshot(ref, snapshot: snapshot, material: nil, expectedRevision: nil,
                            expectedModified: nil, allowShared: allowShared)
    }

    public func restoreSnapshot(_ ref: String, snapshot: Note,
                                material: SnapshotRestoreMaterial?, expectedRevision: String? = nil,
                                expectedModified: Date? = nil,
                                allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
            guard snapshot.document != nil else {
                throw NotesError("snapshot_locked", "The snapshot has no readable note body.")
            }
            let note = try note(ref, in: context)
            guard snapshot.summary.id.uuid.caseInsensitiveCompare(id(note)) == .orderedSame else {
                throw NotesError("snapshot_note_mismatch", "The snapshot belongs to a different note.")
            }
            try guardWritable(note, allowShared: allowShared, allowTrash: true)
            try refreshIfStale(note)
            try requireRestoreState(id(note), expectedRevision: expectedRevision, expectedModified: expectedModified)
            let currentNestedMarkerIDs = Set(
                (try? SQLiteNotesStore(refresh: true).note(id(note)).document.map(Self.nestedMarkerReferences)) ?? []
            )
            let references = try Self.attachmentReferences(snapshot)
            var existing: [SnapshotRestoreExistingAttachment] = []
            var attachmentObjects: [String: NSManagedObject] = [:]
            let currentReadback = try? SQLiteNotesStore(refresh: true).note(id(note))
            func readbackAttachment(_ identifier: String, in attachments: [Attachment]) -> Attachment? {
                for attachment in attachments {
                    if attachment.id == identifier { return attachment }
                    if let found = readbackAttachment(identifier, in: attachment.childAttachments ?? []) {
                        return found
                    }
                }
                return nil
            }
            func dataEvidence(_ data: Data?) -> SnapshotRestoreDigestEvidence {
                guard let data, !data.isEmpty else { return .absent }
                return .present(SnapshotRestoreDigest(
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    byteCount: data.count
                ))
            }
            func fileEvidence(_ path: String?) -> SnapshotRestoreDigestEvidence {
                guard let path, !path.isEmpty else { return .absent }
                let url = URL(fileURLWithPath: path)
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true,
                      let byteCount = values.fileSize,
                      let sha256 = try? FrozenAttachmentInput.hash(file: url) else { return .notCollected }
                return .present(SnapshotRestoreDigest(sha256: sha256, byteCount: byteCount))
            }
            let archivedIDs = Set(material?.archive.attachments.map(\.id) ?? [])
#if DEBUG
            let forcedAbsentIDs = Set((ProcessInfo.processInfo.environment["NOTESCLI_TEST_TREAT_ABSENT"] ?? "")
                .split(separator: ",").map(String.init))
#else
            let forcedAbsentIDs: Set<String> = []
#endif
            for reference in references {
                let predicate = NSPredicate(format: "identifier == %@", reference.id)
                let fetched = try fetch("ICInlineAttachment", predicate: predicate, in: context) +
                    fetch("ICAttachment", predicate: predicate, in: context)
                var seen: Set<NSManagedObjectID> = []
                for attachment in fetched where seen.insert(attachment.objectID).inserted {
                    if forcedAbsentIDs.contains(reference.id) { continue }
                    let parent = value(attachment, "parentAttachment") as? NSManagedObject
                    let parentID = parent.flatMap { value($0, "identifier") as? String }
                    let belongs = NativeAttachmentOwnership.belongs(attachment, to: note)
                    let type = value(attachment, "typeUTI") as? String ?? ""
                    let readback = currentReadback.flatMap {
                        readbackAttachment(reference.id, in: $0.attachments)
                    }
                    let evidence: SnapshotRestoreExistingEvidence
                    if archivedIDs.contains(reference.id) {
                        var orderedChildIDs = readback?.childAttachmentIDs
                        if type == "com.apple.notes.gallery" {
                            orderedChildIDs = try? NCNotesRuntime.galleryPageIdentifiers(in: attachment)
                        }
                        evidence = SnapshotRestoreExistingEvidence(
                            blob: fileEvidence(readback?.filePath ?? readback?.fallbackRasterPath),
                            paperBundle: .notCollected,
                            synapse: dataEvidence(value(attachment, "synapseData") as? Data),
                            linkMetadata: dataEvidence(value(attachment, "linkPresentationArchivedMetadata") as? Data),
                            scanMarkup: dataEvidence(value(attachment, "markupModelData") as? Data),
                            orderedChildIDs: orderedChildIDs
                        )
                    } else {
                        evidence = SnapshotRestoreExistingEvidence()
                    }
                    existing.append(SnapshotRestoreExistingAttachment(
                        id: reference.id,
                        typeUTI: type,
                        parentID: parentID,
                        belongsToTargetNote: belongs,
                        isMarkedForDeletion: value(attachment, "markedForDeletion") as? Bool == true,
                        evidence: evidence
                    ))
                    if belongs, type == reference.typeUTI,
                       parentID == reference.parentID || parentID == reference.alternateParentID {
                        attachmentObjects[reference.id] = attachment
                    }
                }
            }
            let plan = SnapshotRestorePlanner.plan(
                snapshot: snapshot,
                verifiedArchive: material?.archive,
                existing: existing
            )
            guard plan.canRestore else { throw Self.restorePlanError(plan) }
            try preflightSnapshotDocument(snapshot.document!)
            var selfParagraphLinkIDs: Set<String> = []
            for planned in plan.attachments {
                guard case .recreateInline(let request) = planned.action,
                      case .noteLink(let targetID, let paragraphID?, _, _) = request else { continue }
                let target = try self.note(targetID, in: context)
                guard id(target) == id(note) else { continue }
                _ = try paragraphLinkTarget(paragraphID, in: snapshot.document!)
                selfParagraphLinkIDs.insert(planned.id)
            }
            let prepared = try Self.prepareSnapshotFiles(plan, material: material)
            var restoredSnapshot = snapshot
            var attachmentIDMap: [String: String] = [:]
            var recreatedFileCount = 0
            var recreatedFileIDs: Set<String> = []
            var recreatedFileMarkup: [String: (sha256: String, embedded: Bool)] = [:]
            var recreatedRichLinks: [String: Attachment] = [:]
            var recreatedMaps: [String: Attachment] = [:]
            var recreatedLinkPayloads: [String: (synapseHash: String?, synapseBytes: Int?,
                                                   metadataHash: String?, metadataBytes: Int?)] = [:]
            var recreatedPaperDocuments: [String: (oldID: String, subtype: String,
                                                     material: SnapshotAttachmentMaterial)] = [:]
            var recreatedPaperBundleDrawings: [String: SnapshotAttachmentMaterial] = [:]
            var recreatedDrawings: [String: [[PaperStrokeRecord]]] = [:]
            var recreatedLegacyDrawings: [String: [LegacyDrawingStrokeRecord]] = [:]
            var recreatedInline: [String: (request: SnapshotInlineRecreation, parentID: String?)] = [:]
            var recreatedScans: [String: SnapshotScanRecreation] = [:]
            var recreatedRecordings: [String: SnapshotRecordingRecreation] = [:]
            var pendingScans: [(scan: SnapshotScanRecreation, newParentID: String)] = []
            var paperCleanupCandidates: [PaperCleanupCandidate] = []
            var reservedScanIDs = Set(references.map(\.id))
            for planned in plan.attachments {
                guard case .recreateScan(let scan) = planned.action else { continue }
                var newParentID = UUID().uuidString.lowercased()
                while reservedScanIDs.contains(newParentID) { newParentID = UUID().uuidString.lowercased() }
                reservedScanIDs.insert(newParentID)
                attachmentIDMap[scan.parentID] = newParentID
                pendingScans.append((scan, newParentID))
            }
            do {
                for planned in plan.attachments {
                    switch planned.action {
                    case .keep:
                        guard attachmentObjects[planned.id] != nil else {
                            throw NotesError("snapshot_attachment_unavailable", "Attachment \(planned.id) disappeared before restore.")
                        }
                    case .unmark:
                        guard let attachment = attachmentObjects[planned.id] else {
                            throw NotesError("snapshot_attachment_unavailable", "Attachment \(planned.id) disappeared before restore.")
                        }
                        try NCNotesRuntime.unmarkForDeletion(attachment)
                        if planned.typeUTI.lowercased().contains("hashtag") {
                            try NCNotesRuntime.reviveTagAttachment(attachment)
                        }
                    case .recreateFile, .recreateScan, .recreateRecording, .recreatedByParent, .recreateTable,
                         .recreateRichLink, .recreateMap, .recreatePaperDocument, .recreateDrawing, .recreateInline, .refuse:
                        break
                    }
                }
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["replace"])
                for planned in plan.attachments {
                    switch planned.action {
                    case .recreateFile(let fileMaterial):
                        guard let frozen = prepared[planned.id] else {
                            throw NotesError("snapshot_material_missing", "Attachment \(planned.id) has no prepared snapshot blob.")
                        }
                        var kind: NSString?
                        let newID: String
                        if SnapshotRestoreFilename.requiresExplicitType(fileMaterial) {
                            guard let filename = SnapshotRestoreFilename.forExplicitType(fileMaterial) else {
                                throw NotesError("snapshot_attachment_filename_unsupported",
                                                 "Attachment \(planned.id) has invalid saved type metadata.")
                            }
                            newID = try NCNotesRuntime.addFile(
                                frozen.url,
                                to: note,
                                title: fileMaterial.title ?? fileMaterial.filename ?? frozen.sourceName,
                                typeUTI: planned.typeUTI,
                                filename: filename,
                                resultingType: &kind
                            )
                        } else {
                            newID = try NCNotesRuntime.addFile(
                                frozen.url,
                                to: note,
                                title: fileMaterial.title ?? fileMaterial.filename ?? frozen.sourceName,
                                type: &kind
                            )
                        }
                        let createdType = kind as String? ?? ""
                        guard !newID.isEmpty, createdType == planned.typeUTI else {
                            throw NotesError("snapshot_attachment_type_mismatch", "Notes recreated attachment \(planned.id) as \(createdType), not \(planned.typeUTI).")
                        }
                        guard attachmentIDMap.values.contains(newID) == false,
                              references.contains(where: { $0.id == newID }) == false else {
                            throw NotesError("snapshot_attachment_id_collision", "Notes reused attachment identifier \(newID) during restore.")
                        }
                        guard let created = try fetch(
                            "ICAttachment",
                            predicate: NSPredicate(format: "identifier == %@ AND note == %@", newID, note),
                            in: context,
                            limit: 1
                        ).first else {
                            throw NotesError("snapshot_attachment_unavailable", "Notes created no attachment row for restored attachment \(planned.id).")
                        }
                        if let markupHash = fileMaterial.scanMarkupSHA256,
                           let markupBytes = fileMaterial.scanMarkupByteCount {
                            let markup = try Self.verifiedMarkupPayload(
                                hash: markupHash,
                                byteCount: markupBytes,
                                restoreMaterial: material
                            )
                            let embedded = snapshot.attachments.first(where: { $0.id == planned.id })?
                                .hasEmbeddedMarkup == true
                            try NCNotesRuntime.setValue(markup, forKey: "markupModelData", of: created)
                            try NCNotesRuntime.setValue(embedded, forKey: "hasMarkupData", of: created)
                            try NCNotesRuntime.updateChangeCount(of: created, reason: "Restored editable markup")
                            recreatedFileMarkup[newID] = (markupHash, embedded)
                        }
                        attachmentIDMap[planned.id] = newID
                        attachmentObjects[planned.id] = created
                        recreatedFileCount += 1
                        recreatedFileIDs.insert(planned.id)
                        operation?.childAttachmentIDs.append(newID)
                    case .recreateRecording(let recording):
                        guard recording.fragments.allSatisfy({ prepared[$0.id] != nil }) else {
                            throw NotesError("snapshot_material_missing", "Recording \(planned.id) has an incomplete prepared audio graph.")
                        }
                        let measuredDuration = try recording.fragments.reduce(0.0) { total, fragment in
                            guard let frozen = prepared[fragment.id] else {
                                throw NotesError("snapshot_material_missing", "Recording fragment \(fragment.id) is unavailable.")
                            }
                            return total + (try Self.audioDuration(frozen.url))
                        }
                        guard abs(measuredDuration - recording.duration) <= max(0.25, recording.duration * 0.05) else {
                            throw NotesError("snapshot_recording_duration_mismatch",
                                             "The archived recording fragments do not match the saved total duration.")
                        }
                        let canUseNativeGraphConstructor = recording.fragments.allSatisfy {
                            $0.createdDate != nil && $0.transcriptVersion != nil
                        }
                        let newParentID: String
                        let newChildIDs: [String]
                        let created: NSManagedObject
                        if canUseNativeGraphConstructor {
                            let rows: [[String: Any]] = try recording.fragments.map { fragment in
                                guard let frozen = prepared[fragment.id],
                                      let createdDate = fragment.createdDate,
                                      let transcriptVersion = fragment.transcriptVersion else {
                                    throw NotesError("snapshot_material_missing", "Recording fragment \(fragment.id) is incomplete.")
                                }
                                return [
                                    "url": frozen.url,
                                    "typeUTI": fragment.material.typeUTI,
                                    "filename": fragment.material.filename ?? frozen.sourceName,
                                    "duration": fragment.duration,
                                    "createdDate": createdDate,
                                    "transcriptVersion": transcriptVersion,
                                    "segments": transcriptRows(fragment.transcript),
                                ]
                            }
                            let result = try NCNotesRuntime.createRecording(
                                in: note,
                                fragments: rows,
                                title: snapshot.attachments.first(where: { $0.id == planned.id })?.title,
                                duration: recording.duration
                            )
                            guard let parent = result["parentID"] as? String,
                                  let children = result["childIDs"] as? [String],
                                  let createdType = result["typeUTI"] as? String,
                                  !parent.isEmpty, children.count == recording.fragments.count,
                                  Set(children).count == children.count,
                                  createdType == planned.typeUTI else {
                                throw NotesError("snapshot_attachment_type_mismatch", "Notes could not recreate recording \(planned.id) with its saved graph.")
                            }
                            newParentID = parent
                            newChildIDs = children
                            guard let object = try fetch(
                                "ICAttachment",
                                predicate: NSPredicate(format: "identifier == %@ AND note == %@", parent, note),
                                in: context,
                                limit: 1
                            ).first else {
                                throw NotesError("snapshot_attachment_unavailable", "Notes created no parent row for restored recording \(planned.id).")
                            }
                            created = object
                        } else {
                            guard recording.fragments.count == 1,
                                  let fragment = recording.fragments.first,
                                  let frozen = prepared[fragment.id] else {
                                throw NotesError("snapshot_recording_unsupported", "A recording without complete fragment metadata must contain exactly one fragment.")
                            }
                            var kind: NSString?
                            let parent = try NCNotesRuntime.addFile(
                                frozen.url,
                                to: note,
                                title: snapshot.attachments.first(where: { $0.id == planned.id })?.title ?? frozen.sourceName,
                                type: &kind
                            )
                            let createdType = kind as String? ?? ""
                            guard !parent.isEmpty, createdType == planned.typeUTI else {
                                throw NotesError("snapshot_attachment_type_mismatch", "Notes could not recreate recording \(planned.id) with its saved type.")
                            }
                            guard let object = try fetch(
                                "ICAttachment",
                                predicate: NSPredicate(format: "identifier == %@ AND note == %@", parent, note),
                                in: context,
                                limit: 1
                            ).first else {
                                throw NotesError("snapshot_attachment_unavailable", "Notes created no parent row for restored recording \(planned.id).")
                            }
                            let children = try NCNotesRuntime.transformAudioAttachment(object, duration: recording.duration)
                            guard children.count == 1 else {
                                throw NotesError("snapshot_attachment_id_collision", "Notes did not create one fragment for restored recording \(planned.id).")
                            }
                            if !fragment.transcript.isEmpty {
                                _ = try NCNotesRuntime.appendTranscriptSegments(
                                    transcriptRows(fragment.transcript),
                                    toAudioAttachment: object
                                )
                            }
                            newParentID = parent
                            newChildIDs = children
                            created = object
                        }
                        let newGraphIDs = [newParentID] + newChildIDs
                        guard Set(newGraphIDs).count == newGraphIDs.count,
                              Set(newGraphIDs).isDisjoint(with: Set(attachmentIDMap.values)),
                              newGraphIDs.allSatisfy({ newID in
                                  !references.contains(where: { $0.id == newID })
                              }) else {
                            throw NotesError("snapshot_attachment_id_collision", "Notes reused an attachment identifier while restoring recording \(planned.id).")
                        }
                        if let metadata = recording.metadata {
                            try NCNotesRuntime.applyRecordingMetadata(
                                Self.recordingMetadataPayload(metadata),
                                toAudioAttachment: created
                            )
                        }
                        if let searchText = snapshot.attachments.first(where: { $0.id == recording.parentID })?
                            .additionalIndexableText {
                            try NCNotesRuntime.setValue(searchText, forKey: "additionalIndexableText", of: created)
                        }
                        attachmentIDMap[recording.parentID] = newParentID
                        for (fragment, newChildID) in zip(recording.fragments, newChildIDs) {
                            attachmentIDMap[fragment.id] = newChildID
                        }
                        attachmentObjects[recording.parentID] = created
                        recreatedRecordings[newParentID] = recording
                        operation?.childAttachmentIDs.append(contentsOf: newGraphIDs)
                    case .recreateTable:
                        guard let rows = Self.snapshotTableRows(planned.id, in: snapshot.document!) else {
                            throw NotesError("invalid_snapshot", "Table \(planned.id) has no saved cell grid.")
                        }
                        let rightToLeft = snapshot.attachments.first(where: { $0.id == planned.id })?.tableRightToLeft == true
                        let logicalRows = rightToLeft ? rows.map { Array($0.reversed()) } : rows
                        let plain = logicalRows.map { row in
                            row.map { $0.text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                                .joined(separator: "\t")
                        }.joined(separator: "\n")
                        let newID = try editor.addTable(plain)
                        guard !newID.isEmpty,
                              attachmentIDMap.values.contains(newID) == false,
                              references.contains(where: { $0.id == newID }) == false else {
                            throw NotesError("snapshot_attachment_id_collision", "Notes reused attachment identifier \(newID) during table restore.")
                        }
                        guard let created = try fetch(
                            "ICAttachment",
                            predicate: NSPredicate(format: "identifier == %@ AND note == %@ AND typeUTI == %@",
                                                   newID, note, "com.apple.notes.table"),
                            in: context,
                            limit: 1
                        ).first else {
                            throw NotesError("snapshot_attachment_unavailable", "Notes created no table row for restored table \(planned.id).")
                        }
                        if rightToLeft {
                            let tableEditor = try NCTableEditor(attachment: created)
                            try tableEditor.reverseColumnDirection()
                            try tableEditor.save()
                        }
                        attachmentIDMap[planned.id] = newID
                        attachmentObjects[planned.id] = created
                        operation?.childAttachmentIDs.append(newID)
                    case .recreateRichLink:
                        guard let saved = snapshot.attachments.first(where: { $0.id == planned.id }),
                              let urlString = saved.url, let url = URL(string: urlString) else {
                            throw NotesError("invalid_snapshot", "Rich link \(planned.id) has no valid saved URL.")
                        }
                        var nativeKind: NSString?
                        let newID: String
                        if (saved.synapseDataBytes ?? 0) > 0,
                           let title = saved.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                            newID = try NCNotesRuntime.addSynapseLink(url, title: title, to: note, type: &nativeKind)
                        } else {
                            newID = try NCNotesRuntime.addURL(url, to: note, type: &nativeKind)
                        }
                        let createdType = nativeKind as String? ?? ""
                        guard !newID.isEmpty, createdType == planned.typeUTI,
                              attachmentIDMap.values.contains(newID) == false,
                              references.contains(where: { $0.id == newID }) == false else {
                            throw NotesError("snapshot_attachment_type_mismatch", "Notes could not recreate rich link \(planned.id) with its saved type.")
                        }
                        guard let created = try fetch(
                            "ICAttachment",
                            predicate: NSPredicate(format: "identifier == %@ AND note == %@", newID, note),
                            in: context,
                            limit: 1
                        ).first else {
                            throw NotesError("snapshot_attachment_unavailable", "Notes created no row for restored rich link \(planned.id).")
                        }
                        if let linkMaterial = material?.archive.attachments.first(where: { $0.id == planned.id }),
                           linkMaterial.synapseSHA256 != nil || linkMaterial.linkMetadataSHA256 != nil {
                            let payload = try Self.verifiedLinkPayload(linkMaterial, material: material)
                            try NCNotesRuntime.setValue(payload.synapse, forKey: "synapseData", of: created)
                            try NCNotesRuntime.setValue(payload.metadata, forKey: "linkPresentationArchivedMetadata", of: created)
                            try NCNotesRuntime.updateChangeCount(of: created, reason: "Restored rich-link payload")
                            recreatedLinkPayloads[newID] = (
                                linkMaterial.synapseSHA256, linkMaterial.synapseByteCount,
                                linkMaterial.linkMetadataSHA256, linkMaterial.linkMetadataByteCount
                            )
                        }
                        attachmentIDMap[planned.id] = newID
                        attachmentObjects[planned.id] = created
                        recreatedRichLinks[newID] = saved
                        operation?.childAttachmentIDs.append(newID)
                    case .recreateMap:
                        guard let saved = snapshot.attachments.first(where: { $0.id == planned.id }),
                              let urlString = saved.url, let url = URL(string: urlString) else {
                            throw NotesError("invalid_snapshot", "Map card \(planned.id) has no valid saved URL.")
                        }
                        try NativeMapURL.validate(url)
                        var nativeKind: NSString?
                        let newID = try NCNotesRuntime.addURL(url, to: note, type: &nativeKind)
                        let createdType = nativeKind as String? ?? ""
                        guard !newID.isEmpty, createdType == planned.typeUTI,
                              attachmentIDMap.values.contains(newID) == false,
                              references.contains(where: { $0.id == newID }) == false else {
                            throw NotesError("snapshot_attachment_type_mismatch", "Notes could not recreate map card \(planned.id) with its saved type.")
                        }
                        guard let created = try fetch(
                            "ICAttachment",
                            predicate: NSPredicate(format: "identifier == %@ AND note == %@", newID, note),
                            in: context,
                            limit: 1
                        ).first else {
                            throw NotesError("snapshot_attachment_unavailable", "Notes created no row for restored map card \(planned.id).")
                        }
                        let mapEvidence = try NCNotesRuntime.addLocation(toMapAttachment: created)
                        guard mapEvidence["model"] as? String == "ICAttachmentMapModel",
                              mapEvidence["hasLocation"] as? Bool == true else {
                            throw NotesError("map_metadata_missing", "Notes recreated a URL card without native map metadata.")
                        }
                        if let latitude = saved.mapLatitude, let longitude = saved.mapLongitude,
                           latitude.isFinite, longitude.isFinite,
                           (-90...90).contains(latitude), (-180...180).contains(longitude),
                           let location = value(created, "location") as? NSManagedObject {
                            try NCNotesRuntime.setValue(latitude, forKey: "latitude", of: location)
                            try NCNotesRuntime.setValue(longitude, forKey: "longitude", of: location)
                            if let updated = saved.mapPlaceUpdated {
                                try NCNotesRuntime.setValue(updated, forKey: "placeUpdated", of: location)
                            }
                        }
                        if let title = saved.title, !title.isEmpty {
                            try NCNotesRuntime.setValue(title, forKey: "title", of: created)
                        }
                        if let address = saved.mapAddress, !address.isEmpty {
                            try NCNotesRuntime.setValue(address, forKey: "summary", of: created)
                        }
                        if let linkMaterial = material?.archive.attachments.first(where: { $0.id == planned.id }),
                           linkMaterial.synapseSHA256 != nil || linkMaterial.linkMetadataSHA256 != nil {
                            let payload = try Self.verifiedLinkPayload(linkMaterial, material: material)
                            try NCNotesRuntime.setValue(payload.synapse, forKey: "synapseData", of: created)
                            try NCNotesRuntime.setValue(payload.metadata, forKey: "linkPresentationArchivedMetadata", of: created)
                            recreatedLinkPayloads[newID] = (
                                linkMaterial.synapseSHA256, linkMaterial.synapseByteCount,
                                linkMaterial.linkMetadataSHA256, linkMaterial.linkMetadataByteCount
                            )
                        }
                        try NCNotesRuntime.updateChangeCount(of: created, reason: "Restored map card")
                        attachmentIDMap[planned.id] = newID
                        attachmentObjects[planned.id] = created
                        recreatedMaps[newID] = saved
                        operation?.childAttachmentIDs.append(newID)
                    case .recreatePaperDocument(let paperMaterial, let subtype):
                        var nativeKind: NSString?
                        let newID: String
                        let requestedID = UUID().uuidString.lowercased()
                        let cleanupScope = try paperCleanupScope(note)
                        if paperMaterial.paperBundleArchived {
                            let bundle = try Self.verifiedPaperBundlePayload(paperMaterial, material: material)
                            let cleanup = try paperCleanupCandidate(requestedID, note: note, scope: cleanupScope)
                            paperCleanupCandidates.append(cleanup)
                            operation?.committed = true
                            operation?.noteID = id(note)
                            operation?.attachmentID = requestedID
                            newID = try NCNotesRuntime.addPaperDocument(
                                archive: bundle,
                                subtype: subtype,
                                identifier: requestedID,
                                to: note,
                                type: &nativeKind
                            )
                        } else {
                            guard let frozen = prepared[planned.id] else {
                                throw NotesError("snapshot_material_missing", "Paper document \(planned.id) has no prepared fallback PDF.")
                            }
                            let cleanup = try paperCleanupCandidate(requestedID, note: note, scope: cleanupScope)
                            paperCleanupCandidates.append(cleanup)
                            operation?.committed = true
                            operation?.noteID = id(note)
                            operation?.attachmentID = requestedID
                            newID = try NCNotesRuntime.addPaperDocument(
                                at: frozen.url,
                                subtype: subtype,
                                identifier: requestedID,
                                to: note,
                                type: &nativeKind
                            )
                        }
                        guard newID.caseInsensitiveCompare(requestedID) == .orderedSame else {
                            throw NotesError("paper_identifier_mismatch", "Notes returned a different Paper identifier.")
                        }
                        try TestFault.check("after_paper_helper")
                        let createdType = nativeKind as String? ?? ""
                        guard !newID.isEmpty, createdType == planned.typeUTI,
                              attachmentIDMap.values.contains(newID) == false,
                              references.contains(where: { $0.id == newID }) == false else {
                            throw NotesError("snapshot_attachment_type_mismatch", "Notes could not recreate Paper document \(planned.id) with its saved type.")
                        }
                        guard let created = try fetch(
                            "ICAttachment",
                            predicate: NSPredicate(format: "identifier == %@ AND note == %@", newID, note),
                            in: context,
                            limit: 1
                        ).first else {
                            throw NotesError("snapshot_attachment_unavailable", "Notes created no row for restored Paper document \(planned.id).")
                        }
                        if paperMaterial.paperBundleArchived {
                            let fallback = try NCNotesRuntime.regenerateFallbackPDF(for: created)
                            guard (fallback["byteCount"] as? NSNumber)?.intValue ?? 0 > 0 else {
                                throw NotesError("paper_fallback_generation_failed", "Notes restored the Paper bundle but produced no fallback PDF.")
                            }
                        }
                        attachmentIDMap[planned.id] = newID
                        attachmentObjects[planned.id] = created
                        recreatedPaperDocuments[newID] = (planned.id, subtype, paperMaterial)
                        operation?.childAttachmentIDs.append(newID)
                    case .recreateDrawing(let payload):
                        guard let saved = snapshot.attachments.first(where: { $0.id == planned.id }),
                              payload != nil || saved.drawingSVG != nil else {
                            throw NotesError("invalid_snapshot", "Drawing \(planned.id) has no saved editable source.")
                        }
                        var nativeKind: NSString?
                        let lowerType = planned.typeUTI.lowercased()
                        let isLegacy = lowerType.contains("sketch") ||
                            (lowerType.contains("drawing") && !lowerType.contains("paper"))
                        let newID: String
                        if isLegacy {
                            let records: [LegacyDrawingStrokeRecord]
                            if let payload {
                                guard payload.payloadKind == "legacy-drawing-v1" else {
                                    throw NotesError("invalid_snapshot", "Legacy drawing \(planned.id) has the wrong saved payload type.")
                                }
                                let data = try Self.verifiedSnapshotPayload(payload, material: material)
                                records = try JSONDecoder().decode([LegacyDrawingStrokeRecord].self, from: data)
                            } else {
                                let drawing = try SVGDrawingConverter.drawing(from: Data(saved.drawingSVG!.utf8))
                                records = PaperStrokeRecord.records([drawing]).map(LegacyDrawingStrokeRecord.init)
                            }
                            try LegacyDrawingStrokeRecord.validate(records)
                            let data = try JSONEncoder().encode(records)
                            newID = try NCNotesRuntime.addLegacyDrawing(strokesData: data, to: note, type: &nativeKind)
                            recreatedLegacyDrawings[newID] = records
                        } else {
                            let drawing: PKDrawing?
                            let expectedCanvases: [[PaperStrokeRecord]]
                            if let payload {
                                let data = try Self.verifiedSnapshotPayload(payload, material: material)
                                if payload.payloadKind == "paper-canvases-v1" {
                                    guard payload.paperBundleArchived else {
                                        throw NotesError("invalid_snapshot", "Multi-canvas Paper drawing \(planned.id) has no native Paper bundle.")
                                    }
                                    expectedCanvases = try JSONDecoder().decode([[PaperStrokeRecord]].self, from: data)
                                    guard expectedCanvases.count > 1 else {
                                        throw NotesError("invalid_snapshot", "Multi-canvas Paper drawing \(planned.id) has an invalid canvas payload.")
                                    }
                                    for canvas in expectedCanvases { _ = try PaperStrokeRecord.drawing(canvas) }
                                    drawing = nil
                                } else {
                                    guard payload.payloadKind == "paper-strokes-v1" else {
                                        throw NotesError("invalid_snapshot", "Paper drawing \(planned.id) has the wrong saved payload type.")
                                    }
                                    let records = try JSONDecoder().decode([PaperStrokeRecord].self, from: data)
                                    drawing = try PaperStrokeRecord.drawing(records)
                                    expectedCanvases = [records]
                                }
                            } else {
                                let converted = try SVGDrawingConverter.drawing(from: Data(saved.drawingSVG!.utf8))
                                drawing = converted
                                expectedCanvases = [PaperStrokeRecord.records([converted])]
                            }
                            guard expectedCanvases.allSatisfy({ !$0.isEmpty }) else {
                                throw NotesError("invalid_snapshot", "Drawing \(planned.id) has no restorable strokes.")
                            }
                            if let payload, payload.paperBundleArchived {
                                let bundle = try Self.verifiedPaperBundlePayload(payload, material: material)
                                let requestedID = UUID().uuidString.lowercased()
                                let cleanupScope = try paperCleanupScope(note)
                                let cleanup = try paperCleanupCandidate(requestedID, note: note, scope: cleanupScope)
                                paperCleanupCandidates.append(cleanup)
                                operation?.committed = true
                                operation?.noteID = id(note)
                                operation?.attachmentID = requestedID
                                newID = try NCNotesRuntime.addSystemPaper(
                                    archive: bundle,
                                    identifier: requestedID,
                                    to: note,
                                    type: &nativeKind
                                )
                                guard newID.caseInsensitiveCompare(requestedID) == .orderedSame else {
                                    throw NotesError("paper_identifier_mismatch", "Notes returned a different System Paper identifier.")
                                }
                                try TestFault.check("after_paper_helper")
                                recreatedPaperBundleDrawings[newID] = payload
                            } else {
                                guard let drawing else {
                                    throw NotesError("invalid_snapshot", "Multi-canvas Paper drawing \(planned.id) requires its native Paper bundle.")
                                }
                                let cleanupScope = try paperCleanupScope(note)
                                operation?.committed = true
                                operation?.noteID = id(note)
                                newID = try NCNotesRuntime.addSystemPaperDrawing(
                                    drawing as AnyObject,
                                    to: note,
                                    type: &nativeKind
                                )
                                operation?.attachmentID = newID
                                paperCleanupCandidates.append(
                                    try paperCleanupCandidate(newID, note: note, scope: cleanupScope)
                                )
                                try TestFault.check("after_paper_helper")
                            }
                            recreatedDrawings[newID] = expectedCanvases
                        }
                        let createdType = nativeKind as String? ?? ""
                        guard !newID.isEmpty, createdType == planned.typeUTI,
                              attachmentIDMap.values.contains(newID) == false,
                              references.contains(where: { $0.id == newID }) == false else {
                            throw NotesError("snapshot_attachment_type_mismatch", "Notes could not recreate drawing \(planned.id) with its saved type.")
                        }
                        guard let created = try fetch(
                            "ICAttachment",
                            predicate: NSPredicate(format: "identifier == %@ AND note == %@", newID, note),
                            in: context,
                            limit: 1
                        ).first else {
                            throw NotesError("snapshot_attachment_unavailable", "Notes created no row for restored drawing \(planned.id).")
                        }
                        attachmentIDMap[planned.id] = newID
                        attachmentObjects[planned.id] = created
                        operation?.childAttachmentIDs.append(newID)
                    case .recreateInline(let request):
                        var nativeKind: NSString?
                        let newID: String
                        let savedParentID = Self.savedTableParentID(for: planned.id, in: snapshot.document!)
                        let parent = try savedParentID.map { tableID -> NSManagedObject in
                            guard let table = attachmentObjects[tableID] else {
                                throw NotesError("snapshot_attachment_unavailable", "The parent table for inline object \(planned.id) is unavailable.")
                            }
                            return table
                        }
                        switch request {
                        case .hashtag(let name):
                            newID = try NCNotesRuntime.makeTag(name, in: note, parent: parent)
                            nativeKind = "com.apple.notes.inlinetextattachment.hashtag"
                        case .noteLink(let targetID, let paragraphID, let paragraphName, let text):
                            let target = try self.note(targetID, in: context)
                            if let paragraphID {
                                let paragraph = selfParagraphLinkIDs.contains(planned.id)
                                    ? try paragraphLinkTarget(paragraphID, in: snapshot.document!)
                                    : try paragraphLinkTarget(paragraphID, in: target)
                                newID = try NCNotesRuntime.makeParagraphLink(
                                    to: target, paragraphName: paragraphName ?? paragraph.name,
                                    paragraphID: paragraph.id, from: note, text: text, parent: parent
                                )
                            } else {
                                newID = try NCNotesRuntime.makeNoteLink(to: target, from: note, text: text, parent: parent)
                            }
                            nativeKind = "com.apple.notes.inlinetextattachment.link"
                        case .divider:
                            newID = try NCNotesRuntime.makeDivider(in: note, parent: parent, type: &nativeKind)
                        case .math(let expression):
                            newID = try NCNotesRuntime.makeMathExpression(expression, in: note, parent: parent, type: &nativeKind)
                        case .mention(let text, let userRecordName):
                            guard isShared(note) else {
                                throw NotesError("mention_requires_shared_note", "A saved mention can only be restored in its shared note.")
                            }
                            newID = try NCNotesRuntime.makeMention(text, userRecordName: userRecordName,
                                                                  in: note, parent: parent, type: &nativeKind)
                        }
                        let createdType = nativeKind as String? ?? ""
                        guard !newID.isEmpty, createdType == planned.typeUTI,
                              attachmentIDMap.values.contains(newID) == false,
                              references.contains(where: { $0.id == newID }) == false else {
                            throw NotesError("snapshot_attachment_type_mismatch", "Notes could not recreate inline object \(planned.id) with its saved type.")
                        }
                        guard let created = try fetch(
                            "ICInlineAttachment",
                            predicate: NSPredicate(format: "identifier == %@ AND note == %@", newID, note),
                            in: context,
                            limit: 1
                        ).first else {
                            throw NotesError("snapshot_attachment_unavailable", "Notes created no row for restored inline object \(planned.id).")
                        }
                        attachmentIDMap[planned.id] = newID
                        attachmentObjects[planned.id] = created
                        recreatedInline[newID] = (request, savedParentID)
                        operation?.childAttachmentIDs.append(newID)
                    case .keep, .unmark, .recreateScan, .recreatedByParent, .refuse:
                        break
                    }
                }
#if DEBUG
                for oldID in forcedAbsentIDs where references.contains(where: { $0.id == oldID }) {
                    let predicate = NSPredicate(format: "identifier == %@", oldID)
                    let stale = try fetch("ICInlineAttachment", predicate: predicate, in: context) +
                        fetch("ICAttachment", predicate: predicate, in: context)
                    for attachment in stale where NativeAttachmentOwnership.belongs(attachment, to: note) {
                        try NCNotesRuntime.markForDeletion(attachment)
                    }
                }
#endif
                if let tables = snapshot.document?.tables {
                    for attachmentID in tables.keys where snapshot.document?.tableCells?[attachmentID] == nil {
                        guard let attachment = attachmentObjects[attachmentID],
                              let rows = Self.snapshotTableRows(attachmentID, in: snapshot.document!) else {
                            throw NotesError("snapshot_attachment_unavailable", "Table \(attachmentID) is no longer available for restore.")
                        }
                        let rightToLeft = snapshot.attachments.first(where: { $0.id == attachmentID })?.tableRightToLeft == true
                        try restoreTable(Self.remapTableRows(rows, attachmentIDs: attachmentIDMap), attachment: attachment,
                                         rightToLeft: rightToLeft)
                    }
                }
                if let tables = snapshot.document?.tableCells {
                    for (attachmentID, rows) in tables {
                        guard let attachment = attachmentObjects[attachmentID] else {
                            throw NotesError("snapshot_attachment_unavailable", "Table \(attachmentID) is no longer available for restore.")
                        }
                        let rightToLeft = snapshot.attachments.first(where: { $0.id == attachmentID })?.tableRightToLeft == true
                        try restoreTable(Self.remapTableRows(rows, attachmentIDs: attachmentIDMap), attachment: attachment,
                                         rightToLeft: rightToLeft)
                    }
                }
                var handwritingByID: [String: Attachment] = [:]
                for attachment in Self.flattenAttachments(snapshot.attachments) {
                    handwritingByID[attachment.id] = attachment
                }
                for (savedID, saved) in handwritingByID {
                    let type = saved.typeUTI.lowercased()
                    guard type.contains("paper") || type.contains("drawing") || type.contains("sketch") else { continue }
                    guard let attachment = attachmentObjects[savedID] else {
                        throw NotesError("snapshot_attachment_unavailable", "Drawing \(savedID) is unavailable for handwriting restore.")
                    }
                    let expected = saved.handwritingText ?? ""
                    let current = self.value(attachment, "handwritingSummary") as? String ?? ""
                    if current != expected {
                        _ = try NCNotesRuntime.setHandwritingSummary(expected.isEmpty ? nil : expected, attachment: attachment)
                    }
                }
                for (savedID, saved) in handwritingByID where NativeImageMetadata.isImage(typeUTI: saved.typeUTI) {
                    guard let attachment = attachmentObjects[savedID] else {
                        throw NotesError("snapshot_attachment_unavailable", "Image \(savedID) is unavailable for metadata restore.")
                    }
                    let currentOCR = self.value(attachment, "ocrSummary") as? String
                    let currentOCRVersion = (self.value(attachment, "ocrSummaryVersion") as? NSNumber)?.intValue ?? 0
                    if currentOCR != saved.ocrText ||
                        (saved.ocrSummaryVersion.map { $0 != currentOCRVersion } ??
                         !NativeImageMetadata.versionMatches(summary: saved.ocrText, version: currentOCRVersion)) {
                        _ = try NCNotesRuntime.setOCRSummary(saved.ocrText,
                            version: saved.ocrSummaryVersion ?? (saved.ocrText == nil ? 0 : 1), attachment: attachment)
                    }
                    let currentLabels = self.value(attachment, "imageClassificationSummary") as? String
                    let currentLabelVersion = (self.value(attachment, "imageClassificationSummaryVersion") as? NSNumber)?.intValue ?? 0
                    if currentLabels != saved.imageClassification ||
                        (saved.imageClassificationSummaryVersion.map { $0 != currentLabelVersion } ??
                         !NativeImageMetadata.versionMatches(summary: saved.imageClassification, version: currentLabelVersion)) {
                        _ = try NCNotesRuntime.setImageClassificationSummary(saved.imageClassification,
                            version: saved.imageClassificationSummaryVersion ?? (saved.imageClassification == nil ? 0 : 4),
                            attachment: attachment)
                    }
                }
                guard let snapshotDocument = snapshot.document else {
                    throw NotesError("snapshot_locked", "The snapshot has no readable note body.")
                }
                var document = SnapshotAttachmentIDRemapper.remapDocument(
                    snapshotDocument,
                    attachmentIDs: attachmentIDMap
                )
                let built = try attributed(document)
                let oldMarkers = attachmentMarkers(editor.original)
                try editor.begin(["replace"])
                try editor.replace(NSRange(location: 0, length: editor.original.length), with: built.text)
                try editor.finish()
                let pendingSelfLinks = attachmentIDMap.compactMap { savedID, provisionalID ->
                    (savedID: String, provisionalID: String,
                     recreation: (request: SnapshotInlineRecreation, parentID: String?))? in
                    guard selfParagraphLinkIDs.contains(savedID),
                          let recreation = recreatedInline[provisionalID],
                          case .noteLink(_, let paragraphID, _, _) = recreation.request,
                          paragraphID != nil else { return nil }
                    return (savedID, provisionalID, recreation)
                }.sorted { $0.savedID < $1.savedID }

                for (newID, recreation) in recreatedInline {
                    guard case .noteLink(_, _, _, let text) = recreation.request,
                          let attachment = try fetch(
                            "ICInlineAttachment",
                            predicate: NSPredicate(format: "identifier == %@ AND note == %@", newID, note),
                            in: context,
                            limit: 1
                          ).first,
                          value(attachment, "altText") as? String != text else { continue }
                    try NCNotesRuntime.setValue(text, forKey: "altText", of: attachment)
                    try NCNotesRuntime.updateChangeCount(of: attachment, reason: "Restored note link label")
                }

                if title(note) != snapshot.summary.title {
                    try NCNotesRuntime.setValue(snapshot.summary.title, forKey: "title", of: note)
                    if note.entity.propertiesByName["dateForLastTitleModification"] != nil {
                        try NCNotesRuntime.setValue(Date(), forKey: "dateForLastTitleModification", of: note)
                    }
                    try NCNotesRuntime.updateChangeCount(of: note, reason: "Restored note title")
                }
                if (value(note, "isPinned") as? Bool == true) != snapshot.summary.isPinned {
                    try NCNotesRuntime.setPinned(snapshot.summary.isPinned, note: note)
                }

                if !built.collapsedParagraphIDs.isEmpty {
                    try require(["setOutlineStateData:"], of: note)
                    let data = try NCNotesRuntime.outlineStateData(collapsedUUIDStrings: built.collapsedParagraphIDs.sorted())
                    try NCNotesRuntime.setValue(data, forKey: "outlineStateData", of: note)
                } else if document.collapsedParagraphIDs?.isEmpty == false {
                    throw NotesError("snapshot_restore_failed", "Collapsed headings could not be rebuilt from the snapshot.")
                } else if value(note, "outlineStateData") != nil {
                    let data = try NCNotesRuntime.outlineStateData(collapsedUUIDStrings: [])
                    try NCNotesRuntime.setValue(data, forKey: "outlineStateData", of: note)
                }
                let kept = Set(Self.markerReferences(document).map(\.id))
                for old in oldMarkers where !kept.contains(old.2) {
                    let predicate = NSPredicate(format: "identifier == %@ AND note == %@", old.2, note)
                    let inline = try fetch("ICInlineAttachment", predicate: predicate, in: context, limit: 1).first
                    let regular = try fetch("ICAttachment", predicate: predicate, in: context, limit: 1).first
                    if let object = inline ?? regular {
                        try NCNotesRuntime.markForDeletion(object)
                    }
                }
                for staleID in currentNestedMarkerIDs where !kept.contains(staleID) {
                    let predicate = NSPredicate(format: "identifier == %@ AND note == %@", staleID, note)
                    let inline = try fetch("ICInlineAttachment", predicate: predicate, in: context, limit: 1).first
                    let regular = try fetch("ICAttachment", predicate: predicate, in: context, limit: 1).first
                    if let object = inline ?? regular {
                        try NCNotesRuntime.markForDeletion(object)
                    }
                }
                for oldID in recreatedFileIDs {
                    guard let attachment = attachmentObjects[oldID],
                          let expected = prepared[oldID]?.sha256 else {
                        throw NotesError("snapshot_attachment_unavailable", "A restored attachment disappeared before byte verification.")
                    }
                    try corruptStagedAttachmentIfRequested(attachment, savedID: oldID)
                    _ = try stagedAttachmentHash(attachment, expected: expected)
                }
                for recording in recreatedRecordings.values {
                    for fragment in recording.fragments {
                        guard let newID = attachmentIDMap[fragment.id],
                              let expected = prepared[fragment.id]?.sha256,
                              let attachment = try fetch(
                                "ICAttachment",
                                predicate: NSPredicate(format: "identifier == %@ AND note == %@", newID, note),
                                in: context,
                                limit: 1
                              ).first else {
                            throw NotesError("snapshot_attachment_unavailable", "A restored recording fragment disappeared before byte verification.")
                        }
                        try corruptStagedAttachmentIfRequested(attachment, savedID: fragment.id)
                        _ = try stagedAttachmentHash(attachment, expected: expected)
                    }
                }
                try TestFault.check("before_restore_save")
                try requireRestoreState(id(note), expectedRevision: expectedRevision, expectedModified: expectedModified)
                for pending in pendingScans {
                    let otherNewIDs = Set(attachmentIDMap.values).subtracting([pending.newParentID])
                    let restored = try recreateSnapshotScan(
                        pending.scan,
                        newParentID: pending.newParentID,
                        note: note,
                        context: context,
                        prepared: prepared,
                        restoreMaterial: material,
                        snapshotDocument: snapshot.document!,
                        reservedIDs: Set(references.map(\.id)).union(otherNewIDs)
                    )
                    guard restored.idMap[pending.scan.parentID] == pending.newParentID,
                          Set(restored.idMap.values).count == restored.idMap.count,
                          Set(restored.idMap.values).subtracting([pending.newParentID])
                            .isDisjoint(with: Set(attachmentIDMap.values)) else {
                        throw NotesError("snapshot_attachment_id_collision", "A restored scan reused an attachment identifier.")
                    }
                    for (oldID, newID) in restored.idMap {
                        if oldID != pending.scan.parentID, attachmentIDMap[oldID] != nil {
                            throw NotesError("snapshot_attachment_id_collision", "A restored scan reused a saved attachment identifier.")
                        }
                        attachmentIDMap[oldID] = newID
                    }
                    recreatedScans[restored.parentID] = pending.scan
                }
                if pendingScans.isEmpty || context.hasChanges { try save(context, notes: [note]) }
                paperCleanupCandidates.removeAll()
                if !pendingSelfLinks.isEmpty {
                    var reservedIDs = Set(attachmentIDMap.values)
                    var finalized: [(savedID: String, provisionalID: String, finalID: String,
                                     finalObject: NSManagedObject,
                                     recreation: (request: SnapshotInlineRecreation, parentID: String?))] = []
                    for pending in pendingSelfLinks {
                        guard case .noteLink(_, let paragraphID?, let paragraphName, let text) = pending.recreation.request else {
                            continue
                        }
                        let parent = try pending.recreation.parentID.map { savedParentID -> NSManagedObject in
                            guard let object = attachmentObjects[savedParentID] else {
                                throw NotesError(
                                    "snapshot_attachment_unavailable",
                                    "The parent table for inline object \(pending.savedID) is unavailable."
                                )
                            }
                            return object
                        }
                        let paragraph = try paragraphLinkTarget(paragraphID, in: note)
                        let finalID = try NCNotesRuntime.makeParagraphLink(
                            to: note,
                            paragraphName: paragraphName ?? paragraph.name,
                            paragraphID: paragraph.id,
                            from: note,
                            text: text,
                            parent: parent
                        )
                        guard !finalID.isEmpty,
                              finalID != pending.provisionalID,
                              reservedIDs.insert(finalID).inserted,
                              references.contains(where: { $0.id == finalID }) == false,
                              let finalObject = try fetch(
                                "ICInlineAttachment",
                                predicate: NSPredicate(format: "identifier == %@ AND note == %@", finalID, note),
                                in: context,
                                limit: 1
                              ).first,
                              let provisionalObject = try fetch(
                                "ICInlineAttachment",
                                predicate: NSPredicate(format: "identifier == %@ AND note == %@", pending.provisionalID, note),
                                in: context,
                                limit: 1
                              ).first else {
                            throw NotesError(
                                "snapshot_attachment_unavailable",
                                "Notes could not finalize self paragraph link \(pending.savedID)."
                            )
                        }
                        try replaceSnapshotInlineMarker(
                            pending.provisionalID,
                            with: finalID,
                            note: note,
                            parent: parent
                        )
                        try NCNotesRuntime.markForDeletion(provisionalObject)
                        finalized.append((pending.savedID, pending.provisionalID, finalID,
                                          finalObject, pending.recreation))
                    }
                    try save(context, notes: [note])
                    for row in finalized {
                        attachmentIDMap[row.savedID] = row.finalID
                        attachmentObjects[row.savedID] = row.finalObject
                        if let index = operation?.childAttachmentIDs.firstIndex(of: row.provisionalID) {
                            operation?.childAttachmentIDs[index] = row.finalID
                        }
                        recreatedInline.removeValue(forKey: row.provisionalID)
                        recreatedInline[row.finalID] = row.recreation
                    }
                }
                document = SnapshotAttachmentIDRemapper.remapDocument(
                    snapshotDocument,
                    attachmentIDs: attachmentIDMap
                )
                restoredSnapshot = try SnapshotAttachmentIDRemapper.remap(
                    snapshot,
                    attachmentIDs: attachmentIDMap
                )
            } catch {
                context.rollback()
                let failure = (error as? NotesError) ?? nativeError(error)
                let cleanup = cleanFailedPaperRestores(paperCleanupCandidates, context: context)
                guard !cleanup.isEmpty else { throw failure }
                throw NotesError(failure.code, "\(failure.message) \(cleanup)")
            }
            let restoredNoteID = id(note)
            context.reset()
            let fresh = try self.note(restoredNoteID, in: context)
            let nativeBody = try body(fresh)
            let nativeMarkers = attachmentMarkers(nativeBody).map { ($0.2, $0.3) }
            let document = restoredSnapshot.document!
            let expectedMarkers = Self.topLevelMarkerReferences(document)
            let expectedMarkerPairs = expectedMarkers.map { ($0.id, $0.typeUTI) }
            let drawingsVerified = try recreatedDrawings.allSatisfy { id, expected in
                guard let attachment = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", id, fresh),
                    in: context,
                    limit: 1
                ).first else { return false }
                let actual = try readBackDrawingCanvases(attachment)
                guard actual.count == expected.count else { return false }
                return zip(expected, actual).allSatisfy {
                    PaperStrokeRecord.mismatch(expected: $0, actual: $1) == nil
                }
            }
            let legacyDrawingsVerified = try recreatedLegacyDrawings.allSatisfy { id, expected in
                guard let attachment = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", id, fresh),
                    in: context,
                    limit: 1
                ).first else { return false }
                let data = try legacyDrawingPayload(attachment, identifier: id)
                let actual = try JSONDecoder().decode([LegacyDrawingStrokeRecord].self, from: data)
                return LegacyDrawingStrokeRecord.mismatch(expected: expected, actual: actual) == nil
            }
            let paperDocumentsVerified = try recreatedPaperDocuments.allSatisfy { newID, recreation in
                guard let attachment = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", newID, fresh),
                    in: context,
                    limit: 1
                ).first,
                      value(attachment, "typeUTI") as? String ==
                        (recreation.subtype == "scan" ? "com.apple.paper.doc.scan" : "com.apple.paper.doc.pdf") else {
                    return false
                }
                let rawURL = value(attachment, "fallbackPDFURL")
                let fallbackURL = (rawURL as? URL) ?? (rawURL as? NSURL).map { $0 as URL }
                guard let fallbackURL, FileManager.default.fileExists(atPath: fallbackURL.path),
                      let restoredPages = try? Self.pdfPageEvidence(fallbackURL),
                      !restoredPages.isEmpty else { return false }
                if recreation.material.paperBundleArchived {
                    let expected = try Self.verifiedPaperBundlePayload(recreation.material, material: material)
                    let archive = try NCNotesRuntime.archivePaperBundle(for: attachment)
                    guard let expectedSignature = Self.paperBundleSignature(expected),
                          let actualSignature = Self.paperBundleSignature(archive),
                          actualSignature == expectedSignature else { return false }
                }
                guard let source = prepared[recreation.oldID]?.url else {
                    return recreation.material.paperBundleArchived
                }
                let expectedPages = try Self.pdfPageEvidence(source)
                return expectedPages.count == restoredPages.count &&
                    zip(expectedPages, restoredPages).allSatisfy { $0.visuallyMatches($1) }
            }
            let paperBundleDrawingsVerified = try recreatedPaperBundleDrawings.allSatisfy { id, payload in
                guard let attachment = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", id, fresh),
                    in: context,
                    limit: 1
                ).first else { return false }
                let expected = try Self.verifiedPaperBundlePayload(payload, material: material)
                let actual = try NCNotesRuntime.archivePaperBundle(for: attachment)
                guard let expectedSignature = Self.paperBundleSignature(expected),
                      let actualSignature = Self.paperBundleSignature(actual) else { return false }
                return actualSignature == expectedSignature
            }
            let archivedPaperBundlesVerified = try (material?.archive.attachments ?? [])
                .filter(\.paperBundleArchived)
                .allSatisfy { payload in
                    let restoredID = attachmentIDMap[payload.id] ?? payload.id
                    guard let attachment = try fetch(
                        "ICAttachment",
                        predicate: NSPredicate(format: "identifier == %@ AND note == %@", restoredID, fresh),
                        in: context,
                        limit: 1
                    ).first else { return false }
                    let expected = try Self.verifiedPaperBundlePayload(payload, material: material)
                    let actual = try NCNotesRuntime.archivePaperBundle(for: attachment)
                    guard let expectedSignature = Self.paperBundleSignature(expected),
                          let actualSignature = Self.paperBundleSignature(actual) else { return false }
                    return actualSignature == expectedSignature
                }
            let fileMarkupVerified = try recreatedFileMarkup.allSatisfy { id, expected in
                guard let attachment = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", id, fresh),
                    in: context,
                    limit: 1
                ).first,
                      let data = value(attachment, "markupModelData") as? Data,
                      !data.isEmpty else { return false }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let embedded = (value(attachment, "hasMarkupData") as? NSNumber)?.boolValue ?? false
                return hash == expected.sha256 && embedded == expected.embedded
            }
            let linkPayloadsVerified = try recreatedLinkPayloads.allSatisfy { id, expected in
                guard let attachment = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", id, fresh),
                    in: context,
                    limit: 1
                ).first else { return false }
                func matches(_ value: Any?, hash expectedHash: String?, bytes expectedBytes: Int?) -> Bool {
                    guard expectedHash != nil || expectedBytes != nil else { return value == nil || (value as? Data)?.isEmpty != false }
                    guard let expectedHash, let expectedBytes, let data = value as? Data,
                          data.count == expectedBytes else { return false }
                    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expectedHash
                }
                return matches(value(attachment, "synapseData"),
                               hash: expected.synapseHash, bytes: expected.synapseBytes) &&
                    matches(value(attachment, "linkPresentationArchivedMetadata"),
                            hash: expected.metadataHash, bytes: expected.metadataBytes)
            }
            let scansVerified = try recreatedScans.allSatisfy { newParentID, scan in
                guard let gallery = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", newParentID, fresh),
                    in: context,
                    limit: 1
                ).first else { return false }
                let expectedPageIDs = scan.pages.compactMap { attachmentIDMap[$0.id] }
                guard expectedPageIDs.count == scan.pages.count,
                      try NCNotesRuntime.galleryPageIdentifiers(in: gallery) == expectedPageIDs else { return false }
                for (page, newPageID) in zip(scan.pages, expectedPageIDs) {
                    let state = try scanPageState(restoredNoteID, attachmentID: newParentID, pageID: newPageID, in: context)
                    let expectedCrop: ScanCrop?
                    if let crop = page.crop, let frozen = prepared[page.id],
                       let size = Self.scanImagePixelSize(frozen.url) {
                        expectedCrop = Self.normalizedScanCrop(crop, pixelWidth: size.width, pixelHeight: size.height)
                    } else { expectedCrop = nil }
                    guard state.filter.value == page.filter,
                          state.orientation.value == page.orientation,
                          NativeVerificationRules.sameScanCrop(state.crop, expectedCrop),
                          state.hasMarkup == (page.markupSHA256 != nil),
                          state.hasEmbeddedMarkup == page.hasEmbeddedMarkup else { return false }
                }
                return true
            }
            let recordingsVerified = try recreatedRecordings.allSatisfy { newParentID, recording in
                guard let parent = try fetch(
                    "ICAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", newParentID, fresh),
                    in: context,
                    limit: 1
                ).first,
                let children = value(parent, "subAttachments") as? NSSet,
                children.count == recording.fragments.count,
                abs(((value(parent, "duration") as? NSNumber)?.doubleValue ?? 0) - recording.duration) < 0.05 else {
                    return false
                }
                let expectedIDs = recording.fragments.compactMap { attachmentIDMap[$0.id] }
                guard expectedIDs.count == recording.fragments.count else { return false }
                let childObjects = children.compactMap { $0 as? NSManagedObject }
                guard Set(childObjects.compactMap { value($0, "identifier") as? String }) == Set(expectedIDs) else {
                    return false
                }
                return childObjects.allSatisfy { child in
                    guard let childID = value(child, "identifier") as? String,
                          let fragment = recording.fragments.first(where: { attachmentIDMap[$0.id] == childID }),
                          abs(((value(child, "duration") as? NSNumber)?.doubleValue ?? 0) - fragment.duration) < 0.05 else {
                        return false
                    }
                    let parentObject = value(child, "parentAttachment") as? NSManagedObject
                    return (parentObject.flatMap { value($0, "identifier") as? String }) == newParentID
                }
            }
            let inlineParentsVerified = try recreatedInline.allSatisfy { newID, recreation in
                guard let object = try fetch(
                    "ICInlineAttachment",
                    predicate: NSPredicate(format: "identifier == %@ AND note == %@", newID, fresh),
                    in: context,
                    limit: 1
                ).first else { return false }
                let actualParent = (value(object, "parentAttachment") as? NSManagedObject)
                    .flatMap { value($0, "identifier") as? String }
                return actualParent == recreation.parentID.map { attachmentIDMap[$0] ?? $0 }
            }
            var restoredHashes: [String: String] = [:]
            for oldID in recreatedFileIDs {
                guard let newID = attachmentIDMap[oldID] else { continue }
                guard let expected = prepared[oldID]?.sha256,
                      let stored = storedAttachmentHash(noteID: restoredNoteID, attachmentID: newID, expected: expected) else { continue }
                restoredHashes[oldID] = stored
            }
            var restoredRecordingHashes: [String: String] = [:]
            for recording in recreatedRecordings.values {
                for fragment in recording.fragments {
                    guard let newChildID = attachmentIDMap[fragment.id],
                          let expected = prepared[fragment.id]?.sha256,
                          let stored = storedAttachmentHash(noteID: restoredNoteID, attachmentID: newChildID, expected: expected) else { continue }
                    restoredRecordingHashes[fragment.id] = stored
                }
            }
            let recreatedRecordingFragmentCount = recreatedRecordings.values.reduce(0) { $0 + $1.fragments.count }
            let idMapJSON = try Self.sortedJSON(attachmentIDMap)
            let hashesJSON = try Self.sortedJSON(restoredHashes.merging(restoredRecordingHashes) { current, _ in current })
            let bodyVerified = nativeBody.string == document.text
            let markersVerified = NativeVerificationRules.sameMarkerMultiset(expectedMarkerPairs, nativeMarkers)
            let filesVerified = restoredHashes.count == recreatedFileCount
            let recordingFilesVerified = restoredRecordingHashes.count == recreatedRecordingFragmentCount
            return result(
                restoredNoteID,
                native: ["utf16Length": "\(nativeBody.length)", "markerCount": "\(expectedMarkers.count)",
                         "attachmentIDMap": idMapJSON, "restoredSHA256": hashesJSON,
                         "bodyVerified": String(bodyVerified),
                         "markersVerified": String(markersVerified),
                         "scansVerified": String(scansVerified),
                         "inlineParentsVerified": String(inlineParentsVerified),
                         "paperDocumentsVerified": String(paperDocumentsVerified),
                         "paperBundleDrawingsVerified": String(paperBundleDrawingsVerified),
                         "archivedPaperBundlesVerified": String(archivedPaperBundlesVerified)],
                nativeVerified: bodyVerified && markersVerified && filesVerified && recordingFilesVerified &&
                    drawingsVerified && legacyDrawingsVerified && paperDocumentsVerified && paperBundleDrawingsVerified &&
                    archivedPaperBundlesVerified &&
                    fileMarkupVerified && linkPayloadsVerified && scansVerified &&
                    recordingsVerified && inlineParentsVerified,
                sqlite: { restored in
                    func nestedAttachment(_ id: String, in attachments: [Attachment]) -> Attachment? {
                        for attachment in attachments {
                            if attachment.id == id { return attachment }
                            if let found = nestedAttachment(id, in: attachment.childAttachments ?? []) { return found }
                        }
                        return nil
                    }
                    let snapshotSQLiteVerified = SnapshotRestoreVerification.matches(
                        expected: restoredSnapshot,
                        actual: restored,
                        archive: material?.archive,
                        attachmentIDMap: attachmentIDMap
                    )
                    guard snapshotSQLiteVerified,
                          restoredHashes.count == recreatedFileCount,
                          recreatedRichLinks.allSatisfy({ newID, expected in
                              restored.attachments.contains(where: { actual in
                                  actual.id == newID && actual.typeUTI == expected.typeUTI &&
                                      actual.url == expected.url &&
                                      ((expected.synapseDataBytes ?? 0) == 0 || (actual.synapseDataBytes ?? 0) > 0)
                              })
                          }),
                          recreatedMaps.allSatisfy({ newID, expected in
                              restored.attachments.contains(where: { actual in
                                  actual.id == newID && actual.typeUTI == expected.typeUTI &&
                                      actual.url == expected.url && actual.hasMapLocation == true &&
                                      (expected.mapLatitude == nil || abs((actual.mapLatitude ?? .infinity) - expected.mapLatitude!) < 0.000000001) &&
                                      (expected.mapLongitude == nil || abs((actual.mapLongitude ?? .infinity) - expected.mapLongitude!) < 0.000000001) &&
                                      (expected.mapAddress == nil || actual.mapAddress == expected.mapAddress)
                              }) && ((try? SQLiteNotesStore(refresh: true).attachmentHasStoredLocation(
                                  note: restored.summary.id.uuid,
                                  attachmentID: newID
                              )) == true)
                          }),
                          recreatedLinkPayloads.allSatisfy({ newID, expected in
                              guard let actual = restored.attachments.first(where: { $0.id == newID }) else { return false }
                              return actual.synapseDataBytes == expected.synapseBytes &&
                                  actual.linkPreviewMetadataBytes == expected.metadataBytes
                          }),
                          recreatedDrawings.keys.allSatisfy({ newID in
                              restored.attachments.contains(where: { $0.id == newID && $0.kind == "drawing" })
                          }),
                          recreatedLegacyDrawings.keys.allSatisfy({ newID in
                              restored.attachments.contains(where: {
                                  $0.id == newID && $0.typeUTI == "com.apple.notes.sketch"
                              })
                          }),
                          recreatedFileMarkup.allSatisfy({ newID, expected in
                              guard let actual = restored.attachments.first(where: { $0.id == newID }),
                                    actual.hasEmbeddedMarkup == expected.embedded,
                                    let payload = try? SQLiteNotesStore(refresh: true)
                                        .scanMarkupPayloads(restored.summary.id.uuid)[newID] else { return false }
                              return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined() == expected.sha256
                          }),
                          recreatedPaperDocuments.allSatisfy({ newID, recreation in
                              guard let actual = restored.attachments.first(where: { $0.id == newID }),
                                    actual.typeUTI == (recreation.subtype == "scan"
                                        ? "com.apple.paper.doc.scan" : "com.apple.paper.doc.pdf"),
                                    let path = actual.filePath ?? actual.fallbackRasterPath,
                                    let actualPages = try? Self.pdfPageEvidence(URL(fileURLWithPath: path)),
                                    !actualPages.isEmpty else {
                                  return false
                              }
                              guard let source = prepared[recreation.oldID]?.url,
                                    let expectedPages = try? Self.pdfPageEvidence(source) else {
                                  return recreation.material.paperBundleArchived
                              }
                              return expectedPages.count == actualPages.count &&
                                  zip(expectedPages, actualPages).allSatisfy { $0.visuallyMatches($1) }
                          }),
                          recreatedScans.allSatisfy({ newParentID, scan in
                              guard let gallery = restored.attachments.first(where: { $0.id == newParentID }),
                                    let children = gallery.childAttachments else { return false }
                              let expectedPageIDs = scan.pages.compactMap { attachmentIDMap[$0.id] }
                              guard gallery.childAttachmentIDs == expectedPageIDs,
                                    children.map(\.id) == expectedPageIDs else { return false }
                              return zip(scan.pages, children).allSatisfy { page, actual in
                                  guard actual.typeUTI == page.material.typeUTI,
                                        actual.scanFilter == page.filter,
                                        actual.scanOrientation == page.orientation,
                                        actual.scanHasMarkup == (page.markupSHA256 != nil),
                                        actual.scanHasEmbeddedMarkup == page.hasEmbeddedMarkup,
                                        let source = prepared[page.id],
                                        let sourceEvidence = try? Self.scanPageEvidence(source),
                                        let path = actual.filePath,
                                        let actualEvidence = try? Self.scanPageEvidence(
                                            url: URL(fileURLWithPath: path), name: actual.filename ?? actual.id
                                        ),
                                        sourceEvidence.visuallyMatches(actualEvidence) else { return false }
                                  let sourceSize = Self.scanImagePixelSize(source.url)
                                  let actualSize = Self.scanImagePixelSize(URL(fileURLWithPath: path))
                                  let expectedCrop = page.crop.flatMap {
                                      Self.normalizedScanCrop($0, pixelWidth: sourceSize?.width, pixelHeight: sourceSize?.height)
                                  }
                                  let actualCrop = actual.scanCrop.flatMap {
                                      Self.normalizedScanCrop($0, pixelWidth: actualSize?.width, pixelHeight: actualSize?.height)
                                  }
                                  guard NativeVerificationRules.sameScanCrop(expectedCrop, actualCrop) else { return false }
                                  if let expectedHash = page.markupSHA256,
                                     let payload = try? SQLiteNotesStore(refresh: true)
                                        .scanMarkupPayloads(restored.summary.id.uuid)[actual.id] {
                                      return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined() == expectedHash
                                  }
                                  return page.markupSHA256 == nil
                              }
                          }),
                          recreatedRecordings.allSatisfy({ newParentID, recording in
                              guard let actual = nestedAttachment(newParentID, in: restored.attachments),
                                    let children = actual.childAttachments,
                                    let newChildIDs = Optional(recording.fragments.compactMap { attachmentIDMap[$0.id] }),
                                    newChildIDs.count == recording.fragments.count,
                                    actual.childAttachmentIDs == newChildIDs,
                                    children.map(\.id) == newChildIDs,
                                    actual.typeUTI == snapshot.attachments.first(where: { $0.id == recording.parentID })?.typeUTI,
                                    abs((actual.duration ?? 0) - recording.duration) < 0.05,
                                    RecordingFragments.mismatch(
                                        expected: recording.transcript,
                                        actual: actual.transcriptWords ?? []
                                    ) == nil,
                                    actual.recording == recording.metadata ||
                                        (recording.metadata == nil && actual.recording.map(Self.recordingMetadataPayload)?.isEmpty != false) else {
                                  return false
                              }
                              let fragmentsMatch = zip(recording.fragments, children).allSatisfy { fragment, child in
                                  child.typeUTI == fragment.material.typeUTI &&
                                      abs((child.duration ?? 0) - fragment.duration) < 0.05 &&
                                      restoredRecordingHashes[fragment.id] == prepared[fragment.id]?.sha256
                              }
                              guard fragmentsMatch else { return false }
                              let expectedMetadata = recording.fragments.compactMap { fragment -> RecordingFragmentMetadata? in
                                  guard let id = attachmentIDMap[fragment.id],
                                        let date = fragment.createdDate,
                                        let version = fragment.transcriptVersion else { return nil }
                                  return RecordingFragmentMetadata(id: id, createdDate: date, transcriptVersion: version)
                              }
                              if expectedMetadata.isEmpty { return true }
                              guard expectedMetadata.count == recording.fragments.count,
                                    let actualMetadata = actual.recordingFragments,
                                    actualMetadata.count == expectedMetadata.count else { return false }
                              return zip(expectedMetadata, actualMetadata).allSatisfy { expected, found in
                                  expected.id == found.id && expected.transcriptVersion == found.transcriptVersion &&
                                      abs((expected.createdDate?.timeIntervalSince1970 ?? 0) -
                                          (found.createdDate?.timeIntervalSince1970 ?? 0)) < 0.001
                              }
                          }),
                          recreatedInline.allSatisfy({ newID, recreation in
                              guard let actual = nestedAttachment(newID, in: restored.attachments) else { return false }
                              if let parentID = recreation.parentID {
                                  let expectedParentID = attachmentIDMap[parentID] ?? parentID
                                  guard let parent = nestedAttachment(expectedParentID, in: restored.attachments),
                                        parent.childAttachmentIDs?.contains(newID) == true else { return false }
                              } else if !restored.attachments.contains(where: { $0.id == newID }) {
                                  return false
                              }
                              switch recreation.request {
                              case .hashtag(let name):
                                  let value = actual.displayText ?? actual.title ?? ""
                                  return value.trimmingCharacters(in: CharacterSet(charactersIn: "#")) == name
                              case .noteLink(let targetID, let paragraphID, _, _):
                                  return actual.targetNoteID?.caseInsensitiveCompare(targetID) == .orderedSame &&
                                      (paragraphID == nil && actual.targetParagraphID == nil ||
                                       paragraphID != nil && actual.targetParagraphID?.caseInsensitiveCompare(paragraphID!) == .orderedSame)
                              case .divider: return actual.isDivider == true
                              case .math(let expression):
                                  return actual.mathExpression == expression || actual.graphExpression == expression
                              case .mention(_, let identity):
                                  return actual.participantUserID == identity || actual.participantID == identity
                              }
                          }) else { return nil }
                    return ["utf16Length": "\(document.text.utf16.count)", "attachmentTopology": "verified",
                            "attachmentIDMap": idMapJSON, "restoredSHA256": hashesJSON]
                },
                mismatch: "Persisted snapshot readback did not match the saved note structure."
            )
        }
    }

#if DEBUG
    func hardDeleteAttachmentsForTesting(_ ref: String, attachmentIDs: [String]) throws {
        let ids = Set(attachmentIDs)
        guard !ids.isEmpty, ids.count == attachmentIDs.count else {
            throw NotesError("invalid_test_fixture", "The hard-delete test requires unique attachment identifiers.")
        }
        let lease = try writeLease(); defer { lease?.release() }
        lock.lock(); defer { lock.unlock() }
        try performContext { context in
            let target = try note(ref, in: context)
            var objects: [NSManagedObject] = []
            var found: Set<String> = []
            for identifier in ids {
                let predicate = NSPredicate(format: "identifier == %@", identifier)
                let fetched = try fetch("ICInlineAttachment", predicate: predicate, in: context) +
                    fetch("ICAttachment", predicate: predicate, in: context)
                var seen: Set<NSManagedObjectID> = []
                for object in fetched where seen.insert(object.objectID).inserted {
                    guard NativeAttachmentOwnership.belongs(object, to: target) else {
                        throw NotesError("snapshot_attachment_id_collision",
                                         "The hard-delete fixture identifier belongs to another note.")
                    }
                    objects.append(object)
                    if let value = value(object, "identifier") as? String { found.insert(value) }
                }
            }
            guard found == ids else {
                throw NotesError("snapshot_attachment_unavailable",
                                 "The hard-delete fixture no longer contains every requested attachment row.")
            }
            for object in objects { context.delete(object) }
            try context.save()
            context.refreshAllObjects()
        }
    }
#endif

    private static func prepareSnapshotFiles(_ plan: SnapshotRestorePlan,
                                             material restoreMaterial: SnapshotRestoreMaterial?) throws -> [String: FrozenAttachmentInput] {
        let recreations = plan.attachments.flatMap { item -> [(String, SnapshotAttachmentMaterial, String?)] in
            switch item.action {
            case .recreateFile(let material):
                let filename = SnapshotRestoreFilename.requiresExplicitType(material)
                    ? SnapshotRestoreFilename.forExplicitType(material)
                    : SnapshotRestoreFilename.derive(for: material)
                return [(item.id, material, filename)]
            case .recreateScan(let scan): return scan.pages.map { ($0.id, $0.material, nil) }
            case .recreateRecording(let recording): return recording.fragments.map { ($0.id, $0.material, nil) }
            case .recreatePaperDocument(let material, _):
                return material.archived ? [(item.id, material, "paper.pdf")] : []
            default: return []
            }
        }
        guard !recreations.isEmpty else { return [:] }
        guard let restoreMaterial else {
            throw NotesError("snapshot_material_missing", "The snapshot attachment package is unavailable.")
        }
        var result: [String: FrozenAttachmentInput] = [:]
        for (id, material, suggestedName) in recreations {
            guard let hash = material.blobSHA256, hash.count == 64, hash == hash.lowercased(),
                  hash.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
                  let expectedBytes = material.byteCount, expectedBytes > 0 else {
                throw NotesError("snapshot_integrity_failed", "Attachment \(id) has invalid archived blob metadata.")
            }
            let data = try restoreMaterial.blobs.verifiedData(sha256: hash, byteCount: expectedBytes)
            guard data.count == expectedBytes else {
                throw NotesError("snapshot_integrity_failed", "Attachment \(id) failed its archived blob integrity check.")
            }
            guard let filename = suggestedName ?? SnapshotRestoreFilename.derive(for: material) else {
                throw NotesError("snapshot_attachment_filename_unsupported", "Attachment \(id) has no filename that safely preserves its saved type.")
            }
            result[id] = try FrozenAttachmentInput(
                verifiedData: data,
                suggestedName: filename,
                sha256: hash
            )
        }
        return result
    }

    private static func audioDuration(_ source: URL) throws -> Double {
        let file = try AVAudioFile(forReading: source)
        guard file.processingFormat.sampleRate > 0 else {
            throw NotesError("snapshot_recording_invalid", "The archived recording has no readable audio sample rate.")
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, duration <= TranscriptLimits.maxSeconds else {
            throw NotesError("snapshot_recording_invalid", "The archived recording has an invalid duration.")
        }
        return duration
    }

    private static func verifiedSnapshotPayload(_ payload: SnapshotAttachmentMaterial,
                                                material restoreMaterial: SnapshotRestoreMaterial?) throws -> Data {
        guard let restoreMaterial else {
            throw NotesError("snapshot_material_missing", "The snapshot native attachment package is unavailable.")
        }
        guard let hash = payload.blobSHA256,
              hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let byteCount = payload.byteCount, byteCount > 0 else {
            throw NotesError("snapshot_integrity_failed", "The snapshot native attachment payload is invalid.")
        }
        return try restoreMaterial.blobs.verifiedData(sha256: hash, byteCount: byteCount)
    }

    private static func verifiedPaperBundlePayload(_ payload: SnapshotAttachmentMaterial,
                                                   material restoreMaterial: SnapshotRestoreMaterial?) throws -> Data {
        guard let restoreMaterial else {
            throw NotesError("snapshot_material_missing", "The snapshot Paper bundle package is unavailable.")
        }
        guard let hash = payload.paperBundleSHA256,
              hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let byteCount = payload.paperBundleByteCount, byteCount > 0 else {
            throw NotesError("snapshot_integrity_failed", "The snapshot Paper bundle payload is invalid.")
        }
        return try restoreMaterial.blobs.verifiedData(sha256: hash, byteCount: byteCount)
    }

    private static func verifiedLinkPayload(
        _ payload: SnapshotAttachmentMaterial,
        material restoreMaterial: SnapshotRestoreMaterial?
    ) throws -> (synapse: Data?, metadata: Data?) {
        guard let restoreMaterial else {
            throw NotesError("snapshot_material_missing", "The snapshot rich-link package is unavailable.")
        }
        func read(_ hash: String?, _ byteCount: Int?, name: String) throws -> Data? {
            guard hash != nil || byteCount != nil else { return nil }
            guard let hash,
                  hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  let byteCount, byteCount > 0 else {
                throw NotesError("snapshot_integrity_failed", "The snapshot \(name) payload is invalid.")
            }
            let data = try restoreMaterial.blobs.verifiedData(sha256: hash, byteCount: byteCount)
            guard data.count == byteCount else {
                throw NotesError("snapshot_integrity_failed", "The snapshot \(name) payload failed its integrity check.")
            }
            return data
        }
        let synapse = try read(payload.synapseSHA256, payload.synapseByteCount, name: "Synapse")
        let metadata = try read(payload.linkMetadataSHA256, payload.linkMetadataByteCount, name: "link metadata")
        guard synapse != nil || metadata != nil else {
            throw NotesError("snapshot_integrity_failed", "The snapshot rich-link payload is empty.")
        }
        return (synapse, metadata)
    }

    private static func verifiedMarkupPayload(hash: String, byteCount: Int,
                                              restoreMaterial: SnapshotRestoreMaterial?) throws -> Data {
        guard hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              byteCount > 0 else {
            throw NotesError("snapshot_integrity_failed", "The snapshot markup payload is invalid.")
        }
        guard let restoreMaterial else {
            throw NotesError("snapshot_material_missing", "The snapshot markup package is unavailable.")
        }
        let data = try restoreMaterial.blobs.verifiedData(sha256: hash, byteCount: byteCount)
        guard data.count == byteCount else {
            throw NotesError("snapshot_integrity_failed", "The snapshot markup payload failed its integrity check.")
        }
        return data
    }

    static func paperBundleSignature(_ data: Data) -> String? {
        guard let envelope = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              envelope["version"] as? Int == 1,
              let format = envelope["format"] as? String,
              let payload = envelope["payload"] as? Data,
              !payload.isEmpty else { return nil }
        let normalized: Data
        switch format {
        case "file-v1":
            guard let signature = paperArchiveAssetSignature(payload) else { return nil }
            normalized = Data(signature.utf8)
        case "file-wrapper-v1":
            guard let wrapper = FileWrapper(serializedRepresentation: payload),
                  let entries = paperBundleEntries(wrapper, path: "") else { return nil }
            let assets = entries.filter { $0.hasPrefix("F:") }
            normalized = Data(assets.sorted().joined(separator: "\n").utf8)
        default:
            return nil
        }
        return SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
    }

    private static func paperBundleEntries(_ wrapper: FileWrapper, path: String) -> [String]? {
        if wrapper.isSymbolicLink { return nil }
        if wrapper.isRegularFile {
            guard let contents = wrapper.regularFileContents else { return nil }
            guard path.hasPrefix("Assets.bundle/") else { return [] }
            let hash = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
            return ["F:\(Data(path.utf8).base64EncodedString()):\(contents.count):\(hash)"]
        }
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else { return nil }
        var entries = ["D:\(Data(path.utf8).base64EncodedString())"]
        for name in children.keys.sorted() {
            guard let child = children[name] else { return nil }
            let childPath = path.isEmpty ? name : "\(path)/\(name)"
            guard let childEntries = paperBundleEntries(child, path: childPath) else { return nil }
            entries.append(contentsOf: childEntries)
        }
        return entries
    }

    private static func paperArchiveAssetSignature(_ payload: Data) -> String? {
        guard payload.starts(with: Data("BZh".utf8)), payload.count <= maximumScanBytes,
              let archive = try? FrozenAttachmentInput(data: payload, suggestedName: "paper.tar.bz2") else {
            return nil
        }
        func run(_ arguments: [String]) -> Data? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = arguments
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            do { try process.run() } catch { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            _ = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0 ? data : nil
        }
        guard let listingData = run(["-tjf", archive.url.path]),
              listingData.count <= 4 * 1024 * 1024,
              let listing = String(data: listingData, encoding: .utf8) else { return nil }
        let members = listing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var records: [String] = []
        var totalBytes = 0
        for member in members where member.hasPrefix("Assets.bundle/") && !member.hasSuffix("/") {
            let components = member.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !member.contains("\0"),
                  let contents = run(["-xOjf", archive.url.path, member]) else { return nil }
            totalBytes += contents.count
            guard totalBytes <= maximumScanBytes else { return nil }
            let hash = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
            records.append("\(contents.count):\(hash)")
        }
        guard !records.isEmpty else { return "assets:none" }
        return records.sorted().joined(separator: "\n")
    }

    private static func recordingMetadataPayload(_ metadata: RecordingMetadata) -> [String: Any] {
        var result: [String: Any] = [:]
        if let value = metadata.summary { result["summary"] = value }
        if let value = metadata.topLineSummary { result["topLineSummary"] = value }
        if let value = metadata.summaryVersion { result["summaryVersion"] = value }
        if let value = metadata.externalModelAttributionProviderName { result["externalModelAttributionProviderName"] = value }
        if let value = metadata.externalModelAttributionSymbolName { result["externalModelAttributionSymbolName"] = value }
        if let value = metadata.localSpeakerHandle { result["localSpeakerHandle"] = value }
        if let value = metadata.remoteSpeakerHandle { result["remoteSpeakerHandle"] = value }
        if let value = metadata.callType { result["callType"] = value }
        if let value = metadata.isCallRecording { result["isCallRecording"] = value }
        if let value = metadata.startTime { result["startTime"] = value }
        return result
    }

    private static func snapshotTableRows(_ id: String, in document: NoteDocument) -> [[TableCellDocument]]? {
        if let rows = document.tableCells?[id] { return rows }
        return document.tables?[id]?.map { row in
            row.map { TableCellDocument(text: $0, runs: [AttributeRun(length: ($0 as NSString).length)]) }
        }
    }

    private static func savedTableParentID(for id: String, in document: NoteDocument) -> String? {
        for (tableID, rows) in document.tableCells ?? [:] {
            for row in rows {
                for cell in row {
                    if cell.runs.contains(where: {
                        $0.attachment?.id == id && $0.attachment?.parentAttachmentCaptured == true &&
                            $0.attachment?.parentAttachmentID == tableID
                    }) {
                        return tableID
                    }
                }
            }
        }
        return nil
    }

    private static func remapTableRows(
        _ rows: [[TableCellDocument]],
        attachmentIDs mapping: [String: String]
    ) -> [[TableCellDocument]] {
        guard !mapping.isEmpty else { return rows }
        return rows.map { row in
            row.map { cell in
                var cell = cell
                for index in cell.runs.indices {
                    guard let oldID = cell.runs[index].attachment?.id,
                          let newID = mapping[oldID] else { continue }
                    cell.runs[index].attachment?.id = newID
                }
                return cell
            }
        }
    }

    private func requireRestoreState(_ noteID: String, expectedRevision: String?, expectedModified: Date?) throws {
        guard expectedRevision != nil || expectedModified != nil else { return }
        let current: Note
        do { current = try SQLiteNotesStore(refresh: true).note(noteID) }
        catch {
            throw NotesError("native_read_failed", "Could not recheck the note before snapshot restore: \(error.localizedDescription)")
        }
        if let expectedRevision, NoteRevision.value(current) != expectedRevision {
            throw NotesError("undo_conflict", "The note changed before snapshot restore could save it.")
        }
        if expectedRevision == nil, let expectedModified,
           current.summary.modified != expectedModified {
            throw NotesError("undo_conflict", "The note changed before snapshot restore could save it.")
        }
    }

    private static func restorePlanError(_ plan: SnapshotRestorePlan) -> NotesError {
        let refusals = plan.attachments.compactMap { item -> String? in
            guard case .refuse(let reason) = item.action else { return nil }
            return "\(item.id):\(reason.rawValue)"
        }
        let codes = plan.attachments.compactMap { item -> SnapshotRestoreRefusalReason? in
            guard case .refuse(let reason) = item.action else { return nil }
            return reason
        }
        let code: String
        if codes.contains(.invalidSnapshot) || codes.contains(.typeMismatch) || codes.contains(.idCollision) {
            code = "invalid_snapshot"
        } else if codes.contains(.missingMaterial) || codes.contains(.missingBlob) {
            code = "snapshot_material_missing"
        } else {
            code = "snapshot_attachment_recreation_unsupported"
        }
        return NotesError(code, "Snapshot restore preflight refused attachment recreation: \(refusals.joined(separator: ", ")).")
    }

    private static func sortedJSON(_ values: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(values), as: UTF8.self)
    }

    private struct BuiltSnapshotText {
        var text: NSMutableAttributedString
        var collapsedParagraphIDs: [String]
    }

    static func markerReferences(_ document: NoteDocument) -> [InlineRef] {
        var seen: Set<String> = []
        var result: [InlineRef] = []
        func collect(_ value: NoteDocument) {
            for reference in value.runs.compactMap(\.attachment) where seen.insert(reference.id).inserted {
                result.append(reference)
            }
            if let tables = value.tableCells {
                for rows in tables.values { for row in rows { for cell in row { collect(cell.document) } } }
            }
        }
        collect(document)
        return result
    }

    private static func topLevelMarkerReferences(_ document: NoteDocument) -> [InlineRef] {
        var seen: Set<String> = []
        return document.runs.compactMap(\.attachment).filter { seen.insert($0.id).inserted }
    }

    private static func nestedMarkerReferences(_ document: NoteDocument) -> [String] {
        var result: [String] = []
        for rows in document.tableCells?.values ?? Dictionary<String, [[TableCellDocument]]>().values {
            for row in rows {
                for cell in row {
                    result.append(contentsOf: cell.runs.compactMap(\.attachment?.id))
                }
            }
        }
        return result
    }

    private struct SnapshotAttachmentReference {
        var id: String
        var typeUTI: String
        var parentID: String?
        var alternateParentID: String?
    }

    private static func attachmentReferences(_ snapshot: Note) throws -> [SnapshotAttachmentReference] {
        var types: [String: String] = [:], parents: [String: String] = [:], alternateParents: [String: String] = [:]
        func record(id: String, typeUTI: String, parentID: String?, alternateParentID: String? = nil) throws {
            if let existing = types[id], existing != typeUTI {
                throw NotesError("invalid_snapshot", "Attachment \(id) has conflicting saved types.")
            }
            types[id] = typeUTI
            if let parentID {
                if let existing = parents[id], existing != parentID {
                    throw NotesError("invalid_snapshot", "Attachment \(id) has conflicting saved parents.")
                }
                parents[id] = parentID
            }
            if let alternateParentID {
                if let existing = alternateParents[id], existing != alternateParentID {
                    throw NotesError("invalid_snapshot", "Attachment \(id) has conflicting legacy parents.")
                }
                alternateParents[id] = alternateParentID
            }
        }
        func collect(_ attachment: Attachment, parentID: String?) throws {
            try record(id: attachment.id, typeUTI: attachment.typeUTI, parentID: parentID)
            for childID in attachment.childAttachmentIDs ?? [] {
                if let existing = parents[childID], existing != attachment.id {
                    throw NotesError("invalid_snapshot", "Attachment \(childID) has conflicting saved parents.")
                }
                parents[childID] = attachment.id
            }
            for child in attachment.childAttachments ?? [] { try collect(child, parentID: attachment.id) }
        }
        for attachment in snapshot.attachments { try collect(attachment, parentID: nil) }
        func collectTopLevel(_ document: NoteDocument) throws {
            for reference in document.runs.compactMap(\.attachment) {
                try record(id: reference.id, typeUTI: reference.typeUTI, parentID: nil)
            }
            for (tableID, rows) in document.tableCells ?? [:] {
                for row in rows {
                    for cell in row {
                        for reference in cell.runs.compactMap(\.attachment) {
                            if reference.parentAttachmentCaptured == true {
                                try record(
                                    id: reference.id,
                                    typeUTI: reference.typeUTI,
                                    parentID: reference.parentAttachmentID
                                )
                            } else {
                                try record(
                                    id: reference.id,
                                    typeUTI: reference.typeUTI,
                                    parentID: nil,
                                    alternateParentID: tableID
                                )
                            }
                        }
                    }
                }
            }
        }
        try collectTopLevel(snapshot.document!)
        guard parents.keys.allSatisfy({ types[$0] != nil && types[parents[$0]!] != nil }),
              alternateParents.keys.allSatisfy({ types[$0] != nil && types[alternateParents[$0]!] != nil }) else {
            throw NotesError("invalid_snapshot", "The snapshot attachment parent graph is incomplete.")
        }
        return types.keys.sorted().map {
            SnapshotAttachmentReference(
                id: $0,
                typeUTI: types[$0]!,
                parentID: parents[$0],
                alternateParentID: alternateParents[$0]
            )
        }
    }

    private func attributed(_ document: NoteDocument) throws -> BuiltSnapshotText {
        let source = document.text as NSString
        let output = NSMutableAttributedString()
        var offset = 0
        var collapsed: [String] = []
        for run in document.runs {
            guard run.length >= 0, offset + run.length <= source.length else {
                throw NotesError("invalid_snapshot", "A snapshot attribute run is outside the note body.")
            }
            let string = source.substring(with: NSRange(location: offset, length: run.length))
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let paragraph = run.paragraph {
                let style = try NCNotesRuntime.paragraphStyle(
                    Self.nativeStyle(paragraph.kind).number,
                    indent: paragraph.indent,
                    quote: paragraph.kind == .blockquote ? max(1, paragraph.blockQuoteLevel ?? 1) : (paragraph.blockQuoteLevel ?? 0),
                    checked: paragraph.kind == .checklist ? (paragraph.checked == true ? 1 : 0) : -1,
                    basedOn: nil
                )
                if let alignment = paragraph.alignment {
                    try require(["setAlignment:"], of: style as AnyObject)
                    try NCNotesRuntime.setValue(alignment, forKey: "alignment", of: style as AnyObject)
                }
                if let direction = paragraph.writingDirection {
                    try require(["setWritingDirection:"], of: style as AnyObject)
                    try NCNotesRuntime.setValue(direction, forKey: "writingDirection", of: style as AnyObject)
                }
                let paragraphUUID = try paragraph.id.map { value -> UUID in
                    guard let uuid = UUID(uuidString: value) else {
                        throw NotesError("invalid_snapshot", "A saved paragraph ID is not a UUID.")
                    }
                    return uuid
                }
                let checklistUUID = try paragraph.checklistID.map { value -> UUID in
                    guard let uuid = UUID(uuidString: value) else {
                        throw NotesError("invalid_snapshot", "A saved checklist ID is not a UUID.")
                    }
                    return uuid
                }
                if paragraphUUID != nil || checklistUUID != nil {
                    try NCNotesRuntime.applyParagraphID(
                        paragraphUUID, checklistID: checklistUUID,
                        checked: paragraph.checked == true ? 1 : 0, to: style
                    )
                }
                if paragraph.collapsed == true {
                    try require(["uuid", "supportsSectionLinks"], of: style as AnyObject)
                    guard value(style as AnyObject, "supportsSectionLinks") as? Bool == true,
                          let uuid = value(style as AnyObject, "uuid") as? UUID else {
                        throw NotesError("not_collapsible", "A saved collapsed paragraph is not a collapsible heading.")
                    }
                    collapsed.append(uuid.uuidString)
                }
                attributes[.init("TTStyle")] = style
            }
            let hints = (run.font.bold ? 1 : 0) | (run.font.italic ? 2 : 0)
            if hints != 0 { attributes[.init("TTHints")] = hints }
            if run.font.underline { attributes[.init("TTUnderline")] = 1 }
            if run.font.strikethrough { attributes[.init("TTStrikethrough")] = 1 }
            if run.font.superscript != 0 { attributes[.init("NSSuperScript")] = run.font.superscript }
            if run.font.name != nil || run.font.pointSize != nil {
                attributes[.init("ICTTFont")] = try NCNotesRuntime.font(
                    name: run.font.name,
                    size: run.font.pointSize.map { NSNumber(value: $0) },
                    hints: hints,
                    basedOn: nil
                )
            }
            if let link = run.link { attributes[.init("NSLink")] = URL(string: link) ?? link }
            if let color = run.color { attributes[.init("TTColor")] = try Self.color(color) }
            if let highlight = run.highlight { attributes[.init("TTEmphasis")] = highlight.notesValue }
            if let attachment = run.attachment {
                attributes[.init("NSAttachment")] = try NCNotesRuntime.attachmentMarker(id: attachment.id, type: attachment.typeUTI)
            }
            output.append(NSAttributedString(string: string, attributes: attributes))
            offset += run.length
        }
        guard offset == source.length else {
            throw NotesError("invalid_snapshot", "Snapshot attribute runs do not cover the note body.")
        }
        return BuiltSnapshotText(text: output, collapsedParagraphIDs: collapsed)
    }

    private func restoreTable(_ rows: [[TableCellDocument]], attachment: NSManagedObject,
                              rightToLeft: Bool) throws {
        guard !rows.isEmpty, let width = rows.map(\.count).max(), width > 0,
              rows.allSatisfy({ $0.count == width }) else {
            throw NotesError("invalid_snapshot", "A saved table has inconsistent dimensions.")
        }
        let editor = try NCTableEditor(attachment: attachment)
        var rowCount = try editor.rowCount().intValue
        var columnCount = try editor.columnCount().intValue
        while rowCount < rows.count { try editor.insertRow(rowCount); rowCount += 1 }
        while rowCount > rows.count { rowCount -= 1; try editor.removeRow(rowCount) }
        while columnCount < width { try editor.insertColumn(columnCount); columnCount += 1 }
        while columnCount > width { columnCount -= 1; try editor.removeColumn(columnCount) }
        for row in rows.indices {
            for column in rows[row].indices {
                let logicalColumn = rightToLeft ? width - column - 1 : column
                try editor.setAttributedCell(column: logicalColumn, row: row, text: attributed(rows[row][column].document).text)
            }
        }
        try editor.save()
    }

    private func replaceSnapshotInlineMarker(_ oldID: String, with newID: String,
                                             note: NSManagedObject, parent: NSManagedObject?) throws {
        let marker = try NCNotesRuntime.attachmentMarker(
            id: newID,
            type: "com.apple.notes.inlinetextattachment.link"
        )
        if let parent {
            let editor = try NCTableEditor(attachment: parent)
            let rows = try editor.rowCount().intValue
            let columns = try editor.columnCount().intValue
            var matches: [(row: Int, column: Int, range: NSRange, text: NSAttributedString)] = []
            for row in 0..<rows {
                for column in 0..<columns {
                    let text = try editor.attributedText(column: column, row: row)
                    for match in attachmentMarkers(text) where match.2 == oldID {
                        matches.append((row, column, match.0, text))
                    }
                }
            }
            guard matches.count == 1, let match = matches.first else {
                throw NotesError(
                    "snapshot_attachment_unavailable",
                    "The provisional self paragraph link marker is unavailable in its parent table."
                )
            }
            let updated = NSMutableAttributedString(attributedString: match.text)
            var attributes = match.text.attributes(at: match.range.location, effectiveRange: nil)
            attributes[.init("NSAttachment")] = marker
            updated.setAttributes(attributes, range: match.range)
            try editor.setAttributedCell(column: match.column, row: match.row, text: updated)
            try editor.save()
            return
        }

        let editor = try NCBodyEditor(note: note)
        try editor.prepare(["attributes"])
        let matches = attachmentMarkers(editor.original).filter { $0.2 == oldID }
        guard matches.count == 1, let range = matches.first?.0 else {
            throw NotesError(
                "snapshot_attachment_unavailable",
                "The provisional self paragraph link marker is unavailable in the note body."
            )
        }
        var attributes = editor.original.attributes(at: range.location, effectiveRange: nil)
        attributes[.init("NSAttachment")] = marker
        try editor.begin(["attributes"])
        try editor.setAttributes(attributes, range: range)
        try editor.finish()
    }

    private func preflightSnapshotDocument(_ document: NoteDocument) throws {
        _ = try attributed(document)
        for rows in document.tableCells?.values ?? Dictionary<String, [[TableCellDocument]]>().values {
            guard !rows.isEmpty, let width = rows.map(\.count).max(), width > 0,
                  rows.allSatisfy({ $0.count == width }) else {
                throw NotesError("invalid_snapshot", "A saved table has inconsistent dimensions.")
            }
            for row in rows {
                for cell in row { _ = try attributed(cell.document) }
            }
        }
    }

    public func insertRecording(_ ref: String, frozen: FrozenAttachmentInput, title: String?, duration: Double,
                                transcript: [TranscriptWord], allowShared: Bool) throws -> NativeRecordingResult {
        // A new recording has one fragment. Check before Notes saves the audio, which a rollback cannot undo.
        _ = try RecordingFragments.grouped(transcript, fragmentCount: 1)
        return try performRecordingWrite(duration: duration) { context in
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note)
            var attachmentID = "", childIDs: [String] = [], at = 0, kind: NSString?
            do {
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["insert"])
                at = editor.original.length
                attachmentID = try NCNotesRuntime.addFile(frozen.url, to: note, title: title ?? frozen.sourceName, type: &kind)
                operation?.attachmentID = attachmentID
                operation?.attachmentType = kind as String? ?? "public.mpeg-4-audio"
                operation?.attachmentPosition = at
                guard let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@", attachmentID), in: context, limit: 1).first else {
                    throw NotesError("attachment_not_found", "Notes created no audio attachment record.")
                }
                childIDs = try NCNotesRuntime.transformAudioAttachment(attachment, duration: duration)
                if !transcript.isEmpty {
                    _ = try RecordingFragments.grouped(transcript, fragmentCount: childIDs.count)
                    _ = try NCNotesRuntime.appendTranscriptSegments(transcriptRows(transcript), toAudioAttachment: attachment)
                }
                try insertMarker(editor, original: editor.original, id: attachmentID,
                                 type: kind as String? ?? "public.mpeg-4-audio", position: nil)
                try editor.finish()
                try save(context, notes: [note])
            } catch {
                context.rollback()
                throw (error as? NotesError) ?? nativeError(error)
            }
            return try recordingResult(noteID: id(note), attachmentID: attachmentID, childIDs: childIDs,
                                       duration: duration, transcript: transcript, frozen: frozen, position: at)
        }
    }

    public func createRecordingNote(folder folderRef: String?, title: String, frozen: FrozenAttachmentInput, duration: Double,
                                    transcript: [TranscriptWord], allowShared: Bool) throws -> NativeRecordingResult {
        // A new recording has one fragment. Check before Notes saves the audio, which a rollback cannot undo.
        _ = try RecordingFragments.grouped(transcript, fragmentCount: 1)
        return try performRecordingWrite(duration: duration) { context in
            let destination = try destinationFolder(folderRef, in: context)
            try guardWritableFolder(destination, allowShared: allowShared)
            var noteID = "", attachmentID = "", childIDs: [String] = [], kind: NSString?, createdNoteID: String?
            do {
                let note = try NCNotesRuntime.newNote(in: destination)
                createdNoteID = id(note)
                try NCNotesRuntime.setValue(title, forKey: "title", of: note)
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["insert"])
                let built = try MarkdownNativeWriter(owner: self).attributed(markdown: "# " + title, note: note, context: context,
                                                                              editor: editor, existing: [:]).0
                attachmentID = try NCNotesRuntime.addFile(frozen.url, to: note, title: frozen.sourceName, type: &kind)
                try TestFault.check("after_attachment")
                operation?.attachmentID = attachmentID
                operation?.attachmentType = kind as String? ?? "public.mpeg-4-audio"
                operation?.attachmentPosition = built.length
                guard let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@", attachmentID), in: context, limit: 1).first else {
                    throw NotesError("attachment_not_found", "Notes created no audio attachment record.")
                }
                childIDs = try NCNotesRuntime.transformAudioAttachment(attachment, duration: duration)
                if !transcript.isEmpty {
                    _ = try RecordingFragments.grouped(transcript, fragmentCount: childIDs.count)
                    _ = try NCNotesRuntime.appendTranscriptSegments(transcriptRows(transcript), toAudioAttachment: attachment)
                }
                if built.length > 0 { built.append(NSAttributedString(string: "\n")) }
                let marker = try NCNotesRuntime.attachmentMarker(id: attachmentID, type: kind as String? ?? "public.mpeg-4-audio")
                built.append(NSAttributedString(string: "\u{fffc}", attributes: [.init("NSAttachment"): marker]))
                try editor.begin(["insert"])
                try editor.insert(built, at: 0)
                try editor.finish()
                try TestFault.check("before_save")
                try save(context, notes: [note])
                noteID = id(note)
            } catch {
                let write = try rollBackCreatedNote(createdNoteID, after: error, in: context)
                return NativeRecordingResult(attachmentID: "", childAttachmentIDs: [], duration: duration, transcriptSegments: 0, write: write)
            }
            return try recordingResult(noteID: noteID, attachmentID: attachmentID, childIDs: childIDs,
                                       duration: duration, transcript: transcript, frozen: frozen, position: title.utf16.count + 1)
        }
    }

    public func writeRecordingTranscripts(_ ref: String, transcripts: [String: [TranscriptWord]], allowShared: Bool) throws -> NativeWriteResult {
        guard !transcripts.isEmpty else { throw NotesError("recording_not_found", "No recording without a transcript was found.") }
        return try performWrite { context in
            let note = try note(ref, in: context)
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note, protectsBody: false)
            do {
                for (attachmentID, segments) in transcripts {
                    guard !segments.isEmpty else { throw NotesError("transcription_empty", "On-device transcription returned no speech.") }
                    let predicate = NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, note)
                    guard let attachment = try fetch("ICAttachment", predicate: predicate, in: context, limit: 1).first else {
                        throw NotesError("attachment_not_found", "Recording \(attachmentID) is not in this note.")
                    }
                    _ = try RecordingFragments.grouped(segments, fragmentCount: (attachment.value(forKey: "subAttachments") as? NSSet)?.count ?? 0)
                    _ = try NCNotesRuntime.appendTranscriptSegments(transcriptRows(segments), toAudioAttachment: attachment)
                }
                try save(context, notes: [note])
            } catch {
                context.rollback()
                throw (error as? NotesError) ?? nativeError(error)
            }
            let total = transcripts.values.reduce(0) { $0 + $1.count }
            return result(id(note), native: ["recordings": "\(transcripts.count)", "segments": "\(total)"], sqlite: { note in
                let matches = note.attachments.filter { attachment in
                    transcripts[attachment.id].map { RecordingFragments.mismatch(expected: $0, actual: attachment.transcriptWords ?? []) == nil } ?? false
                }
                guard matches.count == transcripts.count else { return nil }
                return ["recordings": "\(matches.count)", "segments": "\(matches.compactMap(\.transcriptWords).reduce(0) { $0 + $1.count })"]
            }, mismatch: "Fresh Notes database readback did not match the written transcript text, timing, speakers, or fragments.")
        }
    }

    private func transcriptRows(_ transcript: [TranscriptWord]) -> [[String: Any]] {
        transcript.map { segment in
            var row: [String: Any] = ["text": segment.text, "start": segment.start ?? 0, "duration": segment.duration ?? 0,
                                      "fragment": segment.fragment ?? 0]
            if let speaker = segment.speaker { row["speaker"] = speaker }
            return row
        }
    }

    private func recordingResult(noteID: String, attachmentID: String, childIDs: [String], duration: Double,
                                 transcript: [TranscriptWord], frozen: FrozenAttachmentInput, position: Int) throws -> NativeRecordingResult {
        let stored = storedAttachmentHash(noteID: noteID, attachmentID: attachmentID, expected: frozen.sha256)
        let write = result(noteID, native: ["attachmentID": attachmentID, "fragments": "\(childIDs.count)",
                                                   "duration": String(duration), "segments": "\(transcript.count)",
                                                   "sourceSHA256": frozen.sha256, "storedSHA256": stored ?? ""],
                           nativeVerified: !childIDs.isEmpty && stored == frozen.sha256,
                           sqlite: { note in
            guard let attachment = note.attachments.first(where: { $0.id == attachmentID }),
                  Set(attachment.childAttachmentIDs ?? []) == Set(childIDs),
                  abs((attachment.duration ?? 0) - duration) < 0.05,
                  RecordingFragments.mismatch(expected: transcript, actual: attachment.transcriptWords ?? []) == nil,
                  stored == frozen.sha256 else { return nil }
            return ["attachmentID": attachment.id, "fragments": "\(attachment.childAttachmentIDs?.count ?? 0)",
                    "duration": String(attachment.duration ?? 0), "segments": "\(attachment.transcriptWords?.count ?? 0)",
                    "storedSHA256": stored!]
        }, mismatch: "Fresh Notes database readback did not match the native recording graph, audio bytes, duration, or transcript.")
        return NativeRecordingResult(attachmentID: attachmentID, childAttachmentIDs: childIDs, duration: duration,
                                     transcriptSegments: transcript.count, write: write)
    }

    private static func nativeStyle(_ kind: ParagraphStyle.Kind) -> NativeParagraphStyle {
        switch kind {
        case .body: .body
        case .title: .title
        case .heading: .heading
        case .subheading: .subheading
        case .monospaced: .monospaced
        case .bulleted: .bulleted
        case .dashed: .dashed
        case .numbered: .numbered
        case .checklist: .checklist
        case .blockquote: .blockquote
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private final class MarkdownNativeWriter {
    fileprivate unowned let owner: NativeNotesWriter
    init(owner: NativeNotesWriter) { self.owner = owner }

    fileprivate struct Line {
        var text: String
        var style: NativeParagraphStyle
        var indent: Int
        var done: Bool?
        var table: [[String]]?
    }

    fileprivate func attributed(markdown: String, note: NSManagedObject, context: NSManagedObjectContext,
                                editor: NCBodyEditor, existing: [String: (AnyObject, String)]) throws -> (NSMutableAttributedString, Int) {
        let lines = try parse(markdown)
        var tableIDs: [String] = []
        for line in lines {
            if let rows = line.table { tableIDs.append(try editor.addTable(rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))) }
        }
        var tableIndex = 0
        let built = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let style = try NCNotesRuntime.paragraphStyle(line.style.number, indent: line.indent,
                                                          quote: line.style == .blockquote ? 1 : 0,
                                                          checked: line.done.map { $0 ? 1 : 0 } ?? -1, basedOn: nil)
            if line.table != nil {
                let id = tableIDs[tableIndex]; tableIndex += 1
                let marker = try NCNotesRuntime.attachmentMarker(id: id, type: "com.apple.notes.table")
                built.append(NSAttributedString(string: "\u{fffc}", attributes: [.init("TTStyle"): style, .init("NSAttachment"): marker]))
            } else {
                built.append(try inline(line.text, style: style, note: note, context: context, existing: existing))
            }
            if index < lines.count - 1 { built.append(NSAttributedString(string: "\n", attributes: [.init("TTStyle"): style])) }
        }
        return (built, lines.count)
    }

    fileprivate func patch(ref: String, markdown: String, mode: NativeNotesWriter.MarkdownPatchMode, allowShared: Bool,
                           expectedFeatures: [String], context: NSManagedObjectContext) throws -> NativeWriteResult {
        let note = try owner.note(ref, in: context)
        try owner.guardWritable(note, allowShared: allowShared)
        try owner.refreshIfStale(note)
        let editor = try NCBodyEditor(note: note)
        try editor.prepare(["replace"])
        let original = editor.original
        let existing = owner.attachmentMarkers(original)
        let existingByID = Dictionary(grouping: existing, by: { $0.2 }).mapValues { ($0[0].1, $0[0].3) }
        let built = try attributed(markdown: markdown, note: note, context: context, editor: editor, existing: existingByID).0
        let source = original.string as NSString
        let paragraphs = owner.paragraphRanges(source)
        func style(_ range: NSRange) -> Int? {
            guard original.length > 0 else { return nil }
            let index = min(range.location, original.length - 1)
            guard let value = original.attribute(.init("TTStyle"), at: index, effectiveRange: nil) as AnyObject? else { return nil }
            return owner.value(value, "style") as? Int
        }
        func headingLevel(_ range: NSRange) -> Int? {
            if let value = style(range), [0, 1, 2].contains(value) { return value }
            guard original.length > 0 else { return nil }
            let index = min(range.location, original.length - 1)
            let hints = original.attribute(.init("TTHints"), at: index, effectiveRange: nil) as? Int ?? 0
            guard hints & 1 != 0,
                  let font = original.attribute(.init("ICTTFont"), at: index, effectiveRange: nil) as AnyObject? else { return nil }
            let size = (owner.value(font, "pointSize") as? NSNumber)?.doubleValue ?? owner.value(font, "pointSize") as? Double ?? 0
            if size >= 22 { return 0 }
            if size >= 17 { return 1 }
            return 2
        }
        func heading(_ text: String) throws -> (Int, NSRange) {
            let matches = paragraphs.enumerated().filter { _, range in
                headingLevel(range) != nil && source.substring(with: range) == text
            }
            guard matches.count == 1, let match = matches.first else {
                throw NotesError(matches.isEmpty ? "heading_not_found" : "ambiguous_heading", "Heading \(text) did not resolve uniquely.")
            }
            return (match.offset, match.element)
        }
        func afterLine(_ range: NSRange) -> Int { NSMaxRange(range) < source.length ? NSMaxRange(range) + 1 : NSMaxRange(range) }
        var deletion = NSRange(location: 0, length: 0)
        var insertion = built
        switch mode {
        case .append:
            deletion.location = source.length
            if source.length > 0, !source.hasSuffix("\n"), built.length > 0 {
                let value = NSMutableAttributedString(string: "\n")
                value.append(built); insertion = value
            }
        case .prepend:
            if let title = paragraphs.first {
                deletion.location = afterLine(title)
                if deletion.location == source.length, !source.hasSuffix("\n"), built.length > 0 {
                    let value = NSMutableAttributedString(string: "\n")
                    value.append(built); insertion = value
                } else if deletion.location < source.length, built.length > 0 {
                    insertion.append(NSAttributedString(string: "\n"))
                }
            } else {
                deletion.location = 0
                if source.length > 0, built.length > 0 { insertion.append(NSAttributedString(string: "\n")) }
            }
        case .insert(let text):
            let (_, range) = try heading(text)
            deletion.location = afterLine(range)
            if deletion.location == source.length, !source.hasSuffix("\n"), built.length > 0 {
                let value = NSMutableAttributedString(string: "\n")
                value.append(built); insertion = value
            } else if deletion.location < source.length, built.length > 0 {
                insertion.append(NSAttributedString(string: "\n"))
            }
        case .section(let text):
            let (index, range) = try heading(text)
            let start = afterLine(range)
            let level = headingLevel(range) ?? 2
            let next = paragraphs.dropFirst(index + 1).first { candidate in
                guard let candidateLevel = headingLevel(candidate) else { return false }
                return candidateLevel <= level
            }?.location ?? source.length
            deletion = NSRange(location: start, length: next - start)
            if next < source.length, built.length > 0 { insertion.append(NSAttributedString(string: "\n")) }
        }
        let expectedText = source.replacingCharacters(in: deletion, with: insertion.string)
        try editor.begin(["replace"])
        try editor.replace(deletion, with: insertion)
        try editor.finish()
        try owner.save(context, notes: [note])
        let noteID = owner.id(note), nativeBody = try owner.body(try owner.note(noteID, in: context))
        let expectedMarkers = owner.attachmentMarkers(original).map { ($0.2, $0.3) } + owner.attachmentMarkers(built).map { ($0.2, $0.3) }
        let actualMarkers = owner.attachmentMarkers(nativeBody).map { ($0.2, $0.3) }
        return owner.result(noteID, native: ["utf16Length": "\(nativeBody.length)", "preservedFeatures": expectedFeatures.joined(separator: ",")],
                            nativeVerified: nativeBody.string == expectedText && NativeVerificationRules.sameMarkerMultiset(expectedMarkers, actualMarkers), sqlite: { after in
            let features = NativeOnlyFeatures.detect(in: after)
            guard after.document?.text == expectedText, Set(expectedFeatures).isSubset(of: Set(features)) else { return nil }
            return ["features": features.joined(separator: ","), "utf16Length": "\(nativeBody.length)"]
        })
    }

    func write(ref: String, markdown: String, dryRun: Bool, backup: Bool, allowShared: Bool, before: Note,
               context: NSManagedObjectContext) throws -> NativeWriteResult {
        let lines = try parse(markdown), note = try owner.note(ref, in: context)
        let preservedIDs = attachmentReferences(markdown)
        let expectedFeatures = NativeOnlyFeatures.detect(in: before)
        try owner.guardWritable(note, allowShared: allowShared); try owner.refreshIfStale(note)
        if backup { try makeBackup(ref: owner.id(note)) }
        if dryRun {
            return owner.result(owner.id(note), native: ["dryRun": "true", "paragraphs": "\(lines.count)"], message: "No write made.")
        }
        var expectedMarkers: [(String, String)] = [], expectedText = ""
        do {
            let editor = try NCBodyEditor(note: note); try editor.prepare(["replace"])
            let existing = owner.attachmentMarkers(editor.original)
            guard Set(preservedIDs).count == preservedIDs.count else { throw NotesError("duplicate_attachment_reference", "Each notescli-attachment ID may appear once.") }
            let existingGroups = Dictionary(grouping: existing, by: { $0.2 })
            guard existingGroups.values.allSatisfy({ $0.count == 1 }) else { throw NotesError("attachment_placement_mismatch", "An existing attachment has more than one placement; nothing was saved.") }
            let existingByID = existingGroups.mapValues { ($0[0].1, $0[0].3) }
            for id in preservedIDs where existingByID[id] == nil { throw NotesError("attachment_not_found", "Attachment \(id) does not belong to this note.") }
            let kept = Set(preservedIDs)
            for marker in existing where !kept.contains(marker.2) {
                throw NotesError("attachment_would_be_lost", "Markdown omitted inline marker \(marker.2); nothing was saved.")
            }
            let built = try attributed(markdown: markdown, note: note, context: context, editor: editor, existing: existingByID).0
            let mappings = unchangedMappings(from: editor.original.string, to: built.string)
            let unpreserved = unpreservedFeatures(in: before, coveredBy: mappings.map(\.old))
            guard unpreserved.isEmpty else {
                throw NotesError(
                    "native_required",
                    "The full-body rewrite changes text carrying native-only features that Markdown cannot preserve: \(unpreserved.joined(separator: ", ")).",
                    hint: "Use a native append, prepend, range, section, or formatting command so those attributes stay attached to the original text."
                )
            }
            try preserveNativeAttributes(from: editor.original, in: built, mappings: mappings)
            expectedText = built.string
            expectedMarkers = owner.attachmentMarkers(built).map { ($0.2, $0.3) }
            try editor.begin(["replace"])
            try editor.replace(NSRange(location: 0, length: editor.original.length), with: built)
            try editor.finish()
            try owner.save(context, notes: [note])
        } catch { context.rollback(); throw (error as? NotesError) ?? owner.nativeError(error) }
        let nativeBody = try owner.body(try owner.note(owner.id(note), in: context))
        let nativeMarkers = owner.attachmentMarkers(nativeBody).map { ($0.2, $0.3) }
        let nativeVerified = nativeBody.string == expectedText && NativeVerificationRules.sameMarkerMultiset(expectedMarkers, nativeMarkers)
        return owner.result(owner.id(note), native: ["utf16Length": "\(nativeBody.length)", "paragraphs": "\(lines.count)", "preservedAttachments": "\(preservedIDs.count)"],
                            nativeVerified: nativeVerified, sqlite: { n in
            guard n.document?.text == nativeBody.string else { return nil }
            let readbackMarkers = n.document?.runs.compactMap { run in run.attachment.map { ($0.id, $0.typeUTI) } } ?? []
            let features = NativeOnlyFeatures.detect(in: n)
            guard NativeVerificationRules.sameMarkerMultiset(expectedMarkers, readbackMarkers),
                  Set(expectedFeatures).isSubset(of: Set(features)) else { return nil }
            return ["features": features.joined(separator: ","), "utf16Length": "\(nativeBody.length)",
                    "hasChecklist": "\(n.summary.hasChecklist)", "preservedAttachments": "\(preservedIDs.count)"]
        })
    }

    private typealias UnchangedMapping = (old: NSRange, new: NSRange)

    private func unchangedMappings(from old: String, to new: String) -> [UnchangedMapping] {
        let old = old as NSString, new = new as NSString
        var prefix = 0
        while prefix < old.length, prefix < new.length, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) { suffix += 1 }
        var result: [UnchangedMapping] = []
        if prefix > 0 { result.append((NSRange(location: 0, length: prefix), NSRange(location: 0, length: prefix))) }
        if suffix > 0 {
            result.append((NSRange(location: old.length - suffix, length: suffix),
                           NSRange(location: new.length - suffix, length: suffix)))
        }
        return result
    }

    private func unpreservedFeatures(in note: Note, coveredBy ranges: [NSRange]) -> [String] {
        guard let document = note.document else { return [] }
        let text = document.text as NSString
        func covered(_ range: NSRange) -> Bool {
            ranges.contains { $0.location <= range.location && NSMaxRange($0) >= NSMaxRange(range) }
        }
        func isNewline(_ value: unichar) -> Bool { value == 0x0A || value == 0x0D || value == 0x2028 || value == 0x2029 }
        func contentRange(_ range: NSRange) -> NSRange {
            var start = range.location, end = NSMaxRange(range)
            while start < end, isNewline(text.character(at: start)) { start += 1 }
            while end > start, isNewline(text.character(at: end - 1)) { end -= 1 }
            return NSRange(location: start, length: end - start)
        }
        var result: Set<String> = [], offset = 0
        for run in document.runs {
            let range = contentRange(NSRange(location: offset, length: run.length)); offset += run.length
            guard range.length > 0, !covered(range) else { continue }
            if run.paragraph?.alignment != nil { result.insert("alignment") }
            if NativeOnlyFeatures.hasCustomWritingDirection(run.paragraph?.writingDirection) { result.insert("writing direction") }
            if run.paragraph?.collapsed == true { result.insert("collapsible headings") }
            if run.paragraph?.startNumber != nil { result.insert("numbered list starts") }
            if (run.paragraph?.blockQuoteLevel ?? 0) > 1 { result.insert("block quote levels") }
            let runText = text.substring(with: range)
            let isDefaultTitleRun = runText.trimmingCharacters(in: .newlines) == note.summary.title
            for feature in NativeOnlyFeatures.customFontFeatures(run.font, isDefaultTitleRun: isDefaultTitleRun) { result.insert(feature) }
            if run.color != nil { result.insert("text color") }
        }
        return result.sorted()
    }

    private func preserveNativeAttributes(from original: NSAttributedString, in replacement: NSMutableAttributedString,
                                          mappings: [UnchangedMapping]) throws {
        for mapping in mappings {
            var oldIndex = mapping.old.location
            let oldEnd = NSMaxRange(mapping.old)
            while oldIndex < oldEnd {
                var oldEffective = NSRange()
                let oldAttributes = original.attributes(at: oldIndex, effectiveRange: &oldEffective)
                let newIndex = mapping.new.location + oldIndex - mapping.old.location
                var newEffective = NSRange()
                let newAttributes = replacement.attributes(at: newIndex, effectiveRange: &newEffective)
                let length = min(NSMaxRange(oldEffective), oldEnd) - oldIndex
                let destination = NSRange(location: newIndex, length: min(length, NSMaxRange(newEffective) - newIndex))

                if let oldStyle = oldAttributes[.init("TTStyle")] as AnyObject?,
                   let newStyle = newAttributes[.init("TTStyle")] as AnyObject? {
                    let style = owner.value(newStyle, "style") as? Int ?? 3
                    let indent = owner.value(newStyle, "indent") as? Int ?? 0
                    let quote = owner.value(newStyle, "blockQuoteLevel") as? Int ?? 0
                    let todo = owner.value(newStyle, "todo") as AnyObject?
                    let checked = todo.flatMap { owner.value($0, "done") as? Bool }.map { $0 ? 1 : 0 } ?? -1
                    let merged = try NCNotesRuntime.paragraphStyle(style, indent: indent, quote: quote,
                                                                   checked: checked, basedOn: oldStyle)
                    replacement.addAttribute(.init("TTStyle"), value: merged, range: destination)
                }
                if let oldFont = oldAttributes[.init("ICTTFont")] as AnyObject? {
                    let hints = newAttributes[.init("TTHints")] as? Int ?? 0
                    let merged = try NCNotesRuntime.font(name: nil, size: nil, hints: hints, basedOn: oldFont)
                    replacement.addAttribute(.init("ICTTFont"), value: merged, range: destination)
                }
                if let color = oldAttributes[.init("TTColor")] {
                    replacement.addAttribute(.init("TTColor"), value: color, range: destination)
                }
                oldIndex += destination.length
            }
        }
    }

    fileprivate func makeBackup(ref: String) throws {
        let store = try SQLiteNotesStore(refresh: true), note = try store.note(ref)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NotesCLI/backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = root.appendingPathComponent("\(ref)-\(stamp)")
        let markdown = note.document.map { NoteRenderer.markdown($0, attachments: note.attachments) } ?? ""
        try markdown.write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(note).write(to: base.appendingPathExtension("json"), options: .atomic)
    }

    fileprivate func attachmentReferences(_ markdown: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"!?\[[^\]]*\]\(<?notescli-attachment:([A-Za-z0-9_-]+)>?\)"#) else { return [] }
        let source = markdown as NSString
        return regex.matches(in: markdown, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range(at: 1)) }
    }

    fileprivate func parse(_ markdown: String) throws -> [Line] {
        let raw = markdown.components(separatedBy: "\n")
        var result: [Line] = [], index = 0, inCode = false
        while index < raw.count {
            let source = raw[index]
            if source.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); index += 1; continue }
            if !inCode, source.contains("|"), index + 1 < raw.count,
               raw[index + 1].range(of: #"^\s*\|?\s*:?-{3,}"#, options: .regularExpression) != nil {
                var rows = [tableCells(source)]; index += 2
                while index < raw.count, raw[index].contains("|") { rows.append(tableCells(raw[index])); index += 1 }
                guard let width = rows.map(\.count).max(), width > 0 else { throw NotesError("invalid_markdown_table", "A table needs cells.") }
                result.append(Line(text: "", style: .body, indent: 0, done: nil, table: rows.map { $0 + Array(repeating: "", count: width - $0.count) }))
                continue
            }
            var text = source, style: NativeParagraphStyle = inCode ? .monospaced : .body, done: Bool?, indent = 0
            if !inCode {
                while text.hasPrefix("  ") { indent += 1; text.removeFirst(2) }
                if text.hasPrefix("# ") { style = .title; text.removeFirst(2) }
                else if text.hasPrefix("## ") { style = .heading; text.removeFirst(3) }
                else if text.hasPrefix("### ") { style = .subheading; text.removeFirst(4) }
                else if text.hasPrefix("- [ ] ") { style = .checklist; done = false; text.removeFirst(6) }
                else if text.lowercased().hasPrefix("- [x] ") { style = .checklist; done = true; text.removeFirst(6) }
                else if text.hasPrefix("* ") { style = .bulleted; text.removeFirst(2) }
                else if text.hasPrefix("- ") { style = .dashed; text.removeFirst(2) }
                else if text.range(of: #"^\d+\. "#, options: .regularExpression) != nil { style = .numbered; text = text.replacingOccurrences(of: #"^\d+\. "#, with: "", options: .regularExpression) }
                else if text.hasPrefix("> ") { style = .blockquote; text.removeFirst(2) }
            }
            result.append(Line(text: text, style: style, indent: indent, done: done, table: nil)); index += 1
        }
        return result
    }

    fileprivate func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }; if text.hasSuffix("|") { text.removeLast() }
        return text.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<br>", with: "\n") }
    }

    fileprivate func inline(_ text: String, style: Any, note: NSManagedObject, context: NSManagedObjectContext,
                        existing: [String: (AnyObject, String)]) throws -> NSAttributedString {
        try inline(text, style: style, note: note, context: context, existing: existing, attributes: [:])
    }

    private func inline(_ text: String, style: Any, note: NSManagedObject, context: NSManagedObjectContext,
                        existing: [String: (AnyObject, String)],
                        attributes: [NSAttributedString.Key: Any]) throws -> NSAttributedString {
        let output = NSMutableAttributedString(), source = text as NSString
        let pattern = #"!?\[[^\]]*\]\(<?notescli-attachment:([A-Za-z0-9_-]+)>?\)|\[([^\]]+)\]\(([^)]+)\)|\*\*(.+?)\*\*|~~(.+?)~~|<mark data-apple-notes-highlight=\"(purple|pink|orange|mint|blue)\">(.*?)</mark>|<u>(.*?)</u>|<sup>(.*?)</sup>|<sub>(.*?)</sub>|\*([^*]+)\*"#
        let regex = try NSRegularExpression(pattern: pattern), matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var cursor = 0
        func merged(_ extra: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var result = attributes, extra = extra
            if let old = result[.init("TTHints")] as? Int, let new = extra.removeValue(forKey: .init("TTHints")) as? Int {
                result[.init("TTHints")] = old | new
            }
            result.merge(extra) { _, new in new }
            return result
        }
        func append(_ value: String, _ extra: [NSAttributedString.Key: Any] = [:]) {
            var attrs: [NSAttributedString.Key: Any] = [.init("TTStyle"): style]
            attrs.merge(merged(extra)) { _, new in new }
            output.append(NSAttributedString(string: value, attributes: attrs))
        }
        func appendNested(_ range: NSRange, _ extra: [NSAttributedString.Key: Any]) throws {
            output.append(try inline(source.substring(with: range), style: style, note: note, context: context,
                                     existing: existing, attributes: merged(extra)))
        }
        for match in matches {
            if match.range.location > cursor { append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))) }
            if match.range(at: 1).location != NSNotFound {
                let id = source.substring(with: match.range(at: 1)); guard let item = existing[id] else { throw NotesError("attachment_not_found", "Attachment \(id) is not in this note.") }; append("\u{fffc}", [.init("NSAttachment"): item.0])
            } else if match.range(at: 2).location != NSNotFound {
                let label = source.substring(with: match.range(at: 2)), url = source.substring(with: match.range(at: 3))
                if url.hasPrefix("applenotes://showNote?identifier=") || url.hasPrefix("note:") {
                    let targetRef = url.hasPrefix("note:") ? String(url.dropFirst(5)) : String(url.split(separator: "=").last ?? "")
                    let target = try owner.note(targetRef, in: context), id = try NCNotesRuntime.makeNoteLink(to: target, from: note, text: label), marker = try NCNotesRuntime.attachmentMarker(id: id, type: "com.apple.notes.inlinetextattachment.link"); append("\u{fffc}", [.init("NSAttachment"): marker])
                } else { try appendNested(match.range(at: 2), [.init("NSLink"): URL(string: url) ?? url]) }
            } else if match.range(at: 4).location != NSNotFound { try appendNested(match.range(at: 4), [.init("TTHints"): 1]) }
            else if match.range(at: 5).location != NSNotFound { try appendNested(match.range(at: 5), [.init("TTStrikethrough"): 1]) }
            else if match.range(at: 6).location != NSNotFound {
                let color = HighlightColor(rawValue: source.substring(with: match.range(at: 6)))!
                try appendNested(match.range(at: 7), [.init("TTEmphasis"): color.notesValue])
            }
            else if match.range(at: 8).location != NSNotFound { try appendNested(match.range(at: 8), [.init("TTUnderline"): 1]) }
            else if match.range(at: 9).location != NSNotFound { try appendNested(match.range(at: 9), [.init("NSSuperScript"): 1]) }
            else if match.range(at: 10).location != NSNotFound { try appendNested(match.range(at: 10), [.init("NSSuperScript"): -1]) }
            else if match.range(at: 11).location != NSNotFound { try appendNested(match.range(at: 11), [.init("TTHints"): 2]) }
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length { append(source.substring(from: cursor)) }
        return output
    }
}
