import Foundation
import XCTest
@testable import notescli

final class EditorUpdatesTests: XCTestCase {
    func testOnlyNewerStableReleaseIsOffered() throws {
        let stable = release("v1.10.2")
        XCTAssertEqual(try EditorUpdates.newerVersion(in: stable, installed: "1.9.30"), "1.10.2")
        XCTAssertNil(try EditorUpdates.newerVersion(in: stable, installed: "1.10.2"))
        XCTAssertNil(try EditorUpdates.newerVersion(in: stable, installed: "2.0.0"))
    }

    func testRejectsPrereleaseDraftAndInvalidReleaseMetadata() {
        for invalid in [release("v1.2.3", prerelease: true), release("v1.2.3", draft: true),
                        release("v1.2.3-beta"), release("v1.2.3/path"), release("v01.2.3"), release("v1..3"), Data()] {
            XCTAssertThrowsError(try EditorUpdates.newerVersion(in: invalid, installed: "1.0.0"))
        }
    }

    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data(#"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(prerelease)}"#.utf8)
    }
}
