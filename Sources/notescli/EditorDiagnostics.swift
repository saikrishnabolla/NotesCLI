import Darwin
import Foundation
import NotesCore

enum EditorDiagnosticEvent: String, CaseIterable, Codable {
    case shortcutStartupFailed, shortcutLayoutUnsupported, shortcutRegistrationFailed
    case searchLoadFailed, searchNoteActionFailed, searchLaunchFailed
    case invalidConfiguration, accessibilityRequired, desktopSessionUnavailable
    case templatePasteUnavailable, templateInsertionUnconfirmed, templatePreparationFailed, clipboardRestoreFailed
}

struct EditorDiagnosticReport: Encodable {
    struct Entry: Encodable {
        let event: EditorDiagnosticEvent
        let lastSeen: Date
    }

    let schemaVersion = 1
    let notesCLIVersion: String
    let macOSVersion: String
    let events: [Entry]
}

/// A bounded local log: one empty marker per event. Only its modification time is exported.
struct EditorDiagnostics {
    let directory: URL
    private static var local: Self {
        Self(directory: MCPConfiguration.home.appendingPathComponent("Library/Caches/NotesCLI/editor-events",
                                                                       isDirectory: true))
    }

    static func record(_ event: EditorDiagnosticEvent) { try? local.record(event) }
    static func export() throws { try Output.json(local.report()) }

    func record(_ event: EditorDiagnosticEvent) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        guard try isPrivateDirectory() else { return }
        try Data().write(to: directory.appendingPathComponent(event.rawValue), options: .atomic)
    }

    func report(now: Date = Date()) throws -> EditorDiagnosticReport {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let events: [EditorDiagnosticReport.Entry]
        if try isPrivateDirectory() {
            events = EditorDiagnosticEvent.allCases.compactMap { event in
                let marker = directory.appendingPathComponent(event.rawValue)
                guard let values = try? marker.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
                ]), values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == 0,
                      let lastSeen = values.contentModificationDate, lastSeen <= now,
                      now.timeIntervalSince(lastSeen) <= 7 * 86_400 else { return nil }
                return .init(event: event, lastSeen: lastSeen)
            }.sorted {
                if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
                return $0.event.rawValue < $1.event.rawValue
            }
        } else {
            events = []
        }
        return .init(notesCLIVersion: notesCLIVersion,
                     macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", events: events)
    }

    private func isPrivateDirectory() throws -> Bool {
        var entry = stat()
        if lstat(directory.path, &entry) != 0 {
            if errno == ENOENT { return false }
            throw NotesError("editor_logs_unavailable", "Could not read the editor diagnostics folder.")
        }
        guard (entry.st_mode & S_IFMT) == S_IFDIR, entry.st_uid == getuid(), (entry.st_mode & 0o077) == 0 else {
            throw NotesError("editor_logs_unavailable", "The editor diagnostics folder is not private.")
        }
        return true
    }
}
