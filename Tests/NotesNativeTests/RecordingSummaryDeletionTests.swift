import NotesCore
import XCTest
@testable import NotesNative

final class RecordingSummaryDeletionTests: XCTestCase {
    private func state(
        summary: String? = "Generated summary",
        localSpeaker: String? = "local",
        words: [TranscriptWord] = [TranscriptWord(text: "hello", start: 0, duration: 1, fragment: 0)]
    ) -> RecordingSummaryDeletionState {
        RecordingSummaryDeletionState(
            metadata: RecordingMetadata(
                summary: summary,
                topLineSummary: summary.map { _ in "Preview" },
                summaryVersion: summary.map { _ in 1 },
                localSpeakerHandle: localSpeaker,
                remoteSpeakerHandle: "remote",
                callType: 1,
                isCallRecording: true,
                startTime: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            transcript: words,
            fragments: ["fragment-1"],
            fragmentMetadata: [RecordingFragmentMetadata(id: "fragment-1", transcriptVersion: 1)]
        )
    }

    func testClearVerificationRequiresSummaryRemovalAndPreservedRecordingState() throws {
        let before = state()
        var after = state(summary: nil)
        after.metadata.topLineSummary = before.metadata.topLineSummary
        after.metadata.summaryVersion = before.metadata.summaryVersion
        after.metadata.externalModelAttributionProviderName = nil
        after.metadata.externalModelAttributionSymbolName = nil
        XCTAssertTrue(after.verifiesClear(from: before))

        after.metadata.localSpeakerHandle = "changed"
        XCTAssertFalse(after.verifiesClear(from: before))
        after = state(summary: nil, words: [])
        XCTAssertFalse(after.verifiesClear(from: before))
        XCTAssertFalse(state().verifiesClear(from: before))
    }

    func testClearRequiresTheDeletableSummaryAndPreservesTopLineAndVersion() throws {
        var topLineOnly = state(summary: nil)
        topLineOnly.metadata.topLineSummary = "Preview"
        XCTAssertThrowsError(try topLineOnly.requireSummary()) {
            XCTAssertEqual(($0 as? NotesError)?.code, "recording_summary_not_found")
        }

        let before = state()
        var after = state(summary: nil)
        after.metadata.topLineSummary = before.metadata.topLineSummary
        after.metadata.summaryVersion = before.metadata.summaryVersion
        after.metadata.externalModelAttributionProviderName = nil
        after.metadata.externalModelAttributionSymbolName = nil
        after.metadata.topLineSummary = "Changed"
        XCTAssertFalse(after.verifiesClear(from: before))
        after.metadata.topLineSummary = before.metadata.topLineSummary
        after.metadata.summaryVersion = 99
        XCTAssertFalse(after.verifiesClear(from: before))
    }

    func testMissingSummaryIsAStableTypedError() {
        XCTAssertThrowsError(try state(summary: nil).requireSummary()) {
            XCTAssertEqual(($0 as? NotesError)?.code, "recording_summary_not_found")
        }
    }
}
