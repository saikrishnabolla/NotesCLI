import AppKit
import SwiftUI

@MainActor
final class NotesCLIApplication: NSObject, NSApplicationDelegate {
    private let model: ControlCenterModel
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

    init(cliURL: URL) {
        model = ControlCenterModel(runner: CLIProcessRunner(executableURL: cliURL))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenuBarItem()
        showControlCenter()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlCenter()
        return true
    }

    @objc func showControlCenter() {
        let window = controlCenterWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refresh() {
        Task { await model.refresh() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func controlCenterWindow() -> NSWindow {
        if let window { return window }
        let controller = NSHostingController(rootView: ControlCenterView(model: model))
        // The window owns its size; changing pages should not resize it.
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.title = "Notes CLI"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 840, height: 540))
        window.contentMinSize = NSSize(width: 720, height: 510)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        return window
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NotesMenuBarIcon.make()
        item.button?.setAccessibilityLabel("Notes CLI")
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Notes CLI", action: #selector(showControlCenter), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let refresh = NSMenuItem(title: "Refresh Status", action: #selector(refresh), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Notes CLI", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }
}
