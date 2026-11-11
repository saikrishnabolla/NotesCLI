import Darwin
import Foundation
import NotesCore

public struct NotesIndexJobStatus: Codable, Sendable, Hashable {
    public var state: String
    public var pid: Int32?
    public var current: Int
    public var total: Int
    public var startedAt: Date?
    public var finishedAt: Date?
    public var errorCode: String?
    public var executablePath: String?
    public init(state: String, pid: Int32? = nil, current: Int = 0, total: Int = 0,
                startedAt: Date? = nil, finishedAt: Date? = nil, errorCode: String? = nil,
                executablePath: String? = nil) {
        self.state = state; self.pid = pid; self.current = current; self.total = total
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.errorCode = errorCode
        self.executablePath = executablePath
    }
}

public enum NotesIndexJobs {
    public static var progressURL: URL {
        if let override = ProcessInfo.processInfo.environment["NOTESCLI_INDEX_PROGRESS_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/NotesCLI/index-progress.json")
    }

    public static func status() -> NotesIndexJobStatus {
        guard let data = try? Data(contentsOf: progressURL),
              var value = try? decoder.decode(NotesIndexJobStatus.self, from: data) else { return NotesIndexJobStatus(state: "idle") }
        if value.state == "running", let pid = value.pid, !isExpectedProcess(pid, executable: value.executablePath) {
            value.state = "failed"; value.finishedAt = Date(); value.errorCode = "process_exited"
            try? write(value)
        }
        return value
    }

    @discardableResult
    public static func start(executable: String, arguments: [String]) throws -> NotesIndexJobStatus {
        let current = status()
        if current.state == "running" { throw NotesError("index_job_running", "A background index job is already running.") }
        try FileManager.default.createDirectory(at: progressURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let executableURL = URL(fileURLWithPath: executable).standardizedFileURL.resolvingSymlinksInPath()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let value = NotesIndexJobStatus(state: "running", pid: process.processIdentifier, startedAt: Date(),
                                        executablePath: executableURL.path)
        try write(value); return value
    }

    public static func report(current: Int, total: Int) {
        var value = status()
        guard value.state == "running" else { return }
        value.current = current; value.total = total
        try? write(value)
    }

    public static func finish(error: Error? = nil) {
        var value = status()
        value.state = error == nil ? "completed" : "failed"; value.finishedAt = Date()
        value.errorCode = (error as? NotesError)?.code ?? error.map { _ in "index_failed" }
        try? write(value)
    }

    @discardableResult
    public static func cancel() throws -> NotesIndexJobStatus {
        var value = status()
        guard value.state == "running", let pid = value.pid else { throw NotesError("index_job_not_running", "No background index job is running.") }
        guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { throw NotesError("index_cancel_failed", "The background index job could not be cancelled.") }
        value.state = "cancelled"; value.finishedAt = Date(); try write(value); return value
    }

    private static let encoder: JSONEncoder = { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.sortedKeys]; return value }()
    private static let decoder: JSONDecoder = { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }()
    private static func isExpectedProcess(_ pid: Int32, executable: String?) -> Bool {
        guard kill(pid, 0) == 0, let executable else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return false }
        let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        let running = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL.resolvingSymlinksInPath().path
        return running == executable
    }
    private static func write(_ value: NotesIndexJobStatus) throws {
        try FileManager.default.createDirectory(at: progressURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try encoder.encode(value).write(to: progressURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: progressURL.path)
    }
}
