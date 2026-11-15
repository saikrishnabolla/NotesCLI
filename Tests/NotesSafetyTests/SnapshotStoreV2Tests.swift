import CryptoKit
import Foundation
import XCTest
import NotesCore
@testable import NotesSafety

final class SnapshotStoreV2Tests: XCTestCase {
    func testLineDiffShowsOnlyInsertedLineWithContext() {
        let result = SnapshotLineDiff.unified(
            snapshot: "alpha\nbeta\ngamma\n",
            current: "alpha\ninserted\nbeta\ngamma\n"
        )

        XCTAssertEqual(result, """
        --- snapshot
        +++ current
        @@ -1,3 +1,4 @@
         alpha
        +inserted
         beta
         gamma
        """)
    }

    func testLineDiffShowsOnlyDeletedLineWithContext() {
        let result = SnapshotLineDiff.unified(
            snapshot: "alpha\nremoved\nbeta\ngamma\n",
            current: "alpha\nbeta\ngamma\n"
        )

        XCTAssertEqual(result, """
        --- snapshot
        +++ current
        @@ -1,4 +1,3 @@
         alpha
        -removed
         beta
         gamma
        """)
    }

    func testLineDiffShowsMinimalChangeWithStableContext() {
        let result = SnapshotLineDiff.unified(
            snapshot: "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\n",
            current: "one\ntwo\nthree\nfour\nchanged\nsix\nseven\neight\nnine\n"
        )

        XCTAssertEqual(result, """
        --- snapshot
        +++ current
        @@ -2,7 +2,7 @@
         two
         three
         four
        -five
        +changed
         six
         seven
         eight
        """)
    }

    func testLineDiffReportsNoChanges() {
        XCTAssertEqual(SnapshotLineDiff.unified(snapshot: "same\n", current: "same\n"), "No changes")
    }

    func testLatestSnapshotNotAfterJournalStartSelectsTheMatchingPreimage() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let note = try InMemoryNotes.sample().note("welcome")
        let first = try store.save(note, now: Date(timeIntervalSince1970: 100))
        _ = try store.save(note, now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(try store.latestSnapshot(note.summary.id.uuid, notAfter: Date(timeIntervalSince1970: 150))?.id,
                       first.id)
        XCTAssertNil(try store.latestSnapshot(note.summary.id.uuid, notAfter: Date(timeIntervalSince1970: 50)))
    }

    func testCorruptedSnapshotIsRefused() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let note = try InMemoryNotes.sample().note("welcome")
        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        let markdownURL = saved.directory.appendingPathComponent("note.md")
        try Data("corrupted".utf8).write(to: markdownURL, options: .atomic)

        XCTAssertThrowsError(try store.loadRestorable(note.summary.id.uuid, snapshot: saved.id)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_integrity_failed")
        }
    }

    func testSnapshotPreservesMillisecondRecordingDatesAndReadsLegacyISO8601() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        var note = try InMemoryNotes.sample().note("welcome")
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        note.attachments = [Attachment(
            id: "recording", typeUTI: "com.apple.m4a-audio",
            recording: RecordingMetadata(startTime: date),
            recordingFragments: [RecordingFragmentMetadata(id: "fragment", createdDate: date, transcriptVersion: 1)],
            duration: 1,
            childAttachmentIDs: ["fragment"],
            childAttachments: [Attachment(id: "fragment", typeUTI: "public.mpeg-4-audio", duration: 1)]
        )]
        let saved = try store.save(note, now: date)
        let loaded = try store.loadRestorable(note.summary.id.uuid, snapshot: saved.id)
        XCTAssertEqual(try XCTUnwrap(loaded.note.attachments.first?.recording?.startTime?.timeIntervalSince1970),
                       date.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(loaded.note.attachments.first?.recordingFragments?.first?.createdDate?.timeIntervalSince1970),
                       date.timeIntervalSince1970, accuracy: 0.000_001)
    }

    func testIntegrityManifestRefusesStillDecodableJSONMutation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let note = try InMemoryNotes.sample().note("welcome")
        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        let noteURL = saved.directory.appendingPathComponent("note.json")
        var noteData = try Data(contentsOf: noteURL)
        noteData.append(contentsOf: Data(" \n".utf8))
        try noteData.write(to: noteURL, options: .atomic)

        XCTAssertThrowsError(try store.loadRestorable(note.summary.id.uuid, snapshot: saved.id)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_integrity_failed")
        }
    }

    func testRestoreRefusesSnapshotWithRequiredMaterialMissing() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let note = try InMemoryNotes.sample().note("welcome")
        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        try FileManager.default.removeItem(at: saved.directory.appendingPathComponent("note.md"))

        XCTAssertThrowsError(try store.loadRestorable(note.summary.id.uuid, snapshot: saved.id)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_material_missing")
        }
    }

    func testLegacySnapshotRemainsRestorableWhenCopiesAgree() throws {
        struct LegacySnapshot: Codable {
            var info: SnapshotInfo
            var note: Note
            var markdown: String
        }

        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try InMemoryNotes.sample().note("welcome")
        let id = "20231114T221320.000Z"
        let directory = root.appendingPathComponent(note.summary.id.uuid, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markdown = note.document?.markdown(attachments: note.attachments) ?? ""
        let info = SnapshotInfo(id: id, noteID: note.summary.id.uuid, created: Date(timeIntervalSince1970: 1_700_000_000),
                                title: note.summary.title, folderPath: note.summary.folderPath,
                                directory: directory, restorable: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(LegacySnapshot(info: info, note: note, markdown: markdown))
            .write(to: directory.appendingPathComponent("note.json"), options: .atomic)
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("note.md"), options: .atomic)

        let loaded = try SnapshotStore(rootURL: root).loadRestorable(note.summary.id.uuid, snapshot: id)
        XCTAssertEqual(loaded.note.summary.id, note.summary.id)
        XCTAssertEqual(loaded.markdown, markdown)

        try Data("conflicting legacy copy".utf8).write(to: directory.appendingPathComponent("note.md"), options: .atomic)
        XCTAssertThrowsError(try SnapshotStore(rootURL: root).loadRestorable(note.summary.id.uuid, snapshot: id)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_integrity_failed")
        }
    }

    func testLegacySnapshotMigratesRawZigZagRecordingIntegers() throws {
        struct LegacySnapshot: Codable {
            var info: SnapshotInfo
            var note: Note
            var markdown: String
        }
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(
            id: "recording", typeUTI: "com.apple.m4a-audio",
            recording: RecordingMetadata(summary: "Saved", summaryVersion: 2, callType: 2, isCallRecording: true),
            recordingFragments: [RecordingFragmentMetadata(id: "fragment", transcriptVersion: 2)],
            duration: 1,
            childAttachmentIDs: ["fragment"],
            childAttachments: [Attachment(id: "fragment", typeUTI: "public.mpeg-4-audio", duration: 1)]
        )]
        let id = "20231114T221321.000Z"
        let directory = root.appendingPathComponent(note.summary.id.uuid, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markdown = note.document?.markdown(attachments: note.attachments) ?? ""
        let info = SnapshotInfo(id: id, noteID: note.summary.id.uuid,
                                created: Date(timeIntervalSince1970: 1_700_000_001),
                                title: note.summary.title, folderPath: note.summary.folderPath,
                                directory: directory, restorable: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LegacySnapshot(info: info, note: note, markdown: markdown))
            .write(to: directory.appendingPathComponent("note.json"), options: .atomic)
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("note.md"), options: .atomic)

        let loaded = try SnapshotStore(rootURL: root).loadRestorable(note.summary.id.uuid, snapshot: id)
        XCTAssertEqual(loaded.note.attachments.first?.recording?.summaryVersion, 1)
        XCTAssertEqual(loaded.note.attachments.first?.recording?.callType, 1)
        XCTAssertEqual(loaded.note.attachments.first?.recordingFragments?.first?.transcriptVersion, 1)
    }

    func testV3ArchivesAttachmentBytesOnceAndLoadsVerifiedMaterial() throws {
        let root = temporaryDirectory()
        let sources = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let bytes = Data("archived attachment bytes".utf8)
        let first = sources.appendingPathComponent("first.pdf")
        let second = sources.appendingPathComponent("second.pdf")
        try bytes.write(to: first)
        try bytes.write(to: second)

        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [
            Attachment(id: "file-1", typeUTI: "com.adobe.pdf", filename: "first.pdf", filePath: first.path),
            Attachment(id: "file-2", typeUTI: "com.adobe.pdf", filename: "second.pdf", filePath: second.path),
        ]
        note.summary.attachmentCount = 2
        let store = SnapshotStore(rootURL: root, attachmentRoots: [sources])
        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        let loaded = try store.loadRestorable(note.summary.id.uuid, snapshot: saved.id)
        let archive = try XCTUnwrap(loaded.attachmentArchive)

        XCTAssertEqual(archive.formatVersion, 1)
        XCTAssertEqual(archive.attachments.count, 2)
        XCTAssertTrue(archive.attachments.allSatisfy(\.archived))
        XCTAssertEqual(Set(archive.attachments.compactMap(\.blobSHA256)).count, 1)
        let blob = saved.directory.appendingPathComponent("blobs")
            .appendingPathComponent(try XCTUnwrap(archive.attachments.first?.blobSHA256))
        XCTAssertEqual(try Data(contentsOf: blob), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blob.deletingLastPathComponent().path)
            .filter { !$0.hasPrefix(".") }.count, 1)
        XCTAssertEqual(permissions(saved.directory), 0o700)
        XCTAssertEqual(permissions(blob.deletingLastPathComponent()), 0o700)
        for name in ["note.json", "note.md", "attachments.json", "integrity.json"] {
            XCTAssertEqual(permissions(saved.directory.appendingPathComponent(name)), 0o600)
        }
        XCTAssertEqual(permissions(blob), 0o600)
    }

    func testV3ArchivesNestedAttachmentParentMetadata() throws {
        let root = temporaryDirectory()
        let sources = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let parentFile = sources.appendingPathComponent("scan.pdf")
        let childFile = sources.appendingPathComponent("page.jpg")
        try Data("scan".utf8).write(to: parentFile)
        try Data("page".utf8).write(to: childFile)
        var parent = Attachment(id: "scan-1", typeUTI: "com.apple.notes.gallery", filePath: parentFile.path)
        parent.childAttachments = [Attachment(id: "page-1", typeUTI: "public.jpeg", filePath: childFile.path)]
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [parent]
        note.summary.attachmentCount = 2

        let store = SnapshotStore(rootURL: root, attachmentRoots: [sources])
        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        let archive = try XCTUnwrap(store.loadRestorable(note.summary.id.uuid, snapshot: saved.id).attachmentArchive)

        XCTAssertNil(archive.attachments.first(where: { $0.id == "scan-1" })?.parentID)
        XCTAssertEqual(archive.attachments.first(where: { $0.id == "page-1" })?.parentID, "scan-1")
    }

    func testV3RejectsInvalidOrUnavailableArchivedMediaDurations() throws {
        let root = temporaryDirectory()
        let sources = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source = sources.appendingPathComponent("fragment.m4a")
        try Data("archived but intentionally undecodable audio".utf8).write(to: source)
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(
            id: "fragment", typeUTI: "public.mpeg-4-audio", filename: "fragment.m4a", filePath: source.path
        )]
        let store = SnapshotStore(rootURL: root, attachmentRoots: [sources])

        for (offset, duration) in [0.0, -1.0, TranscriptLimits.maxSeconds + 1].enumerated() {
            let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)))
            try rewriteArchive(in: saved.directory) { $0.attachments[0].mediaDuration = duration }
            XCTAssertThrowsError(try store.loadRestorable(saved.noteID, snapshot: saved.id)) { error in
                XCTAssertEqual((error as? NotesError)?.code, "snapshot_integrity_failed")
            }
        }

        note.attachments[0].filePath = nil
        let unavailable = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_010))
        try rewriteArchive(in: unavailable.directory) { $0.attachments[0].mediaDuration = 1 }
        XCTAssertThrowsError(try store.loadRestorable(unavailable.noteID, snapshot: unavailable.id)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_integrity_failed")
        }
    }

    func testV3ArchivesAndRevalidatesNativeDrawingPayload() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(id: "drawing-1", typeUTI: "com.apple.notes.paper")]
        note.summary.attachmentCount = 1
        let bytes = Data("synthetic-pencilkit-archive".utf8)
        let paperBundle = Data("synthetic-paper-bundle".utf8)
        let store = SnapshotStore(rootURL: root)

        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000),
                                   drawingPayloads: ["drawing-1": bytes],
                                   paperBundlePayloads: ["drawing-1": paperBundle])
        let loaded = try store.loadRestorable(saved.noteID, snapshot: saved.id)
        let archived = try XCTUnwrap(loaded.attachmentArchive?.attachments.first)
        let material = try XCTUnwrap(store.restoreMaterial(for: loaded))

        XCTAssertEqual(archived.payloadKind, "paper-strokes-v1")
        XCTAssertEqual(try material.blobs.verifiedData(
            sha256: try XCTUnwrap(archived.blobSHA256),
            byteCount: try XCTUnwrap(archived.byteCount)
        ), bytes)
        XCTAssertEqual(try material.blobs.verifiedData(
            sha256: try XCTUnwrap(archived.paperBundleSHA256),
            byteCount: try XCTUnwrap(archived.paperBundleByteCount)
        ), paperBundle)
    }

    func testV3ArchivesAndRevalidatesMultiCanvasPaperPayload() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(id: "drawing-1", typeUTI: "com.apple.notes.paper")]
        note.summary.attachmentCount = 1
        let canvases = Data("[[{\"canvas\":1}],[{\"canvas\":2}]]".utf8)
        let paperBundle = Data("synthetic-multi-canvas-paper-bundle".utf8)
        let store = SnapshotStore(rootURL: root)

        let saved = try store.save(
            note,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            drawingPayloads: ["drawing-1": canvases],
            paperBundlePayloads: ["drawing-1": paperBundle]
        )
        let loaded = try store.loadRestorable(saved.noteID, snapshot: saved.id)
        let archived = try XCTUnwrap(loaded.attachmentArchive?.attachments.first)
        let material = try XCTUnwrap(store.restoreMaterial(for: loaded))

        XCTAssertEqual(archived.payloadKind, "paper-canvases-v1")
        XCTAssertEqual(try material.blobs.verifiedData(
            sha256: try XCTUnwrap(archived.blobSHA256),
            byteCount: try XCTUnwrap(archived.byteCount)
        ), canvases)
        XCTAssertEqual(try material.blobs.verifiedData(
            sha256: try XCTUnwrap(archived.paperBundleSHA256),
            byteCount: try XCTUnwrap(archived.paperBundleByteCount)
        ), paperBundle)
    }

    func testV3ArchivesAndRevalidatesPrivateRichLinkPayloads() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try InMemoryNotes.sample().note("welcome")
        let synapse = Data("synapse-payload".utf8)
        let metadata = Data("link-presentation-payload".utf8)
        note.attachments = [Attachment(
            id: "link-1",
            typeUTI: "public.url",
            title: "Example",
            url: "https://example.com",
            synapseDataBytes: synapse.count,
            linkPreviewMetadataBytes: metadata.count
        )]
        note.summary.attachmentCount = 1
        let store = SnapshotStore(rootURL: root)

        let saved = try store.save(note, linkPayloads: [
            "link-1": SnapshotLinkPayload(
                synapseData: synapse,
                linkPresentationMetadata: metadata
            ),
        ])
        let loaded = try store.loadRestorable(saved.noteID, snapshot: saved.id)
        let archived = try XCTUnwrap(loaded.attachmentArchive?.attachments.first)
        let material = try XCTUnwrap(store.restoreMaterial(for: loaded))
        XCTAssertEqual(try material.blobs.verifiedData(
            sha256: try XCTUnwrap(archived.synapseSHA256),
            byteCount: try XCTUnwrap(archived.synapseByteCount)
        ), synapse)
        XCTAssertEqual(try material.blobs.verifiedData(
            sha256: try XCTUnwrap(archived.linkMetadataSHA256),
            byteCount: try XCTUnwrap(archived.linkMetadataByteCount)
        ), metadata)

        let blob = saved.directory.appendingPathComponent("blobs").appendingPathComponent(
            try XCTUnwrap(archived.linkMetadataSHA256)
        )
        try Data(repeating: 0x41, count: metadata.count).write(to: blob, options: .atomic)
        let tampered = try store.loadRestorable(saved.noteID, snapshot: saved.id)
        let tamperedMaterial = try XCTUnwrap(store.restoreMaterial(for: tampered))
        XCTAssertThrowsError(try tamperedMaterial.blobs.verifiedData(
            sha256: try XCTUnwrap(archived.linkMetadataSHA256),
            byteCount: metadata.count
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_integrity_failed")
        }
    }

    func testV3ArchivesScanMarkupAndRejectsTamperedMarkupBlob() throws {
        let root = temporaryDirectory()
        let sources = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let image = sources.appendingPathComponent("page.jpg")
        try Data("scan-page-image".utf8).write(to: image)
        let markup = Data("editable-scan-markup".utf8)
        let page = Attachment(
            id: "page-1",
            typeUTI: "public.jpeg",
            filename: "page.jpg",
            filePath: image.path,
            scanHasMarkup: true,
            scanHasEmbeddedMarkup: false
        )
        let gallery = Attachment(
            id: "scan-1",
            typeUTI: "com.apple.notes.gallery",
            childAttachmentIDs: [page.id],
            childAttachments: [page]
        )
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [gallery]
        let store = SnapshotStore(rootURL: root, attachmentRoots: [sources])

        let saved = try store.save(note, scanMarkupPayloads: [page.id: markup])
        let loaded = try store.loadRestorable(saved.noteID, snapshot: saved.id)
        let material = try XCTUnwrap(loaded.attachmentArchive?.attachments.first(where: { $0.id == page.id }))
        let hash = try XCTUnwrap(material.scanMarkupSHA256)
        XCTAssertEqual(material.scanMarkupByteCount, markup.count)
        XCTAssertEqual(
            try store.restoreMaterial(for: loaded)?.blobs.verifiedData(
                sha256: hash,
                byteCount: markup.count
            ),
            markup
        )

        let blob = saved.directory.appendingPathComponent("blobs").appendingPathComponent(hash)
        try Data(repeating: 0x41, count: markup.count).write(to: blob, options: .atomic)
        let tampered = try store.loadRestorable(saved.noteID, snapshot: saved.id)
        let tamperedMaterial = try XCTUnwrap(store.restoreMaterial(for: tampered))
        XCTAssertThrowsError(try tamperedMaterial.blobs.verifiedData(
            sha256: hash,
            byteCount: markup.count
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_integrity_failed")
        }
    }

    func testV3RejectsMarkupForWrongAttachmentShape() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let markup = Data("markup".utf8)
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(id: "text", typeUTI: "public.plain-text", scanHasMarkup: true)]
        XCTAssertThrowsError(try SnapshotStore(rootURL: root).save(
            note,
            scanMarkupPayloads: ["text": markup]
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "invalid_snapshot_attachment")
        }

        let page = Attachment(id: "page", typeUTI: "public.jpeg", scanHasMarkup: false)
        note.attachments = [Attachment(
            id: "scan",
            typeUTI: "com.apple.notes.gallery",
            childAttachmentIDs: [page.id],
            childAttachments: [page]
        )]
        XCTAssertThrowsError(try SnapshotStore(rootURL: root).save(
            note,
            scanMarkupPayloads: [page.id: markup]
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "invalid_snapshot_attachment")
        }
    }

    func testV3RefusesDuplicateAttachmentIdentifiersBeforePublishingSnapshot() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [
            Attachment(id: "duplicate", typeUTI: "public.png"),
            Attachment(id: "duplicate", typeUTI: "public.jpeg"),
        ]

        XCTAssertThrowsError(try SnapshotStore(rootURL: root).save(note)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "invalid_snapshot_attachment")
        }
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(note.summary.id.uuid),
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }.isEmpty) ?? true)
    }

    func testV3EmptyAttachmentArchiveLoads() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = []
        note.summary.attachmentCount = 0
        let store = SnapshotStore(rootURL: root)
        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        let loaded = try store.loadRestorable(note.summary.id.uuid, snapshot: saved.id)

        XCTAssertEqual(loaded.attachmentArchive?.attachments, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.directory.appendingPathComponent("blobs").path))
    }

    func testV3RefusesUnexpectedPackageEntriesAndBlobSymlinks() throws {
        let root = temporaryDirectory()
        let sources = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source = sources.appendingPathComponent("file.pdf")
        try Data("pdf".utf8).write(to: source)
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(id: "file-1", typeUTI: "com.adobe.pdf", filePath: source.path)]
        let store = SnapshotStore(rootURL: root, attachmentRoots: [sources])
        let first = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        try Data("extra".utf8).write(to: first.directory.appendingPathComponent("unexpected"))

        XCTAssertThrowsError(try store.load(first.noteID, snapshot: first.id)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_integrity_failed")
        }

        let second = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_001))
        let loaded = try store.load(second.noteID, snapshot: second.id)
        let hash = try XCTUnwrap(loaded.attachmentArchive?.attachments.first?.blobSHA256)
        let blob = second.directory.appendingPathComponent("blobs").appendingPathComponent(hash)
        let replacement = sources.appendingPathComponent("replacement")
        try Data("pdf".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: blob)
        try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: replacement)

        XCTAssertThrowsError(try store.load(second.noteID, snapshot: second.id)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_integrity_failed")
        }
    }

    func testV3RecordsSymlinkSourceAsUnavailable() throws {
        let root = temporaryDirectory()
        let sources = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let target = sources.appendingPathComponent("target.pdf")
        let link = sources.appendingPathComponent("link.pdf")
        try Data("pdf".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(id: "file-1", typeUTI: "com.adobe.pdf", filePath: link.path)]
        let store = SnapshotStore(rootURL: root, attachmentRoots: [sources])
        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        let material = try XCTUnwrap(store.load(saved.noteID, snapshot: saved.id).attachmentArchive?.attachments.first)

        XCTAssertFalse(material.archived)
        XCTAssertEqual(material.unavailableReason, "symbolic_link")
    }

    func testV3ArchivesAFileReachedThroughTheVarPrivateVarAlias() throws {
        let root = temporaryDirectory()
        let sources = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source = sources.appendingPathComponent("file.pdf")
        try Data("pdf".utf8).write(to: source)
        let aliasPath: String
        if source.path.hasPrefix("/private/var/") {
            aliasPath = String(source.path.dropFirst("/private".count))
        } else if source.path.hasPrefix("/var/") {
            aliasPath = "/private" + source.path
        } else {
            throw XCTSkip("This Mac's temporary directory has no /var and /private/var alias.")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: aliasPath))
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(id: "file-1", typeUTI: "com.adobe.pdf", filePath: aliasPath)]
        let store = SnapshotStore(rootURL: root, attachmentRoots: [sources])
        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        let material = try XCTUnwrap(store.load(saved.noteID, snapshot: saved.id).attachmentArchive?.attachments.first)

        XCTAssertTrue(material.archived)
        XCTAssertNil(material.unavailableReason)
    }

    func testRestoreMaterialRevalidatesBlobAfterLoadAndRefusesSymlinkSwap() throws {
        let root = temporaryDirectory()
        let sources = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let bytes = Data("original bytes".utf8)
        let source = sources.appendingPathComponent("file.pdf")
        try bytes.write(to: source)
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(id: "file-1", typeUTI: "com.adobe.pdf", filename: "file.pdf", filePath: source.path)]
        let store = SnapshotStore(rootURL: root, attachmentRoots: [sources])
        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        let loaded = try store.loadRestorable(saved.noteID, snapshot: saved.id)
        let material = try XCTUnwrap(try store.restoreMaterial(for: loaded))
        let archived = try XCTUnwrap(loaded.attachmentArchive?.attachments.first)
        let hash = try XCTUnwrap(archived.blobSHA256)
        let count = try XCTUnwrap(archived.byteCount)
        let blob = saved.directory.appendingPathComponent("blobs").appendingPathComponent(hash)

        XCTAssertEqual(try material.blobs.verifiedData(sha256: hash, byteCount: count), bytes)
        try Data("changed bytes!".utf8).write(to: blob)
        XCTAssertThrowsError(try material.blobs.verifiedData(sha256: hash, byteCount: count)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_integrity_failed")
        }

        try FileManager.default.removeItem(at: blob)
        let replacement = sources.appendingPathComponent("replacement.pdf")
        try bytes.write(to: replacement)
        try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: replacement)
        XCTAssertThrowsError(try material.blobs.verifiedData(sha256: hash, byteCount: count)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_material_missing")
        }
    }

    func testV3RefusesMissingOrChangedAttachmentBlob() throws {
        let root = temporaryDirectory()
        let sources = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source = sources.appendingPathComponent("image.png")
        try Data("image bytes".utf8).write(to: source)
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(id: "image-1", typeUTI: "public.png", filePath: source.path)]
        note.summary.attachmentCount = 1
        let store = SnapshotStore(rootURL: root, attachmentRoots: [sources])
        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        let loaded = try store.load(note.summary.id.uuid, snapshot: saved.id)
        let hash = try XCTUnwrap(loaded.attachmentArchive?.attachments.first?.blobSHA256)
        let blob = saved.directory.appendingPathComponent("blobs").appendingPathComponent(hash)
        try Data("changed".utf8).write(to: blob)

        let changed = try store.loadRestorable(note.summary.id.uuid, snapshot: saved.id)
        XCTAssertEqual(try store.history(note.summary.id.uuid).map(\.id), [saved.id])
        let changedMaterial = try XCTUnwrap(try store.restoreMaterial(for: changed))
        let archived = try XCTUnwrap(changed.attachmentArchive?.attachments.first)
        XCTAssertThrowsError(try changedMaterial.blobs.verifiedData(
            sha256: try XCTUnwrap(archived.blobSHA256),
            byteCount: try XCTUnwrap(archived.byteCount)
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_integrity_failed")
        }

        try FileManager.default.removeItem(at: blob)
        let missing = try store.loadRestorable(note.summary.id.uuid, snapshot: saved.id)
        let missingMaterial = try XCTUnwrap(try store.restoreMaterial(for: missing))
        XCTAssertThrowsError(try missingMaterial.blobs.verifiedData(
            sha256: try XCTUnwrap(archived.blobSHA256),
            byteCount: try XCTUnwrap(archived.byteCount)
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_material_missing")
        }
    }

    func testV3RecordsUnarchivedFilesWithoutLeakingTheirPaths() throws {
        let root = temporaryDirectory()
        let allowed = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: allowed)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = outside.appendingPathComponent("private.pdf")
        try Data("private".utf8).write(to: source)
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(id: "outside-1", typeUTI: "com.adobe.pdf", filePath: source.path)]
        note.summary.attachmentCount = 1
        let store = SnapshotStore(rootURL: root, attachmentRoots: [allowed])
        let saved = try store.save(note, now: Date(timeIntervalSince1970: 1_700_000_000))
        let loaded = try store.load(note.summary.id.uuid, snapshot: saved.id)
        let material = try XCTUnwrap(loaded.attachmentArchive?.attachments.first)

        XCTAssertFalse(material.archived)
        XCTAssertEqual(material.unavailableReason, "outside_notes_container")
        let archiveText = try String(contentsOf: saved.directory.appendingPathComponent("attachments.json"), encoding: .utf8)
        XCTAssertFalse(archiveText.contains(source.path))
        let noteText = try String(contentsOf: saved.directory.appendingPathComponent("note.json"), encoding: .utf8)
        XCTAssertFalse(noteText.contains(source.path))
        XCTAssertNil(loaded.note.attachments.first?.filePath)
    }

    func testConcurrentSavesWithTheSameTimestampReserveUniqueSnapshotIDs() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let note = try InMemoryNotes.sample().note("welcome")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask { try store.save(note, now: now).id }
            }
            var values: [String] = []
            for try await id in group { values.append(id) }
            return values
        }

        XCTAssertEqual(Set(ids).count, 12)
        XCTAssertEqual(try store.history(note.summary.id.uuid).count, 12)
    }

    func testFormatV2SnapshotStillLoads() throws {
        struct V2Snapshot: Codable {
            var formatVersion: Int
            var info: SnapshotInfo
            var note: Note
            var markdown: String
        }
        struct V2Manifest: Codable {
            struct Integrity: Codable { var byteCount: Int; var sha256: String }
            var formatVersion: Int
            var algorithm: String
            var snapshotID: String
            var noteID: String
            var files: [String: Integrity]
        }
        func integrity(_ data: Data) -> V2Manifest.Integrity {
            V2Manifest.Integrity(byteCount: data.count,
                                 sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }

        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try InMemoryNotes.sample().note("welcome")
        let id = "20231114T221320.000Z"
        let directory = root.appendingPathComponent(note.summary.id.uuid, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = SnapshotInfo(id: id, noteID: note.summary.id.uuid,
                                created: Date(timeIntervalSince1970: 1_700_000_000), title: note.summary.title,
                                folderPath: note.summary.folderPath, directory: directory, restorable: true)
        let markdown = note.document?.markdown(attachments: note.attachments) ?? ""
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let noteData = try encoder.encode(V2Snapshot(formatVersion: 2, info: info, note: note, markdown: markdown))
        let markdownData = Data(markdown.utf8)
        let manifest = V2Manifest(formatVersion: 2, algorithm: "SHA-256", snapshotID: id,
                                  noteID: note.summary.id.uuid,
                                  files: ["note.json": integrity(noteData), "note.md": integrity(markdownData)])
        try noteData.write(to: directory.appendingPathComponent("note.json"))
        try markdownData.write(to: directory.appendingPathComponent("note.md"))
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("integrity.json"))

        let loaded = try SnapshotStore(rootURL: root).loadRestorable(note.summary.id.uuid, snapshot: id)
        XCTAssertEqual(loaded.formatVersion, 2)
        XCTAssertNil(loaded.attachmentArchive)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func rewriteArchive(in directory: URL,
                                mutate: (inout SnapshotAttachmentArchive) -> Void) throws {
        let archiveURL = directory.appendingPathComponent("attachments.json")
        var archive = try JSONDecoder().decode(
            SnapshotAttachmentArchive.self,
            from: Data(contentsOf: archiveURL)
        )
        mutate(&archive)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        try data.write(to: archiveURL, options: .atomic)

        let manifestURL = directory.appendingPathComponent("integrity.json")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        var files = try XCTUnwrap(manifest["files"] as? [String: Any])
        files["attachments.json"] = [
            "byteCount": data.count,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        ]
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)
    }

    private func permissions(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
