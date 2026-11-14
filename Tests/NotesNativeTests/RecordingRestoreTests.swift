import AVFoundation
import Foundation
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesSafety
import NotesStore
import XCTest

final class RecordingRestoreTests: XCTestCase {
    private func m4a(duration: Double = 1, frequency: Double = 440) throws -> FrozenAttachmentInput {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-recording-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let sampleRate = 44_100.0
            let format = try XCTUnwrap(AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
            ))
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let frameCount = AVAudioFrameCount(sampleRate * duration)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            let radiansPerFrame = 2.0 * Double.pi * frequency / sampleRate
            for frame in 0..<Int(frameCount) {
                channel[frame] = Float(0.15 * sin(radiansPerFrame * Double(frame)))
            }
            try file.write(from: buffer)
        }
        return try FrozenAttachmentInput(file: url)
    }

    private func nested(_ id: String, in attachments: [Attachment]) -> Attachment? {
        for attachment in attachments {
            if attachment.id == id { return attachment }
            if let found = nested(id, in: attachment.childAttachments ?? []) { return found }
        }
        return nil
    }

    private func signatures(_ attachments: [Attachment], parentID: String? = nil) -> [String] {
        attachments.flatMap { attachment in
            ["\(attachment.id)|\(attachment.typeUTI)|\(parentID ?? "")"] +
                signatures(attachment.childAttachments ?? [], parentID: attachment.id)
        }.sorted()
    }

    func testLiveSnapshotRecreatesSingleFragmentRecording() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-recording-restore-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return JSON.stringify(String(note.id())); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable recording-restore fixture creation failed: \(reply.stderr)")
        }
        let scriptingID = try JSONDecoder().decode(String.self, from: XCTUnwrap(reply.stdout.data(using: .utf8)))
        var noteID: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            noteID = try? SQLiteNotesStore(refresh: true).note(scriptingID).summary.id.uuid
            if noteID != nil { break }
        }
        let ref = try XCTUnwrap(noteID)
        let keepFixture = ProcessInfo.processInfo.environment["NOTESCLI_LIVE_KEEP_FIXTURE"] == "1"
        defer { if !keepFixture { _ = try? scripting.deleteNote(ref) } }
        if keepFixture { print("NOTESCLI_LIVE_FIXTURE_TITLE=\(title)") }

        let audio = try m4a()
        let transcript = [TranscriptWord(
            text: "Restored recording",
            start: 0.1,
            duration: 0.6,
            speaker: "Speaker 1",
            fragment: 0
        )]
        let inserted = try native.insertRecording(
            ref,
            frozen: audio,
            title: "Recording",
            duration: 1,
            transcript: transcript,
            allowShared: false
        )
        XCTAssertEqual(inserted.write.writeResult.outcome, .verified, inserted.write.writeResult.message ?? "no detail")
        let oldParentID = inserted.attachmentID
        let oldChildID = try XCTUnwrap(inserted.childAttachmentIDs.only)

        var snapshot = try SQLiteNotesStore(refresh: true).note(ref)
        let recordingIndex = try XCTUnwrap(snapshot.attachments.firstIndex(where: { $0.id == oldParentID }))
        snapshot.attachments[recordingIndex].recording = RecordingMetadata(
            summary: "A restored long-form recording summary.",
            topLineSummary: "Restored recording preview",
            summaryVersion: 1,
            localSpeakerHandle: "+1-555-0100",
            remoteSpeakerHandle: "+1-555-0199",
            callType: 1,
            isCallRecording: true,
            startTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-recording-snapshot-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }
        let snapshotStore = SnapshotStore(rootURL: snapshotRoot)
        let saved = try snapshotStore.save(snapshot)
        let loaded = try snapshotStore.loadRestorable(ref, snapshot: saved.id)

        XCTAssertEqual(
            try native.deleteAttachment(ref, attachmentID: oldParentID, allowShared: false).writeResult.outcome,
            .verified
        )
        setenv("NOTESCLI_TEST_TREAT_ABSENT", [oldParentID, oldChildID].joined(separator: ","), 1)
        defer { unsetenv("NOTESCLI_TEST_TREAT_ABSENT") }
        let deletedState = try SQLiteNotesStore(refresh: true).note(ref)
        setenv("NOTESCLI_TEST_CORRUPT_STAGED_RESTORE", oldChildID, 1)
        XCTAssertThrowsError(try native.restoreSnapshot(
            ref,
            snapshot: loaded.note,
            material: try snapshotStore.restoreMaterial(for: loaded),
            expectedRevision: nil,
            expectedModified: nil,
            allowShared: false
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_attachment_hash_mismatch")
        }
        unsetenv("NOTESCLI_TEST_CORRUPT_STAGED_RESTORE")
        let afterRollback = try SQLiteNotesStore(refresh: true).note(ref)
        XCTAssertEqual(signatures(afterRollback.attachments), signatures(deletedState.attachments))
        XCTAssertEqual(afterRollback.document, deletedState.document)
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
        let newChildID = try XCTUnwrap(idMap[oldChildID])
        XCTAssertNotEqual(newParentID, oldParentID)
        XCTAssertNotEqual(newChildID, oldChildID)

        let readBack = try SQLiteNotesStore(refresh: true).note(ref)
        let expected = try SnapshotAttachmentIDRemapper.remap(loaded.note, attachmentIDs: idMap)
        XCTAssertEqual(readBack.summary.title, expected.summary.title)
        let expectedDocument = try XCTUnwrap(expected.document)
        let actualDocument = try XCTUnwrap(readBack.document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expectedJSON = String(data: try encoder.encode(expectedDocument), encoding: .utf8) ?? ""
        let actualJSON = String(data: try encoder.encode(actualDocument), encoding: .utf8) ?? ""
        XCTAssertTrue(SnapshotRestoreVerification.matches(
            expectedDocument,
            actualDocument
        ), "expected=\(expectedJSON) actual=\(actualJSON)")
        XCTAssertEqual(signatures(readBack.attachments), signatures(expected.attachments))
        let recording = try XCTUnwrap(nested(newParentID, in: readBack.attachments))
        let fragment = try XCTUnwrap(nested(newChildID, in: readBack.attachments))
        let expectedRecording = try XCTUnwrap(expected.attachments.first { $0.id == newParentID })
        XCTAssertEqual(recording.typeUTI, expectedRecording.typeUTI)
        XCTAssertEqual(recording.title, expectedRecording.title)
        XCTAssertEqual(fragment.typeUTI, try XCTUnwrap(expected.attachments.first?.childAttachments?.first).typeUTI)
        XCTAssertEqual(recording.childAttachmentIDs, [newChildID])
        XCTAssertLessThan(abs((recording.duration ?? 0) - 1), 0.05)
        XCTAssertNil(RecordingFragments.mismatch(expected: transcript, actual: recording.transcriptWords ?? []))
        XCTAssertEqual(recording.recording?.summary, "A restored long-form recording summary.")
        XCTAssertEqual(recording.recording?.topLineSummary, "Restored recording preview")
        XCTAssertEqual(recording.recording?.summaryVersion, 1)
        XCTAssertEqual(recording.recording?.localSpeakerHandle, "+1-555-0100")
        XCTAssertEqual(recording.recording?.remoteSpeakerHandle, "+1-555-0199")
        XCTAssertEqual(recording.recording?.callType, 1)
        XCTAssertEqual(recording.recording?.isCallRecording, true)
        XCTAssertEqual(recording.recording?.startTime, Date(timeIntervalSince1970: 1_700_000_000))
        let fragmentPath = try XCTUnwrap(fragment.filePath)
        XCTAssertEqual(try FrozenAttachmentInput.hash(file: URL(fileURLWithPath: fragmentPath)), audio.sha256)
        XCTAssertGreaterThan(try AVAudioFile(forReading: URL(fileURLWithPath: fragmentPath)).length, 0)

        let silentTranscript = try native.insertRecording(
            ref,
            frozen: audio,
            title: "Recording without transcript",
            duration: 1,
            transcript: [],
            allowShared: false
        )
        XCTAssertEqual(silentTranscript.write.writeResult.outcome, .verified)
        let silentParentID = silentTranscript.attachmentID
        let silentChildID = try XCTUnwrap(silentTranscript.childAttachmentIDs.only)
        let silentSnapshot = try SQLiteNotesStore(refresh: true).note(ref)
        let silentSaved = try snapshotStore.save(silentSnapshot)
        let silentLoaded = try snapshotStore.loadRestorable(ref, snapshot: silentSaved.id)
        XCTAssertEqual(
            try native.deleteAttachment(ref, attachmentID: silentParentID, allowShared: false).writeResult.outcome,
            .verified
        )
        setenv("NOTESCLI_TEST_TREAT_ABSENT", [silentParentID, silentChildID].joined(separator: ","), 1)
        let silentRestored = try native.restoreSnapshot(
            ref,
            snapshot: silentLoaded.note,
            material: try snapshotStore.restoreMaterial(for: silentLoaded),
            expectedRevision: nil,
            expectedModified: nil,
            allowShared: false
        )
        XCTAssertEqual(
            silentRestored.writeResult.outcome,
            .verified,
            "\(silentRestored.writeResult.message ?? "no detail") native=\(silentRestored.verification.nativeReadback) sqlite=\(String(describing: silentRestored.verification.sqliteReadback))"
        )
        let silentMapData = try XCTUnwrap(
            silentRestored.verification.nativeReadback["attachmentIDMap"]?.data(using: .utf8)
        )
        let silentMap = try XCTUnwrap(JSONSerialization.jsonObject(with: silentMapData) as? [String: String])
        let newSilentParentID = try XCTUnwrap(silentMap[silentParentID])
        let silentReadBack = try SQLiteNotesStore(refresh: true).note(ref)
        let silentExpected = try SnapshotAttachmentIDRemapper.remap(silentLoaded.note, attachmentIDs: silentMap)
        if !SnapshotRestoreVerification.matches(expected: silentExpected, actual: silentReadBack) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let expectedJSON = String(data: try encoder.encode(silentExpected), encoding: .utf8) ?? ""
            let actualJSON = String(data: try encoder.encode(silentReadBack), encoding: .utf8) ?? ""
            XCTFail("silent expected=\(expectedJSON) actual=\(actualJSON)")
        }
        XCTAssertEqual(nested(newSilentParentID, in: silentReadBack.attachments)?.transcriptWords ?? [], [])
    }

    func testLiveHardPurgesAndRecreatesAppleMultiFragmentRecording() throws {
        guard let ref = ProcessInfo.processInfo.environment["NOTESCLI_LIVE_HARD_PURGE_RECORDING_REF"],
              !ref.isEmpty else {
            throw XCTSkip("Set NOTESCLI_LIVE_HARD_PURGE_RECORDING_REF to a disposable Apple-created recording note.")
        }
        let snapshotID = ProcessInfo.processInfo.environment["NOTESCLI_LIVE_HARD_PURGE_RECORDING_SNAPSHOT"]
        let native = NativeNotesWriter()
        let store = SnapshotStore()
        let loaded = try store.loadRestorable(ref, snapshot: snapshotID)
        let expected = try XCTUnwrap(loaded.note.attachments.first(where: {
            $0.kind == "audio" && ($0.childAttachmentIDs?.count ?? 0) > 1
        }))
        let oldChildIDs = try XCTUnwrap(expected.childAttachmentIDs)
        let expectedChildren = try XCTUnwrap(expected.childAttachments)
        XCTAssertEqual(oldChildIDs, expectedChildren.map(\.id))
        XCTAssertTrue(expectedChildren.allSatisfy { $0.duration == 0 })
        let archive = try XCTUnwrap(loaded.attachmentArchive)
        let childMaterials = oldChildIDs.compactMap { id in archive.attachments.first(where: { $0.id == id }) }
        XCTAssertEqual(childMaterials.count, oldChildIDs.count)
        XCTAssertTrue(childMaterials.allSatisfy { $0.mediaDuration != nil })
        XCTAssertEqual(childMaterials.compactMap(\.mediaDuration).reduce(0, +),
                       try XCTUnwrap(expected.duration), accuracy: 0.05)
        let expectedHashes = Dictionary(uniqueKeysWithValues: childMaterials.map {
            ($0.id, $0.blobSHA256 ?? "")
        })

        let beforePurge = try SQLiteNotesStore(refresh: true).note(ref)
        let currentRecordings = beforePurge.attachments.filter {
            $0.kind == "audio" && ($0.childAttachmentIDs?.count ?? 0) > 1
        }
        XCTAssertLessThanOrEqual(currentRecordings.count, 1)
        if let current = currentRecordings.first {
            try native.hardDeleteAttachmentsForTesting(
                ref,
                attachmentIDs: [current.id] + (current.childAttachmentIDs ?? [])
            )
        }
        let absent = try SQLiteNotesStore(refresh: true).note(ref)
        XCTAssertNil(nested(expected.id, in: absent.attachments))
        XCTAssertTrue(oldChildIDs.allSatisfy { nested($0, in: absent.attachments) == nil })

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
        let newParentID = try XCTUnwrap(idMap[expected.id])
        let newChildIDs = try oldChildIDs.map { try XCTUnwrap(idMap[$0]) }
        XCTAssertNotEqual(newParentID, expected.id)
        XCTAssertEqual(Set(newChildIDs).count, oldChildIDs.count)

        let readBack = try SQLiteNotesStore(refresh: true).note(ref)
        let recording = try XCTUnwrap(nested(newParentID, in: readBack.attachments))
        XCTAssertEqual(recording.childAttachmentIDs, newChildIDs)
        XCTAssertEqual(recording.childAttachments?.map(\.id), newChildIDs)
        XCTAssertEqual(recording.childAttachments?.map(\.duration), expectedChildren.map(\.duration))
        XCTAssertEqual(recording.recordingFragments?.map(\.transcriptVersion),
                       expected.recordingFragments?.map(\.transcriptVersion))
        XCTAssertEqual(recording.recordingFragments?.compactMap(\.createdDate),
                       expected.recordingFragments?.compactMap(\.createdDate))
        var expectedMetadata = expected.recording
        if expectedMetadata?.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            expectedMetadata?.summary = nil
        }
        if expectedMetadata?.topLineSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            expectedMetadata?.topLineSummary = nil
        }
        XCTAssertEqual(recording.recording, expectedMetadata)
        XCTAssertEqual(try XCTUnwrap(recording.duration), try XCTUnwrap(expected.duration), accuracy: 0.05)
        for (oldID, child) in zip(oldChildIDs, try XCTUnwrap(recording.childAttachments)) {
            let path = try XCTUnwrap(child.filePath)
            XCTAssertEqual(try FrozenAttachmentInput.hash(file: URL(fileURLWithPath: path)), expectedHashes[oldID])
        }

        let secondRestore = try native.restoreSnapshot(ref, snapshot: readBack, allowShared: false)
        XCTAssertEqual(secondRestore.writeResult.outcome, .verified, secondRestore.writeResult.message ?? "no detail")
        XCTAssertEqual(secondRestore.verification.nativeReadback["attachmentIDMap"], "{}")
    }

    func testLiveSnapshotRecreatesOrderedMultiFragmentRecording() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-recording-multi-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return JSON.stringify(String(note.id())); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable multi-recording fixture creation failed: \(reply.stderr)")
        }
        let scriptingID = try JSONDecoder().decode(String.self, from: XCTUnwrap(reply.stdout.data(using: .utf8)))
        var noteID: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            noteID = try? SQLiteNotesStore(refresh: true).note(scriptingID).summary.id.uuid
            if noteID != nil { break }
        }
        let ref = try XCTUnwrap(noteID)
        let keepFixture = ProcessInfo.processInfo.environment["NOTESCLI_LIVE_KEEP_FIXTURE"] == "1"
        defer { if !keepFixture { _ = try? scripting.deleteNote(ref) } }
        if keepFixture { print("NOTESCLI_LIVE_FIXTURE_TITLE=\(title)") }

        let firstAudio = try m4a(duration: 0.6, frequency: 330)
        let secondAudio = try m4a(duration: 0.8, frequency: 660)
        XCTAssertNotEqual(firstAudio.sha256, secondAudio.sha256)
        let inserted = try native.insertRecording(
            ref, frozen: firstAudio, title: nil, duration: 0.6, transcript: [], allowShared: false
        )
        XCTAssertEqual(inserted.write.writeResult.outcome, .verified)
        let oldParentID = inserted.attachmentID
        let oldFirstID = try XCTUnwrap(inserted.childAttachmentIDs.only)
        let oldSecondID = UUID().uuidString

        var snapshot = try SQLiteNotesStore(refresh: true).note(ref)
        let parentIndex = try XCTUnwrap(snapshot.attachments.firstIndex(where: { $0.id == oldParentID }))
        var parent = snapshot.attachments[parentIndex]
        var first = try XCTUnwrap(parent.childAttachments?.first(where: { $0.id == oldFirstID }))
        first.duration = 0.6
        var second = first
        second.id = oldSecondID
        second.filename = secondAudio.sourceName
        second.filePath = secondAudio.url.path
        second.duration = 0.8
        let firstDate = Date(timeIntervalSince1970: 1_700_000_100)
        let secondDate = Date(timeIntervalSince1970: 1_700_000_200)
        let transcript = [
            TranscriptWord(text: "First fragment", start: 0.05, duration: 0.4, speaker: "Speaker 1", fragment: 0),
            TranscriptWord(text: "Second fragment", start: 0.1, duration: 0.5, speaker: "Speaker 2", fragment: 1),
        ]
        parent.filePath = nil
        parent.duration = 1.4
        parent.transcriptText = "First fragment Second fragment"
        parent.transcriptWords = transcript
        parent.recording = RecordingMetadata(
            summary: "Multi-fragment summary",
            topLineSummary: "Multi-fragment preview",
            summaryVersion: 1,
            localSpeakerHandle: "+1-555-0100",
            remoteSpeakerHandle: "+1-555-0199",
            callType: 1,
            isCallRecording: true,
            startTime: Date(timeIntervalSince1970: 1_700_000_000.123)
        )
        parent.recordingFragments = [
            RecordingFragmentMetadata(id: oldFirstID, createdDate: firstDate, transcriptVersion: 1),
            RecordingFragmentMetadata(id: oldSecondID, createdDate: secondDate, transcriptVersion: 2),
        ]
        parent.childAttachmentIDs = [oldFirstID, oldSecondID]
        parent.childAttachments = [first, second]
        snapshot.attachments[parentIndex] = parent

        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-recording-multi-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }
        let notesRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes", isDirectory: true)
        let snapshotStore = SnapshotStore(
            rootURL: snapshotRoot,
            attachmentRoots: [notesRoot, secondAudio.url.deletingLastPathComponent()]
        )
        let saved = try snapshotStore.save(snapshot)
        let loaded = try snapshotStore.loadRestorable(ref, snapshot: saved.id)
        XCTAssertEqual(
            try native.deleteAttachment(ref, attachmentID: oldParentID, allowShared: false).writeResult.outcome,
            .verified
        )
        setenv("NOTESCLI_TEST_TREAT_ABSENT", [oldParentID, oldFirstID, oldSecondID].joined(separator: ","), 1)
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
        let newFirstID = try XCTUnwrap(idMap[oldFirstID])
        let newSecondID = try XCTUnwrap(idMap[oldSecondID])
        let readBack = try SQLiteNotesStore(refresh: true).note(ref)
        let recording = try XCTUnwrap(nested(newParentID, in: readBack.attachments))
        XCTAssertEqual(recording.childAttachmentIDs, [newFirstID, newSecondID])
        XCTAssertEqual(recording.childAttachments?.map(\.id), [newFirstID, newSecondID])
        XCTAssertEqual(recording.recordingFragments?.map(\.id), [newFirstID, newSecondID])
        XCTAssertEqual(recording.recordingFragments?.map(\.transcriptVersion), [1, 2])
        XCTAssertEqual(recording.recordingFragments?.compactMap(\.createdDate), [firstDate, secondDate])
        XCTAssertEqual(recording.recording, parent.recording)
        XCTAssertNil(RecordingFragments.mismatch(expected: transcript, actual: recording.transcriptWords ?? []))
        XCTAssertLessThan(abs((recording.duration ?? 0) - 1.4), 0.05)
        let children = try XCTUnwrap(recording.childAttachments)
        XCTAssertEqual(try FrozenAttachmentInput.hash(file: URL(fileURLWithPath: XCTUnwrap(children[0].filePath))), firstAudio.sha256)
        XCTAssertEqual(try FrozenAttachmentInput.hash(file: URL(fileURLWithPath: XCTUnwrap(children[1].filePath))), secondAudio.sha256)

        let secondRestore = try native.restoreSnapshot(ref, snapshot: readBack, allowShared: false)
        XCTAssertEqual(secondRestore.writeResult.outcome, .verified, secondRestore.writeResult.message ?? "no detail")
        XCTAssertTrue(secondRestore.verification.nativeReadback["attachmentIDMap"] == "{}")
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
