import Foundation
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesSafety
import NotesStore
import XCTest

final class LegacyDrawingRestoreTests: XCTestCase {
    private let records = [LegacyDrawingStrokeRecord(
        color: [0.2, 0.4, 0.8, 1],
        points: [
            .init(x: 10, y: 10, radius: 6, timestamp: 0),
            .init(x: 30, y: 40, radius: 6, timestamp: 0.02),
            .init(x: 60, y: 20, radius: 6, timestamp: 0.04),
        ]
    )]

    func testLegacyDrawingRecordValidationAndComparison() throws {
        try LegacyDrawingStrokeRecord.validate(records)
        XCTAssertNil(LegacyDrawingStrokeRecord.mismatch(expected: records, actual: records))
        var changed = records
        changed[0].points[1].radius = 9
        XCTAssertNotNil(LegacyDrawingStrokeRecord.mismatch(expected: records, actual: changed))
        changed = records
        changed[0].points[1].timestamp = 0
        XCTAssertNil(LegacyDrawingStrokeRecord.mismatch(expected: records, actual: changed))
    }

    func testLiveSnapshotRecreatesEditableLegacySketchAfterHardDeletion() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-legacy-restore-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return String(note.id()); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable legacy drawing fixture creation failed: \(reply.stderr)")
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

        let inserted = try native.insertLegacyDrawing(ref, records: records, position: nil, allowShared: false)
        XCTAssertEqual(inserted.write.writeResult.outcome, .verified, inserted.write.writeResult.message ?? "no detail")
        XCTAssertEqual(inserted.typeUTI, "com.apple.notes.sketch")
        let oldID = inserted.attachmentID

        let captured = try SQLiteNotesStore(refresh: true).note(ref)
        let payloads = try native.snapshotDrawingPayloads(ref)
        let payload = try XCTUnwrap(payloads[oldID])
        let capturedRecords = try JSONDecoder().decode([LegacyDrawingStrokeRecord].self, from: payload)
        XCTAssertNil(LegacyDrawingStrokeRecord.mismatch(expected: records, actual: capturedRecords))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-legacy-drawing-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let saved = try store.save(captured, drawingPayloads: payloads)
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)
        XCTAssertEqual(try store.restoreMaterial(for: loaded)?.archive.attachments.first(where: { $0.id == oldID })?.payloadKind,
                       "legacy-drawing-v1")

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
        XCTAssertTrue(readback.attachments.contains { $0.id == newID && $0.typeUTI == "com.apple.notes.sketch" })
        let restoredPayload = try XCTUnwrap(native.snapshotDrawingPayloads(ref)[newID])
        let restoredRecords = try JSONDecoder().decode([LegacyDrawingStrokeRecord].self, from: restoredPayload)
        XCTAssertNil(LegacyDrawingStrokeRecord.mismatch(expected: capturedRecords, actual: restoredRecords))
    }
}
