import Foundation
import NotesCore

enum InstalledFileCategory: String, Codable {
    case config
    case runtime
}

struct MCPInstallRecord: Codable, Equatable {
    var client: String
    var readOnly: Bool
    var allowNative: Bool
}

struct InstalledFileRecord: Codable, Equatable {
    var path: String
    var category: InstalledFileCategory
}

struct InstallManifestDocument: Codable {
    var schemaVersion = 1
    var owner = "NotesCLI"
    var mcpClients: [MCPInstallRecord] = []
    var files: [InstalledFileRecord] = []
}

enum InstallManifest {
    static var applicationSupport: URL {
        MCPConfiguration.home.appendingPathComponent("Library/Application Support/NotesCLI", isDirectory: true)
    }

    static var url: URL { applicationSupport.appendingPathComponent("install-manifest.json") }

    static func recordMCPClient(_ client: MCPClient, readOnly: Bool, allowNative: Bool) throws {
        var manifest = try load()
        manifest.mcpClients.removeAll { $0.client == client.rawValue }
        manifest.mcpClients.append(MCPInstallRecord(client: client.rawValue, readOnly: readOnly, allowNative: allowNative))
        manifest.mcpClients.sort { $0.client < $1.client }
        try save(manifest)
    }

    static func ownsMCPClient(_ client: MCPClient) throws -> Bool {
        try load().mcpClients.contains { $0.client == client.rawValue }
    }

    static func removeMCPClient(_ client: MCPClient) throws {
        var manifest = try load()
        manifest.mcpClients.removeAll { $0.client == client.rawValue }
        try save(manifest)
    }

    static func recordFile(_ file: URL, category: InstalledFileCategory) throws {
        let path = try validatedOwnedPath(file)
        var manifest = try load()
        manifest.files.removeAll { $0.path == path }
        manifest.files.append(InstalledFileRecord(path: path, category: category))
        manifest.files.sort { $0.path < $1.path }
        try save(manifest)
    }

    static func filesToRemove(keepConfig: Bool) throws -> [InstalledFileRecord] {
        let manifest = try load()
        return try manifest.files.filter { !keepConfig || $0.category != .config }.map { record in
            var record = record
            record.path = try validatedOwnedPath(URL(fileURLWithPath: record.path))
            return record
        }
    }

    static func removeRecordedFile(_ record: InstalledFileRecord, fileManager: FileManager = .default) throws {
        var manifest = try load()
        guard manifest.files.contains(record) else {
            throw NotesError("uninstall_not_owned", "Refusing to remove a file not recorded by NotesCLI.")
        }
        let path = try validatedOwnedPath(URL(fileURLWithPath: record.path))
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw NotesError("uninstall_path_refused", "Refusing to remove a directory from the install manifest.")
            }
            try fileManager.removeItem(atPath: path)
        }
        manifest.files.removeAll { $0 == record }
        try save(manifest)
    }

    static func removeManifestIfEmpty(keepConfig: Bool, fileManager: FileManager = .default) throws {
        guard !keepConfig else { return }
        let manifest = try load()
        guard manifest.mcpClients.isEmpty, manifest.files.isEmpty else { return }
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    static func load() throws -> InstallManifestDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return InstallManifestDocument() }
        let value = try JSONDecoder().decode(InstallManifestDocument.self, from: Data(contentsOf: url))
        guard value.owner == "NotesCLI", value.schemaVersion == 1 else {
            throw NotesError("invalid_install_manifest", "The NotesCLI install manifest has an unknown owner or version.")
        }
        return value
    }

    private static func save(_ manifest: InstallManifestDocument) throws {
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (try encoder.encode(manifest) + Data("\n".utf8)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func validatedOwnedPath(_ file: URL) throws -> String {
        let path = file.standardizedFileURL.path
        let support = applicationSupport.standardizedFileURL.path + "/"
        let launchAgents = MCPConfiguration.home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .standardizedFileURL.path + "/"
        let isSupportFile = path.hasPrefix(support) && path != url.path
        let name = URL(fileURLWithPath: path).lastPathComponent
        let isLaunchAgent = path.hasPrefix(launchAgents) && name.hasPrefix("com.saikrishnabolla.notescli") && name.hasSuffix(".plist")
        guard isSupportFile || isLaunchAgent else {
            throw NotesError("uninstall_path_refused", "Refusing a path outside NotesCLI-owned locations.")
        }
        return path
    }
}
