import Foundation
import XCTest
import NotesCore
@testable import NotesNative
import NotesStore

final class MarkdownAttachmentPlanTests: XCTestCase {
    func testCreateTitleIsLiteralMarkdownAndCannotReferenceLocalFiles() {
        let title = "![secret](~/Documents/secret.txt)\n# next *bold*"
        let document = NotesMarkdownDocument(parsing: markdownSourceWithLiteralTitle(title, body: "Body"))

        XCTAssertEqual(document.paragraphs.map(\.plainText),
                       ["![secret](~/Documents/secret.txt) # next *bold*", "Body"])
        XCTAssertTrue(document.resources.isEmpty)
        XCTAssertEqual(document.paragraphs.first?.kind, .title)
    }

    func testResolvesRepeatedAssetsRelativeToMarkdownFileBeforeWriting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-markdown-assets-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = directory.appendingPathComponent("asset.bin")
        try Data("asset-bytes".utf8).write(to: asset)

        let plan = try MarkdownNativeWriter(owner: NativeNotesWriter()).prepare(
            NativeMarkdownInput(
                source: "![first](asset.bin)\n\n- between\n\n[second](asset.bin)",
                assetBaseDirectory: directory
            )
        )

        let frozen = plan.resources.compactMap { $0 }
        XCTAssertEqual(frozen.count, 2)
        XCTAssertEqual(frozen.map(\.sourceName), ["asset.bin", "asset.bin"])
        XCTAssertEqual(Set(frozen.map(\.sha256)).count, 1)
        XCTAssertFalse(frozen[0] === frozen[1])
        XCTAssertEqual(plan.document.paragraphs.map(\.kind), [.body, .bulleted, .body])
    }

    func testRelativeAssetWithoutBaseFailsBeforeNativeAccess() {
        XCTAssertThrowsError(try MarkdownNativeWriter(owner: NativeNotesWriter()).prepare(
            NativeMarkdownInput(source: "![missing](image.png)")
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "local_attachment_base_missing")
        }
    }

    func testPercentEncodedRelativeAssetUsesDecodedFileName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-markdown-percent-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = directory.appendingPathComponent("my chart.png")
        try Data("image".utf8).write(to: asset)

        let plan = try MarkdownNativeWriter(owner: NativeNotesWriter()).prepare(
            NativeMarkdownInput(source: "![chart](my%20chart.png)", assetBaseDirectory: directory)
        )

        XCTAssertEqual(plan.resources.compactMap { $0 }.map(\.sourceName), ["my chart.png"])
    }

    func testMissingAssetAndTableCellAttachmentFailDuringPreflight() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-missing-assets-" + UUID().uuidString, isDirectory: true)
        XCTAssertThrowsError(try MarkdownNativeWriter(owner: NativeNotesWriter()).prepare(
            NativeMarkdownInput(source: "![missing](image.png)", assetBaseDirectory: directory)
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "invalid_file")
        }
        XCTAssertThrowsError(try MarkdownNativeWriter(owner: NativeNotesWriter()).prepare(
            NativeMarkdownInput(source: "| File |\n| --- |\n| [PDF](document.pdf) |",
                                assetBaseDirectory: directory)
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "attachment_reference_in_table_cell_unsupported")
        }
    }

    func testRemoteImageIsRefusedInsteadOfSilentlyBecomingText() {
        XCTAssertThrowsError(try MarkdownNativeWriter(owner: NativeNotesWriter()).prepare(
            NativeMarkdownInput(source: "![chart](https://example.com/chart.png)")
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "remote_image_unsupported")
        }
    }

    func testExactPlacementComparisonIncludesOrderAndOffset() {
        typealias Placement = NativeVerificationRules.MarkerPlacement
        let first = Placement(id: "A", typeUTI: "public.png", location: 4, length: 1)
        let second = Placement(id: "B", typeUTI: "public.pdf", location: 12, length: 1)

        XCTAssertTrue(NativeVerificationRules.exactMarkerPlacements([first, second], [first, second]))
        XCTAssertFalse(NativeVerificationRules.exactMarkerPlacements([first, second], [second, first]))
        XCTAssertFalse(NativeVerificationRules.exactMarkerPlacements(
            [first], [Placement(id: "A", typeUTI: "public.png", location: 5, length: 1)]
        ))
    }

    func testExistingAttachmentReferencesMustBeExact() throws {
        XCTAssertNoThrow(try NativeMarkdownReferenceValidator.validate(
            requestedIDs: ["drawing", "scan", "recording"],
            existingIDs: ["scan", "recording", "drawing"]
        ))
        for (requested, existing, code) in [
            (["drawing", "drawing"], ["drawing"], "duplicate_attachment_reference"),
            (["foreign"], ["drawing"], "attachment_not_found"),
            (["drawing"], ["drawing", "scan"], "attachment_would_be_lost"),
            (["drawing"], ["drawing", "drawing"], "attachment_placement_mismatch"),
        ] {
            XCTAssertThrowsError(try NativeMarkdownReferenceValidator.validate(
                requestedIDs: requested, existingIDs: existing
            )) {
                XCTAssertEqual(($0 as? NotesError)?.code, code)
            }
        }
    }

    func testPatchMayMoveOnlyAttachmentsInsideTheReplacedRange() throws {
        XCTAssertNoThrow(try NativeMarkdownReferenceValidator.validatePatch(
            requestedIDs: ["IMAGE"], existingIDs: ["image", "outside"], replacedIDs: ["image"]
        ))
        for (requested, replaced, code) in [
            (["outside"], ["image"], "duplicate_attachment_reference"),
            ([], ["image"], "attachment_would_be_lost"),
            (["foreign"], ["image"], "attachment_not_found"),
            (["image", "IMAGE"], ["image"], "duplicate_attachment_reference"),
        ] {
            XCTAssertThrowsError(try NativeMarkdownReferenceValidator.validatePatch(
                requestedIDs: requested, existingIDs: ["image", "outside"], replacedIDs: replaced
            )) {
                XCTAssertEqual(($0 as? NotesError)?.code, code)
            }
        }
    }

    func testLiveCreateKeepsImagesTablesDividersAndFilesInMarkdownOrder() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set NOTESCLI_LIVE_TESTS=1; this test writes one disposable notescli-test note.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-live-markdown-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("pixel.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!.write(to: image)
        let file = directory.appendingPathComponent("source.txt")
        try Data("source material".utf8).write(to: file)
        let trailing = try FrozenAttachmentInput(file: file)
        let title = "notescli-test-markdown-order-" + UUID().uuidString
        let writer = NativeNotesWriter()
        var noteID: String?
        defer {
            if let noteID { _ = try? writer.deleteNote(noteID, allowShared: false) }
        }

        let created = try writer.createNote(
            title: title,
            input: NativeMarkdownInput(
                source: """
                - before
                - second

                ![pixel](pixel.png)

                - after

                7. Seven
                8. Eight

                | [<mark data-apple-notes-highlight="blue">**Name**</mark>](https://example.com) | Value |
                | --- | --- |
                | A | B |

                ---

                ## Assets

                [source](source.txt)
                """,
                assetBaseDirectory: directory,
                trailingAttachments: [trailing]
            ),
            folder: nil,
            allowShared: false
        )
        XCTAssertEqual(created.write.writeResult.outcome, .verified)
        noteID = try XCTUnwrap(created.write.writeResult.noteID?.uuid)

        let note = try SQLiteNotesStore(refresh: true).note(try XCTUnwrap(noteID))
        let markers = note.document?.runs.compactMap(\.attachment) ?? []
        XCTAssertEqual(markers.count, 5)
        XCTAssertTrue(markers[0].typeUTI.lowercased().contains("png") ||
                      markers[0].typeUTI.lowercased().contains("image"))
        XCTAssertEqual(markers[1].typeUTI, "com.apple.notes.table")
        XCTAssertTrue(note.attachments.first(where: { $0.id == markers[2].id })?.isDivider == true)
        XCTAssertEqual(created.attachmentSHA256.count, 3)
        let tableCell = try XCTUnwrap(note.document?.tableCells?[markers[1].id]?[0][0])
        XCTAssertEqual(tableCell.text, "Name")
        XCTAssertTrue(tableCell.runs.contains {
            $0.font.bold && $0.highlight == .blue && $0.link == "https://example.com"
        })
        XCTAssertEqual(note.document?.runs.compactMap(\.paragraph?.startNumber), [7, 8])

        let lossless = try XCTUnwrap(note.document).markdown(
            attachments: note.attachments, preserveNativeAttachments: true
        )
        XCTAssertEqual(NotesMarkdownDocument(parsing: lossless).paragraphs
            .flatMap(\.runs).compactMap(\.attachmentID), markers.map(\.id))
        let rewritten = try writer.writeMarkdown(
            try XCTUnwrap(noteID),
            input: NativeMarkdownInput(source: lossless),
            dryRun: false, backup: false, allowShared: false
        )
        XCTAssertEqual(rewritten.writeResult.outcome, .verified)

        XCTAssertThrowsError(try writer.appendMarkdown(
            try XCTUnwrap(noteID),
            input: NativeMarkdownInput(
                source: "[duplicate](notescli-attachment:\(markers[0].id))"
            ),
            allowShared: false
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "duplicate_attachment_reference")
        }
        let sectionMarkers = Array(markers.suffix(2))
        let replacement = """
        Replacement

        [source](notescli-attachment:\(sectionMarkers[0].id))

        [trailing](notescli-attachment:\(sectionMarkers[1].id))
        """
        XCTAssertEqual(try writer.replaceSection(
            try XCTUnwrap(noteID), heading: "Assets",
            input: NativeMarkdownInput(source: replacement), allowShared: false
        ).writeResult.outcome, .verified)
        XCTAssertThrowsError(try writer.replaceSection(
            try XCTUnwrap(noteID), heading: "Assets",
            input: NativeMarkdownInput(source: "Replacement"), allowShared: false
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "attachment_would_be_lost")
        }
        let unchanged = try SQLiteNotesStore(refresh: true).note(try XCTUnwrap(noteID))
        XCTAssertEqual(unchanged.document?.runs.compactMap(\.attachment).map(\.id), markers.map(\.id))

        let prepended = try writer.prependMarkdown(
            try XCTUnwrap(noteID),
            input: NativeMarkdownInput(source: "![prepended](pixel.png)",
                                       assetBaseDirectory: directory),
            allowShared: false
        )
        XCTAssertEqual(prepended.writeResult.outcome, .verified)
        let afterPrepend = try SQLiteNotesStore(refresh: true).note(try XCTUnwrap(noteID))
        let prependedMarkers = afterPrepend.document?.runs.compactMap(\.attachment) ?? []
        XCTAssertEqual(prependedMarkers.count, markers.count + 1)
        XCTAssertEqual(Array(prependedMarkers.dropFirst()).map(\.id), markers.map(\.id))

        let exported = try XCTUnwrap(note.document).markdown(attachments: note.attachments)
        let reparsed = NotesMarkdownDocument(parsing: exported)
        XCTAssertEqual(reparsed.paragraphs.map(\.kind), [
            .title, .bulleted, .bulleted, .body, .bulleted, .numbered, .numbered,
            .table, .divider, .heading, .body, .body,
        ])
        XCTAssertEqual(reparsed.paragraphs.compactMap(\.startNumber), [7, 8])
    }
}
