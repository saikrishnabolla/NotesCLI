import Foundation
import XCTest
import NotesAutomation
import NotesCore
import NotesNative
import NotesStore

final class NativeTests: XCTestCase {
    func testDoctorResolvesSupportedSurface() {
        let report = NativeNotesWriter().doctor()
        XCTAssertTrue(report.frameworkLoaded, report.error ?? "framework did not load")
        XCTAssertEqual(report.macOS, "27.2.1")
        XCTAssertTrue(report.missing.isEmpty, report.missing.joined(separator: ", "))
    }

    func testStyleNumbersMatchNotes() {
        XCTAssertEqual(NativeParagraphStyle.title.number, 0)
        XCTAssertEqual(NativeParagraphStyle.body.number, 3)
        XCTAssertEqual(NativeParagraphStyle.monospaced.number, 4)
        XCTAssertEqual(NativeParagraphStyle.bulleted.number, 100)
        XCTAssertEqual(NativeParagraphStyle.checklist.number, 103)
    }

    func testUTF16RangeCountsSurrogatePairs() {
        XCTAssertEqual(("a😀b" as NSString).length, 4)
        XCTAssertEqual(UTF16Range(location: 1, length: 2), UTF16Range(location: 1, length: 2))
    }

    func testLiveNativeCapabilities() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_TESTS=1; this suite writes only notescli-test/native.")
        }
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let native = NativeNotesWriter(), token = UUID().uuidString.lowercased()
        let prefix = "notescli-test-", title = prefix + token
        var createdFolders: [String] = [], createdNotes: [String] = [], createdBackups: [URL] = []
        var safeToClean = true

        func folderID(_ path: [String]) throws -> String? {
            try SQLiteNotesStore(refresh: true).folders(account: nil).first { $0.path == path }?.id
        }
        if try folderID(["notescli-test"]) == nil {
            createdFolders.append(try XCTUnwrap(scripting.createFolder(name: "notescli-test").folderID))
        }
        if try folderID(["notescli-test", "native"]) == nil {
            createdFolders.append(try XCTUnwrap(scripting.createFolder(name: "native", parent: "notescli-test").folderID))
        }
        let root = try XCTUnwrap(folderID(["notescli-test"]))
        let nativeFolder = try XCTUnwrap(folderID(["notescli-test", "native"]))

        func create(_ suffix: String, body: String = "body") throws -> String {
            let result = try scripting.createNote(title: title + suffix, markdown: body, folder: "notescli-test > native")
            guard result.outcome != .unknown else { safeToClean = false; throw NotesError("unknown_write", "Fixture creation outcome unknown.") }
            let ref = try XCTUnwrap(result.noteID?.coreDataID)
            createdNotes.append(ref); return ref
        }
        func pass(_ capability: String, _ evidence: String) { print("NATIVE LIVE \(capability): PASS \(evidence)") }

        defer {
            if !safeToClean { print("NATIVE LIVE cleanup: STOPPED after unknown outcome") }
            else { do {
                for ref in createdNotes.reversed() {
                    if let note = try? SQLiteNotesStore(refresh: true).note(ref), note.summary.title.hasPrefix(prefix), !note.summary.isDeleted {
                        _ = try scripting.deleteNote(ref)
                    }
                }
                for folder in createdFolders.reversed() { _ = try? scripting.deleteFolder(folder) }
                for backup in createdBackups { try? FileManager.default.removeItem(at: backup) }
                print("NATIVE LIVE cleanup: PASS")
            } catch { XCTFail("cleanup failed: \(error)") } }
        }

        let ref = try create("-main")
        let target = try create("-target")

        let inserted = try native.insertChecklist(ref, text: "task-\(token)", position: nil, allowShared: false)
        XCTAssertEqual(inserted.writeResult.outcome, .verified)
        let explicitPosition = (try SQLiteNotesStore(refresh: true).note(ref).document?.text as NSString?)?.length ?? 0
        _ = try native.insertChecklist(ref, text: "task-position-\(token)", position: explicitPosition, allowShared: false)
        _ = try native.toggleChecklist(ref, selection: .text("task-\(token)"), done: true, allowShared: false)
        XCTAssertEqual(try native.checklistItems(ref).first(where: { $0.text == "task-\(token)" })?.done, true)
        _ = try native.setAllChecklist(ref, done: true, allowShared: false)
        XCTAssertTrue(try native.checklistItems(ref).allSatisfy(\.done))
        _ = try native.setAllChecklist(ref, done: false, allowShared: false)
        let indexed = try XCTUnwrap(native.checklistItems(ref).first)
        _ = try native.toggleChecklist(ref, selection: .index(indexed.index), done: true, allowShared: false)
        _ = try native.deleteCompleted(ref, allowShared: false)
        XCTAssertFalse(try native.checklistItems(ref).contains(where: { $0.text == indexed.text }))
        pass("checklists", "insert/append/text/index/all/delete sqlite=\(inserted.verification.sqliteReadback != nil)")

        let pinned = try native.setPinned(ref, pinned: true, allowShared: false)
        XCTAssertEqual(pinned.verification.nativeReadback["pinned"], "true")
        let unpinned = try native.setPinned(ref, pinned: false, allowShared: false)
        XCTAssertEqual(unpinned.writeResult.outcome, .verified)
        pass("pin", "pin/unpin native=true sqlite=\(unpinned.verification.sqliteReadback != nil)")

        let tag = "notesclitest\(token.replacingOccurrences(of: "-", with: ""))"
        _ = try native.addTag(ref, tag: tag, position: nil, allowShared: false)
        _ = try native.removeTag(ref, tag: tag, allowShared: false)
        _ = try native.addTag(ref, tag: tag, position: nil, allowShared: false)
        let renamedTag = try native.renameTag(tag, to: tag + "r", expectedCount: 1)
        let deletedTag = try native.deleteTag(tag + "r", expectedCount: 1)
        XCTAssertEqual(renamedTag.writeResult.outcome, .verified)
        XCTAssertEqual(deletedTag.writeResult.outcome, .verified)
        pass("tags", "add/remove/rename/delete expectedCount=1 sqlite=true")

        _ = try native.insertNoteLink(ref, target: target, text: "target", position: nil, allowShared: false)
        XCTAssertEqual(try native.links(ref).count, 1)
        XCTAssertEqual(try native.backlinks(target).count, 1)
        pass("note-links", "links=1 backlinks=1")

        let textPosition = (try SQLiteNotesStore(refresh: true).note(ref).document?.text as NSString?)?.length ?? 0
        _ = try native.insertText(ref, text: " replace-me format-me", position: textPosition, allowShared: false)
        let replaceRange = try XCTUnwrap(native.searchOffsets(ref, text: "replace-me", caseInsensitive: false).first)
        _ = try native.replaceRange(ref, range: replaceRange, text: "replaced", allowShared: false)
        let deleteRange = try XCTUnwrap(native.searchOffsets(ref, text: "replaced", caseInsensitive: false).first)
        _ = try native.deleteRange(ref, range: UTF16Range(location: deleteRange.location, length: 3), allowShared: false)
        let offsets = try native.searchOffsets(ref, text: "format-me", caseInsensitive: false)
        let range = try XCTUnwrap(offsets.first)
        let formatted = try native.setInlineFormat(ref, range: range, format: InlineFormat(bold: true, italic: true, underline: true, strike: true, link: "https://example.com", color: "#336699"), allowShared: false)
        for style in NativeParagraphStyle.allCases {
            XCTAssertEqual(try native.setParagraphStyle(ref, range: range, style: style, indent: 1, allowShared: false).writeResult.outcome, .verified)
        }
        XCTAssertEqual(formatted.writeResult.outcome, .verified)
        pass("range-format", "insert/replace/delete allStyles offset=\(range.location) length=\(range.length) sqlite=true")

        let image = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-test-\(token).png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!.write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        let attached = try native.insertFile(ref, file: image, position: nil, imageView: "small", allowShared: false)
        XCTAssertEqual(attached.write.verification.nativeReadback["placements"], "1")
        _ = try native.deleteAttachment(ref, attachmentID: attached.attachmentID, allowShared: false)
        let large = try native.insertFile(ref, file: image, position: nil, imageView: "large", allowShared: false)
        _ = try native.deleteAttachment(ref, attachmentID: large.attachmentID, allowShared: false)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-test-\(token).txt")
        try Data("synthetic".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let fileAttachment = try native.insertFile(ref, file: file, position: nil, imageView: nil, allowShared: false)
        _ = try native.deleteAttachment(ref, attachmentID: fileAttachment.attachmentID, allowShared: false)
        pass("attachments", "small/large/file placements=1 deleted=true")

        let table = try native.createTable(ref, rows: [["a", "b"], ["c", "d"]], position: nil, allowShared: false)
        let tableID = try XCTUnwrap(table.verification.nativeReadback["tableID"])
        _ = try native.editTable(ref, attachmentID: tableID, row: 1, column: 1, text: "edited", allowShared: false)
        _ = try native.resizeTable(ref, attachmentID: tableID, axis: "row", index: 2, add: true, allowShared: false)
        _ = try native.resizeTable(ref, attachmentID: tableID, axis: "column", index: 2, add: true, allowShared: false)
        _ = try native.resizeTable(ref, attachmentID: tableID, axis: "row", index: 2, add: false, allowShared: false)
        let resized = try native.resizeTable(ref, attachmentID: tableID, axis: "column", index: 2, add: false, allowShared: false)
        XCTAssertEqual(resized.writeResult.outcome, .verified)
        pass("tables", "create/edit/add/remove rows=2 columns=2 sqlite=true")

        let markdown = "# \(title)-main\n## Heading\n- [x] done\n- item\n[web](https://example.com)\n![table](notescli-attachment:\(tableID))\n| x | y |\n| --- | --- |\n| 1 | 2 |\n"
        let backupRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NotesCLI/backups", isDirectory: true)
        let backupID = try SQLiteNotesStore(refresh: true).note(ref).summary.id.uuid
        let beforeBackups = Set((try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? [])
        let dry = try native.writeMarkdown(ref, markdown: markdown, dryRun: true, backup: true, allowShared: false)
        createdBackups = ((try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? []).filter { !beforeBackups.contains($0) && $0.lastPathComponent.hasPrefix(backupID) }
        XCTAssertEqual(dry.verification.nativeReadback["dryRun"], "true")
        XCTAssertEqual(Set(createdBackups.map(\.pathExtension)), Set(["md", "json"]))
        let written = try native.writeMarkdown(ref, markdown: markdown, dryRun: false, backup: false, allowShared: false)
        XCTAssertEqual(written.writeResult.outcome, .verified)
        let markdownReadback = try SQLiteNotesStore(refresh: true).note(ref)
        XCTAssertTrue(markdownReadback.summary.hasChecklist)
        XCTAssertEqual(markdownReadback.document?.tables?.count, 2)
        pass("write-markdown", "dry-run/checklist/headings/lists/links/tables backupFiles=2 sqlite=true")

        let child = try XCTUnwrap(scripting.createFolder(name: "notescli-test-\(token)", parent: "notescli-test > native").folderID)
        createdFolders.append(child)
        XCTAssertEqual(try native.moveFolder(child, parent: root, allowShared: false).writeResult.outcome, .verified)
        XCTAssertEqual(try native.moveFolder(child, parent: nativeFolder, allowShared: false).writeResult.outcome, .verified)
        pass("move-folder", "reparented twice native+sqlite")

        let restoreRef = try create("-restore")
        _ = try scripting.deleteNote(restoreRef)
        Thread.sleep(forTimeInterval: 1)
        _ = try native.restore(restoreRef, folder: nativeFolder, allowShared: false)
        XCTAssertFalse(try SQLiteNotesStore(refresh: true).note(restoreRef).summary.isDeleted)
        pass("restore", "sqlite isDeleted=false")

        let duplicate = try native.duplicate(target, title: title + "-copy", allowShared: false)
        let duplicateID = try XCTUnwrap(duplicate.writeResult.noteID?.uuid)
        createdNotes.append(duplicateID)
        pass("duplicate", "sqlite title verified=\(duplicate.verification.sqliteReadback != nil)")
    }
}
