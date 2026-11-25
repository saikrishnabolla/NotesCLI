import AppKit
import XCTest
@testable import notescli

final class EditorSettingsTests: XCTestCase {
    func testToolbarMenuAppliesChangesInPlaceAndSurvivesRelaunch() throws {
        try withStore { store in
            try editor("--save-settings", "--actions", "bold,italic,underline",
                       "--no-markdown-shortcuts", "--notes-search-hotkey", "cmd+shift+p")
                .run(settingsStore: store)
            let initial = try store.load()
            try MainActor.assumeIsolated {
                _ = NSApplication.shared
                let toolbar = NotesEditorToolbar(try initial.validate().controls, typing: initial.typing,
                                                 showNoteActionsBar: false, toolbarSettings: store)
                @MainActor func displayed() -> [String] { toolbar.toolbarView.subviews.compactMap { $0.identifier?.rawValue } }
                XCTAssertEqual(displayed(), ["bold", "italic", "underline"])

                let customizer = EditorToolbarMenu()
                customizer.apply = toolbar.applyCustomization
                let menu = customizer.menu(for: try initial.validate().controls)
                let bold = try XCTUnwrap(menu.item(withTitle: "Bold")?.submenu)
                XCTAssertFalse(try XCTUnwrap(bold.item(withTitle: "Move Left")).isEnabled)
                bold.performActionForItem(at: bold.indexOfItem(withTitle: "Move Right"))
                XCTAssertEqual(displayed(), ["italic", "bold", "underline"])

                let revised = customizer.menu(for: try store.load().validate().controls)
                let underline = try XCTUnwrap(revised.item(withTitle: "Underline")?.submenu)
                underline.performActionForItem(at: underline.indexOfItem(withTitle: "Hide"))
                XCTAssertEqual(displayed(), ["italic", "bold"])

                let compact = customizer.menu(for: try store.load().validate().controls)
                let hidden = try XCTUnwrap(compact.item(withTitle: "Show Control")?.submenu)
                hidden.performActionForItem(at: hidden.indexOfItem(withTitle: "Bigger"))
                XCTAssertEqual(displayed(), ["italic", "bold", "bigger"])
                let reopened = try EditorSettingsStore(url: store.url).load()
                var expected = initial
                expected.actions = "italic,bold,bigger"
                XCTAssertEqual(reopened, expected)
                let replacement = NotesEditorToolbar(try reopened.validate().controls, typing: reopened.typing,
                                                     showNoteActionsBar: false, toolbarSettings: store)
                XCTAssertEqual(replacement.toolbarView.subviews.compactMap { $0.identifier?.rawValue }, displayed())
                let reset = customizer.menu(for: try reopened.validate().controls)
                reset.performActionForItem(at: reset.indexOfItem(withTitle: "Reset Toolbar"))
                XCTAssertEqual(displayed(), EditorToolbarControl.defaults.map(\.id))
                var resetSettings = initial
                resetSettings.actions = EditorSettings().actions
                XCTAssertEqual(try EditorSettingsStore(url: store.url).load(), resetSettings)
            }
        }
    }

    func testToolbarMenuCanRecoverFromAnEmptyLayout() throws {
        try MainActor.assumeIsolated {
            _ = NSApplication.shared
            let controls: [EditorToolbarControl] = [.format(.bold)]
            let menu = EditorToolbarMenu().menu(for: controls)
            let bold = try XCTUnwrap(menu.item(withTitle: "Bold")?.submenu)
            XCTAssertTrue(try XCTUnwrap(bold.item(withTitle: "Hide")).isEnabled)
            XCTAssertFalse(try XCTUnwrap(bold.item(withTitle: "Move Right")).isEnabled)
            let toolbar = NotesEditorToolbar(controls, typing: .init(), showNoteActionsBar: false, toolbarSettings: nil)
            toolbar.applyCustomization(.hide(.format(.bold)))
            XCTAssertEqual(toolbar.toolbarView.subviews.count, 1)
            toolbar.applyCustomization(.show(.format(.italic)))
            XCTAssertEqual(toolbar.toolbarView.subviews.compactMap { $0.identifier?.rawValue }, ["italic"])
        }
    }

    func testSaveReloadOverrideAndRestoreDefaults() throws {
        try withStore { store in
            XCTAssertEqual(try editor().settings(for: store), EditorSettings())
            try editor("--save-settings", "--no-markdown-shortcuts", "--actions", "italic,bold",
                       "--notes-search-hotkey", "cmd+shift+p", "--global-search-hotkey", "option+cmd+j")
                .run(settingsStore: store)

            let freshStore = EditorSettingsStore(url: store.url)
            let saved = try editor().settings(for: freshStore)
            XCTAssertFalse(saved.markdownShortcuts)
            XCTAssertTrue(saved.typing.slashCommands)
            XCTAssertEqual(saved.actions, "italic,bold")
            XCTAssertEqual(saved.notesSearchHotkey, "cmd+shift+p")
            XCTAssertEqual(saved.globalSearchHotkey, "option+cmd+j")

            let oneRun = try editor("--notes-search-hotkey", "cmd+p").settings(for: freshStore)
            XCTAssertEqual(oneRun, EditorSettings())
            XCTAssertEqual(try freshStore.load(), saved)

            try editor("--save-settings").run(settingsStore: freshStore)
            XCTAssertEqual(try editor().settings(for: freshStore), EditorSettings())
        }
    }

    func testMenuBarIconIsOffByDefaultAndPersistsAnExplicitChoice() throws {
        try withStore { store in
            XCTAssertFalse(try store.load().validate().showMenuBarIcon)
            XCTAssertFalse(try store.load().validate().automaticUpdateChecks)
            try editor("--save-settings", "--menu-bar-icon", "--automatic-update-checks").run(settingsStore: store)
            XCTAssertTrue(try store.load().validate().showMenuBarIcon)
            XCTAssertTrue(try store.load().validate().automaticUpdateChecks)
            XCTAssertFalse(try editor("--no-menu-bar-icon").settings(for: store).validate().showMenuBarIcon)
            XCTAssertTrue(try store.load().validate().showMenuBarIcon)
            try editor("--save-settings", "--no-menu-bar-icon").run(settingsStore: store)
            XCTAssertFalse(try store.load().validate().showMenuBarIcon)
        }
    }

    func testMenuBarActionsOpenSearchCheckForUpdatesAndQuitTheEditor() {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            var actions: [String] = []
            let controller = EditorStatusMenu(search: { actions.append("search") }, updates: { actions.append("updates") },
                                              quit: { actions.append("quit") })
            let menu = controller.menu()
            XCTAssertEqual(menu.items.map(\.title), ["Search Notes…", "Check for Updates…", "Quit Notes CLI Editor"])
            for index in menu.items.indices {
                menu.performActionForItem(at: index)
            }
            XCTAssertEqual(actions, ["search", "updates", "quit"])
        }
    }

    func testOpenAccessibilityRunsOnlyTheGuideAndDoesNotSaveSettings() throws {
        try withStore { store in
            var opened = 0
            func guide() { opened += 1 }
            try editor("--open-accessibility").run(settingsStore: store, accessibilityGuide: guide)
            XCTAssertEqual(opened, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
            for args in [["--open-accessibility", "--save-settings"], ["--open-accessibility", "--menu-bar-icon"]] {
                XCTAssertThrowsError(try EditorCommand.parse(args).run(settingsStore: store, accessibilityGuide: guide))
            }
            XCTAssertEqual(opened, 1)
        }
    }

    func testAccessibilityGuideOpensOnlyTheAccessibilityPane() {
        var calls: [[String]] = []
        var messages: [String] = []
        PermissionGuide.openEditorAccessibility(launch: { calls.append($0); return false },
                                                show: { messages.append($0) })
        XCTAssertEqual(calls, [["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]])
        XCTAssertEqual(messages.first, "In System Settings > Privacy & Security, look for Accessibility or Device Control and Data Access.")
    }

    func testInvalidSettingsDoNotOverwriteSavedSettings() throws {
        try withStore { store in
            try editor("--save-settings", "--no-slash-commands").run(settingsStore: store)
            let original = try Data(contentsOf: store.url)
            XCTAssertThrowsError(try editor("--save-settings", "--global-search-hotkey", "cmd+p")
                .run(settingsStore: store))
            XCTAssertThrowsError(try editor("--save-settings", "--show-settings").run(settingsStore: store))
            XCTAssertThrowsError(try editor("--show-settings", "--no-toolbar").run(settingsStore: store))
            XCTAssertEqual(try Data(contentsOf: store.url), original)
        }
    }

    func testManualUpdateCheckDoesNotReadSettingsOrStartEditor() throws {
        try withStore { store in
            let corrupt = Data("not editor settings".utf8)
            try corrupt.write(to: store.url)
            var checks = 0
            func check() -> String? { checks += 1; return nil }
            try editor("--check-for-updates").run(settingsStore: store, updateCheck: check)
            XCTAssertEqual(checks, 1)
            XCTAssertThrowsError(try editor("--check-for-updates", "--menu-bar-icon")
                .run(settingsStore: store, updateCheck: check))
            XCTAssertThrowsError(try editor("--check-for-updates", "--export-logs")
                .run(settingsStore: store, updateCheck: check))
            XCTAssertEqual(checks, 1)
            XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
        }
    }

    func testCorruptSettingsAreNotSilentlyUsedAndCanBeReset() throws {
        try withStore { store in
            try Data("{ incomplete".utf8).write(to: store.url)
            XCTAssertThrowsError(try editor().settings(for: store))
            try editor("--save-settings").run(settingsStore: store)
            XCTAssertEqual(try store.load(), EditorSettings())
        }
    }

    private func editor(_ arguments: String...) throws -> EditorCommand {
        try XCTUnwrap(NotesCLI.parseAsRoot(["editor"] + arguments) as? EditorCommand)
    }

    private func withStore(_ body: (EditorSettingsStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(EditorSettingsStore(url: directory.appendingPathComponent("editor-settings.json")))
    }
}
