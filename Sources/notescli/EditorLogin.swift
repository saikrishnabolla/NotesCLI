import Darwin
import Foundation
import NotesCore
import NotesHost

struct EditorLogin {
    static let label = "com.saikrishnabolla.notescli.editor"
    static var local: Self {
        Self(plist: CapabilityHostPaths.launchAgent.deletingLastPathComponent().appendingPathComponent("\(label).plist"),
             app: CapabilityHostPaths.app, uid: getuid(), launchctl: HostInstallation.launchctl)
    }

    let plist: URL
    let app: URL
    let uid: uid_t
    let launchctl: ([String]) -> Int32
    private var domain: String { "gui/\(uid)" }
    private var service: String { "\(domain)/\(Self.label)" }

    var loaded: Bool { launchctl(["print", service]) == 0 }

    func runtimeStatus() -> EditorLoginRuntime {
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
            if task.terminationStatus == 0, let text = String(data: data, encoding: .utf8) {
                return EditorLoginRuntime(jobDescription: text)
            }
        } catch {}
        return .notLoaded
    }

    func launchAgentData() throws -> Data {
        let object: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [app.appendingPathComponent("Contents/Helpers/notescli").path, "editor"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "Umask": 63,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    func isEnabled() throws -> Bool {
        let fd = open(plist.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return false }
        guard fd >= 0 else { throw unowned }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == uid, info.st_mode & S_IFMT == S_IFREG,
              (1...4096).contains(info.st_size),
              let data = try FileHandle(fileDescriptor: fd).read(upToCount: 4096),
              data == (try launchAgentData()) else { throw unowned }
        return true
    }

    func enable(validate: (URL) -> Bool = HostInstallation.validSignature) throws {
        guard validate(app) else {
            throw NotesError("editor_login_app_missing", "Run 'notescli onboard' to install the signed app first.")
        }
        let existing = try isEnabled()
        if loaded {
            guard existing else { throw unowned }
            guard launchctl(["kickstart", service]) == 0 else {
                throw NotesError("editor_login_unavailable", "Editor startup is enabled, but the editor could not be started. Check 'notescli editor --export-logs'.")
            }
            return
        }
        if !existing {
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try launchAgentData().write(to: plist, options: .withoutOverwriting)
        }
        if launchctl(["bootstrap", domain, plist.path]) != 0, !loaded {
            if !existing, try isEnabled() { try FileManager.default.removeItem(at: plist) }
            throw NotesError("editor_login_unavailable", "Could not register editor startup in this macOS desktop session.")
        }
    }

    @discardableResult
    func disable() throws -> Bool {
        guard try isEnabled() else { return false }
        if loaded, launchctl(["bootout", service]) != 0, loaded {
            throw NotesError("editor_login_unavailable", "Could not stop the editor login job. Try again from the desktop session.")
        }
        try FileManager.default.removeItem(at: plist)
        return true
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
