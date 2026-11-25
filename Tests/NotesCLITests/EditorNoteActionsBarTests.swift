import AppKit
import ApplicationServices
import XCTest
@testable import notescli

private final class ToolbarButtonTarget: NSObject {
    @objc func pressed(_ sender: NSButton) {}
}

final class EditorNoteActionsBarTests: XCTestCase {
    func testSelectionToolbarActsOnPressExceptForTheNativeAlignmentMenu() {
        MainActor.assumeIsolated {
            let target = ToolbarButtonTarget()
            let controls: [EditorToolbarControl] = [.format(.bold), .alignment, .note(.backlinks)]
            for control in controls {
                let button = control.makeButton(frame: .zero, target: target, action: #selector(ToolbarButtonTarget.pressed(_:)))
                let previous = button.sendAction(on: .leftMouseUp)
                let expected = control == .alignment ? NSEvent.EventTypeMask.leftMouseUp : .leftMouseDown
                XCTAssertEqual(previous, Int(expected.rawValue))
                XCTAssertEqual(button.identifier?.rawValue, control.id)
            }
        }
    }

    func testBacklinkDispatchRechecksTheWindowAndUsesExactSourceUUID() {
        MainActor.assumeIsolated {
            let editor = AXUIElementCreateApplication(getpid())
            let note = NotesEditorSelection(pid: getpid(), noteID: UUID(), editor: editor, window: editor,
                                            location: 0, length: 0)
            let otherWindow = NotesEditorSelection(pid: note.pid, noteID: note.noteID, editor: editor,
                                                  window: AXUIElementCreateSystemWide(), location: 0, length: 0)
            let source = EditorBacklinkDestination(id: UUID())
            var destinations: [URL] = []
            var focused = otherWindow
            source.dispatchIfCurrent({ note.sameEditor(as: focused) }) { destinations.append($0) }
            XCTAssertTrue(destinations.isEmpty)
            focused = note
            source.dispatchIfCurrent({ note.sameEditor(as: focused) }) { destinations.append($0) }
            XCTAssertEqual(destinations.map(\.absoluteString), ["applenotes://showNote?identifier=\(source.id.uuidString)"])
        }
    }

    func testBacklinksPanelFitsAboveBarOrFallsBackBelowIt() {
        MainActor.assumeIsolated {
            let screen = CGRect(x: 100, y: 100, width: 400, height: 400)
            let size = CGSize(width: 260, height: 120)
            let low = CGRect(x: 112, y: 112, width: 112, height: 34)
            let high = CGRect(x: 380, y: 448, width: 112, height: 34)
            XCTAssertEqual(EditorNoteActionsBar.backlinksOrigin(for: size, above: low, in: screen),
                           CGPoint(x: 100, y: 152))
            XCTAssertEqual(EditorNoteActionsBar.backlinksOrigin(for: size, above: high, in: screen),
                           CGPoint(x: 232, y: 322))
            XCTAssertNil(EditorNoteActionsBar.backlinksOrigin(for: CGSize(width: 260, height: 350),
                                                              above: high, in: screen))
        }
    }

    func testBottomBarStaysInVisiblePartOfTheNote() {
        MainActor.assumeIsolated {
            let viewport = CGRect(x: 750, y: 300, width: 400, height: 360)
            let screen = CGRect(x: 0, y: 350, width: 1000, height: 650)
            let size = CGSize(width: 112, height: 34)
            XCTAssertEqual(EditorNoteActionsBar.origin(for: size, in: viewport, desktopTop: 1000,
                                                      visibleFrames: [screen]), CGPoint(x: 878, y: 360))
            XCTAssertNil(EditorNoteActionsBar.origin(for: size, in: viewport, desktopTop: 1000,
                                                    visibleFrames: [CGRect(x: 0, y: 350, width: 820, height: 650)]))
        }
    }

    func testSameNoteInADifferentWindowDoesNotMatchTheDisplayedContext() {
        let element = AXUIElementCreateApplication(getpid())
        let first = NotesEditorSelection(pid: getpid(), noteID: UUID(), editor: element, window: element,
                                         location: 5, length: 0)
        let changedWindow = NotesEditorSelection(pid: first.pid, noteID: first.noteID, editor: element,
                                                 window: AXUIElementCreateSystemWide(), location: 5, length: 0)
        XCTAssertFalse(first.sameEditor(as: changedWindow))
        XCTAssertTrue(first.sameEditor(as: first.covering(NSRange(location: 10, length: 2))))
    }

    func testNoteActionsBarCanBeDisabledWithoutDisablingTheSelectionBar() throws {
        let command = try XCTUnwrap(NotesCLI.parseAsRoot(["editor", "--no-note-actions-bar"]) as? EditorCommand)
        let config = try command.settings(for: .local).validate()
        XCTAssertFalse(config.showNoteActionsBar)
        XCTAssertFalse(config.controls.isEmpty)
    }
}
