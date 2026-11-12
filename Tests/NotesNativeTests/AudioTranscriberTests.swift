import Foundation
import NotesCore
import XCTest
@testable import NotesNative

final class AudioTranscriberTests: XCTestCase {
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
