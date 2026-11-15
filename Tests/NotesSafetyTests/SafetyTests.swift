import Foundation
import XCTest
import NotesCore
@testable import NotesSafety

final class SafetyTests: XCTestCase {
    func testSnapshotRestoreDoesNotMoveAnActiveNoteBackIntoRecentlyDeleted() {
        XCTAssertNil(SnapshotRestorePolicy.destinationFolderPath(
            current: ["notescli-test"],
            snapshot: ["Recently Deleted"],
            snapshotIsDeleted: true
        ))
        XCTAssertNil(SnapshotRestorePolicy.destinationFolderPath(
            current: ["Notes"],
            snapshot: ["Notes"],
            snapshotIsDeleted: false
        ))
        XCTAssertEqual(SnapshotRestorePolicy.destinationFolderPath(
            current: ["Notes"],
            snapshot: ["Archive"],
            snapshotIsDeleted: false
        ), ["Archive"])
    }

    func testNotesPreferenceJournalRecordsThePreimageAndRefusesMissingState() throws {
        func entry(_ operation: String, _ json: String) -> JournalEntry {
            JournalEntry(id: "pref", operation: operation, argumentsHash: "", arguments: Data(json.utf8),
                         idempotencyKey: nil, started: Date(), outcome: .verified, noteID: nil, result: nil, message: nil)
        }
        let cli = entry("notesPreference", #"{"setting":"show-note-count","state":"off","previous_state":"default","engine":"native"}"#)
        XCTAssertEqual(try cli.restoreAction(), .notesPreference(setting: "show-note-count", state: "default"))
        XCTAssertEqual(try cli.restoreExpectation(), .notesPreference("off"))
        let mcp = entry("set_query_date_grouping", #"{"enabled":true,"setting":"query-date-grouping","state":"on","previous_state":"off"}"#)
        XCTAssertEqual(try mcp.restoreAction(), .notesPreference(setting: "query-date-grouping", state: "off"))
        XCTAssertEqual(try mcp.restoreExpectation(), .notesPreference("on"))
        XCTAssertThrowsError(try entry("notesPreference", #"{"setting":"show-note-count","state":"on"}"#).restoreAction()) {
            XCTAssertEqual(($0 as? NotesError)?.code, "journal_preimage_missing")
        }
    }

    func testJournalResolutionIdentityDoesNotInferFromNamesOrTitles() throws {
        let titleOnly = JournalEntry(id: "one", operation: "createNote", argumentsHash: "", arguments: Data(#"{"title":"Unique"}"#.utf8),
                                     idempotencyKey: nil, started: Date(), outcome: .unknown, noteID: nil, result: nil, message: nil)
        XCTAssertNil(titleOnly.stableDispatchIdentity)
        let stable = JournalEntry(id: "two", operation: "renameNote", argumentsHash: "", arguments: Data(#"{"ref":"Old title","stable_id":"uuid-1"}"#.utf8),
                                  idempotencyKey: nil, started: Date(), outcome: .unknown, noteID: nil, result: nil, message: nil)
        XCTAssertEqual(stable.stableDispatchIdentity, "uuid-1")
    }

    func testJournalBindsGenericUndoToOneSnapshotAndPostWriteRevision() {
        let entry = JournalEntry(
            id: "one", operation: "updateNote", argumentsHash: "",
            arguments: Data(#"{"stable_id":"note-1","snapshot_id":"20261113T010203.000Z","post_revision":"abc123"}"#.utf8),
            idempotencyKey: nil, started: Date(), outcome: .verified, noteID: "note-1", result: nil, message: nil)
        XCTAssertEqual(entry.snapshotID, "20261113T010203.000Z")
        XCTAssertEqual(entry.postRevision, "abc123")

        let legacy = JournalEntry(id: "two", operation: "updateNote", argumentsHash: "", arguments: Data(#"{"stable_id":"note-1"}"#.utf8),
                                  idempotencyKey: nil, started: Date(), outcome: .verified, noteID: "note-1", result: nil, message: nil)
        XCTAssertNil(legacy.snapshotID)
        XCTAssertNil(legacy.postRevision)
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

    func testMalformedAllowlistFailsClosed() {
        for value in ["Notes >", "> Notes", "Notes >> Private", "Notes,,Private"] {
            let guardrail = WriteAllowlist(value)
            XCTAssertTrue(guardrail.isRestricted, value)
            XCTAssertFalse(guardrail.allows(["Notes"]), value)
            XCTAssertFalse(guardrail.allows(["Notes", "Private"]), value)
            XCTAssertFalse(guardrail.allows(["Private"]), value)
        }
        XCTAssertFalse(WriteAllowlist("   ").isRestricted)
        XCTAssertTrue(WriteAllowlist("   ").allows(["Anywhere"]))
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
        XCTAssertEqual(try entry("folderDateGrouping", #"{"stable_id":"folder-1","previous_type":"0"}"#).restoreAction(),
                       .folderDateGrouping(folderID: "folder-1", type: 0))
        XCTAssertEqual(try entry("set_folder_date_grouping", #"{"stable_id":"folder-1","previous_enabled":"false"}"#).restoreAction(),
                       .folderDateGrouping(folderID: "folder-1", type: 1))
        XCTAssertEqual(try entry("defaultParagraphStyle", #"{"previous_style":"body"}"#).restoreAction(),
                       .defaultParagraphStyle(style: "body"))
        XCTAssertEqual(try entry("globalNoteSort", #"{"previous_sort":"created"}"#).restoreAction(),
                       .globalNoteSort(sort: "created"))
        XCTAssertEqual(try entry("set_global_note_sort", #"{"previous_sort":"title"}"#).restoreAction(),
                       .globalNoteSort(sort: "title"))
        XCTAssertEqual(try entry("globalDateGrouping", #"{"previous_enabled":"false"}"#).restoreAction(),
                       .globalDateGrouping(enabled: false))
        XCTAssertEqual(try entry("set_global_date_grouping", #"{"previous_enabled":true}"#).restoreAction(),
                       .globalDateGrouping(enabled: true))
        XCTAssertEqual(try entry("defaultTextSize", #"{"previous_points":"18"}"#).restoreAction(),
                       .defaultTextSize(points: 18))
        XCTAssertEqual(try entry("set_default_text_size", #"{"previous_points":24}"#).restoreAction(),
                       .defaultTextSize(points: 24))
        XCTAssertEqual(try entry("resumeLastQuickNote", #"{"previous_enabled":"true"}"#).restoreAction(),
                       .resumeLastQuickNote(enabled: true))
        XCTAssertEqual(try entry("set_resume_last_quick_note", #"{"previous_enabled":false}"#).restoreAction(),
                       .resumeLastQuickNote(enabled: false))
        XCTAssertEqual(try entry("autoConvertToTags", #"{"previous_enabled":"false"}"#).restoreAction(),
                       .autoConvertToTags(enabled: false))
        XCTAssertEqual(try entry("set_auto_convert_tags", #"{"previous_enabled":true}"#).restoreAction(),
                       .autoConvertToTags(enabled: true))
        XCTAssertEqual(try entry("setQuickNote", #"{"ref":"note-1","previous_enabled":"false"}"#).restoreAction(),
                       .quickNote(noteID: "note-1", enabled: false))
        XCTAssertEqual(try entry("set_quick_note", #"{"ref":"note-2","previous_enabled":true}"#).restoreAction(),
                       .quickNote(noteID: "note-2", enabled: true))
        XCTAssertEqual(try entry("setDefaultAccount", #"{"previous_account_id":"account-1"}"#).restoreAction(), .defaultAccount(identifier: "account-1"))
        XCTAssertEqual(try entry("smartFolderEditRules", #"{"stable_id":"smart-1","previous_query_json":"{\"tag\":\"work\"}"}"#).restoreAction(),
                       .smartFolderQuery(folderID: "smart-1", queryJSON: #"{"tag":"work"}"#))
        XCTAssertEqual(try entry("scanFilter", #"{"stable_id":"note-1","attachment_id":"gallery-1","page_id":"page-1","previous_filter":"photo"}"#).restoreAction(),
                       .scanFilter(noteID: "note-1", attachmentID: "gallery-1", pageID: "page-1", filter: "photo", expectedCurrent: nil))
        XCTAssertEqual(try entry("scan_rotate", #"{"stable_id":"note-1","attachment_id":"gallery-1","page_id":"page-1","previous_orientation":"right"}"#).restoreAction(),
                       .scanOrientation(noteID: "note-1", attachmentID: "gallery-1", pageID: "page-1", orientation: "right", expectedCurrent: nil))
        XCTAssertEqual(try entry("scanMove", #"{"stable_id":"note-1","attachment_id":"gallery-1","page_id":"page-1","previous_index":"2"}"#).restoreAction(),
                       .scanMove(noteID: "note-1", attachmentID: "gallery-1", pageID: "page-1", index: 2, expectedPageIDs: nil))
        XCTAssertEqual(try entry("scanDelete", #"{"stable_id":"note-1","attachment_id":"gallery-1","page_id":"page-1","previous_index":"1","applied_page_order":["page-2"]}"#).restoreAction(),
                       .scanUndelete(noteID: "note-1", attachmentID: "gallery-1", pageID: "page-1", index: 1,
                                     expectedPageIDs: ["page-2"]))
        XCTAssertEqual(try entry("scanAppend", #"{"stable_id":"note-1","attachment_id":"gallery-1","created_page_ids":["page-3"],"applied_page_order":["page-1","page-2","page-3"]}"#).restoreAction(),
                       .scanDeletePages(noteID: "note-1", attachmentID: "gallery-1", pageIDs: ["page-3"],
                                        expectedPageIDs: ["page-1", "page-2", "page-3"]))
        let identityCrop = ScanCrop(bottomLeft: ScanPoint(x: 0, y: 1), bottomRight: ScanPoint(x: 1, y: 1),
                                    topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1, y: 0))
        let insetCrop = ScanCrop(bottomLeft: ScanPoint(x: 0.1, y: 0.9), bottomRight: ScanPoint(x: 0.9, y: 0.9),
                                 topLeft: ScanPoint(x: 0.1, y: 0.1), topRight: ScanPoint(x: 0.9, y: 0.1))
        XCTAssertEqual(try entry("scanCrop", #"{"stable_id":"note-1","attachment_id":"gallery-1","page_id":"page-1","previous_crop":"0.0,1.0;1.0,1.0;0.0,0.0;1.0,0.0","crop":"0.1,0.9;0.9,0.9;0.1,0.1;0.9,0.1"}"#).restoreAction(),
                       .scanCrop(noteID: "note-1", attachmentID: "gallery-1", pageID: "page-1",
                                 crop: identityCrop, expectedCurrent: insetCrop))
        XCTAssertNil(try entry("renameNote", #"{"stable_id":"note-1"}"#).restoreAction())

        XCTAssertThrowsError(try entry("setQuickNote", #"{"ref":"note-1"}"#).restoreAction()) { error in
            XCTAssertEqual((error as? NotesError)?.code, "journal_preimage_missing")
        }
        XCTAssertThrowsError(try entry("scan_move", #"{"stable_id":"note-1","attachment_id":"gallery-1","page_id":"page-1"}"#).restoreAction()) { error in
            XCTAssertEqual((error as? NotesError)?.code, "journal_preimage_missing")
        }
    }

    func testJournalSettingUndoRequiresAndDecodesExactPostimages() throws {
        func expectation(_ operation: String, _ json: String) throws -> JournalRestoreExpectation? {
            let entry = JournalEntry(id: "operation-1", operation: operation, argumentsHash: "",
                                     arguments: Data(json.utf8), idempotencyKey: nil,
                                     started: Date(timeIntervalSince1970: 0), outcome: .verified,
                                     noteID: nil, result: nil, message: nil)
            return try entry.restoreExpectation()
        }

        XCTAssertEqual(try expectation("checklistAutoSort", #"{"enabled":true}"#), .checklistAutoSort(true))
        XCTAssertEqual(try expectation("folderSort", #"{"by":"title","direction":"ascending"}"#),
                       .folderSort(order: "title", direction: "ascending"))
        XCTAssertEqual(try expectation("folderDateGrouping", #"{"enabled":false}"#), .folderDateGrouping(type: 1))
        XCTAssertEqual(try expectation("defaultParagraphStyle", #"{"style":"heading"}"#), .defaultParagraphStyle("heading"))
        XCTAssertEqual(try expectation("globalNoteSort", #"{"sort":"created"}"#), .globalNoteSort("created"))
        XCTAssertEqual(try expectation("globalDateGrouping", #"{"enabled":"true"}"#), .globalDateGrouping(true))
        XCTAssertEqual(try expectation("defaultTextSize", #"{"points":"18"}"#), .defaultTextSize(18))
        XCTAssertEqual(try expectation("resumeLastQuickNote", #"{"enabled":false}"#), .resumeLastQuickNote(false))
        XCTAssertEqual(try expectation("autoConvertToTags", #"{"enabled":true}"#), .autoConvertToTags(true))
        XCTAssertEqual(try expectation("setQuickNote", #"{"enabled":true}"#), .quickNote(true))
        XCTAssertEqual(try expectation("setDefaultAccount", #"{"account_id":"account-2"}"#), .defaultAccount("account-2"))
        XCTAssertEqual(try expectation("smartFolderEditRules", #"{"query_json":"{\"tag\":\"new\"}"}"#),
                       .smartFolderQuery(#"{"tag":"new"}"#))
        XCTAssertNil(try expectation("scanFilter", #"{"filter":"color"}"#))

        XCTAssertThrowsError(try expectation("globalNoteSort", #"{"previous_sort":"modified"}"#)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "journal_postimage_missing")
        }
        XCTAssertThrowsError(try expectation("setQuickNote", #"{"previous_enabled":false}"#)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "journal_postimage_missing")
        }
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

        var enriched = note
        enriched.attachments = [Attachment(id: "link", typeUTI: "public.url", synapseDataBytes: 321,
                                           linkPreviewMetadataBytes: 654,
                                           childAttachments: [Attachment(id: "child", typeUTI: "public.url",
                                                                          synapseDataBytes: 7,
                                                                          linkPreviewMetadataBytes: 8)])]
        var changedCounts = enriched
        changedCounts.attachments[0].synapseDataBytes = 999
        changedCounts.attachments[0].linkPreviewMetadataBytes = 1
        changedCounts.attachments[0].childAttachments?[0].synapseDataBytes = 42
        XCTAssertEqual(ConcurrencyGuard.revision(enriched), ConcurrencyGuard.revision(changedCounts))

        let legacy = try JSONDecoder().decode(Attachment.self, from: Data(#"{"id":"legacy","typeUTI":"public.url"}"#.utf8))
        XCTAssertNil(legacy.synapseDataBytes)
        XCTAssertNil(legacy.linkPreviewMetadataBytes)
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

    func testNativeOnlyFeaturesIgnoreDefaultNotesTitleMetadata() throws {
        var note = try InMemoryNotes.sample().note("welcome")
        var paragraph = ParagraphStyle(kind: .title)
        paragraph.writingDirection = 0
        var font = FontStyle(bold: true)
        font.name = ".AppleSystemUIFontBold"
        font.pointSize = 24
        note.summary.title = "Title"
        note.document = NoteDocument(text: "Title\n", runs: [
            AttributeRun(length: 6, paragraph: paragraph, font: font),
        ])
        note.attachments = []

        XCTAssertEqual(NativeOnlyFeatures.detect(in: note), [])

        note.document?.runs[0].font.name = nil
        XCTAssertEqual(NativeOnlyFeatures.detect(in: note), [])

        note.document?.runs[0].font.pointSize = 13
        XCTAssertEqual(NativeOnlyFeatures.detect(in: note), ["font size"])

        note.document?.text = "Body\n"
        note.document?.runs[0].font.bold = false
        note.document?.runs[0].font.pointSize = 24
        XCTAssertEqual(NativeOnlyFeatures.detect(in: note), ["font size"])

        note.document?.text = "Title\n"
        note.document?.runs[0].font.bold = true
        note.document?.runs[0].paragraph?.writingDirection = 1
        note.document?.runs[0].font.name = "Avenir Next"
        note.document?.runs[0].font.pointSize = 22
        XCTAssertEqual(NativeOnlyFeatures.detect(in: note), ["font family", "font size", "writing direction"])
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

        let plain = InMemoryNotes.sample()
        let unavailable = ScriptingRewriteGuard(
            writer: plain, reader: plain, allowDowngrade: false, nativeUnavailable: true
        )
        for write in [
            { try unavailable.createNote(title: "Rich", markdown: "- [ ] task", folder: "Notes") },
            { try unavailable.replaceBody("welcome", markdown: "| A | B |\n|---|---|\n| 1 | 2 |") },
        ] {
            XCTAssertThrowsError(try write()) { XCTAssertEqual(($0 as? NotesError)?.code, "native_unavailable") }
        }
    }

    func testParityDocsStateTheNativeRestoreGuardAndJournalPreimages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let features = try String(contentsOf: root.appendingPathComponent("docs/APPLE-NOTES-FEATURES.md"), encoding: .utf8)
        let parity = try String(contentsOf: root.appendingPathComponent("docs/PARITY.md"), encoding: .utf8)
        let commands = try String(contentsOf: root.appendingPathComponent("docs/commands.md"), encoding: .utf8)
        XCTAssertTrue(features.contains("| Version history, diff, undo, and revert | Partial | Partial |"))
        XCTAssertTrue(features.contains("Apple exposes no complete Notes version-history API for earlier edits."))
        XCTAssertTrue(parity.contains("| Version history / diff / revert |"))
        XCTAssertTrue(parity.contains("| Partial — NotesCLI keeps exact pre-write snapshots for its own writes"))
        XCTAssertTrue(commands.contains("`undo` and `revert` accept a note reference for snapshots or a journal operation ID for a recorded setting or Smart Folder rule preimage."))
        XCTAssertTrue(commands.contains("`--allow-downgrade`"))
    }

    func testDocumentedMatrixCountsMatchTheRows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let features = try String(contentsOf: root.appendingPathComponent("docs/APPLE-NOTES-FEATURES.md"), encoding: .utf8)
        let featureRows = features.split(separator: "\n").filter {
            $0.hasPrefix("|") && !$0.hasPrefix("| ---") && !$0.hasPrefix("| Feature")
        }.map { $0.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
        XCTAssertEqual(featureRows.count, 96)
        XCTAssertEqual(featureRows.map { $0[2] }.filter { $0 == "Done" }.count, 87)
        XCTAssertEqual(featureRows.map { $0[2] }.filter { $0 == "Partial" }.count, 7)
        XCTAssertEqual(featureRows.map { $0[2] }.filter { $0 == "Not possible" }.count, 2)
        XCTAssertEqual(featureRows.map { $0[3] }.filter { $0 == "Done" }.count, 71)
        XCTAssertEqual(featureRows.map { $0[3] }.filter { $0 == "Partial" }.count, 13)
        XCTAssertEqual(featureRows.map { $0[3] }.filter { $0 == "Not possible" }.count, 12)

        let parity = try String(contentsOf: root.appendingPathComponent("docs/PARITY.md"), encoding: .utf8)
        let matrix = parity.components(separatedBy: "## 2. CLI commands")[0]
        let statuses = matrix.split(separator: "\n").filter {
            $0.hasPrefix("|") && !$0.hasPrefix("| ---") && !$0.hasPrefix("| Capability")
        }.compactMap { line in
            line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }[safe: 6]
        }
        XCTAssertEqual(statuses.count, 139)
        let doneCount = statuses.filter { $0.hasPrefix("Done") }.count
        let partialCount = statuses.filter { $0.hasPrefix("Partial") }.count
        let notPlannedCount = statuses.filter { $0.hasPrefix("Not planned") }.count
        XCTAssertEqual(doneCount, 127)
        XCTAssertEqual(partialCount, 4)
        XCTAssertEqual(notPlannedCount, 8)

        let summaryLines = parity.split(separator: "\n").filter { $0.hasPrefix("Status summary: ") }.map(String.init)
        XCTAssertEqual(summaryLines, ["Status summary: \(doneCount) Done, \(partialCount) Partial, and \(notPlannedCount) Not planned."])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
