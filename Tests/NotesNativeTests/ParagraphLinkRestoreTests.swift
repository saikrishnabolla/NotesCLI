import XCTest
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesSafety
import NotesStore

final class ParagraphLinkRestoreTests: XCTestCase {
    func testLiveSnapshotRecreatesParagraphLinkAndParagraphIdentities() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes two disposable notescli-test notes.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let token = UUID().uuidString.lowercased()
        let sourceTitle = "notescli-test-paragraph-link-source-\(token)"
        let targetTitle = "notescli-test-paragraph-link-target-\(token)"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const source = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>Source body</p>'}}); const target = app.make({new: 'note', at: account, withProperties: {name: argv[1], body: '<h1>' + argv[1] + '</h1><h2>Target Section</h2><p>Target body</p>'}}); return JSON.stringify({source: source.id(), target: target.id()}); }"
        let reply = try runner.run(source: create, language: .javaScript,
                                   arguments: [sourceTitle, targetTitle], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable paragraph-link fixture creation failed: \(reply.stderr)")
        }
        let data = try XCTUnwrap(reply.stdout.data(using: .utf8))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let sourceScriptID = try XCTUnwrap(fixture["source"])
        let targetScriptID = try XCTUnwrap(fixture["target"])
        var sourceID: String?, targetID: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            sourceID = sourceID ?? (try? SQLiteNotesStore(refresh: true).note(sourceScriptID).summary.id.uuid)
            targetID = targetID ?? (try? SQLiteNotesStore(refresh: true).note(targetScriptID).summary.id.uuid)
            if sourceID != nil, targetID != nil { break }
        }
        let source = try XCTUnwrap(sourceID)
        let target = try XCTUnwrap(targetID)
        defer {
            _ = try? scripting.deleteNote(source)
            _ = try? scripting.deleteNote(target)
        }

        let sourceRange = try XCTUnwrap(native.searchOffsets(source, text: "Source body", caseInsensitive: false).first)
        let targetRange = try XCTUnwrap(native.searchOffsets(target, text: "Target Section", caseInsensitive: false).first)
        XCTAssertEqual(
            try native.setParagraphStyle(source, range: sourceRange, style: .heading, indent: 0,
                                         alignment: nil, writingDirection: nil, collapsed: false,
                                         allowShared: false).writeResult.outcome,
            .verified
        )
        XCTAssertEqual(
            try native.setParagraphStyle(target, range: targetRange, style: .heading, indent: 0,
                                         alignment: nil, writingDirection: nil, collapsed: false,
                                         allowShared: false).writeResult.outcome,
            .verified
        )

        func findParagraphID(in document: NoteDocument, kind: ParagraphStyle.Kind, containing value: String) -> String? {
            var offset = 0
            let text = document.text as NSString
            for run in document.runs {
                defer { offset += run.length }
                let range = NSRange(location: offset, length: run.length)
                if run.paragraph?.kind == kind, text.substring(with: range).contains(value),
                   let id = run.paragraph?.id { return id }
            }
            return nil
        }
        let sourceDocument = try XCTUnwrap(try SQLiteNotesStore(refresh: true).note(source).document)
        let sourceParagraphID = try XCTUnwrap(findParagraphID(in: sourceDocument, kind: .heading, containing: "Source body"))
        let targetDocument = try XCTUnwrap(try SQLiteNotesStore(refresh: true).note(target).document)
        let paragraphID = try XCTUnwrap(findParagraphID(in: targetDocument, kind: .heading, containing: "Target Section"))
        XCTAssertNotNil(UUID(uuidString: paragraphID))
        let bodyParagraphID = try XCTUnwrap(findParagraphID(in: targetDocument, kind: .body, containing: "Target body"))
        XCTAssertThrowsError(
            try native.insertNoteLink(source, target: target, text: nil, paragraphID: bodyParagraphID,
                                      paragraphName: nil, position: nil, allowShared: false)
        ) { error in
            XCTAssertEqual((error as? NotesError)?.code, "paragraph_not_linkable")
        }

        let selfAdded = try native.insertNoteLink(
            source, target: source, text: nil, paragraphID: sourceParagraphID,
            paragraphName: nil, position: nil, allowShared: false
        )
        XCTAssertEqual(selfAdded.writeResult.outcome, .verified, selfAdded.writeResult.message ?? "no detail")
        let oldSelfLinkID = try XCTUnwrap(selfAdded.verification.nativeReadback["attachmentID"])

        let added = try native.insertNoteLink(
            source, target: target, text: nil, paragraphID: paragraphID,
            paragraphName: nil, position: nil, allowShared: false
        )
        XCTAssertEqual(added.writeResult.outcome, .verified, added.writeResult.message ?? "no detail")
        let oldLinkID = try XCTUnwrap(added.verification.nativeReadback["attachmentID"])
        let before = try SQLiteNotesStore(refresh: true).note(source)
        let savedParagraphIDs = Set(before.document?.runs.compactMap { $0.paragraph?.id?.uppercased() } ?? [])
        XCTAssertFalse(savedParagraphIDs.isEmpty)
        let savedLink = try XCTUnwrap(before.attachments.first(where: { $0.id == oldLinkID }))
        XCTAssertEqual(savedLink.targetNoteID?.lowercased(), target.lowercased())
        XCTAssertEqual(savedLink.targetParagraphID?.lowercased(), paragraphID.lowercased())

        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-paragraph-link-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotRoot) }
        let snapshots = SnapshotStore(rootURL: snapshotRoot)
        let saved = try snapshots.save(before)
        let loaded = try snapshots.loadRestorable(source, snapshot: saved.id)

        XCTAssertEqual(
            try native.setParagraphStyle(source, range: sourceRange, style: .body, indent: 0,
                                         alignment: nil, writingDirection: nil, collapsed: nil,
                                         allowShared: false).writeResult.outcome,
            .verified
        )
        try native.hardDeleteAttachmentsForTesting(source, attachmentIDs: [oldSelfLinkID, oldLinkID])
        let afterDeletion = try SQLiteNotesStore(refresh: true).note(source)
        XCTAssertFalse(afterDeletion.attachments.contains(where: { $0.id == oldSelfLinkID || $0.id == oldLinkID }))
        let restored = try native.restoreSnapshot(
            source, snapshot: loaded.note, material: try snapshots.restoreMaterial(for: loaded),
            expectedRevision: nil, expectedModified: nil, allowShared: false
        )
        let mapData = try XCTUnwrap(restored.verification.nativeReadback["attachmentIDMap"]?.data(using: .utf8))
        let idMap = try XCTUnwrap(JSONSerialization.jsonObject(with: mapData) as? [String: String])
        let newLinkID = try XCTUnwrap(idMap[oldLinkID])
        let newSelfLinkID = try XCTUnwrap(idMap[oldSelfLinkID])
        XCTAssertNotEqual(newLinkID, oldLinkID)
        XCTAssertNotEqual(newSelfLinkID, oldSelfLinkID)

        let fresh = try SQLiteNotesStore(refresh: true).note(source)
        XCTAssertEqual(restored.writeResult.outcome, .verified, restored.writeResult.message ?? "no detail")
        let restoredLink = try XCTUnwrap(fresh.attachments.first(where: { $0.id == newLinkID }))
        XCTAssertEqual(restoredLink.targetNoteID?.lowercased(), target.lowercased())
        XCTAssertEqual(restoredLink.targetParagraphID?.lowercased(), paragraphID.lowercased())
        XCTAssertEqual(Set(fresh.document?.runs.compactMap { $0.paragraph?.id?.uppercased() } ?? []), savedParagraphIDs)
        let nativeLink = try XCTUnwrap(native.links(source).first(where: { $0.attachmentID == newLinkID }))
        XCTAssertEqual(nativeLink.targetID.lowercased(), target.lowercased())
        XCTAssertEqual(nativeLink.targetParagraphID?.lowercased(), paragraphID.lowercased())
        let nativeSelfLink = try XCTUnwrap(native.links(source).first(where: { $0.attachmentID == newSelfLinkID }))
        XCTAssertEqual(nativeSelfLink.targetID.lowercased(), source.lowercased())
        XCTAssertEqual(nativeSelfLink.targetParagraphID?.lowercased(), sourceParagraphID.lowercased())
    }
}
