import Foundation
import NotesCore

struct RecordingSummaryDeletionState: Equatable {
    var metadata: RecordingMetadata
    var transcript: [TranscriptWord]
    var fragments: [String]
    var fragmentMetadata: [RecordingFragmentMetadata]

    var hasSummary: Bool {
        metadata.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var callMetadata: RecordingCallMetadata {
        RecordingCallMetadata(
            localSpeakerHandle: metadata.localSpeakerHandle,
            remoteSpeakerHandle: metadata.remoteSpeakerHandle,
            callType: metadata.callType,
            isCallRecording: metadata.isCallRecording,
            startTime: metadata.startTime
        )
    }

    func verifiesClear(from before: RecordingSummaryDeletionState) -> Bool {
        !hasSummary &&
            metadata.topLineSummary == before.metadata.topLineSummary &&
            metadata.summaryVersion == before.metadata.summaryVersion &&
            metadata.externalModelAttributionProviderName == nil &&
            metadata.externalModelAttributionSymbolName == nil &&
            callMetadata == before.callMetadata &&
            transcript == before.transcript &&
            fragments == before.fragments &&
            fragmentMetadata == before.fragmentMetadata
    }

    func requireSummary() throws {
        guard hasSummary else {
            throw NotesError("recording_summary_not_found", "The recording has no generated summary that Notes can delete.")
        }
    }
}

private struct RecordingCallMetadata: Equatable {
    var localSpeakerHandle: String?
    var remoteSpeakerHandle: String?
    var callType: Int?
    var isCallRecording: Bool?
    var startTime: Date?
}
