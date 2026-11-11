import Foundation
import NotesCore

public struct SyncWaitResult: Codable, Sendable, Hashable {
    public var noteID: String
    public var status: String
    public var elapsed: Double
    public var state: NoteSyncState?
}

public enum NotesSyncWaiter {
    public static func isAcknowledged(_ state: NoteSyncState?) -> Bool {
        guard let state,
              let local = state.currentLocalVersion,
              let synced = state.latestVersionSyncedToCloud else { return false }
        if state.needsSave == true || state.hasChanges == true || state.versionOutOfDate == true { return false }
        if synced < local { return false }
        if state.isInCloud == false { return false }
        return true
    }

    public static func wait(for ref: String, timeout: TimeInterval,
                            databaseURL: URL = SQLiteNotesStore.defaultDatabaseURL,
                            pollInterval: TimeInterval = 0.25) throws -> SyncWaitResult {
        guard timeout >= 0 else { throw NotesError("invalid_timeout", "The timeout must be nonnegative.") }
        let started = Date()
        var stableID: String?
        var lastState: NoteSyncState?
        repeat {
            let store = try SQLiteNotesStore(databaseURL: databaseURL, refresh: true)
            let summary = try store.summary(stableID ?? ref)
            stableID = summary.id.uuid; lastState = summary.syncState
            if isAcknowledged(lastState) {
                return SyncWaitResult(noteID: summary.id.uuid, status: "synced", elapsed: Date().timeIntervalSince(started), state: lastState)
            }
            if Date().timeIntervalSince(started) >= timeout { break }
            Thread.sleep(forTimeInterval: min(pollInterval, max(0, timeout - Date().timeIntervalSince(started))))
        } while true
        return SyncWaitResult(noteID: stableID ?? ref, status: "timed_out", elapsed: Date().timeIntervalSince(started), state: lastState)
    }
}
