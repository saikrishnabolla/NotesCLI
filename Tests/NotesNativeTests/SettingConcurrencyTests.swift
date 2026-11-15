import NotesCore
@testable import NotesNative
import XCTest

final class SettingConcurrencyTests: XCTestCase {
    func testStateMismatchStopsBeforeWrite() {
        let writer = NativeNotesWriter()
        var didWrite = false

        XCTAssertThrowsError(try {
            try writer.requireUndoState(false, expected: true, label: "Test setting")
            didWrite = true
        }()) { error in
            XCTAssertEqual((error as? NotesError)?.code, "undo_conflict")
        }
        XCTAssertFalse(didWrite)
    }

    func testIdentifierMismatchStopsBeforeWrite() {
        let writer = NativeNotesWriter()
        var didWrite = false

        XCTAssertThrowsError(try {
            try writer.requireUndoIdentifier("account-a", expected: "account-b", label: "Default account")
            didWrite = true
        }()) { error in
            XCTAssertEqual((error as? NotesError)?.code, "undo_conflict")
        }
        XCTAssertFalse(didWrite)
    }
}
