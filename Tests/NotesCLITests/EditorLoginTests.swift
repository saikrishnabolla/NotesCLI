import Foundation
import NotesCore
import XCTest
@testable import notescli

final class EditorLoginTests: XCTestCase {
    func testLoginStatusDoesNotConfuseRegistrationWithARunningEditor() {
        let denied = EditorLoginRuntime(jobDescription: "\tstate = not running\n\tlast exit code = 4\n\t\tstate = active\n")
        XCTAssertEqual(denied, .stopped(4))
        XCTAssertTrue(denied.message.contains("denied Accessibility"))
        XCTAssertEqual(EditorLoginRuntime(jobDescription: "\tstate = running\n\tlast exit code = 4\n"), .running)
        XCTAssertEqual(EditorLoginRuntime(jobDescription: "\tstate = xpcproxy\n\tlast exit code = 4\n"), .starting)
        XCTAssertEqual(EditorLoginRuntime(jobDescription: "\tstate = not running\n\tlast exit code = (never exited)\n"),
                       .stopped(nil))
        XCTAssertEqual(EditorLoginRuntime(jobDescription: "no state\n"), .unknown)
    }

    func testRunAtLoginUsesInstalledHelperWithoutRestartLoop() throws {
        try withDirectory { path in
            let job = makeJob(path) { _ in 1 }
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: job.launchAgentData(), format: nil)
                as? [String: Any])
            XCTAssertEqual(plist["Label"] as? String, EditorLogin.label)
            XCTAssertEqual(plist["ProgramArguments"] as? [String],
                           [job.app.appendingPathComponent("Contents/Helpers/notescli").path, "editor"])
            XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
            XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
            XCTAssertNil(plist["KeepAlive"])
        }
    }

    func testEnableAndDisableOnlyTheEditorJob() throws {
        try withDirectory { path in
            var calls: [[String]] = []
            var running = false
            let job = makeJob(path) { args in
                calls.append(args)
                switch args.first {
                case "print": return running ? 0 : 1
                case "bootstrap": running = true; return 0
                case "kickstart": return 0
                case "bootout": running = false; return 0
                default: return 1
                }
            }
            XCTAssertFalse(try job.isEnabled())
            XCTAssertThrowsError(try job.enable { _ in false })
            XCTAssertTrue(calls.isEmpty)
            try job.enable { _ in true }
            try job.enable { _ in true }
            XCTAssertTrue(try job.isEnabled())
            XCTAssertTrue(try job.disable())
            XCTAssertFalse(try job.disable())
            XCTAssertEqual(calls.filter { $0.first != "print" }, [
                ["bootstrap", "gui/\(getuid())", job.plist.path],
                ["kickstart", "gui/\(getuid())/\(EditorLogin.label)"],
                ["bootout", "gui/\(getuid())/\(EditorLogin.label)"],
            ])
        }
    }

    func testFailedBootstrapRollsBackAndForeignPlistIsNeverRemoved() throws {
        try withDirectory { path in
            let job = makeJob(path) { _ in 1 }
            XCTAssertThrowsError(try job.enable { _ in true })
            XCTAssertFalse(try job.isEnabled())
            let foreign = Data("not our LaunchAgent".utf8)
            try foreign.write(to: job.plist)
            XCTAssertThrowsError(try job.enable { _ in true })
            XCTAssertThrowsError(try job.disable())
            XCTAssertEqual(try Data(contentsOf: job.plist), foreign)
        }
    }

    func testEditorInstanceLockRejectsSecondHolderAndAllowsRestart() throws {
        try withDirectory { path in
            let lock = path.appendingPathComponent("editor.lock")
            let first = try EditorInstance.acquire(at: lock)
            XCTAssertThrowsError(try EditorInstance.acquire(at: lock)) {
                XCTAssertEqual(($0 as? NotesError)?.code, "editor_already_running")
            }
            close(first)
            close(try EditorInstance.acquire(at: lock))
        }
    }

    private func makeJob(_ path: URL, launchctl: @escaping ([String]) -> Int32) -> EditorLogin {
        EditorLogin(plist: path.appendingPathComponent("\(EditorLogin.label).plist"),
                    app: path.appendingPathComponent("Notes CLI.app"), uid: getuid(), launchctl: launchctl)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: path) }
        try body(path)
    }
}
