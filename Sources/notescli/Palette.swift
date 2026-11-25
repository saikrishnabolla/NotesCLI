import AppKit
import ArgumentParser
import Foundation
import NotesAutomation
import NotesCore

struct PaletteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "palette", abstract: "Open a local keyboard-first note picker.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "Select this note UUID when the picker opens.")
    var selectedNote: String?

    func validate() throws {
        if let selectedNote, UUID(uuidString: selectedNote) == nil {
            throw ValidationError("--selected-note requires a note UUID.")
        }
    }

    var client: PaletteClient {
        PaletteClient(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                      backend: options.backend, readOnly: options.readOnly,
                      engine: options.engineWasExplicitlySelected ? options.resolvedEngine : nil)
    }

    func run() throws {
        try ClipboardCopy.requireLocalSession()
        guard ProcessInfo.processInfo.environment["NOTESCLI_HOST_ACTIVE"] != "1" else {
            throw NotesError("palette_unavailable", "Open the palette from a local macOS session.")
        }
        let client = self.client
        let id = selectedNote.flatMap(UUID.init(uuidString:))
        try MainActor.assumeIsolated { try PaletteWindow.run(client: client, selectedNote: id) }
    }
}

struct PaletteClient: Sendable {
    let executable: URL
    let backend: String?
    var readOnly = false
    var engine: WriteEngine? = nil

    private struct Page: Decodable { var notes: [NoteSummary] }
    private struct Envelope: Decodable { var result: Page; var fidelity: String? }
    private struct CreateResult: Decodable { var result: WriteResult }

    struct Catalog: Sendable {
        let notes: [NoteSummary]
        let usesLimitedAutomation: Bool
        var automationReader: ScriptingNotesReader? = nil
    }

    static func catalog(_ data: Data) throws -> [NoteSummary] {
        try decodeCatalog(data).notes
    }

    static func decodeCatalog(_ data: Data) throws -> Catalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let page = try? decoder.decode(Page.self, from: data) {
            return Catalog(notes: page.notes, usesLimitedAutomation: false)
        }
        let envelope = try decoder.decode(Envelope.self, from: data)
        return Catalog(notes: envelope.result.notes, usesLimitedAutomation: envelope.fidelity == "limited")
    }

    static func filter(_ notes: [NoteSummary], query: String) -> [NoteSummary] {
        PaletteSearch(query: query).results(from: notes)
    }

    func loadCatalog() throws -> Catalog {
        let env = ProcessInfo.processInfo.environment
        let name = backend ?? env["NOTESCLI_BACKEND"] ?? "default"
        if name == "default", env["NOTESCLI_HOST_ACTIVE"] != "1",
           !CapabilityHostRouting.usesHost(backend: name, environment: env) {
            do {
                let local = try Backends.make(name, automationSnapshotTTL: 8)
                let notes = try local.reader.notes(.init(), sort: .modified)
                return Catalog(notes: notes, usesLimitedAutomation: local.fidelity == .limited,
                               automationReader: local.reader as? ScriptingNotesReader)
            } catch let error as NotesError where error.code == "automation_denied" {
                // macOS can attribute a subprocess's grant differently.
            }
        }
        return try Self.decodeCatalog(invoke(["list"]))
    }

    static func canReuseAutomation(for catalog: Catalog, backend: String?, environment: [String: String]) -> Bool {
        catalog.usesLimitedAutomation &&
            (backend ?? environment["NOTESCLI_BACKEND"] ?? "default") == "default" &&
            environment["NOTESCLI_CAPABILITY_HOST"] != "force" &&
            environment["NOTESCLI_HOST_ACTIVE"] != "1"
    }

    static func search(automation: (() throws -> [EditorSearchMatch])?,
                       routed: () throws -> Data) throws -> [EditorSearchMatch] {
        if let automation {
            do { return try automation() }
            catch let error as NotesError where error.code == "automation_denied" {
                // The CLI/helper may have a different macOS permission grant.
            }
        }
        return try decodeMatches(routed())
    }

    func search(_ query: EditorSearchQuery, automation: ScriptingNotesReader?) throws -> [EditorSearchMatch] {
        try Self.search(automation: automation.map { reader in { try reader.editorSearch(query) } },
                        routed: { try invoke(["editor-body-search", "--", query.text]) })
    }

    private static func decodeMatches(_ data: Data) throws -> [EditorSearchMatch] {
        let decoder = JSONDecoder()
        if let matches = try? decoder.decode([EditorSearchMatch].self, from: data) { return matches }
        return try decoder.decode([String].self, from: data).map { EditorSearchMatch(id: $0) }
    }

    func create(title: String, folderID: String?) throws -> String {
        guard !readOnly else { throw NotesError("read_only", "Writing is disabled by --read-only.") }
        let folder = folderID.map { ["--folder", $0] } ?? []
        let writeEngine = engine.map { ["--engine", $0.rawValue] } ?? []
        let data = try invoke(["add", "--body", ""] + folder + writeEngine + ["--", title])
        let response = try JSONDecoder().decode(CreateResult.self, from: data).result
        guard let id = response.noteID,
              response.outcome == .verified || response.outcome == .unverified else {
            throw NotesError("palette_create_unconfirmed", "Could not confirm creation. Check Notes before trying again.")
        }
        return "id:" + (id.coreDataID ?? id.uuid)
    }

    func backlinks(to note: NoteSummary) throws -> [NoteSummary] {
        try backlinks(reference: Self.reference(to: note))
    }

    func backlinks(reference: String) throws -> [NoteSummary] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try invoke(["backlinks", reference])
        return try decoder.decode([NoteSummary].self, from: data)
    }

    static func reference(to note: NoteSummary) -> String {
        "id:" + (note.id.coreDataID ?? note.id.uuid)
    }

    static func row(for id: UUID, in notes: [NoteSummary]) -> Int? {
        notes.firstIndex { !$0.isDeleted && UUID(uuidString: $0.id.uuid) == id }
    }

    func copy(_ target: EditorNoteCopyTarget, action: EditorNoteAction) throws -> EditorNoteCopy {
        guard action != .backlinks else {
            throw NotesError("invalid_editor_note_action", "Choose a copy action.")
        }
        let data = try invoke(["editor-note-copy", target.value, action.rawValue])
        return try JSONDecoder().decode(EditorNoteCopy.self, from: data)
    }

    func open(reference: String, separately: Bool = false) throws {
        _ = try invoke(["open", reference] + (separately ? ["--new-window"] : []))
    }

    @discardableResult
    func invoke(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        let split = arguments.firstIndex(of: "--") ?? arguments.endIndex
        process.arguments = Array(arguments[..<split]) + ["--json"]
            + (backend.map { ["--backend", $0] } ?? []) + Array(arguments[split...])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NotesError("palette_action_failed", process.terminationStatus == 4
                ? "Check Notes access with notescli doctor." : "The Notes command failed.")
        }
        return data
    }
}

struct EditorBodySearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "editor-body-search", shouldDisplay: false)
    @OptionGroup var options: GlobalOptions
    @Argument var text: String

    func run() throws {
        guard options.json, let query = EditorSearchQuery(text) else {
            throw ValidationError("Provide a search of up to 1024 bytes and use --json.")
        }
        try Output.json(options.backends().reader.editorSearch(query))
    }
}

@MainActor
final class PaletteWindow: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let client: PaletteClient
    private let selectedNote: UUID?
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let search = NSSearchField()
    private let sort = NSPopUpButton()
    private let folder = NSPopUpButton()
    private lazy var titleOnly = NSButton(checkboxWithTitle: "Title only", target: self, action: #selector(changeFilters))
    private let table = PaletteTable()
    private let status = NSTextField(labelWithString: "Loading notes…")
    private let copyToast = EditorToast()
    private lazy var create = NSButton(title: "Create Note", target: self, action: #selector(createNote))
    private lazy var retry = NSButton(title: "Retry", target: self, action: #selector(retrySearch))
    private var noteButtons: [NSButton] = []
    private var notes: [NoteSummary] = []
    private var results: [NoteSummary] = []
    private var loaded = false
    private var catalogFailed = false
    private var busy = false
    private var attemptedCreation: Creation?
    private var searchTask: Task<Void, Never>?
    private var completedSearch: PaletteBodySearchAttempt?
    private var automationReader: ScriptingNotesReader?
    private var resultExcerpts: [String: String] = [:]
    private var excerptQuery: EditorSearchQuery?

    private struct Creation: Equatable {
        let title: String
        let folderID: String?
    }

    static func run(client: PaletteClient, selectedNote: UUID?) throws {
        let app = NSApplication.shared
        guard !NSScreen.screens.isEmpty,
              app.activationPolicy() == .accessory || app.setActivationPolicy(.accessory) else {
            throw NotesError("palette_unavailable", "The palette needs a macOS desktop session.")
        }
        let picker = PaletteWindow(client: client, selectedNote: selectedNote)
        app.delegate = picker
        withExtendedLifetime(picker) { app.run() }
        app.delegate = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(search)
        load()
    }

    init(client: PaletteClient, selectedNote: UUID?) {
        self.client = client
        self.selectedNote = selectedNote
        super.init()
        window.title = "Find a Note"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        search.placeholderString = "Search notes"
        search.delegate = self
        search.setAccessibilityLabel("Search notes")
        sort.addItems(withTitles: PaletteSort.allCases.map(\.rawValue))
        sort.target = self
        sort.action = #selector(changeFilters)
        sort.setAccessibilityLabel("Sort notes")
        folder.addItem(withTitle: "All folders")
        folder.target = self
        folder.action = #selector(changeFilters)
        folder.setAccessibilityLabel("Filter by folder")
        folder.cell?.lineBreakMode = .byTruncatingTail
        let filters = NSStackView(views: [folder, titleOnly])
        filters.spacing = 12
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note")))
        table.headerView = nil
        table.rowHeight = 23
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openNote)
        table.setAccessibilityLabel("Matching notes")
        let menu = NSMenu()
        for (title, action) in [("Open", #selector(openNote)), ("Open Note in New Window", #selector(openNoteSeparately)),
                                ("Copy Markdown", #selector(copyMarkdown)),
                                ("Copy Link", #selector(copyLink)), ("Backlinks", #selector(showBacklinks))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let copyMarkdown = NSButton(title: "Copy Markdown", target: self, action: #selector(copyMarkdown))
        copyMarkdown.keyEquivalent = "m"
        copyMarkdown.keyEquivalentModifierMask = [.command, .shift]
        let copyLink = NSButton(title: "Copy Link", target: self, action: #selector(copyLink))
        copyLink.keyEquivalent = "l"
        copyLink.keyEquivalentModifierMask = [.command]
        let open = NSButton(title: "Open", target: self, action: #selector(openNote))
        let backlinks = NSButton(title: "Backlinks", target: self, action: #selector(showBacklinks))
        noteButtons = [backlinks, copyMarkdown, copyLink, open]
        create.isHidden = true
        retry.isHidden = true
        let buttons = NSStackView(views: [retry] + noteButtons + [create])
        buttons.spacing = 8
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let root = NSView()
        window.contentView = root
        for view in [search, sort, filters, scroll, status, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: sort.leadingAnchor, constant: -8),
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            sort.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            sort.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            sort.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            filters.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            filters.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            folder.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sort.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: sort.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }

    func load() {
        guard !busy else { return }
        busy = true
        automationReader = nil
        completedSearch = nil
        catalogFailed = false
        status.stringValue = "Loading notes…"
        updateActions()
        let client = client
        Task {
            defer { busy = false; updateActions() }
            do {
                let catalog = try await Task.detached { try client.loadCatalog() }.value
                notes = catalog.notes
                if PaletteClient.canReuseAutomation(for: catalog, backend: client.backend,
                                                    environment: ProcessInfo.processInfo.environment) {
                    automationReader = catalog.automationReader ?? ScriptingNotesReader(snapshotTTL: 8)
                }
                let folders = PaletteFolder.choices(in: notes)
                let counts = Dictionary(grouping: folders, by: \.label).mapValues(\.count)
                var ordinal: [String: Int] = [:]
                for option in folders {
                    let label = option.label
                    let number = (ordinal[label] ?? 0) + 1
                    ordinal[label] = number
                    let name = counts[label] == 1 ? label : "\(label) (\(number))"
                    let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                    item.representedObject = option
                    folder.menu?.addItem(item)
                }
                loaded = true
                refresh(selecting: selectedNote)
            } catch {
                EditorDiagnostics.record(.searchLoadFailed)
                catalogFailed = true
                status.stringValue = "Couldn’t read notes."
            }
        }
    }

    private var bodyQuery: EditorSearchQuery? {
        titleOnly.state == .on ? nil : EditorSearchQuery(search.stringValue)
    }

    private func refresh(selecting id: UUID? = nil, preserving identity: String? = nil) {
        let options = PaletteSearch(query: search.stringValue, titleOnly: titleOnly.state == .on,
                                    folder: selectedFolder,
                                    sort: sort.titleOfSelectedItem.flatMap(PaletteSort.init(rawValue:)))
        let query = bodyQuery
        let outcome = completedSearch.flatMap { $0.query == query?.text ? $0 : nil }
        let matches = outcome?.matches ?? []
        results = options.results(from: notes, bodyMatches: Set(matches.map(\.id)))
        excerptQuery = outcome?.matches == nil ? nil : query
        resultExcerpts = matches.reduce(into: [:]) { excerpts, match in
            if let excerpt = match.excerpt { excerpts[match.id] = excerpt }
        }
        table.reloadData()
        if let id {
            if let row = PaletteClient.row(for: id, in: results) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
                status.stringValue = ""
            } else {
                table.deselectAll(nil)
                status.stringValue = "Current note unavailable"
            }
        } else {
            if !results.isEmpty {
                let row = identity.flatMap { value in
                    results.firstIndex { EditorSearchQuery.identity($0) == value }
                } ?? 0
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if identity != nil { table.scrollRowToVisible(row) }
            }
            if query != nil, outcome == nil {
                status.stringValue = "Searching note text…"
            } else if let outcome, outcome.matches == nil {
                status.stringValue = "Note text unavailable."
            } else if !options.query.allSatisfy(\.isWhitespace), EditorSearchQuery(options.query) == nil {
                status.stringValue = "Shorten the search to 1024 bytes."
            } else {
                status.stringValue = results.isEmpty ? "No matching notes" : ""
            }
        }
        if query != nil, outcome == nil { searchNoteText() }
        updateActions()
    }

    private func searchNoteText() {
        guard searchTask == nil else { return }
        let client = client
        searchTask = Task { [weak self] in
            // At most one read at a time. Pick up newer input after this read returns.
            try? await Task.sleep(for: .milliseconds(170))
            guard let self, !Task.isCancelled, window.isVisible else { return }
            guard let query = bodyQuery, completedSearch?.query != query.text else {
                searchTask = nil
                return
            }
            let automationReader = automationReader
            let matches = await Task.detached { try? client.search(query, automation: automationReader) }.value
            searchTask = nil
            guard !Task.isCancelled, window.isVisible else { return }
            if bodyQuery?.text == query.text {
                completedSearch = PaletteBodySearchAttempt(query: query.text, matches: matches)
                if matches == nil { EditorDiagnostics.record(.searchLoadFailed) }
            }
            refresh(preserving: targetNote.map(EditorSearchQuery.identity))
        }
    }

    func windowWillClose(_ notification: Notification) {
        searchTask?.cancel()
        automationReader = nil
        copyToast.dismiss()
        let app = NSApplication.shared
        app.stop(nil)
        // Wake the event loop if a background action closed the window.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          subtype: 0, data1: 0, data2: 0) {
            app.postEvent(event, atStart: true)
        }
    }

    func windowDidResignKey(_ notification: Notification) { copyToast.dismiss() }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        resultExcerpts[EditorSearchQuery.identity(results[row])] == nil ? 23 : 39
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let note = results[row]
        let folder = note.folderPath.joined(separator: " › ")
        let title = folder.isEmpty ? note.title : "\(note.title) — \(folder)"
        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingTail
        guard let query = excerptQuery, let passage = resultExcerpts[EditorSearchQuery.identity(note)] else { return label }

        let size = NSFont.smallSystemFontSize
        let styled = NSMutableAttributedString(string: passage, attributes: [.font: NSFont.systemFont(ofSize: size)])
        for range in query.highlightRanges(in: passage) {
            styled.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold),
                                range: NSRange(range, in: passage))
        }
        let excerpt = NSTextField(labelWithAttributedString: styled)
        excerpt.textColor = .secondaryLabelColor
        excerpt.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [label, excerpt])
        stack.orientation = .vertical
        stack.spacing = 1
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.textField = label
        cell.addSubview(stack)
        for field in [label, excerpt] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func controlTextDidChange(_ notification: Notification) {
        if completedSearch?.query != bodyQuery?.text { completedSearch = nil }
        if loaded { refresh() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            window.close()
        case #selector(NSResponder.insertNewline(_:)):
            openNote()
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(0, table.selectedRow + delta), results.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        default: return false
        }
        return true
    }

    @objc private func openNote() {
        guard !busy, let note = targetNote else { return }
        runOpen(PaletteClient.reference(to: note))
    }

    @objc private func openNoteSeparately() {
        guard !busy, let note = targetNote else { return }
        runOpen(PaletteClient.reference(to: note), separately: true)
    }

    private var creation: Creation? {
        let title = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, !client.readOnly, results.isEmpty, EditorSearchQuery(title) != nil,
              !title.contains(where: \.isNewline) else { return nil }
        if let query = bodyQuery {
            guard completedSearch?.query == query.text, let matches = completedSearch?.matches else { return nil }
            let knownIDs = Set(notes.map(EditorSearchQuery.identity))
            guard matches.allSatisfy({ knownIDs.contains($0.id) }) else { return nil }
        }
        guard let selected = selectedFolder else { return Creation(title: title, folderID: nil) }
        guard let id = selected.id else { return nil }
        return Creation(title: title, folderID: id)
    }

    private var selectedFolder: PaletteFolder? { folder.selectedItem?.representedObject as? PaletteFolder }

    private func updateActions() {
        let hasResults = !results.isEmpty
        noteButtons.forEach { $0.isHidden = !hasResults }
        let choice = creation
        create.isHidden = choice == nil
        create.isEnabled = !busy && choice != attemptedCreation
        retry.isHidden = !catalogFailed && completedSearch?.failed(for: bodyQuery) != true
        retry.isEnabled = !busy
    }

    @objc private func retrySearch() {
        guard !busy else { return }
        if catalogFailed {
            load()
        } else if completedSearch?.failed(for: bodyQuery) == true {
            completedSearch = nil
            refresh(preserving: targetNote.map(EditorSearchQuery.identity))
        }
    }

    @objc private func createNote() {
        guard !busy, let choice = creation, choice != attemptedCreation else { return }
        attemptedCreation = choice
        busy = true
        updateActions()
        status.stringValue = "Creating note…"
        let client = client
        Task {
            defer { busy = false; updateActions() }
            do {
                let reference = try await Task.detached {
                    try client.create(title: choice.title, folderID: choice.folderID)
                }.value
                guard window.isVisible else { return }
                do {
                    try await Task.detached { try client.open(reference: reference) }.value
                    window.close()
                } catch {
                    status.stringValue = "Note created. Open it in Notes."
                }
            } catch {
                status.stringValue = "Could not confirm creation. Check Notes before trying again."
            }
        }
    }
    @objc private func changeFilters() {
        search.placeholderString = titleOnly.state == .on ? "Search titles" : "Search notes"
        search.setAccessibilityLabel(search.placeholderString ?? "Search notes")
        if loaded { refresh() }
    }
    @objc private func copyLink() { copy(.copyLink) }
    @objc private func copyMarkdown() { copy(.copyMarkdown) }
    @objc private func showBacklinks() {
        guard !busy, let note = targetNote else { return }
        busy = true
        let client = client
        status.stringValue = "Loading backlinks…"
        Task {
            defer { busy = false }
            do {
                let sources = try await Task.detached { try client.backlinks(to: note) }.value
                guard window.isVisible, targetNote?.id == note.id else { return }
                guard !sources.isEmpty else { status.stringValue = "No backlinks"; return }
                let menu = NSMenu()
                for source in sources {
                    let item = NSMenuItem(title: source.title, action: #selector(openBacklink(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = PaletteClient.reference(to: source)
                    menu.addItem(item)
                }
                status.stringValue = ""
                let row = table.rect(ofRow: table.selectedRow)
                menu.popUp(positioning: nil, at: NSPoint(x: 12, y: row.maxY), in: table)
            } catch {
                EditorDiagnostics.record(.searchNoteActionFailed)
                status.stringValue = "Backlinks unavailable"
            }
        }
    }

    @objc private func openBacklink(_ sender: NSMenuItem) {
        guard let reference = sender.representedObject as? String else { return }
        // The menu is synchronous; its selection is delivered while backlinks are loading.
        runOpen(reference)
    }

    private var targetNote: NoteSummary? {
        let row = table.selectedRow
        return results.indices.contains(row) ? results[row] : nil
    }

    private func copy(_ action: EditorNoteAction) {
        guard !busy, let note = targetNote else { return }
        if action == .copyMarkdown, note.isLocked {
            status.stringValue = "This note is locked."
            return
        }
        guard let target = EditorNoteCopyTarget(note.id.uuid) else { return }
        let client = client
        let change = NSPasteboard.general.changeCount
        busy = true
        status.stringValue = ""
        copyToast.dismiss()
        Task {
            defer { busy = false }
            do {
                let receipt = try await Task.detached { try client.copy(target, action: action) }.value
                guard window.isKeyWindow, targetNote?.id == note.id else { return }
                guard try receipt.publish(to: .general, expected: target.value, change: change, isCurrent: { true }) else {
                    status.stringValue = "Nothing copied. Try again."
                    return
                }
                let message = receipt.confirmation(for: action)
                let point = window.convertPoint(toScreen: NSPoint(x: 14, y: 74))
                copyToast.show(message, below: point)
                NSAccessibility.post(element: window, notification: .announcementRequested,
                                     userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            } catch {
                EditorDiagnostics.record(.searchNoteActionFailed)
                if window.isKeyWindow, targetNote?.id == note.id {
                    status.stringValue = action == .copyLink && (try? ClipboardCopy.noteLink(note)) == nil
                        ? "Open the note to copy its link." : "Couldn’t copy note."
                }
            }
        }
    }

    private func runOpen(_ reference: String, separately: Bool = false) {
        busy = true
        let client = client
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try client.open(reference: reference, separately: separately) }.value
                window.close()
            } catch {
                EditorDiagnostics.record(.searchNoteActionFailed)
                status.stringValue = separately ? "Could not open a new window. Check Notes Automation."
                    : ((error as? NotesError)?.message ?? "Could not complete the action.")
            }
        }
    }
}

@MainActor
final class PaletteTable: NSTableView {
    override func scrollRowToVisible(_ row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        let rect = rect(ofRow: row)
        let viewport = visibleRect
        let padding = min(16, max(0, (viewport.height - rect.height) / 2))
        let target = NSRect(x: viewport.minX, y: rect.minY - padding,
                            width: viewport.width, height: rect.height + padding * 2)
        scrollToVisible(target.intersection(bounds))
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        if let key = event.specialKey, key == .upArrow || key == .downArrow {
            scrollRowToVisible(selectedRow)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return super.menu(for: event)
    }
}
