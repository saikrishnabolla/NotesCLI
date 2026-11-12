import Foundation
import XCTest
import AVFoundation
import CoreGraphics
import NotesCore
@testable import NotesStore

final class ReadExtrasTests: XCTestCase {
    func testPersistentAnchorRelocatesAndPrunesSyntheticText() throws {
        let fake = InMemoryNotes.sample()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-anchor-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ParagraphAnchorStore(url: root.appendingPathComponent("anchors.sqlite"))
        let original = try fake.note("welcome").document!.text
        let anchor = try store.add(note: fake.note("welcome"), offset: 2)
        _ = try fake.replaceBody("welcome", markdown: "Inserted paragraph\n" + original)
        let resolved = try store.resolve(anchor.id, reader: fake)
        XCTAssertEqual(resolved.offset, "Inserted paragraph\n".utf16.count)
        XCTAssertTrue(resolved.relocated)
        XCTAssertEqual(try store.list(noteRef: "n1").count, 1)
        XCTAssertEqual(try store.list(noteRef: "1").count, 1)
        _ = try fake.replaceBody("welcome", markdown: "Completely unrelated")
        XCTAssertEqual(try store.prune(reader: fake), 1)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testReadOnlyAnchorResolutionDoesNotPersistRelocation() throws {
        let fake = InMemoryNotes.sample()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-anchor-readonly-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("anchors.sqlite"), store = ParagraphAnchorStore(url: url)
        let anchor = try store.add(note: fake.note("welcome"), offset: 0)
        _ = try fake.replaceBody("welcome", markdown: "Inserted\nWelcome to notescli. Browse your shopping notes. #demo")

        let resolved = try ParagraphAnchorStore(url: url, readOnly: true).resolve(anchor.id, reader: fake)
        XCTAssertEqual(resolved.offset, 9)
        XCTAssertEqual(try store.list().first?.currentOffset, 0)
    }

    func testSyncAcknowledgementUsesCloudVersionsAndDirtyFlags() {
        XCTAssertFalse(NotesSyncWaiter.isAcknowledged(nil))
        XCTAssertFalse(NotesSyncWaiter.isAcknowledged(NoteSyncState(needsSave: false)))
        XCTAssertTrue(NotesSyncWaiter.isAcknowledged(NoteSyncState(needsSave: false, hasChanges: false,
                                                                   currentLocalVersion: 3, latestVersionSyncedToCloud: 3, isInCloud: true)))
        XCTAssertFalse(NotesSyncWaiter.isAcknowledged(NoteSyncState(needsSave: true,
                                                                    currentLocalVersion: 3, latestVersionSyncedToCloud: 3, isInCloud: true)))
        XCTAssertFalse(NotesSyncWaiter.isAcknowledged(NoteSyncState(needsSave: false,
                                                                    currentLocalVersion: 4, latestVersionSyncedToCloud: 3, isInCloud: true)))
    }

    func testImagePreviewIsPNGAndBounded() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAD0lEQVR42mNk+M8ABBgAEQAB/7M2VQAAAABJRU5ErkJggg==")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-preview-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.png"); try png.write(to: source)
        let values = try AttachmentPreviewer.write([Attachment(id: "image", typeUTI: "public.png", filePath: source.path)],
                                                   to: root.appendingPathComponent("out"), maximumDimension: 1)
        XCTAssertEqual(values.count, 1)
        let data = try Data(contentsOf: URL(fileURLWithPath: values[0].path))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4e, 0x47])
    }

    func testPDFAndVideoPreviewsUseFirstPageAndFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-media-preview-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let pdf = root.appendingPathComponent("source.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 32, height: 24)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil); context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(mediaBox); context.endPDFPage(); context.closePDF()

        let video = root.appendingPathComponent("source.mov")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16
        ])
        XCTAssertTrue(writer.canAdd(input)); writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0x7f, CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: .zero))
        input.markAsFinished()
        let finished = expectation(description: "video written")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")

        let output = try AttachmentPreviewer.write([
            Attachment(id: "pdf", typeUTI: "com.adobe.pdf", filePath: pdf.path),
            Attachment(id: "video", typeUTI: "public.movie", filePath: video.path)
        ], to: root.appendingPathComponent("out"))
        XCTAssertEqual(Set(output.map(\.attachmentID)), Set(["pdf", "video"]))
        for preview in output {
            let data = try Data(contentsOf: URL(fileURLWithPath: preview.path))
            XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4e, 0x47])
        }
    }
}
