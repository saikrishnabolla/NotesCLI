import AppKit
import Foundation
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesSafety
import NotesStore
import PDFKit
import UniformTypeIdentifiers
import XCTest

final class AmbiguousFileRestoreTests: XCTestCase {
    func testLiveSnapshotRecreatesImageAndPDFThroughFileImport() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-file-import-restore-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return note.id(); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable file-import fixture creation failed: \(reply.stderr)")
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

        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-file-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let imageBytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        let imageURL = sourceRoot.appendingPathComponent("pixel.png")
        try imageBytes.write(to: imageURL, options: .atomic)
        let pdfURL = sourceRoot.appendingPathComponent("page.pdf")
        let pdf = PDFDocument()
        pdf.insert(try XCTUnwrap(PDFPage(image: try XCTUnwrap(NSImage(data: imageBytes)))), at: 0)
        XCTAssertTrue(pdf.write(to: pdfURL))

        let imageWrite = try native.insertFile(ref, file: imageURL, position: nil, imageView: "small", allowShared: false)
        let pdfWrite = try native.insertFile(ref, file: pdfURL, position: nil, imageView: nil, allowShared: false)
        XCTAssertEqual(imageWrite.write.writeResult.outcome, .verified)
        XCTAssertEqual(pdfWrite.write.writeResult.outcome, .verified)
        let captured = try SQLiteNotesStore(refresh: true).note(ref)
        let originalImage = try XCTUnwrap(captured.attachments.first(where: { $0.id == imageWrite.attachmentID }))
        let originalPDF = try XCTUnwrap(captured.attachments.first(where: { $0.id == pdfWrite.attachmentID }))

        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-file-import-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }
        let store = SnapshotStore(rootURL: snapshotRoot)
        let saved = try store.save(captured)
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)

        setenv("NOTESCLI_TEST_TREAT_ABSENT", [imageWrite.attachmentID, pdfWrite.attachmentID].joined(separator: ","), 1)
        defer { unsetenv("NOTESCLI_TEST_TREAT_ABSENT") }
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
        let restoredImage = try XCTUnwrap(try SQLiteNotesStore(refresh: true).note(ref).attachments.first(where: {
            $0.id == idMap[imageWrite.attachmentID]
        }))
        let restoredPDF = try XCTUnwrap(try SQLiteNotesStore(refresh: true).note(ref).attachments.first(where: {
            $0.id == idMap[pdfWrite.attachmentID]
        }))
        XCTAssertEqual(restoredImage.typeUTI, originalImage.typeUTI)
        XCTAssertEqual(restoredImage.filename, originalImage.filename)
        XCTAssertEqual(restoredPDF.typeUTI, originalPDF.typeUTI)
        XCTAssertEqual(restoredPDF.filename, originalPDF.filename)
        let restoredImageURL = URL(fileURLWithPath: try XCTUnwrap(restoredImage.filePath))
        let restoredPDFURL = URL(fileURLWithPath: try XCTUnwrap(restoredPDF.filePath))
        XCTAssertEqual(try Data(contentsOf: restoredImageURL), imageBytes)
        XCTAssertNotNil(NSImage(contentsOf: restoredImageURL))
        XCTAssertEqual(PDFDocument(url: restoredPDFURL)?.pageCount, 1)
    }

    func testLiveSnapshotRecreatesFileWhoseTypeHasNoCanonicalExtension() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-ambiguous-file-restore-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return note.id(); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable ambiguous-file fixture creation failed: \(reply.stderr)")
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

        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-ambiguous-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = sourceRoot.appendingPathComponent("opaque")
        let bytes = Data([0x00, 0xff, 0x13, 0x37, 0x00, 0x42, 0x99])
        try bytes.write(to: source, options: .atomic)

        let inserted = try native.insertFile(ref, file: source, position: nil, imageView: nil, allowShared: false)
        XCTAssertEqual(inserted.write.writeResult.outcome, .verified)
        let oldID = inserted.attachmentID
        let captured = try SQLiteNotesStore(refresh: true).note(ref)
        let original = try XCTUnwrap(captured.attachments.first(where: { $0.id == oldID }))
        XCTAssertNil(UTType(original.typeUTI)?.preferredFilenameExtension)

        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-ambiguous-file-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }
        let store = SnapshotStore(rootURL: snapshotRoot)
        let saved = try store.save(captured)
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)

        setenv("NOTESCLI_TEST_TREAT_ABSENT", oldID, 1)
        defer { unsetenv("NOTESCLI_TEST_TREAT_ABSENT") }
        setenv("NOTESCLI_TEST_CORRUPT_STAGED_RESTORE", oldID, 1)
        XCTAssertThrowsError(try native.restoreSnapshot(
            ref,
            snapshot: loaded.note,
            material: try store.restoreMaterial(for: loaded),
            expectedRevision: nil,
            expectedModified: nil,
            allowShared: false
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_attachment_hash_mismatch")
        }
        unsetenv("NOTESCLI_TEST_CORRUPT_STAGED_RESTORE")
        let afterRollback = try SQLiteNotesStore(refresh: true).note(ref)
        XCTAssertEqual(Set(afterRollback.attachments.map(\.id)), Set(captured.attachments.map(\.id)))
        XCTAssertEqual(afterRollback.document, captured.document)
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
        let recreated = try XCTUnwrap(readback.attachments.first(where: { $0.id == newID }))
        XCTAssertEqual(recreated.typeUTI, original.typeUTI)
        XCTAssertEqual(recreated.filename, original.filename)
        let recreatedPath = try XCTUnwrap(recreated.filePath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: recreatedPath)), bytes)
    }
}
