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

    static func checklistItem(_ items: [ChecklistItem], expected: ChecklistItem, done: Bool) -> Bool {
        items.filter {
            $0.index == expected.index && $0.text == expected.text && $0.range == expected.range && $0.done == done
        }.count == 1
    }

    static func attachment(_ attachmentIDs: [String], id: String) -> Bool {
        attachmentIDs.filter { $0 == id }.count == 1
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
