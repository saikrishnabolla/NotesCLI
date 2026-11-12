import ArgumentParser
import Foundation
import NotesCore
import NotesMCP
import Darwin

enum WriteEngine: String, ExpressibleByArgument, Codable {
    case native
    case scripting
}

struct GlobalOptions: ParsableArguments {
    @Option(help: "Backend: default or fake. Also accepts NOTESCLI_BACKEND.") var backend: String?
    @Option(help: "Write engine: scripting (default) or native. Also accepts NOTESCLI_ENGINE.")
    var engine: WriteEngine = .scripting
    @Flag(help: "Refuse all writes.") var readOnly = false
    @Flag(help: "Print JSON, including errors on stderr.") var json = false
    @Flag(help: "Suppress non-essential human output. Errors are still printed.") var quiet = false
    func backends() throws -> Backends { try Backends.make(backend) }
    var resolvedEngine: WriteEngine {
        if CommandLine.arguments.contains(where: { $0 == "--engine" || $0.hasPrefix("--engine=") }) { return engine }
        return WriteEngine(rawValue: ProcessInfo.processInfo.environment["NOTESCLI_ENGINE"] ?? "") ?? engine
    }
    func writable() throws -> Backends {
        guard !readOnly else { throw NotesError("read_only", "Writing is disabled by --read-only.") }
        return try backends()
    }
}

enum TerminalStyle {
    static var enabled: Bool {
        isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil &&
            ProcessInfo.processInfo.environment["TERM"]?.lowercased() != "dumb"
    }
}

enum Output {
    static func error(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    static func json<T: Encodable>(_ value: T) throws { print(String(decoding: try NotePresentation.json(value), as: UTF8.self)) }
    static func table(_ headers: [String], _ rows: [[String]]) {
        if CommandLine.arguments.contains("--quiet") { return }
        let cleaned = rows.map { $0.map { $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ").filter { !$0.isASCII || $0.asciiValue! >= 32 } } }
        let widths = headers.indices.map { i in min(64, max(headers[i].count, cleaned.map { $0[i].count }.max() ?? 0)) }
        for row in [headers] + cleaned {
            print(row.enumerated().map { i, cell in
                let short = cell.count > widths[i] ? String(cell.prefix(widths[i] - 1)) + "…" : cell
                return short + String(repeating: " ", count: max(0, widths[i] - short.count))
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
    }
    static func notes(_ notes: [NoteSummary], json: Bool) throws {
        if json { try Self.json(notes) }
        else { table(["#ID", "ID", "TITLE", "FOLDER", "MODIFIED"], notes.map {
            [$0.number.map { "#\($0)" } ?? $0.id.shortID ?? "", $0.id.uuid,
             $0.title + ($0.isLocked ? " [locked]" : ""), $0.folderPath.joined(separator: " > "),
             $0.modified.map { NotePresentation.relativeDate($0) } ?? ""]
        }) }
    }
    static func outcome(_ outcome: WriteOutcome) -> String {
        switch outcome {
        case .verified: return "✓ verified"
        case .unverified: return "• unverified"
        case .unknown: return "? unknown"
        }
    }
    static func write(_ result: WriteResult, json: Bool) throws {
        let response = EngineWriteResponse(engine: "scripting", result: result, operationID: result.operationID, syncPending: result.syncPending)
        if result.outcome == .unknown {
            if json { try Self.json(response) }
            throw NotesError("write_outcome_unknown", result.message ?? "The write may have completed. Do not retry automatically.", hint: "Read the note before retrying.")
        }
        if json { try Self.json(response) }
        else { table(["ENGINE", "OUTCOME", "ID", "MESSAGE"], [[response.engine, outcome(result.outcome), result.noteID?.uuid ?? result.folderID ?? "", result.message ?? ""]]) }
    }
}

func positive(_ n: Int?, name: String) throws {
    if let n, n < 0 { throw ValidationError("\(name) must be nonnegative.") }
}
func confirm(_ prompt: String, yes: Bool) throws {
    if yes { return }
    guard isatty(STDIN_FILENO) == 1 else { throw NotesError("confirmation_required", "Use --yes to confirm deletion when stdin is not a TTY.") }
    Output.error(prompt + " [y/N]")
    guard ["y", "yes"].contains(readLine()?.lowercased() ?? "") else { throw NotesError("cancelled", "Deletion cancelled.") }
}
func editor(_ original: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-editor-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("note.md")
    try original.write(to: file, atomically: true, encoding: .utf8)
    let command = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
    guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { throw NotesError("invalid_editor", "EDITOR is empty.") }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command + " \"$1\"", "notescli-editor", file.path]
    process.standardInput = FileHandle.standardInput; process.standardOutput = FileHandle.standardError; process.standardError = FileHandle.standardError
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NotesError("editor_failed", "Editor exited with status \(process.terminationStatus).") }
    return try String(contentsOf: file, encoding: .utf8)
}
func validateBodySources(body: String?, stdin: Bool, file: String? = nil, allowEditor: Bool = false) throws {
    let count = [body != nil, stdin, file != nil].filter { $0 }.count
    guard count <= 1 else { throw ValidationError("Choose only one of --body, --stdin, or --file.") }
    if count == 0 && !allowEditor { throw ValidationError("Provide --body or --stdin.") }
}
func inputBody(body: String?, stdin: Bool, file: String? = nil, allowEditor: Bool = false) throws -> String {
    try validateBodySources(body: body, stdin: stdin, file: file, allowEditor: allowEditor)
    if let body { return body }
    if stdin {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { throw NotesError("invalid_encoding", "stdin must contain UTF-8.") }
        return text
    }
    if let file { return try String(contentsOfFile: NSString(string: file).expandingTildeInPath, encoding: .utf8) }
    if allowEditor { return try editor("") }
    throw ValidationError("Provide --body or --stdin.")
}

enum FuzzySearch {
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() { current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1)) }
            previous = current
        }
        return previous[b.count]
    }
    static func score(query: String, title: String, snippet: String, body: String) -> Int {
        let query = tokens(query); guard !query.isEmpty else { return 0 }
        let fields = [(tokens(title), 5), (tokens(snippet), 2), (tokens(body), 1)]
        var total = 0
        for token in query {
            var best = 0
            for (words, weight) in fields {
                for word in words {
                    let match: Int
                    if token == word { match = 100 }
                    else if word.hasPrefix(token) { match = 75 }
                    else if abs(token.count - word.count) <= 2 && token.count >= 3 {
                        let d = distance(token, word); match = d <= (token.count >= 6 ? 2 : 1) ? 50 - d * 10 : 0
                    } else { match = 0 }
                    best = max(best, weight * match)
                }
            }
            guard best > 0 else { return 0 }; total += best
        }
        return total
    }
    static func search(_ query: String, reader: any NotesReading, folder: String?, limit: Int?) throws -> [NoteSummary] {
        let candidates = try reader.notes(NoteQuery(folder: folder))
        let scored: [(NoteSummary, Int)] = try candidates.map { summary in
            let note = try reader.note(summary.id.uuid)
            return (summary, score(query: query, title: summary.title, snippet: summary.snippet, body: note.document?.text ?? ""))
        }
        let matching = scored.filter { $0.1 > 0 }
        let ranked = matching.sorted { a, b in
            if a.1 == b.1 { return a.0.id.uuid < b.0.id.uuid }
            return a.1 > b.1
        }
        return Array(ranked.prefix(limit ?? ranked.count).map { $0.0 })
    }
}
