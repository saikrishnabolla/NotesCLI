import AppKit
import CoreGraphics
import Dispatch

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
    private static let size = CGSize(width: 342, height: 48)
    private static let gap: CGFloat = 8

    private let panel: NSPanel
    private let check: StripProbe
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private var nextProbeAt: TimeInterval = 0
    private var shown = false
    private(set) var finished = false
    private(set) var result: Bool?

    init(app: URL, probe: @escaping @Sendable () -> Bool) {
        let frame = NSRect(origin: .zero, size: Self.size)
        panel = NSPanel(
            contentRect: frame,
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

        let background = NSVisualEffectView(frame: frame)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = background
        panel.invalidateShadow()

        let drag = StripDragView(app: app, frame: NSRect(x: 0, y: 0, width: 70, height: 48))
        background.addSubview(drag)

        let label = NSTextField(labelWithString: "Drag into Full Disk Access")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 73, y: (frame.height - label.frame.height) / 2)
        background.addSubview(label)

        let dismiss = StripDismissButton(frame: NSRect(x: 304, y: 8, width: 30, height: 32))
        dismiss.isBordered = false
        dismiss.imagePosition = .imageOnly
        dismiss.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        dismiss.contentTintColor = .secondaryLabelColor
        dismiss.setAccessibilityLabel("Dismiss")
        dismiss.target = self
        dismiss.action = #selector(dismissStrip)
        background.addSubview(dismiss)
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

    @objc private func dismissStrip() {
        finish(false)
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
           let frame = Self.placement(for: bounds) {
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

    private static func placement(for window: CGRect) -> CGRect? {
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
private final class StripDismissButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class StripDragView: NSView, NSDraggingSource {
    private let app: URL
    private let icon: NSImage
    private var startPoint: NSPoint?

    init(app: URL, frame: NSRect) {
        self.app = app
        icon = NSWorkspace.shared.icon(forFile: app.path)
        super.init(frame: frame)

        let image = NSImageView(frame: NSRect(x: 12, y: 9, width: 30, height: 30))
        image.image = icon
        image.imageScaling = .scaleProportionallyDown
        addSubview(image)

        let grip = NSImageView(frame: NSRect(x: 49, y: 16, width: 16, height: 16))
        grip.image = NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: nil)
        grip.contentTintColor = .tertiaryLabelColor
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
}
