import Foundation

public enum RecordingTranscriptFormat: String, Codable, Sendable, CaseIterable {
    case text, srt, vtt, json
}

public struct RecordingTranscript: Codable, Sendable, Hashable {
    public var attachmentID: String
    public var duration: Double?
    public var segments: [TranscriptWord]

    public init(attachmentID: String, duration: Double?, segments: [TranscriptWord]) {
        self.attachmentID = attachmentID
        self.duration = duration
        self.segments = segments
    }
}

public enum RecordingTranscriptRenderer {
    public static func render(_ recordings: [RecordingTranscript], format: RecordingTranscriptFormat) throws -> String {
        switch format {
        case .text:
            return recordings.flatMap(\.segments).map { "[\(clock($0.start ?? 0, separator: ".", hours: false))] \(spoken($0))" }.joined(separator: "\n") + suffix(recordings)
        case .srt:
            return recordings.flatMap(\.segments).enumerated().map { index, segment in
                let start = segment.start ?? 0, end = start + (segment.duration ?? 0)
                return "\(index + 1)\n\(clock(start, separator: ",", hours: true)) --> \(clock(end, separator: ",", hours: true))\n\(spoken(segment))"
            }.joined(separator: "\n\n") + suffix(recordings)
        case .vtt:
            let cues = recordings.flatMap(\.segments).map { segment in
                let start = segment.start ?? 0, end = start + (segment.duration ?? 0)
                let line = segment.speaker.map { "<v \($0)>\(segment.text)" } ?? segment.text
                return "\(clock(start, separator: ".", hours: true)) --> \(clock(end, separator: ".", hours: true))\n\(line)"
            }.joined(separator: "\n\n")
            return "WEBVTT\n\n" + cues + (cues.isEmpty ? "" : "\n")
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(recordings), as: UTF8.self) + "\n"
        }
    }

    private static func spoken(_ segment: TranscriptWord) -> String {
        segment.speaker.map { "\($0): \(segment.text)" } ?? segment.text
    }

    private static func suffix(_ recordings: [RecordingTranscript]) -> String {
        recordings.contains { !$0.segments.isEmpty } ? "\n" : ""
    }

    private static func clock(_ value: Double, separator: Character, hours: Bool) -> String {
        let milliseconds = max(0, Int((value * 1_000).rounded()))
        let hour = milliseconds / 3_600_000
        let minute = milliseconds / 60_000 % 60
        let second = milliseconds / 1_000 % 60
        let fraction = milliseconds % 1_000
        if hours { return String(format: "%02d:%02d:%02d%c%03d", hour, minute, second, separator.asciiValue!, fraction) }
        return String(format: "%02d:%02d%c%03d", minute + hour * 60, second, separator.asciiValue!, fraction)
    }
}
