import XCTest
import NotesCore
@testable import NotesNative

final class SnapshotRestorePlannerTests: XCTestCase {
    private func note(attachments: [Attachment], runs: [AttributeRun]) throws -> Note {
        var note = try InMemoryNotes.sample().note("welcome")
        note.document = NoteDocument(
            text: String(repeating: "\u{fffc}", count: runs.count),
            runs: runs
        )
        note.attachments = attachments
        return note
    }

    private func material(_ id: String, typeUTI: String, filename: String? = "file.bin",
                          hash: String? = String(repeating: "a", count: 64),
                          byteCount: Int? = 42, parentID: String? = nil,
                          mediaDuration: Double? = nil, payloadKind: String? = nil) -> SnapshotAttachmentMaterial {
        SnapshotAttachmentMaterial(id: id, typeUTI: typeUTI, filename: filename, parentID: parentID,
                                   blobSHA256: hash, byteCount: byteCount, mediaDuration: mediaDuration,
                                   payloadKind: payloadKind)
    }

    private func action(
        for attachment: Attachment,
        archive: SnapshotAttachmentArchive? = nil,
        existing: [SnapshotRestoreExistingAttachment] = []
    ) throws -> SnapshotRestoreAction {
        let snapshot = try note(
            attachments: [attachment],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: attachment.id, typeUTI: attachment.typeUTI))]
        )
        return try XCTUnwrap(SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: archive,
            existing: existing
        ).attachment(attachment.id)).action
    }

    func testKeepsLiveRowAndUnmarksDeletedRow() throws {
        let snapshot = try note(
            attachments: [
                Attachment(id: "kept", typeUTI: "public.jpeg"),
                Attachment(id: "deleted", typeUTI: "com.apple.notes.table"),
            ],
            runs: [
                AttributeRun(length: 1, attachment: InlineRef(id: "kept", typeUTI: "public.jpeg")),
                AttributeRun(length: 1, attachment: InlineRef(id: "deleted", typeUTI: "com.apple.notes.table")),
            ]
        )

        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: nil,
            existing: [
                SnapshotRestoreExistingAttachment(id: "kept", typeUTI: "public.jpeg", isMarkedForDeletion: false),
                SnapshotRestoreExistingAttachment(id: "deleted", typeUTI: "com.apple.notes.table", isMarkedForDeletion: true),
            ]
        )

        XCTAssertEqual(plan.attachments.map(\.action), [.keep, .unmark])
        XCTAssertTrue(plan.canRestore)
    }

    func testKeepsExistingInlineRowEvenWhenItIsAbsentFromAttachmentMetadata() throws {
        let snapshot = try note(
            attachments: [],
            runs: [AttributeRun(
                length: 1,
                attachment: InlineRef(id: "mention", typeUTI: "com.apple.notes.inlinetextattachment.mention")
            )]
        )
        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: nil,
            existing: [SnapshotRestoreExistingAttachment(
                id: "mention",
                typeUTI: "com.apple.notes.inlinetextattachment.mention",
                isMarkedForDeletion: false
            )]
        )

        XCTAssertEqual(plan.attachment("mention")?.action, .keep)
        XCTAssertTrue(plan.canRestore)
    }

    func testRecreatesTopLevelGenericFileFromVerifiedMaterial() throws {
        let archived = material("file", typeUTI: "public.plain-text", filename: "report.txt")
        let result = try action(
            for: Attachment(id: "file", typeUTI: "public.plain-text", filename: "report.txt"),
            archive: SnapshotAttachmentArchive(attachments: [archived])
        )

        XCTAssertEqual(result, .recreateFile(archived))
    }

    func testRecreatesGenericFileWithAmbiguousTypeUsingExplicitNativeUTI() throws {
        let archived = material("file", typeUTI: "public.data", filename: "report.bin")
        XCTAssertEqual(
            try action(
                for: Attachment(id: "file", typeUTI: "public.data", filename: "report.bin"),
                archive: SnapshotAttachmentArchive(attachments: [archived])
            ),
            .recreateFile(archived)
        )
    }

    func testRefusesMissingMaterialAndMissingBlob() throws {
        let attachment = Attachment(id: "file", typeUTI: "public.data")
        XCTAssertEqual(try action(for: attachment), .refuse(.missingMaterial))
        XCTAssertEqual(
            try action(
                for: attachment,
                archive: SnapshotAttachmentArchive(attachments: [material("file", typeUTI: "public.data", hash: nil)])
            ),
            .refuse(.missingBlob)
        )
        XCTAssertEqual(
            try action(
                for: attachment,
                archive: SnapshotAttachmentArchive(attachments: [
                    material("file", typeUTI: "public.data", hash: String(repeating: "A", count: 64)),
                ])
            ),
            .refuse(.missingBlob)
        )
    }

    func testRestoreFilenamePreservesOrDerivesTheSavedType() {
        XCTAssertEqual(
            SnapshotRestoreFilename.derive(for: SnapshotAttachmentMaterial(
                id: "pdf", typeUTI: "com.adobe.pdf", filename: "Report.PDF"
            )),
            "Report.PDF"
        )
        XCTAssertEqual(
            SnapshotRestoreFilename.derive(for: SnapshotAttachmentMaterial(
                id: "png", typeUTI: "public.png"
            )),
            "attachment.png"
        )
        XCTAssertEqual(
            SnapshotRestoreFilename.derive(for: SnapshotAttachmentMaterial(
                id: "pdf", typeUTI: "com.adobe.pdf", filename: "wrong.png"
            )),
            "attachment.pdf"
        )
        XCTAssertEqual(
            SnapshotRestoreFilename.forExplicitType(SnapshotAttachmentMaterial(
                id: "data", typeUTI: "public.data", filename: "folder/report.bin"
            )),
            "report.bin"
        )
        XCTAssertEqual(
            SnapshotRestoreFilename.forExplicitType(SnapshotAttachmentMaterial(
                id: "custom", typeUTI: "com.example.custom"
            )),
            "attachment"
        )
        XCTAssertFalse(SnapshotRestoreFilename.requiresExplicitType(SnapshotAttachmentMaterial(
            id: "pdf", typeUTI: "com.adobe.pdf", filename: "Report.PDF"
        )))
        XCTAssertFalse(SnapshotRestoreFilename.requiresExplicitType(SnapshotAttachmentMaterial(
            id: "png", typeUTI: "public.png"
        )))
        XCTAssertTrue(SnapshotRestoreFilename.requiresExplicitType(SnapshotAttachmentMaterial(
            id: "opaque", typeUTI: "com.example.custom"
        )))
        XCTAssertTrue(SnapshotRestoreFilename.requiresExplicitType(SnapshotAttachmentMaterial(
            id: "mismatch", typeUTI: "com.adobe.pdf", filename: "report.png"
        )))
        XCTAssertEqual(
            SnapshotRestoreFilename.forExplicitType(SnapshotAttachmentMaterial(
                id: "newline", typeUTI: "public.png", filename: "bad\nname.png"
            )),
            "attachment.png"
        )
        XCTAssertEqual(
            SnapshotRestoreFilename.forExplicitType(SnapshotAttachmentMaterial(
                id: "long", typeUTI: "public.png", filename: String(repeating: "a", count: 300) + ".png"
            )),
            "attachment.png"
        )
    }

    func testRefusesEachUnsupportedInlineFamilyWhenItsRowIsGone() throws {
        let cases: [(String, String)] = [
            ("mention", "com.apple.notes.inlinetextattachment.mention"),
            ("hashtag", "com.apple.notes.inlinetextattachment.hashtag"),
            ("note-link", "com.apple.notes.inlinetextattachment.link"),
            ("math", "com.apple.notes.inlinetextattachment.math"),
            ("calculation", "com.apple.notes.inlinetextattachment.calculate"),
            ("graph", "com.apple.notes.inlinetextattachment.graph"),
        ]

        for (id, typeUTI) in cases {
            XCTAssertEqual(
                try action(for: Attachment(id: id, typeUTI: typeUTI)),
                .refuse(.unsupportedInline),
                id
            )
        }
    }

    func testRecreatesSupportedInlineObjectsFromSavedSemantics() throws {
        let cases: [(Attachment, SnapshotInlineRecreation)] = [
            (Attachment(id: "tag", typeUTI: "com.apple.notes.inlinetextattachment.hashtag",
                        displayText: "#research"), .hashtag("research")),
            (Attachment(id: "link", typeUTI: "com.apple.notes.inlinetextattachment.link",
                        displayText: "Target", targetNoteID: "target-note"),
             .noteLink(targetID: "target-note", paragraphID: nil, paragraphName: nil, text: "Target")),
            (Attachment(id: "section-link", typeUTI: "com.apple.notes.inlinetextattachment.link",
                        displayText: "Target → Section",
                        targetNoteID: "applenotes://showNote?identifier=target-note&paragraphID=11111111-2222-3333-4444-555555555555"),
             .noteLink(targetID: "target-note", paragraphID: "11111111-2222-3333-4444-555555555555",
                       paragraphName: nil, text: "Target → Section")),
            (Attachment(id: "divider", typeUTI: "com.apple.notes.inlinetextattachment.horizontalrule",
                        isDivider: true), .divider),
            (Attachment(id: "math", typeUTI: "com.apple.notes.inlinetextattachment.calculate",
                        mathExpression: "2+2"), .math("2+2")),
        ]

        for (attachment, expected) in cases {
            XCTAssertEqual(try action(for: attachment), .recreateInline(expected), attachment.id)
        }
    }

    func testRecreatesMentionOnlyForSharedSnapshotWithIdentity() throws {
        let mention = Attachment(id: "mention", typeUTI: "com.apple.notes.inlinetextattachment.mention",
                                 displayText: "Ada", participantID: "participant-1",
                                 participantUserID: "user-1")
        var snapshot = try note(
            attachments: [mention],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: mention.id, typeUTI: mention.typeUTI))]
        )
        XCTAssertEqual(
            SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: nil, existing: []).attachment("mention")?.action,
            .refuse(.unsupportedInline)
        )
        snapshot.summary.isShared = true
        XCTAssertEqual(
            SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: nil, existing: []).attachment("mention")?.action,
            .recreateInline(.mention(text: "Ada", userRecordName: "user-1"))
        )
    }

    func testRefusesUnsupportedMissingRowFamilies() throws {
        let cases: [(Attachment, SnapshotRestoreRefusalReason)] = [
            (Attachment(id: "table", typeUTI: "com.apple.notes.table"), .unsupportedTable),
            (Attachment(id: "scan", typeUTI: "com.apple.notes.gallery"), .unsupportedScan),
            (Attachment(id: "audio", typeUTI: "public.mp3"), .unsupportedRecording),
            (Attachment(id: "drawing", typeUTI: "com.apple.notes.paper"), .unsupportedDrawing),
            (Attachment(id: "native", typeUTI: "com.apple.notes.unknown-object"), .unsupportedAttachment),
        ]

        for (attachment, reason) in cases {
            XCTAssertEqual(try action(for: attachment), .refuse(reason), attachment.id)
        }
    }

    func testRecreatesMissingTableFromSavedCellGrid() throws {
        var snapshot = try note(
            attachments: [Attachment(id: "table", typeUTI: "com.apple.notes.table")],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "table", typeUTI: "com.apple.notes.table"))]
        )
        snapshot.document?.tableCells = [
            "table": [[TableCellDocument(text: "saved", runs: [AttributeRun(length: 5)])]],
        ]

        let plan = SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: nil, existing: [])

        XCTAssertEqual(plan.attachment("table")?.action, .recreateTable)
        XCTAssertTrue(plan.canRestore)
    }

    func testRecreatesMissingRichLinkFromSavedURL() throws {
        let attachment = Attachment(
            id: "link",
            typeUTI: "public.url",
            title: "Example",
            url: "https://example.com/report",
            synapseDataBytes: 42
        )

        XCTAssertEqual(try action(for: attachment), .recreateRichLink)
    }

    func testRecreatesMissingNativeMapFromSavedLocation() throws {
        let attachment = Attachment(
            id: "map",
            typeUTI: "public.url",
            title: "Apple Park",
            url: "https://maps.apple.com/?q=Apple+Park",
            hasMapLocation: true
        )

        XCTAssertEqual(try action(for: attachment), .recreateMap)
    }

    func testRefusesMapLocationWithoutAppleMapsURL() throws {
        let attachment = Attachment(
            id: "map",
            typeUTI: "public.url",
            url: "https://example.com/place",
            hasMapLocation: true
        )

        XCTAssertEqual(try action(for: attachment), .refuse(.unsupportedRichLink))
    }

    func testRecreatesMissingDrawingFromSavedSVG() throws {
        let attachment = Attachment(
            id: "drawing",
            typeUTI: "com.apple.notes.paper",
            drawingSVG: "<svg xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M0 0 L10 10\"/></svg>"
        )

        XCTAssertEqual(try action(for: attachment), .recreateDrawing(nil))
    }

    func testPrefersExactPencilKitPayloadForMissingDrawing() throws {
        let payload = material(
            "drawing",
            typeUTI: "com.apple.notes.paper",
            filename: nil,
            payloadKind: "paper-strokes-v1"
        )
        let attachment = Attachment(id: "drawing", typeUTI: "com.apple.notes.paper")

        XCTAssertEqual(
            try action(for: attachment, archive: SnapshotAttachmentArchive(attachments: [payload])),
            .recreateDrawing(payload)
        )
    }

    func testAcceptsMultiCanvasPayloadOnlyWithNativePaperBundle() throws {
        var payload = material(
            "drawing",
            typeUTI: "com.apple.notes.paper",
            filename: nil,
            payloadKind: "paper-canvases-v1"
        )
        let attachment = Attachment(id: "drawing", typeUTI: "com.apple.notes.paper")
        XCTAssertEqual(
            try action(for: attachment, archive: SnapshotAttachmentArchive(attachments: [payload])),
            .refuse(.unsupportedDrawing)
        )
        payload.paperBundleSHA256 = String(repeating: "b", count: 64)
        payload.paperBundleByteCount = 42
        XCTAssertEqual(
            try action(for: attachment, archive: SnapshotAttachmentArchive(attachments: [payload])),
            .recreateDrawing(payload)
        )
    }

    func testAcceptsExactLegacySketchPayloadAndRejectsCrossFamilyPayloads() throws {
        let legacyPayload = material(
            "drawing",
            typeUTI: "com.apple.notes.sketch",
            filename: nil,
            payloadKind: "legacy-drawing-v1"
        )
        let legacy = Attachment(id: "drawing", typeUTI: "com.apple.notes.sketch")
        XCTAssertEqual(
            try action(for: legacy, archive: SnapshotAttachmentArchive(attachments: [legacyPayload])),
            .recreateDrawing(legacyPayload)
        )

        var wrong = legacyPayload
        wrong.payloadKind = "paper-strokes-v1"
        XCTAssertEqual(
            try action(for: legacy, archive: SnapshotAttachmentArchive(attachments: [wrong])),
            .refuse(.unsupportedDrawing)
        )
    }

    func testRefusesMissingDrawingWithoutEditableSource() throws {
        XCTAssertEqual(
            try action(for: Attachment(id: "drawing", typeUTI: "com.apple.notes.paper")),
            .refuse(.unsupportedDrawing)
        )
    }

    func testRefusesMissingRichLinkWithUnsafeOrIncompleteURL() throws {
        for value in ["file:///tmp/private", "https://user:secret@example.com", "not a URL"] {
            let attachment = Attachment(id: "link", typeUTI: "public.url", url: value, synapseDataBytes: 1)
            XCTAssertEqual(try action(for: attachment), .refuse(.unsupportedRichLink), value)
        }
    }

    func testRecreatesMissingTableWithCompleteInlineObjectGraph() throws {
        var reference = InlineRef(id: "cell-tag", typeUTI: "com.apple.notes.inlinetextattachment.hashtag")
        reference.parentAttachmentCaptured = true
        reference.parentAttachmentID = "table"
        let tag = Attachment(id: reference.id, typeUTI: reference.typeUTI, displayText: "#work")
        let table = Attachment(
            id: "table", typeUTI: "com.apple.notes.table",
            childAttachmentIDs: [tag.id], childAttachments: [tag]
        )
        var snapshot = try note(
            attachments: [table],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: table.id, typeUTI: table.typeUTI))]
        )
        snapshot.document?.tableCells = [
            table.id: [[TableCellDocument(
                text: "\u{fffc}", runs: [AttributeRun(length: 1, attachment: reference)]
            )]],
        ]

        let plan = SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: nil, existing: [])

        XCTAssertEqual(plan.attachment(table.id)?.action, .recreateTable)
        XCTAssertEqual(plan.attachment(tag.id)?.action, .recreateInline(.hashtag("work")))
        XCTAssertTrue(plan.canRestore)

        let remapped = try SnapshotAttachmentIDRemapper.remap(
            snapshot,
            attachmentIDs: [table.id: "new-table", tag.id: "new-tag"]
        )
        let remappedReference = try XCTUnwrap(
            remapped.document?.tableCells?["new-table"]?.first?.first?.runs.first?.attachment
        )
        XCTAssertEqual(remappedReference.id, "new-tag")
        XCTAssertEqual(remappedReference.parentAttachmentID, "new-table")
    }

    func testRefusesMissingTableWithUnsupportedNestedAttachmentGraph() throws {
        var snapshot = try note(
            attachments: [
                Attachment(id: "table", typeUTI: "com.apple.notes.table"),
                Attachment(id: "nested", typeUTI: "public.png"),
            ],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "table", typeUTI: "com.apple.notes.table"))]
        )
        snapshot.document?.tableCells = [
            "table": [[TableCellDocument(
                text: "\u{fffc}",
                runs: [AttributeRun(length: 1, attachment: InlineRef(id: "nested", typeUTI: "public.png"))]
            )]],
        ]

        let plan = SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: nil, existing: [])

        XCTAssertEqual(plan.attachment("table")?.action, .refuse(.parentChildTopology))
        XCTAssertFalse(plan.canRestore)
    }

    func testRemapsTableMarkerAndSavedTableKeys() throws {
        var snapshot = try note(
            attachments: [Attachment(id: "old", typeUTI: "com.apple.notes.table")],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "old", typeUTI: "com.apple.notes.table"))]
        )
        snapshot.document?.tables = ["old": [["plain"]]]
        snapshot.document?.tableCells = [
            "old": [[TableCellDocument(text: "rich", runs: [AttributeRun(length: 4)])]],
        ]

        let remapped = try SnapshotAttachmentIDRemapper.remap(snapshot, attachmentIDs: ["old": "new"])

        XCTAssertEqual(remapped.document?.runs.first?.attachment?.id, "new")
        XCTAssertEqual(remapped.document?.tables?["new"], [["plain"]])
        XCTAssertNil(remapped.document?.tables?["old"])
        XCTAssertEqual(remapped.document?.tableCells?["new"]?.first?.first?.text, "rich")
        XCTAssertEqual(remapped.attachments.first?.id, "new")
    }

    func testExistingParentChildRowsRemainRestorable() throws {
        let snapshot = try note(
            attachments: [
                Attachment(id: "gallery", typeUTI: "com.apple.notes.gallery", childAttachmentIDs: ["page"]),
                Attachment(id: "page", typeUTI: "public.jpeg"),
            ],
            runs: [
                AttributeRun(length: 1, attachment: InlineRef(id: "gallery", typeUTI: "com.apple.notes.gallery")),
            ]
        )
        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: nil,
            existing: [
                SnapshotRestoreExistingAttachment(id: "gallery", typeUTI: "com.apple.notes.gallery", isMarkedForDeletion: false),
                SnapshotRestoreExistingAttachment(id: "page", typeUTI: "public.jpeg", parentID: "gallery", isMarkedForDeletion: true),
            ]
        )

        XCTAssertEqual(plan.attachments.map(\.id), ["gallery", "page"])
        XCTAssertEqual(plan.attachment("gallery")?.action, .keep)
        XCTAssertEqual(plan.attachment("page")?.action, .unmark)
        XCTAssertTrue(plan.canRestore)
    }

    func testMissingParentChildRowIsRefusedBeforeRecreation() throws {
        let snapshot = try note(
            attachments: [
                Attachment(id: "gallery", typeUTI: "com.apple.notes.gallery", childAttachmentIDs: ["page"]),
                Attachment(id: "page", typeUTI: "public.jpeg"),
            ],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "gallery", typeUTI: "com.apple.notes.gallery"))]
        )
        let plan = SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: nil, existing: [])

        XCTAssertEqual(plan.attachment("gallery")?.action, .refuse(.unsupportedScan))
        XCTAssertEqual(plan.attachment("page")?.action, .refuse(.unsupportedScan))
        XCTAssertFalse(plan.canRestore)
    }

    func testRecreatesMissingScanGraphFromOrderedPageMaterial() throws {
        let crop = ScanCrop(
            bottomLeft: ScanPoint(x: 0, y: 1), bottomRight: ScanPoint(x: 1, y: 1),
            topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1, y: 0)
        )
        let page = Attachment(id: "page", typeUTI: "public.jpeg", filename: "page.jpg",
                              scanFilter: 2, scanOrientation: 1, scanCrop: crop, scanHasMarkup: false)
        let gallery = Attachment(id: "gallery", typeUTI: "com.apple.notes.gallery",
                                 childAttachmentIDs: ["page"], childAttachments: [page])
        let pageMaterial = material("page", typeUTI: "public.jpeg", filename: "page.jpg", parentID: "gallery")
        let snapshot = try note(
            attachments: [gallery],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "gallery", typeUTI: "com.apple.notes.gallery"))]
        )

        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: SnapshotAttachmentArchive(attachments: [pageMaterial]),
            existing: []
        )

        let expected = SnapshotScanRecreation(parentID: "gallery", pages: [
            SnapshotScanPageRecreation(id: "page", material: pageMaterial, filter: 2, orientation: 1, crop: crop),
        ])
        XCTAssertEqual(plan.attachment("gallery")?.action, .recreateScan(expected))
        XCTAssertEqual(plan.attachment("page")?.action, .recreatedByParent("gallery"))
        XCTAssertTrue(plan.canRestore)
    }

    func testRefusesMissingScanWithMarkupOrPartialExistingGraph() throws {
        let page = Attachment(id: "page", typeUTI: "public.jpeg", filename: "page.jpg", scanHasMarkup: true)
        let gallery = Attachment(id: "gallery", typeUTI: "com.apple.notes.gallery",
                                 childAttachmentIDs: ["page"], childAttachments: [page])
        let pageMaterial = material("page", typeUTI: "public.jpeg", filename: "page.jpg", parentID: "gallery")
        let snapshot = try note(
            attachments: [gallery],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "gallery", typeUTI: "com.apple.notes.gallery"))]
        )
        let archive = SnapshotAttachmentArchive(attachments: [pageMaterial])

        let markup = SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: archive, existing: [])
        XCTAssertEqual(markup.attachment("gallery")?.action, .refuse(.unsupportedScan))
        XCTAssertFalse(markup.canRestore)

        let partial = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: archive,
            existing: [SnapshotRestoreExistingAttachment(
                id: "page", typeUTI: "public.jpeg", parentID: "gallery", isMarkedForDeletion: false
            )]
        )
        XCTAssertEqual(partial.attachment("gallery")?.action, .refuse(.parentChildTopology))
        XCTAssertFalse(partial.canRestore)
    }

    func testRecreatesMissingScanWithArchivedMarkupModel() throws {
        let page = Attachment(id: "page", typeUTI: "public.jpeg", filename: "page.jpg",
                              scanFilter: 0, scanOrientation: 0, scanHasMarkup: true)
        let gallery = Attachment(id: "gallery", typeUTI: "com.apple.notes.gallery",
                                 childAttachmentIDs: ["page"], childAttachments: [page])
        var pageMaterial = material("page", typeUTI: "public.jpeg", filename: "page.jpg", parentID: "gallery")
        pageMaterial.scanMarkupSHA256 = String(repeating: "b", count: 64)
        pageMaterial.scanMarkupByteCount = 128
        let snapshot = try note(
            attachments: [gallery],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "gallery", typeUTI: "com.apple.notes.gallery"))]
        )

        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: SnapshotAttachmentArchive(attachments: [pageMaterial]),
            existing: []
        )

        let expected = SnapshotScanRecreation(parentID: "gallery", pages: [
            SnapshotScanPageRecreation(
                id: "page", material: pageMaterial, filter: 0, orientation: 0, crop: nil,
                markupSHA256: String(repeating: "b", count: 64), markupByteCount: 128
            ),
        ])
        XCTAssertEqual(plan.attachment("gallery")?.action, .recreateScan(expected))
        XCTAssertTrue(plan.canRestore)
    }

    func testRecreatesScanPageWithEmbeddedImageMarkup() throws {
        let page = Attachment(
            id: "page",
            typeUTI: "public.jpeg",
            filename: "page.jpg",
            scanHasMarkup: true,
            scanHasEmbeddedMarkup: true
        )
        let gallery = Attachment(
            id: "gallery",
            typeUTI: "com.apple.notes.gallery",
            childAttachmentIDs: [page.id],
            childAttachments: [page]
        )
        var pageMaterial = material("page", typeUTI: "public.jpeg", filename: "page.jpg", parentID: "gallery")
        pageMaterial.scanMarkupSHA256 = String(repeating: "c", count: 64)
        pageMaterial.scanMarkupByteCount = 96
        let snapshot = try note(
            attachments: [gallery],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "gallery", typeUTI: "com.apple.notes.gallery"))]
        )

        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: SnapshotAttachmentArchive(attachments: [pageMaterial]),
            existing: []
        )

        let expected = SnapshotScanRecreation(parentID: "gallery", pages: [
            SnapshotScanPageRecreation(
                id: "page", material: pageMaterial, filter: 0, orientation: 0, crop: nil,
                hasEmbeddedMarkup: true,
                markupSHA256: String(repeating: "c", count: 64), markupByteCount: 96
            ),
        ])
        XCTAssertEqual(plan.attachment("gallery")?.action, .recreateScan(expected))
        XCTAssertTrue(plan.canRestore)
    }

    func testRecreatesMissingSingleFragmentRecordingWithTranscript() throws {
        let transcript = [TranscriptWord(text: "Hello", start: 0.1, duration: 0.4, speaker: "Speaker 1", fragment: 0)]
        let child = Attachment(id: "fragment", typeUTI: "public.mpeg-4-audio", filename: "audio.m4a")
        let recording = Attachment(
            id: "recording",
            typeUTI: "com.apple.m4a-audio",
            title: "Recording",
            transcriptWords: transcript,
            recording: RecordingMetadata(),
            duration: 1.25,
            childAttachmentIDs: [child.id],
            childAttachments: [child]
        )
        let audio = material(
            child.id,
            typeUTI: child.typeUTI,
            filename: child.filename,
            parentID: recording.id
        )
        let snapshot = try note(
            attachments: [recording],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: recording.id, typeUTI: recording.typeUTI))]
        )

        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: SnapshotAttachmentArchive(attachments: [audio]),
            existing: []
        )

        let recreation = SnapshotRecordingRecreation(
            parentID: recording.id,
            childID: child.id,
            material: audio,
            duration: 1.25,
            transcript: transcript
        )
        XCTAssertEqual(plan.attachment(recording.id)?.action, .recreateRecording(recreation))
        XCTAssertEqual(plan.attachment(child.id)?.action, .recreatedByParent(recording.id))
        XCTAssertTrue(plan.canRestore)
    }

    func testRefusesUnsafeRecordingGraphsAndMetadata() throws {
        let transcript = [TranscriptWord(text: "Hello", start: 0, duration: 0.5, fragment: 0)]
        let first = Attachment(id: "first", typeUTI: "public.mpeg-4-audio", filename: "first.m4a")
        let second = Attachment(id: "second", typeUTI: "public.mpeg-4-audio", filename: "second.m4a")
        func snapshot(children: [Attachment], metadata: RecordingMetadata = RecordingMetadata()) throws -> Note {
            let parent = Attachment(
                id: "recording", typeUTI: "com.apple.m4a-audio", transcriptWords: transcript,
                recording: metadata, duration: 1,
                childAttachmentIDs: children.map(\.id), childAttachments: children
            )
            return try note(
                attachments: [parent],
                runs: [AttributeRun(length: 1, attachment: InlineRef(id: parent.id, typeUTI: parent.typeUTI))]
            )
        }
        let firstMaterial = material(first.id, typeUTI: first.typeUTI, filename: first.filename, parentID: "recording")
        let secondMaterial = material(second.id, typeUTI: second.typeUTI, filename: second.filename, parentID: "recording")

        let multiple = SnapshotRestorePlanner.plan(
            snapshot: try snapshot(children: [first, second]),
            verifiedArchive: SnapshotAttachmentArchive(attachments: [firstMaterial, secondMaterial]),
            existing: []
        )
        XCTAssertEqual(multiple.attachment("recording")?.action, .refuse(.unsupportedRecording))
        XCTAssertFalse(multiple.canRestore)

        let summarized = SnapshotRestorePlanner.plan(
            snapshot: try snapshot(children: [first], metadata: RecordingMetadata(summary: "Saved summary")),
            verifiedArchive: SnapshotAttachmentArchive(attachments: [firstMaterial]),
            existing: []
        )
        XCTAssertEqual(summarized.attachment("recording")?.action, .refuse(.unsupportedRecording))
        XCTAssertFalse(summarized.canRestore)

        let partial = SnapshotRestorePlanner.plan(
            snapshot: try snapshot(children: [first]),
            verifiedArchive: SnapshotAttachmentArchive(attachments: [firstMaterial]),
            existing: [SnapshotRestoreExistingAttachment(
                id: first.id,
                typeUTI: first.typeUTI,
                parentID: "recording",
                isMarkedForDeletion: false
            )]
        )
        XCTAssertEqual(partial.attachment("recording")?.action, .refuse(.parentChildTopology))
        XCTAssertFalse(partial.canRestore)
    }

    func testRecreatesOrderedMultiFragmentRecordingAndRemapsFragmentMetadata() throws {
        let dates = [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200)]
        let first = Attachment(id: "first", typeUTI: "public.mpeg-4-audio", filename: "first.m4a", duration: 0.4)
        let second = Attachment(id: "second", typeUTI: "public.mpeg-4-audio", filename: "second.m4a", duration: 0.6)
        let transcript = [
            TranscriptWord(text: "First", start: 0, duration: 0.3, fragment: 0),
            TranscriptWord(text: "Second", start: 0, duration: 0.5, fragment: 1),
        ]
        let metadata = RecordingMetadata(summary: "Summary", topLineSummary: "Preview", summaryVersion: 1,
                                         callType: 1, isCallRecording: true,
                                         startTime: Date(timeIntervalSince1970: 50))
        let recording = Attachment(
            id: "recording", typeUTI: "com.apple.m4a-audio", transcriptWords: transcript,
            recording: metadata,
            recordingFragments: [
                RecordingFragmentMetadata(id: first.id, createdDate: dates[0], transcriptVersion: 1),
                RecordingFragmentMetadata(id: second.id, createdDate: dates[1], transcriptVersion: 2),
            ],
            duration: 1, childAttachmentIDs: [first.id, second.id],
            childAttachments: [first, second]
        )
        let firstMaterial = material(first.id, typeUTI: first.typeUTI, filename: first.filename, parentID: recording.id)
        let secondMaterial = material(second.id, typeUTI: second.typeUTI, filename: second.filename,
                                      hash: String(repeating: "b", count: 64), parentID: recording.id)
        let snapshot = try note(
            attachments: [recording],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: recording.id, typeUTI: recording.typeUTI))]
        )

        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: SnapshotAttachmentArchive(attachments: [firstMaterial, secondMaterial]),
            existing: []
        )

        XCTAssertEqual(plan.attachment(recording.id)?.action, .recreateRecording(SnapshotRecordingRecreation(
            parentID: recording.id,
            fragments: [
                SnapshotRecordingFragmentRecreation(id: first.id, material: firstMaterial, duration: 0.4,
                                                    createdDate: dates[0], transcriptVersion: 1,
                                                    transcript: [transcript[0]]),
                SnapshotRecordingFragmentRecreation(id: second.id, material: secondMaterial, duration: 0.6,
                                                    createdDate: dates[1], transcriptVersion: 2,
                                                    transcript: [transcript[1]]),
            ],
            duration: 1,
            metadata: metadata
        )))
        XCTAssertTrue(plan.canRestore)

        let remapped = try SnapshotAttachmentIDRemapper.remap(
            snapshot,
            attachmentIDs: ["recording": "new-recording", "first": "new-first", "second": "new-second"]
        )
        XCTAssertEqual(remapped.attachments.first?.recordingFragments?.map(\.id), ["new-first", "new-second"])
    }

    func testRecreatesAppleMultiFragmentRecordingWithZeroStoredChildDurations() throws {
        let dates = [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200)]
        let first = Attachment(id: "first", typeUTI: "public.mpeg-4-audio", filename: "first.m4a", duration: 0)
        let second = Attachment(id: "second", typeUTI: "public.mpeg-4-audio", filename: "second.m4a", duration: 0)
        let recording = Attachment(
            id: "recording", typeUTI: "com.apple.m4a-audio",
            recording: RecordingMetadata(summary: ""),
            recordingFragments: [
                RecordingFragmentMetadata(id: first.id, createdDate: dates[0], transcriptVersion: 1),
                RecordingFragmentMetadata(id: second.id, createdDate: dates[1], transcriptVersion: 1),
            ],
            duration: 9.5, childAttachmentIDs: [first.id, second.id], childAttachments: [first, second]
        )
        let firstMaterial = material(
            first.id, typeUTI: first.typeUTI, filename: first.filename, parentID: recording.id,
            mediaDuration: 4
        )
        let secondMaterial = material(
            second.id, typeUTI: second.typeUTI, filename: second.filename,
            hash: String(repeating: "b", count: 64), parentID: recording.id, mediaDuration: 5.5
        )
        let snapshot = try note(
            attachments: [recording],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: recording.id, typeUTI: recording.typeUTI))]
        )

        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: SnapshotAttachmentArchive(attachments: [firstMaterial, secondMaterial]),
            existing: []
        )

        XCTAssertEqual(plan.attachment(recording.id)?.action, .recreateRecording(SnapshotRecordingRecreation(
            parentID: recording.id,
            fragments: [
                SnapshotRecordingFragmentRecreation(id: first.id, material: firstMaterial, duration: 0,
                                                    createdDate: dates[0], transcriptVersion: 1, transcript: []),
                SnapshotRecordingFragmentRecreation(id: second.id, material: secondMaterial, duration: 0,
                                                    createdDate: dates[1], transcriptVersion: 1, transcript: []),
            ],
            duration: 9.5
        )))
        XCTAssertTrue(plan.canRestore)

        var mismatched = secondMaterial
        mismatched.mediaDuration = 4
        let refused = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: SnapshotAttachmentArchive(attachments: [firstMaterial, mismatched]),
            existing: []
        )
        XCTAssertEqual(refused.attachment(recording.id)?.action, .refuse(.unsupportedRecording))
        XCTAssertFalse(refused.canRestore)
    }

    func testRefusesIncompleteOrAmbiguousMultiFragmentRecordings() throws {
        let first = Attachment(id: "first", typeUTI: "public.mpeg-4-audio", filename: "first.m4a", duration: 0.5)
        let second = Attachment(id: "second", typeUTI: "public.mpeg-4-audio", filename: "second.m4a", duration: 0.5)
        let archive = SnapshotAttachmentArchive(attachments: [
            material(first.id, typeUTI: first.typeUTI, filename: first.filename, parentID: "recording"),
            material(second.id, typeUTI: second.typeUTI, filename: second.filename,
                     hash: String(repeating: "b", count: 64), parentID: "recording"),
        ])
        func snapshot(_ metadata: [RecordingFragmentMetadata], duration: Double = 1,
                      recordingMetadata: RecordingMetadata? = nil) throws -> Note {
            let parent = Attachment(
                id: "recording", typeUTI: "com.apple.m4a-audio",
                transcriptWords: [TranscriptWord(text: "A", fragment: 0), TranscriptWord(text: "B", fragment: 1)],
                recording: recordingMetadata, recordingFragments: metadata, duration: duration,
                childAttachmentIDs: [first.id, second.id], childAttachments: [first, second]
            )
            return try note(
                attachments: [parent],
                runs: [AttributeRun(length: 1, attachment: InlineRef(id: parent.id, typeUTI: parent.typeUTI))]
            )
        }
        let date = Date(timeIntervalSince1970: 100)
        let cases = [
            try snapshot([RecordingFragmentMetadata(id: first.id, createdDate: date, transcriptVersion: 1)]),
            try snapshot([
                RecordingFragmentMetadata(id: first.id, createdDate: date, transcriptVersion: 1),
                RecordingFragmentMetadata(id: first.id, createdDate: date.addingTimeInterval(1), transcriptVersion: 1),
            ]),
            try snapshot([
                RecordingFragmentMetadata(id: first.id, createdDate: date, transcriptVersion: 1),
                RecordingFragmentMetadata(id: second.id, createdDate: date, transcriptVersion: 1),
            ]),
            try snapshot([
                RecordingFragmentMetadata(id: first.id, createdDate: date, transcriptVersion: 1),
                RecordingFragmentMetadata(id: second.id, createdDate: date.addingTimeInterval(1)),
            ]),
            try snapshot([
                RecordingFragmentMetadata(id: first.id, createdDate: date, transcriptVersion: 1),
                RecordingFragmentMetadata(id: second.id, createdDate: date.addingTimeInterval(1), transcriptVersion: 1),
            ], duration: 4),
            try snapshot([
                RecordingFragmentMetadata(id: first.id, createdDate: date.addingTimeInterval(1), transcriptVersion: 1),
                RecordingFragmentMetadata(id: second.id, createdDate: date, transcriptVersion: 1),
            ]),
        ]
        for value in cases {
            let plan = SnapshotRestorePlanner.plan(snapshot: value, verifiedArchive: archive, existing: [])
            XCTAssertEqual(plan.attachment("recording")?.action, .refuse(.unsupportedRecording))
            XCTAssertFalse(plan.canRestore)
        }

        let undatedSingle = Attachment(
            id: "single", typeUTI: "com.apple.m4a-audio",
            transcriptWords: [TranscriptWord(text: "Saved", fragment: 0)],
            recordingFragments: [RecordingFragmentMetadata(id: first.id, transcriptVersion: 1)],
            duration: 0.5, childAttachmentIDs: [first.id], childAttachments: [first]
        )
        let undated = try note(
            attachments: [undatedSingle],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: undatedSingle.id, typeUTI: undatedSingle.typeUTI))]
        )
        let undatedPlan = SnapshotRestorePlanner.plan(
            snapshot: undated,
            verifiedArchive: SnapshotAttachmentArchive(attachments: [
                material(first.id, typeUTI: first.typeUTI, filename: first.filename, parentID: undatedSingle.id)
            ]),
            existing: []
        )
        XCTAssertEqual(undatedPlan.attachment(undatedSingle.id)?.action, .refuse(.unsupportedRecording))
    }

    func testRecreatesRecordingThatHasNoTranscript() throws {
        let child = Attachment(id: "fragment", typeUTI: "com.apple.m4a-audio", filename: "audio.m4a")
        let recording = Attachment(
            id: "recording",
            typeUTI: "com.apple.m4a-audio",
            duration: 1,
            childAttachmentIDs: [child.id],
            childAttachments: [child]
        )
        let audio = material(child.id, typeUTI: child.typeUTI, filename: child.filename, parentID: recording.id)
        let snapshot = try note(
            attachments: [recording],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: recording.id, typeUTI: recording.typeUTI))]
        )

        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: SnapshotAttachmentArchive(attachments: [audio]),
            existing: []
        )

        XCTAssertEqual(
            plan.attachment(recording.id)?.action,
            .recreateRecording(SnapshotRecordingRecreation(
                parentID: recording.id,
                childID: child.id,
                material: audio,
                duration: 1,
                transcript: []
            ))
        )
        XCTAssertTrue(plan.canRestore)
    }

    func testRemapsCompleteScanParentChildGraph() throws {
        let page = Attachment(id: "old-page", typeUTI: "public.jpeg", filename: "page.jpg")
        let gallery = Attachment(id: "old-gallery", typeUTI: "com.apple.notes.gallery",
                                 childAttachmentIDs: ["old-page"], childAttachments: [page])
        let snapshot = try note(
            attachments: [gallery],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "old-gallery", typeUTI: "com.apple.notes.gallery"))]
        )

        let remapped = try SnapshotAttachmentIDRemapper.remap(
            snapshot,
            attachmentIDs: ["old-gallery": "new-gallery", "old-page": "new-page"]
        )

        XCTAssertEqual(remapped.document?.runs.first?.attachment?.id, "new-gallery")
        XCTAssertEqual(remapped.attachments.first?.id, "new-gallery")
        XCTAssertEqual(remapped.attachments.first?.childAttachmentIDs, ["new-page"])
        XCTAssertEqual(remapped.attachments.first?.childAttachments?.first?.id, "new-page")
    }

    func testExistingTableCellRowRemainsRestorableButMissingRowIsRefused() throws {
        var snapshot = try note(
            attachments: [
                Attachment(id: "table", typeUTI: "com.apple.notes.table"),
                Attachment(id: "cell-file", typeUTI: "public.data"),
            ],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "table", typeUTI: "com.apple.notes.table"))]
        )
        snapshot.document?.tableCells = [
            "table": [[TableCellDocument(
                text: "\u{fffc}",
                runs: [AttributeRun(length: 1, attachment: InlineRef(id: "cell-file", typeUTI: "public.data"))]
            )]],
        ]
        let existing = [
            SnapshotRestoreExistingAttachment(id: "table", typeUTI: "com.apple.notes.table", isMarkedForDeletion: false),
            SnapshotRestoreExistingAttachment(id: "cell-file", typeUTI: "public.data", parentID: "table", isMarkedForDeletion: false),
        ]

        let restorable = SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: nil, existing: existing)
        XCTAssertEqual(restorable.attachment("cell-file")?.action, .keep)
        XCTAssertTrue(restorable.canRestore)

        let missing = SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: nil, existing: Array(existing.prefix(1)))
        XCTAssertEqual(missing.attachment("cell-file")?.action, .refuse(.nestedAttachment))
        XCTAssertFalse(missing.canRestore)
    }

    func testTableCellUsesCapturedStoredParentInsteadOfInventingOne() throws {
        func snapshot(parentID: String?) throws -> Note {
            var reference = InlineRef(id: "cell-tag", typeUTI: "com.apple.notes.inlinetextattachment.hashtag")
            reference.parentAttachmentCaptured = true
            reference.parentAttachmentID = parentID
            var value = try note(
                attachments: [
                    Attachment(id: "table", typeUTI: "com.apple.notes.table"),
                    Attachment(id: reference.id, typeUTI: reference.typeUTI, displayText: "#work"),
                ],
                runs: [AttributeRun(length: 1, attachment: InlineRef(id: "table", typeUTI: "com.apple.notes.table"))]
            )
            value.document?.tableCells = [
                "table": [[TableCellDocument(
                    text: "\u{fffc}",
                    runs: [AttributeRun(length: 1, attachment: reference)]
                )]],
            ]
            return value
        }
        let table = SnapshotRestoreExistingAttachment(
            id: "table", typeUTI: "com.apple.notes.table", isMarkedForDeletion: false
        )
        func tag(parentID: String?) -> SnapshotRestoreExistingAttachment {
            SnapshotRestoreExistingAttachment(
                id: "cell-tag",
                typeUTI: "com.apple.notes.inlinetextattachment.hashtag",
                parentID: parentID,
                isMarkedForDeletion: false
            )
        }

        XCTAssertEqual(
            SnapshotRestorePlanner.plan(
                snapshot: try snapshot(parentID: nil), verifiedArchive: nil, existing: [table, tag(parentID: nil)]
            ).attachment("cell-tag")?.action,
            .keep
        )
        XCTAssertEqual(
            SnapshotRestorePlanner.plan(
                snapshot: try snapshot(parentID: nil), verifiedArchive: nil, existing: [table, tag(parentID: "table")]
            ).attachment("cell-tag")?.action,
            .refuse(.parentChildTopology)
        )
        XCTAssertEqual(
            SnapshotRestorePlanner.plan(
                snapshot: try snapshot(parentID: "table"), verifiedArchive: nil, existing: [table, tag(parentID: "table")]
            ).attachment("cell-tag")?.action,
            .keep
        )
        XCTAssertEqual(
            SnapshotRestorePlanner.plan(
                snapshot: try snapshot(parentID: "table"), verifiedArchive: nil, existing: [table, tag(parentID: nil)]
            ).attachment("cell-tag")?.action,
            .refuse(.parentChildTopology)
        )
    }

    func testRecreatesMissingNilParentInlineObjectInsideExistingTable() throws {
        var reference = InlineRef(id: "cell-tag", typeUTI: "com.apple.notes.inlinetextattachment.hashtag")
        reference.parentAttachmentCaptured = true
        reference.parentAttachmentID = nil
        var snapshot = try note(
            attachments: [
                Attachment(id: "table", typeUTI: "com.apple.notes.table"),
                Attachment(id: reference.id, typeUTI: reference.typeUTI, displayText: "#work"),
            ],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "table", typeUTI: "com.apple.notes.table"))]
        )
        snapshot.document?.tableCells = [
            "table": [[TableCellDocument(
                text: "\u{fffc}",
                runs: [AttributeRun(length: 1, attachment: reference)]
            )]],
        ]

        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: nil,
            existing: [SnapshotRestoreExistingAttachment(
                id: "table",
                typeUTI: "com.apple.notes.table",
                isMarkedForDeletion: false
            )]
        )

        XCTAssertEqual(plan.attachment("table")?.action, .keep)
        XCTAssertEqual(plan.attachment(reference.id)?.action, .recreateInline(.hashtag("work")))
        XCTAssertTrue(plan.canRestore)
    }

    func testRecreatesAndRemapsMissingTableParentedInlineObject() throws {
        var reference = InlineRef(id: "cell-tag", typeUTI: "com.apple.notes.inlinetextattachment.hashtag")
        reference.parentAttachmentCaptured = true
        reference.parentAttachmentID = "table"
        let tag = Attachment(id: reference.id, typeUTI: reference.typeUTI, displayText: "#work")
        let table = Attachment(
            id: "table",
            typeUTI: "com.apple.notes.table",
            childAttachmentIDs: [tag.id],
            childAttachments: [tag]
        )
        var snapshot = try note(
            attachments: [table],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: table.id, typeUTI: table.typeUTI))]
        )
        snapshot.document?.tableCells = [
            table.id: [[TableCellDocument(
                text: "\u{fffc}",
                runs: [AttributeRun(length: 1, attachment: reference)]
            )]],
        ]

        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: nil,
            existing: [SnapshotRestoreExistingAttachment(
                id: table.id,
                typeUTI: table.typeUTI,
                isMarkedForDeletion: false
            )]
        )

        XCTAssertEqual(plan.attachment(table.id)?.action, .keep)
        XCTAssertEqual(plan.attachment(tag.id)?.action, .recreateInline(.hashtag("work")))
        XCTAssertTrue(plan.canRestore)

        let remapped = try SnapshotAttachmentIDRemapper.remap(
            snapshot,
            attachmentIDs: [tag.id: "new-tag"]
        )
        XCTAssertEqual(remapped.attachments.first?.childAttachmentIDs, ["new-tag"])
        XCTAssertEqual(remapped.attachments.first?.childAttachments?.first?.id, "new-tag")
        XCTAssertEqual(
            remapped.document?.tableCells?[table.id]?.first?.first?.runs.first?.attachment?.id,
            "new-tag"
        )
    }

    func testRemapsSingleTableCellMarker() throws {
        var reference = InlineRef(id: "old-tag", typeUTI: "com.apple.notes.inlinetextattachment.hashtag")
        reference.parentAttachmentCaptured = true
        var snapshot = try note(
            attachments: [
                Attachment(id: "table", typeUTI: "com.apple.notes.table"),
                Attachment(id: reference.id, typeUTI: reference.typeUTI, displayText: "#work"),
            ],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "table", typeUTI: "com.apple.notes.table"))]
        )
        snapshot.document?.tableCells = [
            "table": [[TableCellDocument(
                text: "\u{fffc}",
                runs: [AttributeRun(length: 1, attachment: reference)]
            )]],
        ]

        let remapped = try SnapshotAttachmentIDRemapper.remap(
            snapshot,
            attachmentIDs: [reference.id: "new-tag"]
        )

        XCTAssertEqual(
            remapped.document?.tableCells?["table"]?.first?.first?.runs.first?.attachment?.id,
            "new-tag"
        )
        XCTAssertEqual(remapped.attachments.first(where: { $0.id == "new-tag" })?.displayText, "#work")
    }

    func testRefusesWrongNoteOwnershipAsIDCollision() throws {
        let result = try action(
            for: Attachment(id: "file", typeUTI: "public.data"),
            existing: [SnapshotRestoreExistingAttachment(
                id: "file",
                typeUTI: "public.data",
                belongsToTargetNote: false,
                isMarkedForDeletion: false
            )]
        )

        XCTAssertEqual(result, .refuse(.idCollision))
    }

    func testRefusesExistingAndArchivedUTIMismatches() throws {
        let attachment = Attachment(id: "file", typeUTI: "public.data")
        XCTAssertEqual(
            try action(
                for: attachment,
                existing: [SnapshotRestoreExistingAttachment(id: "file", typeUTI: "public.jpeg", isMarkedForDeletion: false)]
            ),
            .refuse(.typeMismatch)
        )
        XCTAssertEqual(
            try action(
                for: attachment,
                archive: SnapshotAttachmentArchive(attachments: [material("file", typeUTI: "public.jpeg")])
            ),
            .refuse(.typeMismatch)
        )
        let markerMismatch = try note(
            attachments: [attachment],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: "file", typeUTI: "public.jpeg"))]
        )
        XCTAssertEqual(
            SnapshotRestorePlanner.plan(snapshot: markerMismatch, verifiedArchive: nil, existing: [])
                .attachment("file")?.action,
            .refuse(.typeMismatch)
        )
    }

    func testRefusesDuplicateExistingRowsAndDuplicateArchiveMaterial() throws {
        let attachment = Attachment(id: "file", typeUTI: "public.data")
        let row = SnapshotRestoreExistingAttachment(id: "file", typeUTI: "public.data", isMarkedForDeletion: false)
        XCTAssertEqual(try action(for: attachment, existing: [row, row]), .refuse(.idCollision))

        let archived = material("file", typeUTI: "public.data")
        XCTAssertEqual(
            try action(for: attachment, archive: SnapshotAttachmentArchive(attachments: [archived, archived])),
            .refuse(.idCollision)
        )
        XCTAssertEqual(
            try action(
                for: attachment,
                archive: SnapshotAttachmentArchive(attachments: [archived, archived]),
                existing: [row]
            ),
            .keep
        )
    }

    func testRemapsTopLevelDocumentRunAndAttachment() throws {
        let snapshot = try note(
            attachments: [
                Attachment(id: "old", typeUTI: "public.data", filename: "report.bin"),
                Attachment(id: "untouched", typeUTI: "public.jpeg"),
            ],
            runs: [
                AttributeRun(length: 1, attachment: InlineRef(id: "old", typeUTI: "public.data")),
                AttributeRun(length: 1, attachment: InlineRef(id: "untouched", typeUTI: "public.jpeg")),
            ]
        )

        let remapped = try SnapshotAttachmentIDRemapper.remap(snapshot, attachmentIDs: ["old": "new"])

        XCTAssertEqual(snapshot.document?.runs.compactMap(\.attachment?.id), ["old", "untouched"])
        XCTAssertEqual(remapped.document?.runs.compactMap(\.attachment?.id), ["new", "untouched"])
        XCTAssertEqual(remapped.attachments.map(\.id), ["new", "untouched"])
        XCTAssertEqual(remapped.attachments[0].filename, "report.bin")
    }

    func testRemapRefusesTargetAndManyToOneIDCollisions() throws {
        let snapshot = try note(
            attachments: [
                Attachment(id: "first", typeUTI: "public.data"),
                Attachment(id: "second", typeUTI: "public.jpeg"),
            ],
            runs: [
                AttributeRun(length: 1, attachment: InlineRef(id: "first", typeUTI: "public.data")),
                AttributeRun(length: 1, attachment: InlineRef(id: "second", typeUTI: "public.jpeg")),
            ]
        )

        XCTAssertThrowsError(try SnapshotAttachmentIDRemapper.remap(snapshot, attachmentIDs: ["first": "second"])) {
            XCTAssertEqual(($0 as? NotesError)?.code, "attachment_id_collision")
        }
        XCTAssertThrowsError(try SnapshotAttachmentIDRemapper.remap(
            snapshot,
            attachmentIDs: ["first": "new", "second": "new"]
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "attachment_id_collision")
        }
    }

    // MARK: Existing-row evidence

    private func digest(_ letter: Character, _ byteCount: Int = 42) -> SnapshotRestoreDigest {
        SnapshotRestoreDigest(sha256: String(repeating: letter, count: 64), byteCount: byteCount)
    }

    func testKeepsExistingFileOnlyWhenCollectedBytesMatchTheSnapshot() throws {
        let attachment = Attachment(id: "file", typeUTI: "public.jpeg")
        let archive = SnapshotAttachmentArchive(attachments: [material("file", typeUTI: "public.jpeg")])
        func row(_ blob: SnapshotRestoreDigestEvidence, deleted: Bool = false) -> SnapshotRestoreExistingAttachment {
            SnapshotRestoreExistingAttachment(id: "file", typeUTI: "public.jpeg", isMarkedForDeletion: deleted,
                                              evidence: SnapshotRestoreExistingEvidence(blob: blob))
        }

        XCTAssertEqual(try action(for: attachment, archive: archive, existing: [row(.present(digest("a")))]), .keep)
        XCTAssertEqual(try action(for: attachment, archive: archive,
                                  existing: [row(.present(digest("a")), deleted: true)]), .unmark)
        XCTAssertEqual(try action(for: attachment, archive: archive, existing: [row(.present(digest("b")))]),
                       .refuse(.contentMismatch))
        XCTAssertEqual(try action(for: attachment, archive: archive, existing: [row(.present(digest("a", 43)))]),
                       .refuse(.contentMismatch))
        XCTAssertEqual(try action(for: attachment, archive: archive, existing: [row(.absent, deleted: true)]),
                       .refuse(.contentMismatch))
        // Evidence the caller did not collect stays for post-restore verification.
        XCTAssertEqual(try action(for: attachment, archive: archive, existing: [row(.notCollected)]), .keep)
    }

    func testRestoresOnlyChangedExistingAttachmentMarkup() throws {
        let link = Attachment(id: "link", typeUTI: "public.url", url: "https://example.com", synapseDataBytes: 10)
        var linkMaterial = material("link", typeUTI: "public.url", hash: nil, byteCount: nil)
        linkMaterial.synapseSHA256 = String(repeating: "c", count: 64)
        linkMaterial.synapseByteCount = 10
        let linkArchive = SnapshotAttachmentArchive(attachments: [linkMaterial])
        func linkRow(_ synapse: SnapshotRestoreDigestEvidence) -> SnapshotRestoreExistingAttachment {
            SnapshotRestoreExistingAttachment(id: "link", typeUTI: "public.url", isMarkedForDeletion: false,
                                              evidence: SnapshotRestoreExistingEvidence(synapse: synapse))
        }
        XCTAssertEqual(try action(for: link, archive: linkArchive, existing: [linkRow(.present(digest("c", 10)))]), .keep)
        XCTAssertEqual(try action(for: link, archive: linkArchive, existing: [linkRow(.present(digest("d", 10)))]),
                       .refuse(.contentMismatch))

        let image = Attachment(id: "image", typeUTI: "public.png")
        let imageArchive = SnapshotAttachmentArchive(attachments: [material("image", typeUTI: "public.png")])
        let markedUp = SnapshotRestoreExistingAttachment(
            id: "image", typeUTI: "public.png", isMarkedForDeletion: false,
            evidence: SnapshotRestoreExistingEvidence(blob: .present(digest("a")),
                                                      scanMarkup: .present(digest("e", 7)))
        )
        XCTAssertEqual(
            try action(for: image, archive: imageArchive, existing: [markedUp]),
            .restoreExistingMarkup(SnapshotExistingMarkupRestore(
                sha256: nil, byteCount: nil, embedded: false, unmark: false
            ))
        )

        var savedMarkup = material("image", typeUTI: "public.png")
        savedMarkup.scanMarkupSHA256 = String(repeating: "c", count: 64)
        savedMarkup.scanMarkupByteCount = 10
        let savedImage = Attachment(id: "image", typeUTI: "public.png", markupDataBytes: 10,
                                    hasEmbeddedMarkup: true)
        let savedArchive = SnapshotAttachmentArchive(attachments: [savedMarkup])
        func imageRow(_ markup: SnapshotRestoreDigestEvidence, deleted: Bool = false) -> SnapshotRestoreExistingAttachment {
            SnapshotRestoreExistingAttachment(
                id: "image", typeUTI: "public.png", isMarkedForDeletion: deleted,
                evidence: SnapshotRestoreExistingEvidence(blob: .present(digest("a")), scanMarkup: markup)
            )
        }
        let restore = SnapshotExistingMarkupRestore(
            sha256: String(repeating: "c", count: 64), byteCount: 10, embedded: true, unmark: false
        )
        XCTAssertEqual(try action(for: savedImage, archive: savedArchive,
                                  existing: [imageRow(.present(digest("d", 10)))]),
                       .restoreExistingMarkup(restore))
        XCTAssertEqual(try action(for: savedImage, archive: savedArchive,
                                  existing: [imageRow(.absent)]),
                       .restoreExistingMarkup(restore))
        var unmark = restore
        unmark.unmark = true
        XCTAssertEqual(try action(for: savedImage, archive: savedArchive,
                                  existing: [imageRow(.absent, deleted: true)]),
                       .restoreExistingMarkup(unmark))
    }

    func testRefusesMalformedOrUnsupportedExistingMarkupRestore() throws {
        var malformed = material("image", typeUTI: "public.png")
        malformed.scanMarkupSHA256 = "future-format"
        malformed.scanMarkupByteCount = 10
        let image = Attachment(id: "image", typeUTI: "public.png", markupDataBytes: 10)
        let row = SnapshotRestoreExistingAttachment(
            id: "image", typeUTI: "public.png", isMarkedForDeletion: false,
            evidence: SnapshotRestoreExistingEvidence(blob: .present(digest("a")), scanMarkup: .absent)
        )
        XCTAssertEqual(try action(for: image, archive: SnapshotAttachmentArchive(attachments: [malformed]),
                                  existing: [row]), .refuse(.invalidSnapshot))

        var unsupported = material("text", typeUTI: "public.plain-text")
        unsupported.scanMarkupSHA256 = String(repeating: "c", count: 64)
        unsupported.scanMarkupByteCount = 10
        let text = Attachment(id: "text", typeUTI: "public.plain-text", markupDataBytes: 10)
        let textRow = SnapshotRestoreExistingAttachment(
            id: "text", typeUTI: "public.plain-text", isMarkedForDeletion: false,
            evidence: SnapshotRestoreExistingEvidence(blob: .present(digest("a")), scanMarkup: .absent)
        )
        XCTAssertEqual(try action(for: text, archive: SnapshotAttachmentArchive(attachments: [unsupported]),
                                  existing: [textRow]), .refuse(.contentMismatch))
    }

    func testRefusesKeptPaperDocumentWhoseBundleChanged() throws {
        let paper = Attachment(id: "paper", typeUTI: "com.apple.paper.doc.pdf")
        var paperMaterial = material("paper", typeUTI: "com.apple.paper.doc.pdf")
        paperMaterial.paperBundleSHA256 = String(repeating: "f", count: 64)
        paperMaterial.paperBundleByteCount = 99
        let archive = SnapshotAttachmentArchive(attachments: [paperMaterial])
        func row(_ bundle: SnapshotRestoreDigestEvidence) -> SnapshotRestoreExistingAttachment {
            SnapshotRestoreExistingAttachment(
                id: "paper", typeUTI: "com.apple.paper.doc.pdf", isMarkedForDeletion: false,
                evidence: SnapshotRestoreExistingEvidence(blob: .present(digest("a")), paperBundle: bundle)
            )
        }
        XCTAssertEqual(try action(for: paper, archive: archive, existing: [row(.present(digest("f", 99)))]), .keep)
        XCTAssertEqual(try action(for: paper, archive: archive, existing: [row(.present(digest("0", 99)))]),
                       .refuse(.contentMismatch))
    }

    func testRestoresClearedExistingRecordingSummaryWithoutRecreatingAudio() throws {
        let words = [TranscriptWord(text: "hello", start: 0, duration: 0.5, fragment: 0)]
        let fragments = [RecordingFragmentMetadata(
            id: "fragment", createdDate: Date(timeIntervalSince1970: 100), transcriptVersion: 1
        )]
        let metadata = RecordingMetadata(
            summary: "Saved summary", topLineSummary: "Saved preview", summaryVersion: 2,
            externalModelAttributionProviderName: "Provider",
            externalModelAttributionSymbolName: "symbol",
            localSpeakerHandle: "local", remoteSpeakerHandle: "remote",
            callType: 2, isCallRecording: true,
            startTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let child = Attachment(id: "fragment", typeUTI: "com.apple.m4a-audio", duration: 10)
        let saved = Attachment(
            id: "recording", typeUTI: "com.apple.m4a-audio", transcriptWords: words,
            recording: metadata, recordingFragments: fragments, duration: 10,
            childAttachmentIDs: [child.id], childAttachments: [child]
        )
        var current = saved
        var clearedMetadata = metadata
        clearedMetadata.summary = nil
        clearedMetadata.topLineSummary = nil
        clearedMetadata.summaryVersion = nil
        clearedMetadata.externalModelAttributionProviderName = nil
        clearedMetadata.externalModelAttributionSymbolName = nil
        current.recording = clearedMetadata
        let snapshot = try note(
            attachments: [saved],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: saved.id, typeUTI: saved.typeUTI))]
        )
        let archive = SnapshotAttachmentArchive(attachments: [material(
            child.id, typeUTI: child.typeUTI, filename: "recording.m4a",
            parentID: saved.id, mediaDuration: 10
        )])
        let rows = [
            SnapshotRestoreExistingAttachment(
                id: saved.id, typeUTI: saved.typeUTI, isMarkedForDeletion: false,
                evidence: SnapshotRestoreExistingEvidence(orderedChildIDs: [child.id], readback: current)
            ),
            SnapshotRestoreExistingAttachment(
                id: child.id, typeUTI: child.typeUTI, parentID: saved.id, isMarkedForDeletion: false,
                evidence: SnapshotRestoreExistingEvidence(blob: .present(digest("a")), readback: child)
            ),
        ]

        let plan = SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: archive, existing: rows)
        XCTAssertEqual(plan.attachment(saved.id)?.action,
                       .restoreExistingRecordingMetadata(.init(metadata: metadata, unmark: false)))
        XCTAssertEqual(plan.attachment(child.id)?.action, .keep)

        var restoredMetadata = current.recording
        var unmarked = false
        let applied = try NativeNotesWriter.applyExistingRecordingMetadataAction(
            try XCTUnwrap(plan.attachment(saved.id)?.action),
            unmark: { unmarked = true },
            apply: { restoredMetadata = $0 }
        )
        XCTAssertEqual(applied, .init(metadata: metadata, unmark: false))
        XCTAssertEqual(restoredMetadata, metadata)
        XCTAssertFalse(unmarked)
    }

    func testRefusesUnsafeOrGraphMismatchedExistingRecordingMetadataRestore() throws {
        let child = Attachment(id: "fragment", typeUTI: "com.apple.m4a-audio", duration: 10)
        let unsafe = RecordingMetadata(summary: "Saved summary", topLineSummary: nil, summaryVersion: 2)
        let saved = Attachment(
            id: "recording", typeUTI: "com.apple.m4a-audio",
            transcriptWords: [TranscriptWord(text: "saved", start: 0, duration: 0.5, fragment: 0)],
            recording: unsafe, duration: 10,
            childAttachmentIDs: [child.id], childAttachments: [child]
        )
        var current = saved
        current.recording = nil
        let snapshot = try note(
            attachments: [saved],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: saved.id, typeUTI: saved.typeUTI))]
        )
        let archive = SnapshotAttachmentArchive(attachments: [material(
            child.id, typeUTI: child.typeUTI, filename: "recording.m4a",
            parentID: saved.id, mediaDuration: 10
        )])
        func plan(_ readback: Attachment) -> SnapshotRestorePlan {
            SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: archive, existing: [
                SnapshotRestoreExistingAttachment(
                    id: saved.id, typeUTI: saved.typeUTI, isMarkedForDeletion: false,
                    evidence: SnapshotRestoreExistingEvidence(orderedChildIDs: [child.id], readback: readback)
                ),
                SnapshotRestoreExistingAttachment(
                    id: child.id, typeUTI: child.typeUTI, parentID: saved.id, isMarkedForDeletion: false,
                    evidence: SnapshotRestoreExistingEvidence(blob: .present(digest("a")), readback: child)
                ),
            ])
        }
        XCTAssertEqual(plan(current).attachment(saved.id)?.action, .refuse(.unsupportedRecording))
        current.transcriptWords = [TranscriptWord(text: "changed", start: 0, duration: 0.5, fragment: 0)]
        XCTAssertEqual(plan(current).attachment(saved.id)?.action, .refuse(.contentMismatch))
    }

    func testRefusesExistingScanAndRecordingGraphsWithReversedChildOrder() throws {
        for (parentType, childType) in [("com.apple.notes.gallery", "public.jpeg"), ("com.apple.m4a-audio", "com.apple.m4a-audio")] {
            let snapshot = try note(
                attachments: [
                    Attachment(id: "parent", typeUTI: parentType, childAttachmentIDs: ["one", "two"], childAttachments: [
                        Attachment(id: "one", typeUTI: childType),
                        Attachment(id: "two", typeUTI: childType),
                    ]),
                ],
                runs: [AttributeRun(length: 1, attachment: InlineRef(id: "parent", typeUTI: parentType))]
            )
            func plan(_ order: [String]?) -> SnapshotRestorePlan {
                SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: nil, existing: [
                    SnapshotRestoreExistingAttachment(id: "parent", typeUTI: parentType, isMarkedForDeletion: false,
                                                      evidence: SnapshotRestoreExistingEvidence(orderedChildIDs: order)),
                    SnapshotRestoreExistingAttachment(id: "one", typeUTI: childType, parentID: "parent", isMarkedForDeletion: false),
                    SnapshotRestoreExistingAttachment(id: "two", typeUTI: childType, parentID: "parent", isMarkedForDeletion: false),
                ])
            }
            XCTAssertEqual(plan(["one", "two"]).attachment("parent")?.action, .keep, parentType)
            XCTAssertEqual(plan(nil).attachment("parent")?.action, .keep, parentType)
            XCTAssertEqual(plan(["two", "one"]).attachment("parent")?.action, .refuse(.parentChildTopology), parentType)
            XCTAssertFalse(plan(["two", "one"]).canRestore, parentType)
        }
    }

    func testRestoresExistingScanStateAndOrderWithoutRecreatingPages() throws {
        let crop = ScanCrop(
            bottomLeft: ScanPoint(x: 0.1, y: 0.9), bottomRight: ScanPoint(x: 0.9, y: 0.9),
            topLeft: ScanPoint(x: 0.1, y: 0.1), topRight: ScanPoint(x: 0.9, y: 0.1)
        )
        let first = Attachment(id: "one", typeUTI: "public.jpeg", scanFilter: 2, scanOrientation: 1,
                               scanCrop: crop, scanHasMarkup: false, scanHasEmbeddedMarkup: false)
        let second = Attachment(id: "two", typeUTI: "public.jpeg", scanFilter: 0, scanOrientation: 0,
                                scanCrop: nil, scanHasMarkup: true, scanHasEmbeddedMarkup: true)
        let gallery = Attachment(id: "gallery", typeUTI: "com.apple.notes.gallery",
                                 childAttachmentIDs: [first.id, second.id], childAttachments: [first, second])
        let snapshot = try note(
            attachments: [gallery],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: gallery.id, typeUTI: gallery.typeUTI))]
        )
        let firstMaterial = material(first.id, typeUTI: first.typeUTI, filename: "one.jpg", parentID: gallery.id)
        var secondMaterial = material(second.id, typeUTI: second.typeUTI, filename: "two.jpg",
                                      hash: String(repeating: "b", count: 64), parentID: gallery.id)
        secondMaterial.scanMarkupSHA256 = String(repeating: "c", count: 64)
        secondMaterial.scanMarkupByteCount = 10
        let currentFirst = Attachment(id: first.id, typeUTI: first.typeUTI, scanFilter: 4, scanOrientation: 0,
                                      scanCrop: crop, scanHasMarkup: false, scanHasEmbeddedMarkup: false)
        let currentSecond = Attachment(id: second.id, typeUTI: second.typeUTI, scanFilter: 0, scanOrientation: 0,
                                       scanCrop: nil, scanHasMarkup: false, scanHasEmbeddedMarkup: false)
        let currentGallery = Attachment(id: gallery.id, typeUTI: gallery.typeUTI,
                                        childAttachmentIDs: [second.id, first.id],
                                        childAttachments: [currentSecond, currentFirst])
        let rows = [
            SnapshotRestoreExistingAttachment(
                id: gallery.id, typeUTI: gallery.typeUTI, isMarkedForDeletion: false,
                evidence: SnapshotRestoreExistingEvidence(
                    orderedChildIDs: [second.id, first.id], readback: currentGallery
                )
            ),
            SnapshotRestoreExistingAttachment(
                id: first.id, typeUTI: first.typeUTI, parentID: gallery.id, isMarkedForDeletion: false,
                evidence: SnapshotRestoreExistingEvidence(
                    blob: .present(digest("a")), scanMarkup: .absent, readback: currentFirst
                )
            ),
            SnapshotRestoreExistingAttachment(
                id: second.id, typeUTI: second.typeUTI, parentID: gallery.id, isMarkedForDeletion: false,
                evidence: SnapshotRestoreExistingEvidence(
                    blob: .present(digest("b")), scanMarkup: .absent, readback: currentSecond
                )
            ),
        ]
        let plan = SnapshotRestorePlanner.plan(
            snapshot: snapshot,
            verifiedArchive: SnapshotAttachmentArchive(attachments: [firstMaterial, secondMaterial]),
            existing: rows
        )
        XCTAssertEqual(plan.attachment(gallery.id)?.action, .restoreExistingScan(.init(
            parentID: gallery.id,
            orderedPageIDs: [first.id, second.id],
            pages: [
                .init(id: first.id, filter: 2, orientation: 1, crop: crop,
                      markupSHA256: nil, markupByteCount: nil, hasEmbeddedMarkup: false, unmark: false),
                .init(id: second.id, filter: 0, orientation: 0, crop: nil,
                      markupSHA256: String(repeating: "c", count: 64), markupByteCount: 10,
                      hasEmbeddedMarkup: true, unmark: false),
            ],
            unmarkParent: false
        )))
        XCTAssertEqual(plan.attachment(first.id)?.action, .restoredByParent(gallery.id))
        XCTAssertEqual(plan.attachment(second.id)?.action, .restoredByParent(gallery.id))
    }

    func testRefusesUnsafeExistingScanClearAndNilCropRestore() throws {
        let savedPage = Attachment(id: "page", typeUTI: "public.jpeg", scanFilter: 0, scanOrientation: 0,
                                   scanCrop: nil, scanHasMarkup: false, scanHasEmbeddedMarkup: false)
        let gallery = Attachment(id: "gallery", typeUTI: "com.apple.notes.gallery",
                                 childAttachmentIDs: [savedPage.id], childAttachments: [savedPage])
        let snapshot = try note(
            attachments: [gallery],
            runs: [AttributeRun(length: 1, attachment: InlineRef(id: gallery.id, typeUTI: gallery.typeUTI))]
        )
        let archive = SnapshotAttachmentArchive(attachments: [material(
            savedPage.id, typeUTI: savedPage.typeUTI, filename: "page.jpg", parentID: gallery.id
        )])
        func plan(_ current: Attachment, markup: SnapshotRestoreDigestEvidence) -> SnapshotRestorePlan {
            let currentGallery = Attachment(id: gallery.id, typeUTI: gallery.typeUTI,
                                            childAttachmentIDs: [current.id], childAttachments: [current])
            return SnapshotRestorePlanner.plan(snapshot: snapshot, verifiedArchive: archive, existing: [
                SnapshotRestoreExistingAttachment(
                    id: gallery.id, typeUTI: gallery.typeUTI, isMarkedForDeletion: false,
                    evidence: SnapshotRestoreExistingEvidence(orderedChildIDs: [current.id], readback: currentGallery)
                ),
                SnapshotRestoreExistingAttachment(
                    id: current.id, typeUTI: current.typeUTI, parentID: gallery.id, isMarkedForDeletion: false,
                    evidence: SnapshotRestoreExistingEvidence(blob: .present(digest("a")),
                                                              scanMarkup: markup, readback: current)
                ),
            ])
        }
        var current = savedPage
        current.scanCrop = ScanCrop(
            bottomLeft: ScanPoint(x: 0, y: 1), bottomRight: ScanPoint(x: 1, y: 1),
            topLeft: ScanPoint(x: 0, y: 0), topRight: ScanPoint(x: 1, y: 0)
        )
        XCTAssertEqual(plan(current, markup: .absent).attachment(gallery.id)?.action,
                       .refuse(.unsupportedScan))
        current = savedPage
        current.scanHasMarkup = true
        XCTAssertEqual(plan(current, markup: .present(digest("c", 10))).attachment(gallery.id)?.action,
                       .refuse(.unsupportedScan))
    }
}
