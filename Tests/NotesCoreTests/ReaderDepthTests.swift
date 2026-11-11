import Foundation
import XCTest
@testable import NotesCore

final class ReaderDepthTests: XCTestCase {
    private func varint(_ value: UInt64) -> Data {
        var value = value, data = Data()
        repeat { let byte = UInt8(value & 127); value >>= 7; data.append(value == 0 ? byte : byte | 128) } while value != 0
        return data
    }
    private func int(_ field: Int, _ value: Int) -> Data { varint(UInt64(field << 3)) + varint(UInt64(value)) }
    private func bytes(_ field: Int, _ data: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(data.count)) + data }
    private func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    private func fixed64(_ field: Int, _ value: Double) -> Data {
        var bits = value.bitPattern.littleEndian
        return varint(UInt64(field << 3 | 1)) + Data(bytes: &bits, count: 8)
    }
    private func objectRef(_ index: Int) -> Data { int(6, index) }
    private func map(_ type: Int, _ values: [(Int, Data)]) -> Data {
        bytes(13, int(1, type) + values.reduce(Data()) { $0 + bytes(3, int(1, $1.0) + bytes(2, $1.1)) })
    }
    private func register(_ index: Int) -> Data { bytes(1, bytes(2, objectRef(index))) }

    func testRecordingWordsTimingSpeakerAndSummary() throws {
        let keys = ["text", "timestamp", "duration", "speaker", "summary", "self", "doubleValue"]
        let types = ["com.apple.notes.ICTTTranscriptSegment", "com.apple.notes.ICTTAudioRecording", "com.apple.CRDT.NSString", "com.apple.CRDT.NSNumber"]
        let entries: [Data] = [
            map(2, [(5, string(4, "Hello"))]), register(0),
            map(3, [(6, fixed64(3, 1.5))]), register(2),
            map(3, [(6, fixed64(3, 0.25))]), register(4),
            map(2, [(5, string(4, "Speaker 1"))]), register(6),
            map(0, [(0, objectRef(1)), (1, objectRef(3)), (2, objectRef(5)), (3, objectRef(7))]),
            bytes(10, string(2, "Synthetic summary\n")), register(9),
            map(1, [(4, objectRef(10))])
        ]
        let blob = entries.reduce(Data()) { $0 + bytes(3, $1) }
            + keys.reduce(Data()) { $0 + string(4, $1) }
            + types.reduce(Data()) { $0 + string(5, $1) }
        let decoded = try NotesRecordingDecoder.decode(blob)
        XCTAssertEqual(decoded.words, [TranscriptWord(text: "Hello", start: 1.5, duration: 0.25, speaker: "Speaker 1")])
        XCTAssertEqual(decoded.metadata.summary, "Synthetic summary")
        XCTAssertEqual(NotesRecordingDecoder.joined(decoded.words), "Hello")
    }

    func testRawProtobufPreservesUnknownWireValues() throws {
        let data = int(99, 7) + fixed64(100, 3.5) + bytes(101, string(1, "nested"))
        let raw = try ProtobufMessage(data).raw
        XCTAssertEqual(raw.fields.map(\.number), [99, 100, 101])
        XCTAssertEqual(raw.fields[0].wireType, "varint")
        XCTAssertEqual(raw.fields[2].message?.fields.first?.utf8, "nested")
    }

    func testAttachmentDepthRendersInMarkdownAndJSONModel() throws {
        let ref = InlineRef(id: "audio", typeUTI: "com.apple.m4a-audio")
        let document = NoteDocument(text: "\u{fffc}", runs: [AttributeRun(length: 1, attachment: ref)])
        let attachment = Attachment(id: "audio", typeUTI: ref.typeUTI, title: "Recording", handwritingText: "Synthetic handwriting",
                                    transcriptText: "Synthetic transcript", transcriptWords: [TranscriptWord(text: "Hello", start: 1.25, speaker: "Speaker")],
                                    recording: RecordingMetadata(summary: "Synthetic summary", isCallRecording: true),
                                    pageImagePaths: ["/tmp/synthetic-page.png"])
        let markdown = document.markdown(attachments: [attachment])
        XCTAssertTrue(markdown.contains("Synthetic transcript"))
        XCTAssertTrue(markdown.contains("Synthetic summary"))
        XCTAssertTrue(markdown.contains("Synthetic handwriting"))
        XCTAssertTrue(markdown.contains("1.25s"))
        XCTAssertTrue(markdown.contains("Speaker: Hello"))
        XCTAssertTrue(markdown.contains("synthetic-page.png"))
        XCTAssertNoThrow(try JSONEncoder().encode(attachment))
    }
}
