import Foundation
import NotesAutomation
import NotesCore
@testable import NotesNative
import NotesStore
import XCTest

final class TableCellParentTests: XCTestCase {
    private func removingTopLevelMarker(_ id: String, from document: NoteDocument) -> NoteDocument {
        let source = document.text as NSString
        var text = ""
        var runs: [AttributeRun] = []
        var offset = 0
        for run in document.runs {
            let part = source.substring(with: NSRange(location: offset, length: run.length))
            offset += run.length
            if run.attachment?.id == id { continue }
            text += part
            runs.append(run)
        }
        var result = document
        result.text = text
        result.runs = runs
        return result
    }

    func testLiveTableCellCapturesActualNilParentAndRestoresIdempotently() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-table-parent-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return JSON.stringify(String(note.id())); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable table-parent fixture creation failed: \(reply.stderr)")
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

        let tableResult = try native.createTable(
            ref,
            rows: [["original", "second"], ["third", "fourth"]],
            position: nil,
            allowShared: false
        )
        XCTAssertEqual(tableResult.writeResult.outcome, .verified)
        let tableID = try XCTUnwrap(tableResult.verification.nativeReadback["tableID"])
        XCTAssertEqual(try native.addTag(ref, tag: "cellprobe", position: nil, allowShared: false).writeResult.outcome, .verified)

        var snapshot = try SQLiteNotesStore(refresh: true).note(ref)
        let tagRef = try XCTUnwrap(snapshot.document?.runs.compactMap(\.attachment).first {
            $0.typeUTI == "com.apple.notes.inlinetextattachment.hashtag"
        })
        XCTAssertEqual(tagRef.parentAttachmentCaptured, true)
        XCTAssertNil(tagRef.parentAttachmentID)
        var document = removingTopLevelMarker(tagRef.id, from: try XCTUnwrap(snapshot.document))
        let oldCell = try XCTUnwrap(document.tableCells?[tableID]?.first?.first)
        let style = oldCell.runs.first
        document.tableCells?[tableID] = [[TableCellDocument(
            text: "\u{fffc}",
            runs: [AttributeRun(
                length: 1,
                paragraph: style?.paragraph,
                font: style?.font ?? FontStyle(),
                attachment: tagRef
            )]
        )]]
        document.tables?[tableID] = [["#cellprobe"]]
        snapshot.document = document

        let first = try native.restoreSnapshot(ref, snapshot: snapshot, allowShared: false)
        XCTAssertEqual(first.writeResult.outcome, .verified, first.writeResult.message ?? "no detail")
        let readBack = try SQLiteNotesStore(refresh: true).note(ref)
        let cellRef = try XCTUnwrap(readBack.document?.tableCells?[tableID]?.first?.first?.runs.compactMap(\.attachment).first)
        XCTAssertEqual(cellRef.id, tagRef.id)
        XCTAssertEqual(cellRef.parentAttachmentCaptured, true)
        XCTAssertNil(cellRef.parentAttachmentID)
        XCTAssertFalse(readBack.document?.runs.contains(where: { $0.attachment?.id == tagRef.id }) ?? true)

        let second = try native.restoreSnapshot(ref, snapshot: readBack, allowShared: false)
        XCTAssertEqual(second.writeResult.outcome, .verified, second.writeResult.message ?? "no detail")

        setenv("NOTESCLI_TEST_TREAT_ABSENT", tagRef.id, 1)
        defer { unsetenv("NOTESCLI_TEST_TREAT_ABSENT") }
        let recreated = try native.restoreSnapshot(ref, snapshot: readBack, allowShared: false)
        XCTAssertEqual(recreated.writeResult.outcome, .verified, recreated.writeResult.message ?? "no detail")
        let mapData = try XCTUnwrap(recreated.verification.nativeReadback["attachmentIDMap"]?.data(using: .utf8))
        let idMap = try XCTUnwrap(JSONSerialization.jsonObject(with: mapData) as? [String: String])
        let newTagID = try XCTUnwrap(idMap[tagRef.id])
        XCTAssertNotEqual(newTagID, tagRef.id)
        let recreatedReadBack = try SQLiteNotesStore(refresh: true).note(ref)
        let recreatedRef = try XCTUnwrap(
            recreatedReadBack.document?.tableCells?[tableID]?.first?.first?.runs.compactMap(\.attachment).first
        )
        XCTAssertEqual(recreatedRef.id, newTagID)
        XCTAssertEqual(recreatedRef.parentAttachmentCaptured, true)
        XCTAssertNil(recreatedRef.parentAttachmentID)
        XCTAssertFalse(recreatedReadBack.attachments.contains { $0.id == tagRef.id })

        var withoutTag = recreatedReadBack
        var withoutTagDocument = try XCTUnwrap(withoutTag.document)
        let currentCell = try XCTUnwrap(withoutTagDocument.tableCells?[tableID]?.first?.first)
        withoutTagDocument.tableCells?[tableID] = [[TableCellDocument(
            text: "plain",
            runs: [AttributeRun(
                length: 5,
                paragraph: currentCell.runs.first?.paragraph,
                font: currentCell.runs.first?.font ?? FontStyle()
            )]
        )]]
        withoutTagDocument.tables?[tableID] = [["plain"]]
        withoutTag.document = withoutTagDocument
        withoutTag.attachments.removeAll { $0.id == newTagID }
        let removed = try native.restoreSnapshot(ref, snapshot: withoutTag, allowShared: false)
        XCTAssertEqual(removed.writeResult.outcome, .verified, removed.writeResult.message ?? "no detail")
        let removedReadBack = try SQLiteNotesStore(refresh: true).note(ref)
        XCTAssertFalse(removedReadBack.attachments.contains { $0.id == newTagID })
        XCTAssertEqual(removedReadBack.document?.tableCells?[tableID]?.first?.first?.text, "plain")
    }

    func testLiveSnapshotRecreatesTableParentedTagWithNewID() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-table-parented-tag-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return String(note.id()); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable table-parent fixture creation failed: \(reply.stderr)")
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

        let tableResult = try native.createTable(ref, rows: [["original"]], position: nil, allowShared: false)
        let tableID = try XCTUnwrap(tableResult.verification.nativeReadback["tableID"])
        XCTAssertEqual(
            try native.addTag(ref, tag: "parented", position: nil, allowShared: false).writeResult.outcome,
            .verified
        )
        var snapshot = try SQLiteNotesStore(refresh: true).note(ref)
        let oldTagID = try XCTUnwrap(snapshot.document?.runs.compactMap(\.attachment).first {
            $0.typeUTI == "com.apple.notes.inlinetextattachment.hashtag" &&
                $0.displayText?.trimmingCharacters(in: CharacterSet(charactersIn: "#")) == "parented"
        }?.id)
        var document = removingTopLevelMarker(oldTagID, from: try XCTUnwrap(snapshot.document))
        var tagReference = try XCTUnwrap(snapshot.document?.runs.compactMap(\.attachment).first { $0.id == oldTagID })
        tagReference.parentAttachmentCaptured = true
        tagReference.parentAttachmentID = tableID
        let style = try XCTUnwrap(document.tableCells?[tableID]?.first?.first?.runs.first)
        document.tableCells?[tableID] = [[TableCellDocument(
            text: "\u{fffc}",
            runs: [AttributeRun(
                length: 1,
                paragraph: style.paragraph,
                font: style.font,
                attachment: tagReference
            )]
        )]]
        document.tables?[tableID] = [["#parented"]]
        snapshot.document = document

        let tag = try XCTUnwrap(snapshot.attachments.first(where: { $0.id == oldTagID }))
        snapshot.attachments.removeAll { $0.id == oldTagID }
        let tableIndex = try XCTUnwrap(snapshot.attachments.firstIndex(where: { $0.id == tableID }))
        snapshot.attachments[tableIndex].childAttachmentIDs = [oldTagID]
        snapshot.attachments[tableIndex].childAttachments = [tag]

        setenv("NOTESCLI_TEST_TREAT_ABSENT", oldTagID, 1)
        defer { unsetenv("NOTESCLI_TEST_TREAT_ABSENT") }
        let restored = try native.restoreSnapshot(ref, snapshot: snapshot, allowShared: false)
        XCTAssertEqual(restored.writeResult.outcome, .verified, restored.writeResult.message ?? "no detail")
        let mapData = try XCTUnwrap(restored.verification.nativeReadback["attachmentIDMap"]?.data(using: .utf8))
        let idMap = try XCTUnwrap(JSONSerialization.jsonObject(with: mapData) as? [String: String])
        let newTagID = try XCTUnwrap(idMap[oldTagID])
        XCTAssertNotEqual(newTagID, oldTagID)

        let readback = try SQLiteNotesStore(refresh: true).note(ref)
        let table = try XCTUnwrap(readback.attachments.first(where: { $0.id == tableID }))
        XCTAssertEqual(table.childAttachmentIDs, [newTagID])
        XCTAssertEqual(table.childAttachments?.first?.id, newTagID)
        let cellReference = try XCTUnwrap(
            readback.document?.tableCells?[tableID]?.first?.first?.runs.compactMap(\.attachment).first
        )
        XCTAssertEqual(cellReference.id, newTagID)
        XCTAssertEqual(cellReference.parentAttachmentID, tableID)
        XCTAssertEqual(cellReference.parentAttachmentCaptured, true)

        let second = try native.restoreSnapshot(ref, snapshot: readback, allowShared: false)
        XCTAssertEqual(second.writeResult.outcome, .verified, second.writeResult.message ?? "no detail")
    }

    func testLiveSnapshotRecreatesTableParentedLinkDividerMathAndSelfParagraphLink() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes disposable notescli-test notes.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let sourceTitle = "notescli-test-table-parented-inline-\(UUID().uuidString.lowercased())"
        let targetTitle = "notescli-test-table-parented-target-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const first = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); const second = app.make({new: 'note', at: account, withProperties: {name: argv[1], body: '<h1>' + argv[1] + '</h1><p>target</p>'}}); return JSON.stringify([String(first.id()), String(second.id())]); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [sourceTitle, targetTitle], timeout: 20)
        guard !reply.timedOut, reply.status == 0,
              let data = reply.stdout.data(using: .utf8),
              let scriptingIDs = try? JSONDecoder().decode([String].self, from: data),
              scriptingIDs.count == 2 else {
            throw NotesError("unknown_write", "Disposable table-parent fixtures failed: \(reply.stderr)")
        }
        var sourceID: String?, targetID: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            sourceID = try? SQLiteNotesStore(refresh: true).note(scriptingIDs[0]).summary.id.uuid
            targetID = try? SQLiteNotesStore(refresh: true).note(scriptingIDs[1]).summary.id.uuid
            if sourceID != nil, targetID != nil { break }
        }
        let ref = try XCTUnwrap(sourceID), target = try XCTUnwrap(targetID)
        defer {
            _ = try? scripting.deleteNote(ref)
            _ = try? scripting.deleteNote(target)
        }

        let sourceRange = try XCTUnwrap(native.searchOffsets(ref, text: "body", caseInsensitive: false).first)
        XCTAssertEqual(
            try native.setParagraphStyle(ref, range: sourceRange, style: .heading, indent: 0,
                                         alignment: nil, writingDirection: nil, collapsed: false,
                                         allowShared: false).writeResult.outcome,
            .verified
        )
        let sourceDocument = try XCTUnwrap(try SQLiteNotesStore(refresh: true).note(ref).document)
        let sourceText = sourceDocument.text as NSString
        var sourceOffset = 0
        var sourceParagraphID: String?
        for run in sourceDocument.runs {
            defer { sourceOffset += run.length }
            let range = NSRange(location: sourceOffset, length: run.length)
            if run.paragraph?.kind == .heading,
               sourceText.substring(with: range).contains("body"),
               let paragraphID = run.paragraph?.id {
                sourceParagraphID = paragraphID
                break
            }
        }
        let paragraphID = try XCTUnwrap(sourceParagraphID)

        let tableResult = try native.createTable(ref, rows: [["one", "two", "three", "four"]], position: nil, allowShared: false)
        let tableID = try XCTUnwrap(tableResult.verification.nativeReadback["tableID"])
        let linkID = try XCTUnwrap(
            native.insertNoteLink(ref, target: target, text: "target", position: nil, allowShared: false)
                .verification.nativeReadback["attachmentID"]
        )
        let dividerID = try XCTUnwrap(
            native.insertDivider(ref, position: nil, allowShared: false)
                .verification.nativeReadback["attachmentID"]
        )
        let mathID = try XCTUnwrap(
            native.insertMathExpression(ref, expression: "2+2", position: nil, allowShared: false)
                .verification.nativeReadback["attachmentID"]
        )
        let selfLinkID = try XCTUnwrap(
            native.insertNoteLink(ref, target: ref, text: nil, paragraphID: paragraphID,
                                  paragraphName: nil, position: nil, allowShared: false)
                .verification.nativeReadback["attachmentID"]
        )
        let oldIDs = [linkID, dividerID, mathID, selfLinkID]
        var snapshot = try SQLiteNotesStore(refresh: true).note(ref)
        let originalDocument = try XCTUnwrap(snapshot.document)
        var document = oldIDs.reduce(originalDocument) { removingTopLevelMarker($1, from: $0) }
        let style = try XCTUnwrap(document.tableCells?[tableID]?.first?.first?.runs.first)
        let references = try oldIDs.map { oldID -> InlineRef in
            var reference = try XCTUnwrap(originalDocument.runs.compactMap(\.attachment).first { $0.id == oldID })
            reference.parentAttachmentCaptured = true
            reference.parentAttachmentID = tableID
            return reference
        }
        let cells = references.map { reference in
            TableCellDocument(
                text: "\u{fffc}",
                runs: [AttributeRun(length: 1, paragraph: style.paragraph, font: style.font, attachment: reference)]
            )
        }
        document.tableCells?[tableID] = [cells]
        document.tables?[tableID] = [cells.map { $0.document.plainText() }]
        snapshot.document = document

        let children = try oldIDs.map { oldID in
            try XCTUnwrap(snapshot.attachments.first(where: { $0.id == oldID }))
        }
        snapshot.attachments.removeAll { oldIDs.contains($0.id) }
        let tableIndex = try XCTUnwrap(snapshot.attachments.firstIndex(where: { $0.id == tableID }))
        snapshot.attachments[tableIndex].childAttachmentIDs = oldIDs
        snapshot.attachments[tableIndex].childAttachments = children

        try native.hardDeleteAttachmentsForTesting(ref, attachmentIDs: [tableID] + oldIDs)
        let absent = try SQLiteNotesStore(refresh: true).note(ref)
        XCTAssertNil(absent.attachments.first(where: { $0.id == tableID }))
        XCTAssertTrue(oldIDs.allSatisfy { id in
            absent.attachments.allSatisfy { $0.id != id && $0.childAttachments?.contains(where: { $0.id == id }) != true }
        })
        let restored = try native.restoreSnapshot(ref, snapshot: snapshot, allowShared: false)
        XCTAssertEqual(restored.writeResult.outcome, .verified, restored.writeResult.message ?? "no detail")
        let mapData = try XCTUnwrap(restored.verification.nativeReadback["attachmentIDMap"]?.data(using: .utf8))
        let idMap = try XCTUnwrap(JSONSerialization.jsonObject(with: mapData) as? [String: String])
        let newTableID = try XCTUnwrap(idMap[tableID])
        let newIDs = try oldIDs.map { try XCTUnwrap(idMap[$0]) }

        let readback = try SQLiteNotesStore(refresh: true).note(ref)
        let table = try XCTUnwrap(readback.attachments.first(where: { $0.id == newTableID }))
        XCTAssertEqual(Set(table.childAttachmentIDs ?? []), Set(newIDs))
        let nested = Dictionary(uniqueKeysWithValues: (table.childAttachments ?? []).map { ($0.id, $0) })
        XCTAssertEqual(nested[newIDs[0]]?.targetNoteID?.lowercased(), target.lowercased())
        XCTAssertEqual(nested[newIDs[1]]?.isDivider, true)
        XCTAssertTrue(nested[newIDs[2]]?.mathExpression == "2+2" || nested[newIDs[2]]?.graphExpression == "2+2")
        XCTAssertEqual(nested[newIDs[3]]?.targetNoteID?.lowercased(), ref.lowercased())
        XCTAssertEqual(nested[newIDs[3]]?.targetParagraphID?.lowercased(), paragraphID.lowercased())
        let cellIDs = readback.document?.tableCells?[newTableID]?.first?.compactMap {
            $0.runs.compactMap(\.attachment).first?.id
        }
        XCTAssertEqual(cellIDs, newIDs)
        for reference in readback.document?.tableCells?[newTableID]?.first?.flatMap({ $0.runs.compactMap(\.attachment) }) ?? [] {
            XCTAssertEqual(reference.parentAttachmentID, newTableID)
        }
    }
}
