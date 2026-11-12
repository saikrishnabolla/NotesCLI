import Foundation

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
