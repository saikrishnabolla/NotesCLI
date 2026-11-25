import AppKit
import ApplicationServices

enum EditorSlashAction: Equatable {
    case format(NotesEditorAction)
    case date
    case template(UUID)
}

struct EditorSlashChoice: Equatable {
    let label: String
    let aliases: [String]
    let action: EditorSlashAction

    static let choices: [Self] = [
        .init(label: "Title", aliases: ["title", "h1"], action: .format(.title)),
        .init(label: "Heading", aliases: ["heading", "h2"], action: .format(.heading)),
        .init(label: "Subheading", aliases: ["subheading", "h3"], action: .format(.subheading)),
        .init(label: "Body", aliases: ["body"], action: .format(.body)),
        .init(label: "Monostyled", aliases: ["monostyled", "code"], action: .format(.monostyled)),
        .init(label: "Checklist", aliases: ["checklist"], action: .format(.checklist)),
        .init(label: "Bulleted List", aliases: ["bulletedlist"], action: .format(.bulleted)),
        .init(label: "Dashed List", aliases: ["dashedlist"], action: .format(.dashed)),
        .init(label: "Numbered List", aliases: ["numberedlist"], action: .format(.numbered)),
        .init(label: "Block Quote", aliases: ["quote", "blockquote"], action: .format(.quote)),
        .init(label: "Table", aliases: ["table"], action: .format(.table)),
        .init(label: "Link", aliases: ["link"], action: .format(.link)),
        .init(label: "Align Left", aliases: ["left", "alignleft"], action: .format(.alignLeft)),
        .init(label: "Align Center", aliases: ["center", "centre", "aligncenter"], action: .format(.alignCenter)),
        .init(label: "Align Right", aliases: ["right", "alignright"], action: .format(.alignRight)),
        .init(label: "Justify", aliases: ["justify"], action: .format(.justify)),
        .init(label: "Today's Date", aliases: ["today", "date"], action: .date),
    ]

    static func matching(_ query: String) -> [Self] {
        let query = query.lowercased()
        return choices.filter { query.isEmpty || $0.aliases.contains { $0.hasPrefix(query) } }
            .sorted { ($0.aliases.contains(query) ? 0 : 1) < ($1.aliases.contains(query) ? 0 : 1) }
    }

    static func exact(_ query: String) -> Self? {
        choices.first { $0.aliases.contains(query.lowercased()) }
    }

    static func formattedDate(_ date: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current,
                              style: DateFormatter.Style = .short) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = style
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// A short hint from the local key listener, not proof of the text in Notes.
struct EditorSlashSequence {
    private var query: String?
    private var lastKey: TimeInterval = 0

    mutating func start(now: TimeInterval) { query = ""; lastKey = now }
    mutating func clear() { query = nil }

    mutating func append(_ key: String?, now: TimeInterval) {
        guard let query, let key, query.count < 20, now - lastKey < 0.45 else { clear(); return }
        self.query = query + key
        lastKey = now
    }

    func exactCommand(now: TimeInterval) -> (literal: String, choice: EditorSlashChoice)? {
        guard let query, now - lastKey < 0.45, let choice = EditorSlashChoice.exact(query) else { return nil }
        return ("/" + query, choice)
    }
}

struct EditorTypingOptions {
    let slashCommands: Bool
    let interceptsSlashKeys: Bool
    let markdownActions: Set<NotesEditorAction>

    var isEnabled: Bool { slashCommands || !markdownActions.isEmpty }

    init(slashCommands: Bool = true, slashKeys: Bool = true, markdownShortcuts: Bool = true,
         disabledMarkdown: Set<NotesEditorAction> = []) {
        self.slashCommands = slashCommands
        interceptsSlashKeys = slashCommands && slashKeys
        markdownActions = markdownShortcuts ? EditorTrigger.markdownActions.subtracting(disabledMarkdown) : []
    }
}

struct EditorTrigger: Equatable {
    enum Kind: Equatable {
        case slash(String)
        case markdown(NotesEditorAction)
    }
    let kind: Kind
    let literal: String
    let range: NSRange

    static let maximumPrefix = 96
    private static let markers: [String: NotesEditorAction] = [
        "# ": .title, "## ": .heading, "### ": .subheading, "[] ": .checklist,
        "``` ": .monostyled, "> ": .quote, "- ": .dashed, "* ": .bulleted, "1. ": .numbered,
    ]
    static let markdownActions = Set(markers.values)

    static func parse(prefix: String, endingAt caret: Int, atDocumentStart: Bool,
                      nextUnit: String?, allowMarkdown: Bool, allowTemplateQuery: Bool = false,
                      typing: EditorTypingOptions = .init()) -> Self? {
        guard caret >= prefix.utf16.count,
              let lastBreak = prefix.lastIndex(where: \.isNewline).map({ prefix.index(after: $0) })
                  ?? (atDocumentStart ? prefix.startIndex : nil) else { return nil }
        let line = prefix[lastBreak...].drop(while: { $0 == " " || $0 == "\t" })
        let literal = String(line)
        let anchor = NSRange(location: caret - literal.utf16.count, length: literal.utf16.count)
        if allowMarkdown, let action = markers[literal], typing.markdownActions.contains(action) {
            return Self(kind: .markdown(action), literal: literal, range: anchor)
        }
        guard nextUnit == nil || nextUnit?.first?.isNewline == true,
              typing.slashCommands, line.first == "/" else { return nil }
        let query = line.dropFirst()
        let knownCommand = query.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            && !EditorSlashChoice.matching(String(query)).isEmpty
        let templateQuery = allowTemplateQuery && query.allSatisfy({ $0 != "/" && !$0.isNewline && !$0.isASCIIControl })
        guard knownCommand || templateQuery else { return nil }
        return Self(kind: .slash(String(query)), literal: literal, range: anchor)
    }
}

private extension Character {
    var isASCIIControl: Bool {
        guard let asciiValue else { return false }
        return asciiValue < 32 || asciiValue == 127
    }
}

@MainActor
final class EditorSlashRow: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    var keyboardSelected = false { didSet { updateFill() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        hoverArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateFill()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateFill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = keyboardSelected ? NSColor.selectedControlColor.cgColor
                : hovered ? NSColor.labelColor.withAlphaComponent(0.14).cgColor : nil
        }
    }
}

@MainActor
final class EditorTriggerPanel: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 238, height: 40),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let background = NSVisualEffectView()
    private var choices: [EditorSlashChoice] = []
    private var selected = 0
    private var firstVisible = 0
    private let maxRows = 7
    private let rowHeight: CGFloat = 28
    var choose: ((EditorSlashChoice) -> Void)?
    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.title = "Notes Slash Commands"
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        panel.contentView = background
    }

    func show(_ choices: [EditorSlashChoice], beside axBounds: CGRect) {
        guard !choices.isEmpty else { hide(); return }
        if self.choices != choices || !isVisible {
            self.choices = choices
            selected = 0
            firstVisible = 0
            render()
        }
        guard let origin = EditorPanelPlacement.origin(for: panel.frame.size, beside: axBounds, preferBelow: true) else {
            hide()
            return
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    func move(_ delta: Int) {
        guard isVisible, !choices.isEmpty else { return }
        selected = (selected + delta + choices.count) % choices.count
        if selected < firstVisible { firstVisible = selected }
        if selected >= firstVisible + maxRows { firstVisible = selected - maxRows + 1 }
        render()
    }

    func accept() {
        guard isVisible, choices.indices.contains(selected) else { return }
        choose?(choices[selected])
    }

    private func render() {
        let rows = Array(choices.dropFirst(firstVisible).prefix(maxRows))
        let width = panel.frame.width
        let height = CGFloat(rows.count) * rowHeight + 10
        panel.setContentSize(NSSize(width: width, height: height))
        background.subviews.forEach { $0.removeFromSuperview() }
        for (index, choice) in rows.enumerated() {
            let row = EditorSlashRow(frame: NSRect(x: 6, y: height - 5 - CGFloat(index + 1) * rowHeight, width: width - 12, height: rowHeight))
            row.title = choice.label
            row.alignment = .left
            row.isBordered = false
            row.font = .systemFont(ofSize: 13, weight: firstVisible + index == selected ? .semibold : .regular)
            row.wantsLayer = true
            row.layer?.cornerRadius = 5
            row.keyboardSelected = firstVisible + index == selected
            row.tag = firstVisible + index
            row.target = self
            row.action = #selector(pick(_:))
            background.addSubview(row)
        }
    }

    @objc private func pick(_ button: NSButton) {
        guard choices.indices.contains(button.tag) else { return }
        choose?(choices[button.tag])
    }
}

@MainActor
enum EditorPanelPlacement {
    static func origin(for size: NSSize, beside axBounds: CGRect, preferBelow: Bool) -> NSPoint? {
        guard let desktop = NSScreen.screens.first else { return nil }
        let bounds = CGRect(x: axBounds.minX, y: desktop.frame.maxY - axBounds.maxY,
                            width: axBounds.width, height: axBounds.height)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(bounds) }) else { return nil }
        let area = screen.visibleFrame
        let above = bounds.maxY + 7
        let below = bounds.minY - size.height - 7
        let x = max(area.minX, min(bounds.midX - size.width / 2, area.maxX - size.width))
        let canGoAbove = above + size.height <= area.maxY
        let canGoBelow = below >= area.minY
        if preferBelow, canGoBelow { return NSPoint(x: x, y: below) }
        if canGoAbove { return NSPoint(x: x, y: above) }
        return canGoBelow ? NSPoint(x: x, y: below) : nil
    }
}
