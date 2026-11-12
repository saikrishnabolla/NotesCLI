import XCTest
@testable import NotesCore

final class RecordingTranscriptRendererTests: XCTestCase {
    private let recordings = [RecordingTranscript(
        attachmentID: "recording-1",
        duration: 3.5,
        segments: [
            TranscriptWord(text: "Hello there.", start: 0.25, duration: 1.5, speaker: "Speaker 1", fragment: 0),
            TranscriptWord(text: "General Kenobi.", start: 2.0, duration: 1.25, speaker: "Speaker 2", fragment: 0),
        ]
    )]

    func testTextIncludesTimingAndSpeakers() throws {
        XCTAssertEqual(try RecordingTranscriptRenderer.render(recordings, format: .text),
                       "[00:00.250] Speaker 1: Hello there.\n[00:02.000] Speaker 2: General Kenobi.\n")
    }

    func testSRTUsesLiteralCueTimes() throws {
        XCTAssertEqual(try RecordingTranscriptRenderer.render(recordings, format: .srt),
                       "1\n00:00:00,250 --> 00:00:01,750\nSpeaker 1: Hello there.\n\n2\n00:00:02,000 --> 00:00:03,250\nSpeaker 2: General Kenobi.\n")
    }

    func testVTTUsesLiteralCueTimes() throws {
        XCTAssertEqual(try RecordingTranscriptRenderer.render(recordings, format: .vtt),
                       "WEBVTT\n\n00:00:00.250 --> 00:00:01.750\n<v Speaker 1>Hello there.\n\n00:00:02.000 --> 00:00:03.250\n<v Speaker 2>General Kenobi.\n")
    }

    func testJSONKeepsTimingSpeakerAndFragment() throws {
        let data = try XCTUnwrap(try RecordingTranscriptRenderer.render(recordings, format: .json).data(using: .utf8))
        let decoded = try JSONDecoder().decode([RecordingTranscript].self, from: data)
        XCTAssertEqual(decoded, recordings)
    }
}
