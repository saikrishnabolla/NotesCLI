import Foundation
import XCTest
import NotesCore
@testable import NotesAutomation

final class StubRunner: ScriptRunning, @unchecked Sendable {
    struct Call { let source: String; let language: ScriptLanguage; let arguments: [String] }
    private let lock = NSLock()
    private var pending: [ScriptOutput]
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }
    init(_ outputs: [ScriptOutput]) { pending = outputs }
    func run(source: String, language: ScriptLanguage, arguments: [String], timeout: TimeInterval) throws -> ScriptOutput {
        try lock.withLock {
            recorded.append(Call(source: source, language: language, arguments: arguments))
            guard !pending.isEmpty else { throw NotesError("unexpected_call", "No queued response.") }
            return pending.removeFirst()
        }
    }
}

final class WriterTests: XCTestCase {
    let id = "x-coredata://synthetic/ICNote/p123"
    func testUserStringsStayInArguments() throws {
        let runner = StubRunner([ScriptOutput(stdout: #"{"id":"x-coredata://synthetic/ICNote/p123"}"#)])
        let title = "\"; do shell script \"touch /tmp/unsafe\"\n'\\ 👩🏽‍💻"
        let result = try ScriptingNotesWriter(runner: runner).createNote(title: title, markdown: "**<&>**", folder: "A > B")
        XCTAssertEqual(result.outcome, .unverified)
        XCTAssertEqual(result.noteID?.coreDataID, id)
        XCTAssertEqual(result.noteID?.uuid, "")
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.source, NotesScripts.operation)
        XCTAssertFalse(call.source.contains(title))
        let payload = try JSONDecoder().decode([String: String].self, from: Data(call.arguments[0].utf8))
        XCTAssertEqual(payload["title"], title)
        XCTAssertEqual(payload["html"], "<div><b>&lt;&amp;&gt;</b></div>")
        XCTAssertEqual(payload["folder"], "A > B")
    }
    func testTimeoutNeverRetriesOrVerifies() throws {
        let runner = StubRunner([ScriptOutput(timedOut: true)])
        let writer = ScriptingNotesWriter(runner: runner, verifier: { _ in XCTFail("Must not verify unknown writes"); return .verified })
        XCTAssertEqual(try writer.deleteNote(id).outcome, .unknown)
        XCTAssertEqual(runner.calls.count, 1)
    }
    func testAppleEventTimeoutIsUnknown() throws {
        let runner = StubRunner([ScriptOutput(stdout: #"{"errorNumber":-1712}"#)])
        XCTAssertEqual(try ScriptingNotesWriter(runner: runner).renameNote(id, title: "title").outcome, .unknown)
        XCTAssertEqual(runner.calls.count, 1)
    }
    func testLostWriteResponseIsUnknown() throws {
        let runner = StubRunner([ScriptOutput(stdout: "bad response")])
        XCTAssertEqual(try ScriptingNotesWriter(runner: runner).deleteNote(id).outcome, .unknown)
    }
    func testVerifierAndChecklistMessage() throws {
        let runner = StubRunner([ScriptOutput(stdout: #"{"id":"x-coredata://synthetic/ICNote/p123"}"#)])
        let writer = ScriptingNotesWriter(runner: runner, verifier: { result in
            XCTAssertEqual(result.message, #"downgraded: ["checklist"]"#)
            return .verified
        })
        XCTAssertEqual(try writer.createNote(title: "test", markdown: "- [ ] task").outcome, .verified)
    }
    func testVerifierFailureDoesNotTurnSuccessIntoRetryableError() throws {
        let runner = StubRunner([ScriptOutput(stdout: "{}")])
        let writer = ScriptingNotesWriter(runner: runner, verifier: { _ in throw NotesError("unavailable", "reader") })
        let result = try writer.deleteNote(id)
        XCTAssertEqual(result.outcome, .unverified)
        XCTAssertTrue(result.message?.contains("Do not retry") == true)
        XCTAssertEqual(runner.calls.count, 1)
    }
    func testResolver() throws {
        let runner = StubRunner([ScriptOutput(stdout: "{}")])
        let writer = ScriptingNotesWriter(runner: runner, resolver: { _ in "x-coredata://synthetic/ICNote/p123" })
        _ = try writer.renameNote("uuid", title: "new")
        XCTAssertTrue(runner.calls[0].arguments[0].contains("synthetic"))
        XCTAssertThrowsError(try ScriptingNotesWriter(runner: runner).deleteNote("uuid")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "note_not_found")
        }
        XCTAssertEqual(runner.calls.count, 1)
    }
    func testReadLaunchesAndRetriesOnlyOnce() throws {
        let runner = StubRunner([ScriptOutput(stdout: #"{"errorNumber":-600}"#), ScriptOutput(stdout: "{}"), ScriptOutput(stdout: #"{"notes":[]}"#)])
        XCTAssertEqual(try ScriptingNotesWriter(runner: runner).listViaScripting(), [])
        XCTAssertEqual(runner.calls.count, 3)
        XCTAssertEqual(runner.calls[1].source, NotesScripts.launch)
        let writes = StubRunner([ScriptOutput(stdout: #"{"errorNumber":-600}"#)])
        XCTAssertThrowsError(try ScriptingNotesWriter(runner: writes).deleteNote(id)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "app_not_running")
        }
        XCTAssertEqual(writes.calls.count, 1)
    }
    func testReadRetryFailureStops() {
        let runner = StubRunner([ScriptOutput(stdout: #"{"errorNumber":-600}"#), ScriptOutput(stdout: "{}"), ScriptOutput(stdout: #"{"errorNumber":-600}"#)])
        XCTAssertThrowsError(try ScriptingNotesWriter(runner: runner).listViaScripting())
        XCTAssertEqual(runner.calls.count, 3)
    }
    func testErrorMappingsAndPrivacy() {
        for (number, code) in [(-1743, "automation_denied"), (-1728, "note_not_found")] {
            let runner = StubRunner([ScriptOutput(stderr: "private text (\(number))\n", status: 1)])
            XCTAssertThrowsError(try ScriptingNotesWriter(runner: runner).deleteNote(id)) { error in
                let error = error as? NotesError
                XCTAssertEqual(error?.code, code)
                XCTAssertFalse(error?.description.contains("private text") == true)
                if number == -1743 { XCTAssertEqual(error?.hint, "System Settings > Privacy & Security > Automation") }
            }
        }
    }
    func testMissingFolderAndConsentDoNotWrite() {
        let runner = StubRunner([ScriptOutput(stdout: #"{"errorCode":"folder_not_found"}"#)])
        XCTAssertThrowsError(try ScriptingNotesWriter(runner: runner).createNote(title: "test", markdown: "", folder: "missing")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "folder_not_found")
        }
        let denied = StubRunner([])
        let writer = ScriptingNotesWriter(runner: denied, permissionCheck: { throw NotesError("automation_denied", "denied") })
        XCTAssertThrowsError(try writer.deleteNote(id))
        XCTAssertTrue(denied.calls.isEmpty)
    }
    func testFolderMutationsAndEmptyName() throws {
        let runner = StubRunner(Array(repeating: ScriptOutput(stdout: #"{"folderID":"folder"}"#), count: 3))
        let writer = ScriptingNotesWriter(runner: runner)
        XCTAssertEqual(try writer.createFolder(name: "sub", parent: "notescli-test", account: "default").folderID, "folder")
        _ = try writer.renameFolder("folder", name: "renamed")
        _ = try writer.deleteFolder("folder")
        XCTAssertThrowsError(try writer.createFolder(name: " "))
        XCTAssertEqual(runner.calls.count, 3)
    }
    func testMissingImageDowngrades() throws {
        let runner = StubRunner([ScriptOutput(stdout: #"{"id":"x-coredata://synthetic/ICNote/p123"}"#)])
        let result = try ScriptingNotesWriter(runner: runner).createNote(title: "test", markdown: "![missing](/notescli-missing-file.png)")
        XCTAssertEqual(result.message, #"downgraded: ["image"]"#)
        XCTAssertEqual(runner.calls.count, 1)
    }
    func testAttachmentTimeoutDoesNotRetry() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let runner = StubRunner([ScriptOutput(stdout: #"{"id":"x-coredata://synthetic/ICNote/p123"}"#), ScriptOutput(timedOut: true)])
        let result = try ScriptingNotesWriter(runner: runner).createNote(title: "test", markdown: "![file](\(file.path))")
        XCTAssertEqual(result.outcome, .unknown)
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls[1].arguments, [id, file.path])
    }
    func testKnownUUIDIsRetained() throws {
        let uuid = "00000000-0000-0000-0000-000000000123"
        let runner = StubRunner([ScriptOutput(stdout: "{}")])
        let writer = ScriptingNotesWriter(runner: runner, resolver: { _ in "x-coredata://synthetic/ICNote/p123" })
        XCTAssertEqual(try writer.renameNote(uuid, title: "new").noteID?.uuid, uuid)
    }
    func testDisabledAttachmentsDowngradeWithoutDispatch() throws {
        let runner = StubRunner([ScriptOutput(stdout: #"{"id":"x-coredata://synthetic/ICNote/p123"}"#)])
        let writer = ScriptingNotesWriter(runner: runner, attachLocalImages: false)
        let result = try writer.createNote(title: "test", markdown: "![file](/tmp/image.png)")
        XCTAssertEqual(result.outcome, .unverified)
        XCTAssertTrue(result.message?.contains(#"downgraded: ["image"]"#) == true)
        XCTAssertEqual(runner.calls.count, 1)
    }
    func testLostConnectionAndProcessCrashAreUnknown() throws {
        for output in [ScriptOutput(stdout: #"{"errorNumber":-609}"#), ScriptOutput(status: 9)] {
            let runner = StubRunner([output])
            XCTAssertEqual(try ScriptingNotesWriter(runner: runner).deleteNote(id).outcome, .unknown)
            XCTAssertEqual(runner.calls.count, 1)
        }
    }
    func testListDecodesArbitraryTitlesAndPaths() throws {
        let note = ScriptingNote(id: id, title: "quotes \" and \n 🌲", folderID: "f", folderPath: ["A", "B"], accountID: "a")
        let encoded = try JSONEncoder().encode(["notes": [note]])
        let runner = StubRunner([ScriptOutput(stdout: String(decoding: encoded, as: UTF8.self))])
        XCTAssertEqual(try ScriptingNotesWriter(runner: runner).listViaScripting(), [note])
    }

}
