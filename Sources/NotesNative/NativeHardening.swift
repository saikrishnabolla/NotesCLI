import Foundation
import NotesCore
import NotesNativeObjC

enum NativePrivateMessageProbe {
    static func integer(_ selector: String, of object: AnyObject) throws -> Int {
        try NCNotesRuntime.checkedInteger(selector, of: object).intValue
    }
}

enum NativeVerificationRules {
    static func exactText(_ source: String, text: String, location: Int) -> Bool {
        let source = source as NSString
        let textLength = (text as NSString).length
        guard location >= 0, textLength >= 0, location <= source.length, textLength <= source.length - location else { return false }
        return source.substring(with: NSRange(location: location, length: textLength)) == text
    }

    static func exactLink(_ links: [NativeNoteLink], attachmentID: String, targetID: String) -> Bool {
        links.filter {
            $0.attachmentID == attachmentID && $0.targetID.caseInsensitiveCompare(targetID) == .orderedSame
        }.count == 1
    }

    static func exactTable(_ actual: [[String]]?, expected: [[String]]) -> Bool {
        actual == expected
    }

    static func exactReplacement(before: String, after: String, range: NSRange, text: String) -> Bool {
        let source = before as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { return false }
        let expected = source.replacingCharacters(in: range, with: text)
        let expectedLength = source.length - range.length + (text as NSString).length
        return (after as NSString).length == expectedLength && after == expected
    }

    static func checklistItem(_ items: [ChecklistItem], expected: ChecklistItem, done: Bool) -> Bool {
        items.filter {
            $0.index == expected.index && $0.text == expected.text && $0.range == expected.range && $0.done == done
        }.count == 1
    }

    static func attachment(_ attachmentIDs: [String], id: String) -> Bool {
        attachmentIDs.filter { $0 == id }.count == 1
    }

    static func sameMarkerMultiset(_ lhs: [(String, String)], _ rhs: [(String, String)]) -> Bool {
        func counts(_ values: [(String, String)]) -> [String: Int] {
            values.reduce(into: [:]) { $0[$1.0 + "\u{0}" + $1.1, default: 0] += 1 }
        }
        return counts(lhs) == counts(rhs)
    }
}

enum NativeSharedWriteGuard {
    static func require(isShared: Bool, allowShared: Bool, isReadOnly: Bool?) throws {
        guard isShared else { return }
        guard allowShared else { throw NotesError("shared_write_refused", "The item is shared. Pass --allow-shared to confirm the write.") }
        guard let isReadOnly else {
            throw NotesError("shared_permission_unknown", "Notes did not expose the current participant's write role; nothing was changed.")
        }
        if isReadOnly { throw NotesError("shared_read_only", "The current participant has read-only access to this shared item.") }
    }
}

enum NativeDestinationResolver {
    static func folderID(_ location: DefaultNotesLocation?) throws -> String {
        guard let folderID = location?.folderID, !folderID.isEmpty else {
            throw NotesError("folder_not_found", "The default Notes folder could not be resolved.")
        }
        return folderID
    }
}

enum NativeStaleGuard {
    static func validate(
        loadedDate: Date?,
        snapshotDate: Date?,
        refreshedDate: Date?,
        loadedTarget: NSAttributedString?,
        refreshedTarget: NSAttributedString?
    ) throws {
        guard loadedDate != snapshotDate else { return }
        guard refreshedDate == snapshotDate else {
            throw NotesError("stale_note", "Notes changed the note while the native transaction was starting.")
        }
        if let loadedTarget, let refreshedTarget, !loadedTarget.isEqual(to: refreshedTarget) {
            throw NotesError("stale_note", "Notes changed the target text. Resolve the range again before retrying.")
        }
    }
}
