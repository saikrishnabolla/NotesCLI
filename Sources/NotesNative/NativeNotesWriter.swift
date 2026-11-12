import AppKit
import CoreData
import Foundation
import NotesCore
import NotesNativeObjC
import NotesStore
import PencilKit

fileprivate struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
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
    }
    var operation: Operation?
    fileprivate let operationID: () -> String
    fileprivate let contextProvider: () throws -> NSManagedObjectContext

    public convenience init() {
        self.init(operationID: { UUID().uuidString.lowercased() }, contextProvider: { try NCNotesRuntime.sharedContext() })
    }
    init(operationID: @escaping () -> String, contextProvider: @escaping () throws -> NSManagedObjectContext) {
        self.operationID = operationID
        self.contextProvider = contextProvider
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

    func performWrite(_ body: (NSManagedObjectContext) throws -> NativeWriteResult) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }
        precondition(operation == nil)
        operation = Operation(id: operationID())
        defer { operation = nil }
        do {
            return try performContext { context in
                context.automaticallyMergesChangesFromParent = true
                context.refreshAllObjects()
                return try body(context)
            }
        } catch {
            guard let operation, operation.committed else { throw error }
            return NativeWriteResult(
                writeResult: WriteResult(
                    outcome: .unknown,
                    noteID: operation.noteID.map { NoteID(uuid: $0) },
                    folderID: operation.folderID,
                    message: "The Core Data save committed, but follow-up failed. Do not retry. operation_id=\(operation.id): \(error.localizedDescription)",
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
        lock.lock(); defer { lock.unlock() }
        precondition(operation == nil)
        operation = Operation(id: operationID())
        defer { operation = nil }
        do {
            let receipt = try performContext { context in
                context.automaticallyMergesChangesFromParent = true
                context.refreshAllObjects()
                return try transaction(context)
            }
            return try performContext { context in
                context.automaticallyMergesChangesFromParent = true
                context.refreshAllObjects()
                return try readback(context, receipt)
            }
        } catch {
            guard let operation, operation.committed else { throw error }
            return NativeWriteResult(
                writeResult: WriteResult(
                    outcome: .unknown,
                    noteID: operation.noteID.map { NoteID(uuid: $0) },
                    folderID: operation.folderID,
                    message: "The Core Data save committed, but follow-up failed. Do not retry. operation_id=\(operation.id): \(error.localizedDescription)",
                    operationID: operation.id
                ),
                verification: NativeVerification(nativeReadback: [:], sqliteReadback: nil),
                operationID: operation.id
            )
        }
    }

    fileprivate func performAttachmentWrite(_ body: (NSManagedObjectContext) throws -> NativeAttachmentResult) throws -> NativeAttachmentResult {
        lock.lock(); defer { lock.unlock() }
        precondition(operation == nil)
        operation = Operation(id: operationID())
        defer { operation = nil }
        do {
            return try performContext { context in
                context.automaticallyMergesChangesFromParent = true
                context.refreshAllObjects()
                return try body(context)
            }
        } catch {
            guard let operation, operation.committed else { throw error }
            let write = NativeWriteResult(
                writeResult: WriteResult(
                    outcome: .unknown,
                    noteID: operation.noteID.map { NoteID(uuid: $0) },
                    message: "The Core Data save committed, but follow-up failed. Do not retry. operation_id=\(operation.id): \(error.localizedDescription)",
                    operationID: operation.id
                ),
                verification: NativeVerification(nativeReadback: [:], sqliteReadback: nil),
                operationID: operation.id
            )
            return NativeAttachmentResult(attachmentID: operation.attachmentID ?? "", typeUTI: operation.attachmentType ?? "public.data",
                                          position: operation.attachmentPosition ?? 0, write: write)
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
        var matches = try fetch("ICNote", predicate: NSPredicate(format: "identifier ==[c] %@", ref), in: context)
        if let number = NoteReference.explicitNumber(ref) {
            if let object = primaryKeyNote(number), !matches.contains(where: { $0.objectID == object.objectID }) { matches.append(object) }
        } else if let number = NoteReference.bareNumber(ref) {
            if let object = primaryKeyNote(number), !matches.contains(where: { $0.objectID == object.objectID }) { matches.append(object) }
            for object in try fetch("ICNote", predicate: NSPredicate(format: "title == %@ AND markedForDeletion == NO", ref), in: context)
                where !matches.contains(where: { $0.objectID == object.objectID }) { matches.append(object) }
        } else if matches.isEmpty {
            matches = try fetch("ICNote", predicate: NSPredicate(format: "title == %@ AND markedForDeletion == NO", ref), in: context)
        }
        guard !matches.isEmpty else { throw NotesError("note_not_found", "No note matches the reference.") }
        guard matches.count == 1 else { throw NotesError("ambiguous_note", "More than one note matches. Use #ID or a UUID.") }
        return matches[0]
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
        try performWrite { _ in
            do { try NCNotesRuntime.setChecklistAutoSort(enabled); operation?.committed = true }
            catch { throw nativeError(error) }
            let readback = NCNotesRuntime.checklistAutoSortEnabled()
            return globalResult(native: ["enabled": String(readback)], nativeVerified: readback == enabled)
        }
    }

    fileprivate func save(_ context: NSManagedObjectContext, notes: [NSManagedObject]) throws {
        do { try NCNotesRuntime.save(context) }
        catch { context.rollback(); throw nativeError(error) }
        operation?.committed = true
        operation?.noteID = notes.first.map(id)
        for note in notes { try sync(note) }
        context.refreshAllObjects()
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
                                         message: "The save committed, but readback failed. Do not retry. operation_id=\(id ?? "unknown"): \(sqliteError?.localizedDescription ?? "unknown error")",
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
                                         message: "The save committed, but readback failed. Do not retry. operation_id=\(id ?? "unknown"): \(sqliteError?.localizedDescription ?? "unknown error")",
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
            try editor.finish(); try NCNotesRuntime.save(context); operation?.committed = true; operation?.noteID = id(note)
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

    public func insertNoteLink(_ ref: String, target: String, text: String?, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let source = try note(ref, in: context), destination = try note(target, in: context); try guardWritable(source, allowShared: allowShared); try refreshIfStale(source)
        guard id(source) != id(destination) else { throw NotesError("invalid_note_link", "A note cannot link to itself.") }
        var attachmentID = ""
        do { let editor = try NCBodyEditor(note: source); try editor.prepare(["insert"]); attachmentID = try NCNotesRuntime.makeNoteLink(to: destination, from: source, text: text ?? title(destination)); try insertMarker(editor, original: editor.original, id: attachmentID, type: "com.apple.notes.inlinetextattachment.link", position: position); try editor.finish(); try save(context, notes: [source]) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let read = try links(id(source))
        let destinationID = id(destination)
        return result(id(source), native: ["target": destinationID, "linkCount": "\(read.count)", "attachmentID": attachmentID], nativeVerified: NativeVerificationRules.exactLink(read, attachmentID: attachmentID, targetID: destinationID), sqlite: { n in
            n.document?.runs.filter { $0.attachment?.id == attachmentID && $0.attachment?.url?.localizedCaseInsensitiveContains(destinationID) == true }.count == 1 ? ["target": destinationID, "attachmentID": attachmentID] : nil
        }, mismatch: "Attachment \(attachmentID) did not point to note \(destinationID) exactly once.")
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
        if case .mention = request {
            guard isShared(note) else { throw NotesError("mention_requires_shared_note", "Mentions are supported only in shared notes.") }
            guard allowShared else { throw NotesError("shared_write_refused", "Creating a mention changes a shared note. Pass --allow-shared.") }
        }
        var attachmentID = "", kind: NSString?
        do {
            let editor = try NCBodyEditor(note: note); try editor.prepare(["insert"])
            switch request {
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
            switch request {
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
    public func insertMention(_ ref: String, text: String, userRecordName: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        try insertInlineObject(ref, request: .mention(text: text, userRecordName: userRecordName), position: position, allowShared: allowShared)
    }

    fileprivate func linkRows(_ source: NSManagedObject) throws -> [NativeNoteLink] {
        guard let context = source.managedObjectContext else { throw NotesError("native_read_failed", "The note is detached from its native context.") }
        return try inlineMatches(source, type: "com.apple.notes.inlinetextattachment.link", label: nil).map { attachment, range in
            let token = value(attachment, "tokenContentIdentifier") as? String ?? ""
            let match = token.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, options: .regularExpression)
            let candidate = match.map { String(token[$0]) }
            let target = try candidate.flatMap { try fetch("ICNote", predicate: NSPredicate(format: "identifier ==[c] %@", $0), in: context, limit: 1).first.map(id) } ?? token
            return NativeNoteLink(sourceID: id(source), targetID: target, text: value(attachment, "altText") as? String ?? "", attachmentID: id(attachment), range: UTF16Range(location: range.location, length: range.length))
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
            return NativeNoteLink(sourceID: id(source), targetID: target, text: value(attachment, "altText") as? String ?? "",
                                  attachmentID: attachmentID, range: UTF16Range(location: range.location, length: range.length))
        }
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
        let (note, after) = try mutateBody(ref, context: context, allowShared: allowShared) { _, editor, original in let r = try self.valid(range, length: original.length); try editor.begin(["delete", "insert"]); try editor.delete(r); try editor.insert(NSAttributedString(string: text), at: UInt(r.location)) }
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
        let expectedStrokeCount = drawing.strokes.count
        guard expectedStrokeCount > 0 else { throw NotesError("invalid_drawing", "The drawing has no strokes.") }
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
            let decodedStrokeCount: Int
            if let attachment {
                decodedStrokeCount = try NCNotesRuntime.systemPaperDrawings(for: attachment).reduce(0) { count, value in
                    guard let drawing = value as? PKDrawing else { throw NotesError("drawing_decode_failed", "Notes returned an unknown Paper drawing object.") }
                    return count + drawing.strokes.count
                }
            } else {
                decodedStrokeCount = 0
            }
            let type = kind as String? ?? "com.apple.notes.paper"
            let native = ["attachmentID": attachmentID, "typeUTI": type, "placements": String(placements),
                          "strokeCount": String(decodedStrokeCount)]
            let write = result(id(note), native: native,
                               nativeVerified: placements == 1 && decodedStrokeCount == expectedStrokeCount,
                               sqlite: { note in
                guard note.attachments.filter({ $0.id == attachmentID && $0.typeUTI == type }).count == 1 else { return nil }
                return ["attachmentID": attachmentID, "typeUTI": type, "placements": "1",
                        "strokeCount": String(decodedStrokeCount)]
            }, mismatch: "The Paper attachment or its editable strokes did not match the input drawing.")
            return NativeAttachmentResult(attachmentID: attachmentID, typeUTI: type, position: at, write: write)
        }
    }

    fileprivate func storedAttachmentHash(noteID: String, attachmentID: String, expected: String) -> String? {
        for attempt in 0..<12 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
            guard let attachment = try? SQLiteNotesStore(refresh: true).attachments(noteID).first(where: { $0.id == attachmentID }),
                  let path = attachment.filePath,
                  let hash = try? FrozenAttachmentInput.hash(file: URL(fileURLWithPath: path)) else { continue }
            if hash == expected { return hash }
        }
        return nil
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

    public func createDrawingNote(title: String, folder folderRef: String?, drawing: PKDrawing,
                                  allowShared: Bool) throws -> NativeCreateResult {
        let expectedStrokeCount = drawing.strokes.count
        guard expectedStrokeCount > 0 else { throw NotesError("invalid_drawing", "The drawing has no strokes.") }
        var createdAttachmentID = ""
        let write = try performWrite { context in
            let destination = try destinationFolder(folderRef, in: context)
            try guardWritableFolder(destination, allowShared: allowShared)
            var noteID = "", attachmentID = "", type = "com.apple.notes.paper"
            do {
                let note = try NCNotesRuntime.newNote(in: destination)
                try NCNotesRuntime.setValue(title, forKey: "title", of: note)
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["insert"])
                let built = try MarkdownNativeWriter(owner: self).attributed(markdown: "# " + title, note: note,
                    context: context, editor: editor, existing: [:]).0
                var kind: NSString?
                attachmentID = try NCNotesRuntime.addSystemPaperDrawing(drawing as AnyObject, to: note, type: &kind)
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
                try save(context, notes: [note])
                noteID = id(note)
            } catch {
                context.rollback()
                throw (error as? NotesError) ?? nativeError(error)
            }
            let fresh = try self.note(noteID, in: context)
            let placements = attachmentMarkers(try body(fresh)).filter { $0.2 == attachmentID }.count
            let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, fresh), in: context, limit: 1).first
            let decodedStrokeCount: Int
            if let attachment {
                decodedStrokeCount = try NCNotesRuntime.systemPaperDrawings(for: attachment).reduce(0) {
                    guard let drawing = $1 as? PKDrawing else { throw NotesError("drawing_decode_failed", "Notes returned an unknown Paper drawing object.") }
                    return $0 + drawing.strokes.count
                }
            } else { decodedStrokeCount = 0 }
            return result(noteID, native: ["title": title, "attachmentID": attachmentID, "typeUTI": type,
                                           "placements": String(placements), "strokeCount": String(decodedStrokeCount)],
                          nativeVerified: placements == 1 && decodedStrokeCount == expectedStrokeCount,
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

    public func createNote(title: String, markdown: String, folder folderRef: String?, attachments: [FrozenAttachmentInput], allowShared: Bool) throws -> NativeCreateResult {
        let write = try performWrite { context in
            let destination = try destinationFolder(folderRef, in: context)
            try guardWritableFolder(destination, allowShared: allowShared)
            var noteID = "", attachmentIDs: [String] = []
            do {
                let note = try NCNotesRuntime.newNote(in: destination)
                try NCNotesRuntime.setValue(title, forKey: "title", of: note)
                let editor = try NCBodyEditor(note: note)
                try editor.prepare(["insert"])
                let source = "# " + title + (markdown.isEmpty ? "" : "\n" + markdown)
                let built = try MarkdownNativeWriter(owner: self).attributed(markdown: source, note: note, context: context,
                                                                                 editor: editor, existing: [:]).0
                for frozen in attachments {
                    var kind: NSString?
                    let attachmentID = try NCNotesRuntime.addFile(frozen.url, to: note, title: frozen.sourceName, type: &kind)
                    let marker = try NCNotesRuntime.attachmentMarker(id: attachmentID, type: kind as String? ?? "public.data")
                    if built.length > 0 { built.append(NSAttributedString(string: "\n")) }
                    built.append(NSAttributedString(string: "\u{fffc}", attributes: [.init("NSAttachment"): marker]))
                    attachmentIDs.append(attachmentID)
                }
                try editor.begin(["insert"])
                try editor.insert(built, at: 0)
                try editor.finish()
                try save(context, notes: [note])
                noteID = id(note)
            } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
            var hashes: [String: String] = [:]
            for (index, attachmentID) in attachmentIDs.enumerated() {
                if let hash = storedAttachmentHash(noteID: noteID, attachmentID: attachmentID, expected: attachments[index].sha256) {
                    hashes[attachmentID] = hash
                }
            }
            return result(noteID, native: ["title": title, "attachments": "\(attachmentIDs.count)", "hashes": "\(hashes.count)"],
                          nativeVerified: attachmentIDs.count == attachments.count && hashes.count == attachments.count,
                          sqlite: { note in
                guard note.summary.title == title,
                      Set(attachmentIDs).isSubset(of: Set(note.attachments.map(\.id))),
                      hashes.count == attachments.count else { return nil }
                return ["title": note.summary.title, "attachments": "\(attachmentIDs.count)", "hashes": "\(hashes.count)"]
            }, mismatch: "The created note or frozen attachment bytes did not match.")
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
            let editor = try NCBodyEditor(note: note); try editor.begin(["delete", "insert"]); try editor.delete(marker.0)
            if !text.isEmpty { try editor.insert(NSAttributedString(string: text), at: UInt(marker.0.location)) }
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
        do { let copy = try NCNotesRuntime.duplicateNote(source, folder: folder); if let newTitle { try NCNotesRuntime.setValue(newTitle, forKey: "title", of: copy) }; try save(context, notes: [copy]); let copyTitle = title(copy); return result(id(copy), native: ["duplicatedFrom": id(source), "title": copyTitle], sqlite: { $0.summary.title == copyTitle ? ["title": $0.summary.title] : nil }) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        }
    }

    fileprivate func appleMove(_ note: NSManagedObject, to folder: NSManagedObject) throws {
        let script = "on run argv\ntell application \"Notes\" to move note id (item 1 of argv) to folder id (item 2 of argv)\nend run", process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-e", script, "--", note.objectID.uriRepresentation().absoluteString, folder.objectID.uriRepresentation().absoluteString]; let errorPipe = Pipe(); process.standardError = errorPipe; process.standardOutput = FileHandle.nullDevice; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw NotesError("native_sync_failed", String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
    }
    public func restore(_ ref: String, folder destination: String?, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
        let note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared, allowTrash: true); try refreshIfStale(note, protectsBody: false)
        let target: NSManagedObject
        if let destination { target = try folder(destination, in: context) }
        else { guard let original = ["folderBeforeDeletion", "originalFolder", "previousFolder"].compactMap({ value(note, $0) as? NSManagedObject }).first else { throw NotesError("restore_folder_required", "NotesShared exposes no original folder for this note. Pass --folder.") }; target = original }
        try guardWritableFolder(target, allowShared: allowShared)
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
        try performWrite { context in
            let folder = try folder(ref, in: context), folderID = id(folder)
            guard !((order == .title) != (direction == .ascending || direction == .descending)) else {
                throw NotesError("invalid_folder_sort", "Use ascending or descending for title, and newest or oldest for date sorts.")
            }
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

    public func defaultAccountIdentifier() throws -> String {
        try performRead { _ in
            do { return try NCNotesRuntime.defaultAccountIdentifier() }
            catch { throw nativeError(error) }
        }
    }

    public func setDefaultAccount(_ identifier: String) throws -> NativeWriteResult {
        try performWrite { _ in
            do { try NCNotesRuntime.setDefaultAccountIdentifier(identifier); operation?.committed = true }
            catch { throw nativeError(error) }
            let readback: String
            do { readback = try NCNotesRuntime.defaultAccountIdentifier() }
            catch { throw nativeError(error) }
            return globalResult(native: ["accountID": readback], nativeVerified: readback.caseInsensitiveCompare(identifier) == .orderedSame)
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
        try SmartFolderQueryGrammar.validate(queryJSON)
        return try performWriteWithFreshReadback(transaction: { context in
            let matches = try matchingSmartFolders(ref, in: context)
            guard matches.count == expectedCount else { throw NotesError("expected_count_mismatch", "Found \(matches.count) matching Smart Folders, not \(expectedCount).") }
            guard expectedCount == 1, let folder = matches.first else { throw NotesError("invalid_expected_count", "Smart Folder rule editing requires --expected-count 1.") }
            let folderID = id(folder)
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
                try editor.begin(["delete", "insert"])
                for range in ranges.reversed() {
                    var attributes: [NSAttributedString.Key: Any] = [:]
                    if original.length > 0 { attributes = original.attributes(at: min(range.location, original.length - 1), effectiveRange: nil) }
                    try editor.delete(range)
                    try editor.insert(NSAttributedString(string: replacement, attributes: attributes), at: UInt(range.location))
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

    public func restoreSnapshot(_ ref: String, snapshot: Note, allowShared: Bool) throws -> NativeWriteResult {
        try performWrite { context in
            guard let document = snapshot.document else {
                throw NotesError("snapshot_locked", "The snapshot has no readable note body.")
            }
            let note = try note(ref, in: context)
            guard snapshot.summary.id.uuid.caseInsensitiveCompare(id(note)) == .orderedSame else {
                throw NotesError("snapshot_note_mismatch", "The snapshot belongs to a different note.")
            }
            try guardWritable(note, allowShared: allowShared)
            try refreshIfStale(note)
            let expectedMarkers = Self.topLevelMarkerReferences(document)
            let expectedAttachments = try Self.attachmentReferences(snapshot)
            var attachmentObjects: [String: NSManagedObject] = [:]
            var unresolved = expectedAttachments
            while !unresolved.isEmpty {
                var next: [SnapshotAttachmentReference] = [], madeProgress = false
                for reference in unresolved {
                    if let parentID = reference.parentID, attachmentObjects[parentID] == nil {
                        next.append(reference)
                        continue
                    }
                    let predicate: NSPredicate
                    if let parentID = reference.parentID, let parent = attachmentObjects[parentID] {
                        predicate = NSPredicate(format: "identifier == %@ AND parentAttachment == %@", reference.id, parent)
                    } else {
                        predicate = NSPredicate(format: "identifier == %@ AND note == %@", reference.id, note)
                    }
                    let rows = try fetch("ICInlineAttachment", predicate: predicate, in: context) +
                        fetch("ICAttachment", predicate: predicate, in: context)
                    guard let attachment = rows.first(where: { NativeAttachmentOwnership.belongs($0, to: note) }),
                          value(attachment, "typeUTI") as? String == reference.typeUTI else {
                        throw NotesError("snapshot_attachment_unavailable", "Attachment \(reference.id) is not available on the target note with its saved type and parent.")
                    }
                    attachmentObjects[reference.id] = attachment
                    madeProgress = true
                }
                guard madeProgress || next.isEmpty else {
                    throw NotesError("invalid_snapshot", "The snapshot attachment parent graph is incomplete.")
                }
                unresolved = next
            }
            do {
                for attachment in attachmentObjects.values where value(attachment, "markedForDeletion") as? Bool == true {
                    try NCNotesRuntime.unmarkForDeletion(attachment)
                }
                let built = try attributed(document)
                let editor = try NCBodyEditor(note: note)
                let oldMarkers = attachmentMarkers(editor.original)
                try editor.begin(["delete", "insert"])
                try editor.delete(NSRange(location: 0, length: editor.original.length))
                try editor.insert(built.text, at: 0)
                try editor.finish()

                if let tables = document.tableCells {
                    for (attachmentID, rows) in tables {
                        guard let attachment = attachmentObjects[attachmentID] else {
                            throw NotesError("snapshot_attachment_unavailable", "Table \(attachmentID) is no longer available for restore.")
                        }
                        try restoreTable(rows, attachment: attachment)
                    }
                }
                if !built.collapsedParagraphIDs.isEmpty {
                    try require(["setOutlineStateData:"], of: note)
                    let data = try NCNotesRuntime.outlineStateData(collapsedUUIDStrings: built.collapsedParagraphIDs.sorted())
                    try NCNotesRuntime.setValue(data, forKey: "outlineStateData", of: note)
                } else if snapshot.document?.collapsedParagraphIDs?.isEmpty == false {
                    throw NotesError("snapshot_restore_failed", "Collapsed headings could not be rebuilt from the snapshot.")
                } else if value(note, "outlineStateData") != nil {
                    let data = try NCNotesRuntime.outlineStateData(collapsedUUIDStrings: [])
                    try NCNotesRuntime.setValue(data, forKey: "outlineStateData", of: note)
                }
                let kept = Set(expectedMarkers.map(\.id))
                for old in oldMarkers where !kept.contains(old.2) {
                    let predicate = NSPredicate(format: "identifier == %@ AND note == %@", old.2, note)
                    let inline = try fetch("ICInlineAttachment", predicate: predicate, in: context, limit: 1).first
                    let regular = try fetch("ICAttachment", predicate: predicate, in: context, limit: 1).first
                    if let object = inline ?? regular {
                        try NCNotesRuntime.markForDeletion(object)
                    }
                }
                try save(context, notes: [note])
            } catch {
                context.rollback()
                throw (error as? NotesError) ?? nativeError(error)
            }
            let fresh = try self.note(id(note), in: context)
            let nativeBody = try body(fresh)
            let nativeMarkers = attachmentMarkers(nativeBody).map { ($0.2, $0.3) }
            let expectedMarkerPairs = expectedMarkers.map { ($0.id, $0.typeUTI) }
            return result(
                id(note),
                native: ["utf16Length": "\(nativeBody.length)", "markerCount": "\(expectedMarkers.count)"],
                nativeVerified: nativeBody.string == document.text && NativeVerificationRules.sameMarkerMultiset(expectedMarkerPairs, nativeMarkers),
                sqlite: { restored in
                    guard SnapshotRestoreVerification.matches(expected: snapshot, actual: restored) else { return nil }
                    return ["utf16Length": "\(document.text.utf16.count)", "attachmentTopology": "verified"]
                },
                mismatch: "Persisted snapshot readback did not match the saved note structure."
            )
        }
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

    private struct SnapshotAttachmentReference {
        var id: String
        var typeUTI: String
        var parentID: String?
    }

    private static func attachmentReferences(_ snapshot: Note) throws -> [SnapshotAttachmentReference] {
        var types: [String: String] = [:], parents: [String: String] = [:]
        func record(id: String, typeUTI: String, parentID: String?) throws {
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
        func collect(_ document: NoteDocument, parentID: String?) throws {
            for reference in document.runs.compactMap(\.attachment) {
                try record(id: reference.id, typeUTI: reference.typeUTI, parentID: parentID)
            }
            for (tableID, rows) in document.tableCells ?? [:] {
                for row in rows { for cell in row { try collect(cell.document, parentID: tableID) } }
            }
        }
        try collect(snapshot.document!, parentID: nil)
        guard parents.keys.allSatisfy({ types[$0] != nil && types[parents[$0]!] != nil }) else {
            throw NotesError("invalid_snapshot", "The snapshot attachment parent graph is incomplete.")
        }
        return types.keys.sorted().map { SnapshotAttachmentReference(id: $0, typeUTI: types[$0]!, parentID: parents[$0]) }
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

    private func restoreTable(_ rows: [[TableCellDocument]], attachment: NSManagedObject) throws {
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
                try editor.setAttributedCell(column: column, row: row, text: attributed(rows[row][column].document).text)
            }
        }
        try editor.save()
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
        try editor.prepare(["delete", "insert"])
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
        try editor.begin(["delete", "insert"])
        if deletion.length > 0 { try editor.delete(deletion) }
        if insertion.length > 0 { try editor.insert(insertion, at: UInt(deletion.location)) }
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
            let editor = try NCBodyEditor(note: note); try editor.prepare(["delete", "insert"])
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
            try editor.begin(["delete", "insert"]); try editor.delete(NSRange(location: 0, length: editor.original.length)); try editor.insert(built, at: 0); try editor.finish()
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
        func covered(_ range: NSRange) -> Bool {
            ranges.contains { $0.location <= range.location && NSMaxRange($0) >= NSMaxRange(range) }
        }
        var result: Set<String> = [], offset = 0
        for run in document.runs {
            let range = NSRange(location: offset, length: run.length); offset += run.length
            guard run.length > 0, !covered(range) else { continue }
            if run.paragraph?.alignment != nil { result.insert("alignment") }
            if run.paragraph?.writingDirection != nil { result.insert("writing direction") }
            if run.paragraph?.collapsed == true { result.insert("collapsible headings") }
            if run.paragraph?.startNumber != nil { result.insert("numbered list starts") }
            if (run.paragraph?.blockQuoteLevel ?? 0) > 1 { result.insert("block quote levels") }
            if run.font.name != nil { result.insert("font family") }
            if run.font.pointSize != nil { result.insert("font size") }
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
