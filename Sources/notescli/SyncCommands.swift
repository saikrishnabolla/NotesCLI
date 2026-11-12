import ArgumentParser
import Foundation
import NotesCore
import NotesSync

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Synchronize Markdown files with a Notes folder.")
    @OptionGroup var options: GlobalOptions
    @Argument(help: "Directory to sync, or 'status' to inspect the current directory.") var directory: String
    @Option var folder: String?
    @Option(name: .customLong("dir"), help: "Directory used by 'sync status'.") var statusDirectory: String?
    @Flag var propagateDeletes = false
    @Flag var allowDowngrade = false
    @Flag var dryRun = false

    func run() throws {
        let isStatus = directory == "status"
        let path = isStatus ? (statusDirectory ?? FileManager.default.currentDirectoryPath) : directory
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true).standardizedFileURL
        guard let selectedFolder = folder ?? MarkdownSync.syncedFolder(at: url) else {
            throw NotesError("invalid_sync_folder", "Provide --folder for the first sync.")
        }
        let backend = try (dryRun || isStatus) ? options.backends() : options.writable()
        let writer: (any NotesWriting)?
        if dryRun || isStatus { writer = nil }
        else {
            writer = try bodyRewriteWriter(options: options, allowDowngrade: allowDowngrade,
                                           allowShared: false, backend: backend)
        }
        let report = try MarkdownSync(reader: backend.reader, writer: writer).run(
            SyncOptions(directory: url, folder: selectedFolder, propagateDeletes: propagateDeletes, dryRun: dryRun || isStatus))
        try printSync(report, json: options.json)
    }
}

struct SyncDaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync-daemon", abstract: "Run Markdown sync at a fixed interval.")
    @OptionGroup var options: GlobalOptions
    @Argument var directory: String
    @Option var folder: String?
    @Option var interval: Double = 30
    @Flag var propagateDeletes = false
    @Flag var allowDowngrade = false
    @Flag var dryRun = false

    func validate() throws { if interval <= 0 { throw ValidationError("--interval must be greater than zero.") } }

    func run() throws {
        let url = URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath, isDirectory: true).standardizedFileURL
        guard let selectedFolder = folder ?? MarkdownSync.syncedFolder(at: url) else {
            throw NotesError("invalid_sync_folder", "Provide --folder for the first sync.")
        }
        while true {
            do {
                let backend = try dryRun ? options.backends() : options.writable()
                let writer: (any NotesWriting)?
                if dryRun { writer = nil }
                else {
                    writer = try bodyRewriteWriter(options: options, allowDowngrade: allowDowngrade,
                                                   allowShared: false, backend: backend)
                }
                let report = try MarkdownSync(reader: backend.reader, writer: writer).run(
                    SyncOptions(directory: url, folder: selectedFolder, propagateDeletes: propagateDeletes, dryRun: dryRun))
                try printSync(report, json: options.json)
            } catch let error as NotesSyncError {
                if case .writeUnknown = error { throw error }
                Output.error(error.description)
            } catch { Output.error(String(describing: error)) }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}

struct WatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch", abstract: "Stream note create, modify, and delete events.")
    @OptionGroup var options: GlobalOptions
    @Option var folder: String?
    @Option var interval: Double = 2
    @Option(name: .customLong("exec")) var command: String?

    func validate() throws { if interval <= 0 { throw ValidationError("--interval must be greater than zero.") } }

    func run() throws {
        let backendName = options.backend
        let poller = NoteEventPoller(makeReader: { try Backends.make(backendName).reader }, folder: folder)
        _ = try poller.poll()
        let wal = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite-wal")
        let wakeup = NotesDatabaseWakeup(walURL: wal)
        while true {
            wakeup.wait(timeout: interval)
            for event in try poller.poll() {
                if options.json { try Output.json(event) }
                else { Output.table(["EVENT", "ID", "TITLE", "FOLDER"], [[event.kind.rawValue, event.noteID, event.title, event.folder.joined(separator: " > ")]]) }
                if let command { try execute(command, event: event) }
            }
        }
    }

    private func execute(_ command: String, event: NoteEvent) throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_HOST_ACTIVE"] != "1" else {
            throw NotesError("host_command_refused", "watch --exec cannot run through the capability host.")
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "NOTESCLI_EVENT": event.kind.rawValue, "NOTESCLI_NOTE_ID": event.noteID,
            "NOTESCLI_TITLE": event.title, "NOTESCLI_FOLDER": event.folder.joined(separator: " > "),
        ]) { _, value in value }
        process.standardOutput = FileHandle.standardError; process.standardError = FileHandle.standardError
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 { Output.error("watch --exec exited with status \(process.terminationStatus).") }
    }
}

private func printSync(_ report: SyncReport, json: Bool) throws {
    if json { try Output.json(report) }
    else {
        Output.table(["ACTION", "ID", "PATH", "DETAIL"], report.actions.map { [$0.kind.rawValue, $0.noteID ?? "", $0.path ?? "", $0.message] })
        Output.error("Actions \(report.actions.count), conflicts \(report.conflicts), refused attachments \(report.refusedAttachments).")
    }
}
