import Foundation
import NotesCore
import XCTest
@testable import NotesSync

final class SyncTests: XCTestCase {
    private final class UnknownAfterWrite: NotesWriting, @unchecked Sendable {
        enum Operation { case create, replace }
        let notes: InMemoryNotes, operation: Operation
        init(_ notes: InMemoryNotes, operation: Operation) { self.notes = notes; self.operation = operation }
        func createNote(title: String, markdown: String, folder: String?) throws -> WriteResult {
            let result = try notes.createNote(title: title, markdown: markdown, folder: folder)
            return operation == .create ? WriteResult(outcome: .unknown, noteID: result.noteID) : result
        }
        func replaceBody(_ ref: String, markdown: String) throws -> WriteResult {
            let result = try notes.replaceBody(ref, markdown: markdown)
            return operation == .replace ? WriteResult(outcome: .unknown, noteID: result.noteID) : result
        }
        func appendToNote(_ ref: String, markdown: String) throws -> WriteResult { try notes.appendToNote(ref, markdown: markdown) }
        func renameNote(_ ref: String, title: String) throws -> WriteResult { try notes.renameNote(ref, title: title) }
        func moveNote(_ ref: String, toFolder: String) throws -> WriteResult { try notes.moveNote(ref, toFolder: toFolder) }
        func deleteNote(_ ref: String) throws -> WriteResult { try notes.deleteNote(ref) }
        func createFolder(name: String, parent: String?, account: String?) throws -> WriteResult { try notes.createFolder(name: name, parent: parent, account: account) }
        func renameFolder(_ ref: String, name: String) throws -> WriteResult { try notes.renameFolder(ref, name: name) }
        func deleteFolder(_ ref: String) throws -> WriteResult { try notes.deleteFolder(ref) }
    }

    private func fixture() -> InMemoryNotes {
        let account = Account(id: "a", name: "A", kind: "local")
        let folder = Folder(id: "f", name: "Sync", accountID: "a", parentID: nil, path: ["Sync"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 1)
        let summary = NoteSummary(id: NoteID(uuid: "n1"), title: "Draft", snippet: "one", folderID: "f", folderPath: ["Sync"], accountID: "a", created: Date(timeIntervalSince1970: 1), modified: Date(timeIntervalSince1970: 1), isPinned: false, isLocked: false, isDeleted: false, hasChecklist: false, attachmentCount: 0, tags: [])
        return InMemoryNotes(accounts: [account], folders: [folder], notes: [Note(summary: summary, document: NoteDocument(text: "one\ntwo\nthree", runs: []), attachments: [])])
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-sync-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMergesEditsOnBothSides() throws {
        let fake = fixture(), root = try root(), sync = MarkdownSync(reader: fake, writer: fake)
        _ = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        let file = root.appendingPathComponent("Draft.md")
        var local = MarkdownFile.parse(try String(contentsOf: file), fallbackTitle: "Draft")
        local.body = "ONE\ntwo\nthree"; try local.rendered().write(to: file, atomically: true, encoding: .utf8)
        _ = try fake.replaceBody("n1", markdown: "one\ntwo\nTHREE")
        let report = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        XCTAssertEqual(report.conflicts, 0)
        XCTAssertEqual(try fake.note("n1").document?.text, "ONE\ntwo\nTHREE")
        XCTAssertTrue(try String(contentsOf: file).contains("ONE\ntwo\nTHREE"))
    }

    func testDefaultRestoresOneSidedDeleteAndPropagateDeletesSoftly() throws {
        let fake = fixture(), root = try root(), sync = MarkdownSync(reader: fake, writer: fake)
        _ = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        let file = root.appendingPathComponent("Draft.md")
        try FileManager.default.removeItem(at: file)
        _ = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file)
        _ = try sync.run(SyncOptions(directory: root, folder: "Sync", propagateDeletes: true))
        XCTAssertTrue(try fake.note("n1").summary.isDeleted)
    }

    func testRenameAndMoveCreatesFolder() throws {
        let fake = fixture(), root = try root(), sync = MarkdownSync(reader: fake, writer: fake)
        _ = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        let source = root.appendingPathComponent("Draft.md")
        let child = root.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let destination = child.appendingPathComponent("Renamed.md")
        try FileManager.default.moveItem(at: source, to: destination)
        _ = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        let note = try fake.note("n1")
        XCTAssertEqual(note.summary.title, "Renamed")
        XCTAssertEqual(note.summary.folderPath, ["Sync", "Child"])
    }

    func testNewMarkdownCreatesNoteAndDryRunDoesNotMutate() throws {
        let fake = fixture(), root = try root(), sync = MarkdownSync(reader: fake, writer: fake)
        _ = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        try "new body".write(to: root.appendingPathComponent("New.md"), atomically: true, encoding: .utf8)
        let dry = try sync.run(SyncOptions(directory: root, folder: "Sync", dryRun: true))
        XCTAssertTrue(dry.actions.contains { $0.kind == .createNote })
        XCTAssertThrowsError(try fake.note("New"))
        _ = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        XCTAssertEqual(try fake.note("New").document?.text, "new body")
    }

    func testOverlappingEditsWriteConflictMarkersAndDoNotOverwriteNotes() throws {
        let fake = fixture(), root = try root(), sync = MarkdownSync(reader: fake, writer: fake)
        _ = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        let file = root.appendingPathComponent("Draft.md")
        var local = MarkdownFile.parse(try String(contentsOf: file), fallbackTitle: "Draft")
        local.body = "one\nLOCAL\nthree"; try local.rendered().write(to: file, atomically: true, encoding: .utf8)
        _ = try fake.replaceBody("n1", markdown: "one\nREMOTE\nthree")
        let report = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        XCTAssertEqual(report.conflicts, 1)
        let conflicted = try String(contentsOf: file)
        XCTAssertTrue(conflicted.contains("<<<<<<< LOCAL")); XCTAssertTrue(conflicted.contains("REMOTE"))
        XCTAssertEqual(try fake.note("n1").document?.text, "one\nREMOTE\nthree")
        let repeated = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        XCTAssertEqual(repeated.conflicts, 1)
        var resolved = MarkdownFile.parse(try String(contentsOf: file), fallbackTitle: "Draft")
        resolved.body = "one\nLOCAL and REMOTE\nthree"
        try resolved.rendered().write(to: file, atomically: true, encoding: .utf8)
        _ = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        XCTAssertEqual(try fake.note("n1").document?.text, resolved.body)
    }

    func testRemoteDeleteIsRestoredByDefault() throws {
        let fake = fixture(), root = try root(), sync = MarkdownSync(reader: fake, writer: fake)
        _ = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        _ = try fake.deleteNote("n1")
        let report = try sync.run(SyncOptions(directory: root, folder: "Sync"))
        XCTAssertTrue(report.actions.contains { $0.kind == .restore })
        let active = try fake.notes(NoteQuery(folder: "Sync"))
        XCTAssertEqual(active.count, 1); XCTAssertEqual(active[0].title, "Draft")
    }

    func testRefusesAttachmentRoundTrip() throws {
        let fake = fixture(), root = try root()
        var note = try fake.note("n1")
        note.attachments = [Attachment(id: "a", typeUTI: "public.png")]
        note.summary.attachmentCount = 1
        let withAttachment = InMemoryNotes(accounts: try fake.accounts(), folders: try fake.folders(account: nil), notes: [note])
        let report = try MarkdownSync(reader: withAttachment, writer: withAttachment).run(SyncOptions(directory: root, folder: "Sync"))
        XCTAssertEqual(report.refusedAttachments, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Draft.md").path))
    }

    func testUnknownCreateIsReadBeforeAnyRetry() throws {
        let fake = fixture(), root = try root()
        _ = try MarkdownSync(reader: fake, writer: fake).run(SyncOptions(directory: root, folder: "Sync"))
        try "new".write(to: root.appendingPathComponent("New.md"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MarkdownSync(reader: fake, writer: UnknownAfterWrite(fake, operation: .create))
            .run(SyncOptions(directory: root, folder: "Sync"))) { error in
                guard case NotesSyncError.writeUnknown = error else { return XCTFail("Unexpected error: \(error)") }
            }
        _ = try MarkdownSync(reader: fake, writer: fake).run(SyncOptions(directory: root, folder: "Sync"))
        XCTAssertEqual(try fake.notes(NoteQuery(folder: "Sync")).filter { $0.title == "New" }.count, 1)
    }

    func testUnknownReplaceConvergesWithoutRepeatingBodyWrite() throws {
        let fake = fixture(), root = try root(), file = root.appendingPathComponent("Draft.md")
        _ = try MarkdownSync(reader: fake, writer: fake).run(SyncOptions(directory: root, folder: "Sync"))
        var markdown = MarkdownFile.parse(try String(contentsOf: file), fallbackTitle: "Draft")
        markdown.body = "changed"; try markdown.rendered().write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MarkdownSync(reader: fake, writer: UnknownAfterWrite(fake, operation: .replace))
            .run(SyncOptions(directory: root, folder: "Sync")))
        let report = try MarkdownSync(reader: fake, writer: fake).run(SyncOptions(directory: root, folder: "Sync"))
        XCTAssertTrue(report.actions.contains { $0.message.contains("same body") })
        XCTAssertEqual(try fake.note("n1").document?.text, "changed")
    }
}
