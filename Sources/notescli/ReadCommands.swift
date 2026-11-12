import ArgumentParser
import Foundation
import NotesCore
import NotesIndex
import NotesMCP
import NotesStore

extension NoteSort: ExpressibleByArgument {}

struct ReadList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", discussion: """
        EXAMPLES:
          notescli list --limit 20
          notescli list --folder "Projects" --tag research --json
        """)
    @OptionGroup var options: GlobalOptions
    @Option var folder: String?
    @Option var account: String?
    @Flag var pinned = false
    @Option var tag: String?
    @Option var since: String?
    @Option var until: String?
    @Option var limit: Int?
    @Option(name: .long, help: "Require an attachment kind. Repeat or separate kinds with |.") var has: [String] = []
    @Option(help: "Continue from an opaque stable cursor.") var cursor: String?
    @Option var sort: NoteSort = .modified
    @Flag var includeDeleted = false
    func validate() throws { try positive(limit, name: "limit") }
    func run() throws {
        let after = try since.map { try NotePresentation.date($0) }, before = try until.map { try NotePresentation.date($0) }
        if let after, let before, after > before { throw ValidationError("--since must precede --until.") }
        let query = NoteQuery(folder: folder, account: account, includeDeleted: includeDeleted, pinnedOnly: pinned,
                              tag: tag, modifiedAfter: after, modifiedBefore: before, attachmentKinds: try parseAttachmentKinds(has))
        let backend = try options.backends()
        let page = try ReadCursorPaging.page(backend.reader.notes(query, sort: sort), sort: sort, cursor: cursor, limit: limit)
        if options.json { try Output.readJSON(page, backend: backend) }
        else {
            try Output.notes(page.notes, json: false, backend: backend)
            if let next = page.nextCursor, !options.quiet { print("Next cursor: \(next)") }
        }
    }
}

struct IndexedSearch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", discussion: """
        EXAMPLES:
          notescli search "quarterly results" --limit 10
          notescli search "tag:research AND has:pdf" --index --json
        """)
    @OptionGroup var options: GlobalOptions
    @Argument var query: String
    @Option var folder: String?
    @Option var limit: Int?
    @Flag var fuzzy = false
    @Flag(name: .long, help: "Use the local FTS index and boolean query syntax.") var index = false
    @Flag(help: "Rebuild the local index before searching.") var rebuild = false
    @Option(name: .long, help: "Require an attachment kind. Repeat or separate kinds with |.") var has: [String] = []
    @Option(help: "Continue from an opaque stable cursor.") var cursor: String?
    func validate() throws { try positive(limit, name: "limit") }
    func run() throws {
        let backend = try options.backends(), reader = backend.reader
        if index {
            let local = LocalNotesIndex(); _ = try local.update(from: reader, rebuild: rebuild)
            let kindQuery = try parseAttachmentKinds(has).map { "has:\($0)" }.joined(separator: " AND ")
            let effectiveQuery = kindQuery.isEmpty ? query : "(\(query)) AND \(kindQuery)"
            let page = try ReadCursorPaging.searchPage(local.search(effectiveQuery, folder: folder, limit: 5000), cursor: cursor, limit: limit ?? 50)
            if options.json { try Output.readJSON(page, backend: backend) }
            else {
                Output.table(["#ID", "ID", "TITLE", "FOLDER", "SCORE", "SNIPPET"], page.hits.map { [$0.number.map { "#\($0)" } ?? $0.shortID ?? "", $0.noteID, $0.title, $0.folder, String(format: "%.0f", $0.score), $0.snippet] })
                if let next = page.nextCursor, !options.quiet { print("Next cursor: \(next)") }
            }
            return
        }
        if fuzzy {
            let candidates = try reader.notes(NoteQuery(folder: folder))
            var scored: [(summary: NoteSummary, score: Int)] = []
            for summary in candidates {
                let body = (try? reader.note(summary.id.uuid))?.document?.text ?? ""
                let score = FuzzySearch.score(query: query, title: summary.title, snippet: summary.snippet, body: body)
                if score > 0 { scored.append((summary, score)) }
            }
            scored.sort { $0.score == $1.score ? $0.summary.id.uuid < $1.summary.id.uuid : $0.score > $1.score }
            let page = try ReadCursorPaging.fuzzyPage(scored, cursor: cursor, limit: limit)
            if options.json { try Output.readJSON(page, backend: backend) }
            else {
                try Output.notes(page.notes, json: false, backend: backend)
                if let next = page.nextCursor, !options.quiet { print("Next cursor: \(next)") }
            }
            return
        }
        let notes = try reader.notes(NoteQuery(folder: folder, text: query, attachmentKinds: try parseAttachmentKinds(has)))
        let page = try ReadCursorPaging.page(notes, sort: .modified, cursor: cursor, limit: limit)
        if options.json { try Output.readJSON(page, backend: backend) }
        else {
            try Output.notes(page.notes, json: false, backend: backend)
            if let next = page.nextCursor, !options.quiet { print("Next cursor: \(next)") }
        }
    }
}

private struct FetchResult: Codable {
    var id: String
    var status: String
    var error: String?
}

struct Fetch: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String?
    @Flag var all = false
    @Option var wait: Double = 30
    func validate() throws {
        guard (ref != nil) != all else { throw ValidationError("Provide one REF or --all.") }
        guard wait >= 0 else { throw ValidationError("--wait must be nonnegative.") }
    }
    func run() throws {
        let backend = try options.backends()
        let candidates = try all ? backend.reader.notes(NoteQuery()) : [backend.reader.summary(ref!)]
        var results: [String: FetchResult] = [:]
        for summary in candidates {
            if summary.isLocked {
                results[summary.id.uuid] = FetchResult(id: summary.id.uuid, status: "failed", error: "note_locked")
                continue
            }
            do {
                _ = try backend.reader.note(summary.id.uuid)
                results[summary.id.uuid] = FetchResult(id: summary.id.uuid, status: "downloaded")
            } catch let error as NotesError where error.code == "body_unavailable" {
                do {
                    do { try backend.openNote(summary.id) }
                    catch let error as NotesError where error.code == "note_not_found" { try Self.openDeepLink(summary.deepLink ?? "applenotes://showNote?identifier=\(summary.id.uuid)") }
                    results[summary.id.uuid] = FetchResult(id: summary.id.uuid, status: "still pending")
                } catch { results[summary.id.uuid] = FetchResult(id: summary.id.uuid, status: "failed", error: Self.safeError(error)) }
            } catch { results[summary.id.uuid] = FetchResult(id: summary.id.uuid, status: "failed", error: Self.safeError(error)) }
        }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline, results.values.contains(where: { $0.status == "still pending" }) {
            Thread.sleep(forTimeInterval: min(0.5, max(0, deadline.timeIntervalSinceNow)))
            guard let fresh = try? SQLiteNotesStore(refresh: true) else { continue }
            for id in results.keys where results[id]?.status == "still pending" {
                do { _ = try fresh.note(id); results[id]?.status = "downloaded" }
                catch let error as NotesError where error.code == "body_unavailable" { continue }
                catch { results[id]?.status = "failed"; results[id]?.error = Self.safeError(error) }
            }
        }
        let output = results.values.sorted { $0.id < $1.id }
        if options.json { try Output.json(output) }
        else { Output.table(["ID", "STATUS", "ERROR"], output.map { [$0.id, $0.status, $0.error ?? ""] }) }
    }
    private static func safeError(_ error: Error) -> String {
        if let error = error as? NotesError { return error.code }
        return "fetch_failed"
    }
    private static func openDeepLink(_ link: String) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [link]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NotesError("fetch_trigger_failed", "Notes could not open the note deep link.") }
    }
}

struct IndexCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "index")
    @OptionGroup var options: GlobalOptions
    @Flag var rebuild = false
    @Flag var status = false
    @Flag var background = false
    @Flag var cancel = false
    @Flag(name: .customLong("background-worker"), help: .hidden) var backgroundWorker = false
    func validate() throws {
        if [status, background, cancel, backgroundWorker].filter({ $0 }).count > 1 { throw ValidationError("Choose one index action.") }
    }
    func run() throws {
        let index = LocalNotesIndex()
        if background {
            var arguments: [String] = []
            if let backend = options.backend { arguments += ["--backend", backend] }
            arguments += ["index", "--background-worker"]
            if rebuild { arguments.append("--rebuild") }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
            let value = try NotesIndexJobs.start(executable: executable, arguments: arguments)
            if options.json { try Output.json(value) } else { Output.table(["STATE", "PID"], [[value.state, value.pid.map(String.init) ?? ""]]) }
            return
        }
        if cancel {
            let value = try NotesIndexJobs.cancel()
            if options.json { try Output.json(value) } else { Output.table(["STATE", "PID"], [[value.state, value.pid.map(String.init) ?? ""]]) }
            return
        }
        if status {
            let value = IndexStatusOutput(index: try index.status(), job: NotesIndexJobs.status())
            if options.json { try Output.json(value) }
            else { Output.table(["PATH", "NOTES", "BYTES", "LAST INDEXED", "JOB", "PROGRESS"], [[value.index.path, String(value.index.noteCount), String(value.index.fileSize), value.index.lastIndexed.map { ISO8601DateFormatter().string(from: $0) } ?? "never", value.job.state, "\(value.job.current)/\(value.job.total)"]]) }
            return
        }
        if backgroundWorker {
            do {
                _ = try index.update(from: options.backends().reader, rebuild: rebuild) { NotesIndexJobs.report(current: $0, total: $1) }
                NotesIndexJobs.finish(); return
            } catch { NotesIndexJobs.finish(error: error); throw error }
        }
        let value = try index.update(from: options.backends().reader, rebuild: rebuild)
        if options.json { try Output.json(value) }
        else { Output.table(["PATH", "NOTES", "BYTES", "LAST INDEXED"], [[value.path, String(value.noteCount), String(value.fileSize), value.lastIndexed.map { ISO8601DateFormatter().string(from: $0) } ?? "never"]]) }
    }
}

private struct StatsValue: Codable {
    var total: Int
    var byFolder: [String: Int]
    var byAccount: [String: Int]
    var byKind: [String: Int]
}

struct Stats: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let reader = try options.backends().reader, notes = try reader.notes(NoteQuery(includeDeleted: true))
        var folders: [String: Int] = [:], accounts: [String: Int] = [:]
        for note in notes { folders[note.folderPath.joined(separator: " > "), default: 0] += 1; accounts[note.accountID, default: 0] += 1 }
        let value = StatsValue(total: notes.count, byFolder: folders, byAccount: accounts, byKind: try reader.attachmentKindCounts())
        if options.json { try Output.json(value) }
        else {
            Output.table(["METRIC", "VALUE"], [["notes", String(value.total)]])
            Output.table(["FOLDER", "NOTES"], value.byFolder.keys.sorted().map { [$0, String(value.byFolder[$0]!)] })
            Output.table(["ACCOUNT", "NOTES"], value.byAccount.keys.sorted().map { [$0, String(value.byAccount[$0]!)] })
            Output.table(["KIND", "COUNT"], value.byKind.keys.sorted().map { [$0, String(value.byKind[$0]!)] })
        }
    }
}

struct Count: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Option var folder: String?
    @Option var account: String?
    @Flag var includeDeleted = false
    func run() throws {
        let count = try options.backends().reader.notes(NoteQuery(folder: folder, account: account, includeDeleted: includeDeleted)).count
        if options.json { try Output.json(["count": count]) } else { print(count) }
    }
}

struct ShowMany: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show-many")
    @OptionGroup var options: GlobalOptions
    @Argument var refs: [String]
    @Option var format: NoteFormat = .markdown
    @Flag var noAttachments = false
    func validate() throws { if refs.isEmpty { throw ValidationError("Provide at least one REF.") } }
    func run() throws {
        let reader = try options.backends().reader, notes = try refs.map(reader.note)
        if options.json || format == .json { try Output.json(notes); return }
        for (index, note) in notes.enumerated() {
            if index > 0 { print("\n---\n") }
            print(try NotePresentation.render(note, format: format.rawValue, attachments: !noAttachments))
        }
    }
}

struct Selection: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let source = #"function run(){const a=Application('com.apple.Notes');return JSON.stringify((a.selection()||[]).map(x=>x.id()));}"#
        let process = Process(); let output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]
        process.standardOutput = output; process.standardError = error
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NotesError("automation_failed", "Cannot read the Notes selection.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let ids = try JSONSerialization.jsonObject(with: data) as? [String] else { throw NotesError("automation_failed", "Notes returned an invalid selection.") }
        let reader = try options.backends().reader, selected = ids.compactMap { try? reader.summary($0) }
        try Output.notes(selected, json: options.json)
    }
}

struct Link: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    func run() throws {
        let summary = try options.backends().reader.summary(ref)
        let link = summary.deepLink ?? "applenotes://showNote?identifier=\(summary.id.uuid)"
        if options.json { try Output.json(["url": link]) } else { print(link) }
    }
}

struct Backlinks: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    func run() throws { try Output.notes(options.backends().reader.backlinks(ref), json: options.json) }
}

struct AttachmentsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "attachments")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Option var save: String?
    @Option var preview: String?
    func run() throws {
        var attachments = try options.backends().reader.attachments(ref)
        if let preview {
            let root = URL(fileURLWithPath: NSString(string: preview).expandingTildeInPath, isDirectory: true).standardizedFileURL
            let values = try AttachmentPreviewer.write(attachments, to: root)
            if options.json { try Output.json(values) }
            else { Output.table(["ID", "KIND", "PREVIEW"], values.map { [$0.attachmentID, $0.kind, $0.path] }) }
            return
        }
        if let save {
            let root = URL(fileURLWithPath: NSString(string: save).expandingTildeInPath, isDirectory: true).standardizedFileURL
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let boundary = root.resolvingSymlinksInPath().path + "/"
            var copied: [String: String] = [:]
            func copy(_ path: String, name: String) throws -> String {
                let source = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                if let existing = copied[source.path] { return existing }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    throw NotesError("attachment_unavailable", "An attachment original is not available on disk.")
                }
                let safeName = URL(fileURLWithPath: name).lastPathComponent.replacingOccurrences(of: "/", with: "_")
                let target = root.appendingPathComponent(safeName).standardizedFileURL
                guard target.resolvingSymlinksInPath().path.hasPrefix(boundary) else { throw NotesError("invalid_export_path", "Attachment path leaves the output directory.") }
                guard !FileManager.default.fileExists(atPath: target.path) else { throw NotesError("file_exists", "Refusing to replace an existing attachment file: \(target.lastPathComponent)") }
                try FileManager.default.copyItem(at: source, to: target)
                copied[source.path] = target.path
                return target.path
            }
            for index in attachments.indices {
                let id = attachments[index].id.replacingOccurrences(of: "/", with: "_")
                if let path = attachments[index].filePath {
                    let source = URL(fileURLWithPath: path)
                    attachments[index].filePath = try copy(path, name: id + "-" + (attachments[index].filename ?? source.lastPathComponent))
                }
                if let pages = attachments[index].pageImagePaths {
                    attachments[index].pageImagePaths = try pages.enumerated().map { page, path in
                        let ext = URL(fileURLWithPath: path).pathExtension
                        return try copy(path, name: "\(id)-page-\(page + 1)" + (ext.isEmpty ? "" : ".\(ext)"))
                    }
                }
                if let raster = attachments[index].fallbackRasterPath {
                    let ext = URL(fileURLWithPath: raster).pathExtension
                    attachments[index].fallbackRasterPath = try copy(raster, name: id + "-fallback" + (ext.isEmpty ? "" : ".\(ext)"))
                }
            }
        }
        if options.json { try Output.json(attachments) }
        else { Output.table(["ID", "KIND", "FILE", "PATH"], attachments.map { [$0.id, $0.kind, $0.filename ?? "", $0.filePath ?? "not downloaded"] }) }
    }
}

struct Raw: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    func run() throws { try Output.json(options.backends().reader.rawNote(ref)) }
}

struct Deleted: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let notes = try options.backends().reader.notes(NoteQuery(includeDeleted: true)).filter(\.isDeleted)
        try Output.notes(notes, json: options.json)
    }
}

struct SmartFolders: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-folders")
    @OptionGroup var options: GlobalOptions
    @Flag var evaluate = false
    func run() throws {
        let folders = try options.backends().reader.smartFolders(evaluate: evaluate)
        if options.json { try Output.json(folders) }
        else { Output.table(["ID", "FOLDER", "RULES", "MATCHES", "UNSUPPORTED"], folders.map { [$0.folder.id, $0.folder.path.joined(separator: " > "), $0.rules.joined(separator: "; "), $0.matchingNoteIDs.map { String($0.count) } ?? "", $0.unsupportedRules.joined(separator: "; ")] }) }
    }
}
