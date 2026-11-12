import Foundation
import XCTest
import NotesCore
@testable import NotesNative

/// Every file input must pass the shared source-path check before NotesCLI reads it.
final class InputPathTests: XCTestCase {
    private var hidden: URL!

    override func setUpWithError() throws {
        hidden = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notescli-test-input-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: hidden) }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = hidden.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func assertRefused(_ expression: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual((error as? NotesError)?.code, "input_path_refused", "\(error)", file: file, line: line)
        }
    }

    func testAttachmentFromHiddenHomeFolderIsRefused() throws {
        assertRefused(try FrozenAttachmentInput(file: try file("secret.txt", "secret")))
    }

    func testTranscriptJSONFromHiddenHomeFolderIsRefused() throws {
        let json = try file("transcript.json", #"[{"text":"hello","start":0,"duration":1}]"#)
        assertRefused(try AudioTranscriber.readTranscriptFile(json))
    }

    func testAudioFromHiddenHomeFolderIsRefusedBeforeConversion() throws {
        let audio = try file("audio.wav", "not really audio")
        assertRefused(try AudioTranscriber.prepareBlocking(audio))
    }

    func testDrawingSVGFromHiddenHomeFolderIsRefused() throws {
        let svg = try file("drawing.svg", #"<svg xmlns="http://www.w3.org/2000/svg"><line x1="0" y1="0" x2="10" y2="10" stroke="black"/></svg>"#)
        assertRefused(try SVGDrawingConverter.drawing(contentsOf: svg))
    }

    func testSymlinkIntoHiddenHomeFolderIsRefused() throws {
        let target = try file("secret.txt", "secret")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-link-" + UUID().uuidString + ".txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link) }
        assertRefused(try FrozenAttachmentInput(file: link))
    }

    func testTemporaryFileIsAccepted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-input-" + UUID().uuidString + ".json")
        try Data(#"[{"text":"hello","start":0,"duration":1}]"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try AudioTranscriber.readTranscriptFile(url).segments, [TranscriptWord(text: "hello", start: 0, duration: 1)])
    }
}
