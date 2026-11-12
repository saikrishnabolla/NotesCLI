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

    static func exactRuns(_ document: NoteDocument, range: UTF16Range, match: (AttributeRun) -> Bool) -> Bool {
        var offset = 0, selected: [AttributeRun] = []
        let end = range.location + range.length
        for run in document.runs {
            let runEnd = offset + run.length
            if offset < end && runEnd > range.location { selected.append(run) }
            offset = runEnd
        }
        return !selected.isEmpty && selected.allSatisfy(match)
    }
}

enum SnapshotRestoreVerification {
    static func matches(expected: Note, actual: Note) -> Bool {
        guard expected.summary.title == actual.summary.title,
              let expectedDocument = expected.document,
              let actualDocument = actual.document,
              matches(expectedDocument, actualDocument) else { return false }
        return true
    }

    static func matches(_ expected: NoteDocument, _ actual: NoteDocument) -> Bool {
        guard expected.text == actual.text,
              signatures(expected.runs) == signatures(actual.runs),
              expected.tables == actual.tables else { return false }
        let expectedCells = expected.tableCells ?? [:]
        let actualCells = actual.tableCells ?? [:]
        guard expectedCells.keys == actualCells.keys else { return false }
        for id in expectedCells.keys {
            guard let left = expectedCells[id], let right = actualCells[id], left.count == right.count else { return false }
            for row in left.indices {
                guard left[row].count == right[row].count else { return false }
                for column in left[row].indices {
                    guard matches(left[row][column].document, right[row][column].document) else { return false }
                }
            }
        }
        return true
    }

    private struct RunSignature: Equatable {
        var length: Int
        var paragraph: ParagraphSignature?
        var font: FontStyle
        var link: String?
        var color: String?
        var highlight: HighlightColor?
        var attachment: InlineRef?
    }

    private struct ParagraphSignature: Equatable {
        var kind: ParagraphStyle.Kind
        var alignment: Int?
        var writingDirection: Int?
        var blockQuoteLevel: Int?
        var indent: Int
        var checked: Bool?
        var startNumber: Int?
        var collapsed: Bool?
    }

    private static func signatures(_ runs: [AttributeRun]) -> [RunSignature] {
        var result: [RunSignature] = []
        for run in runs where run.length > 0 {
            let paragraph = run.paragraph.map {
                ParagraphSignature(kind: $0.kind, alignment: $0.alignment, writingDirection: $0.writingDirection,
                                   blockQuoteLevel: $0.blockQuoteLevel, indent: $0.indent, checked: $0.checked,
                                   startNumber: $0.startNumber, collapsed: $0.collapsed)
            }
            let next = RunSignature(length: run.length, paragraph: paragraph, font: run.font, link: run.link,
                                    color: run.color, highlight: run.highlight, attachment: run.attachment)
            if let last = result.last,
               last.paragraph == next.paragraph, last.font == next.font, last.link == next.link,
               last.color == next.color, last.highlight == next.highlight, last.attachment == next.attachment {
                result[result.count - 1].length += next.length
            } else {
                result.append(next)
            }
        }
        return result
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
