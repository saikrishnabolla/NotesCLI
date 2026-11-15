import Foundation
import CoreData
import NotesAutomation
import NotesCore
import NotesNativeObjC
import NotesSafety
import NotesStore
import XCTest
@testable import NotesNative

final class RecognitionTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-recognition-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testRecognitionResultEncodesOnlyTextAndTitle() throws {
        let result = OCRRecognitionResult(text: "Recognized words", title: "Receipt")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual(object as NSDictionary, ["text": "Recognized words", "title": "Receipt"] as NSDictionary)
    }

    func testRejectsNonFileURLBeforeCallingRuntime() throws {
        var called = false
        XCTAssertThrowsError(try OCRRecognition.recognize(
            fileURL: URL(string: "https://example.com/image.png")!,
            runtime: { _, _, _ in called = true; return ["text": "wrong"] }
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "ocr_input_not_file_url")
        }
        XCTAssertFalse(called)
    }

    func testRejectsMissingAndDirectoryInputsBeforeCallingRuntime() throws {
        let missing = temporaryDirectory.appendingPathComponent("missing.png")
        XCTAssertThrowsError(try OCRRecognition.recognize(fileURL: missing, runtime: { _, _, _ in [:] })) { error in
            XCTAssertEqual((error as? NotesError)?.code, "ocr_input_missing")
        }
        XCTAssertThrowsError(try OCRRecognition.recognize(fileURL: temporaryDirectory, runtime: { _, _, _ in [:] })) { error in
            XCTAssertEqual((error as? NotesError)?.code, "ocr_input_not_file")
        }
    }

    func testRejectsUnreadableInputBeforeCallingRuntime() throws {
        let file = temporaryDirectory.appendingPathComponent("unreadable.png")
        try Data("image".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        XCTAssertThrowsError(try OCRRecognition.recognize(fileURL: file, runtime: { _, _, _ in [:] })) { error in
            XCTAssertEqual((error as? NotesError)?.code, "ocr_input_unreadable")
        }
    }

    func testForwardsTitleAndLanguagesWithoutWriting() throws {
        let file = temporaryDirectory.appendingPathComponent("image.png")
        try Data("image".utf8).write(to: file)
        var received: (URL, [String]?, String?)?
        let result = try OCRRecognition.recognize(fileURL: file, languages: ["en-US", "es-ES"], title: "Invoice") {
            received = ($0, $1, $2)
            return ["text": "Total 42", "title": "Generated title"]
        }
        XCTAssertEqual(received?.0, file.standardizedFileURL)
        XCTAssertEqual(received?.1, ["en-US", "es-ES"])
        XCTAssertEqual(received?.2, "Invoice")
        XCTAssertEqual(result, OCRRecognitionResult(text: "Total 42", title: "Generated title"))
    }

    func testMissingRuntimeIsFeatureUnavailable() throws {
        let file = temporaryDirectory.appendingPathComponent("image.png")
        try Data("image".utf8).write(to: file)
        XCTAssertThrowsError(try OCRRecognition.recognize(fileURL: file) { _, _, _ in
            throw NSError(domain: "NotesCLI.NotesNative", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "ICOCRGenerator is unavailable"])
        }) { error in
            XCTAssertEqual((error as? NotesError)?.code, "feature_unavailable")
        }
    }

    func testAttachmentResolverRequiresOneImageWithLocalSource() throws {
        let image = Attachment(id: "image-1", typeUTI: "public.png", filePath: "/tmp/image.png", title: "Photo")
        let other = Attachment(id: "file-1", typeUTI: "public.plain-text", filePath: "/tmp/file.txt")
        XCTAssertEqual(try OCRAttachmentResolver.resolve([image, other], attachmentID: nil).id, "image-1")
        XCTAssertThrowsError(try OCRAttachmentResolver.resolve([other], attachmentID: "file-1")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "ocr_attachment_not_image")
        }
        XCTAssertThrowsError(try OCRAttachmentResolver.resolve([
            image, Attachment(id: "image-2", typeUTI: "public.jpeg", filePath: "/tmp/two.jpeg"),
        ], attachmentID: nil)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "ocr_attachment_ambiguous")
        }
        XCTAssertThrowsError(try OCRAttachmentResolver.resolve([
            Attachment(id: "remote", typeUTI: "public.heic"),
        ], attachmentID: "remote")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "attachment_unavailable")
        }
    }

    func testAttachmentResolverUsesUTTypeImageConformance() throws {
        let tiff = Attachment(id: "tiff-1", typeUTI: "public.tiff", filePath: "/tmp/image.tiff")
        XCTAssertEqual(try OCRAttachmentResolver.resolve([tiff], attachmentID: nil).id, "tiff-1")
    }

    func testAttachmentResolverFindsImageInsideScanGallery() throws {
        let page = Attachment(id: "page-1", typeUTI: "public.jpeg", filePath: "/tmp/page.jpeg")
        let scan = Attachment(id: "scan-1", typeUTI: "com.apple.notes.gallery", childAttachments: [page])
        XCTAssertEqual(try OCRAttachmentResolver.resolve([scan], attachmentID: "page-1").id, "page-1")
    }

    func testImageMetadataSettersUpdateNativeValuesAndVersions() throws {
        let modelURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/NotesShared.framework/Versions/A/Resources/NoteData.mom")
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try coordinator.addPersistentStore(type: .inMemory, at: URL(fileURLWithPath: "/dev/null"))
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let attachment = NSEntityDescription.insertNewObject(forEntityName: "ICAttachment", into: context)

        _ = try NCNotesRuntime.setOCRSummary("Exact OCR", version: 7, attachment: attachment)
        XCTAssertEqual(attachment.value(forKey: "ocrSummary") as? String, "Exact OCR")
        XCTAssertEqual((attachment.value(forKey: "ocrSummaryVersion") as? NSNumber)?.intValue, 7)
        _ = try NCNotesRuntime.setOCRSummary(nil, version: 0, attachment: attachment)
        XCTAssertNil(attachment.value(forKey: "ocrSummary"))
        XCTAssertEqual((attachment.value(forKey: "ocrSummaryVersion") as? NSNumber)?.intValue, 0)

        _ = try NCNotesRuntime.setImageClassificationSummary("receipt, document", version: 9, attachment: attachment)
        XCTAssertEqual(attachment.value(forKey: "imageClassificationSummary") as? String, "receipt, document")
        XCTAssertEqual((attachment.value(forKey: "imageClassificationSummaryVersion") as? NSNumber)?.intValue, 9)
        _ = try NCNotesRuntime.setImageClassificationSummary(nil, version: 0, attachment: attachment)
        XCTAssertNil(attachment.value(forKey: "imageClassificationSummary"))
        XCTAssertEqual((attachment.value(forKey: "imageClassificationSummaryVersion") as? NSNumber)?.intValue, 0)
    }

    func testImageMetadataRejectsNonImageAttachmentType() throws {
        XCTAssertNoThrow(try NativeImageMetadata.requireImage(typeUTI: "public.jpeg", attachmentID: "image"))
        XCTAssertThrowsError(try NativeImageMetadata.requireImage(typeUTI: "public.plain-text", attachmentID: "text")) {
            XCTAssertEqual(($0 as? NotesError)?.code, "image_metadata_attachment_not_image")
        }
    }

    func testImageMetadataRejectsDeletedAttachment() throws {
        XCTAssertNoThrow(try NativeImageMetadata.requireActive(markedForDeletion: false, attachmentID: "image"))
        XCTAssertThrowsError(try NativeImageMetadata.requireActive(markedForDeletion: true, attachmentID: "image")) {
            XCTAssertEqual(($0 as? NotesError)?.code, "attachment_not_found")
        }
    }

    func testLiveHandwritingSurvivesHardDeleteAndDrawingRecreation() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-handwriting-restore-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return String(note.id()); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable handwriting fixture creation failed: \(reply.stderr)")
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

        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/paper.svg")
        let drawing = try SVGDrawingConverter.drawing(from: Data(contentsOf: fixture))
        let inserted = try native.insertDrawing(ref, drawing: drawing, position: nil, allowShared: false)
        XCTAssertEqual(inserted.write.writeResult.outcome, .verified)
        let oldID = inserted.attachmentID
        let savedText = "Snapshot handwriting text"
        XCTAssertEqual(try native.setHandwritingSummary(
            ref, attachmentID: oldID, summary: savedText, allowShared: false
        ).writeResult.outcome, .verified)
        XCTAssertFalse(try native.recognizeHandwriting(ref, attachmentID: oldID).text.isEmpty)

        let captured = try SQLiteNotesStore(refresh: true).note(ref)
        XCTAssertEqual(captured.attachments.first(where: { $0.id == oldID })?.handwritingText, savedText)
        let payloads = try native.snapshotDrawingPayloads(ref)
        let paperBundles = try native.snapshotPaperBundlePayloads(ref)
        XCTAssertGreaterThan(try XCTUnwrap(paperBundles[oldID]).count, 0)
        let root = temporaryDirectory.appendingPathComponent("snapshot", isDirectory: true)
        let store = SnapshotStore(rootURL: root)
        let saved = try store.save(
            captured,
            drawingPayloads: payloads,
            paperBundlePayloads: paperBundles
        )
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)

        try native.hardDeleteAttachmentsForTesting(ref, attachmentIDs: [oldID])
        XCTAssertFalse(try SQLiteNotesStore(refresh: true).note(ref).attachments.contains { $0.id == oldID })
        let restored = try native.restoreSnapshot(
            ref,
            snapshot: loaded.note,
            material: try store.restoreMaterial(for: loaded),
            expectedRevision: nil,
            expectedModified: nil,
            allowShared: false
        )
        XCTAssertEqual(restored.writeResult.outcome, .verified, restored.writeResult.message ?? "no detail")
        let mapData = try XCTUnwrap(restored.verification.nativeReadback["attachmentIDMap"]?.data(using: .utf8))
        let idMap = try XCTUnwrap(JSONSerialization.jsonObject(with: mapData) as? [String: String])
        let newID = try XCTUnwrap(idMap[oldID])
        XCTAssertNotEqual(newID, oldID)
        let readback = try SQLiteNotesStore(refresh: true).note(ref)
        XCTAssertEqual(readback.attachments.first(where: { $0.id == newID })?.handwritingText, savedText)
        XCTAssertGreaterThan(try XCTUnwrap(native.snapshotPaperBundlePayloads(ref)[newID]).count, 0)
        XCTAssertFalse(try native.recognizeHandwriting(ref, attachmentID: newID).text.isEmpty)
    }
}
