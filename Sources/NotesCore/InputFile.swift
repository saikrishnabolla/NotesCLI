import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The one check every user-supplied input file passes before NotesCLI reads or converts it.
/// Allowed: the home folder outside `~/Library` and hidden folders, temporary folders, and `/Volumes`.
/// Symlinks are resolved first, so a link cannot point past the check.
public enum InputFile {
    /// Limit for Markdown, template, and other text inputs.
    public static let maxTextBytes = 20 * 1024 * 1024

    /// Returns the resolved file URL, or throws `input_path_refused`, `invalid_file`, or `input_too_large`.
    public static func validated(_ url: URL, kind: String, maxBytes: Int) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        guard isAllowed(resolved.path) else {
            throw NotesError("input_path_refused",
                             "The \(kind) must come from your home folder outside Library and hidden folders, a temporary folder, or an external volume.")
        }
        var directory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &directory), !directory.boolValue,
              fileManager.isReadableFile(atPath: resolved.path) else {
            throw NotesError("invalid_file", "The \(kind) must be a readable regular file.")
        }
        let size = (try? fileManager.attributesOfItem(atPath: resolved.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw tooLarge(kind, maxBytes) }
        return resolved
    }

    /// Validates the path, then reads at most `maxBytes` from the resolved file.
    public static func read(_ url: URL, kind: String, maxBytes: Int) throws -> Data {
        let resolved = try validated(url, kind: kind, maxBytes: maxBytes)
        let data: Data
        do { data = try Data(contentsOf: resolved, options: .mappedIfSafe) }
        catch { throw NotesError("invalid_file", "Could not read the \(kind): \(error.localizedDescription)") }
        guard data.count <= maxBytes else { throw tooLarge(kind, maxBytes) }
        return data
    }

    public static func readText(_ url: URL, kind: String, maxBytes: Int) throws -> String {
        guard let text = String(data: try read(url, kind: kind, maxBytes: maxBytes), encoding: .utf8) else {
            throw NotesError("invalid_encoding", "The \(kind) must be UTF-8 text.")
        }
        return text
    }

    /// Opens an already resolved source path without following a symlink swapped
    /// into any component after validation. All subsequent reads use this handle.
    public static func openRegularSource(_ url: URL, kind: String, maxBytes: Int) throws -> FileHandle {
        var path = url.standardizedFileURL.path
        guard url.isFileURL, isAllowed(path) else {
            throw NotesError("input_path_refused", "The \(kind) path is outside the allowed locations.")
        }
#if canImport(Darwin)
        // Foundation preserves these two system aliases even after resolving symlinks.
        if path.hasPrefix("/tmp/") || path.hasPrefix("/var/") { path = "/private" + path }
#endif
        let components = path.split(separator: "/")
        guard let name = components.last else { throw NotesError("invalid_file", "Choose a regular file.") }
        var dir = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { throw NotesError("invalid_file", "Could not open the \(kind) directory.") }
        defer { _ = close(dir) }
        for component in components.dropLast() {
            let next = openat(dir, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw NotesError("invalid_file", "The \(kind) directory is unreadable or changed.") }
            _ = close(dir)
            dir = next
        }
        let descriptor = openat(dir, String(name), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NotesError("invalid_file", "The \(kind) is unreadable or changed.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            _ = close(descriptor)
            throw NotesError("invalid_file", "The \(kind) must be a regular file.")
        }
        guard info.st_size <= maxBytes else {
            _ = close(descriptor)
            throw tooLarge(kind, maxBytes)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public static func readImportText(_ resolved: URL) throws -> String {
        let input = try openRegularSource(resolved, kind: "import document", maxBytes: maxTextBytes)
        defer { try? input.close() }
        var data = Data()
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maxTextBytes else { throw tooLarge("import document", maxTextBytes) }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NotesError("invalid_encoding", "The import document must be UTF-8 text.")
        }
        return text
    }

    public static func isAllowed(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        func inside(_ root: String) -> Bool { path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        let hiddenHomeComponent = inside(home) && path.dropFirst(home.count).split(separator: "/").contains { $0.hasPrefix(".") }
        let allowedHome = inside(home) && !inside(home + "/Library") && !hiddenHomeComponent
        let temporaryRoots = [NSTemporaryDirectory(), "/tmp", "/private/tmp", "/private/var/folders"]
        return allowedHome || temporaryRoots.contains(where: inside) || inside("/Volumes")
    }

    private static func tooLarge(_ kind: String, _ maxBytes: Int) -> NotesError {
        NotesError("input_too_large", "The \(kind) is larger than the \(byteText(maxBytes)) limit.")
    }

    public static func byteText(_ bytes: Int) -> String {
        if bytes >= 1_048_576, bytes % 1_048_576 == 0 { return "\(bytes / 1_048_576) MB" }
        if bytes >= 1_024, bytes % 1_024 == 0 { return "\(bytes / 1_024) KB" }
        return "\(bytes) bytes"
    }

}
