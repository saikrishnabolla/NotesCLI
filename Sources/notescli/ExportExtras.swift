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
    @Argument var path: String
    @Flag var dryRun = false

    func run() throws {
        let backend = try dryRun ? options.backends() : options.writable()
        let report = try SingleFileSync(reader: backend.reader, writer: dryRun ? nil : backend.writer())
            .push(from: fileURL(path), dryRun: dryRun)
        try printFileSync(report, json: options.json)
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
