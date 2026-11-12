import XCTest
@testable import NotesCore

final class RecordingFragmentsTests: XCTestCase {
    private func recording() -> Attachment {
        let first = Attachment(id: "FRAG-A", typeUTI: "com.apple.m4a-audio", filePath: "/media/a.m4a")
        let second = Attachment(id: "FRAG-B", typeUTI: "com.apple.m4a-audio", filePath: "/media/b.m4a")
        return Attachment(id: "REC-1", typeUTI: "com.apple.m4a-audio", filePath: "/media/a.m4a",
                          childAttachmentIDs: ["FRAG-A", "FRAG-B"], childAttachments: [first, second])
    }

    func testTranscriptionReadsEveryFragmentFileInOrder() throws {
        XCTAssertEqual(try RecordingFragments.audioFiles(recording()).map(\.path), ["/media/a.m4a", "/media/b.m4a"])
    }

    func testUndownloadedFragmentFailsWithItsID() {
        var value = recording()
        value.childAttachments?[1].filePath = nil
        XCTAssertThrowsError(try RecordingFragments.audioFiles(value)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "audio_not_downloaded")
            XCTAssertEqual((error as? NotesError)?.message, "Fragment FRAG-B of recording REC-1 is not downloaded.")
        }
    }

    func testAssignSetsTheFragmentIndex() {
        let tagged = RecordingFragments.assign([TranscriptWord(text: "Hi", start: 0.5, duration: 0.25, speaker: "Speaker 1", fragment: 0)], fragment: 1)
        XCTAssertEqual(tagged, [TranscriptWord(text: "Hi", start: 0.5, duration: 0.25, speaker: "Speaker 1", fragment: 1)])
    }

    func testImportedFragmentIndicesGroupSegmentsByFragment() throws {
        let segments = [
            TranscriptWord(text: "second", start: 0, duration: 1, fragment: 1),
            TranscriptWord(text: "first", start: 0, duration: 1),
            TranscriptWord(text: "second again", start: 1, duration: 1, fragment: 1),
        ]
        let groups = try RecordingFragments.grouped(segments, fragmentCount: 2)
        XCTAssertEqual(groups.map { $0.map(\.text) }, [["first"], ["second", "second again"]])
        XCTAssertThrowsError(try RecordingFragments.grouped(segments, fragmentCount: 1)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "invalid_transcript")
            XCTAssertEqual((error as? NotesError)?.message, "The transcript uses fragment 1, but the recording has 1 fragment.")
        }
    }

    func testReadbackComparesTextTimingSpeakerAndFragment() {
        let written = [
            TranscriptWord(text: "later", start: 2, duration: 1, speaker: "Speaker 2", fragment: 1),
            TranscriptWord(text: "Hello", start: 0, duration: 0.5, speaker: "Speaker 1", fragment: 0),
        ]
        let readBack = [
            TranscriptWord(text: "Hello", start: 0, duration: 0.5, speaker: "Speaker 1", fragment: 0),
            TranscriptWord(text: "later", start: 2.0004, duration: 1, speaker: "Speaker 2", fragment: 1),
        ]
        XCTAssertNil(RecordingFragments.mismatch(expected: written, actual: readBack))

        var wrongFragment = readBack; wrongFragment[1].fragment = 0
        XCTAssertEqual(RecordingFragments.mismatch(expected: written, actual: wrongFragment), "Segment 1 is in fragment 0; expected fragment 1.")
        var wrongText = readBack; wrongText[0].text = "Hullo"
        XCTAssertEqual(RecordingFragments.mismatch(expected: written, actual: wrongText), "Segment 0 reads \"Hullo\"; expected \"Hello\".")
        var wrongStart = readBack; wrongStart[1].start = 3
        XCTAssertEqual(RecordingFragments.mismatch(expected: written, actual: wrongStart), "Segment 1 starts at 3.0; expected 2.0.")
        var wrongDuration = readBack; wrongDuration[0].duration = 0.75
        XCTAssertEqual(RecordingFragments.mismatch(expected: written, actual: wrongDuration), "Segment 0 lasts 0.75; expected 0.5.")
        var wrongSpeaker = readBack; wrongSpeaker[0].speaker = "Speaker 2"
        XCTAssertEqual(RecordingFragments.mismatch(expected: written, actual: wrongSpeaker), "Segment 0 speaker is \"Speaker 2\"; expected \"Speaker 1\".")
        XCTAssertEqual(RecordingFragments.mismatch(expected: written, actual: Array(readBack.prefix(1))), "Expected 2 transcript segments; read back 1.")
    }

    /// A one-fragment recording written by Notes on macOS 27: the fragment identity is the child attachment ID.
    func testDecoderListsFragmentIdentitiesInOrder() throws {
        let blob = try XCTUnwrap(Data(base64Encoded: "CgwKBAgAEAEKBAgBEAISABqZAWqWAQgMGioIABImIiQwMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDAaBggBEgIwARoGCAISAjACGgYIAxICMAMaBggEEgIwBBoGCBASAjAWGgYIERICMBcaBggSEgIwGBoGCBMSAjAZGgYIFBICMBoaBggVEgIwGxoGCBYSAjAcGgYIFxICMB0aBggYEgIwHhoICgYKBAgAEAEaCAoGCgQIABABGggKBgoECAAQARocKhoKGBICMAUaBgoECAAQASIKCgQIABABEgIwFRpIakYIDRoqCAASJiIkODNFRjAxQ0UtMjUzQy00RDJELThENzItNThBMkUzQzZDNjQ1GgYIBRICMAYaBggHEgIwCBoGCAkSAjAKGgwKCgoECAEQAhICMAcaDGoKCAAaBggGEgIIAhoMCgoKBAgAEAESAjAJGhNqEQgJGg0ICBIJGcpQwvNpvdpBGnV6cwpdCkUSA++/vBoQCgQIABAAEAAaBAgAEAAoARoQCgQIARAAEAEaBAgBEAAoAhoWCggIABD/////DxAAGggIABD/////DyoCCAESFAgAEhCifPFWUkBFA6YIkqUijisPEhIKEAoCMBQSAjALGgYKBAgBEAEaUGpOCA4aKggAEiYiJEIxNDlCRjA1LUJGREItNEM2NC04NURELTNGRThDNDU3QzMyORoGCAoSAjAMGgYIDBICMA4aBggNEgIwEBoGCA4SAjASGgwKCgoECAEQARICMA0aFWoTCAEaDwgLEgsiCVNwZWFrZXIgMRoMCgoKBAgBEAESAjAPGhNqEQgAGg0ICBIJGTMzMzMzMwNAGgwKCgoECAEQARICMBEaE2oRCAAaDQgIEgkZAAAAAAAAAAAaDAoKCgQIARABEgIwExoraikIARolCAsSISIfTm90ZXMgQ0xJIGF1ZGlvIHJlY29yZGluZyB0ZXN0LhoMagoIAhoGCA8SAhACGghKBgoECAAQABoICgYKBAgAEAEaCAoGCgQIABABGggKBgoECAAQARoICgYKBAgAEAEaCAoGCgQIABABGggKBgoECAAQARoICgYKBAgAEAEaCAoGCgQIABABGggKBgoECAAQASIIaWRlbnRpdHkiHnRvcGxpbmVTdW1tYXJ5TW9kZWxWZXJzaW9uSW5mbyIkZXh0ZXJuYWxNb2RlbEF0dHJpYnV0aW9uUHJvdmlkZXJOYW1lIhZjYWxsUmVjb3JkaW5nU3RhcnRUaW1lIglmcmFnbWVudHMiEXRyYW5zY3JpcHRWZXJzaW9uIgxpbnRlZ2VyVmFsdWUiC2NyZWF0ZWREYXRlIgtkb3VibGVWYWx1ZSIKdHJhbnNjcmlwdCIHc3BlYWtlciIEc2VsZiIIZHVyYXRpb24iCXRpbWVzdGFtcCIEdGV4dCIJVVVJREluZGV4IiJleHRlcm5hbE1vZGVsQXR0cmlidXRpb25TeW1ib2xOYW1lIh9sb25nZm9ybVN1bW1hcnlNb2RlbFZlcnNpb25JbmZvIgdzdW1tYXJ5Ig50b3BMaW5lU3VtbWFyeSIIY2FsbFR5cGUiFmNhbGxMb2NhbFNwZWFrZXJIYW5kbGUiDnN1bW1hcnlWZXJzaW9uIhdjYWxsUmVtb3RlU3BlYWtlckhhbmRsZSINY2FsbFJlY29yZGluZyoXY29tLmFwcGxlLkNSRFQuTlNOdW1iZXIqF2NvbS5hcHBsZS5DUkRULk5TU3RyaW5nKhVjb20uYXBwbGUuQ1JEVC5OU1VVSUQqFmNvbS5hcHBsZS5DUkRULkNSVHVwbGUqKGNvbS5hcHBsZS5DUkRULkNSUmVnaXN0ZXJNdWx0aVZhbHVlTGVhc3QqI2NvbS5hcHBsZS5DUkRULkNSUmVnaXN0ZXJNdWx0aVZhbHVlKhVjb20uYXBwbGUuQ1JEVC5DUlRyZWUqGWNvbS5hcHBsZS5DUkRULkNSVHJlZU5vZGUqFWNvbS5hcHBsZS5DUkRULk5TRGF0YSoVY29tLmFwcGxlLkNSRFQuTlNEYXRlKjFjb20uYXBwbGUubm90ZXMuSUNDbG91ZFN5bmNpbmdPYmplY3RBY3Rpdml0eUV2ZW50Kihjb20uYXBwbGUubm90ZXMuSUNGYXN0U3luY1NlbGVjdGlvblN0YXRlKiJjb20uYXBwbGUubm90ZXMuSUNUVEF1ZGlvUmVjb3JkaW5nKitjb20uYXBwbGUubm90ZXMuSUNUVEF1ZGlvUmVjb3JkaW5nLkZyYWdtZW50KiVjb20uYXBwbGUubm90ZXMuSUNUVFRyYW5zY3JpcHRTZWdtZW50Khdjb20uYXBwbGUubm90ZXMuQ1JUYWJsZSoXY29tLmFwcGxlLm5vdGVzLklDVGFibGUyECwzkuLURkeolnN+w4H6BNYyEGLr1RNclke4nE4ae1kWOVsyEKJ88VZSQEUDpgiSpSKOKw86HAoaChBi69UTXJZHuJxOGntZFjlbEgIIARICCAE="))
        let decoded = try NotesRecordingDecoder.decode(blob)
        XCTAssertEqual(decoded.fragments, ["83EF01CE-253C-4D2D-8D72-58A2E3C6C645"])
        XCTAssertEqual(decoded.words.map(\.text), ["Notes CLI audio recording test."])
        XCTAssertEqual(decoded.words.map(\.fragment), [0])
    }
}
