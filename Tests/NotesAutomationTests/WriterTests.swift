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
        let writer = ScriptingNotesWriter(runner: runner, verifier: { _ in XCTFail("Must not verify unknown writes"); return WriteVerificationResult(outcome: .verified) })
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
        let writer = ScriptingNotesWriter(runner: runner, verifier: { request in
            XCTAssertEqual(request.result.message, #"downgraded: ["checklist"]"#)
            XCTAssertEqual(request.operation, .createNote)
            XCTAssertEqual(request.title, "test")
            return WriteVerificationResult(outcome: .verified, noteID: NoteID(uuid: "stable", coreDataID: request.result.noteID?.coreDataID))
        })
        let result = try writer.createNote(title: "test", markdown: "- [ ] task")
        XCTAssertEqual(result.outcome, .verified)
        XCTAssertEqual(result.noteID?.uuid, "stable")
    }
    func testVerifierFailureDoesNotTurnSuccessIntoRetryableError() throws {
        let runner = StubRunner([ScriptOutput(stdout: "{}")])
        let writer = ScriptingNotesWriter(runner: runner, verifier: { _ in throw NotesError("unavailable", "reader") })
        let result = try writer.deleteNote(id)
        XCTAssertEqual(result.outcome, .unverified)
        XCTAssertTrue(result.message?.contains("Do not retry") == true)
        XCTAssertEqual(runner.calls.count, 1)
    }
    func testChangedIncompleteResponseStillUsesOperationVerifier() throws {
        let runner = StubRunner([ScriptOutput(stdout: #"{"changed":true,"errorCode":"automation_error"}"#)])
        let writer = ScriptingNotesWriter(runner: runner, verifier: { request in
            XCTAssertEqual(request.operation, .moveFolder)
            XCTAssertEqual(request.expectedFolderPath, ["Archive", "Source"])
            return WriteVerificationResult(outcome: .verified, folderID: "x-coredata://moved-folder")
        })
        let result = try writer.moveFolder("Old > Source", toParent: "Archive")
        XCTAssertEqual(result.outcome, .verified)
        XCTAssertEqual(result.folderID, "x-coredata://moved-folder")
        XCTAssertTrue(result.message?.contains("could not complete its response") == true)
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
    func testVerifierReceivesOperationAndReportsMismatch() throws {
        let runner = StubRunner([ScriptOutput(stdout: #"{"id":"x-coredata://synthetic/ICNote/p123"}"#)])
        let writer = ScriptingNotesWriter(runner: runner, verifier: { request in
            XCTAssertEqual(request.operation, .renameNote)
            XCTAssertEqual(request.title, "new title")
            XCTAssertEqual(request.ref, "x-coredata://synthetic/ICNote/p123")
            return WriteVerificationResult(outcome: .unverified, mismatch: "title was still old")
        })
        let result = try writer.renameNote(id, title: "new title")
        XCTAssertEqual(result.outcome, .unverified)
        XCTAssertTrue(result.message?.contains("mismatch: title was still old") == true)
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

    func testPrependPreservesExistingHTMLAndAttachmentGuardStopsBeforeWrite() throws {
        let read = ScriptOutput(stdout: #"{"id":"x-coredata://synthetic/ICNote/p123","title":"T","body":"<h1>T</h1><div>old</div>","attachmentCount":0}"#)
        let written = ScriptOutput(stdout: #"{"id":"x-coredata://synthetic/ICNote/p123"}"#)
        let runner = StubRunner([read, written])
        _ = try ScriptingNotesWriter(runner: runner).prependToNote(id, markdown: "new")
        let payload = try JSONDecoder().decode([String: String].self, from: Data(runner.calls[1].arguments[0].utf8))
        XCTAssertEqual(payload["operation"], "prependToNote")
        XCTAssertEqual(payload["html"], "<h1>T</h1><div>new</div><div>old</div>")

        let guarded = StubRunner([ScriptOutput(stdout: #"{"id":"x","title":"T","body":"<h1>T</h1>","attachmentCount":1}"#)])
        XCTAssertThrowsError(try ScriptingNotesWriter(runner: guarded).replaceText(id, find: "T", replacement: "X")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "attachments_would_be_lost")
        }
        XCTAssertEqual(guarded.calls.count, 1)
    }

    func testReplaceSectionKeepsOtherSections() throws {
        let body = "<h1>T</h1><h2>A</h2><div>old</div><h2>B</h2><div>keep</div>"
        let read = ScriptOutput(stdout: "{\"id\":\"x\",\"title\":\"T\",\"body\":\"\(body)\",\"attachmentCount\":0}")
        let runner = StubRunner([read, ScriptOutput(stdout: #"{"id":"x-coredata://synthetic/ICNote/p123"}"#)])
        _ = try ScriptingNotesWriter(runner: runner).replaceSection(id, heading: "A", markdown: "new")
        let payload = try JSONDecoder().decode([String: String].self, from: Data(runner.calls[1].arguments[0].utf8))
        XCTAssertEqual(payload["html"], "<h1>T</h1><h2>A</h2><div>new</div><h2>B</h2><div>keep</div>")
    }

    func testStyledNotesHeadingsAreDetected() throws {
        let body = #"<div><b><span style="font-size: 24px">T</span></b></div><div><b><span style="font-size: 18px">A</span></b></div><div>old</div><div><b><span style="font-size: 18px">B</span></b></div><div>keep</div>"#
        let encoded = String(decoding: try JSONEncoder().encode(["id": "x", "title": "T", "body": body, "attachmentCount": "0"]), as: UTF8.self)
            .replacingOccurrences(of: #""attachmentCount":"0""#, with: #""attachmentCount":0"#)
        let runner = StubRunner([ScriptOutput(stdout: encoded), ScriptOutput(stdout: #"{"id":"x-coredata://synthetic/ICNote/p123"}"#)])
        _ = try ScriptingNotesWriter(runner: runner).replaceSection(id, heading: "A", markdown: "new")
        let payload = try JSONDecoder().decode([String: String].self, from: Data(runner.calls[1].arguments[0].utf8))
        XCTAssertTrue(payload["html"]?.contains(#"font-size: 18px">A</span></b></div><div>new</div><div><b><span style="font-size: 18px">B"#) == true)
    }

}
