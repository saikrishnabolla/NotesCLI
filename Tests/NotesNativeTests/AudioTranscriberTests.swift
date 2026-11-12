import Foundation
import NotesCore
import XCTest
@testable import NotesNative

final class AudioTranscriberTests: XCTestCase {
    func testTranscriptFileRoundTripsLiteralTimedSegments() throws {
        let expected = AudioTranscriptFile(locale: "en-US", segments: [
            TranscriptWord(text: "Notes CLI audio test.", start: 0.25, duration: 1.5,
                           speaker: "Speaker 1", fragment: 0),
        ])

        let data = try AudioTranscriber.encodeTranscriptFile(expected)
        XCTAssertEqual(try AudioTranscriber.decodeTranscriptFile(data), expected)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["locale"] as? String, "en-US")
        XCTAssertEqual((object["segments"] as? [[String: Any]])?.first?["start"] as? Double, 0.25)
    }

    func testTranscriptFileAcceptsBareSegmentsAndRejectsInvalidTiming() throws {
        let bare = Data(#"[{"text":"Offline transcript","start":0,"duration":2,"speaker":"Speaker 1","fragment":0}]"#.utf8)
        XCTAssertEqual(try AudioTranscriber.decodeTranscriptFile(bare).segments,
                       [TranscriptWord(text: "Offline transcript", start: 0, duration: 2,
                                       speaker: "Speaker 1", fragment: 0)])

        for invalid in [
            Data(#"{"version":2,"segments":[{"text":"Wrong version"}]}"#.utf8),
            Data(#"{"version":1,"segments":[{"text":"","start":0,"duration":1}]}"#.utf8),
            Data(#"{"version":1,"segments":[{"text":"Missing timing"}]}"#.utf8),
            Data(#"{"version":1,"segments":[{"text":"Bad timing","start":-1,"duration":1}]}"#.utf8),
        ] {
            XCTAssertThrowsError(try AudioTranscriber.decodeTranscriptFile(invalid)) {
                XCTAssertEqual(($0 as? NotesError)?.code, "invalid_transcript_file")
            }
        }
    }

    func testTranscriptFileRejectsOutOfBoundsValuesWithClearErrors() throws {
        func segment(_ text: String = "Hello", start: Double = 0, duration: Double = 1, speaker: String? = nil, fragment: Int? = nil) -> TranscriptWord {
            TranscriptWord(text: text, start: start, duration: duration, speaker: speaker, fragment: fragment)
        }
        func assertRejected(_ segments: [TranscriptWord], _ message: String, line: UInt = #line) throws {
            let data = try JSONEncoder().encode(segments)
            XCTAssertThrowsError(try AudioTranscriber.decodeTranscriptFile(data), line: line) { error in
                XCTAssertEqual((error as? NotesError)?.code, "invalid_transcript_file", line: line)
                XCTAssertEqual((error as? NotesError)?.message, message, line: line)
            }
        }
        try assertRejected([segment(start: 1e300)], "Transcript timing must be finite and within 0...604800 seconds.")
        try assertRejected([segment(start: 604_000, duration: 801)], "Transcript timing must be finite and within 0...604800 seconds.")
        try assertRejected([segment(String(repeating: "a", count: 10_001))], "Transcript segment text must be at most 10000 characters.")
        try assertRejected([segment(speaker: String(repeating: "s", count: 201))], "Transcript speaker names must be at most 200 characters.")
        try assertRejected([segment(fragment: -1)], "Transcript fragment indices must be within 0...999.")
        try assertRejected([segment(fragment: 1_000)], "Transcript fragment indices must be within 0...999.")
        try assertRejected(Array(repeating: segment(), count: 100_001), "The transcript file has more than 100000 segments.")
    }

    func testTranscriptFileOverSizeLimitIsRefusedBeforeDecoding() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-big-transcript-" + UUID().uuidString + ".json")
        try Data(repeating: 0x20, count: 10 * 1024 * 1024 + 1).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try AudioTranscriber.readTranscriptFile(url)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "input_too_large")
            XCTAssertEqual((error as? NotesError)?.message, "The transcript file is larger than the 10 MB limit.")
        }
    }

    func testSpeechAuthorizationRefusesBundleWithoutUsageDescription() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = root.appendingPathComponent("MissingSpeech.bundle/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.notescli.tests.missing-speech",
            "CFBundleName": "Missing Speech",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))

        XCTAssertThrowsError(try AudioTranscriber.requireSpeechUsageDescription(in: bundle)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "speech_permission_unavailable")
            XCTAssertEqual(($0 as? NotesError)?.message,
                           "Speech Recognition is unavailable because this build has no NSSpeechRecognitionUsageDescription.")
            XCTAssertEqual(($0 as? NotesError)?.hint, "Run the packaged notescli release.")
        }
    }
}
