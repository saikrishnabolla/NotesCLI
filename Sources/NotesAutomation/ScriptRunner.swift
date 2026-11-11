import Foundation
import ApplicationServices
import Darwin
import NotesCore

public enum ScriptLanguage: String, Sendable { case appleScript = "AppleScript", javaScript = "JavaScript" }

public struct ScriptOutput: Sendable {
    public var stdout: String
    public var stderr: String
    public var status: Int32
    public var timedOut: Bool
    public init(stdout: String = "", stderr: String = "", status: Int32 = 0, timedOut: Bool = false) {
        self.stdout = stdout; self.stderr = stderr; self.status = status; self.timedOut = timedOut
    }
}

public protocol ScriptRunning: Sendable {
    func run(source: String, language: ScriptLanguage, arguments: [String], timeout: TimeInterval) throws -> ScriptOutput
}

/// Uses private files for output so a full pipe cannot deadlock a large response.
/// Killing osascript does not cancel an Apple Event already delivered to Notes.
public struct OSAScriptRunner: ScriptRunning {
    public init() {}

    public static func invocation(scriptPath: String, language: ScriptLanguage, arguments: [String]) -> [String] {
        ["-l", language.rawValue, scriptPath] + arguments
    }

    public func run(source: String, language: ScriptLanguage, arguments: [String], timeout: TimeInterval) throws -> ScriptOutput {
        guard timeout.isFinite, timeout > 0 else { throw NotesError("invalid_timeout", "Timeout must be positive and finite.") }
        guard !arguments.contains(where: { $0.contains("\0") }) else {
            throw NotesError("invalid_argument", "Script arguments cannot contain NUL characters.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notectl-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("script")
        try source.write(to: script, atomically: true, encoding: .utf8)
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        for url in [outputURL, errorURL] {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw NotesError("script_io_error", "Could not create private script output.")
            }
        }
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = Self.invocation(scriptPath: script.path, language: language, arguments: arguments)
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = finished.wait(timeout: .now() + 1)
            }
        }
        // If output cannot be read after dispatch, return an empty response. The writer
        // treats that as unknown instead of throwing an error that could invite a retry.
        return ScriptOutput(
            stdout: String(decoding: (try? Data(contentsOf: outputURL)) ?? Data(), as: UTF8.self),
            stderr: String(decoding: (try? Data(contentsOf: errorURL)) ?? Data(), as: UTF8.self),
            status: process.isRunning ? -1 : process.terminationStatus, timedOut: timedOut)
    }
}

public enum NotesAutomationPermission {
    /// Never opens a consent prompt. A denied or undetermined grant stops the operation before dispatch.
    public static func check() throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        if status == -1743 || status == -1744 {
            throw NotesError("automation_denied", "Notes Automation permission check returned \(status)" +
                (status == -1744 ? " (consent required; no prompt was opened)." : " (not authorized)."),
                hint: "System Settings > Privacy & Security > Automation")
        }
        // -600 is handled by the read-only launch/retry path.
        if status != noErr && status != -600 { throw NotesError("automation_error", "Automation permission check returned \(status).") }
    }
}
