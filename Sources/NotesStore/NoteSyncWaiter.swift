import Foundation
import NotesCore

public enum NoteSyncWaiter {
    public static func isSynced(summary: NoteSummary, modifiedAfter: Date, postWriteVersion: Int? = nil) -> Bool {
        guard let modified = summary.modified, modified >= modifiedAfter,
              let state = summary.syncState,
              state.needsInitialFetch != true,
              state.needsFetch != true,
              state.needsFetchAssets != true,
              state.needsSave != true,
              state.hasChanges != true,
              state.versionOutOfDate != true,
              NotesSyncWaiter.isAcknowledged(state),
              postWriteVersion.map({ (state.latestVersionSyncedToCloud ?? Int.min) >= $0 }) ?? true,
              let lastSync = state.lastSyncDate,
              lastSync >= modified else { return false }
        return true
    }

    public static func wait(noteID: String, modifiedAfter: Date, timeout: TimeInterval,
                            pollInterval: TimeInterval = 0.5) throws -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        var postWriteVersion: Int?
        repeat {
            let summary = try SQLiteNotesStore(refresh: true).summary(noteID)
            if postWriteVersion == nil, summary.modified.map({ $0 >= modifiedAfter }) == true {
                postWriteVersion = summary.syncState?.currentLocalVersion
            }
            if isSynced(summary: summary, modifiedAfter: modifiedAfter, postWriteVersion: postWriteVersion) { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: min(max(0.05, pollInterval), max(0.05, deadline.timeIntervalSinceNow)))
        } while true
    }
}
