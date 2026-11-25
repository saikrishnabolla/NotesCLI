import AppKit

@MainActor
final class EditorStatusMenu: NSObject {
    private let search: () -> Void
    private let updates: () -> Void
    private let quit: () -> Void
    private var statusItem: NSStatusItem?

    init(search: @escaping () -> Void, updates: @escaping () -> Void, quit: @escaping () -> Void) {
        self.search = search
        self.updates = updates
        self.quit = quit
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Search Notes…", #selector(searchNotes)),
                                ("Check for Updates…", #selector(checkForUpdates)),
                                ("Quit Notes CLI Editor", #selector(quitEditor))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Notes CLI Editor")
        icon?.isTemplate = true
        item.button?.image = icon
        if icon == nil { item.button?.title = ">_" }
        item.button?.setAccessibilityLabel("Notes CLI Editor")
        item.menu = menu()
        statusItem = item
    }

    func remove() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func searchNotes() { search() }
    @objc private func checkForUpdates() { updates() }
    @objc private func quitEditor() { quit() }
}
