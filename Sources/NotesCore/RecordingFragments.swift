import Foundation

/// Notes splits a native recording into ordered audio fragments. Each transcript segment belongs to one
/// fragment, identified by its index in that order.
public enum RecordingFragments {
    /// The audio file of each fragment, in fragment order.
    public static func audioFiles(_ recording: Attachment) throws -> [URL] {
        let fragments = recording.childAttachments ?? []
        guard !fragments.isEmpty else {
            throw NotesError("recording_not_found", "Recording \(recording.id) has no audio fragments.")
        }
        return try fragments.map { fragment in
            guard let path = fragment.filePath else {
                throw NotesError("audio_not_downloaded", "Fragment \(fragment.id) of recording \(recording.id) is not downloaded.")
            }
            return URL(fileURLWithPath: path)
        }
    }

    /// Returns the segments with every fragment index set to `fragment`.
    public static func assign(_ segments: [TranscriptWord], fragment: Int) -> [TranscriptWord] {
        segments.map { segment in
            var copy = segment
            copy.fragment = fragment
            return copy
        }
    }

    /// Splits segments by fragment index, keeping their order within each fragment.
    /// A missing index means fragment 0. Throws `invalid_transcript` for an index the recording lacks.
    public static func grouped(_ segments: [TranscriptWord], fragmentCount: Int) throws -> [[TranscriptWord]] {
        var groups = Array(repeating: [TranscriptWord](), count: max(fragmentCount, 0))
        for segment in segments {
            let index = segment.fragment ?? 0
            guard groups.indices.contains(index) else {
                let available = fragmentCount == 1 ? "1 fragment" : "\(fragmentCount) fragments"
                throw NotesError("invalid_transcript", "The transcript uses fragment \(index), but the recording has \(available).")
            }
            groups[index].append(segment)
        }
        return groups
    }

    /// Compares written segments with the transcript read back from Notes, segment by segment.
    /// Returns nil when text, start, duration, speaker, and fragment all match, or a description of the first difference.
    public static func mismatch(expected: [TranscriptWord], actual: [TranscriptWord], tolerance: Double = 0.001) -> String? {
        let wanted = expected.enumerated().sorted { ($0.element.fragment ?? 0, $0.offset) < ($1.element.fragment ?? 0, $1.offset) }.map(\.element)
        guard wanted.count == actual.count else {
            return "Expected \(wanted.count) transcript segments; read back \(actual.count)."
        }
        func close(_ left: Double?, _ right: Double?) -> Bool { abs((left ?? 0) - (right ?? 0)) <= tolerance }
        for (index, (want, got)) in zip(wanted, actual).enumerated() {
            if (want.fragment ?? 0) != (got.fragment ?? 0) {
                return "Segment \(index) is in fragment \(got.fragment ?? 0); expected fragment \(want.fragment ?? 0)."
            }
            if want.text != got.text { return "Segment \(index) reads \"\(got.text)\"; expected \"\(want.text)\"." }
            if !close(want.start, got.start) { return "Segment \(index) starts at \(got.start ?? 0); expected \(want.start ?? 0)." }
            if !close(want.duration, got.duration) {
                return "Segment \(index) lasts \(got.duration ?? 0); expected \(want.duration ?? 0)."
            }
            if (want.speaker ?? "") != (got.speaker ?? "") {
                return "Segment \(index) speaker is \"\(got.speaker ?? "")\"; expected \"\(want.speaker ?? "")\"."
            }
        }
        return nil
    }
}
