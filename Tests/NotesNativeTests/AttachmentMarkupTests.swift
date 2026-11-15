import AppKit
import Foundation
import NotesAutomation
import NotesCore
import NotesNativeObjC
import NotesStore
import XCTest
@testable import NotesNative

final class AttachmentMarkupTests: XCTestCase {
    private func generatedMarkup() throws -> Data {
        try NCNotesRuntime.scanRectangleMarkupData(x: 1, y: 2, width: 8, height: 6, strokeWidth: 1)
    }

    private func mutatedGeneratedMarkup(_ mutate: (inout [Any], [String: Any]) throws -> Void) throws -> Data {
        var root = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: generatedMarkup(), format: nil
        ) as? [String: Any])
        var objects = try XCTUnwrap(root["$objects"] as? [Any])
        let top = try XCTUnwrap(root["$top"] as? [String: Any])
        try mutate(&objects, top)
        root["$objects"] = objects
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    func testFrozenMarkupAcceptsAnnotationKitArchiveAndKeepsExactBytes() throws {
        let data = try generatedMarkup()
        let frozen = try FrozenAttachmentMarkup(data: data)

        XCTAssertEqual(frozen.data, data)
        XCTAssertEqual(frozen.byteCount, data.count)
        XCTAssertEqual(frozen.sha256, FrozenAttachmentInput.hash(data))
    }

    func testFrozenMarkupRejectsUnknownAndOversizedPayloads() throws {
        XCTAssertThrowsError(try FrozenAttachmentMarkup(data: Data("not markup".utf8))) {
            XCTAssertEqual(($0 as? NotesError)?.code, "unknown_attachment_markup")
        }
        XCTAssertThrowsError(try FrozenAttachmentMarkup(data: Data(repeating: 0, count: FrozenAttachmentMarkup.maximumBytes + 1))) {
            XCTAssertEqual(($0 as? NotesError)?.code, "attachment_markup_too_large")
        }
    }

    func testFrozenMarkupRejectsMagicOnlyCompressedPayload() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "$archiver": "NSKeyedArchiver",
            "$version": 100_000,
            "$top": ["AKComprArchiveRoot": 1],
            "$objects": ["$null", "AKComprSizeKey", "AKComprDataKey", 10,
                         Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 1])],
        ], format: .binary, options: 0)

        XCTAssertThrowsError(try FrozenAttachmentMarkup(data: data)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "unknown_attachment_markup")
        }
    }

    func testFrozenMarkupRejectsTruncatedAndMismatchedCompressedPayloads() throws {
        let truncated = try mutatedGeneratedMarkup { objects, _ in
            let index = try XCTUnwrap(objects.firstIndex { $0 is Data })
            objects[index] = Data((objects[index] as! Data).prefix(7))
        }
        let mismatched = try mutatedGeneratedMarkup { objects, _ in
            let index = try XCTUnwrap(objects.firstIndex { $0 is NSNumber })
            objects[index] = (objects[index] as! NSNumber).intValue + 1
        }

        for data in [truncated, mismatched] {
            XCTAssertThrowsError(try FrozenAttachmentMarkup(data: data)) {
                XCTAssertEqual(($0 as? NotesError)?.code, "unknown_attachment_markup")
            }
        }
    }

    func testFrozenMarkupRejectsOversizedCyclicAndDecoyArchives() throws {
        let oversized = try mutatedGeneratedMarkup { objects, _ in
            let index = try XCTUnwrap(objects.firstIndex { $0 is NSNumber })
            objects[index] = FrozenAttachmentMarkup.maximumBytes + 1
        }
        let cyclic = try mutatedGeneratedMarkup { objects, top in
            var root = try XCTUnwrap(objects[1] as? [String: Any])
            var values = try XCTUnwrap(root["NS.objects"] as? [Any])
            values[1] = try XCTUnwrap(top["AKComprArchiveRoot"])
            root["NS.objects"] = values
            objects[1] = root
        }
        let decoy = try mutatedGeneratedMarkup { objects, _ in
            var root = try XCTUnwrap(objects[1] as? [String: Any])
            var values = try XCTUnwrap(root["NS.objects"] as? [Any])
            values[1] = values[0]
            root["NS.objects"] = values
            objects[1] = root
        }

        for data in [oversized, cyclic, decoy] {
            XCTAssertThrowsError(try FrozenAttachmentMarkup(data: data)) {
                XCTAssertEqual(($0 as? NotesError)?.code, "unknown_attachment_markup")
            }
        }
    }

    func testFrozenMarkupReadsOnlyAllowedInputPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-markup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("markup.data")
        let data = try generatedMarkup()
        try data.write(to: file)

        XCTAssertEqual(try FrozenAttachmentMarkup(file: file).data, data)
        XCTAssertThrowsError(try FrozenAttachmentMarkup(file: URL(fileURLWithPath: "/etc/hosts"))) {
            XCTAssertEqual(($0 as? NotesError)?.code, "input_path_refused")
        }
    }

    func testMarkupExportRefusesToReplaceAnExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-markup-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("markup.data")
        let data = try generatedMarkup()
        let metadata = NativeAttachmentMarkupMetadata(
            noteID: "note", attachmentID: "attachment", typeUTI: "public.png",
            hasMarkup: true, byteCount: data.count, sha256: FrozenAttachmentInput.hash(data),
            embedded: false, recognized: true
        )
        let value = NativeAttachmentMarkupExport(metadata: metadata, data: data)

        try value.write(to: output)
        XCTAssertThrowsError(try value.write(to: output)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "file_exists")
        }
        XCTAssertEqual(try Data(contentsOf: output), data)
    }

    func testLiveImageMarkupSetCopyExportAndClearUseExactReadback() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_SNAPSHOT_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-image-markup-interface-\(UUID().uuidString.lowercased())"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); const note = app.make({new: 'note', at: account, withProperties: {name: argv[0], body: '<h1>' + argv[0] + '</h1><p>body</p>'}}); return String(note.id()); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [title], timeout: 20)
        guard !reply.timedOut, reply.status == 0 else {
            throw NotesError("unknown_write", "Disposable markup fixture creation failed: \(reply.stderr)")
        }
        let scriptingID = reply.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var noteID: String?
        for attempt in 0..<40 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            noteID = try? SQLiteNotesStore(refresh: true).note(scriptingID).summary.id.uuid
            if noteID != nil { break }
        }
        let ref = try XCTUnwrap(noteID)
        defer { _ = try? scripting.deleteNote(ref) }

        func image() throws -> FrozenAttachmentInput {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 20,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ))
            bitmap.setColor(.red, atX: 0, y: 0)
            return try FrozenAttachmentInput(
                data: XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                suggestedName: "markup.png"
            )
        }

        let firstImage = try image()
        let secondImage = try image()
        let first = try native.insertFile(ref, file: firstImage.url, position: nil, imageView: nil, allowShared: false)
        let second = try native.insertFile(ref, file: secondImage.url, position: nil, imageView: nil, allowShared: false)
        let data = try generatedMarkup()
        let expectedHash = FrozenAttachmentInput.hash(data)
        let set = try native.setAttachmentMarkupData(
            ref, attachmentID: first.attachmentID, data: data, embedded: false, allowShared: false
        )
        XCTAssertEqual(set.writeResult.outcome, .verified)
        XCTAssertEqual(set.verification.nativeReadback["sha256"], expectedHash)
        XCTAssertEqual(set.verification.sqliteReadback?["sha256"], expectedHash)

        let copy = try native.copyAttachmentMarkup(
            ref, attachmentID: second.attachmentID,
            sourceRef: ref, sourceAttachmentID: first.attachmentID,
            allowShared: false
        )
        XCTAssertEqual(copy.writeResult.outcome, .verified)
        let metadata = try native.attachmentMarkupMetadata(ref, attachmentID: second.attachmentID)
        XCTAssertEqual(metadata.sha256, expectedHash)
        XCTAssertTrue(metadata.recognized)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-markup-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("markup.data")
        try native.attachmentMarkupData(ref, attachmentID: second.attachmentID).write(to: output)
        XCTAssertEqual(try Data(contentsOf: output), data)

        let clear = try native.clearAttachmentMarkup(ref, attachmentID: second.attachmentID, allowShared: false)
        XCTAssertEqual(clear.writeResult.outcome, .verified)
        XCTAssertEqual(clear.verification.nativeReadback["hasMarkup"], "false")
        XCTAssertEqual(clear.verification.sqliteReadback?["hasMarkup"], "false")
        XCTAssertFalse(try native.attachmentMarkupMetadata(ref, attachmentID: second.attachmentID).hasMarkup)
        XCTAssertNil(try SQLiteNotesStore(refresh: true).scanMarkupPayloads(ref)[second.attachmentID])
    }
}
