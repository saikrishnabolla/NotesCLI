import AppKit
import Foundation
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesSafety
import NotesStore
import PDFKit
import XCTest

final class PaperDocumentRestoreTests: XCTestCase {
    func testPaperBundleSignatureComparesNormalizedContents() throws {
        func envelope(_ value: String, rootName: String) throws -> Data {
            let file = FileWrapper(regularFileWithContents: Data(value.utf8))
            file.preferredFilename = "canvas.data"
            let assets = FileWrapper(directoryWithFileWrappers: ["canvas.data": file])
            assets.preferredFilename = "Assets.bundle"
            let root = FileWrapper(directoryWithFileWrappers: ["Assets.bundle": assets])
            root.preferredFilename = rootName
            let payload = try XCTUnwrap(root.serializedRepresentation)
            return try PropertyListSerialization.data(
                fromPropertyList: [
                    "version": 1,
                    "format": "file-wrapper-v1",
                    "name": rootName,
                    "payload": payload,
                ],
                format: .binary,
                options: 0
            )
        }

        let first = try envelope("first", rootName: "one.bundle")
        let same = try envelope("first", rootName: "two.bundle")
        let changed = try envelope("other", rootName: "one.bundle")

        XCTAssertEqual(NativeNotesWriter.paperBundleSignature(first),
                       NativeNotesWriter.paperBundleSignature(same))
        XCTAssertNotEqual(NativeNotesWriter.paperBundleSignature(first),
                          NativeNotesWriter.paperBundleSignature(changed))
    }

    private func pdf() throws -> FrozenAttachmentInput {
        let image = NSImage(size: NSSize(width: 160, height: 90))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 160, height: 90).fill()
        NSColor.systemBlue.setFill()
        NSRect(x: 20, y: 20, width: 120, height: 50).fill()
        image.unlockFocus()
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        return try FrozenAttachmentInput(
            data: try XCTUnwrap(document.dataRepresentation()),
            suggestedName: "paper.pdf"
        )
    }

    func testPlannerRecreatesPaperDocumentsFromVerifiedFallbackPDF() throws {
        for (type, subtype) in [("com.apple.paper.doc.pdf", "pdf"), ("com.apple.paper.doc.scan", "scan")] {
            let attachment = Attachment(id: subtype, typeUTI: type)
            var snapshot = try InMemoryNotes.sample().note("welcome")
            snapshot.document = NoteDocument(text: "\u{fffc}", runs: [
                AttributeRun(length: 1, attachment: InlineRef(id: subtype, typeUTI: type)),
            ])
            snapshot.attachments = [attachment]
            let material = SnapshotAttachmentMaterial(
                id: subtype,
                typeUTI: type,
                blobSHA256: String(repeating: "a", count: 64),
                byteCount: 12
            )
            let plan = SnapshotRestorePlanner.plan(
                snapshot: snapshot,
                verifiedArchive: SnapshotAttachmentArchive(formatVersion: 1, attachments: [material]),
                existing: []
            )
            XCTAssertEqual(
                try XCTUnwrap(plan.attachment(subtype)).action,
                SnapshotRestoreAction.recreatePaperDocument(material, subtype: subtype)
            )
            let bundleOnly = SnapshotAttachmentMaterial(
                id: subtype,
                typeUTI: type,
                paperBundleSHA256: String(repeating: "b", count: 64),
                paperBundleByteCount: 24,
                unavailableReason: "not_downloaded"
            )
            let bundlePlan = SnapshotRestorePlanner.plan(
                snapshot: snapshot,
                verifiedArchive: SnapshotAttachmentArchive(formatVersion: 1, attachments: [bundleOnly]),
                existing: []
            )
            XCTAssertEqual(
                try XCTUnwrap(bundlePlan.attachment(subtype)).action,
                SnapshotRestoreAction.recreatePaperDocument(bundleOnly, subtype: subtype)
            )
        }
    }

    func testLivePaperPDFAndScanSurviveHardDeletionAndRecreation() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes disposable notescli-test notes.")
        }
        for subtype in ["pdf", "scan"] {
            try liveRoundTrip(subtype: subtype)
        }
    }

    func testLiveFailedPaperRestorePurgesCreatedFiles() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes disposable notescli-test notes.")
        }
        for subtype in ["pdf", "scan"] {
            try liveFailedPaperDocumentRestore(subtype: subtype)
        }
        try liveFailedSystemPaperRestore()
    }

    private func disposableNote(_ label: String) throws -> (NativeNotesWriter, ScriptingNotesWriter, String) {
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-\(label)-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return String(note.id()); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable Paper fixture creation failed: \(reply.stderr)")
        }
        let scriptingID = reply.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            if let ref = try? SQLiteNotesStore(refresh: true).note(scriptingID).summary.id.uuid {
                return (native, scripting, ref)
            }
        }
        throw NotesError("note_not_found", "The disposable Paper note did not appear in the Notes store.")
    }

    private func cleanupIdentifier(_ result: NativeWriteResult) throws -> String {
        let message = try XCTUnwrap(result.writeResult.message)
        let marker = "Paper cleanup verified for "
        guard let range = message.range(of: marker) else {
            XCTFail(message)
            throw NotesError("paper_cleanup_not_verified", message)
        }
        let suffix = String(message[range.upperBound...])
        let identifier = suffix.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        _ = try XCTUnwrap(UUID(uuidString: identifier))
        return identifier
    }

    private func assertFailedRestoreCleaned(_ result: NativeWriteResult, native: NativeNotesWriter,
                                            noteID: String, bundleNamesBefore: Set<String>) throws {
        XCTAssertEqual(result.writeResult.outcome, .unknown)
        let identifier = try cleanupIdentifier(result)
        XCTAssertEqual(try native.paperBundleNamesForTesting(noteID), bundleNamesBefore)
        XCTAssertTrue(try native.paperFileURLsForTesting(noteID, identifier: identifier).allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        XCTAssertFalse(try SQLiteNotesStore(refresh: true).note(noteID).attachments.contains {
            $0.id.caseInsensitiveCompare(identifier) == .orderedSame
        })
    }

    private func liveFailedPaperDocumentRestore(subtype: String) throws {
        let (native, scripting, ref) = try disposableNote("paper-\(subtype)-cleanup")
        defer { _ = try? scripting.deleteNote(ref) }
        let inserted = try native.insertPaperDocument(
            ref,
            frozen: try pdf(),
            subtype: subtype,
            position: nil,
            allowShared: false
        )
        let oldID = inserted.attachmentID
        let captured = try SQLiteNotesStore(refresh: true).note(ref)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-paper-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let saved = try store.save(captured, paperBundlePayloads: native.snapshotPaperBundlePayloads(ref))
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)
        let material = try XCTUnwrap(try store.restoreMaterial(for: loaded))
        try native.hardDeleteAttachmentsForTesting(ref, attachmentIDs: [oldID])
        let before = try native.paperBundleNamesForTesting(ref)
        setenv("NOTESCLI_TEST_FAULT", "after_paper_helper", 1)
        defer { unsetenv("NOTESCLI_TEST_FAULT") }
        let result = try native.restoreSnapshot(
            ref,
            snapshot: loaded.note,
            material: material,
            expectedRevision: nil,
            expectedModified: nil,
            allowShared: false
        )
        try assertFailedRestoreCleaned(result, native: native, noteID: ref, bundleNamesBefore: before)
    }

    private func liveFailedSystemPaperRestore() throws {
        let (native, scripting, ref) = try disposableNote("system-paper-cleanup")
        defer { _ = try? scripting.deleteNote(ref) }
        let drawing = try SVGDrawingConverter.drawing(from: Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <path d="M10 10 L50 80 L90 20" fill="none" stroke="#336699" stroke-width="4"/>
        </svg>
        """.utf8))
        let inserted = try native.insertDrawing(ref, drawing: drawing, position: nil, allowShared: false)
        let oldID = inserted.attachmentID
        let captured = try SQLiteNotesStore(refresh: true).note(ref)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-system-paper-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let saved = try store.save(
            captured,
            drawingPayloads: native.snapshotDrawingPayloads(ref),
            paperBundlePayloads: native.snapshotPaperBundlePayloads(ref)
        )
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)
        let material = try XCTUnwrap(try store.restoreMaterial(for: loaded))
        try native.hardDeleteAttachmentsForTesting(ref, attachmentIDs: [oldID])
        let before = try native.paperBundleNamesForTesting(ref)
        setenv("NOTESCLI_TEST_FAULT", "after_paper_helper", 1)
        defer { unsetenv("NOTESCLI_TEST_FAULT") }
        let result = try native.restoreSnapshot(
            ref,
            snapshot: loaded.note,
            material: material,
            expectedRevision: nil,
            expectedModified: nil,
            allowShared: false
        )
        try assertFailedRestoreCleaned(result, native: native, noteID: ref, bundleNamesBefore: before)
    }

    private func liveRoundTrip(subtype: String) throws {
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-paper-\(subtype)-restore-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return String(note.id()); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable Paper fixture creation failed: \(reply.stderr)")
        }
        let scriptingID = reply.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var noteID: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            noteID = try? SQLiteNotesStore(refresh: true).note(scriptingID).summary.id.uuid
            if noteID != nil { break }
        }
        let ref = try XCTUnwrap(noteID)
        defer { _ = try? scripting.deleteNote(ref) }

        let inserted = try native.insertPaperDocument(
            ref,
            frozen: try pdf(),
            subtype: subtype,
            position: nil,
            allowShared: false
        )
        XCTAssertEqual(inserted.write.writeResult.outcome, .verified, inserted.write.writeResult.message ?? "no detail")
        let oldID = inserted.attachmentID
        let captured = try SQLiteNotesStore(refresh: true).note(ref)
        let oldAttachment = try XCTUnwrap(captured.attachments.first(where: { $0.id == oldID }))
        XCTAssertEqual(oldAttachment.typeUTI, "com.apple.paper.doc.\(subtype)")
        let sourcePath = try XCTUnwrap(oldAttachment.filePath ?? oldAttachment.fallbackRasterPath)
        XCTAssertEqual(PDFDocument(url: URL(fileURLWithPath: sourcePath))?.pageCount, 1)
        let paperBundles = try native.snapshotPaperBundlePayloads(ref)
        let paperBundle = try XCTUnwrap(paperBundles[oldID])
        XCTAssertGreaterThan(paperBundle.count, 0)
        let envelope = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: paperBundle, format: nil) as? [String: Any]
        )
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertTrue(["file-v1", "file-wrapper-v1"].contains(envelope["format"] as? String ?? ""))
        XCTAssertGreaterThan((envelope["payload"] as? Data)?.count ?? 0, 0)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-paper-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let saved = try store.save(captured, paperBundlePayloads: paperBundles)
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)
        let verifiedMaterial = try XCTUnwrap(try store.restoreMaterial(for: loaded))
        var bundleOnlyArchive = verifiedMaterial.archive
        let materialIndex = try XCTUnwrap(bundleOnlyArchive.attachments.firstIndex { $0.id == oldID })
        bundleOnlyArchive.attachments[materialIndex].blobSHA256 = nil
        bundleOnlyArchive.attachments[materialIndex].byteCount = nil
        bundleOnlyArchive.attachments[materialIndex].unavailableReason = "fallback_removed_for_test"
        let bundleOnlyMaterial = SnapshotRestoreMaterial(
            archive: bundleOnlyArchive,
            blobs: verifiedMaterial.blobs
        )

        try native.hardDeleteAttachmentsForTesting(ref, attachmentIDs: [oldID])
        XCTAssertFalse(try SQLiteNotesStore(refresh: true).note(ref).attachments.contains { $0.id == oldID })
        let restored = try native.restoreSnapshot(
            ref,
            snapshot: loaded.note,
            material: bundleOnlyMaterial,
            expectedRevision: nil,
            expectedModified: nil,
            allowShared: false
        )
        XCTAssertEqual(
            restored.writeResult.outcome,
            .verified,
            "\(restored.writeResult.message ?? "no detail") native=\(restored.verification.nativeReadback) sqlite=\(String(describing: restored.verification.sqliteReadback))"
        )
        let mapData = try XCTUnwrap(restored.verification.nativeReadback["attachmentIDMap"]?.data(using: .utf8))
        let idMap = try XCTUnwrap(JSONSerialization.jsonObject(with: mapData) as? [String: String])
        let newID = try XCTUnwrap(idMap[oldID])
        XCTAssertNotEqual(newID, oldID)
        let readback = try SQLiteNotesStore(refresh: true).note(ref)
        let newAttachment = try XCTUnwrap(readback.attachments.first(where: { $0.id == newID }))
        XCTAssertEqual(newAttachment.typeUTI, "com.apple.paper.doc.\(subtype)")
        let restoredPaperBundle = try XCTUnwrap(native.snapshotPaperBundlePayloads(ref)[newID])
        let restoredEnvelope = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: restoredPaperBundle, format: nil) as? [String: Any]
        )
        XCTAssertEqual(restoredEnvelope["version"] as? Int, 1)
        XCTAssertGreaterThan((restoredEnvelope["payload"] as? Data)?.count ?? 0, 0)
        let restoredPath = try XCTUnwrap(newAttachment.filePath ?? newAttachment.fallbackRasterPath)
        XCTAssertEqual(PDFDocument(url: URL(fileURLWithPath: restoredPath))?.pageCount, 1)
        XCTAssertEqual(try native.regenerateFallbackPDF(
            ref,
            attachmentID: newID,
            allowShared: false
        ).write.writeResult.outcome, .verified)
    }
}
