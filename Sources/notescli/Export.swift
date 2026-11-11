import ArgumentParser
import Foundation
import NotesCore
import NotesSync

enum ExportFormat: String, ExpressibleByArgument { case markdown, html, json, ndjson, sqlite, zip }

struct Export: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Option var out: String = "notes-export"
    @Option var folder: String?
    @Option var format: ExportFormat = .markdown
    @Flag(name: .customLong("attachments"), inversion: .prefixedNo) var attachments = true
    @Flag var embedMedia = false
    @Option(help: "Inline template or path to a template file.") var template: String?
    @Option var filename: String?
    @Flag var obsidian = false
    @Flag var prune = false

    func validate() throws {
        if embedMedia && format != .html { throw ValidationError("--embed-media requires --format html.") }
    }

    func run() throws {
        let reader = try options.backends().reader
        let output = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath).standardizedFileURL
        let templateText = try template.map { value -> String in
            let path = NSString(string: value).expandingTildeInPath
            return FileManager.default.fileExists(atPath: path) ? try String(contentsOfFile: path, encoding: .utf8) : value
        }
        let exportOptions = ExportOptions(output: output, folder: folder,
            format: NotesExportFormat(rawValue: format.rawValue)!, includeAttachments: attachments,
            embedMedia: embedMedia, template: templateText, filenameTemplate: filename,
            obsidian: obsidian, prune: prune)
        let report = try NotesExporter(reader: reader).run(exportOptions)
        for issue in report.incomplete { Output.error("Incomplete \(issue.noteID) \(issue.title): \(issue.reason)") }
        if options.json { try Output.json(report.files) }
        else {
            Output.table(["EXPORTED FILE"], report.files.map { [$0] })
            Output.error("Exported \(report.exported), unchanged \(report.unchanged), pruned \(report.pruned), incomplete \(report.incomplete.count).")
        }
    }
}
