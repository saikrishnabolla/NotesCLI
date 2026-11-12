import Foundation

/// Bounds for transcript data read from JSON files or from the Notes database.
public enum TranscriptLimits {
    public static let maxFileBytes = 10 * 1024 * 1024
    public static let maxSegments = 100_000
    public static let maxTextCharacters = 10_000
    public static let maxSpeakerCharacters = 200
    public static let maxFragments = 1_000
    /// Seven days. Starts, durations, and ends must be finite and within 0...maxSeconds.
    public static let maxSeconds: Double = 7 * 24 * 60 * 60

    public static let timingMessage = "Transcript timing must be finite and within 0...\(Int(maxSeconds)) seconds."

    public static func isValidTime(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= maxSeconds }

    /// The first reason an imported transcript is out of bounds, or nil when it is valid.
    public static func problem(in segments: [TranscriptWord]) -> String? {
        guard segments.count <= maxSegments else { return "The transcript file has more than \(maxSegments) segments." }
        for segment in segments {
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let start = segment.start, let duration = segment.duration else {
                return "Transcript segments require text and non-negative finite timing values."
            }
            guard isValidTime(start), isValidTime(duration), isValidTime(start + duration) else { return timingMessage }
            guard segment.text.count <= maxTextCharacters else {
                return "Transcript segment text must be at most \(maxTextCharacters) characters."
            }
            if let speaker = segment.speaker, speaker.count > maxSpeakerCharacters {
                return "Transcript speaker names must be at most \(maxSpeakerCharacters) characters."
            }
            if let fragment = segment.fragment, !(0..<maxFragments).contains(fragment) {
                return "Transcript fragment indices must be within 0...\(maxFragments - 1)."
            }
        }
        return nil
    }
}
