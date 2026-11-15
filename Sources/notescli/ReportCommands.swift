import ArgumentParser
import Foundation
import NotesCore
import NotesNative
import NotesSafety

struct ReportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Create a verified native Apple Notes report.",
        subcommands: [ReportCreate.self]
    )
}

struct ReportCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option var title: String
    @Option var file: String
    @Option var folder: String?
    @Option(help: "Comma-separated native tags.") var tags: String?
    @Option(name: .long, parsing: .upToNextOption,
            help: "Local paths or HTTPS URLs to attach.") var attach: [String] = []
    @Flag(help: "Replace one exact-title report in the target folder.") var replace = false

    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        guard !backend.isFake else { throw NotesError("native_required", "Report creation requires the live native Notes engine.") }
        let source = URL(fileURLWithPath: NSString(string: file).expandingTildeInPath).standardizedFileURL
        let markdown = try readReportMarkdown(source)
        let reportTags = tags?.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty } ?? []
        let target = try NotesReportWriter.resolveTarget(
            title: title, folder: folder, replacing: replace, reader: backend.reader
        )
        let replaced = replace ? target.existing.first : nil
        let plan = DryRunPlan(operation: "createReport", target: title,
                              arguments: ["file": source.path, "folder": target.folder.id,
                                          "tags": reportTags.joined(separator: ","),
                                          "replace": String(replace)],
                              resultingHTML: SafetyExecutor.bodyHTML(title: title, markdown: markdown),
                              engine: "native")
        var captured: NativeReportResult?
        let result = try SafetyExecutor.run(
            options: write, operation: "createReport",
            arguments: ["title": title, "file": source.path, "folder": target.folder.id,
                        "tags": reportTags.joined(separator: ","), "replace": String(replace),
                        "engine": "native"],
            note: replaced, allowedPaths: [target.folder.path], destructive: replace, plan: plan
        ) {
            let value = try NotesReportWriter().create(NativeReportRequest(
                title: title, markdown: markdown, assetBaseDirectory: source.deletingLastPathComponent(),
                folder: target.folder.id, tags: reportTags, attachments: attach, replace: replace,
                allowShared: write.allowShared
            ))
            captured = value
            return value.write.writeResult
        }
        guard result != nil else { return }
        guard let captured else {
            throw NotesError("report_result_unavailable", "The report write completed without a verification summary.")
        }
        if options.json { try Output.json(captured) }
        else {
            let requested = captured.requested
            let written = captured.written
            Output.table(["ELEMENT", "REQUESTED", "WRITTEN"], [
                ["headings", String(requested.headings), String(written.headings)],
                ["tables", String(requested.tables), String(written.tables)],
                ["links", String(requested.links), String(written.links)],
                ["rich links", String(requested.richLinks), String(written.richLinks)],
                ["images", String(requested.images), String(written.images)],
                ["remote images", String(requested.remoteImages), String(written.remoteImages)],
                ["diagrams", String(requested.diagrams), String(written.diagrams)],
                ["tags", String(requested.tags), String(written.tags)],
                ["checklists", String(requested.checklists), String(written.checklists)],
                ["attachments", String(requested.attachments), String(written.attachments)],
                ["citations", String(requested.citations), String(written.citations)],
                ["dividers", String(requested.dividers), String(written.dividers)],
            ])
            Output.table(["OUTCOME", "ID", "LINK", "DEGRADED"], [[
                captured.write.writeResult.outcome.rawValue, captured.noteID,
                captured.noteLink, captured.degraded.joined(separator: ",")
            ]])
        }
    }
}

func readReportMarkdown(_ source: URL) throws -> String {
    do { return try InputFile.readText(source, kind: "report file", maxBytes: InputFile.maxTextBytes) }
    catch let error as NotesError where error.code == "input_path_refused" {
        let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.path == root || resolved.path.hasPrefix(root + "/") else { throw error }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: resolved.path) else {
            throw NotesError("invalid_file", "The report file must be a readable regular file.")
        }
        guard (values.fileSize ?? 0) <= InputFile.maxTextBytes else {
            throw NotesError("input_too_large", "The report file is larger than the 20 MB limit.")
        }
        let data = try Data(contentsOf: resolved, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NotesError("invalid_encoding", "The report file must be UTF-8 text.")
        }
        return text
    }
}
