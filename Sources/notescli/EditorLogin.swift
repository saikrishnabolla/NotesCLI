import Darwin
import Foundation
import NotesCore
import NotesHost

struct EditorLogin {
    static let label = "com.saikrishnabolla.notescli.editor"
    static var local: Self {
        Self(plist: CapabilityHostPaths.launchAgent.deletingLastPathComponent().appendingPathComponent("\(label).plist"),
             app: CapabilityHostPaths.app, uid: getuid(), launchctl: HostInstallation.launchctl,
             jobDescription: describeJob)
    }

    let plist: URL
    let app: URL
    let uid: uid_t
    let launchctl: ([String]) -> Int32
    let jobDescription: (String) -> String?
    private var domain: String { "gui/\(uid)" }
    private var service: String { "\(domain)/\(Self.label)" }

    private enum Record: Equatable { case current, legacy }

    func runtimeStatus() -> EditorLoginRuntime {
        jobDescription(service).map(EditorLoginRuntime.init(jobDescription:)) ?? .notLoaded
    }

    private static func describeJob(_ service: String) -> String? {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", service]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return String(decoding: data, as: UTF8.self) }
        } catch {}
        return nil
    }

    private func executable(_ record: Record) -> String {
        app.appendingPathComponent(record == .current ? "Contents/MacOS/Notes CLI" : "Contents/Helpers/notescli").path
    }

    func launchAgentData() throws -> Data {
        try launchAgentData(.current)
    }

    private func launchAgentData(_ record: Record) throws -> Data {
        let object: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable(record), "editor"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "Umask": 63,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    func isEnabled() throws -> Bool {
        let record = try installedRecord()
        _ = try hasOwnedJob(record)
        return record != nil
    }

    private func installedRecord() throws -> Record? {
        let fd = open(plist.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw unowned }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == uid, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, (1...4096).contains(info.st_size),
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 4097),
              data.count == Int(info.st_size) else { throw unowned }
        if data == (try launchAgentData(.current)) { return .current }
        if data == (try launchAgentData(.legacy)) { return .legacy }
        throw unowned
    }

    private func matches(_ description: String, _ record: Record) -> Bool {
        let lines = description.split(whereSeparator: \.isNewline)
        let program = executable(record)
        guard lines.contains(Substring("\tpath = \(plist.path)")), lines.contains("\ttype = LaunchAgent"),
              lines.contains(Substring("\tprogram = \(program)")),
              let arguments = lines.firstIndex(of: "\targuments = {") else { return false }
        return lines.dropFirst(arguments + 1).prefix(3).elementsEqual([Substring("\t\t\(program)"), "\t\teditor", "\t}"])
    }

    private func hasOwnedJob(_ record: Record?) throws -> Bool {
        guard let description = jobDescription(service) else { return false }
        guard let record, matches(description, record) else { throw unowned }
        return true
    }

    func enable(validate: (URL) -> Bool = {
        NotesCLIApplication.supportsEmbeddedEditor(at: $0) && HostInstallation.validSignature($0)
    }) throws {
        guard validate(app) else {
            throw NotesError("editor_login_app_missing", "Run 'notescli onboard' to install the signed app first.")
        }
        let record = try installedRecord()
        let wasLoaded = try hasOwnedJob(record)
        if record == .legacy {
            try migrateLegacy(restart: wasLoaded)
            if wasLoaded { return }
        } else if wasLoaded {
            guard launchctl(["kickstart", service]) == 0 else {
                throw NotesError("editor_login_unavailable", "Editor startup is enabled, but the editor could not be started. Check 'notescli editor --export-logs'.")
            }
            return
        }
        if record == nil {
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try launchAgentData().write(to: plist, options: .withoutOverwriting)
        }
        if launchctl(["bootstrap", domain, plist.path]) != 0 {
            if (try? hasOwnedJob(.current)) == true { return }
            if record == nil, try installedRecord() == .current { try FileManager.default.removeItem(at: plist) }
            throw NotesError("editor_login_unavailable", "Could not register editor startup in this macOS desktop session.")
        }
    }

    func migrateIfNeeded() throws {
        let wasLoaded: Bool
        do {
            guard try installedRecord() == .legacy else { return }
            wasLoaded = try hasOwnedJob(.legacy)
        } catch let error as NotesError where error.code == unowned.code {
            return
        }
        try migrateLegacy(restart: wasLoaded)
    }

    func restartLegacyAfterAppRollback() throws {
        guard try installedRecord() == .legacy, try hasOwnedJob(.legacy) else { return }
        guard launchctl(["kickstart", "-k", service]) == 0 else {
            throw NotesError("editor_login_unavailable", "Could not restart the editor with the restored Notes CLI app.")
        }
    }

    private func migrateLegacy(restart: Bool) throws {
        let current = try launchAgentData(.current)
        let former = try launchAgentData(.legacy)
        if restart { try stop() }
        do {
            guard try installedRecord() == .legacy else { throw unowned }
            try current.write(to: plist, options: .atomic)
            if restart, launchctl(["bootstrap", domain, plist.path]) != 0 {
                throw NotesError("editor_login_unavailable", "Could not start the updated editor login job.")
            }
        } catch {
            if restart {
                do {
                    switch try installedRecord() {
                    case .current: try former.write(to: plist, options: .atomic)
                    case .legacy: break
                    case nil: throw unowned
                    }
                    if let description = jobDescription(service), !matches(description, .legacy) {
                        guard matches(description, .current) else { throw unowned }
                        try stop()
                    }
                    if try !hasOwnedJob(.legacy), launchctl(["bootstrap", domain, plist.path]) != 0,
                       try !hasOwnedJob(.legacy) {
                        throw NotesError("editor_login_unavailable", "Could not reload the former editor login job.")
                    }
                } catch let rollback {
                    throw NotesError("editor_login_migration_rollback_failed", "Could not restore the former editor login job.",
                                     hint: "\(error) \(rollback)")
                }
            }
            throw error
        }
    }

    @discardableResult
    func disable() throws -> Bool {
        let record = try installedRecord()
        if try hasOwnedJob(record) { try stop() }
        guard let record else { return false }
        guard try installedRecord() == record else { throw unowned }
        try FileManager.default.removeItem(at: plist)
        return true
    }

    private func stop() throws {
        if launchctl(["bootout", service]) != 0, jobDescription(service) != nil {
            throw NotesError("editor_login_unavailable", "Could not stop the editor login job. Try again from the desktop session.")
        }
    }

    private var unowned: NotesError {
        NotesError("editor_login_not_owned", "The editor login job does not match Notes CLI. It was left unchanged.")
    }
}

enum EditorLoginRuntime: Equatable {
    case notLoaded, starting, running, stopped(Int?), unknown

    init(jobDescription: String) {
        let lines = jobDescription.split(whereSeparator: \.isNewline)
        func value(_ key: String) -> String? {
            let prefix = "\(key) = "
            return lines.lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
        }
        switch value("state") {
        case "running": self = .running
        case "spawn scheduled", "xpcproxy", "spawned": self = .starting
        case "not running", "exited": self = .stopped(value("last exit code").flatMap(Int.init))
        default: self = .unknown
        }
    }

    var message: String {
        switch self {
        case .notLoaded: "Editor job not loaded in this desktop session."
        case .starting: "Editor job is starting."
        case .running: "Editor job is running."
        case .stopped(4): "Editor stopped: macOS denied Accessibility. Run 'notescli editor --open-accessibility', allow Notes CLI, then run 'notescli editor --login enable' again."
        case .stopped: "Editor job is not running. Run 'notescli editor --export-logs' for details."
        case .unknown: "Could not determine whether the editor job is running."
        }
    }
}

enum EditorInstance {
    static var lockURL: URL { CapabilityHostPaths.supportDirectory.appendingPathComponent("editor-instance.lock") }

    static func acquire(at url: URL = lockURL) throws -> Int32 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let unavailable = NotesError("editor_lock_unavailable", "Could not open the editor instance lock.")
        let fd = open(url.path, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else {
            close(fd)
            throw unavailable
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        let code = errno
        close(fd)
        if code == EWOULDBLOCK {
            throw NotesError("editor_already_running", "The Notes editor is already running in this account.")
        }
        throw unavailable
    }
}
