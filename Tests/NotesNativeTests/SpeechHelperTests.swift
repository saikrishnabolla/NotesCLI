import Foundation
import NotesCore
import XCTest
@testable import NotesNative

final class SpeechHelperTests: XCTestCase {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-fake-helper-" + UUID().uuidString)
        try ("#!/bin/sh\nwhile [ \"$1\" != \"--reply\" ]; do shift; done\nREPLY_PATH=\"$2\"\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testHelperValueIsReturned() throws {
        let helper = try script(#"printf '{"value":[{"text":"Hello","start":0,"duration":1}]}' > "$REPLY_PATH""#)
        let words = try SpeechHelper.run(helper, ["--file", "/tmp/x.m4a"], as: [TranscriptWord].self)
        XCTAssertEqual(words, [TranscriptWord(text: "Hello", start: 0, duration: 1)])
    }

    func testHelperErrorKeepsItsCode() throws {
        let helper = try script(#"printf '{"error":{"code":"speech_permission_required","message":"denied"}}' > "$REPLY_PATH""#)
        XCTAssertThrowsError(try SpeechHelper.run(helper, ["--authorize"], as: Int.self)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "speech_permission_required")
        }
    }

    func testHelperCrashWithoutReplyIsAClearError() throws {
        let helper = try script("kill -ABRT $$")
        XCTAssertThrowsError(try SpeechHelper.run(helper, ["--status"], as: Int.self)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "speech_helper_failed")
        }
    }
}
