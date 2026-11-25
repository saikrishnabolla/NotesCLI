import AppKit
import XCTest
@testable import notescli

final class EditorSlashPanelTests: XCTestCase {
    func testSelectedRowResolvesNativeColorsAcrossAppearances() throws {
        try MainActor.assumeIsolated {
            _ = NSApplication.shared
            let row = EditorSlashRow(frame: NSRect(x: 0, y: 0, width: 226, height: 28))
            row.configure(for: try XCTUnwrap(EditorSlashChoice.exact("quote")))
            XCTAssertEqual(row.contentTintColor, .labelColor)
            row.keyboardSelected = true
            for name: NSAppearance.Name in [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                row.appearance = try XCTUnwrap(NSAppearance(named: name))
                row.viewDidChangeEffectiveAppearance()
                row.effectiveAppearance.performAsCurrentDrawingAppearance {
                    XCTAssertEqual(row.layer?.backgroundColor, NSColor.selectedContentBackgroundColor.cgColor)
                    XCTAssertEqual(row.contentTintColor, .alternateSelectedControlTextColor)
                }
            }
        }
    }

    func testPlacementLeadsWithTextAndClampsAtScreenEdges() throws {
        try MainActor.assumeIsolated {
            _ = NSApplication.shared
            guard let screen = NSScreen.screens.first else { throw XCTSkip("Requires a macOS desktop session.") }
            let area = screen.visibleFrame
            let desktop = screen.frame
            let size = CGSize(width: 238, height: 206)
            let anchor = CGRect(x: area.midX, y: desktop.maxY - area.midY, width: 38, height: 16)
            let toolbar = try XCTUnwrap(EditorPanelPlacement.origin(for: size, beside: anchor, preferBelow: false))
            let slash = try XCTUnwrap(EditorPanelPlacement.origin(for: size, beside: anchor, preferBelow: true))
            XCTAssertEqual(toolbar.x, anchor.minX)
            XCTAssertEqual(toolbar.y, area.midY + 7)
            XCTAssertEqual(slash.x, anchor.minX)
            XCTAssertEqual(slash.y, area.midY - anchor.height - size.height - 7)
            let edge = CGRect(x: area.maxX - 20, y: desktop.maxY - area.minY - 25, width: 12, height: 16)
            let clamped = try XCTUnwrap(EditorPanelPlacement.origin(for: size, beside: edge, preferBelow: true))
            XCTAssertEqual(clamped.x, area.maxX - size.width)
            XCTAssertEqual(clamped.y, area.minY + 32)
        }
    }

    func testToolbarStaysInPlaceThroughShortFormattingHandoffOnly() {
        let editor = AXUIElementCreateApplication(21)
        let window = AXUIElementCreateApplication(22)
        let original = NotesEditorSelection(pid: 21, noteID: UUID(), editor: editor, window: window,
                                            location: 5, length: 10)
        let otherNote = NotesEditorSelection(pid: 21, noteID: UUID(), editor: editor, window: window,
                                             location: 5, length: 10)
        let otherWindow = NotesEditorSelection(pid: 21, noteID: original.noteID, editor: editor,
                                               window: AXUIElementCreateApplication(23), location: 5, length: 10)
        let continuity = EditorToolbarContinuity(original, now: 1)
        func keeps(_ selection: NotesEditorSelection?, front: pid_t? = 21, now: TimeInterval = 1.1) -> Bool {
            continuity.keepsPanel(for: selection, frontPID: front, helperPID: 24, now: now)
        }
        XCTAssertTrue(keeps(original))
        XCTAssertTrue(keeps(nil))
        XCTAssertTrue(keeps(nil, front: 24))
        XCTAssertTrue(keeps(original.covering(NSRange(location: 15, length: 0))))
        XCTAssertFalse(keeps(original.covering(NSRange(location: 1, length: 3))))
        XCTAssertFalse(keeps(otherNote))
        XCTAssertFalse(keeps(otherWindow))
        XCTAssertFalse(keeps(nil, front: 23))
        XCTAssertFalse(keeps(nil, front: nil))
        XCTAssertFalse(keeps(nil, now: 1.31))
    }

    func testPanelKeepsNativeButtonsAndFullCommandRange() throws {
        try MainActor.assumeIsolated {
            let app = NSApplication.shared
            guard let screen = NSScreen.screens.first else { throw XCTSkip("Requires a macOS desktop session.") }
            let area = screen.visibleFrame
            let anchor = CGRect(x: area.midX, y: screen.frame.maxY - area.midY, width: 12, height: 16)
            let popup = EditorTriggerPanel()
            defer { popup.hide() }
            let template = EditorSlashChoice(label: "A long template title", aliases: [], action: .template(UUID()))
            let choices = EditorSlashChoice.choices + [template]
            for choice in choices {
                XCTAssertNotNil(NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil), choice.label)
            }
            var picks: [EditorSlashChoice] = []
            popup.choose = { picks.append($0) }
            popup.show(choices, beside: anchor)
            let window = try XCTUnwrap(app.windows.first { $0.title == "Notes Slash Commands" && $0.isVisible })
            XCTAssertFalse(window.isKeyWindow)
            let content = try XCTUnwrap(window.contentView)
            @MainActor func rows() -> [EditorSlashRow] { content.subviews.compactMap { $0 as? EditorSlashRow } }
            let first = try XCTUnwrap(rows().first)
            XCTAssertTrue(first.isAccessibilityElement())
            XCTAssertEqual(first.accessibilityRole(), .button)
            XCTAssertEqual(first.accessibilityLabel(), choices[0].label)
            XCTAssertTrue(first.isAccessibilitySelected())
            for (index, choice) in choices.enumerated() {
                let selected = try XCTUnwrap(rows().first { $0.keyboardSelected })
                XCTAssertEqual(rows().count, 7)
                XCTAssertTrue(rows().allSatisfy { $0.image?.size == NSSize(width: 20, height: 18) })
                XCTAssertEqual(Set(rows().compactMap { row in
                    (row.cell as? NSButtonCell)?.titleRect(forBounds: row.bounds).minX
                }).count, 1, "Symbols should not shift the text column.")
                XCTAssertEqual(selected.tag, index)
                XCTAssertEqual(selected.accessibilityLabel(), choice.label)
                XCTAssertTrue(selected.isAccessibilitySelected())
                popup.accept()
                XCTAssertEqual(picks.last, choice)
                popup.move(1)
                if index == 0 { XCTAssertTrue(rows().first === first) }
            }
            XCTAssertEqual(rows().first { $0.keyboardSelected }?.tag, 0)
            popup.move(-1)
            XCTAssertEqual(rows().last { $0.keyboardSelected }?.tag, choices.count - 1)
            let pointerChoice = try XCTUnwrap(rows().first)
            pointerChoice.performClick(nil)
            XCTAssertEqual(picks.last, choices[pointerChoice.tag])
            let accessibilityChoice = try XCTUnwrap(rows().dropFirst().first)
            XCTAssertTrue(accessibilityChoice.accessibilityPerformPress())
            XCTAssertEqual(picks.last, choices[accessibilityChoice.tag])
            XCTAssertEqual(rows().last { $0.keyboardSelected }?.tag, choices.count - 1)
            popup.show(EditorSlashChoice.matching("h2"), beside: anchor)
            XCTAssertEqual(rows().count, 1)
            popup.accept()
            XCTAssertEqual(picks.last?.action, .format(.heading))
        }
    }
}
