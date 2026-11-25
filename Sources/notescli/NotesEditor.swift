import AppKit
import ApplicationServices
import ArgumentParser
import NotesCore
import NotesStore

struct EditorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "editor",
        abstract: "Add a formatting bar, typing shortcuts, and quick search to Apple Notes.",
        discussion: "Runs until you press Control-C in Terminal. Formatting and typing controls require Accessibility access."
    )

    @Option(help: "Comma-separated controls, in display order.")
    var actions: String?

    @Option(help: "Search shortcut in Notes (default: cmd+p). Use none to turn it off.")
    var notesSearchHotkey: String?

    @Option(help: "Optional search shortcut for all apps.")
    var globalSearchHotkey: String?

    @Option(help: "Shortcut for current-note actions in Notes (default: ctrl+shift+cmd+n). Use none to turn it off.")
    var noteActionsHotkey: String?

    @Flag(help: "Hide the selection toolbar.")
    var noToolbar = false

    @Flag(help: "Hide the current-note actions at the bottom of the editor.")
    var noNoteActionsBar = false

    @Flag(inversion: .prefixedNo, help: "Show a Notes CLI editor icon in the menu bar (off by default).")
    var menuBarIcon: Bool?

    @Flag(inversion: .prefixedNo, help: "Check for a new Notes CLI release at startup and daily (off by default).")
    var automaticUpdateChecks: Bool?

    @Flag(help: "Turn off slash commands and Markdown typing shortcuts.")
    var noTypingShortcuts = false

    @Flag(help: "Turn off slash commands, including templates.")
    var noSlashCommands = false

    @Flag(help: "Turn off Markdown typing shortcuts.")
    var noMarkdownShortcuts = false

    @Option(help: ArgumentHelp("Turn off specific Markdown shortcuts. Use comma-separated names: \(EditorCommand.markdownNames).",
                               valueName: "names"),
            transform: EditorCommand.parseDisabledMarkdown)
    var disableMarkdown: Set<NotesEditorAction> = []

    @Flag(help: "Choose slash commands with the pointer and leave arrow, Return, and Escape keys in Notes.")
    var noSlashKeys = false

    @Flag(help: "Print local editor diagnostics as JSON without starting the editor.")
    var exportLogs = false

    @Flag(help: "Check GitHub for a new release without starting the editor or installing anything.")
    var checkForUpdates = false

    @Flag(help: "Open Accessibility in System Settings without changing permissions.")
    var openAccessibility = false

    @Flag(help: "Replace saved editor settings with these options, or defaults if no options are given.")
    var saveSettings = false

    @Flag(help: "Print the saved editor settings, or defaults if none are saved.")
    var showSettings = false

    @Option(help: "Manage editor startup at login: enable, disable, or status.")
    var login: EditorLoginMode?

    private static let markdownNames = EditorTrigger.markdownActions.map(\.rawValue).sorted().joined(separator: ", ")

    private static func parseDisabledMarkdown(_ value: String) throws -> Set<NotesEditorAction> {
        let names = value.split(separator: ",", omittingEmptySubsequences: false)
        let actions = names.compactMap { NotesEditorAction(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        let distinct = Set(actions)
        guard !actions.isEmpty, distinct.count == names.count, distinct.isSubset(of: EditorTrigger.markdownActions) else {
            throw ValidationError("Use distinct Markdown shortcut names: \(markdownNames).")
        }
        return distinct
    }

    private var invocationSettings: EditorSettings {
        var settings = EditorSettings()
        settings.actions = actions ?? settings.actions
        settings.notesSearchHotkey = notesSearchHotkey ?? settings.notesSearchHotkey
        settings.globalSearchHotkey = globalSearchHotkey
        settings.noteActionsHotkey = noteActionsHotkey ?? settings.noteActionsHotkey
        settings.toolbar = !noToolbar
        settings.hideNoteActionsBar = noNoteActionsBar ? true : nil
        settings.showMenuBarIcon = menuBarIcon
        settings.automaticUpdateChecks = automaticUpdateChecks
        settings.slashCommands = !noTypingShortcuts && !noSlashCommands
        settings.slashKeys = !noSlashKeys
        settings.markdownShortcuts = !noTypingShortcuts && !noMarkdownShortcuts
        settings.disabledMarkdown = disableMarkdown.map(\.rawValue).sorted()
        return settings
    }

    var typingOptions: EditorTypingOptions { invocationSettings.typing }

    private var hasEditorOptions: Bool {
        actions != nil || notesSearchHotkey != nil || globalSearchHotkey != nil || noteActionsHotkey != nil ||
            noToolbar || noNoteActionsBar || noTypingShortcuts || noSlashCommands || noMarkdownShortcuts ||
            noSlashKeys || !disableMarkdown.isEmpty || menuBarIcon != nil || automaticUpdateChecks != nil
    }

    func settings(for store: EditorSettingsStore) throws -> EditorSettings {
        if saveSettings || hasEditorOptions { return invocationSettings }
        return try store.load()
    }

    func run() throws { try run(settingsStore: .local) }

    func run(settingsStore: EditorSettingsStore, updateCheck: () throws -> String? = EditorUpdates.checkFromCLI,
             accessibilityGuide: () throws -> Void = {
                 try ClipboardCopy.requireLocalSession()
                 PermissionGuide.openEditorAccessibility()
             }) throws {
        guard [exportLogs, checkForUpdates, openAccessibility, saveSettings, showSettings, login != nil]
            .filter({ $0 }).count <= 1 else {
            throw ValidationError("Choose one editor setup or diagnostics option at a time.")
        }
        guard !hasEditorOptions || !(exportLogs || checkForUpdates || openAccessibility || showSettings || login != nil) else {
            throw ValidationError("Editor options can only be used when starting the editor or with --save-settings.")
        }
        if exportLogs { try EditorDiagnostics.export(); return }
        if checkForUpdates {
            if let version = try updateCheck() {
                print("Notes CLI \(version) is available. If you installed with Homebrew, run brew upgrade notescli.")
            } else {
                print("Notes CLI is up to date.")
            }
            return
        }
        if openAccessibility { try accessibilityGuide(); return }
        if saveSettings { try settingsStore.save(invocationSettings); return }
        if showSettings { try Output.json(settingsStore.load()); return }
        if let login { try login.run(settingsStore: settingsStore); return }
        try ClipboardCopy.requireLocalSession()
        do {
            let configuration = try settings(for: settingsStore).validate()
            let lock = try EditorInstance.acquire()
            defer { close(lock) }
            try MainActor.assumeIsolated {
                try NotesEditorToolbar.run(configuration.controls, typing: configuration.typing,
                                           showToolbar: configuration.showToolbar,
                                           showNoteActionsBar: configuration.showNoteActionsBar,
                                           showMenuBarIcon: configuration.showMenuBarIcon,
                                           automaticUpdateChecks: configuration.automaticUpdateChecks,
                                           notes: configuration.notes, global: configuration.global,
                                           noteActions: configuration.noteActions,
                                           toolbarSettings: hasEditorOptions ? nil : settingsStore)
            }
        } catch {
            switch (error as? NotesError)?.code {
            case "accessibility_permission_denied": EditorDiagnostics.record(.accessibilityRequired)
            case "editor_unavailable": EditorDiagnostics.record(.desktopSessionUnavailable)
            case "invalid_editor_actions", "invalid_editor_hotkey": EditorDiagnostics.record(.invalidConfiguration)
            default: break
            }
            throw error
        }
    }
}

enum EditorLoginMode: String, ExpressibleByArgument {
    case enable, disable, status

    func run(settingsStore: EditorSettingsStore) throws {
        let job = EditorLogin.local
        switch self {
        case .enable:
            try ClipboardCopy.requireLocalSession()
            _ = try settingsStore.load()
            try job.enable { _ in HostInstallation.isCurrentInstall }
            print("Editor startup at login is enabled. If it cannot start, run 'notescli editor --export-logs'.")
        case .disable:
            try ClipboardCopy.requireLocalSession()
            try job.disable()
            print("Editor startup at login is disabled.")
        case .status:
            let enabled = try job.isEnabled()
            print(enabled ? "Enabled" : "Disabled")
            if enabled { print(job.runtimeStatus().message) }
        }
    }
}

enum NotesEditorAction: String, CaseIterable, Sendable {
    case title, heading, subheading, body, monostyled, bulleted, dashed, numbered, quote, checklist, table
    case bold, italic, underline, strikethrough, highlight, link, bigger, smaller
    case alignLeft = "align-left", alignCenter = "align-center", alignRight = "align-right", justify

    var shortcut: NotesMenuShortcut? {
        switch self {
        case .title: .init("t", 1)
        case .heading: .init("h", 1)
        case .subheading: .init("j", 1)
        case .body: .init("b", 1)
        case .monostyled: .init("m", 1)
        case .bulleted: .init("7", 1)
        case .dashed: .init("8", 1)
        case .numbered: .init("9", 1)
        case .quote: .init("'", 0)
        case .checklist: .init("l", 1)
        case .table: .init("t", 2)
        case .bold: .init("b", 0)
        case .italic: .init("i", 0)
        case .underline: .init("u", 0)
        case .strikethrough, .bigger, .smaller, .alignLeft, .alignCenter, .alignRight, .justify: nil
        case .highlight: .init("e", 1)
        case .link: .init("k", 0)
        }
    }

    var symbol: String {
        switch self {
        case .title: "textformat.size.larger"
        case .heading: "textformat.size"
        case .subheading: "textformat.size.smaller"
        case .body: "text.alignleft"
        case .monostyled: "chevron.left.forwardslash.chevron.right"
        case .bulleted: "list.bullet"
        case .dashed: "list.dash"
        case .numbered: "list.number"
        case .quote: "text.quote"
        case .checklist: "checklist"
        case .table: "tablecells"
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .bigger: "plus"
        case .smaller: "minus"
        case .alignLeft: "text.alignleft"
        case .alignCenter: "text.aligncenter"
        case .alignRight: "text.alignright"
        case .justify: "text.justify"
        case .highlight: "highlighter"
        case .link: "link"
        }
    }

    var menuPath: [String] {
        switch self {
        case .title: ["Format", "Title"]
        case .heading: ["Format", "Heading"]
        case .subheading: ["Format", "Subheading"]
        case .body: ["Format", "Body"]
        case .monostyled: ["Format", "Monostyled"]
        case .bulleted: ["Format", "Bulleted List"]
        case .dashed: ["Format", "Dashed List"]
        case .numbered: ["Format", "Numbered List"]
        case .quote: ["Format", "Block Quote"]
        case .checklist: ["Format", "Checklist"]
        case .table: ["Format", "Table"]
        case .bold: ["Format", "Font", "Bold"]
        case .italic: ["Format", "Font", "Italic"]
        case .underline: ["Format", "Font", "Underline"]
        case .strikethrough: ["Format", "Font", "Strikethrough"]
        case .bigger: ["Format", "Font", "Bigger"]
        case .smaller: ["Format", "Font", "Smaller"]
        case .alignLeft: ["Format", "Alignment", "Align Left"]
        case .alignCenter: ["Format", "Alignment", "Center"]
        case .alignRight: ["Format", "Alignment", "Align Right"]
        case .justify: ["Format", "Alignment", "Justify"]
        case .highlight: ["Format", "Font", "Highlight"]
        case .link: ["Edit", "Add Link…"]
        }
    }

    var menuPaths: [[String]] {
        let path = menuPath
        guard path.count == 3, path[1] == "Alignment" else { return [path] }
        return [path, ["Format", "Text", path[2]]]
    }

    static func parse(_ value: String) throws -> [Self] {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        let names = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        let controls = names.compactMap(Self.init(rawValue:))
        guard !controls.isEmpty, controls.count == names.count, Set(controls).count == controls.count else {
            throw NotesError("invalid_editor_actions", "Use distinct controls: \(allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return controls
    }
}

struct NotesMenuShortcut: Equatable {
    let key: String
    // AXMenuItemCmdModifiers: 0 includes Command; 1 adds Shift; 2 adds Option.
    let modifiers: Int
    init(_ key: String, _ modifiers: Int) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }
}

struct NotesEditorSelection: Equatable {
    let pid: pid_t
    let noteID: UUID
    let editor: AXUIElement
    let window: AXUIElement
    let location: Int
    let length: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sameEditor(as: rhs) && lhs.location == rhs.location && lhs.length == rhs.length
    }

    func sameEditor(as other: Self) -> Bool {
        pid == other.pid && noteID == other.noteID && CFEqual(editor, other.editor) && CFEqual(window, other.window)
    }

    func covering(_ range: NSRange) -> Self {
        Self(pid: pid, noteID: noteID, editor: editor, window: window, location: range.location, length: range.length)
    }

    static func noteID(_ identifier: String?) -> UUID? {
        guard let identifier, identifier.hasPrefix("Note[id="), identifier.hasSuffix("]") else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(8).dropLast()))
    }
}

@MainActor
enum EditorSlashReturn {
    static func finish(caret: NotesEditorSelection, trigger: EditorTrigger,
                       commit: () -> Bool, selection: () -> NotesEditorSelection?,
                       readTrigger: (NotesEditorSelection) -> EditorTrigger?, replay: () -> Void) {
        // A rejected command should behave like ordinary Return, but only if
        // Notes still has the original caret and unchanged command text.
        guard !commit(), selection() == caret, readTrigger(caret) == trigger,
              selection() == caret else { return }
        replay()
    }
}

@MainActor
struct NotesEditorAccess {
    static let bundleID = "com.apple.Notes"

    static func frontmostPID() -> pid_t? {
        guard let running = NSWorkspace.shared.frontmostApplication,
              running.bundleIdentifier == bundleID else { return nil }
        return running.processIdentifier
    }

    static func selection(requireText: Bool = true) -> NotesEditorSelection? {
        guard let pid = frontmostPID() else { return nil }
        return selection(inNotesPID: pid, requireText: requireText)
    }

    static func matchesBacklinkContext(_ context: NotesEditorSelection) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              (front.bundleIdentifier == bundleID && front.processIdentifier == context.pid)
                || front.processIdentifier == getpid() else { return false }
        // An accessibility click on our own panel can briefly activate this process.
        // Still require the exact editor and focused window in the original Notes process.
        return selection(inNotesPID: context.pid, requireText: false)?.sameEditor(as: context) == true
    }

    private static func selection(inNotesPID pid: pid_t, requireText: Bool) -> NotesEditorSelection? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let editor = element(attribute(app, kAXFocusedUIElementAttribute)),
              attribute(editor, kAXRoleAttribute) as? String == kAXTextAreaRole,
              let window = element(attribute(editor, kAXWindowAttribute)),
              let focusedWindow = element(attribute(app, kAXFocusedWindowAttribute)), CFEqual(window, focusedWindow),
              let noteID = NotesEditorSelection.noteID(attribute(editor, kAXIdentifierAttribute) as? String),
              let range = axValue(attribute(editor, kAXSelectedTextRangeAttribute), type: .cfRange) else { return nil }
        var offsets = CFRange()
        guard AXValueGetValue(range, .cfRange, &offsets), offsets.location >= 0, offsets.length >= 0,
              !requireText || offsets.length > 0 else { return nil }
        return NotesEditorSelection(pid: pid, noteID: noteID, editor: editor, window: window,
                                    location: offsets.location, length: offsets.length)
    }

    static func bounds(_ context: NotesEditorSelection) -> CGRect? {
        if let visible = axValue(attribute(context.editor, kAXVisibleCharacterRangeAttribute), type: .cfRange) {
            var offsets = CFRange()
            if AXValueGetValue(visible, .cfRange, &offsets), offsets.location >= 0, offsets.length >= 0,
               context.location.addingReportingOverflow(context.length).overflow == false,
               offsets.location.addingReportingOverflow(offsets.length).overflow == false,
               (context.location >= offsets.location + offsets.length
                || context.location + context.length <= offsets.location) { return nil }
        }
        var range = CFRange(location: context.location, length: context.length)
        guard let input = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(context.editor, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         input, &raw) == .success,
              let value = axValue(raw, type: .cgRect) else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &bounds), !bounds.isNull, !bounds.isInfinite,
              !bounds.isEmpty, bounds.minX.isFinite, bounds.minY.isFinite else { return nil }
        return bounds
    }

    static func noteViewport(_ context: NotesEditorSelection) -> CGRect? {
        func frame(_ node: AXUIElement) -> CGRect? {
            guard let position = axValue(attribute(node, kAXPositionAttribute), type: .cgPoint),
                  let size = axValue(attribute(node, kAXSizeAttribute), type: .cgSize) else { return nil }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
            let result = CGRect(origin: origin, size: dimensions)
            return result.isEmpty || result.isInfinite || !result.minX.isFinite || !result.minY.isFinite ? nil : result
        }
        guard let windowFrame = frame(context.window) else { return nil }
        var container = context.editor
        for _ in 0..<8 {
            guard let parent = element(attribute(container, kAXParentAttribute)), !CFEqual(parent, context.window) else { break }
            if attribute(parent, kAXRoleAttribute) as? String == kAXScrollAreaRole, let viewport = frame(parent) {
                return viewport.intersection(windowFrame)
            }
            container = parent
        }
        return frame(context.editor)?.intersection(windowFrame)
    }

    static func perform(_ action: NotesEditorAction, for context: NotesEditorSelection) -> Bool {
        guard selection(requireText: false) == context else { return false }
        let app = AXUIElementCreateApplication(context.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let bar = element(attribute(app, kAXMenuBarAttribute)),
              let item = uniqueMenuItem(action, in: bar) ?? (action == .link
                  ? uniqueMenuItem(paths: [["Edit", "Edit Link"]], shortcut: action.shortcut, in: bar) : nil),
              selection(requireText: false) == context else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    static func trigger(in context: NotesEditorSelection, allowMarkdown: Bool, typing: EditorTypingOptions) -> EditorTrigger? {
        guard context.length == 0,
              let count = attribute(context.editor, kAXNumberOfCharactersAttribute) as? Int,
              context.location > 0, context.location <= count else { return nil }
        let location = max(0, context.location - EditorTrigger.maximumPrefix)
        guard let prefix = string(in: NSRange(location: location, length: context.location - location),
                                  of: context.editor) else { return nil }
        var next: String?
        if context.location < count {
            guard let value = string(in: NSRange(location: context.location, length: 1), of: context.editor) else { return nil }
            next = value
        }
        return EditorTrigger.parse(prefix: prefix, endingAt: context.location, atDocumentStart: location == 0,
                                   nextUnit: next, allowMarkdown: allowMarkdown, allowTemplateQuery: true, typing: typing)
    }

    static func execute(_ action: EditorSlashAction, trigger: EditorTrigger, caret: NotesEditorSelection,
                        typing: EditorTypingOptions, template: EditorTemplatePayload? = nil,
                        templateFailure: ((EditorTemplateFailure) -> Void)? = nil) -> Bool {
        guard selection(requireText: false) == caret,
              self.trigger(in: caret, allowMarkdown: true, typing: typing) == trigger else { return false }
        let replacement: String
        var menu: AXUIElement?
        switch action {
        case .date: replacement = EditorSlashChoice.formattedDate()
        case .template:
            guard let template else { return false }
            replacement = template.text
        case .format(let format):
            let app = AXUIElementCreateApplication(caret.pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            guard let bar = element(attribute(app, kAXMenuBarAttribute)),
                  let item = uniqueMenuItem(format, in: bar) else { return false }
            menu = item
            replacement = ""
        }
        guard selection(requireText: false) == caret,
              self.trigger(in: caret, allowMarkdown: true, typing: typing) == trigger else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(caret.editor, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        func setRange(_ location: Int, _ length: Int) -> Bool {
            var range = CFRange(location: location, length: length)
            guard let span = AXValueCreate(.cfRange, &range) else { return false }
            return AXUIElementSetAttributeValue(caret.editor, kAXSelectedTextRangeAttribute as CFString, span) == .success
        }
        func hasSelectedTrigger() -> Bool {
            selection(requireText: false) == caret.covering(trigger.range)
                && attribute(caret.editor, kAXSelectedTextAttribute) as? String == trigger.literal
        }
        func selectTrigger() -> Bool {
            selection(requireText: false) == caret
                && setRange(trigger.range.location, trigger.range.length)
                && hasSelectedTrigger()
        }
        if let template, template.richText != nil || template.markdown != nil {
            // Nil means the Notes menu item was unavailable before we touched the note.
            func paste(_ data: Data, type: NSPasteboard.PasteboardType, action: String) throws -> Bool? {
                try EditorTemplatePaste.withData(data, type: type) { stillStaged in
                    let app = AXUIElementCreateApplication(caret.pid)
                    AXUIElementSetMessagingTimeout(app, 0.2)
                    guard let bar = element(attribute(app, kAXMenuBarAttribute)),
                          let paste = uniqueMenuItem(["Edit", action], in: bar) else {
                        return stillStaged() ? nil : false
                    }
                    guard stillStaged(), selectTrigger() else { return false }
                    guard hasSelectedTrigger(), stillStaged() else {
                        if hasSelectedTrigger() { _ = setRange(caret.location, caret.length) }
                        return false
                    }
                    guard AXUIElementPerformAction(paste, kAXPressAction as CFString) == .success else {
                        templateFailure?(.unconfirmed)
                        return false
                    }
                    // Notes can return from AXPress before it has read the pasteboard.
                    let first = template.text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces) ?? ""
                    let sample = type == .string ? String(first.prefix(48)) : template.text
                    let inserted = EditorTemplatePaste.confirmInsertion(sample: sample, at: trigger.range.location,
                                                                        stillStaged: stillStaged, read: { range in
                        guard let current = selection(requireText: false), current.sameEditor(as: caret) else { return nil }
                        return (NSRange(location: current.location, length: current.length),
                                string(in: range, of: current.editor))
                    })
                    if !inserted { templateFailure?(.unconfirmed) }
                    return inserted
                }
            }
            do {
                if let markdown = template.markdown,
                   let result = try paste(Data(markdown.utf8), type: .string, action: "Paste as Markdown") {
                    return result
                }
                if let richText = template.richText,
                   let result = try paste(richText.rtfd(expectedText: template.text), type: .rtfd, action: "Paste") {
                    return result
                }
                templateFailure?(.unavailable)
                return false
            } catch {
                templateFailure?(EditorTemplateFailure(error))
                return false
            }
        }
        guard selectTrigger(), AXUIElementSetAttributeValue(caret.editor, kAXSelectedTextAttribute as CFString,
                                                             replacement as CFString) == .success else { return false }
        guard let menu else { return true }
        // Never dispatch to a different editor even if Notes switched focus during the replacement.
        guard selection(requireText: false) == caret.covering(NSRange(location: trigger.range.location, length: 0)) else { return false }
        return AXUIElementPerformAction(menu, kAXPressAction as CFString) == .success
    }

    private static func string(in range: NSRange, of editor: AXUIElement) -> String? {
        var range = CFRange(location: range.location, length: range.length)
        guard let input = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(editor, kAXStringForRangeParameterizedAttribute as CFString,
                                                         input, &value) == .success else { return nil }
        return value as? String
    }

    private static func uniqueMenuItem(_ action: NotesEditorAction, in bar: AXUIElement) -> AXUIElement? {
        uniqueMenuItem(paths: action.menuPaths, shortcut: action.shortcut, in: bar)
    }

    private static func uniqueMenuItem(_ path: [String], in bar: AXUIElement) -> AXUIElement? {
        uniqueMenuItem(paths: [path], shortcut: nil, in: bar)
    }

    private static func uniqueMenuItem(paths: [[String]], shortcut: NotesMenuShortcut?, in bar: AXUIElement) -> AXUIElement? {
        var matches: [AXUIElement] = []
        func visit(_ parent: AXUIElement, paths: [[String]], component: Int, depth: Int) {
            guard depth < 7, matches.count < 2, !paths.isEmpty else { return }
            for item in attribute(parent, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                let role = attribute(item, kAXRoleAttribute) as? String
                if role == kAXMenuRole {
                    visit(item, paths: paths, component: component, depth: depth + 1)
                } else if role == kAXMenuBarItemRole || role == kAXMenuItemRole {
                    // Require both parts of the known menu identity. A shortcut alone may be remapped.
                    guard let title = attribute(item, kAXTitleAttribute) as? String else { continue }
                    let candidates = paths.filter { $0.count > component && $0[component] == title }
                    guard !candidates.isEmpty else { continue }
                    if candidates.contains(where: { $0.count == component + 1 }) {
                        var supported: CFArray?
                        if let shortcut {
                            guard let char = attribute(item, kAXMenuItemCmdCharAttribute) as? String,
                                  let modifiers = attribute(item, kAXMenuItemCmdModifiersAttribute) as? Int,
                                  NotesMenuShortcut(char, modifiers) == shortcut else { continue }
                        }
                        if attribute(item, kAXEnabledAttribute) as? Bool == true,
                           AXUIElementCopyActionNames(item, &supported) == .success,
                           (supported as? [String])?.contains(kAXPressAction) == true {
                            matches.append(item)
                        }
                    } else { visit(item, paths: candidates, component: component + 1, depth: depth + 1) }
                }
                if matches.count > 1 { return }
            }
        }
        visit(bar, paths: paths.flatMap { NotesMenuLocalization.system.paths(for: $0) }, component: 0, depth: 0)
        return matches.count == 1 ? matches[0] : nil
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axValue(_ value: CFTypeRef?, type: AXValueType) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let typed = value as! AXValue
        return AXValueGetType(typed) == type ? typed : nil
    }
}

@MainActor
final class NotesEditorToolbar: NSObject, NSApplicationDelegate {
    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private var controls: [EditorToolbarControl]
    private let showToolbar: Bool
    private let toolbarSettings: EditorSettingsStore?
    private let customize = EditorToolbarMenu()
    private var customizing = false
    private let typing: EditorTypingOptions
    private let slashPanel = EditorTriggerPanel()
    private let templateToast = EditorToast()
    private let keyTap = EditorKeyTap()
    private var lastEditor: NotesEditorSelection?
    private var pendingSpace: (NotesEditorSelection, TimeInterval)?
    private var visibleTrigger: (NotesEditorSelection, EditorTrigger)?
    private var dismissed: (NotesEditorSelection, EditorTrigger)?
    private var slashFreshness: TimeInterval = 0
    private var slashRefresh: Task<Void, Never>?
    private var slashSequence = EditorSlashSequence()
    private var slashOrigin: NotesEditorSelection?
    private var templateCatalog: (destination: UUID, loaded: TimeInterval, items: [EditorTemplate])?
    private var templateRequest: UUID?
    private var insertingTemplate = false
    private var timer: Timer?
    private var context: NotesEditorSelection?
    private var alignmentContext: NotesEditorSelection?
    private var picker: Process?
    private var hotkeys: EditorHotkeys?
    private let currentNoteActions = EditorCurrentNoteActions()
    private let noteActionsBar: EditorNoteActionsBar?
    private var statusMenu: EditorStatusMenu?
    private var automaticUpdateChecks = false
    private let updates = EditorUpdateChecks()
    private var activationObserver: NSObjectProtocol?

    static func run(_ controls: [EditorToolbarControl], typing: EditorTypingOptions, showToolbar: Bool, showNoteActionsBar: Bool,
                    showMenuBarIcon: Bool, automaticUpdateChecks: Bool,
                    notes: EditorHotkey?, global: EditorHotkey?, noteActions: EditorHotkey?,
                    toolbarSettings: EditorSettingsStore?) throws {
        guard !showToolbar && !typing.isEnabled && noteActions == nil && !showNoteActionsBar || AXIsProcessTrusted() else {
            throw NotesError("accessibility_permission_denied", "The editor needs Accessibility access.",
                             hint: "Run 'notescli editor --open-accessibility' to open System Settings.")
        }
        let app = NSApplication.shared
        guard !NSScreen.screens.isEmpty,
              app.activationPolicy() == .accessory || app.setActivationPolicy(.accessory) else {
            throw NotesError("editor_unavailable", "Run the editor controls in a macOS desktop session.")
        }
        let toolbar = NotesEditorToolbar(controls, typing: typing, showToolbar: showToolbar, showNoteActionsBar: showNoteActionsBar,
                                         toolbarSettings: toolbarSettings)
        toolbar.hotkeys = EditorHotkeys(notes: notes, global: global, noteActions: noteActions,
            openPalette: { [weak toolbar] in toolbar?.openPalette() },
            openNoteActions: { [weak toolbar] in toolbar?.currentNoteActions.showMenu() })
        toolbar.automaticUpdateChecks = automaticUpdateChecks
        if showMenuBarIcon {
            toolbar.statusMenu = EditorStatusMenu(search: { [weak toolbar] in toolbar?.openPalette() },
                                                  updates: { [weak toolbar] in toolbar?.updates.check(manual: true) },
                                                  quit: { app.stop(nil) })
        }
        app.delegate = toolbar
        withExtendedLifetime(toolbar) { app.run() }
        toolbar.keyTap.stop()
        toolbar.hotkeys?.stop()
        toolbar.statusMenu?.remove()
        toolbar.updates.stop()
        if let observer = toolbar.activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        app.delegate = nil
    }

    init(_ controls: [EditorToolbarControl], typing: EditorTypingOptions, showToolbar: Bool = true, showNoteActionsBar: Bool,
         toolbarSettings: EditorSettingsStore?) {
        self.controls = controls
        self.showToolbar = showToolbar
        self.toolbarSettings = toolbarSettings
        self.typing = typing
        noteActionsBar = showNoteActionsBar ? EditorNoteActionsBar() : nil
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 38),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        noteActionsBar?.choose = { [weak self] action, shownContext in
            guard let self else { return }
            currentNoteActions.run(action, for: shownContext, from: noteActionsBar)
        }
        slashPanel.choose = { [weak self] choice in self?.commitSlash(choice) }
        keyTap.receive = { [weak self] key in self?.handle(key) == true }
        keyTap.lost = { [weak self] in
            self?.pendingSpace = nil
            self?.clearSlashSequence()
            self?.slashRefresh?.cancel()
            self?.slashRefresh = nil
            self?.hideSlash()
        }
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = "Notes Formatting"
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        panel.contentView = background
        rebuildToolbar()
    }

    var toolbarView: NSView { background }

    private func rebuildToolbar() {
        panel.setContentSize(NSSize(width: CGFloat(34 * (controls.count + 1) + 12), height: 38))
        background.subviews = []
        guard showToolbar else { return }
        for (index, action) in controls.enumerated() {
            let button = action.makeButton(frame: NSRect(x: 6 + 34 * index, y: 4, width: 34, height: 30),
                                           target: self, action: #selector(apply(_:)))
            background.addSubview(button)
        }
        let more = NSButton(frame: NSRect(x: 6 + 34 * controls.count, y: 4, width: 34, height: 30))
        more.isBordered = false
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        more.title = more.image == nil ? "…" : ""
        more.setAccessibilityLabel("Customize Toolbar")
        more.toolTip = "Customize Toolbar"
        more.target = self
        more.action = #selector(showCustomization(_:))
        background.addSubview(more)
    }

    @objc private func showCustomization(_ sender: NSButton) {
        guard !customizing, let context, NotesEditorAccess.matchesBacklinkContext(context) else { return }
        customizing = true
        var requested: EditorToolbarMenu.Change?
        customize.apply = { requested = $0 }
        let anchor = sender.convert(NSPoint(x: sender.bounds.midX, y: sender.bounds.minY), to: nil)
        customize.menu(for: controls).popUp(positioning: nil, at: panel.convertPoint(toScreen: anchor), in: nil)
        customize.apply = nil
        customizing = false
        if let requested { applyCustomization(requested) }
        refresh()
    }

    func applyCustomization(_ change: EditorToolbarMenu.Change) {
        guard let layout = change.layout(from: controls) else { return }
        do { try toolbarSettings?.saveToolbar(layout) }
        catch {
            Output.error("Could not save the toolbar layout.")
            NSSound.beep()
            return
        }
        controls = layout
        rebuildToolbar()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeys?.start()
        statusMenu?.install()
        if automaticUpdateChecks { updates.startAutomaticChecks() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotkeys?.refresh()
                self?.refresh()
            }
        }
        guard showToolbar || typing.isEnabled || noteActionsBar != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func openPalette() {
        guard picker?.isRunning != true else { return }
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["palette"]
        if let active = NotesEditorAccess.selection(requireText: false) {
            process.arguments?.append(contentsOf: ["--selected-note", active.noteID.uuidString])
        }
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            picker = process
        } catch {
            EditorDiagnostics.record(.searchLaunchFailed)
            Output.error("Could not open the Notes search palette.")
        }
    }

    private func refresh() {
        guard !customizing else { return }
        let trusted = AXIsProcessTrusted()
        let directTyping = typing.isEnabled && trusted && EditorKeyTap.isDirectKeyboardLayout()
        if typing.isEnabled {
            keyTap.watch(directTyping ? NotesEditorAccess.frontmostPID() : nil, interceptNavigation: typing.interceptsSlashKeys)
        }
        guard showToolbar || typing.isEnabled || noteActionsBar != nil,
              trusted, let selected = NotesEditorAccess.selection(requireText: false) else {
            lastEditor = nil
            pendingSpace = nil
            clearSlashSequence()
            dismissed = nil
            hideSlash()
            hide()
            noteActionsBar?.hide()
            return
        }
        lastEditor = selected
        if let noteActionsBar {
            if let viewport = NotesEditorAccess.noteViewport(selected) { noteActionsBar.show(for: selected, in: viewport) }
            else { noteActionsBar.hide() }
        }
        if directTyping && selected.length == 0 { refreshTyping(selected) }
        else { hideSlash() }
        guard showToolbar, alignmentContext == nil, selected.length > 0, let bounds = NotesEditorAccess.bounds(selected),
              let origin = EditorPanelPlacement.origin(for: panel.frame.size, beside: bounds, preferBelow: false) else {
            hide()
            return
        }
        context = selected
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func refreshTyping(_ selected: NotesEditorSelection) {
        let now = ProcessInfo.processInfo.systemUptime
        let allowMarkdown = pendingSpace.map { $0.0.sameEditor(as: selected) && now - $0.1 < 0.38 } ?? false
        if !allowMarkdown { pendingSpace = nil }
        guard let command = NotesEditorAccess.trigger(in: selected, allowMarkdown: allowMarkdown, typing: typing) else {
            if dismissed?.0 != selected { dismissed = nil }
            hideSlash()
            return
        }
        if dismissed?.0 == selected && dismissed?.1 == command { return }
        dismissed = nil
        switch command.kind {
        case .markdown(let action):
            pendingSpace = nil
            hideSlash()
            _ = NotesEditorAccess.execute(.format(action), trigger: command, caret: selected, typing: typing)
        case .slash(let query):
            guard let bounds = NotesEditorAccess.bounds(selected.covering(command.range)) else { hideSlash(); return }
            loadTemplates(for: selected.noteID, now: now)
            let templates = templateCatalog?.destination == selected.noteID ? templateCatalog?.items ?? [] : []
            let choices = EditorSlashChoice.matching(query) + EditorTemplate.choices(templates, matching: query)
            guard !choices.isEmpty, !insertingTemplate else { hideSlash(); return }
            visibleTrigger = (selected, command)
            slashPanel.show(choices, beside: bounds)
            slashFreshness = ProcessInfo.processInfo.systemUptime
        }
    }

    private func loadTemplates(for destination: UUID, now: TimeInterval) {
        if let catalog = templateCatalog, catalog.destination == destination, now - catalog.loaded < 15 { return }
        guard !insertingTemplate, templateRequest == nil, let executable = Bundle.main.executableURL else { return }
        templateRequest = destination
        let client = PaletteClient(executable: executable, backend: nil)
        let request = Task.detached { () throws -> [EditorTemplate] in
            try client.templates(destination: destination)
        }
        Task {
            let items: [EditorTemplate] = (try? await request.value) ?? []
            templateRequest = nil
            guard lastEditor?.noteID == destination else { return }
            templateCatalog = (destination, ProcessInfo.processInfo.systemUptime, items)
            refresh()
        }
    }

    private func handle(_ input: EditorKeyTap.Input) -> Bool {
        guard !customizing else { return false }
        let key = input.key
        let now = ProcessInfo.processInfo.systemUptime
        if key == .slash, typing.interceptsSlashKeys, let lastEditor {
            slashSequence.start(now: now)
            slashOrigin = lastEditor
        } else if key == .other {
            slashSequence.append(input.letterOrDigit, now: now)
        } else if key != .accept {
            clearSlashSequence()
        }
        if key == .other || key == .slash {
            slashFreshness = 0
            pendingSpace = nil
            if typing.slashCommands, key == .slash || visibleTrigger != nil || slashRefresh != nil {
                refreshSlashAfterTyping()
            }
            return false
        }
        if key == .space {
            if let lastEditor, lastEditor.length == 0 {
                if !typing.markdownActions.isEmpty {
                    pendingSpace = (lastEditor, ProcessInfo.processInfo.systemUptime)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in self?.refresh() }
            }
            return false
        }
        let freshMenu = slashPanel.isVisible && now - slashFreshness < 0.3
        if key == .accept {
            let exact = slashSequence.exactCommand(now: now)
            let origin = slashOrigin
            clearSlashSequence()
            if !freshMenu, let exact, let origin, let code = input.returnCode, !insertingTemplate {
                acceptFastSlash(exact.choice, literal: exact.literal, origin: origin, returnCode: code)
                return true
            }
        }
        guard freshMenu, let pending = visibleTrigger else { return false }
        // Do not call into Notes from the event-tap callback. It has not yet received this event.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visibleTrigger?.0 == pending.0, self.visibleTrigger?.1 == pending.1 else { return }
            switch key {
            case .up: self.slashPanel.move(-1)
            case .down: self.slashPanel.move(1)
            case .accept: self.slashPanel.accept()
            case .dismiss:
                self.dismissed = pending
                self.hideSlash()
            case .space, .slash, .other: break
            }
        }
        return true
    }

    private func clearSlashSequence() {
        slashSequence.clear()
        slashOrigin = nil
    }

    private func acceptFastSlash(_ choice: EditorSlashChoice, literal: String, origin: NotesEditorSelection,
                                 returnCode: CGKeyCode) {
        Task { [weak self] in
            guard let self else { return }
            // An exact built-in is the only reason to defer Return. Verify the
            // real text and caret after Notes receives the preceding keystroke.
            for attempt in 0...2 {
                guard let caret = NotesEditorAccess.selection(requireText: false), caret.sameEditor(as: origin) else {
                    return
                }
                if EditorKeyTap.isDirectKeyboardLayout(),
                   let trigger = NotesEditorAccess.trigger(in: caret, allowMarkdown: false, typing: self.typing),
                   trigger.literal == literal, self.dismissed?.0 != caret || self.dismissed?.1 != trigger {
                    EditorSlashReturn.finish(caret: caret, trigger: trigger, commit: {
                        self.commitSlash(choice, caret: caret, trigger: trigger)
                    }, selection: {
                        NotesEditorAccess.selection(requireText: false)
                    }, readTrigger: {
                        NotesEditorAccess.trigger(in: $0, allowMarkdown: false, typing: self.typing)
                    }, replay: {
                        EditorKeyTap.forwardReturn(returnCode, to: caret.pid)
                    })
                    return
                }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(8)) }
            }
            guard NotesEditorAccess.selection(requireText: false)?.sameEditor(as: origin) == true else { return }
            EditorKeyTap.forwardReturn(returnCode, to: origin.pid)
        }
    }

    private func refreshSlashAfterTyping() {
        guard slashRefresh == nil, let origin = lastEditor else { return }
        slashRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(24)) } catch { return }
            guard let self else { return }
            self.slashRefresh = nil
            // Read after Notes receives the key. Never perform AX work in the tap
            // or use a trigger from a different window or text selection.
            guard EditorKeyTap.isDirectKeyboardLayout(),
                  let caret = NotesEditorAccess.selection(requireText: false),
                  caret.length == 0, caret.sameEditor(as: origin) else { return }
            self.refreshTyping(caret)
        }
    }

    private func commitSlash(_ choice: EditorSlashChoice) {
        guard let (caret, trigger) = visibleTrigger else { return }
        commitSlash(choice, caret: caret, trigger: trigger)
    }

    @discardableResult
    private func commitSlash(_ choice: EditorSlashChoice, caret: NotesEditorSelection, trigger: EditorTrigger) -> Bool {
        dismissed = (caret, trigger)
        hideSlash()
        if case .template(let source) = choice.action {
            guard !insertingTemplate, let executable = Bundle.main.executableURL else { return false }
            insertingTemplate = true
            let client = PaletteClient(executable: executable, backend: nil)
            let destination = caret.noteID
            let point = NotesEditorAccess.bounds(caret.covering(trigger.range)).flatMap { bounds in
                NSScreen.screens.first.map { NSPoint(x: bounds.minX, y: $0.frame.maxY - bounds.maxY) }
            } ?? NSEvent.mouseLocation
            let request = Task.detached { () throws -> EditorTemplatePayload in
                try client.template(destination: destination, source: source)
            }
            Task {
                defer { insertingTemplate = false }
                do {
                    let payload = try await request.value
                    var failure: EditorTemplateFailure?
                    if !NotesEditorAccess.execute(choice.action, trigger: trigger, caret: caret, typing: typing,
                                                  template: payload, templateFailure: { failure = $0 }),
                       let failure {
                        showTemplateFailure(failure, for: caret, below: point)
                    }
                } catch { showTemplateFailure(.preparation, for: caret, below: point) }
            }
            return true
        }
        let applied = NotesEditorAccess.execute(choice.action, trigger: trigger, caret: caret, typing: typing)
        if !applied { NSSound.beep() }
        return applied
    }

    private func showTemplateFailure(_ failure: EditorTemplateFailure, for caret: NotesEditorSelection, below point: NSPoint) {
        EditorDiagnostics.record(failure.event)
        guard NotesEditorAccess.selection(requireText: false)?.sameEditor(as: caret) == true else { return }
        templateToast.show(failure.message, below: point, duration: 3.8)
    }

    private func hideSlash() {
        visibleTrigger = nil
        slashPanel.hide()
    }

    private func hide() {
        context = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    @objc private func apply(_ sender: NSButton) {
        guard let action = sender.identifier.flatMap({ EditorToolbarControl($0.rawValue) }),
              let context else { return }
        hide()
        switch action {
        case .format(let value):
            if !NotesEditorAccess.perform(value, for: context) { NSSound.beep() }
        case .note(let value): currentNoteActions.run(value, for: context)
        case .alignment:
            let anchor = sender.convert(NSPoint(x: sender.bounds.midX, y: sender.bounds.minY), to: nil)
            showAlignment(at: panel.convertPoint(toScreen: anchor), for: context)
        }
    }

    private func showAlignment(at point: NSPoint, for context: NotesEditorSelection) {
        guard alignmentContext == nil, NotesEditorAccess.selection() == context else { return }
        alignmentContext = context
        defer { alignmentContext = nil }
        let menu = NSMenu()
        let choices: [NotesEditorAction] = [.alignLeft, .alignCenter, .alignRight, .justify]
        for choice in choices {
            let item = NSMenuItem(title: EditorToolbarControl.format(choice).title,
                                  action: #selector(applyAlignment(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    @objc private func applyAlignment(_ item: NSMenuItem) {
        guard let context = alignmentContext, let raw = item.representedObject as? String,
              let action = NotesEditorAction(rawValue: raw) else { return }
        if !NotesEditorAccess.perform(action, for: context) { NSSound.beep() }
    }
}
