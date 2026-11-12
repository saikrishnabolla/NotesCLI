import Foundation
import CoreData
import XCTest
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesNativeObjC
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

    func testSnapshotVerificationMatchesStructureAcrossEquivalentRunSplits() throws {
        var expected = try InMemoryNotes.sample().note("welcome")
        var checklist = ParagraphStyle(kind: .checklist, checked: true, checklistID: "old-item")
        checklist.id = "old-paragraph"
        expected.document = NoteDocument(text: "task", runs: [
            AttributeRun(length: 4, paragraph: checklist, font: FontStyle(bold: true),
                         link: "https://example.com", highlight: .mint),
        ])

        var actual = expected
        actual.document = NoteDocument(text: "task", runs: [
            AttributeRun(length: 2, paragraph: ParagraphStyle(kind: .checklist, checked: true, checklistID: "new-item"),
                         font: FontStyle(bold: true), link: "https://example.com", highlight: .mint),
            AttributeRun(length: 2, paragraph: ParagraphStyle(kind: .checklist, checked: true, checklistID: "new-item"),
                         font: FontStyle(bold: true), link: "https://example.com", highlight: .mint),
        ])
        actual.document?.runs[0].paragraph?.id = "new-paragraph"
        actual.document?.runs[1].paragraph?.id = "new-paragraph"

        XCTAssertTrue(SnapshotRestoreVerification.matches(expected: expected, actual: actual))
        actual.document?.runs[1].highlight = .purple
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

    func testDoctorResolvesSupportedSurface() {
        let report = NativeNotesWriter().doctor()
        XCTAssertTrue(report.frameworkLoaded, report.error ?? "framework did not load")
        XCTAssertEqual(report.macOS, "27.2.1")
        XCTAssertTrue(report.missing.isEmpty, report.missing.joined(separator: ", "))
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
    }

    func testUTF16RangeCountsSurrogatePairs() {
        XCTAssertEqual(("a😀b" as NSString).length, 4)
        XCTAssertEqual(UTF16Range(location: 1, length: 2), UTF16Range(location: 1, length: 2))
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

        let markdown = "# \(title)-main\n## Heading\n**<mark data-apple-notes-highlight=\"mint\">native</mark> formatting**\n- [x] done\n- item\n[web](https://example.com)\n![table](notescli-attachment:\(tableID))\n| x | y |\n| --- | --- |\n| 1 | 2 |\n"
        let backupRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NotesCLI/backups", isDirectory: true)
        let backupID = try SQLiteNotesStore(refresh: true).note(ref).summary.id.uuid
        let beforeBackups = Set((try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? [])
        let dry = verify(try native.writeMarkdown(ref, markdown: markdown, dryRun: true, backup: true, allowShared: false), "markdown dry run")
        createdBackups = ((try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? []).filter { !beforeBackups.contains($0) && $0.lastPathComponent.hasPrefix(backupID) }
        XCTAssertEqual(dry.verification.nativeReadback["dryRun"], "true")
        XCTAssertEqual(Set(createdBackups.map(\.pathExtension)), Set(["md", "json"]))
        let written = verify(try native.writeMarkdown(ref, markdown: markdown, dryRun: false, backup: false, allowShared: false), "markdown write")
        XCTAssertEqual(written.writeResult.outcome, .verified)
        let markdownReadback = try SQLiteNotesStore(refresh: true).note(ref)
        XCTAssertTrue(markdownReadback.summary.hasChecklist)
        XCTAssertTrue(markdownReadback.document?.runs.contains { $0.highlight == .mint && $0.font.bold } == true)
        XCTAssertTrue(NoteRenderer.markdown(try XCTUnwrap(markdownReadback.document)).contains("**<mark data-apple-notes-highlight=\"mint\">native</mark> formatting**"))
        XCTAssertEqual(markdownReadback.document?.tables?.count, 2)
        pass("write-markdown", "dry-run/checklist/headings/lists/links/tables backupFiles=2 sqlite=true")

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
