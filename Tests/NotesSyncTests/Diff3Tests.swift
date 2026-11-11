import XCTest
@testable import NotesSync

final class Diff3Tests: XCTestCase {
    func testTakesEitherChangedSide() {
        XCTAssertEqual(Diff3.merge(base: "a\nb", local: "A\nb", remote: "a\nb"), MergeResult(text: "A\nb", hadConflicts: false))
        XCTAssertEqual(Diff3.merge(base: "a\nb", local: "a\nb", remote: "a\nB"), MergeResult(text: "a\nB", hadConflicts: false))
    }

    func testMergesNonOverlappingLines() {
        let result = Diff3.merge(base: "one\ntwo\nthree", local: "ONE\ntwo\nthree", remote: "one\ntwo\nTHREE")
        XCTAssertEqual(result, MergeResult(text: "ONE\ntwo\nTHREE", hadConflicts: false))
    }

    func testMergesIndependentInsertions() {
        let result = Diff3.merge(base: "one\ntwo\nthree", local: "one\nlocal\ntwo\nthree", remote: "one\ntwo\nthree\nremote")
        XCTAssertEqual(result, MergeResult(text: "one\nlocal\ntwo\nthree\nremote", hadConflicts: false))
    }

    func testMarksOverlappingConflictWithoutDroppingEitherSide() {
        let result = Diff3.merge(base: "one\ntwo\nthree", local: "one\nLOCAL\nthree", remote: "one\nREMOTE\nthree")
        XCTAssertTrue(result.hadConflicts)
        for value in ["LOCAL", "REMOTE", "two", "<<<<<<< LOCAL", ">>>>>>> NOTES"] { XCTAssertTrue(result.text.contains(value)) }
    }
}
