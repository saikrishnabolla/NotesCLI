import Foundation
import CoreData
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

    static func exactLink(_ links: [NativeNoteLink], attachmentID: String, targetID: String,
                          paragraphID: String? = nil) -> Bool {
        links.filter {
            $0.attachmentID == attachmentID &&
                $0.targetID.caseInsensitiveCompare(targetID) == .orderedSame &&
                (paragraphID == nil && $0.targetParagraphID == nil ||
                 paragraphID != nil && $0.targetParagraphID?.caseInsensitiveCompare(paragraphID!) == .orderedSame)
        }.count == 1
    }

    static func exactTable(_ actual: [[String]]?, expected: [[String]]) -> Bool {
        actual == expected
    }

    static func sameScanCrop(_ lhs: ScanCrop?, _ rhs: ScanCrop?, tolerance: Double = 0.000_001) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)):
            let left = [lhs.bottomLeft, lhs.bottomRight, lhs.topLeft, lhs.topRight]
            let right = [rhs.bottomLeft, rhs.bottomRight, rhs.topLeft, rhs.topRight]
            return zip(left, right).allSatisfy {
                abs($0.x - $1.x) <= tolerance && abs($0.y - $1.y) <= tolerance
            }
        default: return false
        }
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
        guard expected.summary.id.uuid.caseInsensitiveCompare(actual.summary.id.uuid) == .orderedSame,
              expected.summary.title == actual.summary.title,
              expected.summary.isPinned == actual.summary.isPinned,
              let expectedDocument = expected.document,
              let actualDocument = actual.document,
              matches(expectedDocument, actualDocument),
              let expectedAttachments = attachmentSignatures(expected.attachments),
              let actualAttachments = attachmentSignatures(actual.attachments),
              expectedAttachments == actualAttachments,
              familyEvidenceMatches(expected: expected.attachments, actual: actual.attachments) else { return false }
        return true
    }

    struct FileDigest: Equatable, Sendable {
        var sha256: String
        var byteCount: Int
    }

    /// Also compares the archived file bytes with the restored files. `expected` must already use
    /// restored IDs; `attachmentIDMap` maps snapshot IDs to recreated IDs and is empty for kept rows.
    static func matches(
        expected: Note,
        actual: Note,
        archive: SnapshotAttachmentArchive?,
        attachmentIDMap: [String: String],
        fileDigest: (String) -> FileDigest? = defaultFileDigest
    ) -> Bool {
        guard matches(expected: expected, actual: actual) else { return false }
        return archivedFilesMatch(expected: expected, actual: actual, archive: archive,
                                  attachmentIDMap: attachmentIDMap, fileDigest: fileDigest)
    }

    static func defaultFileDigest(_ path: String) -> FileDigest? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              let hash = try? FrozenAttachmentInput.hash(file: url) else { return nil }
        return FileDigest(sha256: hash, byteCount: size)
    }

    /// Compares plain file payloads. Kept rows must be byte-identical. Recreated scan pages and
    /// Paper documents are skipped because Notes rewrites them; the writer verifies those itself.
    static func archivedFilesMatch(
        expected: Note,
        actual: Note,
        archive: SnapshotAttachmentArchive?,
        attachmentIDMap: [String: String],
        fileDigest: (String) -> FileDigest?
    ) -> Bool {
        guard let archive else { return true }
        guard let expectedIndex = flatten(expected.attachments),
              let actualIndex = flatten(actual.attachments) else { return false }
        for material in archive.attachments where material.unavailableReason == nil && material.payloadKind == nil {
            guard let sha256 = material.blobSHA256, let byteCount = material.byteCount else { continue }
            let restoredID = attachmentIDMap[material.id] ?? material.id
            let recreated = attachmentIDMap[material.id] != nil
            if recreated {
                let restoredKind = expectedIndex.byID[restoredID]?.kind
                let parentKind = expectedIndex.parents[restoredID].flatMap { expectedIndex.byID[$0]?.kind }
                if restoredKind == "scan" || parentKind == "scan" ||
                    material.typeUTI.hasPrefix("com.apple.paper.doc") { continue }
            }
            guard expectedIndex.byID[restoredID] != nil,
                  let path = actualIndex.byID[restoredID]?.filePath, !path.isEmpty,
                  let digest = fileDigest(path),
                  digest == FileDigest(sha256: sha256, byteCount: byteCount) else { return false }
        }
        return true
    }

    private struct FlatAttachments {
        var byID: [String: Attachment] = [:]
        var parents: [String: String] = [:]
    }

    private static func flatten(_ attachments: [Attachment]) -> FlatAttachments? {
        var result = FlatAttachments()
        var valid = true
        func visit(_ attachment: Attachment, parentID: String?) {
            if let existing = result.byID[attachment.id] {
                if existing != attachment { valid = false }
            } else {
                result.byID[attachment.id] = attachment
            }
            if let parentID { result.parents[attachment.id] = parentID }
            for childID in attachment.childAttachmentIDs ?? [] where result.parents[childID] == nil {
                result.parents[childID] = attachment.id
            }
            for child in attachment.childAttachments ?? [] { visit(child, parentID: attachment.id) }
        }
        for attachment in attachments { visit(attachment, parentID: nil) }
        return valid ? result : nil
    }

    /// Family-specific fields that a restore must preserve. Optional evidence missing from the
    /// snapshot is not compared.
    private static func familyEvidenceMatches(expected: [Attachment], actual: [Attachment]) -> Bool {
        guard let expectedIndex = flatten(expected), let actualIndex = flatten(actual) else { return false }
        for (id, left) in expectedIndex.byID {
            guard let right = actualIndex.byID[id], sameFamilyEvidence(left, right) else { return false }
        }
        return true
    }

    private static func sameFamilyEvidence(_ expected: Attachment, _ actual: Attachment) -> Bool {
        let isRecordingRoot = expected.kind == "audio" && expected.childAttachmentIDs?.isEmpty == false
        if expected.kind == "scan" || isRecordingRoot {
            guard (expected.childAttachmentIDs ?? []) == (actual.childAttachmentIDs ?? []) else { return false }
            if let children = expected.childAttachments, !children.isEmpty,
               children.map(\.id) != (actual.childAttachments ?? []).map(\.id) { return false }
        }
        if let url = expected.url, actual.url != url { return false }
        if (expected.synapseDataBytes ?? 0) > 0, (actual.synapseDataBytes ?? 0) == 0 { return false }
        if (expected.linkPreviewMetadataBytes ?? 0) > 0, (actual.linkPreviewMetadataBytes ?? 0) == 0 { return false }
        if expected.hasMapLocation == true, actual.hasMapLocation != true { return false }
        for (left, right) in [(expected.mapLatitude, actual.mapLatitude), (expected.mapLongitude, actual.mapLongitude)] {
            if let left, abs((right ?? .infinity) - left) >= 0.000_000_001 { return false }
        }
        if let address = expected.mapAddress, actual.mapAddress != address { return false }
        guard (expected.scanFilter ?? 0) == (actual.scanFilter ?? 0),
              (expected.scanOrientation ?? 0) == (actual.scanOrientation ?? 0),
              (expected.scanHasMarkup == true) == (actual.scanHasMarkup == true),
              (expected.scanHasEmbeddedMarkup == true) == (actual.scanHasEmbeddedMarkup == true) else { return false }
        if let crop = expected.scanCrop,
           !NativeVerificationRules.sameScanCrop(crop, actual.scanCrop, tolerance: 0.000_1) { return false }
        guard ((expected.markupDataBytes ?? 0) > 0) == ((actual.markupDataBytes ?? 0) > 0),
              (expected.hasEmbeddedMarkup == true) == (actual.hasEmbeddedMarkup == true) else { return false }
        if isRecordingRoot {
            if let duration = expected.duration {
                guard let actualDuration = actual.duration,
                      abs(actualDuration - duration) <= max(0.25, duration * 0.05) else { return false }
            }
            if let words = expected.transcriptWords, !words.isEmpty {
                guard RecordingFragments.mismatch(expected: words, actual: actual.transcriptWords ?? []) == nil else {
                    return false
                }
            }
            if let fragments = expected.recordingFragments, !fragments.isEmpty,
               fragments.map(\.id) != (actual.recordingFragments ?? []).map(\.id) { return false }
        }
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
        var attachment: InlineRefSignature?
    }

    private struct InlineRefSignature: Equatable {
        var id: String
        var typeUTI: String
        var displayText: String?
        var url: String?
        var parentAttachmentID: String?
        var parentAttachmentCaptured: Bool?
    }

    private struct AttachmentSignature: Hashable {
        var id: String
        var typeUTI: String
        var parentID: String?
        var handwritingText: String?
        var ocrText: String?
        var imageClassification: String?
    }

    private static func attachmentSignatures(_ attachments: [Attachment]) -> Set<AttachmentSignature>? {
        var types: [String: String] = [:]
        var parents: [String: String] = [:]
        var handwriting: [String: String?] = [:]
        var ocr: [String: String?] = [:]
        var imageClassification: [String: String?] = [:]
        var valid = true
        func record(_ attachment: Attachment, parentID: String?) {
            if let existing = types[attachment.id], existing != attachment.typeUTI { valid = false }
            types[attachment.id] = attachment.typeUTI
            if let existing = handwriting[attachment.id], existing != attachment.handwritingText { valid = false }
            handwriting[attachment.id] = attachment.handwritingText
            if let existing = ocr[attachment.id], existing != attachment.ocrText { valid = false }
            ocr[attachment.id] = attachment.ocrText
            if let existing = imageClassification[attachment.id], existing != attachment.imageClassification { valid = false }
            imageClassification[attachment.id] = attachment.imageClassification
            if let parentID {
                if let existing = parents[attachment.id], existing != parentID { valid = false }
                parents[attachment.id] = parentID
            }
            for childID in attachment.childAttachmentIDs ?? [] {
                if let existing = parents[childID], existing != attachment.id { valid = false }
                parents[childID] = attachment.id
            }
            for child in attachment.childAttachments ?? [] { record(child, parentID: attachment.id) }
        }
        for attachment in attachments { record(attachment, parentID: nil) }
        guard valid, parents.keys.allSatisfy({ types[$0] != nil }) else { return nil }
        return Set(types.map {
            AttachmentSignature(id: $0.key, typeUTI: $0.value, parentID: parents[$0.key],
                                handwritingText: handwriting[$0.key] ?? nil,
                                ocrText: ocr[$0.key] ?? nil,
                                imageClassification: imageClassification[$0.key] ?? nil)
        })
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
        var id: String?
        var checklistID: String?
    }

    private static func signatures(_ runs: [AttributeRun]) -> [RunSignature] {
        var result: [RunSignature] = []
        for run in runs where run.length > 0 {
            let paragraph = run.paragraph.map {
                ParagraphSignature(kind: $0.kind, alignment: $0.alignment, writingDirection: $0.writingDirection,
                                   blockQuoteLevel: $0.blockQuoteLevel, indent: $0.indent, checked: $0.checked,
                                   startNumber: $0.startNumber, collapsed: $0.collapsed,
                                   id: $0.id?.uppercased(), checklistID: $0.checklistID?.uppercased())
            }
            let attachment = run.attachment.map {
                InlineRefSignature(
                    id: $0.id,
                    typeUTI: $0.typeUTI,
                    displayText: $0.typeUTI == "com.apple.m4a-audio" ? nil : $0.displayText,
                    url: $0.url,
                    parentAttachmentID: $0.parentAttachmentID,
                    parentAttachmentCaptured: $0.parentAttachmentCaptured
                )
            }
            let next = RunSignature(length: run.length, paragraph: paragraph, font: run.font, link: run.link,
                                    color: run.color, highlight: run.highlight, attachment: attachment)
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

enum NativeAttachmentOwnership {
    static func belongs(_ attachment: NSManagedObject, to note: NSManagedObject) -> Bool {
        var current: NSManagedObject? = attachment
        var visited: Set<NSManagedObjectID> = []
        while let object = current, visited.insert(object.objectID).inserted {
            if relationship("note", of: object)?.objectID == note.objectID { return true }
            current = relationship("parentAttachment", of: object)
        }
        return false
    }

    private static func relationship(_ key: String, of object: NSManagedObject) -> NSManagedObject? {
        guard object.entity.propertiesByName[key] != nil else { return nil }
        return object.value(forKey: key) as? NSManagedObject
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

enum NativeMentionTarget {
    static func resolve(_ requested: String, participants: [NoteParticipant], allIdentity: String?) throws -> String {
        let value = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw NotesError("invalid_mention", "A mention identity is required.") }
        if value.caseInsensitiveCompare("all") == .orderedSame || value.caseInsensitiveCompare("@all") == .orderedSame {
            guard let allIdentity, !allIdentity.isEmpty else {
                throw NotesError("mention_all_unavailable", "Notes did not expose the @All identity.")
            }
            return allIdentity
        }
        guard let participant = participants.first(where: {
            $0.userID?.caseInsensitiveCompare(value) == .orderedSame ||
            $0.participantID?.caseInsensitiveCompare(value) == .orderedSame
        }) else {
            throw NotesError("mention_participant_not_found", "The mention identity is not a participant in this note.")
        }
        return participant.userID ?? participant.participantID ?? value
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
