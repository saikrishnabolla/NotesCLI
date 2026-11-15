import XCTest
import NotesCore
@testable import NotesNative

final class SnapshotRestoreVerificationEvidenceTests: XCTestCase {
    private func note(_ attachments: [Attachment]) throws -> Note {
        var note = try InMemoryNotes.sample().note("welcome")
        note.document = NoteDocument(
            text: String(repeating: "\u{fffc}", count: attachments.count),
            runs: attachments.map { AttributeRun(length: 1, attachment: InlineRef(id: $0.id, typeUTI: $0.typeUTI)) }
        )
        note.attachments = attachments
        return note
    }

    private func scan(_ order: [String]) -> Attachment {
        Attachment(id: "scan", typeUTI: "com.apple.notes.gallery", childAttachmentIDs: order,
                   childAttachments: order.map { Attachment(id: $0, typeUTI: "public.jpeg", scanFilter: 1, scanOrientation: 0) })
    }

    private func recording(_ order: [String], duration: Double = 10, words: [TranscriptWord] = []) -> Attachment {
        Attachment(id: "recording", typeUTI: "com.apple.m4a-audio", transcriptWords: words,
                   recordingFragments: order.map { RecordingFragmentMetadata(id: $0) }, duration: duration,
                   childAttachmentIDs: order,
                   childAttachments: order.map { Attachment(id: $0, typeUTI: "com.apple.m4a-audio") })
    }

    func testRejectsReversedScanPageAndRecordingFragmentOrder() throws {
        let expectedScan = try note([scan(["p1", "p2"])])
        XCTAssertTrue(SnapshotRestoreVerification.matches(expected: expectedScan, actual: expectedScan))
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expectedScan, actual: try note([scan(["p2", "p1"])])))

        let expectedRecording = try note([recording(["f1", "f2"])])
        XCTAssertTrue(SnapshotRestoreVerification.matches(expected: expectedRecording, actual: expectedRecording))
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expectedRecording,
                                                           actual: try note([recording(["f2", "f1"])])))
    }

    func testComparesRecordingDurationAndTranscriptWithTolerance() throws {
        let words = [TranscriptWord(text: "hello", start: 0, duration: 0.5)]
        let expected = try note([recording(["f1"], duration: 10, words: words)])
        XCTAssertTrue(SnapshotRestoreVerification.matches(expected: expected,
                                                          actual: try note([recording(["f1"], duration: 10.2, words: words)])))
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected,
                                                           actual: try note([recording(["f1"], duration: 12, words: words)])))
        let changed = [TranscriptWord(text: "goodbye", start: 0, duration: 0.5)]
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected,
                                                           actual: try note([recording(["f1"], duration: 10, words: changed)])))
    }

    func testRejectsChangedOCRAndImageClassificationMetadata() throws {
        let image = Attachment(id: "image", typeUTI: "public.jpeg",
                               ocrText: "Invoice total 42", imageClassification: "receipt, document")
        let expected = try note([image])
        XCTAssertTrue(SnapshotRestoreVerification.matches(expected: expected, actual: expected))

        var changedOCR = image
        changedOCR.ocrText = "Invoice total 41"
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: try note([changedOCR])))

        var changedLabels = image
        changedLabels.imageClassification = "photo"
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: try note([changedLabels])))
    }

    func testRejectsChangedScanStateURLMapAndMarkup() throws {
        var page = Attachment(id: "page", typeUTI: "public.jpeg", scanFilter: 2, scanOrientation: 1,
                              scanCrop: ScanCrop(bottomLeft: ScanPoint(x: 0, y: 0), bottomRight: ScanPoint(x: 1, y: 0),
                                                 topLeft: ScanPoint(x: 0, y: 1), topRight: ScanPoint(x: 1, y: 1)))
        let gallery = Attachment(id: "scan", typeUTI: "com.apple.notes.gallery", childAttachmentIDs: ["page"],
                                 childAttachments: [page])
        let link = Attachment(id: "link", typeUTI: "public.url", url: "https://example.com/a", synapseDataBytes: 5)
        let map = Attachment(id: "map", typeUTI: "public.url", url: "https://maps.apple.com/?ll=1,2",
                             hasMapLocation: true, mapLatitude: 1, mapLongitude: 2, mapAddress: "Somewhere")
        let image = Attachment(id: "image", typeUTI: "public.png", markupDataBytes: 12, hasEmbeddedMarkup: true)
        let expected = try note([gallery, link, map, image])
        XCTAssertTrue(SnapshotRestoreVerification.matches(expected: expected, actual: expected))

        func altered(_ change: (inout [Attachment]) -> Void) throws -> Note {
            var attachments = [gallery, link, map, image]
            change(&attachments)
            return try note(attachments)
        }
        page.scanFilter = 3
        let changedPage = page
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: try altered {
            $0[0].childAttachments = [changedPage]
        }))
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: try altered {
            $0[0].childAttachments?[0].scanCrop?.topRight = ScanPoint(x: 0.9, y: 1)
        }))
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: try altered {
            $0[1].url = "https://example.com/b"
        }))
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: try altered {
            $0[1].synapseDataBytes = nil
        }))
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: try altered {
            $0[2].mapLatitude = 1.5
        }))
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: try altered {
            $0[3].markupDataBytes = nil
        }))
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: try altered {
            $0[3].hasEmbeddedMarkup = false
        }))
    }

    func testRejectsKeptFileWithSameIDAndTypeButDifferentBytes() throws {
        let image = Attachment(id: "image", typeUTI: "public.jpeg", filePath: "/notes/image.jpg")
        let expected = try note([image])
        let archive = SnapshotAttachmentArchive(attachments: [
            SnapshotAttachmentMaterial(id: "image", typeUTI: "public.jpeg", blobSHA256: String(repeating: "a", count: 64),
                                       byteCount: 42),
        ])
        func verify(_ digest: SnapshotRestoreVerification.FileDigest?) -> Bool {
            SnapshotRestoreVerification.matches(expected: expected, actual: expected, archive: archive,
                                                attachmentIDMap: [:], fileDigest: { _ in digest })
        }
        XCTAssertTrue(verify(.init(sha256: String(repeating: "a", count: 64), byteCount: 42)))
        XCTAssertFalse(verify(.init(sha256: String(repeating: "b", count: 64), byteCount: 42)))
        XCTAssertFalse(verify(.init(sha256: String(repeating: "a", count: 64), byteCount: 41)))
        XCTAssertFalse(verify(nil))
        // The plain overload cannot see bytes, so it still matches.
        XCTAssertTrue(SnapshotRestoreVerification.matches(expected: expected, actual: expected))
    }

    func testHashesRealFilesAndSkipsRecreatedScanPages() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.bin")
        let bytes = Data("snapshot bytes".utf8)
        try bytes.write(to: file)
        let sha = FrozenAttachmentInput.hash(bytes)

        let recreatedFile = Attachment(id: "new-file", typeUTI: "public.data", filePath: file.path)
        let recreatedPage = Attachment(id: "new-page", typeUTI: "public.jpeg", filePath: directory.appendingPathComponent("missing.jpg").path)
        let gallery = Attachment(id: "new-scan", typeUTI: "com.apple.notes.gallery", childAttachmentIDs: ["new-page"],
                                 childAttachments: [recreatedPage])
        let expected = try note([recreatedFile, gallery])
        let archive = SnapshotAttachmentArchive(attachments: [
            SnapshotAttachmentMaterial(id: "old-file", typeUTI: "public.data", blobSHA256: sha, byteCount: bytes.count),
            SnapshotAttachmentMaterial(id: "old-scan", typeUTI: "com.apple.notes.gallery",
                                       blobSHA256: String(repeating: "d", count: 64), byteCount: 11),
            SnapshotAttachmentMaterial(id: "old-page", typeUTI: "public.jpeg", parentID: "old-scan",
                                       blobSHA256: String(repeating: "c", count: 64), byteCount: 9),
        ])
        let map = ["old-file": "new-file", "old-page": "new-page", "old-scan": "new-scan"]
        XCTAssertTrue(SnapshotRestoreVerification.matches(expected: expected, actual: expected, archive: archive,
                                                          attachmentIDMap: map))

        try Data("changed bytes!".utf8).write(to: file)
        XCTAssertFalse(SnapshotRestoreVerification.matches(expected: expected, actual: expected, archive: archive,
                                                           attachmentIDMap: map))
    }
}
