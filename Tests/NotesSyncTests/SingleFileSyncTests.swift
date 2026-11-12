import Foundation
import NotesCore
import XCTest
@testable import NotesSync

final class SingleFileSyncTests: XCTestCase {
    private final class UnknownWriter: NotesWriting, @unchecked Sendable {
        let notes: InMemoryNotes
        private(set) var replacements = 0
        init(_ notes: InMemoryNotes) { self.notes = notes }
        func createNote(title: String, markdown: String, folder: String?) throws -> WriteResult { try notes.createNote(title: title, markdown: markdown, folder: folder) }
        func replaceBody(_ ref: String, markdown: String) throws -> WriteResult {
            replacements += 1; _ = try notes.replaceBody(ref, markdown: markdown)
            return WriteResult(outcome: .unknown, noteID: try notes.note(ref).summary.id)
        }
        func appendToNote(_ ref: String, markdown: String) throws -> WriteResult { try notes.appendToNote(ref, markdown: markdown) }
        func renameNote(_ ref: String, title: String) throws -> WriteResult { try notes.renameNote(ref, title: title) }
        func moveNote(_ ref: String, toFolder: String) throws -> WriteResult { try notes.moveNote(ref, toFolder: toFolder) }
        func deleteNote(_ ref: String) throws -> WriteResult { try notes.deleteNote(ref) }
        func createFolder(name: String, parent: String?, account: String?) throws -> WriteResult { try notes.createFolder(name: name, parent: parent, account: account) }
        func renameFolder(_ ref: String, name: String) throws -> WriteResult { try notes.renameFolder(ref, name: name) }
        func deleteFolder(_ ref: String) throws -> WriteResult { try notes.deleteFolder(ref) }
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-file-sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPullStoresSidecarAndMergesNonOverlappingChanges() throws {
        let notes = InMemoryNotes.sample(), root = try root(), path = root.appendingPathComponent("note.md")
        let sync = SingleFileSync(reader: notes, writer: notes)
        XCTAssertEqual(try sync.pull(note: "welcome", to: path).action, .pull)
        XCTAssertTrue(try String(contentsOf: path).contains("notes-id: \"welcome\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".notescli/note.md.json").path))
        var local = MarkdownFile.parse(try String(contentsOf: path), fallbackTitle: "note")
        local.body = "LOCAL\n" + local.body; try local.rendered().write(to: path, atomically: true, encoding: .utf8)
        _ = try notes.replaceBody("welcome", markdown: (try notes.note("welcome").document?.text ?? "") + "\nREMOTE")
        XCTAssertEqual(try sync.pull(note: "welcome", to: path).conflicts, 0)
        let merged = try String(contentsOf: path)
        XCTAssertTrue(merged.contains("LOCAL")); XCTAssertTrue(merged.contains("REMOTE"))
    }

    func testPushWritesConflictMarkersAndDryRunDoesNotWriteNotes() throws {
        let notes = InMemoryNotes.sample(), root = try root(), path = root.appendingPathComponent("note.md")
        let sync = SingleFileSync(reader: notes, writer: notes)
        _ = try sync.pull(note: "welcome", to: path)
        var local = MarkdownFile.parse(try String(contentsOf: path), fallbackTitle: "note")
        local.body = "LOCAL"; try local.rendered().write(to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(try sync.push(from: path, dryRun: true).action, .push)
        XCTAssertNotEqual(try notes.note("welcome").document?.text, "LOCAL")
        _ = try notes.replaceBody("welcome", markdown: "REMOTE")
        let report = try sync.push(from: path)
        XCTAssertEqual(report.action, .conflict); XCTAssertEqual(report.conflicts, 1)
        XCTAssertTrue(try String(contentsOf: path).contains("<<<<<<< LOCAL"))
        XCTAssertEqual(try notes.note("welcome").document?.text, "REMOTE")
        XCTAssertEqual(try sync.push(from: path).action, .conflict)
        XCTAssertEqual(try notes.note("welcome").document?.text, "REMOTE")
        local = MarkdownFile.parse(try String(contentsOf: path), fallbackTitle: "note")
        local.body = "RESOLVED"; try local.rendered().write(to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(try sync.push(from: path).action, .push)
        XCTAssertEqual(try notes.note("welcome").document?.text, "RESOLVED")
    }

    func testPushRefusesAttachmentLoss() throws {
        let sample = InMemoryNotes.sample(), root = try root(), path = root.appendingPathComponent("note.md")
        var note = try sample.note("welcome")
        note.attachments = [Attachment(id: "asset", typeUTI: "public.png")]; note.summary.attachmentCount = 1
        let notes = InMemoryNotes(accounts: try sample.accounts(), folders: try sample.folders(account: nil), notes: [note])
        let sync = SingleFileSync(reader: notes, writer: notes)
        _ = try sync.pull(note: "welcome", to: path)
        var local = MarkdownFile.parse(try String(contentsOf: path), fallbackTitle: "note")
        local.body += "changed"; try local.rendered().write(to: path, atomically: true, encoding: .utf8)
        let report = try sync.push(from: path)
        XCTAssertEqual(report.action, .refused); XCTAssertTrue(report.refusedAttachments)
    }

    func testUnknownPushIsPersistedAndNotRetried() throws {
        let notes = InMemoryNotes.sample(), root = try root(), path = root.appendingPathComponent("note.md")
        _ = try SingleFileSync(reader: notes, writer: notes).pull(note: "welcome", to: path)
        var local = MarkdownFile.parse(try String(contentsOf: path), fallbackTitle: "note")
        local.body = "changed"; try local.rendered().write(to: path, atomically: true, encoding: .utf8)
        let writer = UnknownWriter(notes), sync = SingleFileSync(reader: notes, writer: writer)
        XCTAssertThrowsError(try sync.push(from: path)) { error in
            guard case NotesSyncError.writeUnknown = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try sync.push(from: path).action, .unchanged)
        XCTAssertEqual(writer.replacements, 1)
    }

    func testPullConflictCannotPushMarkersIntoNotes() throws {
        let notes = InMemoryNotes.sample(), root = try root(), path = root.appendingPathComponent("note.md")
        let sync = SingleFileSync(reader: notes, writer: notes)
        _ = try sync.pull(note: "welcome", to: path)
        var local = MarkdownFile.parse(try String(contentsOf: path), fallbackTitle: "note")
        local.body = "LOCAL"; try local.rendered().write(to: path, atomically: true, encoding: .utf8)
        _ = try notes.replaceBody("welcome", markdown: "REMOTE")

        XCTAssertEqual(try sync.pull(note: "welcome", to: path).action, .conflict)
        let state = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".notescli/note.md.json"))) as? [String: Any])
        XCTAssertEqual(state["conflicted"] as? Bool, true)
        XCTAssertEqual(try sync.push(from: path).action, .conflict)
        XCTAssertEqual(try notes.note("welcome").document?.text, "REMOTE")
    }

    func testPushRejectsConflictMarkersWithoutSidecarState() throws {
        let notes = InMemoryNotes.sample(), root = try root(), path = root.appendingPathComponent("note.md")
        let body = "<<<<<<< OURS\nlocal\n=======\nremote\n>>>>>>> THEIRS"
        let file = MarkdownFile(noteID: "welcome", title: "Welcome", modified: nil, body: body)
        try file.rendered().write(to: path, atomically: true, encoding: .utf8)

        XCTAssertEqual(try SingleFileSync(reader: notes, writer: notes).push(from: path).action, .conflict)
        XCTAssertEqual(try notes.note("welcome").document?.text, "Welcome to notescli. Browse your shopping notes. #demo")
    }

    func testConfirmedUnknownMergeUpdatesLocalFileWithoutRetrying() throws {
        let notes = InMemoryNotes.sample(), root = try root(), path = root.appendingPathComponent("note.md")
        _ = try SingleFileSync(reader: notes, writer: notes).pull(note: "welcome", to: path)
        var local = MarkdownFile.parse(try String(contentsOf: path), fallbackTitle: "note")
        local.body = "LOCAL\n" + local.body; try local.rendered().write(to: path, atomically: true, encoding: .utf8)
        _ = try notes.replaceBody("welcome", markdown: (try notes.note("welcome").document?.text ?? "") + "\nREMOTE")
        let writer = UnknownWriter(notes), sync = SingleFileSync(reader: notes, writer: writer)

        XCTAssertThrowsError(try sync.push(from: path))
        XCTAssertEqual(try sync.push(from: path).action, .unchanged)
        XCTAssertEqual(MarkdownFile.parse(try String(contentsOf: path), fallbackTitle: "note").body,
                       "LOCAL\nWelcome to notescli. Browse your shopping notes. #demo\nREMOTE")
        XCTAssertEqual(writer.replacements, 1)
    }

    func testPushRejectsSymlinkedSidecarDirectory() throws {
        let notes = InMemoryNotes.sample(), root = try root(), path = root.appendingPathComponent("note.md")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-sidecar-outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let file = MarkdownFile(noteID: "welcome", title: "Welcome", modified: nil, body: "changed")
        try file.rendered().write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".notescli"),
                                                   withDestinationURL: outside.appendingPathComponent("missing"))

        XCTAssertThrowsError(try SingleFileSync(reader: notes, writer: notes).push(from: path)) {
            XCTAssertEqual($0 as? NotesSyncError, .invalidPath(".notescli/note.md.json"))
        }
    }
}
