import AppKit

@MainActor
final class EditorNoteActionsBar: NSObject {
    let panel: NSPanel
    var choose: ((EditorNoteAction, NotesEditorSelection) -> Void)?
    private var shownContext: NotesEditorSelection?
    private var backlinkPanel: NSPanel?
    private var backlinkReferences: [String] = []
    private var chooseBacklink: ((String) -> Void)?

    override init() {
        let frame = NSRect(x: 0, y: 0, width: 112, height: 34)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Notes Actions"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: frame)
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        for (index, action) in EditorNoteAction.allCases.enumerated() {
            let button = NSButton(frame: NSRect(x: 5 + 34 * index, y: 2, width: 34, height: 30))
            button.isBordered = false
            button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
            button.title = button.image == nil ? String(action.title.prefix(2)) : ""
            button.setAccessibilityLabel(action.title)
            button.toolTip = action.title
            button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            button.target = self
            button.action = #selector(press(_:))
            // Bind to the note shown when the click starts, not after a window switch on release.
            button.sendAction(on: .leftMouseDown)
            background.addSubview(button)
        }
        panel.contentView = background
    }

    func show(for context: NotesEditorSelection, in axViewport: CGRect) {
        let screens = NSScreen.screens
        guard let desktop = screens.first,
              let origin = Self.origin(for: panel.frame.size, in: axViewport, desktopTop: desktop.frame.maxY,
                                       visibleFrames: screens.map(\.visibleFrame)) else { hide(); return }
        if shownContext?.sameEditor(as: context) != true { hideBacklinks() }
        shownContext = context
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        positionBacklinks()
        if !panel.isVisible, backlinkPanel == nil { panel.orderFrontRegardless() }
    }

    func hide() {
        shownContext = nil
        hideBacklinks()
        if panel.isVisible { panel.orderOut(nil) }
    }

    func showBacklinks(_ items: [(String, String)], for context: NotesEditorSelection,
                       choose: @escaping (String) -> Void) {
        guard shownContext?.sameEditor(as: context) == true, panel.isVisible, !items.isEmpty else { return }
        hideBacklinks()
        let width: CGFloat = 260
        let row: CGFloat = 30
        let visibleRows = min(items.count, 7)
        let frame = NSRect(x: 0, y: 0, width: width, height: 34 + CGFloat(visibleRows) * row)
        let list = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        list.title = "Note Backlinks"
        list.level = .floating
        list.isOpaque = false
        list.backgroundColor = .clear
        list.hasShadow = true
        list.hidesOnDeactivate = false
        list.becomesKeyOnlyIfNeeded = true
        list.collectionBehavior = panel.collectionBehavior
        let background = NSVisualEffectView(frame: frame)
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        let title = NSTextField(labelWithString: "Backlinks")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 12, y: frame.height - 26, width: width - 50, height: 18)
        background.addSubview(title)
        let close = NSButton(title: "Close", target: self, action: #selector(closeBacklinks(_:)))
        close.frame = NSRect(x: width - 30, y: frame.height - 30, width: 25, height: 25)
        close.isBordered = false
        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Backlinks") {
            close.image = image
            close.imagePosition = .imageOnly
        }
        close.setAccessibilityLabel("Close Backlinks")
        background.addSubview(close)
        let scroll = NSScrollView(frame: NSRect(x: 5, y: 5, width: width - 10, height: CGFloat(visibleRows) * row))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = visibleRows < items.count
        scroll.autohidesScrollers = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(items.count) * row))
        for (index, item) in items.enumerated() {
            let button = NSButton(title: item.0, target: self, action: #selector(openBacklink(_:)))
            button.frame = NSRect(x: 6, y: CGFloat(items.count - index - 1) * row, width: document.frame.width - 12, height: row)
            button.alignment = .left
            button.isBordered = false
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = item.0
            button.tag = index
            button.sendAction(on: .leftMouseDown)
            document.addSubview(button)
        }
        scroll.documentView = document
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        background.addSubview(scroll)
        list.contentView = background
        backlinkReferences = items.map { $0.1 }
        chooseBacklink = choose
        backlinkPanel = list
        positionBacklinks()
        if backlinkPanel === list {
            panel.orderOut(nil)
            list.orderFrontRegardless()
        }
    }

    private func positionBacklinks() {
        guard let list = backlinkPanel else { return }
        guard let area = NSScreen.screens.first(where: { $0.visibleFrame.contains(panel.frame) })?.visibleFrame,
              let origin = Self.backlinksOrigin(for: list.frame.size, above: panel.frame, in: area) else {
            hideBacklinks()
            return
        }
        if list.frame.origin != origin { list.setFrameOrigin(origin) }
    }

    static func backlinksOrigin(for size: CGSize, above bar: CGRect, in area: CGRect) -> CGPoint? {
        let gap: CGFloat = 6
        guard size.width <= area.width, size.height <= area.height else { return nil }
        let above = bar.maxY + gap
        let below = bar.minY - gap - size.height
        let y = above + size.height <= area.maxY ? above : below
        guard y >= area.minY else { return nil }
        return CGPoint(x: min(area.maxX - size.width, max(area.minX, bar.maxX - size.width)), y: y)
    }

    private func hideBacklinks() {
        backlinkPanel?.orderOut(nil)
        backlinkPanel = nil
        chooseBacklink = nil
        backlinkReferences = []
    }

    static func origin(for size: NSSize, in axViewport: CGRect, desktopTop: CGFloat,
                       visibleFrames: [CGRect]) -> NSPoint? {
        guard !axViewport.isEmpty, !axViewport.isInfinite,
              axViewport.minX.isFinite, axViewport.maxY.isFinite else { return nil }
        let viewport = CGRect(x: axViewport.minX, y: desktopTop - axViewport.maxY,
                              width: axViewport.width, height: axViewport.height)
        let inset: CGFloat = 10
        let areas = visibleFrames.map { $0.intersection(viewport) }
            .filter { !$0.isEmpty && $0.width >= size.width + inset * 2 && $0.height >= size.height + inset * 2 }
        guard let area = areas.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return NSPoint(x: area.maxX - size.width - inset, y: area.minY + inset)
    }

    @objc private func press(_ sender: NSButton) {
        guard let action = sender.identifier.flatMap({ EditorNoteAction(rawValue: $0.rawValue) }),
              let context = shownContext else { return }
        choose?(action, context)
    }

    @objc private func closeBacklinks(_ sender: NSButton) {
        guard sender.window === backlinkPanel else { return }
        hideBacklinks()
    }

    @objc private func openBacklink(_ sender: NSButton) {
        guard sender.window === backlinkPanel, backlinkReferences.indices.contains(sender.tag),
              let choose = chooseBacklink else { return }
        let reference = backlinkReferences[sender.tag]
        choose(reference)
        hideBacklinks()
    }
}
