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

    func testAnnotationArchiveAddsListsAndRemovesEverySupportedBasicType() throws {
        let inputs: [AttachmentMarkupAnnotationInput] = [
            .init(kind: .rectangle, x: 2, y: 2, width: 20, height: 12),
            .init(kind: .oval, x: 4, y: 4, width: 18, height: 10, color: "ff3b30"),
            .init(kind: .text, x: 5, y: 5, width: 30, height: 14, text: "hello"),
            .init(kind: .arrow, x: 2, y: 20, width: 24, height: 8),
            .init(kind: .line, x: 3, y: 22, width: 20, height: 2),
            .init(kind: .ink, points: [ScanPoint(x: 1, y: 1), ScanPoint(x: 8, y: 9), ScanPoint(x: 16, y: 3)]),
            .init(kind: .highlight, x: 2, y: 30, width: 28, height: 8, color: "ffcc00aa"),
        ]
        var payload: FrozenAttachmentMarkup?
        for input in inputs { payload = try AttachmentMarkupArchive.adding(input, to: payload?.data) }

        let annotations = try AttachmentMarkupArchive.annotations(in: try XCTUnwrap(payload).data)
        XCTAssertEqual(annotations.count, inputs.count)
        XCTAssertEqual(Set(annotations.map(\.type)), Set([
            "AKRectAnnotation", "AKOvalAnnotation", "AKTextBoxAnnotation", "AKArrowAnnotation",
            "AKDoodleAnnotation", "AKHighlightAnnotation",
        ]))
        XCTAssertEqual(annotations.first(where: { $0.type == "AKTextBoxAnnotation" })?.text, "hello")

        let removed = try XCTUnwrap(AttachmentMarkupArchive.removing(annotations[2].id, from: payload!.data))
        let remaining = try AttachmentMarkupArchive.annotations(in: removed.data)
        XCTAssertEqual(remaining.count, inputs.count - 1)
        XCTAssertFalse(remaining.contains { $0.id == annotations[2].id })
    }

    func testRemovingOnlyAnnotationReturnsClearAndRenderingProducesPNG() throws {
        let payload = try AttachmentMarkupArchive.adding(
            .init(kind: .rectangle, x: 2, y: 2, width: 20, height: 12), to: nil
        )
        let annotation = try XCTUnwrap(AttachmentMarkupArchive.annotations(in: payload.data).first)
        XCTAssertNil(try AttachmentMarkupArchive.removing(annotation.id, from: payload.data))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-markup-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("base.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let rendered = try AttachmentMarkupArchive.renderedPNG(data: payload.data, baseImageURL: image)
        XCTAssertTrue(rendered.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        XCTAssertGreaterThan(rendered.count, 100)
    }

    func testAttachmentMarkupRendersOverPDF() throws {
        let payload = try AttachmentMarkupArchive.adding(
            .init(kind: .oval, x: 8, y: 8, width: 30, height: 20), to: nil
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-markup-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("base.pdf")
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 96, height: 72)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        try (bytes as Data).write(to: pdf)

        let rendered = try AttachmentMarkupArchive.renderedPNG(data: payload.data, baseImageURL: pdf)
        XCTAssertTrue(rendered.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        XCTAssertGreaterThan(rendered.count, 100)
    }

    func testImageMarkupEmbedsTheArchiveAndClearRestoresTheBaseImage() throws {
        let payload = try AttachmentMarkupArchive.adding(
            .init(kind: .rectangle, x: 2, y: 2, width: 20, height: 12), to: nil
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-markup-embed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let marked = root.appendingPathComponent("marked.png")
        let cleared = root.appendingPathComponent("cleared.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)

        try AttachmentMarkupArchive.imageData(embedding: payload.data, baseImageURL: source).write(to: marked)
        let embedded = try AttachmentMarkupArchive.embeddedData(at: marked)
        XCTAssertEqual(try AttachmentMarkupArchive.annotations(in: embedded).count, 1)

        try AttachmentMarkupArchive.imageData(embedding: nil, baseImageURL: marked).write(to: cleared)
        XCTAssertThrowsError(try AttachmentMarkupArchive.embeddedData(at: cleared))
        XCTAssertNotNil(NSImage(contentsOf: cleared))
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
        let environment = ProcessInfo.processInfo.environment
        guard environment["NOTESCLI_LIVE_TESTS"] == "1" || environment["NOTESCLI_LIVE_SNAPSHOT_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_TESTS=1; this test writes one disposable note in NotesCLI Test camera.")
        }
        let runner = OSAScriptRunner()
        let native = NativeNotesWriter()
        let scripting = ScriptingNotesWriter(timeout: 20, resolver: { ref in
            try SQLiteNotesStore(refresh: true).note(ref).summary.id.coreDataID
        })
        let title = "notescli-test-image-markup-interface-\(UUID().uuidString.lowercased())"
        let folderName = "NotesCLI Test camera"
        let create = "function run(argv) { const app = Application('Notes'); const account = app.defaultAccount(); let matches = account.folders.whose({name: argv[0]})(); const folder = matches.length ? matches[0] : app.make({new: 'folder', at: account, withProperties: {name: argv[0]}}); const note = app.make({new: 'note', at: folder, withProperties: {name: argv[1], body: '<h1>' + argv[1] + '</h1><p>body</p>'}}); return String(note.id()); }"
        let reply = try runner.run(source: create, language: .javaScript, arguments: [folderName, title], timeout: 20)
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

        func image(_ color: NSColor) throws -> FrozenAttachmentInput {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 20,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ))
            bitmap.setColor(color, atX: 0, y: 0)
            return try FrozenAttachmentInput(
                data: XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                suggestedName: "markup.png"
            )
        }

        let firstImage = try image(.red)
        let secondImage = try image(.blue)
        let first = try native.insertFile(ref, file: firstImage.url, position: nil, imageView: nil, allowShared: false)
        let second = try native.insertFile(ref, file: secondImage.url, position: nil, imageView: nil, allowShared: false)
        let data = try generatedMarkup()
        let set = try native.setAttachmentMarkupData(
            ref, attachmentID: first.attachmentID, data: data, embedded: false, allowShared: false
        )
        XCTAssertEqual(set.writeResult.outcome, .verified)
        let setHash = try XCTUnwrap(set.verification.nativeReadback["sha256"])
        XCTAssertEqual(set.verification.sqliteReadback?["sha256"], setHash)
        XCTAssertEqual(set.verification.sqliteReadback?["embedded"], "true")
        XCTAssertNil(try SQLiteNotesStore(refresh: true).scanMarkupPayloads(ref)[first.attachmentID])

        let added = try native.addAttachmentMarkupAnnotation(
            ref, attachmentID: first.attachmentID,
            input: .init(kind: .oval, x: 4, y: 4, width: 18, height: 10, color: "ff3b30"),
            allowShared: false
        )
        XCTAssertEqual(added.writeResult.outcome, .verified)
        XCTAssertNotNil(added.verification.nativeReadback["sha256"])
        XCTAssertNotNil(added.verification.sqliteReadback?["sha256"])
        XCTAssertEqual(try native.attachmentMarkupAnnotations(ref, attachmentID: first.attachmentID).count, 2)
        let rendered = try native.renderAttachmentMarkup(ref, attachmentID: first.attachmentID)
        XCTAssertTrue(rendered.starts(with: [0x89, 0x50, 0x4e, 0x47]))

        let copy = try native.copyAttachmentMarkup(
            ref, attachmentID: second.attachmentID,
            sourceRef: ref, sourceAttachmentID: first.attachmentID,
            allowShared: false
        )
        XCTAssertEqual(copy.writeResult.outcome, .verified, "\(copy.verification)")
        let metadata = try native.attachmentMarkupMetadata(ref, attachmentID: second.attachmentID)
        XCTAssertEqual(metadata.sha256, added.verification.nativeReadback["sha256"])
        XCTAssertTrue(metadata.embedded)
        XCTAssertTrue(metadata.recognized)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-markup-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("markup.data")
        try native.attachmentMarkupData(ref, attachmentID: second.attachmentID).write(to: output)
        XCTAssertEqual(FrozenAttachmentInput.hash(try Data(contentsOf: output)), metadata.sha256)

        let clear = try native.clearAttachmentMarkup(ref, attachmentID: second.attachmentID, allowShared: false)
        XCTAssertEqual(clear.writeResult.outcome, .verified)
        XCTAssertEqual(clear.verification.nativeReadback["hasMarkup"], "false")
        XCTAssertEqual(clear.verification.sqliteReadback?["hasMarkup"], "false")
        XCTAssertFalse(try native.attachmentMarkupMetadata(ref, attachmentID: second.attachmentID).hasMarkup)
        XCTAssertNil(try SQLiteNotesStore(refresh: true).scanMarkupPayloads(ref)[second.attachmentID])
    }
}
