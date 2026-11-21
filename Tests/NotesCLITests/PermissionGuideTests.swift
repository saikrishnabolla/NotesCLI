import AppKit
import Foundation
import XCTest
@testable import notescli

final class PermissionGuideTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/tmp/Example User/Applications/Notes CLI.app")

    func testAcceptedDropAdvancesButCancelledDropDoesNot() {
        XCTAssertEqual(PermissionStripStep.addApp.afterDrop([]), .addApp)
        XCTAssertEqual(PermissionStripStep.addApp.afterDrop(.copy), .enableAccess)
        XCTAssertEqual(PermissionStripStep.enableAccess.afterDrop([]), .enableAccess)
    }

    func testCompactGuideActionsAndInstructions() {
        let app = self.app
        MainActor.assumeIsolated {
            let view = PermissionStripContent(app: app)
            var revealed: URL?
            var dismissed = false
            view.onReveal = { revealed = $0 }
            view.onDismiss = { dismissed = true }
            let buttons = view.subviews.compactMap { $0 as? NSButton }
            let reveal = buttons.first { $0.title == "Show in Finder" }
            let skip = buttons.first { $0.title == "Already added?" }
            let dismiss = buttons.first { $0.accessibilityLabel() == "Dismiss" }
            @MainActor func checkLayout() {
                view.setFrameSize(view.preferredSize)
                view.layoutSubtreeIfNeeded()
                let labels = view.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
                XCTAssertEqual(labels.map(\.stringValue), [view.step.instruction])
                for label in labels {
                    XCTAssertTrue(view.bounds.contains(label.frame))
                    XCTAssertGreaterThanOrEqual(label.frame.width, label.intrinsicContentSize.width, label.stringValue)
                }
            }

            XCTAssertEqual(view.step, .addApp)
            checkLayout()
            reveal?.performClick(nil)
            XCTAssertEqual(revealed, app)
            XCTAssertEqual(view.step, .addApp)
            skip?.performClick(nil)
            XCTAssertEqual(view.step, .enableAccess)
            XCTAssertEqual(reveal?.isHidden, true)
            XCTAssertEqual(skip?.isHidden, true)
            XCTAssertFalse(dismissed, "The next instruction is not a successful permission check")
            checkLayout()
            dismiss?.performClick(nil)
            XCTAssertTrue(dismissed)
        }
    }

    func testOnlyLocalInteractiveCommandsShowPermissionGuide() {
        func allowed(json: Bool = false, input: Bool = true, output: Bool = true,
                     environment: [String: String] = [:]) -> Bool {
            OnboardingInteraction.canShowPermissionGuide(json: json, stdinIsTTY: input,
                                                          stdoutIsTTY: output, environment: environment)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(json: true))
        XCTAssertFalse(allowed(input: false))
        XCTAssertFalse(allowed(output: false))
        XCTAssertFalse(allowed(environment: ["SSH_CONNECTION": "remote"]))
        XCTAssertFalse(allowed(environment: ["SSH_TTY": "/dev/ttys001"]))
        XCTAssertFalse(allowed(environment: ["NOTESCLI_HOST_ACTIVE": "1"]))
    }

    func testOnboardOpensFullDiskAccessAndRevealsInstalledApp() {
        var commands: [[String]] = []
        var messages: [String] = []
        PermissionGuide.openFullDiskAccess(revealing: app, launch: { commands.append($0); return true },
                                           show: { messages.append($0) })
        XCTAssertEqual(commands, [
            ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"], ["-R", app.path],
        ])
        XCTAssertTrue(messages.contains { $0.contains("Drag it from the Finder window") })
        XCTAssertEqual(messages.last, "Then run 'notescli onboard' again.")
    }

    func testOnboardGivesManualStepsWhenWindowsCannotOpen() {
        var messages: [String] = []
        PermissionGuide.openFullDiskAccess(revealing: app, launch: { _ in false }, show: { messages.append($0) })
        XCTAssertTrue(messages.contains { $0.contains("System Settings > Privacy & Security > Full Disk Access") })
        XCTAssertTrue(messages.contains { $0.contains("open -R") })
    }

    func testOnboardDoesNotRevealAnAppForSourceBuilds() {
        var commands: [[String]] = []
        var messages: [String] = []
        PermissionGuide.openFullDiskAccess(revealing: nil, launch: { commands.append($0); return true },
                                           show: { messages.append($0) })
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(messages.contains { $0.contains("Terminal") })
    }
}
