import Foundation
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesSafety
import NotesStore
import XCTest

final class MapRestoreTests: XCTestCase {
    func testLiveSnapshotRecreatesNativeMapCard() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-map-restore-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return note.id(); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable map-restore fixture creation failed: \(reply.stderr)")
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

        let mapURL = try XCTUnwrap(URL(string: "https://maps.apple.com/?ll=37.3349,-122.0090&q=Apple+Park"))
        let inserted = try native.insertMap(ref, url: mapURL, position: nil, allowShared: false)
        XCTAssertEqual(inserted.writeResult.outcome, .verified)
        let oldID = try XCTUnwrap(inserted.verification.nativeReadback["attachmentID"])
        let captured = try SQLiteNotesStore(refresh: true).note(ref)
        let savedMap = try XCTUnwrap(captured.attachments.first(where: { $0.id == oldID }))
        XCTAssertEqual(savedMap.url, mapURL.absoluteString)
        XCTAssertEqual(savedMap.hasMapLocation, true)
        XCTAssertEqual(savedMap.mapLatitude ?? 0, 37.3349, accuracy: 0.000000001)
        XCTAssertEqual(savedMap.mapLongitude ?? 0, -122.0090, accuracy: 0.000000001)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-map-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(rootURL: root)
        let linkPayloads = try native.snapshotLinkPayloads(ref)
        let originalLinkPayload = linkPayloads[oldID]
        let saved = try store.save(captured, linkPayloads: linkPayloads)
        let loaded = try store.loadRestorable(ref, snapshot: saved.id)

        setenv("NOTESCLI_TEST_TREAT_ABSENT", oldID, 1)
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
        let newID = try XCTUnwrap(idMap[oldID])
        XCTAssertNotEqual(newID, oldID)
        let readback = try SQLiteNotesStore(refresh: true).note(ref)
        let recreated = try XCTUnwrap(readback.attachments.first(where: { $0.id == newID }))
        XCTAssertEqual(recreated.url, mapURL.absoluteString)
        XCTAssertEqual(recreated.hasMapLocation, true)
        XCTAssertEqual(recreated.mapLatitude ?? 0, savedMap.mapLatitude ?? 1, accuracy: 0.000000001)
        XCTAssertEqual(recreated.mapLongitude ?? 0, savedMap.mapLongitude ?? 1, accuracy: 0.000000001)
        XCTAssertTrue(try SQLiteNotesStore(refresh: true).attachmentHasStoredLocation(
            note: ref,
            attachmentID: newID
        ))
        if let originalLinkPayload {
            let restoredLinkPayload = try XCTUnwrap(try native.snapshotLinkPayloads(ref)[newID])
            XCTAssertEqual(restoredLinkPayload.synapseData, originalLinkPayload.synapseData)
            XCTAssertEqual(restoredLinkPayload.linkPresentationMetadata, originalLinkPayload.linkPresentationMetadata)
        }
    }
}
