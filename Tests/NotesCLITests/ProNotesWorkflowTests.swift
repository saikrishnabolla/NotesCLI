import AppKit
import Carbon
import Foundation
import NotesCore
import NotesMCP
import XCTest
@testable import notescli

@MainActor
private final class PickerScrollRows: NSObject, NSTableViewDataSource {
    let count: Int

    init(count: Int = 30) { self.count = count }

    func numberOfRows(in tableView: NSTableView) -> Int { count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "Note \(row)" }
}

final class ProNotesWorkflowTests: XCTestCase {
    func testFailedBodySearchCanRetryOnlyTheCurrentQuery() {
        let failure = PaletteBodySearchAttempt(query: "needle", matches: nil)
        XCTAssertTrue(failure.failed(for: EditorSearchQuery("needle")))
        XCTAssertFalse(failure.failed(for: EditorSearchQuery("different")))
        XCTAssertFalse(failure.failed(for: nil))
        let empty = PaletteBodySearchAttempt(query: "needle", matches: [])
        XCTAssertFalse(empty.failed(for: EditorSearchQuery("needle")))
    }

    @MainActor
    func testPickerRetryRecoversCatalogAndBodySearchWithoutLosingSelection() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("picker-fixture")
        try """
        #!/bin/sh
        cd -- "$(dirname -- "$0")" || exit 1
        case "$1" in
          list)
            if [ ! -e listed ]; then touch listed; exit 1; fi
            exec /bin/cat catalog
            ;;
          editor-body-search)
            shift
            while [ "$1" != "--" ]; do [ "$#" -gt 0 ] || exit 2; shift; done
            case "$2" in
              needle) [ -e needle ] || { touch needle; exit 1; }; printf '[{"id":"body","excerpt":"Look for the Néedle here."}]' ;;
              absent) [ -e absent ] || { touch absent; exit 1; }; printf '[]' ;;
              *) exit 2 ;;
            esac
            ;;
          *) exit 2 ;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        struct Catalog: Encodable { let notes: [NoteSummary] }
        let notes = [
            noteSummary("first", title: "Needle first", folder: []),
            noteSummary("second", title: "Needle second", folder: []),
            noteSummary("body", title: "Body match", folder: [])
        ]
        try JSONEncoder().encode(Catalog(notes: notes)).write(to: directory.appendingPathComponent("catalog"))

        let picker = PaletteWindow(client: PaletteClient(executable: executable, backend: "fixture"), selectedNote: nil)
        let root = try XCTUnwrap(picker.window.contentView)
        let buttons = try XCTUnwrap(root.subviews.compactMap { $0 as? NSStackView }.last)
        let retry = try XCTUnwrap(buttons.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == "Retry" })
        let create = try XCTUnwrap(buttons.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == "Create Note" })
        let field = try XCTUnwrap(root.subviews.compactMap { $0 as? NSSearchField }.first)
        let table = try XCTUnwrap(root.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }.first)
        let status = try XCTUnwrap(root.subviews.compactMap { $0 as? NSTextField }.first { $0 !== field })
        picker.window.orderBack(nil)
        defer { picker.window.orderOut(nil) }

        func waitUntil(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !predicate() && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            _ = try XCTUnwrap(predicate() ? true : nil, "Picker state did not update before the deadline.")
        }
        func search(_ text: String) {
            field.stringValue = text
            picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }

        picker.load()
        try await waitUntil { !retry.isHidden && retry.isEnabled }
        XCTAssertEqual(status.stringValue, "Couldn’t read notes.")
        retry.performClick(nil)
        try await waitUntil { table.numberOfRows == 3 }
        search("needle")
        try await waitUntil { !retry.isHidden && retry.isEnabled }
        XCTAssertEqual(status.stringValue, "Note text unavailable.")
        XCTAssertEqual(table.numberOfRows, 2)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        retry.performClick(nil)
        XCTAssertTrue(retry.isHidden)
        try await waitUntil { table.numberOfRows == 3 }
        let row = try XCTUnwrap(table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) as? NSTextField)
        XCTAssertEqual(row.stringValue, "Needle second")
        let match = try XCTUnwrap((0..<table.numberOfRows).lazy.compactMap {
            table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView
        }.first)
        let stack = try XCTUnwrap(match.subviews.first as? NSStackView)
        let excerpt = try XCTUnwrap(stack.arrangedSubviews.last as? NSTextField)
        XCTAssertEqual(excerpt.stringValue, "Look for the Néedle here.")
        let hit = (excerpt.stringValue as NSString).range(of: "Néedle").location
        XCTAssertEqual(excerpt.attributedStringValue.attribute(.font, at: hit, effectiveRange: nil) as? NSFont,
                       NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold))
        XCTAssertGreaterThan(table.rect(ofRow: table.row(for: match)).height, table.rect(ofRow: table.selectedRow).height)

        search("absent")
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertTrue(create.isHidden)
        try await waitUntil { !retry.isHidden && retry.isEnabled }
        XCTAssertTrue(create.isHidden)
        retry.performClick(nil)
        XCTAssertTrue(create.isHidden)
        try await waitUntil { !create.isHidden && create.isEnabled }
        XCTAssertTrue(retry.isHidden)
    }

    func testBodyExcerptClipsAroundTheMatchWithoutReturningUnrelatedText() throws {
        let note = noteSummary("body", title: "Body match", folder: ["Work"])
        let query = try XCTUnwrap(EditorSearchQuery("work café"))
        let text = "Body match\nprivate prefix " + String(repeating: "📚 ", count: 60)
            + "Visit the CAFÉ\nwith a friend " + String(repeating: "after ", count: 90) + "private suffix"
        let hit = try XCTUnwrap(query.match(note, body: { text }))
        let excerpt = try XCTUnwrap(hit.excerpt)
        XCTAssertTrue(excerpt.hasPrefix("…"))
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertTrue(excerpt.contains("with a friend"))
        XCTAssertFalse(excerpt.contains("private"))
        XCTAssertEqual(query.highlightRanges(in: excerpt).map { String(excerpt[$0]) }, ["CAFÉ"])
        XCTAssertNil(query.match(note, titleOnly: true, body: { XCTFail("Read body in title-only search"); return text }))
    }

    func testToolbarFontSizingUsesNativeLocalizedFontItems() throws {
        XCTAssertEqual(try EditorToolbarControl.parse("bigger,smaller"), [.format(.bigger), .format(.smaller)])
        XCTAssertEqual(NotesEditorAction.bigger.menuPath, ["Format", "Font", "Bigger"])
        XCTAssertEqual(NotesEditorAction.smaller.menuPath, ["Format", "Font", "Smaller"])
        XCTAssertGreaterThan(NotesMenuLocalization.system.paths(for: NotesEditorAction.bigger.menuPath).count, 1)
        XCTAssertGreaterThan(NotesMenuLocalization.system.paths(for: NotesEditorAction.smaller.menuPath).count, 1)
    }

    func testSlashRowHoverDoesNotReplaceKeyboardSelection() throws {
        try MainActor.assumeIsolated {
            let row = EditorSlashRow(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
            row.wantsLayer = true
            row.updateTrackingAreas()
            row.updateTrackingAreas()
            XCTAssertEqual(row.trackingAreas.filter { $0.owner === row }.count, 1)
            let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            row.mouseEntered(with: enter)
            XCTAssertNotNil(row.layer?.backgroundColor)
            XCTAssertFalse(row.keyboardSelected)
            row.mouseExited(with: exit)
            XCTAssertNil(row.layer?.backgroundColor)
            row.keyboardSelected = true
            let selectionFill = try XCTUnwrap(row.layer?.backgroundColor)
            row.mouseEntered(with: enter)
            XCTAssertEqual(row.layer?.backgroundColor, selectionFill)
            row.mouseExited(with: exit)
            XCTAssertEqual(row.layer?.backgroundColor, selectionFill)
        }
    }

    func testPickerCanMatchOnlyTitlesWithinTheSelectedFolderAndSortByDate() {
        var older = noteSummary("older", title: "Project plan", folder: ["Work", "Drafts"])
        older.created = Date(timeIntervalSince1970: 10)
        older.modified = Date(timeIntervalSince1970: 40)
        var newer = noteSummary("newer", title: "Project outline", folder: ["Work", "Drafts"])
        newer.created = Date(timeIntervalSince1970: 20)
        newer.modified = Date(timeIntervalSince1970: 30)
        var other = newer
        other.id = NoteID(uuid: "other")
        other.accountID = "different"
        let unknown = noteSummary("unknown", title: "Project idea", folder: ["Work", "Drafts"])
        let folderMatch = noteSummary("folder-only", title: "Work", folder: ["Project"])
        let rows = [folderMatch, unknown, other, newer, older]
        let folder = PaletteFolder(older)
        let search = PaletteSearch(query: "project", titleOnly: true, folder: folder, sort: .createdNewest)
        XCTAssertEqual(search.results(from: rows).map(\.id.uuid), ["newer", "older", "unknown"])
        let oldestFirst = PaletteSearch(query: "project", titleOnly: true, folder: folder, sort: .editedOldest)
        XCTAssertEqual(oldestFirst.results(from: rows).map(\.id.uuid), ["newer", "older", "unknown"])
        XCTAssertFalse(PaletteSearch(query: "project", titleOnly: true).results(from: rows).contains(folderMatch))
        XCTAssertTrue(PaletteSearch(query: "project").results(from: rows).contains(folderMatch))
    }
    func testPickerAppliesBodyMatchesOnlyInTheChosenFolderAndOutsideTitleOnlyMode() {
        let bodyMatch = noteSummary("body", title: "Update", folder: ["Work"])
        let otherFolder = noteSummary("other", title: "Update", folder: ["Personal"])
        var locked = noteSummary("locked", title: "Update", folder: ["Work"])
        locked.isLocked = true
        let notes = [otherFolder, locked, bodyMatch]
        let ids: Set<String> = ["body", "other", "locked"]
        var filters = PaletteSearch(query: "needle", folder: PaletteFolder(bodyMatch))
        XCTAssertEqual(filters.results(from: notes, bodyMatches: ids).map(\.id.uuid), ["body"])
        filters.titleOnly = true
        XCTAssertTrue(filters.results(from: notes, bodyMatches: ids).isEmpty)
    }

    func testPickerKeepsIdenticallyNamedFoldersSeparateWithinAndAcrossAccounts() {
        var primary = noteSummary("first", title: "Update", folder: ["Work", "Drafts"])
        primary.folderID = "folder-a"
        var sameAccount = noteSummary("second", title: "Update", folder: ["Work", "Drafts"])
        sameAccount.folderID = "folder-b"
        var otherAccount = primary
        otherAccount.id = NoteID(uuid: "third")
        otherAccount.accountID = "other-account"
        let notes = [sameAccount, primary, otherAccount]
        let choices = PaletteFolder.choices(in: notes)

        XCTAssertEqual(choices.count, 3)
        XCTAssertEqual(choices, PaletteFolder.choices(in: Array(notes.reversed())))
        XCTAssertEqual(PaletteSearch(query: "Update", folder: PaletteFolder(primary))
            .results(from: notes).map(\.id.uuid), ["first"])
        XCTAssertEqual(PaletteSearch(query: "Update", folder: PaletteFolder(sameAccount))
            .results(from: notes).map(\.id.uuid), ["second"])
        XCTAssertEqual(PaletteSearch(query: "Update", folder: PaletteFolder(otherAccount))
            .results(from: notes).map(\.id.uuid), ["third"])
    }

    func testPickerScrollRevealsContextAboveAndBelowTheSelectedRow() {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 105))
            let table = PaletteTable(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
            let rows = PickerScrollRows()
            table.headerView = nil
            table.rowHeight = 23
            table.addTableColumn(NSTableColumn(identifier: .init("note")))
            scroll.documentView = table
            table.dataSource = rows
            table.reloadData()
            scroll.tile()

            table.scrollRowToVisible(10)
            XCTAssertGreaterThanOrEqual(table.visibleRect.maxY - table.rect(ofRow: 10).maxY, 12)
            table.scrollRowToVisible(6)
            XCTAssertGreaterThanOrEqual(table.rect(ofRow: 6).minY - table.visibleRect.minY, 12)
            table.scrollRowToVisible(0)
            XCTAssertTrue(table.visibleRect.contains(table.rect(ofRow: 0)))
            table.scrollRowToVisible(29)
            XCTAssertTrue(table.visibleRect.contains(table.rect(ofRow: 29)))
        }
    }

    func testPickerCopyMatchesScriptingIdentityWithoutMatchingOtherNotes() throws {
        let coreData = "x-coredata://store/ICNote/p19"
        let target = try XCTUnwrap(EditorNoteCopyTarget(coreData))
        XCTAssertTrue(target.matches(NoteID(uuid: coreData, coreDataID: coreData)))
        XCTAssertTrue(target.matches(NoteID(uuid: UUID().uuidString, coreDataID: coreData)))
        XCTAssertFalse(target.matches(NoteID(uuid: UUID().uuidString, coreDataID: coreData + "0")))
        XCTAssertNil(EditorNoteCopyTarget("a note title"))
    }

    func testPickerContextMenuTargetsTheClickedRowAndIgnoresEmptySpace() throws {
        try MainActor.assumeIsolated {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                                  styleMask: .borderless, backing: .buffered, defer: true)
            let table = PaletteTable(frame: try XCTUnwrap(window.contentView).bounds)
            let rows = PickerScrollRows(count: 3)
            table.headerView = nil
            table.rowHeight = 23
            table.addTableColumn(NSTableColumn(identifier: .init("note")))
            window.contentView?.addSubview(table)
            table.dataSource = rows
            table.reloadData()

            let context = NSMenu()
            context.addItem(withTitle: "Open Note in New Window", action: nil, keyEquivalent: "")
            table.menu = context
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

            @MainActor func rightClick(at point: NSPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
                                                location: table.convert(point, to: nil), modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }

            let thirdRow = table.rect(ofRow: 2)
            XCTAssertTrue(table.menu(for: try rightClick(at: NSPoint(x: thirdRow.midX, y: thirdRow.midY))) === context)
            XCTAssertEqual(table.selectedRow, 2)
            table.setFrameSize(NSSize(width: 240, height: 120))
            let emptySpace = NSPoint(x: thirdRow.midX, y: thirdRow.maxY + 12)
            XCTAssertTrue(table.bounds.contains(emptySpace))
            XCTAssertNil(table.menu(for: try rightClick(at: emptySpace)))
            XCTAssertEqual(table.selectedRow, 2)
        }
    }

    func testCurrentNoteCopyPublishesOnlyForUnchangedClipboardAndMatchingFocus() throws {
        try MainActor.assumeIsolated {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let target = UUID().uuidString
            let copy = EditorNoteCopy(id: target, text: "**Current note**")
            try ClipboardCopy.write("an earlier copy", to: board)
            let original = board.changeCount
            XCTAssertFalse(try copy.publish(to: board, expected: UUID().uuidString, change: original) { true })
            XCTAssertFalse(try copy.publish(to: board, expected: target, change: original) { false })
            XCTAssertEqual(board.string(forType: .string), "an earlier copy")
            try ClipboardCopy.write("a newer copy", to: board)
            XCTAssertFalse(try copy.publish(to: board, expected: target, change: original) { true })
            XCTAssertEqual(board.string(forType: .string), "a newer copy")
            XCTAssertTrue(try copy.publish(to: board, expected: target, change: board.changeCount) { true })
            XCTAssertEqual(board.string(forType: .string), "**Current note**")
        }
    }

    func testCurrentNoteToolbarControlsCanBeReorderedAndHidden() throws {
        XCTAssertEqual(try EditorToolbarControl.parse("copy-link, italic, backlinks"),
                       [.note(.copyLink), .format(.italic), .note(.backlinks)])
        XCTAssertEqual(try EditorToolbarControl.parse("bold"), [.format(.bold)])
        XCTAssertThrowsError(try EditorToolbarControl.parse("copy-link, copy-link"))
    }

    func testToolbarAcceptsNativeStrikethroughAndParagraphAlignment() throws {
        let controls = try EditorToolbarControl.parse("strikethrough,align-left,align-center,align-right,justify")
        XCTAssertEqual(controls.map(\.title), ["Strikethrough", "Align Left", "Align Center", "Align Right", "Justify"])
        XCTAssertEqual(try EditorToolbarControl.parse("alignment,bold").map(\.title), ["Alignment", "Bold"])
    }

    func testSlashOffersLinkAndAllAlignmentCommands() {
        XCTAssertEqual(EditorSlashChoice.matching("link").map(\.action), [.format(.link)])
        XCTAssertEqual(EditorSlashChoice.matching("left").map(\.action), [.format(.alignLeft)])
        XCTAssertEqual(EditorSlashChoice.matching("center").map(\.action), [.format(.alignCenter)])
        XCTAssertEqual(EditorSlashChoice.matching("right").map(\.action), [.format(.alignRight)])
        XCTAssertEqual(EditorSlashChoice.matching("justify").map(\.action), [.format(.justify)])
    }

    func testNotesMenuPathsKeepTranslationsTogetherAndUseTheMenuBarItemTitle() {
        let menus = NotesMenuLocalization(tables: [
            ["GEO-Iw-cKr.title": "Format", "jxT-CU-nIS.title": "Formater", "5IP-Ek-bcg.title": "Sous-titre"],
            ["GEO-Iw-cKr.title": "フォーマット", "5IP-Ek-bcg.title": "見出し"],
            ["5IP-Ek-bcg.title": "Unmapped heading"]
        ])
        XCTAssertEqual(Set(menus.paths(for: NotesEditorAction.heading.menuPath)), Set([
            ["Format", "Heading"], ["Format", "Sous-titre"], ["フォーマット", "見出し"]
        ]))
        XCTAssertEqual(menus.paths(for: ["Edit", "Unknown"]), [["Edit", "Unknown"]])
    }

    func testEditLinkUsesTheNativeLocalizedMenuTitle() {
        let menus = NotesMenuLocalization(tables: [
            ["W48-6f-4Dl.title": "Édition", "Edit Link": "Modifier le lien"]
        ])
        XCTAssertEqual(menus.paths(for: ["Edit", "Edit Link"]),
                       [["Edit", "Edit Link"], ["Édition", "Modifier le lien"]])
    }

    func testMarkdownAndLinkPasteboardRoundTrip() throws {
        let source = "A bold line"
        let uuid = "01F1D525-2B94-4A66-9A46-E3CA38A23F93"
        let note = Note(summary: noteSummary(uuid, title: "Title", folder: ["Work"]),
                        document: NoteDocument(text: source, runs: [
                            AttributeRun(length: source.utf16.count, font: FontStyle(bold: true))
                        ]), attachments: [])
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        try ClipboardCopy.write(ClipboardCopy.markdown(note, includeAttachments: true), to: clipboard)
        XCTAssertEqual(clipboard.string(forType: .string), "**A bold line**")
        try ClipboardCopy.write(ClipboardCopy.noteLink(note.summary), to: clipboard)
        XCTAssertEqual(clipboard.string(forType: .string), "applenotes://showNote?identifier=\(uuid)")
        let locked = Note(summary: note.summary, document: nil, attachments: [])
        XCTAssertThrowsError(try ClipboardCopy.markdown(locked, includeAttachments: false))
        XCTAssertEqual(clipboard.string(forType: .string), "applenotes://showNote?identifier=\(uuid)")
    }

    func testCopyLinkDoesNotMistakeACoreDataURIForTheNoteUUID() throws {
        let uri = "x-coredata://test/ICNote/p123"
        var note = noteSummary(uri, title: "Limited", folder: ["Notes"])
        XCTAssertThrowsError(try ClipboardCopy.noteLink(note)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "editor_note_link_unavailable")
        }
        let id = try XCTUnwrap(UUID(uuidString: "01F1D525-2B94-4A66-9A46-E3CA38A23F93"))
        note.deepLink = "applenotes://showNote?identifier=\(id.uuidString)"
        XCTAssertEqual(try ClipboardCopy.noteLink(note), ClipboardCopy.noteLink(id))
        note.deepLink = "applenotes://showNote?identifier=\(id.uuidString)&other=1"
        XCTAssertThrowsError(try ClipboardCopy.noteLink(note))
    }

    func testCopyMarkdownKeepsTableAndImageInPlaceWithoutIndexedContent() throws {
        var document = NoteDocument(text: "Intro\n\u{fffc}\nBefore \u{fffc} after", runs: [
            AttributeRun(length: 6, paragraph: .init(kind: .heading)),
            AttributeRun(length: 1, attachment: InlineRef(id: "table", typeUTI: "com.apple.notes.table")),
            AttributeRun(length: 8),
            AttributeRun(length: 1, attachment: InlineRef(id: "image", typeUTI: "public.png")),
            AttributeRun(length: 6)
        ])
        document.tables = ["table": [["Name", "Status"], ["Sample", "Ready"]]]
        let note = Note(summary: noteSummary("a", title: "Intro", folder: ["Notes"]),
                        document: document, attachments: [
            Attachment(id: "table", typeUTI: "com.apple.notes.table"),
            Attachment(id: "image", typeUTI: "public.png", filename: "Plot.png",
                       filePath: "/tmp/Plot space.png", ocrText: "indexed-only-words"),
            Attachment(id: "file", typeUTI: "com.adobe.pdf", filename: "Source.pdf", pdfText: "hidden-text")
        ])
        let expected = """
        ## Intro

        | Name | Status |
        | --- | --- |
        | Sample | Ready |

        Before ![Plot.png](file:///tmp/Plot%20space.png) after

        [Source.pdf](notescli-attachment:file)
        """
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try ClipboardCopy.write(ClipboardCopy.markdown(note, includeAttachments: true), to: board)
        XCTAssertEqual(board.string(forType: .string), expected)
        let textOnly = try ClipboardCopy.markdown(note, includeAttachments: false)
        XCTAssertTrue(textOnly.contains("Before  after"))
        XCTAssertFalse(textOnly.contains("Source.pdf"))
        XCTAssertFalse(textOnly.contains("\u{fffc}"))
    }

    func testClipboardRejectsSSH() {
        XCTAssertNoThrow(try ClipboardCopy.requireLocalSession(environment: [:]))
        for variable in ["SSH_CONNECTION", "SSH_TTY"] {
            XCTAssertThrowsError(try ClipboardCopy.requireLocalSession(environment: [variable: "remote"])) {
                XCTAssertEqual(($0 as? NotesError)?.code, "clipboard_unavailable")
            }
        }
    }

    func testPaletteCatalogAndFilterKeepDistinctIDs() throws {
        let notes = [noteSummary("a", title: "Café", folder: ["Work"]),
                     noteSummary("b", title: "Café", folder: ["Home"]),
                     noteSummary("c", title: "Deleted", folder: ["Work"], deleted: true)]
        struct Page: Encodable { var notes: [NoteSummary] }
        struct Envelope: Encodable { var result: Page }
        let page = Page(notes: notes)
        for data in [try NotePresentation.json(page), try NotePresentation.json(Envelope(result: page))] {
            XCTAssertEqual(try PaletteClient.catalog(data), notes)
        }
        XCTAssertEqual(PaletteClient.filter(notes, query: "cafe WORK").map(\.id.uuid), ["a"])
        XCTAssertEqual(PaletteClient.filter(notes, query: "CaFÉ").map(\.id.uuid), ["a", "b"])
        XCTAssertEqual(PaletteClient.filter(notes, query: " ").map(\.id.uuid), ["a", "b"])
        XCTAssertEqual(PaletteClient.filter(notes, query: "Deleted"), [])
    }

    func testPaletteReusesAutomationOnlyForAnExplicitLimitedDefaultCatalog() throws {
        let plain = try PaletteClient.decodeCatalog(Data(#"{"notes":[]}"#.utf8))
        let unmarked = try PaletteClient.decodeCatalog(Data(#"{"result":{"notes":[]}}"#.utf8))
        let limited = try PaletteClient.decodeCatalog(Data(#"{"fidelity":"limited","result":{"notes":[]}}"#.utf8))
        for catalog in [plain, unmarked] {
            XCTAssertFalse(PaletteClient.canReuseAutomation(for: catalog, backend: nil, environment: [:]))
        }
        XCTAssertTrue(PaletteClient.canReuseAutomation(for: limited, backend: nil, environment: [:]))
        XCTAssertFalse(PaletteClient.canReuseAutomation(for: limited, backend: "fake", environment: [:]))
        for env in [["NOTESCLI_CAPABILITY_HOST": "force"], ["NOTESCLI_BACKEND": "fake"], ["NOTESCLI_HOST_ACTIVE": "1"]] {
            XCTAssertFalse(PaletteClient.canReuseAutomation(for: limited, backend: nil, environment: env))
        }
    }

    func testPaletteSearchReusesAutomationAndKeepsRoutedPermissionFallback() throws {
        func data(_ id: String) throws -> Data { try JSONEncoder().encode([id]) }
        let local = try PaletteClient.search(automation: { [.init(id: "local")] },
                                            routed: { XCTFail("Do not route"); return Data() })
        XCTAssertEqual(local, [.init(id: "local")])
        let routed = try PaletteClient.search(automation: { throw NotesError("automation_denied", "Denied") },
                                             routed: { try data("routed") })
        XCTAssertEqual(routed, [.init(id: "routed")])
        XCTAssertThrowsError(try PaletteClient.search(automation: { throw NotesError("automation_timeout", "Timed out") },
                                                     routed: { XCTFail("Do not repeat the timed-out read"); return Data() }))
    }

    func testPalettePreservesExplicitBackendAndStrictReference() throws {
        let command = try XCTUnwrap(NotesCLI.parseAsRoot(["palette", "--backend", "fake"]) as? PaletteCommand)
        XCTAssertEqual(command.options.backend, "fake")
        var note = noteSummary("123", title: "123", folder: ["Work"])
        XCTAssertEqual(PaletteClient.reference(to: note), "id:123")
        note.id.coreDataID = "x-coredata://folder/ICNote/p123"
        XCTAssertEqual(PaletteClient.reference(to: note), "id:x-coredata://folder/ICNote/p123")
    }

    func testPaletteSelectsCurrentNoteByUUID() throws {
        let id = UUID()
        let notes = [noteSummary(UUID().uuidString, title: "Same title", folder: []),
                     noteSummary(id.uuidString, title: "Same title", folder: [], deleted: true),
                     noteSummary(id.uuidString.lowercased(), title: "Same title", folder: [])]
        XCTAssertEqual(PaletteClient.row(for: id, in: notes), 2)
        XCTAssertNil(PaletteClient.row(for: UUID(), in: notes))
        XCTAssertThrowsError(try NotesCLI.parseAsRoot(["palette", "--selected-note", "Same title"]))
    }

    func testEditorRejectsNonNoteIdentityAndAmbiguousControlSettings() throws {
        let id = UUID()
        XCTAssertEqual(NotesEditorSelection.noteID("Note[id=\(id)]"), id)
        for invalid in [nil, "Search", "Note[id=unknown]", "OtherNote[id=\(id)]", "Note[id=\(id)]more"] {
            XCTAssertNil(NotesEditorSelection.noteID(invalid))
        }
        XCTAssertEqual(try NotesEditorAction.parse("link, bold,highlight"), [.link, .bold, .highlight])
        for invalid in ["", "bold,bold", "bold,", "check"] {
            XCTAssertThrowsError(try NotesEditorAction.parse(invalid))
        }
        XCTAssertEqual(NotesEditorAction.bold.shortcut, NotesMenuShortcut("B", 0))
        XCTAssertNotEqual(NotesEditorAction.body.shortcut, NotesEditorAction.bold.shortcut)
    }

    func testEditorSearchHotkeyRejectsBareAndDuplicateKeys() throws {
        XCTAssertEqual(try EditorHotkey("CMD+shift+P"), try EditorHotkey("shift+cmd+p"))
        XCTAssertNotEqual(try EditorHotkey("cmd+p"), try EditorHotkey("cmd+shift+p"))
        for invalid in ["p", "shift+p", "cmd+cmd+p", "cmd++p", "meta+p", "cmd+xy", "cmd+é"] {
            XCTAssertThrowsError(try EditorHotkey(invalid), invalid)
        }
    }

    @MainActor
    func testEditorHotkeysResolveAgainstSystemKeyboardLayoutsWithoutSwitchingInputSources() throws {
        func layout(_ id: String) throws -> TISInputSource {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            let values = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
            guard let value = values?.first else { throw XCTSkip("System layout unavailable: \(id)") }
            return value
        }
        let us = try layout("com.apple.keylayout.US")
        let dvorak = try layout("com.apple.keylayout.Dvorak")
        let french = try layout("com.apple.keylayout.French")
        let search = try EditorHotkey("cmd+p")
        XCTAssertEqual(search.keyCode(in: us), UInt32(kVK_ANSI_P))
        XCTAssertEqual(search.keyCode(in: dvorak), UInt32(kVK_ANSI_R))
        XCTAssertEqual(try EditorHotkey("cmd+shift+1").keyCode(in: french), UInt32(kVK_ANSI_1))
    }

    func testEditorSlashAndMarkdownTriggersUseExactUTF16Ranges() throws {
        let prefix = "👩🏽‍💻\n  /h2"
        let command = try XCTUnwrap(EditorTrigger.parse(prefix: prefix, endingAt: prefix.utf16.count,
                                                        atDocumentStart: false, nextUnit: "\n", allowMarkdown: false))
        XCTAssertEqual(command.kind, .slash("h2"))
        XCTAssertEqual(command.range, NSRange(location: prefix.utf16.count - 3, length: 3))
        XCTAssertEqual(EditorSlashChoice.matching("h2").map(\.action), [.format(.heading)])
        XCTAssertEqual(EditorSlashChoice.matching("blockquote").map(\.action), [.format(.quote)])
        XCTAssertEqual(EditorSlashChoice.matching("today").map(\.action), [.date])
        let markers: [(String, NotesEditorAction)] = [
            ("# ", .title), ("## ", .heading), ("### ", .subheading), ("[] ", .checklist),
            ("``` ", .monostyled), ("> ", .quote), ("- ", .dashed), ("* ", .bulleted), ("1. ", .numbered),
        ]
        for (marker, action) in markers {
            XCTAssertEqual(EditorTrigger.parse(prefix: marker, endingAt: marker.utf16.count, atDocumentStart: true,
                                               nextUnit: nil, allowMarkdown: true)?.kind, .markdown(action))
            XCTAssertNil(EditorTrigger.parse(prefix: marker, endingAt: marker.utf16.count, atDocumentStart: true,
                                             nextUnit: nil, allowMarkdown: false))
        }
        for literal in ["https://example.com", "a /today", "/foo", "/tmp/abc", "/today ", "not ## ", "/askai"] {
            XCTAssertNil(EditorTrigger.parse(prefix: literal, endingAt: literal.utf16.count,
                                             atDocumentStart: true, nextUnit: nil, allowMarkdown: true), literal)
        }
        XCTAssertNil(EditorTrigger.parse(prefix: "/h2", endingAt: 93, atDocumentStart: false, nextUnit: nil, allowMarkdown: true))
        XCTAssertNil(EditorTrigger.parse(prefix: "/h2", endingAt: 3, atDocumentStart: true, nextUnit: "x", allowMarkdown: true))
    }

    private func noteSummary(_ id: String, title: String, folder: [String], deleted: Bool = false) -> NoteSummary {
        NoteSummary(id: NoteID(uuid: id), title: title, snippet: "", folderID: nil, folderPath: folder,
                    accountID: "local", created: nil, modified: nil, isPinned: false, isLocked: false,
                    isDeleted: deleted, hasChecklist: false, attachmentCount: 0, tags: [])
    }
}
