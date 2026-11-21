import Foundation
import XCTest
@testable import notescli

final class PermissionGuideTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/tmp/Example User/Applications/Notes CLI.app")

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
