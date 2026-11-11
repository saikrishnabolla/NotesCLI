import Foundation
import XCTest
import NotesCore
@testable import NotesStore

final class NoteSyncWaiterTests: XCTestCase {
    private func summary(modified: Date?, state: NoteSyncState?) -> NoteSummary {
        NoteSummary(id: NoteID(uuid: "note"), title: "T", snippet: "", folderID: nil, folderPath: ["Notes"], accountID: "a",
                    created: nil, modified: modified, isPinned: false, isLocked: false, isDeleted: false,
                    hasChecklist: false, attachmentCount: 0, tags: [], syncState: state)
    }

    func testSyncedRequiresTheNewVersionAndNoPendingCloudFlags() {
        let changed = Date(timeIntervalSinceReferenceDate: 500)
        let synced = NoteSyncState(needsInitialFetch: false, needsFetch: false, needsFetchAssets: false,
                                   needsSave: false, hasChanges: false, versionOutOfDate: false,
                                   cloudState: 1, lastSyncDate: changed.addingTimeInterval(1))
        XCTAssertTrue(NoteSyncWaiter.isSynced(summary: summary(modified: changed, state: synced), modifiedAfter: changed.addingTimeInterval(-1)))
        XCTAssertFalse(NoteSyncWaiter.isSynced(summary: summary(modified: changed.addingTimeInterval(-5), state: synced), modifiedAfter: changed))
        var pending = synced
        pending.needsSave = true
        XCTAssertFalse(NoteSyncWaiter.isSynced(summary: summary(modified: changed, state: pending), modifiedAfter: changed.addingTimeInterval(-1)))
        var staleSync = synced
        staleSync.lastSyncDate = changed.addingTimeInterval(-1)
        XCTAssertFalse(NoteSyncWaiter.isSynced(summary: summary(modified: changed, state: staleSync), modifiedAfter: changed.addingTimeInterval(-1)))
    }
}
