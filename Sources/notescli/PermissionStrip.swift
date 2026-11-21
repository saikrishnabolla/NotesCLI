import AppKit
import CoreGraphics
import Dispatch

enum PermissionStripStep: Equatable {
    case addApp
    case enableAccess

    var instruction: String {
        switch self {
        case .addApp: "Drag Notes CLI into the list"
        case .enableAccess: "Turn on Notes CLI in System Settings"
        }
    }

    func afterDrop(_ operation: NSDragOperation) -> Self {
        operation.contains(.copy) ? .enableAccess : self
    }
}

@MainActor
internal enum PermissionStrip {
    private static var running = false

    static func run(
        app: URL,
        openSettings: () -> Bool,
        probe: @escaping @Sendable () -> Bool
    ) -> Bool? {
        guard !running, app.isFileURL,
              FileManager.default.fileExists(atPath: app.path),
              !NSScreen.screens.isEmpty else { return nil }
        running = true
        defer { running = false }

        let application = NSApplication.shared
        let policy = application.activationPolicy()
        if policy == .prohibited {
            guard application.setActivationPolicy(.accessory) else { return nil }
        }
        defer {
            if policy == .prohibited { application.setActivationPolicy(policy) }
        }

        let session = StripSession(app: app, probe: probe)
        defer { session.stop() }
        guard openSettings() else { return nil }
        session.start()

        // A synchronous CLI caller has no AppKit event loop to dispatch clicks or drags.
        while !session.finished {
            if let event = application.nextEvent(
                matching: .any,
                until: Date(timeIntervalSinceNow: 0.1),
                inMode: .default,
                dequeue: true
            ) {
                application.sendEvent(event)
            }
        }
        return session.result
    }
}

@MainActor
private final class StripSession: NSObject {
    private static let settingsBundleID = "com.apple.systempreferences"
    private static let gap: CGFloat = 8

    private let panel: NSPanel
    private let content: PermissionStripContent
    private let check: StripProbe
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private var nextProbeAt: TimeInterval = 0
    private var shown = false
    private(set) var finished = false
    private(set) var result: Bool?

    init(app: URL, probe: @escaping @Sendable () -> Bool) {
        content = PermissionStripContent(app: app)
        panel = StripPanel(
            contentRect: content.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        check = StripProbe(probe)
        super.init()

        panel.title = "Notes CLI Permission Guide"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = content
        panel.invalidateShadow()
        content.onDismiss = { [weak self] in self?.finish(false) }
    }

    func start() {
        startedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        check.cancel()
        panel.close()
    }

    private func finish(_ value: Bool?) {
        guard !finished else { return }
        result = value
        finished = true
        panel.orderOut(nil)
    }

    private func tick() {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if check.takeResult() == true {
            finish(true)
            return
        }
        if !shown, now - startedAt >= 5 {
            finish(nil)
            return
        }
        if now - startedAt >= 180 {
            finish(false)
            return
        }

        let workspace = NSWorkspace.shared
        let foreground = workspace.frontmostApplication
        let settings: NSRunningApplication?
        if foreground?.bundleIdentifier == Self.settingsBundleID {
            settings = foreground
        } else if foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            settings = NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.settingsBundleID
            ).first { !$0.isTerminated }
        } else {
            settings = nil
        }

        if let settings,
           let bounds = Self.settingsWindow(pid: settings.processIdentifier),
           let frame = Self.placement(for: bounds, size: content.preferredSize) {
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
            shown = shown || panel.isVisible
        } else if panel.isVisible {
            panel.orderOut(nil)
        }

        if shown, now >= nextProbeAt, check.start() {
            nextProbeAt = now + 1
        }
    }

    private static func settingsWindow(pid: pid_t) -> CGRect? {
        // Window titles are unnecessary. PID, layer and bounds work without screen capture access.
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let mainDisplayTop = CGDisplayBounds(CGMainDisplayID()).maxY
        return windows.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerPID as String] as? Int == Int(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds),
                  bounds.width >= 300, bounds.height >= 240 else { return nil }
            return CGRect(
                x: bounds.minX, y: mainDisplayTop - bounds.maxY,
                width: bounds.width, height: bounds.height
            )
        }.first
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    private static func placement(for window: CGRect, size: CGSize) -> CGRect? {
        guard let screen = NSScreen.screens.max(by: {
            area($0.frame.intersection(window)) < area($1.frame.intersection(window))
        }), area(screen.frame.intersection(window)) > 0 else { return nil }
        let visible = screen.visibleFrame.insetBy(dx: gap, dy: gap)
        guard visible.width >= size.width, visible.height >= size.height else { return nil }
        let x = min(max(window.maxX - size.width, visible.minX), visible.maxX - size.width)
        let y = min(max(window.minY, visible.minY), visible.maxY - size.height)
        let candidates = [
            CGPoint(x: x, y: window.minY - gap - size.height),
            CGPoint(x: window.maxX + gap, y: y),
            CGPoint(x: window.minX - gap - size.width, y: y),
            CGPoint(x: x, y: window.maxY + gap)
        ]
        return candidates.lazy.map { CGRect(origin: $0, size: size) }.first {
            visible.contains($0)
        }
    }
}

@MainActor
private final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PermissionStripContent: NSVisualEffectView {
    private let app: URL
    private let drag: StripDragView
    private let tint = NSView()
    private let instruction = NSTextField(labelWithString: "")
    private let finder = StripButton(title: "Show in Finder", target: nil, action: nil)
    private let alreadyAdded = StripButton(title: "Already added?", target: nil, action: nil)
    private let dismiss = StripButton(frame: .zero)
    private(set) var step = PermissionStripStep.addApp
    var onDismiss: (() -> Void)?
    var onReveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    var preferredSize: CGSize {
        CGSize(width: step == .addApp ? 514 : 368, height: 54)
    }

    init(app: URL) {
        self.app = app
        drag = StripDragView(app: app, frame: .zero)
        super.init(frame: NSRect(x: 0, y: 0, width: 514, height: 54))
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.masksToBounds = true
        tint.wantsLayer = true
        tint.setAccessibilityElement(false)

        instruction.font = .systemFont(ofSize: 15, weight: .semibold)
        instruction.textColor = .labelColor
        instruction.lineBreakMode = .byTruncatingTail

        for (button, action) in [(finder, #selector(revealApp)), (alreadyAdded, #selector(showEnableStep))] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        dismiss.isBordered = false
        dismiss.imagePosition = .imageOnly
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        dismiss.contentTintColor = .secondaryLabelColor
        dismiss.setAccessibilityLabel("Dismiss")
        dismiss.target = self
        dismiss.action = #selector(dismissGuide)

        drag.onDrop = { [weak self] operation in
            guard let self else { return }
            setStep(step.afterDrop(operation))
        }
        for view in [tint, drag, instruction, finder, alreadyAdded, dismiss] { addSubview(view) }
        nextKeyView = alreadyAdded
        alreadyAdded.nextKeyView = finder
        finder.nextKeyView = dismiss
        dismiss.nextKeyView = alreadyAdded
        setStep(.addApp)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.82).cgColor
        }
        tint.frame = bounds
        let width = bounds.width
        dismiss.frame = NSRect(x: width - 36, y: 11, width: 28, height: 32)
        if step == .addApp {
            drag.frame = NSRect(x: 4, y: 0, width: 65, height: 54)
            finder.frame = NSRect(x: width - 137, y: 14, width: 99, height: 25)
            alreadyAdded.frame = NSRect(x: width - 238, y: 14, width: 98, height: 25)
            instruction.frame = NSRect(x: 70, y: 18, width: width - 318, height: 19)
        } else {
            drag.frame = NSRect(x: 4, y: 0, width: 46, height: 54)
            instruction.frame = NSRect(x: 54, y: 18, width: width - 96, height: 19)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func setStep(_ value: PermissionStripStep) {
        step = value
        let adding = value == .addApp
        instruction.stringValue = value.instruction
        drag.showsGrip = adding
        drag.toolTip = adding ? "Drag Notes CLI into Full Disk Access" : "Drag again if Notes CLI is not in the list"
        drag.menu = adding ? nil : retryMenu()
        alreadyAdded.isHidden = !adding
        finder.isHidden = !adding
        needsLayout = true
    }

    private func retryMenu() -> NSMenu {
        let menu = NSMenu()
        let retry = menu.addItem(withTitle: "Back to adding Notes CLI", action: #selector(showAddStep), keyEquivalent: "")
        retry.target = self
        return menu
    }

    @objc private func showAddStep() { setStep(.addApp) }
    @objc private func showEnableStep() { setStep(.enableAccess) }
    @objc private func revealApp() { onReveal(app) }
    @objc private func dismissGuide() { onDismiss?() }
}

private final class StripProbe: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "notescli.permission-strip.probe")
    private let lock = NSLock()
    private let probe: @Sendable () -> Bool
    private var inFlight = false
    private var cancelled = false
    private var result: Bool?

    init(_ probe: @escaping @Sendable () -> Bool) {
        self.probe = probe
    }

    func start() -> Bool {
        let ready = lock.withLock {
            guard !inFlight, !cancelled, result == nil else { return false }
            inFlight = true
            return true
        }
        guard ready else { return false }
        Self.queue.async { [self] in
            guard lock.withLock({ !cancelled }) else { return }
            let allowed = probe()
            lock.withLock {
                inFlight = false
                if !cancelled { result = allowed }
            }
        }
        return true
    }

    func takeResult() -> Bool? {
        lock.withLock {
            defer { result = nil }
            return result
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

@MainActor
private final class StripButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class StripDragView: NSView, NSDraggingSource {
    private let app: URL
    private let icon: NSImage
    private let grip = NSImageView(frame: NSRect(x: 46, y: 19, width: 14, height: 16))
    private var startPoint: NSPoint?
    var onDrop: ((NSDragOperation) -> Void)?
    var showsGrip = true { didSet { grip.isHidden = !showsGrip } }

    init(app: URL, frame: NSRect) {
        self.app = app
        icon = NSWorkspace.shared.icon(forFile: app.path)
        super.init(frame: frame)

        let image = NSImageView(frame: NSRect(x: 10, y: 11, width: 32, height: 32))
        image.image = icon
        image.imageScaling = .scaleProportionallyDown
        addSubview(image)

        grip.image = NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: nil)
        grip.contentTintColor = .secondaryLabelColor
        addSubview(grip)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        startPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let location = event.locationInWindow
        guard hypot(location.x - startPoint.x, location.y - startPoint.y) >= 3 else { return }
        self.startPoint = nil

        let point = convert(location, from: nil)
        let item = NSDraggingItem(pasteboardWriter: app as NSURL)
        item.setDraggingFrame(
            NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
            contents: icon
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // A drop can be accepted without permission being granted.
        onDrop?(operation)
    }
}
