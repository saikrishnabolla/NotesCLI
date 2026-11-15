import Foundation
import CoreData
import XCTest
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesNativeObjC
import NotesSafety
import NotesStore

private final class FakePrivateTable: NSObject {
    @objc dynamic func rowCount() -> Int { 2 }
}

private final class QueueTurnFlag: @unchecked Sendable {
    var observed = false
}

private final class FakeChangeTracked: NSObject {
    var reason: String?
    @objc(updateChangeCountWithReason:) dynamic func updateChangeCount(reason: String) { self.reason = reason }
}

final class NativeTests: XCTestCase {
    private static func varint(_ value: Int) -> Data {
        var value = value
        var data = Data()
        repeat {
            let byte = UInt8(value & 0x7f)
            value >>= 7
            data.append(value == 0 ? byte : byte | 0x80)
        } while value != 0
        return data
    }

    private static func field(_ number: Int, bytes: Data) -> Data {
        varint(number << 3 | 2) + varint(bytes.count) + bytes
    }

    private static func bodyData(text: String, runLength: Int) -> Data {
        let run = varint(1 << 3) + varint(runLength)
        let note = field(2, bytes: Data(text.utf8)) + field(5, bytes: run)
        return field(2, bytes: field(3, bytes: note))
    }

    func testLoadingNativeRuntimeDisablesCoreDataDebugStderr() {
        unsetenv("com.apple.CoreData.SQLDebug")
        unsetenv("com.apple.CoreData.Logging.stderr")
        _ = NativeNotesWriter().doctor()
        XCTAssertEqual(getenv("com.apple.CoreData.SQLDebug").map { String(cString: $0) }, "0")
        XCTAssertEqual(getenv("com.apple.CoreData.Logging.stderr").map { String(cString: $0) }, "0")
    }

    private func inMemoryContext() throws -> NSManagedObjectContext {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "Item"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        let value = NSAttributeDescription()
        value.name = "value"
        value.attributeType = .stringAttributeType
        entity.properties = [value]
        model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try coordinator.addPersistentStore(type: .inMemory, at: URL(fileURLWithPath: "/dev/null"))
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    func testCommittedFollowUpFailureReturnsUnknownWithOperationID() throws {
        let context = try inMemoryContext()
        var writer: NativeNotesWriter!
        writer = NativeNotesWriter(operationID: { "operation-123" }, contextProvider: { context })

        let result = try writer.performWrite { _ in
            writer.operation?.committed = true
            throw NotesError("synthetic_nudge_failure", "The Notes.app save nudge timed out.")
        }

        XCTAssertEqual(result.writeResult.outcome, .unknown)
        XCTAssertEqual(result.operationID, "operation-123")
        XCTAssertTrue(result.writeResult.message?.contains("Do not retry") == true)
        XCTAssertTrue(result.writeResult.message?.contains("operation_id=operation-123") == true)
    }

    func testRestoreMarksAnUnmarkSaveCommittedBeforeMoving() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NotesNative/NativeNotesWriter.swift"),
                                encoding: .utf8)
        let restoreStart = try XCTUnwrap(source.range(of: "public func restore("))
        let restoreEnd = try XCTUnwrap(source.range(of: "public func moveFolder(", range: restoreStart.upperBound..<source.endIndex))
        let restore = source[restoreStart.lowerBound..<restoreEnd.lowerBound]
        let save = try XCTUnwrap(restore.range(of: "try NCNotesRuntime.save(context)"))
        let committed = try XCTUnwrap(restore.range(of: "operation?.committed = true", range: save.upperBound..<restore.endIndex))
        let move = try XCTUnwrap(restore.range(of: "try appleMove(note, to: target)"))
        XCTAssertLessThan(committed.lowerBound, move.lowerBound)
    }

    func testNoteLinkVerificationDoesNotReenterWriterLockAcrossContextQueue() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NotesNative/NativeNotesWriter.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public func insertNoteLink("))
        let end = try XCTUnwrap(source.range(of: "fileprivate enum InlineObjectRequest", range: start.upperBound..<source.endIndex))
        let implementation = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(implementation.contains("let read = try linkRows(source)"))
        XCTAssertFalse(implementation.contains("try links(id(source))"))
    }

    func testSnapshotHashtagRevivalAlsoRevivesTheHashtagRecord() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/NotesNative/NativeNotesWriter.swift"),
                                encoding: .utf8)
        let restoreStart = try XCTUnwrap(source.range(of: "public func restoreSnapshot("))
        let restoreEnd = try XCTUnwrap(source.range(of: "private static func prepareSnapshotFiles", range: restoreStart.upperBound..<source.endIndex))
        let restore = source[restoreStart.lowerBound..<restoreEnd.lowerBound]
        let unmark = try XCTUnwrap(restore.range(of: "try NCNotesRuntime.unmarkForDeletion(attachment)"))
        let revive = try XCTUnwrap(restore.range(of: "try NCNotesRuntime.reviveTagAttachment(attachment)",
                                                 range: unmark.upperBound..<restore.endIndex))
        XCTAssertLessThan(unmark.lowerBound, revive.lowerBound)
    }

    func testNativeTransactionRunsManagedObjectWorkOnContextQueue() throws {
        let context = try inMemoryContext()
        var writer: NativeNotesWriter!
        writer = NativeNotesWriter(operationID: { "operation-queue" }, contextProvider: { context })

        _ = try writer.performWrite { context in
            let object = NSEntityDescription.insertNewObject(forEntityName: "Item", into: context)
            object.setValue("saved", forKey: "value")
            try context.save()
            writer.operation?.committed = true
            return NativeWriteResult(
                writeResult: WriteResult(outcome: .verified),
                verification: NativeVerification(nativeReadback: ["value": "saved"], sqliteReadback: nil)
            )
        }

        let count = try context.performAndWait {
            try context.count(for: NSFetchRequest(entityName: "Item"))
        }
        XCTAssertEqual(count, 1)
    }

    func testWriteResetsRegisteredObjectsBeforeTransaction() throws {
        let context = try inMemoryContext()
        try context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: "Item", into: context)
            object.setValue("cached", forKey: "value")
            try context.save()
            XCTAssertFalse(context.registeredObjects.isEmpty)
        }
        let writer = NativeNotesWriter(operationID: { "operation-reset" }, contextProvider: { context })

        _ = try writer.performWrite { context in
            XCTAssertTrue(context.registeredObjects.isEmpty)
            return NativeWriteResult(
                writeResult: WriteResult(outcome: .verified),
                verification: NativeVerification(nativeReadback: ["reset": "true"], sqliteReadback: nil)
            )
        }

        XCTAssertEqual(try context.performAndWait {
            try context.count(for: NSFetchRequest(entityName: "Item"))
        }, 1)
    }

    func testBodyIntegrityRejectsInvalidRunsAndStaleText() throws {
        let valid = Self.bodyData(text: "body", runLength: 4)
        XCTAssertNoThrow(try NativeBodyIntegrity.validate(serialized: valid, expectedText: "body"))
        XCTAssertThrowsError(try NativeBodyIntegrity.validate(
            serialized: Self.bodyData(text: "body", runLength: 5),
            expectedText: "body"
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "native_body_inconsistent")
        }
        XCTAssertThrowsError(try NativeBodyIntegrity.validate(serialized: valid, expectedText: "new body")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "native_body_inconsistent")
        }
    }

    func testCommittedChecklistReadbackRunsInFreshContextTurn() throws {
        let context = try inMemoryContext()
        var writer: NativeNotesWriter!
        let flag = QueueTurnFlag()
        writer = NativeNotesWriter(operationID: { "operation-readback" }, contextProvider: { context })

        let result = try writer.performWriteWithFreshReadback(transaction: { context in
            context.perform { flag.observed = true }
            writer.operation?.committed = true
            return "receipt"
        }, readback: { _, receipt in
            XCTAssertEqual(receipt, "receipt")
            XCTAssertTrue(flag.observed)
            return NativeWriteResult(
                writeResult: WriteResult(outcome: .verified),
                verification: NativeVerification(nativeReadback: ["done": "true"], sqliteReadback: nil)
            )
        })
        XCTAssertEqual(result.writeResult.outcome, .verified)
    }

    func testPrivatePropertyGetterRequiresItsExactSelector() throws {
        XCTAssertEqual(try NativePrivateMessageProbe.integer("rowCount", of: FakePrivateTable()), 2)
        XCTAssertThrowsError(try NativePrivateMessageProbe.integer("columnCount", of: FakePrivateTable())) {
            XCTAssertTrue($0.localizedDescription.contains("required selectors missing"))
            XCTAssertTrue($0.localizedDescription.contains("columnCount"))
        }
    }

    func testChangeCountUsesTheCheckedSelector() throws {
        let object = FakeChangeTracked()
        try NCNotesRuntime.updateChangeCount(of: object, reason: "Edited Smart Folder rules")
        XCTAssertEqual(object.reason, "Edited Smart Folder rules")
        XCTAssertThrowsError(try NCNotesRuntime.updateChangeCount(of: NSObject(), reason: "missing")) {
            XCTAssertTrue($0.localizedDescription.contains("updateChangeCountWithReason:"))
        }
    }

    func testExactVerificationRejectsNonSpecificEvidence() {
        XCTAssertTrue(NativeVerificationRules.exactText("a😀insertedz", text: "inserted", location: 3))
        XCTAssertFalse(NativeVerificationRules.exactText("inserted elsewhere", text: "inserted", location: 3))

        let link = NativeNoteLink(sourceID: "source", targetID: "target", text: "Target", attachmentID: "new-link", range: nil)
        XCTAssertTrue(NativeVerificationRules.exactLink([link], attachmentID: "new-link", targetID: "target"))
        XCTAssertFalse(NativeVerificationRules.exactLink([link], attachmentID: "other-link", targetID: "target"))
        let section = NativeNoteLink(sourceID: "source", targetID: "target",
                                     targetParagraphID: "11111111-2222-3333-4444-555555555555",
                                     text: "Target → Section", attachmentID: "new-section", range: nil)
        XCTAssertTrue(NativeVerificationRules.exactLink([section], attachmentID: "new-section", targetID: "target",
                                                        paragraphID: "11111111-2222-3333-4444-555555555555"))
        XCTAssertFalse(NativeVerificationRules.exactLink([section], attachmentID: "new-section", targetID: "target"))

        XCTAssertTrue(NativeVerificationRules.exactTable([["a", "b"]], expected: [["a", "b"]]))
        XCTAssertFalse(NativeVerificationRules.exactTable([["a", "wrong"]], expected: [["a", "b"]]))

        let marker = NSRange(location: 3, length: 1)
        XCTAssertTrue(NativeVerificationRules.exactReplacement(before: "pre\u{fffc}post", after: "prea,b\nc,dpost", range: marker, text: "a,b\nc,d"))
        XCTAssertFalse(NativeVerificationRules.exactReplacement(before: "pre\u{fffc}post a,b\nc,d", after: "prepost a,b\nc,d", range: marker, text: "a,b\nc,d"))
        XCTAssertFalse(NativeVerificationRules.exactReplacement(before: "pre\u{fffc}post", after: "prea,b\nc,dpost!", range: marker, text: "a,b\nc,d"))

        let item = ChecklistItem(index: 4, text: "task", done: true, range: UTF16Range(location: 0, length: 4))
        XCTAssertTrue(NativeVerificationRules.checklistItem([item], expected: item, done: true))
        XCTAssertFalse(NativeVerificationRules.checklistItem([item], expected: item, done: false))
        let moved = ChecklistItem(index: 4, text: "task", done: true, range: UTF16Range(location: 1, length: 4))
        XCTAssertFalse(NativeVerificationRules.checklistItem([item], expected: moved, done: true))

        XCTAssertTrue(NativeVerificationRules.attachment(["new-attachment"], id: "new-attachment"))
        XCTAssertFalse(NativeVerificationRules.attachment(["new-attachment", "new-attachment"], id: "new-attachment"))

        let persisted = NoteDocument(text: "notes", runs: [
            AttributeRun(length: 4, highlight: .purple),
            AttributeRun(length: 1),
        ])
        XCTAssertTrue(NativeVerificationRules.exactRuns(persisted, range: UTF16Range(location: 0, length: 4)) { $0.highlight == .purple })
        XCTAssertFalse(NativeVerificationRules.exactRuns(persisted, range: UTF16Range(location: 0, length: 5)) { $0.highlight == .purple })
        XCTAssertFalse(NativeVerificationRules.exactRuns(NoteDocument(text: "note", runs: []), range: UTF16Range(location: 0, length: 4)) { _ in true })
    }

    func testWholeBodyVerificationRequiresTheFullMarkerMultiset() {
        let before = [("mention", "mention"), ("tag", "hashtag"), ("tag", "hashtag")]
        XCTAssertTrue(NativeVerificationRules.sameMarkerMultiset(before, before))
        XCTAssertFalse(NativeVerificationRules.sameMarkerMultiset(before, [("mention", "mention"), ("tag", "hashtag")]))
        XCTAssertFalse(NativeVerificationRules.sameMarkerMultiset(before, [("mention", "mention"), ("tag", "other"), ("tag", "hashtag")]))
    }

    func testMentionTargetsRequireParticipantsAndResolveAll() throws {
        let participants = [
            NoteParticipant(participantID: "participant-1", userID: "user-1"),
            NoteParticipant(participantID: "participant-2", userID: nil),
        ]
        XCTAssertEqual(try NativeMentionTarget.resolve("user-1", participants: participants, allIdentity: nil), "user-1")
        XCTAssertEqual(try NativeMentionTarget.resolve("PARTICIPANT-1", participants: participants, allIdentity: nil), "user-1")
        XCTAssertEqual(try NativeMentionTarget.resolve("participant-2", participants: participants, allIdentity: nil), "participant-2")
        XCTAssertEqual(try NativeMentionTarget.resolve("@All", participants: participants, allIdentity: "all-users"), "all-users")
        XCTAssertThrowsError(try NativeMentionTarget.resolve("stranger", participants: participants, allIdentity: nil)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "mention_participant_not_found")
        }
        XCTAssertThrowsError(try NativeMentionTarget.resolve("all", participants: participants, allIdentity: nil)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "mention_all_unavailable")
        }
    }

    func testSnapshotVerificationMatchesStructureAcrossEquivalentRunSplits() throws {
        var expected = try InMemoryNotes.sample().note("welcome")
        let paragraphID = "11111111-2222-3333-4444-555555555555"
        let checklistID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        var checklist = ParagraphStyle(kind: .checklist, checked: true, checklistID: checklistID)
        checklist.id = paragraphID
        expected.document = NoteDocument(text: "task", runs: [
            AttributeRun(length: 4, paragraph: checklist, font: FontStyle(bold: true),
                         link: "https://example.com", highlight: .mint),
        ])

        var actual = expected
        actual.document = NoteDocument(text: "task", runs: [
            AttributeRun(length: 2, paragraph: ParagraphStyle(kind: .checklist, checked: true, checklistID: checklistID),
                         font: FontStyle(bold: true), link: "https://example.com", highlight: .mint),
            AttributeRun(length: 2, paragraph: ParagraphStyle(kind: .checklist, checked: true, checklistID: checklistID),
                         font: FontStyle(bold: true), link: "https://example.com", highlight: .mint),
        ])
        actual.document?.runs[0].paragraph?.id = paragraphID
        actual.document?.runs[1].paragraph?.id = paragraphID

        XCTAssertTrue(SnapshotRestoreVerification.matches(expected: expected, actual: actual))
        actual.document?.runs[1].paragraph?.checklistID = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: actual))
        actual.document?.runs[1].paragraph?.checklistID = checklistID
        actual.document?.runs[1].highlight = .purple
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: actual))
    }

    func testSnapshotVerificationIgnoresRegeneratedRecordingMarkerDisplayText() throws {
        var expected = try InMemoryNotes.sample().note("welcome")
        var expectedReference = InlineRef(id: "recording", typeUTI: "com.apple.m4a-audio")
        expectedReference.displayText = "New Recording"
        expected.document = NoteDocument(text: "\u{fffc}", runs: [
            AttributeRun(length: 1, attachment: expectedReference),
        ])
        expected.attachments = [Attachment(id: "recording", typeUTI: "com.apple.m4a-audio")]
        var actual = expected
        actual.document?.runs[0].attachment?.displayText = nil

        XCTAssertTrue(SnapshotRestoreVerification.matches(expected: expected, actual: actual))
        actual.document?.runs[0].attachment?.typeUTI = "public.mpeg-4-audio"
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: actual))
    }

    func testSnapshotVerificationRequiresNoteIdentityAndAttachmentTopology() throws {
        var expected = try InMemoryNotes.sample().note("welcome")
        expected.attachments = [
            Attachment(id: "scan", typeUTI: "com.apple.notes.gallery", childAttachmentIDs: ["page"]),
            Attachment(id: "page", typeUTI: "public.jpeg"),
            Attachment(id: "cell-image", typeUTI: "public.png"),
        ]

        var wrongNote = expected
        wrongNote.summary.id = NoteID(uuid: "other-note")
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: wrongNote))

        var wrongType = expected
        wrongType.attachments[1].typeUTI = "public.heic"
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: wrongType))

        var wrongParent = expected
        wrongParent.attachments[0].childAttachmentIDs = []
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: wrongParent))
    }

    func testSnapshotAttachmentScanIncludesTableCellMarkers() {
        var document = NoteDocument(text: "\u{fffc}", runs: [
            AttributeRun(length: 1, attachment: InlineRef(id: "table", typeUTI: "com.apple.notes.table")),
        ])
        document.tableCells = ["table": [[
            TableCellDocument(text: "\u{fffc}", runs: [
                AttributeRun(length: 1, attachment: InlineRef(id: "cell-image", typeUTI: "public.png")),
            ]),
        ]]]

        XCTAssertEqual(NativeNotesWriter.markerReferences(document).map(\.id), ["table", "cell-image"])
        XCTAssertEqual(NativeNotesWriter.markerReferences(document).map(\.typeUTI), ["com.apple.notes.table", "public.png"])
    }

    func testSharedWriteGuardRejectsUnknownAndReadOnlyRoles() {
        XCTAssertThrowsError(try NativeSharedWriteGuard.require(isShared: true, allowShared: true, isReadOnly: nil)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "shared_permission_unknown")
        }
        XCTAssertThrowsError(try NativeSharedWriteGuard.require(isShared: true, allowShared: true, isReadOnly: true)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "shared_read_only")
        }
        XCTAssertNoThrow(try NativeSharedWriteGuard.require(isShared: true, allowShared: true, isReadOnly: false))
    }

    func testNativeDeletionRequiresRecentlyDeletedState() {
        XCTAssertFalse(NativeDeleteVerification.isDeleted(markedForDeletion: true, folderType: 0))
        XCTAssertFalse(NativeDeleteVerification.isDeleted(markedForDeletion: true, folderType: 1))
        XCTAssertTrue(NativeDeleteVerification.isDeleted(markedForDeletion: false, folderType: 1))
        XCTAssertFalse(NativeDeleteVerification.isDeleted(markedForDeletion: false, folderType: 0))
        XCTAssertFalse(NativeDeleteVerification.isDeleted(markedForDeletion: false, folderType: nil))
    }

    func testDefaultNativeDestinationUsesStoreFolderID() throws {
        let location = DefaultNotesLocation(accountID: "account-a", accountName: "iCloud", folderID: "stable-folder-id",
                                            folderName: "Notes", folderPath: ["Notes"])
        XCTAssertEqual(try NativeDestinationResolver.folderID(location), "stable-folder-id")
        XCTAssertThrowsError(try NativeDestinationResolver.folderID(nil)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "folder_not_found")
        }
    }

    func testStaleGuardRejectsChangedTargetText() {
        let loaded = Date(timeIntervalSinceReferenceDate: 1)
        let snapshot = Date(timeIntervalSinceReferenceDate: 2)
        XCTAssertThrowsError(try NativeStaleGuard.validate(
            loadedDate: loaded,
            snapshotDate: snapshot,
            refreshedDate: snapshot,
            loadedTarget: NSAttributedString(string: "old target"),
            refreshedTarget: NSAttributedString(string: "new target")
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "stale_note")
        }
    }

    func testDoctorResolvesSupportedSurface() throws {
        let report = NativeNotesWriter().doctor()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(report.macOS, "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        XCTAssertTrue(report.frameworkLoaded, report.error ?? "framework did not load")
        XCTAssertEqual(report.classes["ICHashtagController"]?.selectors["+shouldAutoConvertToTag"], true)
        XCTAssertEqual(report.classes["ICHashtagController"]?.selectors["+setShouldAutoConvertToTag:"], true)
        XCTAssertEqual(report.classes["Calculate"]?.selectors["+evaluate:options:error:"], true)
        XCTAssertEqual(report.classes["CalculateResult"]?.selectors["-formattedResult"], true)
        XCTAssertEqual(report.classes["ICAttachmentAudioModel"]?.selectors["-deleteSummaryAndReturnError:"], true)
        XCTAssertTrue(report.missingCore.isEmpty, report.missingCore.joined(separator: ", "))
        XCTAssertTrue(report.usable)
        if version.majorVersion >= 27 {
            XCTAssertTrue(report.missing.isEmpty, report.missing.joined(separator: ", "))
        }
    }

    func testCalculateEvaluationMatchesNotesPlainTextRepresentation() throws {
        let value = try NativeNotesWriter().evaluateMath("2+2=")
        XCTAssertEqual(value, NativeCalculation(expression: "2+2", formattedExpression: "2+2",
                                                result: "4", renderedText: "2+2=4"))
        XCTAssertThrowsError(try NativeNotesWriter().evaluateMath("2+")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "math_evaluation_failed")
        }
    }

    func testMissingOptionalSelectorDisablesOnlyItsFeature() {
        let featureSelectors = [
            "+[ICInlineAttachment newDividerLineAttachmentWithIdentifier:note:parentAttachment:]",
            "-[ICDocCamScannedDocumentEditor setQuad:forAttachmentWithIdentifier:]",
            "-[ICDocCamScannedDocumentEditor deletePagesAtIndexes:]",
            "-[ICDocCamScannedDocumentEditor undeleteSubAttachment:]",
            "-[ICDocCamScannedDocumentEditor galleryModel]",
            "-[ICAttachmentGalleryModel indexOfSubAttachmentWithIdentifier:]",
            "-[ICAttachmentGalleryModel insertSubAttachment:atIndex:]",
            "-[ICAttachmentAudioModel deleteSummaryAndReturnError:]",
        ]
        let optional = NativeDoctorReport(frameworkLoaded: true, frameworkPath: "", macOS: "26.7.2", missing: featureSelectors, error: nil, classes: [:])
        XCTAssertTrue(optional.usable)
        XCTAssertEqual(optional.missingOptional, featureSelectors)
        XCTAssertEqual(optional.missingCore, [])
        let core = NativeDoctorReport(frameworkLoaded: true, frameworkPath: "", macOS: "26.7.2", missing: ["-[ICNote saveNoteData]"], error: nil, classes: [:])
        XCTAssertFalse(core.usable)
        XCTAssertEqual(core.missingCore, ["-[ICNote saveNoteData]"])
        let paragraphIdentity = "-[ICTTParagraphStyle setUuid:]"
        let identityCore = NativeDoctorReport(frameworkLoaded: true, frameworkPath: "", macOS: "26.7.2",
                                              missing: [paragraphIdentity], error: nil, classes: [:])
        XCTAssertFalse(identityCore.usable)
        XCTAssertEqual(identityCore.missingCore, [paragraphIdentity])
    }

    func testStyleNumbersMatchNotes() {
        XCTAssertEqual(NativeParagraphStyle.title.number, 0)
        XCTAssertEqual(NativeParagraphStyle.body.number, 3)
        XCTAssertEqual(NativeParagraphStyle.monospaced.number, 4)
        XCTAssertEqual(NativeParagraphStyle.bulleted.number, 100)
        XCTAssertEqual(NativeParagraphStyle.checklist.number, 103)
    }

    func testExtendedFormattingModelsUseNotesValues() {
        XCTAssertEqual(NativeParagraphAlignment.center.value, 2)
        XCTAssertEqual(NativeWritingDirection.leftToRight.value, 0)
        XCTAssertEqual(NativeWritingDirection.rightToLeft.value, 1)

        let format = InlineFormat(superscript: -1, fontName: "AvenirNext-Regular", fontSize: 17.5, highlight: .mint)
        XCTAssertEqual(format.superscript, -1)
        XCTAssertEqual(format.fontName, "AvenirNext-Regular")
        XCTAssertEqual(format.fontSize, 17.5)
        XCTAssertEqual(format.highlight, .mint)
        XCTAssertEqual(format.highlight?.notesValue, 4)
        XCTAssertEqual(NativeDefaultParagraphStyle.title.value, 0)
        XCTAssertEqual(NativeDefaultParagraphStyle.body.value, 3)
        XCTAssertNil(NativeDefaultParagraphStyle(value: 4))
        XCTAssertEqual(NativeDefaultParagraphStyle.allCases.map(\.rawValue), ["title", "heading", "subheading", "body"])
    }

    func testNotesPreferencesMapStoredValuesToSettingStates() throws {
        XCTAssertEqual(NativeNotesPreference.allCases.map(\.key),
                       ["kICQueryDateHeadersTypeKey", "ICShouldAutoFormatMarkdownDefaultsKey",
                        "alwaysShowLightContent", "showsNoteCount"])
        XCTAssertEqual(NativeNotesPreference.allCases.map(\.inApplicationDomain), [false, false, true, true])
        let stored: [(NativeNotesPreference, Bool, Int)] = [
            (.queryDateGrouping, true, 2), (.queryDateGrouping, false, 1),
            (.autoFormatMarkdown, true, 1), (.autoFormatMarkdown, false, 0),
            (.darkBackgrounds, true, 0), (.darkBackgrounds, false, 1),
            (.showNoteCount, true, 1), (.showNoteCount, false, 0),
        ]
        for (setting, enabled, value) in stored {
            XCTAssertEqual(setting.storedValue(enabled: enabled), value, setting.rawValue)
            XCTAssertEqual(try setting.state(stored: NSNumber(value: value)), enabled ? .on : .off, setting.rawValue)
            XCTAssertEqual(try setting.state(stored: nil), .default)
        }
        XCTAssertEqual(try NativeNotesPreference.queryDateGrouping.state(stored: NSNumber(value: 0)), .default)
        XCTAssertEqual(NativePreferenceValue(setting: .darkBackgrounds, state: .default).enabled, true)
        XCTAssertEqual(NativePreferenceValue(setting: .showNoteCount, state: .off).enabled, false)
        XCTAssertThrowsError(try NativeNotesPreference.queryDateGrouping.state(stored: NSNumber(value: 3))) {
            XCTAssertEqual(($0 as? NotesError)?.code, "unsupported_preference")
        }
        XCTAssertThrowsError(try NativeNotesPreference.showNoteCount.state(stored: "yes")) {
            XCTAssertEqual(($0 as? NotesError)?.code, "unsupported_preference")
        }
    }

    func testNoteContainerViewReadsTheSavedWindowState() throws {
        let saved: [String: Any] = ["windowStateArchive": [
            "currentNoteContainerViewMode": NSNumber(value: 1),
            "kICWindowStatePreferredNoteContainerViewMode": NSNumber(value: -1),
            "gridViewNoteItemSizeRatio": NSNumber(value: 1.5),
        ]]
        XCTAssertEqual(try NativeNotesWriter.noteContainerView(saved),
                       NativeNoteContainerViewState(mode: "gallery", preferredMode: nil, galleryItemSizeRatio: 1.5))
        XCTAssertNil(try NativeNotesWriter.noteContainerView([:]))
        let list: [String: Any] = ["windowStateArchive": ["currentNoteContainerViewMode": NSNumber(value: 0),
                                                          "kICWindowStatePreferredNoteContainerViewMode": NSNumber(value: 1)]]
        XCTAssertEqual(try NativeNotesWriter.noteContainerView(list),
                       NativeNoteContainerViewState(mode: "list", preferredMode: "gallery", galleryItemSizeRatio: nil))
        let unknown: [String: Any] = ["windowStateArchive": ["currentNoteContainerViewMode": NSNumber(value: 7)]]
        XCTAssertThrowsError(try NativeNotesWriter.noteContainerView(unknown)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "unsupported_view_mode")
        }
    }

    func testGlobalNoteSortParsesNamesAndNotesValues() throws {
        let cases: [(NativeGlobalNoteSort, Int, String)] = [
            (.modified, 0, "modified"),
            (.created, 1, "created"),
            (.title, 2, "title"),
        ]

        XCTAssertEqual(NativeGlobalNoteSort.allCases, cases.map(\.0))
        for (sort, value, name) in cases {
            XCTAssertEqual(sort.value, value)
            XCTAssertEqual(NativeGlobalNoteSort(value: value), sort)
            XCTAssertEqual(NativeGlobalNoteSort(rawValue: name), sort)
            XCTAssertEqual(String(decoding: try JSONEncoder().encode(sort), as: UTF8.self), "\"\(name)\"")
        }
        XCTAssertNil(NativeGlobalNoteSort(value: -1))
        XCTAssertNil(NativeGlobalNoteSort(value: 3))
        XCTAssertNil(NativeGlobalNoteSort(rawValue: "alphabetical"))
        XCTAssertNil(NativeGlobalNoteSort(rawValue: "Modified"))
    }

    func testNativeNotesSettingsRoundTripsItsPublicJSONShape() throws {
        let settings = NativeNotesSettings(sort: .title, groupsByDate: false,
                                           defaultTextSize: 24, resumesLastQuickNote: true,
                                           autoConvertsToTags: false)
        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["sort"] as? String, "title")
        XCTAssertEqual(object["groupsByDate"] as? Bool, false)
        XCTAssertEqual(object["defaultTextSize"] as? Int, 24)
        XCTAssertEqual(object["resumesLastQuickNote"] as? Bool, true)
        XCTAssertEqual(object["autoConvertsToTags"] as? Bool, false)
        XCTAssertEqual(try JSONDecoder().decode(NativeNotesSettings.self, from: data), settings)
    }

    func testMapURLRequiresAppleMapsHTTPS() throws {
        XCTAssertNoThrow(try NativeMapURL.validate(URL(string: "https://maps.apple.com/?q=Apple+Park")!))
        for value in ["http://maps.apple.com/?q=x", "https://example.com/map", "maps://maps.apple.com"] {
            XCTAssertThrowsError(try NativeMapURL.validate(URL(string: value)!)) { error in
                XCTAssertEqual((error as? NotesError)?.code, "invalid_map_url")
            }
        }
    }

    func testUTF16RangeCountsSurrogatePairs() {
        XCTAssertEqual(("a😀b" as NSString).length, 4)
        XCTAssertEqual(UTF16Range(location: 1, length: 2), UTF16Range(location: 1, length: 2))
    }

    func testSavedParagraphLinkTargetRequiresOneLinkableHeading() throws {
        let bodyID = UUID().uuidString
        let headingID = UUID().uuidString
        let body = ParagraphStyle(kind: .body)
        var bodyWithID = body
        bodyWithID.id = bodyID
        var heading = ParagraphStyle(kind: .heading)
        heading.id = headingID
        let document = NoteDocument(
            text: "body\nheading\n",
            runs: [
                AttributeRun(length: 5, paragraph: bodyWithID),
                AttributeRun(length: 8, paragraph: heading),
            ]
        )
        let writer = NativeNotesWriter()
        XCTAssertThrowsError(try writer.paragraphLinkTarget(bodyID, in: document)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "paragraph_not_linkable")
        }
        let resolved = try writer.paragraphLinkTarget(headingID, in: document)
        XCTAssertEqual(resolved.id.uuidString.lowercased(), headingID.lowercased())
        XCTAssertEqual(resolved.name, "heading")

        var secondHeading = heading
        secondHeading.id = headingID
        let duplicate = NoteDocument(
            text: "one\ntwo\n",
            runs: [
                AttributeRun(length: 4, paragraph: heading),
                AttributeRun(length: 4, paragraph: secondHeading),
            ]
        )
        XCTAssertThrowsError(try writer.paragraphLinkTarget(headingID, in: duplicate)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "ambiguous_paragraph_id")
        }
    }

    func testLiveSnapshotRecreatesNativeObjectFamilies() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-table-restore-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); const target = app.make({new: 'note', at: account, withProperties: {name: argv[0] + '-target', body: '<h1>Target</h1>'}}); return JSON.stringify({note: note.id(), target: target.id()}); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable table-restore fixture creation failed: \(reply.stderr)")
        }
        let fixtureData = try XCTUnwrap(reply.stdout.data(using: .utf8))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData) as? [String: String])
        let scriptingID = try XCTUnwrap(fixture["note"])
        let targetScriptingID = try XCTUnwrap(fixture["target"])
        var ref: String?, targetRef: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            if let note = try? SQLiteNotesStore(refresh: true).note(scriptingID) {
                ref = note.summary.id.uuid
            }
            if let note = try? SQLiteNotesStore(refresh: true).note(targetScriptingID) { targetRef = note.summary.id.uuid }
            if ref != nil, targetRef != nil { break }
        }
        let noteID = try XCTUnwrap(ref)
        let targetID = try XCTUnwrap(targetRef)
        defer {
            _ = try? scripting.deleteNote(noteID)
            _ = try? scripting.deleteNote(targetID)
        }

        let beforeRefusedSave = try SQLiteNotesStore(refresh: true).note(noteID)
        let refusedTag = "refused\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            setenv("NOTESCLI_TEST_CORRUPT_PENDING_BODY", noteID, 1)
            defer { unsetenv("NOTESCLI_TEST_CORRUPT_PENDING_BODY") }
            XCTAssertThrowsError(try native.addTag(noteID, tag: refusedTag, position: nil, allowShared: false)) { error in
                XCTAssertEqual((error as? NotesError)?.code, "native_body_inconsistent")
            }
        }
        let afterRefusedSave = try SQLiteNotesStore(refresh: true).note(noteID)
        XCTAssertEqual(afterRefusedSave.document?.text, beforeRefusedSave.document?.text)
        XCTAssertFalse(afterRefusedSave.summary.tags.contains { $0.caseInsensitiveCompare(refusedTag) == .orderedSame })

        let created = try native.createTable(
            noteID,
            rows: [["alpha", "beta"], ["gamma", "delta"]],
            position: nil,
            allowShared: false
        )
        XCTAssertEqual(created.writeResult.outcome, .verified)
        let oldTableID = try XCTUnwrap(created.verification.nativeReadback["tableID"])
        let linkURL = URL(string: "https://example.com/notescli-restore")!
        let link = try native.insertSynapseLink(
            noteID,
            url: linkURL,
            title: "NotesCLI restore link",
            position: nil,
            allowShared: false
        )
        XCTAssertEqual(link.writeResult.outcome, .verified)
        let oldLinkID = try XCTUnwrap(link.verification.nativeReadback["attachmentID"])
        let drawing = try SVGDrawingConverter.drawing(from: Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <path d="M10 10 L50 70 L90 20" fill="none" stroke="#336699" stroke-width="4"/>
        </svg>
        """.utf8))
        let drawingWrite = try native.insertDrawing(noteID, drawing: drawing, position: nil, allowShared: false)
        XCTAssertEqual(drawingWrite.write.writeResult.outcome, .verified)
        let oldDrawingID = drawingWrite.attachmentID
        let tagName = "restore\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        XCTAssertEqual(try native.addTag(noteID, tag: tagName, position: nil, allowShared: false).writeResult.outcome, .verified)
        let tagged = try SQLiteNotesStore(refresh: true).note(noteID)
        let oldTagID = try XCTUnwrap(tagged.attachments.first(where: {
            $0.kind == "hashtag" && ($0.displayText?.localizedCaseInsensitiveContains(tagName) == true ||
                                      $0.title?.localizedCaseInsensitiveContains(tagName) == true)
        })?.id)
        let divider = try native.insertDivider(noteID, position: nil, allowShared: false)
        let oldDividerID = try XCTUnwrap(divider.verification.nativeReadback["attachmentID"])
        let math = try native.insertMathExpression(noteID, expression: "2+2", position: nil, allowShared: false)
        let oldMathID = try XCTUnwrap(math.verification.nativeReadback["attachmentID"])
        let noteLink = try native.insertNoteLink(noteID, target: targetID, text: "Restore target",
                                                position: nil, allowShared: false)
        let oldNoteLinkID = try XCTUnwrap(noteLink.verification.nativeReadback["attachmentID"])
        let snapshot = try SQLiteNotesStore(refresh: true).note(noteID)
        XCTAssertEqual(
            snapshot.attachments.first(where: { $0.id == oldNoteLinkID })?.targetNoteID?.lowercased(),
            targetID.lowercased()
        )
        let drawingPayloads = try native.snapshotDrawingPayloads(noteID)
        let drawingPayload = try XCTUnwrap(drawingPayloads[oldDrawingID])
        XCTAssertFalse(drawingPayload.isEmpty)
        XCTAssertFalse(try JSONDecoder().decode([PaperStrokeRecord].self, from: drawingPayload).isEmpty)
        let linkPayloads = try native.snapshotLinkPayloads(noteID)
        let originalLinkPayload = try XCTUnwrap(linkPayloads[oldLinkID])
        XCTAssertFalse(originalLinkPayload.synapseData?.isEmpty ?? true)
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-snapshot-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }
        let snapshotStore = SnapshotStore(rootURL: snapshotRoot)
        let saved = try snapshotStore.save(
            snapshot,
            drawingPayloads: drawingPayloads,
            linkPayloads: linkPayloads
        )
        let loaded = try snapshotStore.loadRestorable(noteID, snapshot: saved.id)

        XCTAssertEqual(try native.setPinned(noteID, pinned: true, allowShared: false).writeResult.outcome, .verified)
        let changed = try native.replaceText(
            noteID,
            find: title,
            replacement: "\(title)-changed",
            allowShared: false
        )
        XCTAssertEqual(changed.writeResult.outcome, .verified, changed.writeResult.message ?? "no detail")
        XCTAssertEqual(try SQLiteNotesStore(refresh: true).note(noteID).summary.title, "\(title)-changed")

        setenv("NOTESCLI_TEST_TREAT_ABSENT", [oldTableID, oldLinkID, oldDrawingID, oldTagID,
                                               oldDividerID, oldMathID, oldNoteLinkID].joined(separator: ","), 1)
        defer { unsetenv("NOTESCLI_TEST_TREAT_ABSENT") }
        let restored = try native.restoreSnapshot(
            noteID,
            snapshot: loaded.note,
            material: try snapshotStore.restoreMaterial(for: loaded),
            expectedRevision: nil,
            expectedModified: nil,
            allowShared: false
        )

        XCTAssertEqual(restored.writeResult.outcome, .verified, restored.writeResult.message ?? "no detail")
        let idMapData = try XCTUnwrap(restored.verification.nativeReadback["attachmentIDMap"]?.data(using: .utf8))
        let idMap = try XCTUnwrap(JSONSerialization.jsonObject(with: idMapData) as? [String: String])
        let newTableID = try XCTUnwrap(idMap[oldTableID])
        let newLinkID = try XCTUnwrap(idMap[oldLinkID])
        let newDrawingID = try XCTUnwrap(idMap[oldDrawingID])
        let newTagID = try XCTUnwrap(idMap[oldTagID])
        let newDividerID = try XCTUnwrap(idMap[oldDividerID])
        let newMathID = try XCTUnwrap(idMap[oldMathID])
        let newNoteLinkID = try XCTUnwrap(idMap[oldNoteLinkID])
        XCTAssertNotEqual(newTableID, oldTableID)
        XCTAssertNotEqual(newLinkID, oldLinkID)
        XCTAssertNotEqual(newDrawingID, oldDrawingID)
        let readback = try SQLiteNotesStore(refresh: true).note(noteID)
        XCTAssertEqual(readback.summary.title, title)
        XCTAssertFalse(readback.summary.isPinned)
        XCTAssertEqual(readback.document?.tables?[newTableID], [["alpha", "beta"], ["gamma", "delta"]])
        XCTAssertNil(readback.document?.tables?[oldTableID])
        XCTAssertEqual(readback.attachments.first(where: { $0.id == newLinkID })?.url, linkURL.absoluteString)
        let restoredLinkPayload = try XCTUnwrap(try native.snapshotLinkPayloads(noteID)[newLinkID])
        XCTAssertEqual(restoredLinkPayload.synapseData, originalLinkPayload.synapseData)
        XCTAssertEqual(restoredLinkPayload.linkPresentationMetadata, originalLinkPayload.linkPresentationMetadata)
        XCTAssertFalse(readback.attachments.contains(where: { $0.id == oldLinkID }))
        XCTAssertFalse(try native.paperDrawings(noteID, attachmentID: newDrawingID).first?.drawings.first?.strokes.isEmpty ?? true)
        XCTAssertTrue(readback.attachments.contains(where: { $0.id == newTagID && $0.kind == "hashtag" }))
        XCTAssertTrue(readback.attachments.contains(where: { $0.id == newDividerID && $0.isDivider == true }))
        XCTAssertTrue(readback.attachments.contains(where: {
            $0.id == newMathID && ($0.mathExpression == "2+2" || $0.graphExpression == "2+2")
        }))
        XCTAssertTrue(readback.attachments.contains(where: {
            $0.id == newNoteLinkID && $0.targetNoteID?.caseInsensitiveCompare(targetID) == .orderedSame
        }))

        let edited = try native.editTable(
            noteID,
            attachmentID: newTableID,
            row: 1,
            column: 1,
            text: "edited-after-restore",
            allowShared: false
        )
        XCTAssertEqual(edited.writeResult.outcome, .verified)
        XCTAssertEqual(
            try SQLiteNotesStore(refresh: true).note(noteID).document?.tables?[newTableID]?[1][1],
            "edited-after-restore"
        )
    }

    func testLiveNativeCapabilities() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_TESTS=1; this suite writes only notescli-test/native-harden.")
        }
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        }, folderResolver: { ref in
            try SQLiteNotesStore(refresh: true).folders(account: nil).first {
                $0.id.caseInsensitiveCompare(ref) == .orderedSame
            }?.coreDataID
        })
        let native = NativeNotesWriter(), runner = OSAScriptRunner(), token = UUID().uuidString.lowercased()
        let prefix = "notescli-test-", title = prefix + token
        var testFolders: [(uuid: String, scriptingID: String)] = [], createdNotes: [String] = [], createdBackups: [URL] = []
        var safeToClean = true

        let childName = "notescli-test-\(token)"
        let setupScript = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const all = app.folders(); function named(name) { return all.filter(function(folder) { try { return folder.name() === name; } catch (error) { return false; } }); } let native = named('native-harden').filter(function(folder) { try { return folder.container().name() === 'notescli-test'; } catch (error) { return false; } })[0]; let root = native ? native.container() : named('notescli-test')[0]; if (!root) root = app.make({new: 'folder', at: account, withProperties: {name: 'notescli-test'}}); if (!native) native = app.make({new: 'folder', at: root, withProperties: {name: 'native-harden'}}); function note(name) { return app.make({new: 'note', at: native, withProperties: {name: name, body: '<h1>' + name + '</h1><p>body</p>'}}); } const child = app.make({new: 'folder', at: native, withProperties: {name: argv[3]}}); return JSON.stringify({root: root.id(), native: native.id(), child: child.id(), main: note(argv[0]).id(), target: note(argv[1]).id(), restore: note(argv[2]).id()}); }"
        let setup = try runner.run(source: setupScript, language: .javaScript,
                                   arguments: [title + "-main", title + "-target", title + "-restore", childName], timeout: 20)
        guard !setup.timedOut, setup.status == 0,
              let data = setup.stdout.data(using: .utf8),
              let fixture = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            safeToClean = false
            throw NotesError("unknown_write", "Live fixture creation did not return a known outcome: \(setup.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let rootRef = try XCTUnwrap(fixture["root"]), nativeFolderRef = try XCTUnwrap(fixture["native"])
        let child = try XCTUnwrap(fixture["child"]), ref = try XCTUnwrap(fixture["main"])
        let target = try XCTUnwrap(fixture["target"]), restoreRef = try XCTUnwrap(fixture["restore"])
        createdNotes = [ref, target, restoreRef]
        var fixtureFolders: [Folder] = []
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            let folders = try SQLiteNotesStore(refresh: true).folders(account: nil)
            fixtureFolders = [rootRef, nativeFolderRef, child].compactMap { id in folders.first { $0.coreDataID == id } }
            if fixtureFolders.count == 3 { break }
        }
        guard fixtureFolders.count == 3 else { safeToClean = false; throw NotesError("unknown_write", "Live fixture folders were not readable.") }
        let root = fixtureFolders[0].id, nativeFolder = fixtureFolders[1].id, childUUID = fixtureFolders[2].id
        testFolders = [(root, rootRef), (nativeFolder, nativeFolderRef), (childUUID, child)]
        func pass(_ capability: String, _ evidence: String) { print("NATIVE LIVE \(capability): PASS \(evidence)") }
        @discardableResult func verify(_ result: NativeWriteResult, _ capability: String) -> NativeWriteResult {
            if result.writeResult.outcome == .unknown { safeToClean = false }
            XCTAssertEqual(result.writeResult.outcome, .verified, "\(capability): \(result.writeResult.message ?? "no detail")")
            return result
        }
        @discardableResult func verify(_ result: NativeAttachmentResult, _ capability: String) -> NativeAttachmentResult {
            _ = verify(result.write, capability)
            return result
        }

        defer {
            if !safeToClean { print("NATIVE LIVE cleanup: STOPPED after unknown outcome") }
            else { do {
                for ref in createdNotes.reversed() {
                    if let note = try? SQLiteNotesStore(refresh: true).note(ref), note.summary.title.hasPrefix(prefix), !note.summary.isDeleted {
                        _ = try scripting.deleteNote(ref)
                    }
                }
                let deleteFolderScript = "function run(argv) { const app = Application('Notes'); const matches = app.folders().filter(function(folder) { try { return folder.id() === argv[0]; } catch (error) { return false; } }); if (matches.length === 0) return 'absent'; app.delete(matches[0]); return 'deleted'; }"
                for folder in testFolders.reversed() {
                    let reply = try runner.run(source: deleteFolderScript, language: .javaScript, arguments: [folder.scriptingID], timeout: 20)
                    guard !reply.timedOut, reply.status == 0 else { throw NotesError("cleanup_failed", "Notes.app did not accept deletion of test folder \(folder.uuid).") }
                }
                for backup in createdBackups { try? FileManager.default.removeItem(at: backup) }
                print("NATIVE LIVE cleanup: PASS")
            } catch { XCTFail("cleanup failed: \(error)") } }
        }

        let inserted = verify(try native.insertChecklist(ref, text: "task-\(token)", position: nil, allowShared: false), "checklist insert")
        let explicitPosition = (try SQLiteNotesStore(refresh: true).note(ref).document?.text as NSString?)?.length ?? 0
        verify(try native.insertChecklist(ref, text: "task-position-\(token)", position: explicitPosition, allowShared: false), "checklist positioned insert")
        verify(try native.toggleChecklist(ref, selection: .text("task-\(token)"), done: true, allowShared: false), "checklist text toggle")
        XCTAssertEqual(try native.checklistItems(ref).first(where: { $0.text == "task-\(token)" })?.done, true)
        verify(try native.setAllChecklist(ref, done: true, allowShared: false), "checklist set all")
        XCTAssertTrue(try native.checklistItems(ref).allSatisfy(\.done))
        verify(try native.setAllChecklist(ref, done: false, allowShared: false), "checklist clear all")
        let indexed = try XCTUnwrap(native.checklistItems(ref).first)
        verify(try native.toggleChecklist(ref, selection: .index(indexed.index), done: true, allowShared: false), "checklist index toggle")
        verify(try native.deleteCompleted(ref, allowShared: false), "checklist delete completed")
        XCTAssertFalse(try native.checklistItems(ref).contains(where: { $0.text == indexed.text }))
        pass("checklists", "insert/append/text/index/all/delete sqlite=\(inserted.verification.sqliteReadback != nil)")

        let pinned = verify(try native.setPinned(ref, pinned: true, allowShared: false), "pin")
        XCTAssertEqual(pinned.verification.nativeReadback["pinned"], "true")
        let unpinned = verify(try native.setPinned(ref, pinned: false, allowShared: false), "unpin")
        XCTAssertEqual(unpinned.writeResult.outcome, .verified)
        pass("pin", "pin/unpin native=true sqlite=\(unpinned.verification.sqliteReadback != nil)")

        let tag = "notesclitest\(token.replacingOccurrences(of: "-", with: ""))"
        verify(try native.addTag(ref, tag: tag, position: nil, allowShared: false), "tag add")
        verify(try native.removeTag(ref, tag: tag, allowShared: false), "tag remove")
        verify(try native.addTag(ref, tag: tag, position: nil, allowShared: false), "tag re-add")
        let renamedTag = verify(try native.renameTag(tag, to: tag + "r", expectedCount: 1), "tag rename")
        let deletedTag = verify(try native.deleteTag(tag + "r", expectedCount: 1), "tag delete")
        XCTAssertEqual(renamedTag.writeResult.outcome, .verified)
        XCTAssertEqual(deletedTag.writeResult.outcome, .verified)
        pass("tags", "add/remove/rename/delete expectedCount=1 sqlite=true")

        verify(try native.insertNoteLink(ref, target: target, text: "target", position: nil, allowShared: false), "note link insert")
        XCTAssertEqual(try native.links(ref).count, 1)
        XCTAssertEqual(try native.backlinks(target).count, 1)
        pass("note-links", "links=1 backlinks=1")

        let textPosition = (try SQLiteNotesStore(refresh: true).note(ref).document?.text as NSString?)?.length ?? 0
        verify(try native.insertText(ref, text: " replace-me format-me", position: textPosition, allowShared: false), "text insert")
        let replaceRange = try XCTUnwrap(native.searchOffsets(ref, text: "replace-me", caseInsensitive: false).first)
        verify(try native.replaceRange(ref, range: replaceRange, text: "replaced", allowShared: false), "range replace")
        let deleteRange = try XCTUnwrap(native.searchOffsets(ref, text: "replaced", caseInsensitive: false).first)
        verify(try native.deleteRange(ref, range: UTF16Range(location: deleteRange.location, length: 3), allowShared: false), "range delete")
        let offsets = try native.searchOffsets(ref, text: "format-me", caseInsensitive: false)
        let range = try XCTUnwrap(offsets.first)
        let formatted = verify(try native.setInlineFormat(ref, range: range, format: InlineFormat(bold: true, italic: true, underline: true, strike: true, link: "https://example.com", color: "#336699"), allowShared: false), "inline format")
        for style in NativeParagraphStyle.allCases {
            XCTAssertEqual(try native.setParagraphStyle(ref, range: range, style: style, indent: 1, allowShared: false).writeResult.outcome, .verified)
        }
        XCTAssertEqual(formatted.writeResult.outcome, .verified)
        pass("range-format", "insert/replace/delete allStyles offset=\(range.location) length=\(range.length) sqlite=true")

        let image = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-test-\(token).png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!.write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        let attached = verify(try native.insertFile(ref, file: image, position: nil, imageView: "small", allowShared: false), "small image insert")
        XCTAssertEqual(attached.write.verification.nativeReadback["placements"], "1")
        verify(try native.deleteAttachment(ref, attachmentID: attached.attachmentID, allowShared: false), "small image delete")
        let large = verify(try native.insertFile(ref, file: image, position: nil, imageView: "large", allowShared: false), "large image insert")
        verify(try native.deleteAttachment(ref, attachmentID: large.attachmentID, allowShared: false), "large image delete")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-test-\(token).txt")
        try Data("synthetic".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let fileAttachment = verify(try native.insertFile(ref, file: file, position: nil, imageView: nil, allowShared: false), "file insert")
        verify(try native.deleteAttachment(ref, attachmentID: fileAttachment.attachmentID, allowShared: false), "file delete")
        pass("attachments", "small/large/file placements=1 deleted=true")

        let table = verify(try native.createTable(ref, rows: [["a", "b"], ["c", "d"]], position: nil, allowShared: false), "table create")
        let tableID = try XCTUnwrap(table.verification.nativeReadback["tableID"])
        verify(try native.editTable(ref, attachmentID: tableID, row: 1, column: 1, text: "edited", allowShared: false), "table edit")
        verify(try native.resizeTable(ref, attachmentID: tableID, axis: "row", index: 2, add: true, allowShared: false), "table add row")
        verify(try native.resizeTable(ref, attachmentID: tableID, axis: "column", index: 2, add: true, allowShared: false), "table add column")
        verify(try native.resizeTable(ref, attachmentID: tableID, axis: "row", index: 2, add: false, allowShared: false), "table remove row")
        let resized = verify(try native.resizeTable(ref, attachmentID: tableID, axis: "column", index: 2, add: false, allowShared: false), "table remove column")
        XCTAssertEqual(resized.writeResult.outcome, .verified)
        pass("tables", "create/edit/add/remove rows=2 columns=2 sqlite=true")

        let preservedTable = verify(try native.createTable(target, rows: [["kept", "cell"], ["row", "two"]], position: nil, allowShared: false), "markdown preserved table create")
        let preservedTableID = try XCTUnwrap(preservedTable.verification.nativeReadback["tableID"])
        let markdown = "# \(title)-target\n## Heading\n**<mark data-apple-notes-highlight=\"mint\">native</mark> formatting**\n- [x] done\n- item\n[web](https://example.com)\n![table](notescli-attachment:\(preservedTableID))\n| x | y |\n| --- | --- |\n| 1 | 2 |\n"
        let backupRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NotesCLI/backups", isDirectory: true)
        let backupID = try SQLiteNotesStore(refresh: true).note(target).summary.id.uuid
        let beforeBackups = Set((try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? [])
        let dry = verify(try native.writeMarkdown(target, markdown: markdown, dryRun: true, backup: true, allowShared: false), "markdown dry run")
        createdBackups = ((try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? []).filter { !beforeBackups.contains($0) && $0.lastPathComponent.hasPrefix(backupID) }
        XCTAssertEqual(dry.verification.nativeReadback["dryRun"], "true")
        XCTAssertEqual(Set(createdBackups.map(\.pathExtension)), Set(["md", "json"]))
        let written = verify(try native.writeMarkdown(target, markdown: markdown, dryRun: false, backup: false, allowShared: false), "markdown write")
        XCTAssertEqual(written.writeResult.outcome, .verified)
        let markdownReadback = try SQLiteNotesStore(refresh: true).note(target)
        XCTAssertTrue(markdownReadback.summary.hasChecklist)
        XCTAssertTrue(markdownReadback.document?.runs.contains { $0.highlight == .mint && $0.font.bold } == true)
        XCTAssertTrue(NoteRenderer.markdown(try XCTUnwrap(markdownReadback.document)).contains("**<mark data-apple-notes-highlight=\"mint\">native</mark> formatting**"))
        XCTAssertEqual(markdownReadback.document?.tables?.count, 2)
        XCTAssertTrue(markdownReadback.document?.runs.contains { $0.attachment?.id == preservedTableID } == true)
        pass("write-markdown", "dry-run/checklist/headings/lists/links/tables/preserved-attachment backupFiles=2 sqlite=true")

        XCTAssertEqual(try native.moveFolder(child, parent: root, allowShared: false).writeResult.outcome, .verified)
        XCTAssertEqual(try native.moveFolder(child, parent: nativeFolder, allowShared: false).writeResult.outcome, .verified)
        pass("move-folder", "reparented twice native+sqlite")

        _ = try scripting.deleteNote(restoreRef)
        Thread.sleep(forTimeInterval: 1)
        verify(try native.restore(restoreRef, folder: nativeFolder, allowShared: false), "restore")
        XCTAssertFalse(try SQLiteNotesStore(refresh: true).note(restoreRef).summary.isDeleted)
        pass("restore", "sqlite isDeleted=false")

        let duplicate = verify(try native.duplicate(target, title: title + "-copy", allowShared: false), "duplicate")
        let duplicateID = try XCTUnwrap(duplicate.writeResult.noteID?.uuid)
        createdNotes.append(duplicateID)
        pass("duplicate", "sqlite title verified=\(duplicate.verification.sqliteReadback != nil)")
    }
}
