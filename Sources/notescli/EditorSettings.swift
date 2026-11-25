import Foundation
import NotesCore

struct EditorSettings: Codable, Equatable {
    private(set) var schemaVersion = 1
    var actions = EditorToolbarControl.defaults.map(\.id).joined(separator: ",")
    var notesSearchHotkey = "cmd+p"
    var globalSearchHotkey: String?
    var noteActionsHotkey = "ctrl+shift+cmd+n"
    var toolbar = true
    var hideNoteActionsBar: Bool?
    var showMenuBarIcon: Bool?
    var automaticUpdateChecks: Bool?
    var slashCommands = true
    var slashKeys = true
    var markdownShortcuts = true
    var disabledMarkdown: [String] = []

    var typing: EditorTypingOptions {
        EditorTypingOptions(slashCommands: slashCommands, slashKeys: slashKeys,
                            markdownShortcuts: markdownShortcuts,
                            disabledMarkdown: Set(disabledMarkdown.compactMap(NotesEditorAction.init(rawValue:))))
    }

    struct Validated {
        let controls: [EditorToolbarControl]
        let typing: EditorTypingOptions
        let notes: EditorHotkey?
        let global: EditorHotkey?
        let noteActions: EditorHotkey?
        let showToolbar: Bool
        let showNoteActionsBar: Bool
        let showMenuBarIcon: Bool
        let automaticUpdateChecks: Bool
    }

    func validate() throws -> Validated {
        let disabled = Set(disabledMarkdown.compactMap(NotesEditorAction.init(rawValue:)))
        guard schemaVersion == 1, disabled.count == disabledMarkdown.count,
              disabled.isSubset(of: EditorTrigger.markdownActions) else {
            throw NotesError("invalid_editor_settings", "Run 'notescli editor --save-settings' to restore defaults.")
        }
        let controls = try EditorToolbarControl.parse(actions)
        let notes = try notesSearchHotkey == "none" ? nil : EditorHotkey(notesSearchHotkey)
        let global = try globalSearchHotkey.map(EditorHotkey.init)
        let noteActions = try noteActionsHotkey == "none" ? nil : EditorHotkey(noteActionsHotkey)
        let bindings = [notes, global, noteActions].compactMap { $0 }
        guard Set(bindings).count == bindings.count else {
            throw NotesError("invalid_editor_hotkey", "Choose different shortcuts for search and note actions.")
        }
        let options = typing
        let showNoteActionsBar = hideNoteActionsBar != true
        let menuBar = showMenuBarIcon == true
        guard toolbar || showNoteActionsBar || menuBar || options.isEnabled || !bindings.isEmpty else {
            throw NotesError("invalid_editor_actions", "Turn on editor controls or a search shortcut.")
        }
        return .init(controls: toolbar ? controls : [], typing: options, notes: notes,
                     global: global, noteActions: noteActions, showToolbar: toolbar,
                     showNoteActionsBar: showNoteActionsBar, showMenuBarIcon: menuBar,
                     automaticUpdateChecks: automaticUpdateChecks == true)
    }
}

struct EditorSettingsStore: Sendable {
    let url: URL
    var record: (@Sendable (URL) throws -> Void)? = nil

    static var local: Self {
        Self(url: InstallManifest.applicationSupport.appendingPathComponent("editor-settings.json"),
             record: { try InstallManifest.recordFile($0, category: .config) })
    }

    func load() throws -> EditorSettings {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return EditorSettings() }
        guard let value = try? JSONDecoder().decode(EditorSettings.self, from: data) else {
            throw NotesError("invalid_editor_settings", "Run 'notescli editor --save-settings' to restore defaults.")
        }
        _ = try value.validate()
        return value
    }

    func save(_ value: EditorSettings) throws {
        _ = try value.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value) + Data("\n".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try record?(url)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func saveToolbar(_ controls: [EditorToolbarControl]) throws {
        var latest = try load()
        latest.actions = controls.map(\.id).joined(separator: ",")
        try save(latest)
    }
}
