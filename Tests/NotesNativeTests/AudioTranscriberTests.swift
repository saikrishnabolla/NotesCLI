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
