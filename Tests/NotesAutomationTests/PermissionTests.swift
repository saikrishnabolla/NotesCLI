import ApplicationServices
import XCTest
import NotesCore
@testable import NotesAutomation

final class PermissionTests: XCTestCase {
    func testCheckNeverRequestsAConsentPrompt() throws {
        var calls: [Bool] = []
        try NotesAutomationPermission.check { askUserIfNeeded in
            calls.append(askUserIfNeeded)
            return noErr
        }
        XCTAssertEqual(calls, [false])
    }

    func testRequestPromptsThenVerifiesWithoutPrompting() throws {
        var calls: [Bool] = []
        try NotesAutomationPermission.request { askUserIfNeeded in
            calls.append(askUserIfNeeded)
            return noErr
        }
        XCTAssertEqual(calls, [true, false])
    }

    func testRequestFailsWhenPromptReturnsSuccessButPreflightRemainsUnknown() {
        var statuses: [OSStatus] = [noErr, -1744]
        XCTAssertThrowsError(try NotesAutomationPermission.request { _ in statuses.removeFirst() }) { error in
            XCTAssertEqual((error as? NotesError)?.code, "automation_denied")
        }
        XCTAssertTrue(statuses.isEmpty)
    }

    func testRequestFailsWhenNotesIsNotRunning() {
        XCTAssertThrowsError(try NotesAutomationPermission.request { _ in -600 }) { error in
            XCTAssertEqual((error as? NotesError)?.code, "automation_error")
        }
    }

    func testRequestFailsWhenUserDeniesConsent() {
        XCTAssertThrowsError(try NotesAutomationPermission.request { _ in -1743 }) { error in
            XCTAssertEqual((error as? NotesError)?.code, "automation_denied")
        }
    }

    func testRequestFailsWhenVerifiedStatusIsDenied() {
        var statuses: [OSStatus] = [noErr, -1743]
        XCTAssertThrowsError(try NotesAutomationPermission.request { _ in statuses.removeFirst() }) { error in
            XCTAssertEqual((error as? NotesError)?.code, "automation_denied")
        }
        XCTAssertTrue(statuses.isEmpty)
    }
}
