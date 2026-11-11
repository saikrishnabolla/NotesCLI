import AppKit
import CoreData
import Foundation
import NotesCore
import NotesNativeObjC
import NotesStore

public final class NativeNotesWriter: NotesNativeWriting {
    fileprivate let lock = NSRecursiveLock()
    public init() {}

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
        do { return try NCNotesRuntime.sharedContext() }
        catch { throw nativeError(error) }
    }

    fileprivate func nativeError(_ error: Error) -> NotesError {
        let text = error.localizedDescription
        if text.contains("required selector missing") || text.contains("required class missing") ||
            text.contains("cannot load NotesShared") || text.contains("cannot load NotesUI") ||
            text.contains("unrecognized selector") || text.contains("doesNotRecognizeSelector") {
            return NotesError("native_unavailable", text, hint: "Use the AppleScript command when it supports this write, or run notescli native-doctor --json.")
        }
        return NotesError("native_write_failed", text)
    }

    fileprivate func value(_ object: AnyObject?, _ key: String) -> Any? {
        guard let object else { return nil }
        return NCNotesRuntime.value(forKey: key, of: object)
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
        var matches = try fetch("ICNote", predicate: NSPredicate(format: "identifier ==[c] %@", ref), in: context)
        if matches.isEmpty { matches = try fetch("ICNote", predicate: NSPredicate(format: "title == %@ AND markedForDeletion == NO", ref), in: context) }
        guard !matches.isEmpty else { throw NotesError("note_not_found", "No note matches the reference.") }
        guard matches.count == 1 else { throw NotesError("ambiguous_note", "More than one note has this title. Use its UUID.") }
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
        if value(note, "isPasswordProtected") as? Bool == true { throw NotesError("note_locked", "Locked notes cannot be changed.") }
        if !allowTrash, value(note, "markedForDeletion") as? Bool == true { throw NotesError("note_deleted", "The note is marked for deletion.") }
        if !allowTrash, let folder = value(note, "folder") as? NSManagedObject, value(folder, "folderType") as? Int == 1 {
            throw NotesError("note_in_trash", "Restore the note before changing its contents.")
        }
        if isShared(note) && !allowShared { throw NotesError("shared_write_refused", "The note is shared. Pass --allow-shared to confirm the write.") }
        if value(note, "isSharedReadOnly") as? Bool == true { throw NotesError("shared_read_only", "The shared note is read-only.") }
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
        lock.lock(); defer { lock.unlock() }
        let context = try context(); return try checklist(note(ref, in: context))
    }

    fileprivate func save(_ context: NSManagedObjectContext, notes: [NSManagedObject]) throws {
        do { try NCNotesRuntime.save(context) }
        catch { context.rollback(); throw nativeError(error) }
        for note in notes { try sync(note) }
        context.refreshAllObjects()
    }

    fileprivate func sync(_ note: NSManagedObject) throws {
        guard let folder = value(note, "folder") as? NSManagedObject else { throw NotesError("native_sync_failed", "The note has no folder.") }
        let script = "on run argv\ntell application \"Notes\" to move note id (item 1 of argv) to folder id (item 2 of argv)\nend run"
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--", note.objectID.uriRepresentation().absoluteString, folder.objectID.uriRepresentation().absoluteString]
        let stderr = Pipe(); process.standardOutput = FileHandle.nullDevice; process.standardError = stderr
        do { try process.run(); process.waitUntilExit() }
        catch { throw NotesError("native_sync_failed", "Saved locally, but Notes.app could not be asked to sync: \(error.localizedDescription)") }
        guard process.terminationStatus == 0 else {
            let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NotesError("native_sync_failed", "Saved locally, but Notes.app did not accept the sync request: \(text)")
        }
    }

    fileprivate func result(_ noteID: String?, native: [String: String], nativeVerified: Bool = true,
                            sqlite: ((Note) -> [String: String]?)? = nil, message: String? = nil) -> NativeWriteResult {
        var sqliteEvidence: [String: String]?
        if let noteID, let sqlite {
            for attempt in 0..<12 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
                if let store = try? SQLiteNotesStore(refresh: true), let note = try? store.note(noteID), let evidence = sqlite(note) { sqliteEvidence = evidence; break }
            }
        }
        let verified = nativeVerified && !native.isEmpty && (sqlite == nil || sqliteEvidence != nil)
        return NativeWriteResult(writeResult: WriteResult(outcome: verified ? .verified : .unverified,
                                                           noteID: noteID.map { NoteID(uuid: $0) }, message: message),
                                 verification: NativeVerification(nativeReadback: native, sqliteReadback: sqliteEvidence))
    }

    fileprivate func globalResult(native: [String: String], nativeVerified: Bool = true,
                                  folderID: String? = nil, sqlite: (() throws -> [String: String]?)? = nil,
                                  message: String? = nil) -> NativeWriteResult {
        var sqliteEvidence: [String: String]?
        if let sqlite {
            for attempt in 0..<12 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
                if let evidence = try? sqlite() { sqliteEvidence = evidence }
                if sqliteEvidence != nil { break }
            }
        }
        let verified = nativeVerified && !native.isEmpty && (sqlite == nil || sqliteEvidence != nil)
        return NativeWriteResult(writeResult: WriteResult(outcome: verified ? .verified : .unverified, folderID: folderID, message: message),
                                 verification: NativeVerification(nativeReadback: native, sqliteReadback: sqliteEvidence))
    }

    fileprivate func mutateBody(_ ref: String, allowShared: Bool, edit: (NSManagedObject, NCBodyEditor, NSAttributedString) throws -> Void) throws -> (NSManagedObject, NSAttributedString) {
        let context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared)
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
        lock.lock(); defer { lock.unlock() }
        guard !text.contains("\n") else { throw NotesError("invalid_checklist_text", "A checklist item must be one line.") }
        let (note, _) = try mutateBody(ref, allowShared: allowShared) { _, editor, original in
            let at = position ?? original.length; guard (0...original.length).contains(at) else { throw NotesError("invalid_range", "Position exceeds the note length.") }
            let style = try NCNotesRuntime.paragraphStyle(103, indent: 0, quote: 0, checked: 0, basedOn: nil)
            let prefix = at > 0 && (original.string as NSString).character(at: at - 1) != 10 ? "\n" : ""
            let item = NSAttributedString(string: prefix + text, attributes: [NSAttributedString.Key("TTStyle"): style])
            try editor.begin(); try editor.insert(item, at: UInt(at))
        }
        let items = try checklist(note)
        return result(id(note), native: ["checklistCount": "\(items.count)", "inserted": items.contains { $0.text == text } ? "true" : "false"],
                      sqlite: { n in n.document?.runs.contains(where: { $0.paragraph?.kind == .checklist }) == true ? ["hasChecklist": "true"] : nil })
    }

    fileprivate func setChecklist(_ ref: String, allowShared: Bool, select: ([ChecklistItem]) throws -> Set<Int>, done: Bool?) throws -> NativeWriteResult {
        let context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared)
        let before = try checklist(note), chosen = try select(before)
        guard !chosen.isEmpty else { throw NotesError("checklist_item_not_found", "No checklist item matched.") }
        do {
            let editor = try NCBodyEditor(note: note), original = editor.original; try editor.begin()
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
        let after = try checklist(try self.note(id(note), in: context))
        let states = after.map { $0.done ? "1" : "0" }.joined(separator: ",")
        return result(id(note), native: ["doneFlags": states], sqlite: { n in
            let flags = n.document?.runs.filter { $0.paragraph?.kind == .checklist }.map { $0.paragraph?.checked == true ? "1" : "0" }.joined(separator: ",") ?? ""
            return flags == states ? ["doneFlags": flags] : nil
        })
    }

    public func toggleChecklist(_ ref: String, selection: ChecklistSelection, done: Bool?, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }
        return try setChecklist(ref, allowShared: allowShared, select: { items in
            switch selection {
            case .index(let index): return Set(items.filter { $0.index == index }.map(\.index))
            case .text(let text):
                let matches = items.filter { $0.text == text }; guard matches.count <= 1 else { throw NotesError("ambiguous_checklist_item", "More than one checklist item has that text. Use --index.") }
                return Set(matches.map(\.index))
            }
        }, done: done)
    }
    public func setAllChecklist(_ ref: String, done: Bool, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; return try setChecklist(ref, allowShared: allowShared, select: { Set($0.map(\.index)) }, done: done)
    }
    public func deleteCompleted(_ ref: String, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }
        let context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared)
        let items = try checklist(note).filter(\.done); guard !items.isEmpty else { return result(id(note), native: ["deleted": "0"], sqlite: nil, message: "No completed items.") }
        do {
            let editor = try NCBodyEditor(note: note), text = editor.original.string as NSString; try editor.begin()
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

    public func setPinned(_ ref: String, pinned: Bool, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared)
        do { try NCNotesRuntime.setPinned(pinned, note: note); try save(context, notes: [note]) } catch { context.rollback(); throw nativeError(error) }
        let fresh = try self.note(id(note), in: context), state = value(fresh, "isPinned") as? Bool == true
        return result(id(note), native: ["pinned": "\(state)"], sqlite: { $0.summary.isPinned == pinned ? ["pinned": "\(pinned)"] : nil })
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
        try editor.begin(); try editor.insert(NSAttributedString(string: "\u{fffc}", attributes: [.init("TTStyle"): style, .init("NSAttachment"): marker]), at: UInt(at))
    }

    public func addTag(_ ref: String, tag: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let name = try normalizedTag(tag), context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared)
        do {
            let editor = try NCBodyEditor(note: note), attachmentID = try NCNotesRuntime.makeTag(name, in: note)
            try insertMarker(editor, original: editor.original, id: attachmentID, type: "com.apple.notes.inlinetextattachment.hashtag", position: position)
            try editor.finish(); try NCNotesRuntime.save(context)
            if let attachment = try fetch("ICInlineAttachment", predicate: NSPredicate(format: "identifier == %@", attachmentID), in: context, limit: 1).first { try NCNotesRuntime.reviveTagAttachment(attachment) }
            try save(context, notes: [note])
        } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        return result(id(note), native: ["tag": name], sqlite: { $0.summary.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? ["tag": name] : nil })
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
        lock.lock(); defer { lock.unlock() }; let name = try normalizedTag(tag), context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared)
        let matches = try inlineMatches(note, type: "com.apple.notes.inlinetextattachment.hashtag", label: name)
        guard !matches.isEmpty else { throw NotesError("tag_not_found", "The note does not contain that native tag.") }
        do { let editor = try NCBodyEditor(note: note); try editor.begin(); for row in matches.sorted(by: { $0.1.location > $1.1.location }) { try editor.delete(row.1); try NCNotesRuntime.markForDeletion(row.0) }; try editor.finish(); try save(context, notes: [note]) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        return result(id(note), native: ["removed": name], sqlite: { !$0.summary.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? ["removed": name] : nil })
    }

    fileprivate func hashtag(_ name: String, context: NSManagedObjectContext) throws -> NSManagedObject {
        var rows = try fetch("ICHashtag", predicate: NSPredicate(value: true), in: context).filter { tag in
            guard value(tag, "markedForDeletion") as? Bool != true else { return false }
            return [value(tag, "displayText") as? String, value(tag, "standardizedContent") as? String]
                .compactMap { $0?.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
                .contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        if rows.isEmpty {
            let inline = try fetch("ICInlineAttachment", predicate: NSPredicate(format: "altText ==[c] %@ OR altText ==[c] %@", name, "#" + name), in: context)
            rows = inline.flatMap { attachment in
                attachment.entity.relationshipsByName.keys.compactMap { key in
                    (value(attachment, key) as? NSManagedObject).flatMap { $0.entity.name == "ICHashtag" ? $0 : nil }
                }
            }
        }
        guard !rows.isEmpty else { throw NotesError("tag_not_found", "No native tag matches.") }
        let standardized = Set(rows.compactMap { (value($0, "standardizedContent") as? String)?.lowercased() })
        guard standardized.count <= 1 else { throw NotesError("ambiguous_tag", "Several native tags match.") }
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

    public func renameTag(_ tag: String, to: String, expectedCount: Int) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let old = try normalizedTag(tag), new = try normalizedTag(to), context = try context(), uses = try tagUses(old, context: context)
        guard uses.count == expectedCount else { throw NotesError("expected_count_mismatch", "Tag is used by \(uses.count) notes/items, not \(expectedCount).") }
        guard !uses.contains(where: { isShared($0.0) }) else { throw NotesError("shared_write_refused", "Global tag changes refuse shared notes.") }
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

    public func deleteTag(_ tag: String, expectedCount: Int) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let name = try normalizedTag(tag), context = try context(), uses = try tagUses(name, context: context)
        guard uses.count == expectedCount else { throw NotesError("expected_count_mismatch", "Tag is used \(uses.count) times, not \(expectedCount).") }
        guard !uses.contains(where: { isShared($0.0) || value($0.0, "isPasswordProtected") as? Bool == true }) else { throw NotesError("unsafe_global_tag_delete", "A use is shared or locked; nothing changed.") }
        let grouped = Dictionary(grouping: uses, by: { id($0.0) })
        do {
            for rows in grouped.values { guard let note = rows.first?.0 else { continue }; let editor = try NCBodyEditor(note: note); try editor.begin(); for row in rows.sorted(by: { $0.2.location > $1.2.location }) { try editor.delete(row.2); try NCNotesRuntime.markForDeletion(row.1) }; try editor.finish() }
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

    public func insertNoteLink(_ ref: String, target: String, text: String?, position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let context = try context(), source = try note(ref, in: context), destination = try note(target, in: context); try guardWritable(source, allowShared: allowShared)
        guard id(source) != id(destination) else { throw NotesError("invalid_note_link", "A note cannot link to itself.") }
        do { let editor = try NCBodyEditor(note: source), attachmentID = try NCNotesRuntime.makeNoteLink(to: destination, from: source, text: text ?? title(destination)); try insertMarker(editor, original: editor.original, id: attachmentID, type: "com.apple.notes.inlinetextattachment.link", position: position); try editor.finish(); try save(context, notes: [source]) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let read = try links(id(source))
        let destinationID = id(destination)
        return result(id(source), native: ["target": destinationID, "linkCount": "\(read.count)"], sqlite: { n in n.document?.runs.contains(where: { $0.attachment?.typeUTI.contains("inlinetextattachment.link") == true }) == true ? ["target": destinationID] : nil })
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
    public func links(_ ref: String) throws -> [NativeNoteLink] { lock.lock(); defer { lock.unlock() }; let c = try context(); return try linkRows(note(ref, in: c)) }
    public func backlinks(_ ref: String) throws -> [NativeNoteLink] {
        lock.lock(); defer { lock.unlock() }
        let context = try context(), target = id(try note(ref, in: context))
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

    public func insertText(_ ref: String, text: String, position: Int, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let (note, after) = try mutateBody(ref, allowShared: allowShared) { _, editor, original in guard (0...original.length).contains(position) else { throw NotesError("invalid_range", "Position exceeds note length.") }; try editor.begin(); try editor.insert(NSAttributedString(string: text), at: UInt(position)) }
        return result(id(note), native: ["length": "\(after.length)"], sqlite: { $0.document?.text.utf16.count == after.length ? ["length": "\(after.length)"] : nil })
    }
    public func deleteRange(_ ref: String, range: UTF16Range, allowShared: Bool) throws -> NativeWriteResult { try replaceRange(ref, range: range, text: "", allowShared: allowShared) }
    public func replaceRange(_ ref: String, range: UTF16Range, text: String, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let (note, after) = try mutateBody(ref, allowShared: allowShared) { _, editor, original in let r = try self.valid(range, length: original.length); try editor.begin(); try editor.delete(r); try editor.insert(NSAttributedString(string: text), at: UInt(r.location)) }
        return result(id(note), native: ["length": "\(after.length)"], sqlite: { $0.document?.text.utf16.count == after.length ? ["length": "\(after.length)"] : nil })
    }
    public func searchOffsets(_ ref: String, text: String, caseInsensitive: Bool) throws -> [UTF16Range] {
        lock.lock(); defer { lock.unlock() }; guard !text.isEmpty else { return [] }; let c = try context(), source = try body(note(ref, in: c)).string as NSString
        var rows: [UTF16Range] = [], start = 0
        while start <= source.length { let found = source.range(of: text, options: caseInsensitive ? [.caseInsensitive, .diacriticInsensitive] : [], range: NSRange(location: start, length: source.length - start)); if found.location == NSNotFound { break }; rows.append(UTF16Range(location: found.location, length: found.length)); start = NSMaxRange(found) }
        return rows
    }

    public func setParagraphStyle(_ ref: String, range: UTF16Range, style: NativeParagraphStyle, indent: Int?, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let (note, after) = try mutateBody(ref, allowShared: allowShared) { _, editor, original in
            let target = try self.valid(range, length: original.length, allowEmpty: false)
            var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
            original.enumerateAttributes(in: target) { attrs, run, _ in runs.append((run, attrs)) }
            var writes: [(NSRange, [NSAttributedString.Key: Any])] = []
            for (run, attrs) in runs {
                var copy = attrs; let old = attrs[.init("TTStyle")] as AnyObject?
                copy[.init("TTStyle")] = try NCNotesRuntime.paragraphStyle(style.number, indent: indent ?? (self.value(old, "indent") as? Int ?? 0), quote: style == .blockquote ? 1 : (self.value(old, "blockQuoteLevel") as? Int ?? 0), checked: style == .checklist ? 0 : -1, basedOn: old)
                writes.append((run, copy))
            }
            try editor.begin(); for row in writes { try editor.setAttributes(row.1, range: row.0) }
        }
        let target = try valid(range, length: after.length, allowEmpty: false)
        var nativeMatches = true
        after.enumerateAttribute(.init("TTStyle"), in: target) { raw, _, _ in
            guard let raw = raw as AnyObject? else { nativeMatches = false; return }
            let styleMatches = style == .blockquote ? (value(raw, "style") as? Int == 3 && (value(raw, "blockQuoteLevel") as? Int ?? 0) > 0) : value(raw, "style") as? Int == style.number
            let indentMatches = indent.map { value(raw, "indent") as? Int == $0 } ?? true
            nativeMatches = nativeMatches && styleMatches && indentMatches
        }
        return result(id(note), native: ["style": style.rawValue, "location": "\(range.location)", "length": "\(range.length)"], nativeVerified: nativeMatches,
                      sqlite: { n in
            guard let document = n.document else { return nil }
            let runs = Self.documentRuns(document, in: range)
            guard !runs.isEmpty, runs.allSatisfy({ $0.paragraph?.kind.rawValue == style.rawValue && (indent == nil || $0.paragraph?.indent == indent) }) else { return nil }
            return ["style": style.rawValue, "location": "\(range.location)", "length": "\(range.length)"]
        })
    }

    public func setInlineFormat(_ ref: String, range: UTF16Range, format: InlineFormat, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }
        let requestedColor = try format.color.map(Self.color)
        let (note, after) = try mutateBody(ref, allowShared: allowShared) { _, editor, original in
            let target = try self.valid(range, length: original.length, allowEmpty: false); var writes: [(NSRange, [NSAttributedString.Key: Any])] = []
            original.enumerateAttributes(in: target) { attrs, run, _ in
                var copy = attrs, hints = copy[.init("TTHints")] as? Int ?? 0
                if let bold = format.bold { hints = bold ? hints | 1 : hints & ~1 }; if let italic = format.italic { hints = italic ? hints | 2 : hints & ~2 }; copy[.init("TTHints")] = hints == 0 ? nil : hints
                if let underline = format.underline { copy[.init("TTUnderline")] = underline ? 1 : nil }; if let strike = format.strike { copy[.init("TTStrikethrough")] = strike ? 1 : nil }
                if format.clearLink { copy[.init("NSLink")] = nil } else if let link = format.link { copy[.init("NSLink")] = URL(string: link) ?? link }
                if format.clearColor { copy[.init("TTColor")] = nil } else if let requestedColor { copy[.init("TTColor")] = requestedColor }
                writes.append((run, copy))
            }
            try editor.begin(); for row in writes { try editor.setAttributes(row.1, range: row.0) }
        }
        let target = try valid(range, length: after.length, allowEmpty: false)
        var nativeMatches = true
        after.enumerateAttributes(in: target) { attrs, _, _ in nativeMatches = nativeMatches && Self.matches(attrs, format: format) }
        return result(id(note), native: ["formatted": "true", "location": "\(range.location)", "length": "\(range.length)"], nativeVerified: nativeMatches,
                      sqlite: { n in
            guard let document = n.document else { return nil }
            let runs = Self.documentRuns(document, in: range)
            guard !runs.isEmpty, runs.allSatisfy({ Self.matches($0, format: format) }) else { return nil }
            return ["formatted": "true", "location": "\(range.location)", "length": "\(range.length)"]
        })
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
    fileprivate static func matches(_ attrs: [NSAttributedString.Key: Any], format: InlineFormat) -> Bool {
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
        return true
    }
    fileprivate static func color(_ text: String) throws -> CGColor {
        let value = text.trimmingCharacters(in: CharacterSet(charactersIn: "#")); guard value.count == 6, let rgb = Int(value, radix: 16) else { throw NotesError("invalid_color", "Use a six-digit hex color.") }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1).cgColor
    }

    public func insertFile(_ ref: String, file: URL, position: Int?, imageView: String?, allowShared: Bool) throws -> NativeAttachmentResult {
        lock.lock(); defer { lock.unlock() }; var directory: ObjCBool = false; guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue, FileManager.default.isReadableFile(atPath: file.path) else { throw NotesError("invalid_file", "The file is not readable.") }
        let context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared)
        var attachmentID = "", kind: NSString?, at = 0
        do {
            let editor = try NCBodyEditor(note: note); at = position ?? editor.original.length
            attachmentID = try NCNotesRuntime.addFile(file, to: note, title: file.lastPathComponent, type: &kind)
            guard let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@", attachmentID), in: context, limit: 1).first else { throw NotesError("attachment_not_found", "Notes created no attachment record.") }
            if let imageView { guard ["small", "large"].contains(imageView) else { throw NotesError("invalid_image_view", "Use small or large.") }; try NCNotesRuntime.setPreferredImageSize(imageView, attachment: attachment) }
            try insertMarker(editor, original: editor.original, id: attachmentID, type: kind as String? ?? "public.data", position: position); try editor.finish(); try save(context, notes: [note])
        } catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let count = attachmentMarkers(try body(try self.note(id(note), in: context))).filter { $0.2 == attachmentID }.count
        guard count == 1 else { throw NotesError("attachment_placement_mismatch", "Expected one placement after save; found \(count). Do not retry.") }
        let write = result(id(note), native: ["attachmentID": attachmentID, "placements": "1"], sqlite: { n in n.attachments.filter { $0.id == attachmentID }.count == 1 ? ["attachments": "1"] : nil })
        return NativeAttachmentResult(attachmentID: attachmentID, typeUTI: kind as String? ?? "public.data", position: at, write: write)
    }

    public func deleteAttachment(_ ref: String, attachmentID: String, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared)
        let markers = attachmentMarkers(try body(note)).filter { $0.2 == attachmentID }; guard markers.count == 1 else { throw NotesError("attachment_placement_mismatch", "Attachment must have exactly one placement; found \(markers.count).") }
        guard let attachment = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@ AND note == %@", attachmentID, note), in: context, limit: 1).first else { throw NotesError("attachment_not_found", "Attachment does not belong to this note.") }
        do { let editor = try NCBodyEditor(note: note); try editor.begin(); try editor.delete(markers[0].0); try NCNotesRuntime.markForDeletion(attachment); try editor.finish(); try save(context, notes: [note]) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        return result(id(note), native: ["deletedAttachment": attachmentID], sqlite: { !$0.attachments.contains(where: { $0.id == attachmentID }) ? ["deletedAttachment": attachmentID] : nil })
    }

    fileprivate func table(_ attachmentID: String, note: NSManagedObject, context: NSManagedObjectContext) throws -> NSManagedObject {
        guard let item = try fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@ AND note == %@ AND typeUTI == %@", attachmentID, note, "com.apple.notes.table"), in: context, limit: 1).first else { throw NotesError("table_not_found", "No table attachment matches this note.") }; return item
    }
    fileprivate func tableRows(_ attachment: NSManagedObject) throws -> [[String]] { let editor = try NCTableEditor(attachment: attachment); return (0..<editor.rowCount).map { r in (0..<editor.columnCount).map { c in editor.text(column: c, row: r) } } }
    public func createTable(_ ref: String, rows: [[String]], position: Int?, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let width = rows.map(\.count).max() ?? 0; guard !rows.isEmpty, width > 0 else { throw NotesError("invalid_table", "A table needs at least one cell.") }
        let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }, context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared)
        var tableID = ""
        do { let editor = try NCBodyEditor(note: note); tableID = try editor.addTable(padded.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }.joined(separator: "\n")); try insertMarker(editor, original: editor.original, id: tableID, type: "com.apple.notes.table", position: position); try editor.finish(); try save(context, notes: [note]); let attachment = try table(tableID, note: try self.note(id(note), in: context), context: context); if try tableRows(attachment) != padded { let edit = try NCTableEditor(attachment: attachment), style = try NCNotesRuntime.paragraphStyle(3, indent: 0, quote: 0, checked: -1, basedOn: nil); for r in padded.indices { for c in padded[r].indices { try edit.setCell(column: c, row: r, text: padded[r][c], style: style) } }; try edit.save(); try save(context, notes: [note]) } }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        return result(id(note), native: ["tableID": tableID, "rows": "\(rows.count)", "columns": "\(width)"], sqlite: { $0.document?.tables?[tableID]?.count == rows.count ? ["tableID": tableID, "rows": "\(rows.count)"] : nil })
    }
    public func editTable(_ ref: String, attachmentID: String, row: Int, column: Int, text: String, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); let attachment = try table(attachmentID, note: note, context: context)
        do { let editor = try NCTableEditor(attachment: attachment); guard row >= 0, row < editor.rowCount, column >= 0, column < editor.columnCount else { throw NotesError("invalid_table_cell", "Cell is outside the table.") }; let style = try NCNotesRuntime.paragraphStyle(3, indent: 0, quote: 0, checked: -1, basedOn: nil); try editor.setCell(column: column, row: row, text: text, style: style); try editor.save(); try save(context, notes: [note]) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        return result(id(note), native: ["tableID": attachmentID, "cell": "\(row),\(column)", "text": text], sqlite: { $0.document?.tables?[attachmentID]?[safe: row]?[safe: column] == text ? ["cell": "\(row),\(column)"] : nil })
    }
    public func resizeTable(_ ref: String, attachmentID: String, axis: String, index: Int, add: Bool, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; guard ["row", "column"].contains(axis), index >= 0 else { throw NotesError("invalid_table_resize", "Axis must be row or column and index nonnegative.") }; let context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared); let attachment = try table(attachmentID, note: note, context: context)
        do {
            let editor = try NCTableEditor(attachment: attachment), count = axis == "row" ? editor.rowCount : editor.columnCount
            guard add ? index <= count : index < count else { throw NotesError("invalid_table_resize", "Index is outside the table.") }
            if !add && count <= 1 { throw NotesError("invalid_table_resize", "A table must keep one \(axis).") }
            if axis == "row" { if add { try editor.insertRow(index) } else { try editor.removeRow(index) } }
            else { if add { try editor.insertColumn(index) } else { try editor.removeColumn(index) } }
            try editor.save(); try save(context, notes: [note])
        }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
        let rows = try tableRows(try table(attachmentID, note: try self.note(id(note), in: context), context: context))
        return result(id(note), native: ["rows": "\(rows.count)", "columns": "\(rows.first?.count ?? 0)"], sqlite: { $0.document?.tables?[attachmentID].map { ["rows": "\($0.count)", "columns": "\($0.first?.count ?? 0)"] } })
    }

    public func duplicate(_ ref: String, title newTitle: String?, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let context = try context(), source = try note(ref, in: context); try guardWritable(source, allowShared: allowShared); guard let folder = value(source, "folder") as? NSManagedObject else { throw NotesError("folder_not_found", "The source note has no folder.") }
        do { let copy = try NCNotesRuntime.duplicateNote(source, folder: folder); if let newTitle { copy.setValue(newTitle, forKey: "title") }; try save(context, notes: [copy]); let copyTitle = title(copy); return result(id(copy), native: ["duplicatedFrom": id(source), "title": copyTitle], sqlite: { $0.summary.title == copyTitle ? ["title": $0.summary.title] : nil }) }
        catch { context.rollback(); throw (error as? NotesError) ?? nativeError(error) }
    }

    fileprivate func appleMove(_ note: NSManagedObject, to folder: NSManagedObject) throws {
        let script = "on run argv\ntell application \"Notes\" to move note id (item 1 of argv) to folder id (item 2 of argv)\nend run", process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-e", script, "--", note.objectID.uriRepresentation().absoluteString, folder.objectID.uriRepresentation().absoluteString]; let errorPipe = Pipe(); process.standardError = errorPipe; process.standardOutput = FileHandle.nullDevice; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw NotesError("native_sync_failed", String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
    }
    public func restore(_ ref: String, folder destination: String?, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let context = try context(), note = try note(ref, in: context); try guardWritable(note, allowShared: allowShared, allowTrash: true)
        let target: NSManagedObject
        if let destination { target = try folder(destination, in: context) }
        else { guard let original = ["folderBeforeDeletion", "originalFolder", "previousFolder"].compactMap({ value(note, $0) as? NSManagedObject }).first else { throw NotesError("restore_folder_required", "NotesShared exposes no original folder for this note. Pass --folder.") }; target = original }
        if (isShared(note) || isSharedFolder(target)) && !allowShared { throw NotesError("shared_write_refused", "Restoring changes shared access. Pass --allow-shared.") }
        try appleMove(note, to: target); context.refreshAllObjects(); let restored = try self.note(id(note), in: context)
        guard let restoredFolder = value(restored, "folder") as? NSManagedObject else {
            return result(id(note), native: ["restored": "false"], nativeVerified: false,
                          sqlite: { !$0.summary.isDeleted ? ["restored": "true"] : nil }, message: "Notes.app did not expose a destination folder after the move.")
        }
        return result(id(note), native: ["folderID": id(restoredFolder), "restored": "true"], sqlite: { !$0.summary.isDeleted ? ["restored": "true"] : nil })
    }
    public func moveFolder(_ ref: String, parent: String?, allowShared: Bool) throws -> NativeWriteResult {
        lock.lock(); defer { lock.unlock() }; let context = try context(), moved = try folder(ref, in: context), target = try parent.map { try folder($0, in: context) }
        if (isSharedFolder(moved) || target.map(isSharedFolder) == true) && !allowShared { throw NotesError("shared_write_refused", "The folder is shared. Pass --allow-shared.") }
        if let target { var current: NSManagedObject? = target; while let item = current { if item == moved { throw NotesError("invalid_folder_move", "A folder cannot move inside itself.") }; current = value(item, "parent") as? NSManagedObject } }
        guard (value(moved, "account") as? NSManagedObject) == target.flatMap({ value($0, "account") as? NSManagedObject }) || target == nil else { throw NotesError("invalid_folder_move", "Folders move only within one account.") }
        do { try NCNotesRuntime.moveFolder(moved, parent: target); try NCNotesRuntime.save(context) } catch { context.rollback(); throw nativeError(error) }
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

    public func writeMarkdown(_ ref: String, markdown: String, dryRun: Bool, backup: Bool, allowShared: Bool) throws -> NativeWriteResult {
        try MarkdownNativeWriter(owner: self).write(ref: ref, markdown: markdown, dryRun: dryRun, backup: backup, allowShared: allowShared)
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

    func write(ref: String, markdown: String, dryRun: Bool, backup: Bool, allowShared: Bool) throws -> NativeWriteResult {
        owner.lock.lock(); defer { owner.lock.unlock() }
        let lines = try parse(markdown), context = try owner.context(), note = try owner.note(ref, in: context)
        try owner.guardWritable(note, allowShared: allowShared)
        if backup { try makeBackup(ref: owner.id(note)) }
        if dryRun {
            return owner.result(owner.id(note), native: ["dryRun": "true", "paragraphs": "\(lines.count)"], message: "No write made.")
        }
        do {
            let editor = try NCBodyEditor(note: note), existing = owner.attachmentMarkers(editor.original)
            let preservedIDs = attachmentReferences(markdown)
            guard Set(preservedIDs).count == preservedIDs.count else { throw NotesError("duplicate_attachment_reference", "Each notescli-attachment ID may appear once.") }
            let existingGroups = Dictionary(grouping: existing, by: { $0.2 })
            guard existingGroups.values.allSatisfy({ $0.count == 1 }) else { throw NotesError("attachment_placement_mismatch", "An existing attachment has more than one placement; nothing was saved.") }
            let existingByID = existingGroups.mapValues { ($0[0].1, $0[0].3) }
            for id in preservedIDs where existingByID[id] == nil { throw NotesError("attachment_not_found", "Attachment \(id) does not belong to this note.") }
            let kept = Set(preservedIDs)
            for marker in existing where !kept.contains(marker.2) {
                if let attachment = try owner.fetch("ICAttachment", predicate: NSPredicate(format: "identifier == %@ AND note == %@", marker.2, note), in: context, limit: 1).first {
                    throw NotesError("attachment_would_be_lost", "Markdown omitted attachment \(owner.id(attachment)); nothing was saved.")
                }
            }
            var tableIDs: [String] = []
            for line in lines { if let rows = line.table { tableIDs.append(try editor.addTable(rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))) } }
            var tableIndex = 0
            let built = NSMutableAttributedString()
            for (index, line) in lines.enumerated() {
                let style = try NCNotesRuntime.paragraphStyle(line.style.number, indent: line.indent,
                                                              quote: line.style == .blockquote ? 1 : 0,
                                                              checked: line.done.map { $0 ? 1 : 0 } ?? -1, basedOn: nil)
                if let _ = line.table {
                    let id = tableIDs[tableIndex]; tableIndex += 1
                    let marker = try NCNotesRuntime.attachmentMarker(id: id, type: "com.apple.notes.table")
                    built.append(NSAttributedString(string: "\u{fffc}", attributes: [.init("TTStyle"): style, .init("NSAttachment"): marker]))
                } else {
                    built.append(try inline(line.text, style: style, note: note, context: context, existing: existingByID))
                }
                if index < lines.count - 1 { built.append(NSAttributedString(string: "\n", attributes: [.init("TTStyle"): style])) }
            }
            try editor.begin(); try editor.delete(NSRange(location: 0, length: editor.original.length)); try editor.insert(built, at: 0); try editor.finish()
            try owner.save(context, notes: [note])
        } catch { context.rollback(); throw (error as? NotesError) ?? owner.nativeError(error) }
        let nativeBody = try owner.body(try owner.note(owner.id(note), in: context))
        return owner.result(owner.id(note), native: ["utf16Length": "\(nativeBody.length)", "paragraphs": "\(lines.count)"],
                            sqlite: { n in n.document?.text.utf16.count == nativeBody.length ? ["utf16Length": "\(nativeBody.length)", "hasChecklist": "\(n.summary.hasChecklist)"] : nil })
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
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(notescli-attachment:([A-Za-z0-9_-]+)\)"#) else { return [] }
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
        if raw.last == "", !result.isEmpty { result.removeLast() }
        return result
    }

    fileprivate func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }; if text.hasSuffix("|") { text.removeLast() }
        return text.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<br>", with: "\n") }
    }

    fileprivate func inline(_ text: String, style: Any, note: NSManagedObject, context: NSManagedObjectContext,
                        existing: [String: (AnyObject, String)]) throws -> NSAttributedString {
        let output = NSMutableAttributedString(), source = text as NSString
        let pattern = #"!\[[^\]]*\]\(notescli-attachment:([^)]+)\)|\[([^\]]+)\]\(([^)]+)\)|\*\*([^*]+)\*\*|~~([^~]+)~~|<u>(.*?)</u>|\*([^*]+)\*"#
        let regex = try NSRegularExpression(pattern: pattern), matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var cursor = 0
        func append(_ value: String, _ extra: [NSAttributedString.Key: Any] = [:]) { var attrs: [NSAttributedString.Key: Any] = [.init("TTStyle"): style]; attrs.merge(extra) { _, new in new }; output.append(NSAttributedString(string: value, attributes: attrs)) }
        for match in matches {
            if match.range.location > cursor { append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))) }
            if match.range(at: 1).location != NSNotFound {
                let id = source.substring(with: match.range(at: 1)); guard let item = existing[id] else { throw NotesError("attachment_not_found", "Attachment \(id) is not in this note.") }; append("\u{fffc}", [.init("NSAttachment"): item.0])
            } else if match.range(at: 2).location != NSNotFound {
                let label = source.substring(with: match.range(at: 2)), url = source.substring(with: match.range(at: 3))
                if url.hasPrefix("applenotes://showNote?identifier=") || url.hasPrefix("note:") {
                    let targetRef = url.hasPrefix("note:") ? String(url.dropFirst(5)) : String(url.split(separator: "=").last ?? "")
                    let target = try owner.note(targetRef, in: context), id = try NCNotesRuntime.makeNoteLink(to: target, from: note, text: label), marker = try NCNotesRuntime.attachmentMarker(id: id, type: "com.apple.notes.inlinetextattachment.link"); append("\u{fffc}", [.init("NSAttachment"): marker])
                } else { append(label, [.init("NSLink"): URL(string: url) ?? url]) }
            } else if match.range(at: 4).location != NSNotFound { append(source.substring(with: match.range(at: 4)), [.init("TTHints"): 1]) }
            else if match.range(at: 5).location != NSNotFound { append(source.substring(with: match.range(at: 5)), [.init("TTStrikethrough"): 1]) }
            else if match.range(at: 6).location != NSNotFound { append(source.substring(with: match.range(at: 6)), [.init("TTUnderline"): 1]) }
            else if match.range(at: 7).location != NSNotFound { append(source.substring(with: match.range(at: 7)), [.init("TTHints"): 2]) }
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length { append(source.substring(from: cursor)) }
        return output
    }
}
