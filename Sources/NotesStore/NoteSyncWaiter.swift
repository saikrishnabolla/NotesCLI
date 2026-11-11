import Foundation
import NotesCore

public enum NoteSyncWaiter {
    public static func isSynced(summary: NoteSummary, modifiedAfter: Date) -> Bool {
        guard let modified = summary.modified, modified >= modifiedAfter,
              let state = summary.syncState,
              state.needsInitialFetch != true,
              state.needsFetch != true,
              state.needsFetchAssets != true,
              state.needsSave != true,
              state.hasChanges != true,
              state.versionOutOfDate != true,
              let lastSync = state.lastSyncDate,
              lastSync >= modified else { return false }
        return true
    }

    public static func wait(noteID: String, modifiedAfter: Date, timeout: TimeInterval,
                            pollInterval: TimeInterval = 0.5) throws -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            let summary = try SQLiteNotesStore(refresh: true).summary(noteID)
            if isSynced(summary: summary, modifiedAfter: modifiedAfter) { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: min(max(0.05, pollInterval), max(0.05, deadline.timeIntervalSinceNow)))
        } while true
    }
}
