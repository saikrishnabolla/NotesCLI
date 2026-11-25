import AppKit

@MainActor
final class EditorToolbarMenu: NSObject {
    enum Change: Equatable {
        case moveLeft(EditorToolbarControl)
        case moveRight(EditorToolbarControl)
        case hide(EditorToolbarControl)
        case show(EditorToolbarControl)
        case reset

        func layout(from controls: [EditorToolbarControl]) -> [EditorToolbarControl]? {
            var updated = controls
            switch self {
            case .reset:
                updated = EditorToolbarControl.defaults
            case .show(let control):
                guard !updated.contains(control) else { return nil }
                updated.append(control)
            case .hide(let control):
                guard let index = updated.firstIndex(of: control) else { return nil }
                updated.remove(at: index)
            case .moveLeft(let control), .moveRight(let control):
                guard let index = updated.firstIndex(of: control) else { return nil }
                let target = index + (self == .moveLeft(control) ? -1 : 1)
                guard updated.indices.contains(target) else { return nil }
                updated.swapAt(index, target)
            }
            return updated == controls ? nil : updated
        }
    }

    private final class MenuCommand: NSObject {
        let change: Change
        init(_ change: Change) { self.change = change }
    }

    var apply: ((Change) -> Void)?
    var chooseNoteAction: ((EditorNoteAction) -> Void)?

    func overflow(for controls: [EditorToolbarControl]) -> NSMenu {
        let root = NSMenu(title: "More Actions")
        let actions = EditorNoteAction.allCases.filter { !controls.contains(.note($0)) }
        for action in actions {
            let item = NSMenuItem(title: action.title, action: #selector(selectNoteAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            root.addItem(item)
        }
        if !actions.isEmpty { root.addItem(.separator()) }
        let customize = NSMenuItem(title: "Customize Toolbar", action: nil, keyEquivalent: "")
        root.addItem(customize)
        root.setSubmenu(menu(for: controls), for: customize)
        return root
    }

    func menu(for controls: [EditorToolbarControl]) -> NSMenu {
        let root = NSMenu(title: "Customize Toolbar")
        root.autoenablesItems = false
        for control in controls {
            let section = NSMenu(title: control.title)
            section.autoenablesItems = false
            section.addItem(item("Move Left", .moveLeft(control), controls))
            section.addItem(item("Move Right", .moveRight(control), controls))
            let hideTitle = if case .note = control { "Move to More Actions" } else { "Hide" }
            section.addItem(item(hideTitle, .hide(control), controls))
            let entry = NSMenuItem(title: control.title, action: nil, keyEquivalent: "")
            root.addItem(entry)
            root.setSubmenu(section, for: entry)
        }
        if !controls.isEmpty { root.addItem(.separator()) }
        let missing = EditorToolbarControl.available.filter { !controls.contains($0) }
        if !missing.isEmpty {
            let hidden = NSMenu(title: "Show Control")
            hidden.autoenablesItems = false
            for control in missing { hidden.addItem(item(control.title, .show(control), controls)) }
            let show = NSMenuItem(title: "Show Control", action: nil, keyEquivalent: "")
            root.addItem(show)
            root.setSubmenu(hidden, for: show)
        }
        root.addItem(item("Reset Toolbar", .reset, controls))
        return root
    }

    private func item(_ title: String, _ change: Change, _ controls: [EditorToolbarControl]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectChange(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = change.layout(from: controls) != nil
        item.representedObject = MenuCommand(change)
        return item
    }

    @objc private func selectChange(_ item: NSMenuItem) {
        guard item.isEnabled, let command = item.representedObject as? MenuCommand else { return }
        apply?(command.change)
    }

    @objc private func selectNoteAction(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let action = EditorNoteAction(rawValue: raw) else { return }
        chooseNoteAction?(action)
    }
}
