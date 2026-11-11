import Foundation
import XCTest
@testable import NotesAutomation

final class ScriptRunnerTests: XCTestCase {
    func testAppleScriptArgumentsRoundTripWithoutExecutingText() throws {
        let input = "\" & do shell script \"not-a-command\" & \"\n\\ -- -e 日本語"
        let output = try OSAScriptRunner().run(source: "on run argv\nreturn item 1 of argv\nend run", language: .appleScript, arguments: [input], timeout: 5)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout, input + "\n")
    }
    func testJXAArgumentsRoundTrip() throws {
        let values = ["-e", "$(not-a-command)", "'\"\\\n\r\t🌲"]
        let output = try OSAScriptRunner().run(source: "function run(argv) { return JSON.stringify(argv); }", language: .javaScript, arguments: values, timeout: 5)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(output.stdout.utf8)), values)
    }
    func testBoundedTimeout() throws {
        let start = Date()
        let output = try OSAScriptRunner().run(source: "delay 10", language: .appleScript, arguments: [], timeout: 0.1)
        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testLargeOutputDoesNotBlockPipe() throws {
        let output = try OSAScriptRunner().run(source: "function run(argv) { return 'x'.repeat(200000); }", language: .javaScript, arguments: [], timeout: 5)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout.utf8.count, 200001)
    }
    func testInvalidArguments() {
        XCTAssertThrowsError(try OSAScriptRunner().run(source: "", language: .appleScript, arguments: ["\0"], timeout: 1))
        XCTAssertThrowsError(try OSAScriptRunner().run(source: "", language: .appleScript, arguments: [], timeout: 0))
    }
}
