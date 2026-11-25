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

    func testRunAtLoginUsesBrandedExecutableWithoutRestartLoop() throws {
        try withDirectory { path in
            let job = makeJob(path) { _ in 1 }
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: job.launchAgentData(), format: nil)
                as? [String: Any])
            XCTAssertEqual(plist["Label"] as? String, "com.saikrishnabolla.notescli.editor")
            XCTAssertEqual(plist["ProgramArguments"] as? [String],
                           [job.app.appendingPathComponent("Contents/MacOS/Notes CLI").path, "editor"])
            XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
            XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
            XCTAssertNil(plist["KeepAlive"])
        }
    }

    func testEnableAndDisableOnlyTheEditorJob() throws {
        try withDirectory { path in
            var calls: [[String]] = []
            var running = false
            let job = makeJob(path, jobDescription: { _ in
                running ? self.description(path, executable: "Contents/MacOS/Notes CLI") : nil
            }) { args in
                calls.append(args)
                switch args.first {
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
            XCTAssertEqual(calls, [
                ["bootstrap", "gui/\(getuid())", job.plist.path],
                ["kickstart", "gui/\(getuid())/\(EditorLogin.label)"],
                ["bootout", "gui/\(getuid())/\(EditorLogin.label)"],
            ])
        }
    }

    func testMigrationReplacesAndRestartsAnEnabledLoadedLegacyJob() throws {
        try withDirectory { path in
            let former = try legacyData(path)
            let runtime = try LoginRuntime(path, loaded: former)
            let job = makeJob(path, jobDescription: runtime.print, launchctl: runtime.run)
            try former.write(to: job.plist)

            XCTAssertTrue(try job.isEnabled())
            try job.migrateIfNeeded()
            XCTAssertEqual(try Data(contentsOf: job.plist), try job.launchAgentData())
            XCTAssertEqual(runtime.arguments, [job.app.appendingPathComponent("Contents/MacOS/Notes CLI").path, "editor"])
            XCTAssertEqual(runtime.calls, [
                ["bootout", "gui/\(getuid())/\(EditorLogin.label)"],
                ["bootstrap", "gui/\(getuid())", job.plist.path],
            ])
            try job.migrateIfNeeded()
            XCTAssertEqual(runtime.calls.count, 2)
        }
    }

    func testMigrationLeavesAnUnloadedLegacyJobUnloadedAndDoesNotEnableAMissingJob() throws {
        try withDirectory { path in
            let runtime = try LoginRuntime(path)
            let job = makeJob(path, jobDescription: runtime.print, launchctl: runtime.run)
            try job.migrateIfNeeded()
            XCTAssertFalse(try job.isEnabled())
            try legacyData(path).write(to: job.plist)
            try job.migrateIfNeeded()
            XCTAssertEqual(try Data(contentsOf: job.plist), try job.launchAgentData())
            XCTAssertNil(runtime.arguments)
            XCTAssertTrue(runtime.calls.isEmpty)
        }
    }

    func testFailedMigrationRestoresLegacyBytesAndReloadsFormerJob() throws {
        try withDirectory { path in
            let former = try legacyData(path)
            let runtime = try LoginRuntime(path, loaded: former)
            runtime.bootstrapFailuresRemaining = 1
            let job = makeJob(path, jobDescription: runtime.print, launchctl: runtime.run)
            try former.write(to: job.plist)

            XCTAssertThrowsError(try job.migrateIfNeeded()) {
                XCTAssertEqual(($0 as? NotesError)?.code, "editor_login_unavailable")
            }
            XCTAssertEqual(try Data(contentsOf: job.plist), former)
            XCTAssertEqual(runtime.arguments, [job.app.appendingPathComponent("Contents/Helpers/notescli").path, "editor"])
            XCTAssertTrue(try job.isEnabled())
            try job.restartLegacyAfterAppRollback()
            XCTAssertEqual(runtime.calls.last, ["kickstart", "-k", "gui/\(getuid())/\(EditorLogin.label)"])
            runtime.arguments = nil
            let calls = runtime.calls.count
            try job.restartLegacyAfterAppRollback()
            XCTAssertEqual(runtime.calls.count, calls, "Do not start an unloaded legacy job during rollback.")
        }
    }

    func testFailedRollbackReportsThatLegacyJobCouldNotBeReloaded() throws {
        try withDirectory { path in
            let former = try legacyData(path)
            let runtime = try LoginRuntime(path, loaded: former)
            runtime.bootstrapFailuresRemaining = 2
            let job = makeJob(path, jobDescription: runtime.print, launchctl: runtime.run)
            try former.write(to: job.plist)

            XCTAssertThrowsError(try job.migrateIfNeeded()) {
                XCTAssertEqual(($0 as? NotesError)?.code, "editor_login_migration_rollback_failed")
            }
            XCTAssertEqual(try Data(contentsOf: job.plist), former)
            XCTAssertNil(runtime.arguments)
        }
    }

    func testMigrationSkipsForeignLoadedJobAndInteractiveCommandsRefuseIt() throws {
        try withDirectory { path in
            let former = try legacyData(path)
            let runtime = try LoginRuntime(path, loaded: former)
            runtime.source = path.appendingPathComponent("foreign.plist").path
            let job = makeJob(path, jobDescription: runtime.print, launchctl: runtime.run)
            try former.write(to: job.plist)

            try job.migrateIfNeeded()
            let actions: [() throws -> Void] = [
                { _ = try job.isEnabled() }, { try job.enable { _ in true } }, { _ = try job.disable() },
            ]
            for action in actions {
                XCTAssertThrowsError(try action()) {
                    XCTAssertEqual(($0 as? NotesError)?.code, "editor_login_not_owned")
                }
            }
            XCTAssertEqual(try Data(contentsOf: job.plist), former)
            XCTAssertEqual(runtime.arguments?.last, "editor")
            XCTAssertTrue(runtime.calls.isEmpty)
        }
    }

    func testDisableRemovesExactLegacyRecordButRejectsEditedLegacyPlist() throws {
        try withDirectory { path in
            let former = try legacyData(path)
            let runtime = try LoginRuntime(path, loaded: former)
            let job = makeJob(path, jobDescription: runtime.print, launchctl: runtime.run)
            var edited = former
            edited.append(0x0A)
            try edited.write(to: job.plist)
            XCTAssertThrowsError(try job.isEnabled())
            try job.migrateIfNeeded()
            XCTAssertThrowsError(try job.disable())
            XCTAssertEqual(try Data(contentsOf: job.plist), edited)
            XCTAssertTrue(runtime.calls.isEmpty)

            try former.write(to: job.plist)
            XCTAssertTrue(try job.disable())
            XCTAssertFalse(try job.isEnabled())
            XCTAssertNil(runtime.arguments)
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

    private func makeJob(_ path: URL, jobDescription: @escaping (String) -> String? = { _ in nil },
                         launchctl: @escaping ([String]) -> Int32) -> EditorLogin {
        EditorLogin(plist: path.appendingPathComponent("\(EditorLogin.label).plist"),
                    app: path.appendingPathComponent("Notes CLI.app"), uid: getuid(), launchctl: launchctl,
                    jobDescription: jobDescription)
    }

    private func legacyData(_ path: URL) throws -> Data {
        let record: [String: Any] = [
            "Label": "com.saikrishnabolla.notescli.editor",
            "ProgramArguments": [path.appendingPathComponent("Notes CLI.app/Contents/Helpers/notescli").path, "editor"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "Umask": 63,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        return try PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0)
    }

    private func description(_ path: URL, executable: String) -> String {
        LoginRuntime.description(source: path.appendingPathComponent("\(EditorLogin.label).plist").path,
                                 arguments: [path.appendingPathComponent("Notes CLI.app/\(executable)").path, "editor"])
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: path) }
        try body(path)
    }
}

private final class LoginRuntime {
    var arguments: [String]?
    var source: String
    var bootstrapFailuresRemaining = 0
    var calls: [[String]] = []

    init(_ path: URL, loaded data: Data? = nil) throws {
        source = path.appendingPathComponent("\(EditorLogin.label).plist").path
        arguments = try data.map(Self.programArguments)
    }

    func print(_ service: String) -> String? {
        arguments.map { Self.description(source: source, arguments: $0) }
    }

    func run(_ command: [String]) -> Int32 {
        calls.append(command)
        switch command.first {
        case "bootout": arguments = nil; return 0
        case "kickstart": return arguments == nil ? 1 : 0
        case "bootstrap":
            if bootstrapFailuresRemaining > 0 { bootstrapFailuresRemaining -= 1; return 1 }
            guard arguments == nil, let path = command.last,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let loaded = try? Self.programArguments(data) else { return 1 }
            source = path
            arguments = loaded
            return 0
        default: return 1
        }
    }

    static func description(source: String, arguments: [String]) -> String {
        "\tpath = \(source)\n\ttype = LaunchAgent\n\tprogram = \(arguments[0])\n\targuments = {\n" +
            arguments.map { "\t\t\($0)\n" }.joined() + "\t}\n"
    }

    private static func programArguments(_ data: Data) throws -> [String] {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return try XCTUnwrap(plist?["ProgramArguments"] as? [String])
    }
}
