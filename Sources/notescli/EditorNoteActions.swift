import AppKit
import ArgumentParser
import NotesCore

enum EditorNoteAction: String, CaseIterable, ExpressibleByArgument, Sendable {
    case copyMarkdown = "copy-markdown", copyLink = "copy-link", backlinks

    var title: String {
        switch self {
        case .copyMarkdown: "Copy Markdown"
        case .copyLink: "Copy Note Link"
        case .backlinks: "Backlinks"
        }
    }

    var symbol: String {
        switch self {
        case .copyMarkdown: "doc.on.clipboard"
        case .copyLink: "link.badge.plus"
        case .backlinks: "arrow.turn.up.left"
        }
    }
}

enum EditorToolbarControl: Equatable, Sendable {
    case format(NotesEditorAction)
    case note(EditorNoteAction)
    case alignment

    static let defaults: [Self] = [
        .format(.title), .format(.heading), .format(.subheading), .format(.body),
        .format(.bold), .format(.italic), .format(.underline), .format(.strikethrough),
        .alignment, .format(.highlight), .format(.link), .format(.checklist),
        .note(.copyMarkdown), .note(.copyLink), .note(.backlinks)
    ]

    static let available: [Self] = [.alignment] + NotesEditorAction.allCases.map(Self.format)
        + EditorNoteAction.allCases.map(Self.note)

    init?(_ id: String) {
        if id == "alignment" { self = .alignment }
        else if let value = NotesEditorAction(rawValue: id) { self = .format(value) }
        else if let value = EditorNoteAction(rawValue: id) { self = .note(value) }
        else { return nil }
    }

    var id: String {
        switch self { case .format(let value): value.rawValue; case .note(let value): value.rawValue; case .alignment: "alignment" }
    }

    var title: String {
        switch self {
        case .format(let value): value.rawValue.replacingOccurrences(of: "-", with: " ").capitalized
        case .note(let value): value.title
        case .alignment: "Alignment"
        }
    }

    var symbol: String {
        switch self { case .format(let value): value.symbol; case .note(let value): value.symbol; case .alignment: "text.alignleft" }
    }

    @MainActor
    func makeButton(frame: NSRect, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(frame: frame)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.title = button.image == nil ? String(title.prefix(2)) : ""
        button.setAccessibilityLabel(title)
        button.toolTip = title
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.target = target
        button.action = action
        // The native Alignment menu tracks its own mouse events.
        button.sendAction(on: self == .alignment ? .leftMouseUp : .leftMouseDown)
        return button
    }

    static func parse(_ value: String) throws -> [Self] {
        if value.isEmpty { return [] }
        let names = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let items = names.compactMap(Self.init)
        guard !items.isEmpty, items.count == names.count, Set(names).count == names.count else {
            let allowed = available.map(\.id)
            throw NotesError("invalid_editor_actions", "Use distinct controls: \(allowed.joined(separator: ", ")).")
        }
        return items
    }
}

enum EditorNoteCopyTarget: Sendable {
    case uuid(UUID)
    case coreData(String)

    init?(_ value: String) {
        if let uuid = UUID(uuidString: value) { self = .uuid(uuid) }
        else if value.hasPrefix("x-coredata://") { self = .coreData(value) }
        else { return nil }
    }

    var value: String {
        switch self { case .uuid(let id): id.uuidString; case .coreData(let id): id }
    }

    func matches(_ note: NoteID) -> Bool {
        switch self {
        case .uuid(let id): UUID(uuidString: note.uuid) == id
        case .coreData(let id): note.coreDataID == id
        }
    }
}

struct EditorNoteCopy: Codable, Equatable, Sendable {
    let id: String
    let text: String
    var limited = false

    func confirmation(for action: EditorNoteAction) -> String {
        if action == .copyLink { return "Copied note link" }
        return limited ? "Copied with limited formatting" : "Copied Markdown"
    }

    @MainActor
    func publish(to board: NSPasteboard, expected: String, change: Int, isCurrent: () -> Bool) throws -> Bool {
        guard id == expected, isCurrent(), board.changeCount == change else { return false }
        try ClipboardCopy.write(text, to: board)
        return true
    }
}

struct EditorNoteCopyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "editor-note-copy", shouldDisplay: false)
    @OptionGroup var options: GlobalOptions
    @Argument var id: String
    @Argument var action: EditorNoteAction

    func run() throws {
        guard options.json, let target = EditorNoteCopyTarget(id), action != .backlinks else {
            throw NotesError("invalid_editor_note_action", "Use a note ID and a copy action with JSON output.")
        }
        let backend = try options.backends()
        let ref = "id:" + target.value
        func verify(_ note: NoteSummary) throws {
            guard target.matches(note.id), !note.isDeleted else {
                throw NotesError("editor_note_not_found", "Could not verify the note.")
            }
        }
        let value: String
        if action == .copyMarkdown {
            let note = try backend.reader.note(ref)
            try verify(note.summary)
            guard !note.summary.isLocked else { throw NotesError("note_locked", "This note is locked.") }
            value = try ClipboardCopy.markdown(note, includeAttachments: true)
        } else {
            let summary = try backend.reader.summary(ref)
            try verify(summary)
            value = try ClipboardCopy.noteLink(summary)
        }
        try Output.json(EditorNoteCopy(id: target.value, text: value, limited: backend.fidelity == .limited))
    }
}

struct EditorBacklinkDestination {
    let id: UUID

    @MainActor
    func dispatchIfCurrent(_ isCurrent: () -> Bool, open: (URL) -> Void) {
        var parts = URLComponents()
        parts.scheme = "applenotes"
        parts.host = "showNote"
        parts.queryItems = [URLQueryItem(name: "identifier", value: id.uuidString)]
        guard let url = parts.url, isCurrent() else { return }
        open(url)
    }
}

@MainActor
final class EditorCurrentNoteActions: NSObject {
    private var busy = false
    private var trackingMenu = false
    private var selection: String?
    private let toast = EditorToast()

    func showMenu() {
        guard !busy, !trackingMenu, let context = NotesEditorAccess.selection(requireText: false) else { return }
        let items = EditorNoteAction.allCases.map { ($0.title, $0.rawValue) }
        guard let raw = pick(items, at: NSEvent.mouseLocation),
              let action = EditorNoteAction(rawValue: raw) else { return }
        run(action, for: context)
    }

    func run(_ action: EditorNoteAction, for context: NotesEditorSelection, from bar: EditorNoteActionsBar? = nil) {
        guard !busy, isCurrent(context), let executable = Bundle.main.executableURL else { return }
        let client = PaletteClient(executable: executable, backend: nil)
        let id = context.noteID
        let reference = "id:" + id.uuidString
        let point = NSEvent.mouseLocation
        let change = NSPasteboard.general.changeCount
        busy = true
        Task { [self] in
            defer { busy = false }
            do {
                if action == .backlinks {
                    let rows = try await Task.detached { try client.backlinks(reference: reference) }.value
                    guard isCurrent(context) else { return }
                    let items = rows.compactMap { row -> (String, String)? in
                        guard !row.isDeleted, let id = UUID(uuidString: row.id.uuid) else { return nil }
                        return (row.title, id.uuidString)
                    }
                    guard !items.isEmpty else { toast.show("No backlinks", below: point); return }
                    if let bar {
                        bar.showBacklinks(items, for: context) { [weak self] source in
                            guard let self, !busy else { return }
                            openBacklink(source, from: context, at: point, allowPanelFocus: true)
                        }
                        return
                    }
                    guard let source = pick(items, at: point) else { return }
                    openBacklink(source, from: context, at: point, allowPanelFocus: false)
                } else {
                    let copy: EditorNoteCopy
                    if action == .copyLink {
                        // The focused editor provides the note UUID even when the scripting catalog only has a Core Data URI.
                        copy = EditorNoteCopy(id: id.uuidString, text: ClipboardCopy.noteLink(id))
                    } else {
                        copy = try await Task.detached { try client.copy(.uuid(id), action: action) }.value
                    }
                    guard try copy.publish(to: .general, expected: id.uuidString, change: change,
                                           isCurrent: { isCurrent(context) }) else { return }
                    toast.show(copy.confirmation(for: action), below: point)
                }
            } catch {
                if isCurrent(context) {
                    toast.show(action == .backlinks ? "Backlinks unavailable" : "Couldn’t copy note", below: point)
                }
            }
        }
    }

    private func isCurrent(_ context: NotesEditorSelection) -> Bool {
        NotesEditorAccess.selection(requireText: false)?.sameEditor(as: context) == true
    }

    private func openBacklink(_ source: String, from context: NotesEditorSelection, at point: NSPoint,
                              allowPanelFocus: Bool) {
        guard let id = UUID(uuidString: source), let notes = NSRunningApplication(processIdentifier: context.pid),
              notes.bundleIdentifier == NotesEditorAccess.bundleID, let app = notes.bundleURL else { return }
        let originalPID = context.pid
        let originalNote = context.noteID
        EditorBacklinkDestination(id: id).dispatchIfCurrent({
            allowPanelFocus ? NotesEditorAccess.matchesBacklinkContext(context) : isCurrent(context)
        }, open: { url in
            // No second read or subprocess between checking the window and submitting the URL.
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor in
                    guard let self, let current = NotesEditorAccess.selection(requireText: false),
                          current.pid == originalPID, current.noteID == originalNote else { return }
                    self.toast.show("Couldn’t open backlink", below: point)
                }
            }
        })
    }

    private func pick(_ items: [(String, String)], at point: NSPoint) -> String? {
        guard !trackingMenu else { return nil }
        trackingMenu = true
        selection = nil
        let menu = NSMenu()
        for (title, value) in items {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: nil)
        defer { selection = nil; trackingMenu = false }
        return selection
    }

    @objc private func choose(_ item: NSMenuItem) { selection = item.representedObject as? String }
}

@MainActor
final class EditorToast {
    private var toast: NSPanel?
    private var expiry: Timer?

    func dismiss() {
        expiry?.invalidate()
        toast?.orderOut(nil)
        toast = nil
        expiry = nil
    }

    func show(_ message: String, below point: NSPoint, duration: TimeInterval = 1.8) {
        dismiss()
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.sizeToFit()
        let width = label.frame.width + 24
        let height: CGFloat = 32
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let rect = screen?.visibleFrame else { return }
        let frame = NSRect(x: max(rect.minX, min(point.x, rect.maxX - width)),
                           y: max(rect.minY, min(point.y - height - 10, rect.maxY - height)),
                           width: width, height: height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = message
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        label.setFrameOrigin(NSPoint(x: 12, y: (height - label.frame.height) / 2))
        background.addSubview(label)
        panel.contentView = background
        panel.orderFrontRegardless()
        toast = panel
        expiry = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }
}
