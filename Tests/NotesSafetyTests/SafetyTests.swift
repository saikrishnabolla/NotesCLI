import Foundation
import XCTest
import NotesCore
@testable import NotesSafety

final class SafetyTests: XCTestCase {
    func testJournalResolutionIdentityDoesNotInferFromNamesOrTitles() throws {
        let titleOnly = JournalEntry(id: "one", operation: "createNote", argumentsHash: "", arguments: Data(#"{"title":"Unique"}"#.utf8),
                                     idempotencyKey: nil, started: Date(), outcome: .unknown, noteID: nil, result: nil, message: nil)
        XCTAssertNil(titleOnly.stableDispatchIdentity)
        let stable = JournalEntry(id: "two", operation: "renameNote", argumentsHash: "", arguments: Data(#"{"ref":"Old title","stable_id":"uuid-1"}"#.utf8),
                                  idempotencyKey: nil, started: Date(), outcome: .unknown, noteID: nil, result: nil, message: nil)
        XCTAssertEqual(stable.stableDispatchIdentity, "uuid-1")
    }
    func testAllowlistMatchesOnlyConfiguredTrees() throws {
        let guardrail = WriteAllowlist("Work, Inbox > Agents")
        XCTAssertTrue(guardrail.allows(["Work"]))
        XCTAssertTrue(guardrail.allows(["Work", "Archive"]))
        XCTAssertTrue(guardrail.allows(["Inbox", "Agents", "Runs"]))
        XCTAssertFalse(guardrail.allows(["Inbox"]))
        XCTAssertFalse(guardrail.allows(["Personal"]))
        XCTAssertThrowsError(try guardrail.require(["Personal"])) { error in
            XCTAssertEqual((error as? NotesError)?.code, "write_not_allowed")
        }
        XCTAssertTrue(WriteAllowlist(nil).allows(["Anywhere"]))
    }

    func testJournalReplaysAKeyAndRejectsDifferentArguments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try WriteJournal(url: directory.appendingPathComponent("journal.sqlite"))
        let first = try journal.begin(operation: "rename", arguments: Data(#"{"ref":"one","title":"new"}"#.utf8), idempotencyKey: "key")
        XCTAssertFalse(first.replayed)
        try journal.finish(first.entry.id, outcome: .verified, noteID: "note-1", result: WriteResult(outcome: .verified, noteID: NoteID(uuid: "note-1")))
        let replay = try journal.begin(operation: "rename", arguments: Data(#"{"ref":"one","title":"new"}"#.utf8), idempotencyKey: "key")
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.entry.outcome, .verified)
        XCTAssertEqual(replay.entry.result?.noteID?.uuid, "note-1")
        XCTAssertThrowsError(try journal.begin(operation: "rename", arguments: Data(#"{"ref":"one","title":"other"}"#.utf8), idempotencyKey: "key")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "idempotency_conflict")
        }
        XCTAssertEqual(try journal.list().count, 1)
    }

    func testJournalSettingPreimagesProduceLiteralRestoreActions() throws {
        func entry(_ operation: String, _ json: String) -> JournalEntry {
            JournalEntry(id: "operation-1", operation: operation, argumentsHash: "", arguments: Data(json.utf8),
                         idempotencyKey: nil, started: Date(timeIntervalSince1970: 0), outcome: .verified,
                         noteID: nil, result: nil, message: nil)
        }
        XCTAssertEqual(try entry("checklistAutoSort", #"{"previous_enabled":"true"}"#).restoreAction(), .checklistAutoSort(enabled: true))
        XCTAssertEqual(try entry("folderSort", #"{"stable_id":"folder-1","previous_by":"created","previous_direction":"oldest"}"#).restoreAction(),
                       .folderSort(folderID: "folder-1", order: "created", direction: "oldest"))
        XCTAssertEqual(try entry("setDefaultAccount", #"{"previous_account_id":"account-1"}"#).restoreAction(), .defaultAccount(identifier: "account-1"))
        XCTAssertEqual(try entry("smartFolderEditRules", #"{"stable_id":"smart-1","previous_query_json":"{\"tag\":\"work\"}"}"#).restoreAction(),
                       .smartFolderQuery(folderID: "smart-1", queryJSON: #"{"tag":"work"}"#))
        XCTAssertNil(try entry("renameNote", #"{"stable_id":"note-1"}"#).restoreAction())
    }

    func testSnapshotWritesFullJSONAndMarkdownAndLoadsLatest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(rootURL: directory)
        let note = try InMemoryNotes.sample().note("welcome")
        let saved = try store.save(note)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.directory.appendingPathComponent("note.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.directory.appendingPathComponent("note.md").path))
        XCTAssertEqual(try store.load(note.summary.id.uuid, snapshot: saved.id).note.summary.title, note.summary.title)
        XCTAssertEqual(try store.load(note.summary.id.uuid).markdown, note.document?.markdown())
        XCTAssertEqual(try store.history(note.summary.id.uuid).map(\.id), [saved.id])
        XCTAssertThrowsError(try store.load(note.summary.id.uuid, snapshot: "../../outside")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "snapshot_not_found")
        }
    }

    func testConcurrencyRejectsStaleDateAndRevision() throws {
        let note = try InMemoryNotes.sample().note("welcome")
        let modified = try XCTUnwrap(note.summary.modified)
        let iso = ISO8601DateFormatter().string(from: modified)
        XCTAssertNoThrow(try ConcurrencyGuard.require(note, ifModified: iso, expectRevision: nil))
        var subsecondNote = note
        subsecondNote.summary.modified = modified.addingTimeInterval(0.75)
        XCTAssertThrowsError(try ConcurrencyGuard.require(subsecondNote, ifModified: iso, expectRevision: nil)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "stale_note")
        }
        XCTAssertNoThrow(try ConcurrencyGuard.require(note, ifModified: nil, expectRevision: ConcurrencyGuard.revision(note)))
        XCTAssertThrowsError(try ConcurrencyGuard.require(note, ifModified: "2020-01-01T00:00:00Z", expectRevision: nil)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "stale_note")
        }
        XCTAssertThrowsError(try ConcurrencyGuard.require(note, ifModified: nil, expectRevision: "old")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "stale_note")
        }
    }

    func testSnapshotsWithAttachmentsRetainTheRichNoteForNativeRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(rootURL: directory)
        var note = try InMemoryNotes.sample().note("welcome")
        note.attachments = [Attachment(id: "attachment", typeUTI: "public.png")]
        note.summary.attachmentCount = 1
        let saved = try store.save(note)
        XCTAssertTrue(saved.restorable)
        XCTAssertTrue(try XCTUnwrap(store.history(note.summary.id.uuid).first).restorable)
        XCTAssertEqual(try store.loadRestorable(note.summary.id.uuid, snapshot: saved.id).note.attachments, note.attachments)
    }

    func testSnapshotRestorePolicyListsNativeOnlyFeatures() throws {
        var note = try InMemoryNotes.sample().note("welcome")
        var paragraph = ParagraphStyle(kind: .dashed, indent: 2, startNumber: 7)
        paragraph.alignment = 2
        paragraph.writingDirection = 1
        paragraph.blockQuoteLevel = 3
        paragraph.collapsed = true
        var font = FontStyle(bold: true, superscript: -1)
        font.name = "Avenir Next"
        font.pointSize = 17
        note.document = NoteDocument(text: "item\u{fffc}", runs: [
            AttributeRun(length: 4, paragraph: paragraph, font: font, link: "https://example.com",
                         color: "#123456", highlight: .purple),
            AttributeRun(length: 1, attachment: InlineRef(id: "table-1", typeUTI: "com.apple.notes.table")),
        ])
        note.document?.tables = ["table-1": [["cell"]]]
        note.attachments = [Attachment(id: "table-1", typeUTI: "com.apple.notes.table")]

        XCTAssertEqual(SnapshotRestorePolicy.nativeRequiredFeatures(note), [
            "alignment", "block quote levels", "collapsible headings", "dashed lists", "font family", "font size",
            "highlights", "indentation", "links", "numbered list starts", "subscript", "tables", "text color",
            "writing direction",
        ])
    }

    func testSnapshotRestorePolicyRefusesScriptingUnlessDowngradeIsAllowed() throws {
        var note = try InMemoryNotes.sample().note("welcome")
        note.document = NoteDocument(text: "task", runs: [
            AttributeRun(length: 4, paragraph: ParagraphStyle(kind: .checklist, checked: false)),
        ])

        XCTAssertThrowsError(try SnapshotRestorePolicy.requireScriptingRestoreAllowed(note, allowDowngrade: false)) { error in
            let notesError = error as? NotesError
            XCTAssertEqual(notesError?.code, "native_required")
            XCTAssertEqual(notesError?.message, "This snapshot contains native-only features: checklists.")
        }
        XCTAssertNoThrow(try SnapshotRestorePolicy.requireScriptingRestoreAllowed(note, allowDowngrade: true))
    }

    func testScriptingRewriteGuardCoversEveryBodyRewrite() throws {
        let sample = InMemoryNotes.sample()
        var note = try sample.note("welcome")
        note.document = NoteDocument(text: "task", runs: [
            AttributeRun(length: 4, paragraph: ParagraphStyle(kind: .checklist, checked: false), highlight: .mint),
        ])
        let reader = InMemoryNotes(accounts: try sample.accounts(), folders: try sample.folders(account: nil), notes: [note])
        let writer = ScriptingRewriteGuard(writer: reader, reader: reader, allowDowngrade: false)
        let writes: [() throws -> WriteResult] = [
            { try writer.appendToNote("welcome", markdown: "x") },
            { try writer.prependToNote("welcome", markdown: "x", allowAttachmentLoss: false) },
            { try writer.replaceBody("welcome", markdown: "x") },
            { try writer.replaceBody("welcome", markdown: "x", allowAttachmentLoss: false) },
            { try writer.insertUnderHeading("welcome", heading: "H", markdown: "x", allowAttachmentLoss: false) },
            { try writer.replaceSection("welcome", heading: "H", markdown: "x", allowAttachmentLoss: false) },
            { try writer.replaceText("welcome", find: "task", replacement: "x", allowAttachmentLoss: false) },
        ]
        for write in writes {
            XCTAssertThrowsError(try write()) { XCTAssertEqual(($0 as? NotesError)?.code, "native_required") }
        }
        let allowed = ScriptingRewriteGuard(writer: reader, reader: reader, allowDowngrade: true)
        XCTAssertEqual(try allowed.appendToNote("welcome", markdown: "x").outcome, .verified)
    }

    func testParityDocsStateTheNativeRestoreGuardAndJournalPreimages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let features = try String(contentsOf: root.appendingPathComponent("docs/APPLE-NOTES-FEATURES.md"), encoding: .utf8)
        let parity = try String(contentsOf: root.appendingPathComponent("docs/PARITY.md"), encoding: .utf8)
        let commands = try String(contentsOf: root.appendingPathComponent("docs/commands.md"), encoding: .utf8)
        XCTAssertTrue(features.contains("| Version history, diff, undo, and revert | Partial | Partial |"))
        XCTAssertTrue(features.contains("Native-only snapshots return `native_required` on the scripting engine."))
        XCTAssertTrue(parity.contains("| Version history / diff / revert |"))
        XCTAssertTrue(parity.contains("| Partial — lossless native snapshot restore"))
        XCTAssertTrue(commands.contains("`undo` and `revert` accept a note reference for snapshots or a journal operation ID for a recorded setting or Smart Folder rule preimage."))
        XCTAssertTrue(commands.contains("`--allow-downgrade`"))
    }

    func testDocumentedMatrixCountsMatchTheRows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let features = try String(contentsOf: root.appendingPathComponent("docs/APPLE-NOTES-FEATURES.md"), encoding: .utf8)
        let featureRows = features.split(separator: "\n").filter {
            $0.hasPrefix("|") && !$0.hasPrefix("| ---") && !$0.hasPrefix("| Feature")
        }.map { $0.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
        XCTAssertEqual(featureRows.count, 95)
        XCTAssertEqual(featureRows.map { $0[2] }.filter { $0 == "Done" }.count, 86)
        XCTAssertEqual(featureRows.map { $0[2] }.filter { $0 == "Partial" }.count, 5)
        XCTAssertEqual(featureRows.map { $0[2] }.filter { $0 == "Not possible" }.count, 4)
        XCTAssertEqual(featureRows.map { $0[3] }.filter { $0 == "Done" }.count, 64)
        XCTAssertEqual(featureRows.map { $0[3] }.filter { $0 == "Partial" }.count, 8)
        XCTAssertEqual(featureRows.map { $0[3] }.filter { $0 == "Not possible" }.count, 23)

        let parity = try String(contentsOf: root.appendingPathComponent("docs/PARITY.md"), encoding: .utf8)
        let matrix = parity.components(separatedBy: "## 2. CLI commands")[0]
        let statuses = matrix.split(separator: "\n").filter {
            $0.hasPrefix("|") && !$0.hasPrefix("| ---") && !$0.hasPrefix("| Capability")
        }.compactMap { line in
            line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }[safe: 6]
        }
        XCTAssertEqual(statuses.count, 139)
        XCTAssertEqual(statuses.filter { $0.hasPrefix("Done") }.count, 127)
        XCTAssertEqual(statuses.filter { $0.hasPrefix("Partial") }.count, 2)
        XCTAssertEqual(statuses.filter { $0.hasPrefix("Not possible") || $0.hasPrefix("Not planned") }.count, 10)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
