import ArgumentParser
import Darwin
import Foundation
import NotesCore
import NotesMCP

private struct HomeResponse: Encodable {
    var version: String
    var tagline: String
    var commands: [String]
    var recent: [HomeRecentNote]
}

/// Home output lists only what the screen shows: no snippets, participants, or other note content.
private struct HomeRecentNote: Encodable {
    var number: Int?
    var title: String
    var folder: String?
    var modified: Date?

    init(_ note: NoteSummary) {
        number = note.number; title = note.title; folder = note.folderPath.last; modified = note.modified
    }
}

enum HomeScreen {
    static let tagline = "Power-user Apple Notes CLI for humans and agents"
    static let commands = ["recent", "search", "pinned", "tags", "folders", "stats", "doctor", "capabilities"]

    /// Recent titles show by default; `--no-recent` or `NOTESCLI_HOME_RECENT=0` hides them.
    static func showsRecent(noRecent: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !noRecent && environment["NOTESCLI_HOME_RECENT"] != "0"
    }

    static func run(options: GlobalOptions, noRecent: Bool) throws {
        let showRecent = showsRecent(noRecent: noRecent)
        func recentNotes() throws -> [NoteSummary] { showRecent ? try options.backends().reader.notes(NoteQuery(limit: 5)) : [] }
        if options.json {
            try Output.json(HomeResponse(version: NotesCLI.version, tagline: tagline, commands: commands,
                                         recent: try recentNotes().map(HomeRecentNote.init)))
            return
        }
        guard isatty(STDOUT_FILENO) == 1 else {
            if !options.quiet { print(NotesCLI.helpMessage()) }
            return
        }
        let recent = try recentNotes()
        let styled = TerminalStyle.enabled
        func color(_ code: String, _ text: String) -> String { styled ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text }
        print(color("38;5;220", #"""
             _   _       _            ____ _     ___
            | \ | | ___ | |_ ___  ___/ ___| |   |_ _|
            |  \| |/ _ \| __/ _ \/ __| |   | |    | |
            | |\  | (_) | ||  __/\__ \ |___| |___ | |
            |_| \_|\___/ \__\___||___/\____|_____|___|
            """#))
        print("\(color("1", "notescli \(NotesCLI.version)")) · \(tagline)\n")
        print(color("1", "Commands"))
        let descriptions = [
            "recent": "recently edited notes", "search": "search titles and bodies", "pinned": "pinned notes",
            "tags": "tags and counts", "folders": "folder tree", "stats": "library statistics",
            "doctor": "permissions and health", "capabilities": "feature support"
        ]
        for command in commands { print("  \(color("36", command.padding(toLength: 13, withPad: " ", startingAt: 0))) \(descriptions[command]!)") }
        print("\nMore: notescli help [command]")
        guard showRecent else { return }
        print("\n\(color("1", "Recently Edited (\(recent.count))"))")
        if recent.isEmpty { print("  No notes found.") }
        for note in recent {
            let id = note.number.map { "#\($0)" } ?? note.id.shortID ?? String(note.id.uuid.prefix(8))
            let title = truncate(note.title.isEmpty ? "Untitled" : note.title, to: 42)
            let folder = note.folderPath.last ?? "No folder"
            let modified = note.modified.map { NotePresentation.relativeDate($0) } ?? "unknown"
            print("  \(color("36", id.padding(toLength: 7, withPad: " ", startingAt: 0))) \(title)  \(color("2", "\(folder) · \(modified)"))")
        }
    }

    private static func truncate(_ value: String, to limit: Int) -> String {
        value.count > limit ? String(value.prefix(limit - 1)) + "…" : value
    }
}

struct Pinned: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List pinned notes.", discussion: """
        EXAMPLES:
          notescli pinned --limit 20
          notescli pinned --json
        """)
    @OptionGroup var options: GlobalOptions
    @Option var limit: Int?
    func validate() throws { try positive(limit, name: "limit") }
    func run() throws {
        try Output.notes(options.backends().reader.notes(NoteQuery(pinnedOnly: true, limit: limit)), json: options.json)
    }
}

struct Capabilities: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Report Apple Notes feature and permission support.", discussion: """
        EXAMPLES:
          notescli capabilities
          notescli capabilities --json
        """)
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let report = CapabilityReporter.report()
        if options.json { try Output.json(report); return }
        Output.table(["FEATURE", "READ", "WRITE", "READ ENGINE", "WRITE ENGINE", "FDA", "AUTOMATION", "SPEECH", "NATIVE"], report.features.map {
            [$0.feature, $0.read, $0.write, $0.readEngine, $0.writeEngine,
             $0.permissions["fullDiskAccess"] ?? "", $0.permissions["automation"] ?? "",
             $0.permissions["speech"] ?? "", $0.nativeSelectors]
        })
    }
}

struct HelpAlias: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "help", abstract: "Show help for notescli or one command.")
    @Argument var command: String?
    func run() throws {
        guard let command else { print(NotesCLI.helpMessage()); return }
        let names = NotesCLI.namedSubcommands
        if let type = names.first(where: { $0.0 == command })?.1 {
            print(NotesCLI.helpMessage(for: type))
            return
        }
        let suggestion = names.map(\.0).min { FuzzySearch.distance(command, $0) < FuzzySearch.distance(command, $1) }
        throw NotesError("unknown_command", "Unknown command: \(command).", hint: suggestion.map { "Did you mean '\($0)'?" })
    }
}
