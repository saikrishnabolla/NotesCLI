import Foundation

public enum NotesSafetyPaths {
    public static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotesCLI", isDirectory: true)
    }
    public static var journal: URL { applicationSupport.appendingPathComponent("journal.sqlite") }
    public static var snapshots: URL { applicationSupport.appendingPathComponent("snapshots", isDirectory: true) }
}
