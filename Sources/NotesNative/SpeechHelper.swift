import Darwin
import Foundation
import NotesCore

/// Runs Speech Recognition in a child `notescli speech-helper` process that disclaims its parent app.
///
/// macOS checks the usage description of the *responsible* app, which is the terminal or MCP host
/// that launched notescli. Those apps have no NSSpeechRecognitionUsageDescription, so TCC kills
/// notescli the moment it asks for speech access. A child spawned with responsibility disclaimed is
/// responsible for itself, so TCC reads the Info.plist embedded in the notescli binary instead.
/// The helper gets a private copy of the audio, so it never needs Full Disk Access.
public enum SpeechHelper {
    public static let subcommand = "speech-helper"
    static let inProcessKey = "NOTESCLI_SPEECH_IN_PROCESS"

    /// The notescli binary to run the helper from, or nil to transcribe in this process.
    static var executable: URL? {
        let environment = ProcessInfo.processInfo.environment
        if environment[inProcessKey] == "1" { return nil }
        // A command launched by the signed Capability Host must keep the host as its responsible
        // process so one permission grant covers speech as well as Notes access.
        if environment["NOTESCLI_HOST_ACTIVE"] == "1" { return nil }
        if let path = environment["NOTESCLI_SPEECH_HELPER"], !path.isEmpty { return URL(fileURLWithPath: path) }
        guard let url = Bundle.main.executableURL, url.lastPathComponent == "notescli" else { return nil }
        return url
    }

    struct Reply<Value: Codable>: Codable {
        var value: Value?
        var error: NotesError?
    }

    /// Writes the helper's reply. The helper calls this with either a value or an error.
    public static func writeReply<Value: Codable>(_ value: Value?, error: NotesError?, to path: String) throws {
        try JSONEncoder().encode(Reply(value: value, error: error)).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func privateCopy(of file: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-speech-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let copy = directory.appendingPathComponent("audio." + (file.pathExtension.isEmpty ? "m4a" : file.pathExtension))
        do { try FileManager.default.copyItem(at: file, to: copy) }
        catch {
            try? FileManager.default.removeItem(at: directory)
            throw NotesError("audio_not_readable", "Could not read the audio file: \(error.localizedDescription)")
        }
        return copy
    }

    static func run<Value: Codable>(_ executable: URL, _ arguments: [String], as: Value.Type,
                                    timeout: TimeInterval? = nil) throws -> Value {
        let reply = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-speech-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: reply) }
        let status = try spawnDisclaimed(executable, [subcommand] + arguments + ["--reply", reply.path], timeout: timeout)
        guard let data = try? Data(contentsOf: reply), let decoded = try? JSONDecoder().decode(Reply<Value>.self, from: data) else {
            throw NotesError("speech_helper_failed", "The speech helper exited with status \(status) and no result.",
                             hint: "Run notescli permissions, then try again.")
        }
        if let error = decoded.error { throw error }
        guard let value = decoded.value else { throw NotesError("speech_helper_failed", "The speech helper returned no result.") }
        return value
    }

    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static func spawnDisclaimed(_ executable: URL, _ arguments: [String], timeout: TimeInterval?) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            throw NotesError("speech_helper_failed", "This macOS version cannot start the speech helper.")
        }
        _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)

        var environment = ProcessInfo.processInfo.environment
        environment[inProcessKey] = "1"
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, nil, &attributes, argv, envp)
        guard spawned == 0 else {
            throw NotesError("speech_helper_failed", "Could not start the speech helper: \(String(cString: strerror(spawned))).")
        }
        var status: Int32 = 0
        guard let timeout else {
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            return status
        }

        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result == -1, errno != EINTR {
                throw NotesError("speech_helper_failed", "Could not wait for the speech helper: \(String(cString: strerror(errno))).")
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                throw NotesError("speech_helper_timeout", "The speech helper did not respond in time.")
            }
            usleep(10_000)
        }
    }
}
