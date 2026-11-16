import AppKit
import NotesCore
import PDFKit
import XCTest
@testable import NotesNative
import NotesNativeObjC
import NotesAutomation
import NotesSafety
import NotesStore

final class ScanTests: XCTestCase {
    func testNotesOwnedScanPageCanBeFrozenOutsidePublicInputRoots() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notescli-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("scan-page.png")
        try Data("fixture".utf8).write(to: source)
        XCTAssertThrowsError(try FrozenAttachmentInput(file: source)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "input_path_refused")
        }
        let frozen = try FrozenAttachmentInput(notesFile: source)
        XCTAssertEqual(try Data(contentsOf: frozen.url), try Data(contentsOf: source))
    }

    func testBatchScanOrderRequiresExactPermutation() throws {
        XCTAssertNoThrow(try NativeNotesWriter.validateScanOrder(
            current: ["a", "b", "c"], requested: ["c", "a", "b"]
        ))
        for invalid in [["a", "b"], ["a", "a", "c"], ["a", "b", "d"], []] {
            XCTAssertThrowsError(try NativeNotesWriter.validateScanOrder(
                current: ["a", "b", "c"], requested: invalid
            )) {
                XCTAssertEqual(($0 as? NotesError)?.code, "invalid_scan_page_order")
            }
        }
    }

    private func png(width: Int = 8, height: Int = 4) throws -> FrozenAttachmentInput {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return try FrozenAttachmentInput(data: data, suggestedName: "page.png")
    }

    func testScanInputRequiresAtLeastOnePage() {
        XCTAssertThrowsError(try NativeNotesWriter.validateScanInputs([])) {
            XCTAssertEqual(($0 as? NotesError)?.code, "invalid_scan_page_count")
        }
    }

    func testScanInputRejectsMoreThanOneHundredPagesBeforeImageDecoding() throws {
        let page = try png()
        XCTAssertThrowsError(try NativeNotesWriter.validateScanInputs(Array(repeating: page, count: 101))) {
            XCTAssertEqual(($0 as? NotesError)?.code, "invalid_scan_page_count")
        }
    }

    func testScanInputRejectsNonImageBytes() throws {
        let page = try FrozenAttachmentInput(data: Data("not an image".utf8), suggestedName: "page.txt")
        XCTAssertThrowsError(try NativeNotesWriter.validateScanInputs([page])) {
            XCTAssertEqual(($0 as? NotesError)?.code, "invalid_scan_image")
        }
    }

    func testScanInputRejectsPDFBeforePrivateFrameworkDispatch() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let page = try FrozenAttachmentInput(data: try XCTUnwrap(document.dataRepresentation()), suggestedName: "page.pdf")
        XCTAssertThrowsError(try NativeNotesWriter.validateScanInputs([page])) {
            XCTAssertEqual(($0 as? NotesError)?.code, "invalid_scan_image")
        }
    }

    func testScanInputAcceptsOrderedImagePages() throws {
        XCTAssertNoThrow(try NativeNotesWriter.validateScanInputs([png(width: 8, height: 4), png(width: 4, height: 8)]))
    }

    func testScanFilterAndOrientationValuesMatchNotesStorage() {
        XCTAssertEqual(NativeScanFilter.allCases.map(\.value), [0, 1, 2, 3, 4])
        XCTAssertEqual(NativeScanFilter.allCases.map(\.rawValue), ["photo", "color", "grayscale", "black-and-white", "whiteboard"])
        XCTAssertEqual(NativeScanOrientation.allCases.map(\.value), [0, 1, 2, 3])
        XCTAssertEqual(NativeScanOrientation.allCases.map(\.rawValue), ["upright", "upside-down", "left", "right"])
        for value in NativeScanFilter.allCases { XCTAssertEqual(NativeScanFilter(value: value.value), value) }
        for value in NativeScanOrientation.allCases { XCTAssertEqual(NativeScanOrientation(value: value.value), value) }
    }

    func testZeroedStoredCropDecodesAsMissing() {
        let zero = ScanPoint(x: 0, y: 0)
        XCTAssertNil(NativeNotesWriter.decodedScanCrop(bottomLeft: zero, bottomRight: zero,
                                                       topLeft: zero, topRight: zero))
    }

    func testStoredCropDecodesWithoutChangingItsCoordinateSpace() throws {
        let crop = try XCTUnwrap(NativeNotesWriter.decodedScanCrop(
            bottomLeft: ScanPoint(x: 0, y: 765), bottomRight: ScanPoint(x: 1107, y: 765),
            topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1107, y: 0)))
        XCTAssertEqual(crop.bottomRight, ScanPoint(x: 1107, y: 765))
        XCTAssertEqual(crop.topLeft, ScanPoint(x: 0, y: 0))
    }

    func testPixelCropNormalizesToThePublicCoordinateSpace() throws {
        let stored = ScanCrop(
            bottomLeft: ScanPoint(x: 0, y: 765), bottomRight: ScanPoint(x: 1107, y: 765),
            topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1107, y: 0))
        let crop = try XCTUnwrap(NativeNotesWriter.normalizedScanCrop(stored, pixelWidth: 1107, pixelHeight: 765))
        XCTAssertEqual(crop.bottomLeft, ScanPoint(x: 0, y: 1))
        XCTAssertEqual(crop.bottomRight, ScanPoint(x: 1, y: 1))
        XCTAssertEqual(crop.topRight, ScanPoint(x: 1, y: 0))
    }

    func testPixelCropRefusesMismatchedImageDimensions() {
        let stored = ScanCrop(
            bottomLeft: ScanPoint(x: 0, y: 765), bottomRight: ScanPoint(x: 1107, y: 765),
            topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1107, y: 0))
        XCTAssertNil(NativeNotesWriter.normalizedScanCrop(stored, pixelWidth: 100, pixelHeight: 100))
    }

    func testScanCropVerificationToleratesStorageRounding() {
        let expected = ScanCrop(
            bottomLeft: ScanPoint(x: 0.1, y: 0.9), bottomRight: ScanPoint(x: 0.9, y: 0.9),
            topLeft: ScanPoint(x: 0.1, y: 0.1), topRight: ScanPoint(x: 0.9, y: 0.1)
        )
        var actual = expected
        actual.topLeft.y = 0.10000000000000002
        actual.topRight.y = 0.10000000000000002
        XCTAssertTrue(NativeVerificationRules.sameScanCrop(expected, actual))
    }

    func testLiveSnapshotRecreatesEditableScanGraph() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-scan-restore-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return JSON.stringify(String(note.id())); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable scan-restore fixture creation failed: \(reply.stderr)")
        }
        let scriptingID = try JSONDecoder().decode(String.self, from: XCTUnwrap(reply.stdout.data(using: .utf8)))
        var noteID: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            noteID = try? SQLiteNotesStore(refresh: true).note(scriptingID).summary.id.uuid
            if noteID != nil { break }
        }
        let ref = try XCTUnwrap(noteID)
        defer { _ = try? scripting.deleteNote(ref) }

        let inserted = try native.insertScan(
            ref,
            pages: [try png(width: 40, height: 24), try png(width: 24, height: 40)],
            position: nil,
            allowShared: false
        )
        XCTAssertNotEqual(inserted.write.writeResult.outcome, .unknown)
        let oldParentID = inserted.attachmentID
        let oldPageIDs = inserted.pageAttachmentIDs
        XCTAssertEqual(oldPageIDs.count, 2)
        let crop = ScanCrop(
            bottomLeft: ScanPoint(x: 0.1, y: 0.9), bottomRight: ScanPoint(x: 0.9, y: 0.9),
            topLeft: ScanPoint(x: 0.1, y: 0.1), topRight: ScanPoint(x: 0.9, y: 0.1)
        )
        XCTAssertNotEqual(try native.setScanCrop(
            ref, attachmentID: oldParentID, pageID: oldPageIDs[0], crop: crop,
            expectedCurrent: native.scanPageState(ref, attachmentID: oldParentID, pageID: oldPageIDs[0]).crop,
            allowShared: false
        ).writeResult.outcome, .unknown)
        XCTAssertTrue(NativeVerificationRules.sameScanCrop(try native.scanPageState(
            ref, attachmentID: oldParentID, pageID: oldPageIDs[0]
        ).crop, crop))
        XCTAssertEqual(try native.setScanFilter(
            ref, attachmentID: oldParentID, pageID: oldPageIDs[0], filter: .grayscale,
            expectedCurrent: .photo, allowShared: false
        ).writeResult.outcome, .verified)
        XCTAssertEqual(try native.setScanOrientation(
            ref, attachmentID: oldParentID, pageID: oldPageIDs[0], orientation: .right,
            expectedCurrent: .upright, allowShared: false
        ).writeResult.outcome, .verified)

        let markup = try NCNotesRuntime.scanRectangleMarkupData(
            x: 2, y: 2, width: 12, height: 8, strokeWidth: 2
        )
        XCTAssertEqual(try native.setScanMarkupData(
            ref, attachmentID: oldParentID, pageID: oldPageIDs[1], data: markup,
            embedded: true,
            allowShared: false
        ).writeResult.outcome, .verified)
        let markedState = try native.scanPageState(
            ref, attachmentID: oldParentID, pageID: oldPageIDs[1]
        )
        XCTAssertTrue(markedState.hasMarkup)
        XCTAssertTrue(markedState.hasEmbeddedMarkup)

        let snapshot = try SQLiteNotesStore(refresh: true).note(ref)
        let scanMarkupPayloads = try SQLiteNotesStore(refresh: true).scanMarkupPayloads(ref)
        XCTAssertEqual(scanMarkupPayloads[oldPageIDs[1]], markup)
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-scan-snapshot-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }
        let snapshotStore = SnapshotStore(rootURL: snapshotRoot)
        let saved = try snapshotStore.save(snapshot, scanMarkupPayloads: scanMarkupPayloads)
        let loaded = try snapshotStore.loadRestorable(ref, snapshot: saved.id)

        XCTAssertEqual(try native.deleteAttachment(
            ref, attachmentID: oldParentID, allowShared: false
        ).writeResult.outcome, .verified)
        XCTAssertFalse(try SQLiteNotesStore(refresh: true).note(ref).document?.runs.contains(where: {
            $0.attachment?.id == oldParentID
        }) ?? true)

        setenv("NOTESCLI_TEST_TREAT_ABSENT", ([oldParentID] + oldPageIDs).joined(separator: ","), 1)
        defer { unsetenv("NOTESCLI_TEST_TREAT_ABSENT") }
        let restored = try native.restoreSnapshot(
            ref,
            snapshot: loaded.note,
            material: try snapshotStore.restoreMaterial(for: loaded),
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
        let newParentID = try XCTUnwrap(idMap[oldParentID])
        let newPageIDs = try oldPageIDs.map { try XCTUnwrap(idMap[$0]) }
        XCTAssertNotEqual(newParentID, oldParentID)
        XCTAssertEqual(try native.scanPageState(
            ref, attachmentID: newParentID, pageID: newPageIDs[0]
        ).filter, .grayscale)
        XCTAssertEqual(try native.scanPageState(
            ref, attachmentID: newParentID, pageID: newPageIDs[0]
        ).orientation, .right)
        XCTAssertTrue(NativeVerificationRules.sameScanCrop(try native.scanPageState(
            ref, attachmentID: newParentID, pageID: newPageIDs[0]
        ).crop, crop))
        let restoredMarkedState = try native.scanPageState(
            ref, attachmentID: newParentID, pageID: newPageIDs[1]
        )
        XCTAssertTrue(restoredMarkedState.hasMarkup)
        XCTAssertTrue(restoredMarkedState.hasEmbeddedMarkup)
        XCTAssertEqual(try SQLiteNotesStore(refresh: true).scanMarkupPayloads(ref)[newPageIDs[1]], markup)
        XCTAssertEqual(try native.setScanFilter(
            ref, attachmentID: newParentID, pageID: newPageIDs[0], filter: .color,
            expectedCurrent: .grayscale, allowShared: false
        ).writeResult.outcome, .verified)
    }

    func testLiveExistingScanRestoreFailureIsUnknownAfterImmediateMutation() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-scan-restore-failure-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return JSON.stringify(String(note.id())); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable scan fixture creation failed: \(reply.stderr)")
        }
        let scriptingID = try JSONDecoder().decode(String.self, from: XCTUnwrap(reply.stdout.data(using: .utf8)))
        var noteID: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            noteID = try? SQLiteNotesStore(refresh: true).note(scriptingID).summary.id.uuid
            if noteID != nil { break }
        }
        let ref = try XCTUnwrap(noteID)
        defer { _ = try? scripting.deleteNote(ref) }

        let inserted = try native.insertScan(
            ref, pages: [try png(width: 32, height: 20)], position: nil, allowShared: false
        )
        XCTAssertEqual(inserted.write.writeResult.outcome, .verified)
        let parentID = inserted.attachmentID
        let pageID = try XCTUnwrap(inserted.pageAttachmentIDs.first)
        let captured = try SQLiteNotesStore(refresh: true).note(ref)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-scan-restore-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let saved = try store.save(captured)
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)

        XCTAssertEqual(try native.setScanFilter(
            ref, attachmentID: parentID, pageID: pageID, filter: .grayscale,
            expectedCurrent: .photo, allowShared: false
        ).writeResult.outcome, .verified)
        let expectedRevision = ConcurrencyGuard.revision(try SQLiteNotesStore(refresh: true).note(ref))
        let guarded = try native.restoreSnapshot(
            ref,
            snapshot: loaded.note,
            material: try store.restoreMaterial(for: loaded),
            expectedRevision: expectedRevision,
            expectedModified: nil,
            allowShared: false
        )
        XCTAssertEqual(guarded.writeResult.outcome, .verified, guarded.writeResult.message ?? "no detail")
        XCTAssertEqual(try native.scanPageState(
            ref, attachmentID: parentID, pageID: pageID
        ).filter, .photo)
        XCTAssertEqual(try native.setScanFilter(
            ref, attachmentID: parentID, pageID: pageID, filter: .grayscale,
            expectedCurrent: .photo, allowShared: false
        ).writeResult.outcome, .verified)
        defer { unsetenv("NOTESCLI_TEST_FAULT") }
        setenv("NOTESCLI_TEST_FAULT", "after_existing_scan_filter_mutation", 1)
        let result = try native.restoreSnapshot(
            ref,
            snapshot: loaded.note,
            material: try store.restoreMaterial(for: loaded),
            expectedRevision: nil,
            expectedModified: nil,
            allowShared: false
        )
        XCTAssertEqual(result.writeResult.outcome, .unknown)
        XCTAssertTrue(result.writeResult.message?.contains("Do not retry") == true)
        XCTAssertTrue(result.writeResult.message?.contains("after_existing_scan_filter_mutation") == true)
        unsetenv("NOTESCLI_TEST_FAULT")
        XCTAssertEqual(try native.scanPageState(
            ref, attachmentID: parentID, pageID: pageID
        ).filter, .photo)

        XCTAssertEqual(try native.setScanFilter(
            ref, attachmentID: parentID, pageID: pageID, filter: .grayscale,
            expectedCurrent: .photo, allowShared: false
        ).writeResult.outcome, .verified)
        setenv("NOTESCLI_TEST_FAULT", "before_restore_save", 1)
        XCTAssertThrowsError(try native.restoreSnapshot(
            ref,
            snapshot: loaded.note,
            material: try store.restoreMaterial(for: loaded),
            expectedRevision: nil,
            expectedModified: nil,
            allowShared: false
        ))
        unsetenv("NOTESCLI_TEST_FAULT")
        XCTAssertEqual(try native.scanPageState(
            ref, attachmentID: parentID, pageID: pageID
        ).filter, .grayscale)
    }

    func testLiveCorruptFileStopsRestoreBeforeScanCommit() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-scan-transaction-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return JSON.stringify(String(note.id())); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable scan-transaction fixture creation failed: \(reply.stderr)")
        }
        let scriptingID = try JSONDecoder().decode(String.self, from: XCTUnwrap(reply.stdout.data(using: .utf8)))
        var noteID: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            noteID = try? SQLiteNotesStore(refresh: true).note(scriptingID).summary.id.uuid
            if noteID != nil { break }
        }
        let ref = try XCTUnwrap(noteID)
        defer { _ = try? scripting.deleteNote(ref) }

        let scan = try native.insertScan(
            ref,
            pages: [try png(width: 32, height: 20)],
            position: nil,
            allowShared: false
        )
        XCTAssertNotEqual(scan.write.writeResult.outcome, .unknown)
        let fileSource = try png(width: 16, height: 16)
        let file = try native.insertFile(
            ref,
            file: fileSource.url,
            position: nil,
            imageView: nil,
            allowShared: false
        )
        XCTAssertEqual(file.write.writeResult.outcome, .verified)
        let captured = try SQLiteNotesStore(refresh: true).note(ref)
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-scan-transaction-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }
        let store = SnapshotStore(rootURL: snapshotRoot)
        let saved = try store.save(captured)
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)

        let forcedAbsent = [scan.attachmentID] + scan.pageAttachmentIDs + [file.attachmentID]
        setenv("NOTESCLI_TEST_TREAT_ABSENT", forcedAbsent.joined(separator: ","), 1)
        defer { unsetenv("NOTESCLI_TEST_TREAT_ABSENT") }
        setenv("NOTESCLI_TEST_CORRUPT_STAGED_RESTORE", file.attachmentID, 1)
        defer { unsetenv("NOTESCLI_TEST_CORRUPT_STAGED_RESTORE") }
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

        let after = try SQLiteNotesStore(refresh: true).note(ref)
        XCTAssertEqual(after.document, captured.document)
        XCTAssertEqual(Set(after.attachments.map(\.id)), Set(captured.attachments.map(\.id)))
        XCTAssertEqual(after.attachments.filter { $0.typeUTI == "com.apple.notes.gallery" }.map(\.id),
                       captured.attachments.filter { $0.typeUTI == "com.apple.notes.gallery" }.map(\.id))
    }

    func testLiveImageMarkupSurvivesHardDeletionAndRecreation() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-image-markup-restore-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return String(note.id()); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable markup fixture creation failed: \(reply.stderr)")
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

        let source = try png(width: 80, height: 48)
        let inserted = try native.insertFile(
            ref,
            file: source.url,
            position: nil,
            imageView: nil,
            allowShared: false
        )
        XCTAssertEqual(inserted.write.writeResult.outcome, .verified)
        let oldID = inserted.attachmentID
        let markup = try NCNotesRuntime.scanRectangleMarkupData(
            x: 4, y: 4, width: 24, height: 16, strokeWidth: 3
        )
        XCTAssertEqual(try native.setAttachmentMarkupData(
            ref,
            attachmentID: oldID,
            data: markup,
            embedded: false,
            allowShared: false
        ).writeResult.outcome, .verified)

        let snapshot = try SQLiteNotesStore(refresh: true).note(ref)
        let captured = try XCTUnwrap(snapshot.attachments.first(where: { $0.id == oldID }))
        XCTAssertEqual(captured.markupDataBytes, markup.count)
        XCTAssertEqual(captured.hasEmbeddedMarkup, false)
        let payloads = try SQLiteNotesStore(refresh: true).scanMarkupPayloads(ref)
        XCTAssertEqual(payloads[oldID], markup)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-image-markup-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let saved = try store.save(snapshot, scanMarkupPayloads: payloads)
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)

        try native.hardDeleteAttachmentsForTesting(ref, attachmentIDs: [oldID])
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
        let restoredAttachment = try XCTUnwrap(readback.attachments.first(where: { $0.id == newID }))
        XCTAssertEqual(restoredAttachment.markupDataBytes, markup.count)
        XCTAssertEqual(restoredAttachment.hasEmbeddedMarkup, false)
        XCTAssertEqual(try SQLiteNotesStore(refresh: true).scanMarkupPayloads(ref)[newID], markup)
    }
}
