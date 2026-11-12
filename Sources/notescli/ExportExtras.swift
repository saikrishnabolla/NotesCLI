import ArgumentParser
import Foundation
import NotesCore
import NotesSync

struct FileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "file", abstract: "Sync one Markdown file with one note.",
                                                    subcommands: [FilePull.self, FilePush.self, FileDiff.self])
}

private struct FilePull: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pull")
    @OptionGroup var options: GlobalOptions
    @Argument var note: String
    @Argument var path: String
    @Flag var dryRun = false

    func run() throws {
        let backend = try options.backends()
        let report = try SingleFileSync(reader: backend.reader, writer: nil).pull(note: note, to: fileURL(path), dryRun: dryRun)
        try printFileSync(report, json: options.json)
    }
}

private struct FilePush: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "push")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var path: String

    func run() throws {
        let backend = try write.dryRun ? options.backends() : options.writable()
        let url = fileURL(path)
        let markdown = MarkdownFile.parse(try String(contentsOf: url, encoding: .utf8), fallbackTitle: url.deletingPathExtension().lastPathComponent)
        guard let noteID = markdown.noteID else { throw NotesError("invalid_file", "The Markdown file must contain notes-id front matter.") }
        let note = try backend.reader.note(noteID)
        let plan = DryRunPlan(operation: "filePush", target: note.summary.id.uuid, arguments: ["path": url.path],
                              resultingHTML: SafetyExecutor.html(note))
        var report: FileSyncReport? = write.dryRun ? try SingleFileSync(reader: backend.reader, writer: nil).push(from: url, dryRun: true) : nil
        let result = try SafetyExecutor.run(options: write, operation: "filePush", arguments: ["path": url.path], note: note,
            allowedPaths: [note.summary.folderPath], destructive: true, plan: plan, emitDryRun: false, action: {
                do {
                    let writer = try bodyRewriteWriter(options: options, allowDowngrade: write.allowDowngrade,
                                                       allowShared: write.allowShared, backend: backend)
                    let value = try SingleFileSync(reader: backend.reader, writer: writer).push(from: url)
                    report = value
                    return WriteResult(outcome: .verified, noteID: note.summary.id, message: value.message)
                } catch NotesSyncError.writeUnknown(let message) {
                    return WriteResult(outcome: .unknown, noteID: note.summary.id, message: message)
                }
            })
        if let report { try printFileSync(report, json: options.json) }
        else if let result { try Output.write(result, json: options.json) }
    }
}

private struct FileDiff: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diff")
    @OptionGroup var options: GlobalOptions
    @Argument var path: String

    func run() throws {
        let backend = try options.backends()
        let report = try SingleFileSync(reader: backend.reader, writer: nil).diff(fileURL(path))
        try printFileSync(report, json: options.json)
    }
}

private func fileURL(_ value: String) -> URL {
    URL(fileURLWithPath: NSString(string: value).expandingTildeInPath).standardizedFileURL
}

private func printFileSync(_ report: FileSyncReport, json: Bool) throws {
    if json { try Output.json(report) }
    else {
        Output.table(["ACTION", "ID", "PATH", "DETAIL"],
                     [[report.action.rawValue, report.noteID, report.path, report.message]])
    }
}
