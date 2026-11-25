import AppKit
import Foundation
import NotesCore
import NotesStore
import XCTest
@testable import notescli

@MainActor
private final class TemplatePasteTextView: NSTextView {
    private let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}

@MainActor
private final class TemplatePasteSecondWriter: EditorTemplatePasteboard {
    let board: NSPasteboard
    var afterWrite: (() -> Void)?
    var rejectNextWrite = false

    init(_ board: NSPasteboard) { self.board = board }
    var changeCount: Int { board.changeCount }
    var pasteboardItems: [NSPasteboardItem]? { board.pasteboardItems }
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        board.prepareForNewContents(with: options)
    }
    func data(forType type: NSPasteboard.PasteboardType) -> Data? { board.data(forType: type) }
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        if rejectNextWrite {
            rejectNextWrite = false
            return false
        }
        let written = board.writeObjects(objects)
        let callback = afterWrite
        afterWrite = nil
        callback?()
        return written
    }
}

@MainActor
private final class TemplatePasteUnreadableFlavor: NSObject, NSPasteboardItemDataProvider, EditorTemplatePasteboard {
    let item = NSPasteboardItem()
    let flavor = NSPasteboard.PasteboardType("org.notescli.test.unreadable")
    private(set) var clearCount = 0
    private(set) var writeCount = 0

    var changeCount: Int { 1 }
    var pasteboardItems: [NSPasteboardItem]? { [item] }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // The item advertises this type, but its source has no data to provide.
    }

    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        clearCount += 1
        return changeCount
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        writeCount += 1
        return false
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? { nil }
}

final class EditorTemplatesTests: XCTestCase {
    func testTemplateFailureExplainsClipboardRecoveryWithoutLeakingErrorDetails() {
        let clipboard = EditorTemplateFailure(NotesError("template_pasteboard_unavailable", "private details"))
        XCTAssertEqual(clipboard, .clipboard)
        XCTAssertEqual(clipboard.event, .templatePasteUnavailable)
        XCTAssertTrue(clipboard.message.contains("plain text"))
        let preparation = EditorTemplateFailure(NotesError("template_rich_text_changed", "private details"))
        XCTAssertEqual(preparation, .preparation)
        XCTAssertFalse(preparation.message.contains("private details"))
        XCTAssertEqual(preparation.event, .templatePreparationFailed)
        XCTAssertEqual(EditorTemplateFailure.unconfirmed.event, .templateInsertionUnconfirmed)
    }

    func testCustomPointSizeUsesRichPasteAndKeepsTheExactUTF16Range() throws {
        let summary = folder("r", "Templates", account: Account(id: "a", name: "A", kind: "local"))
        let prefix = "🌱 Before "
        let sized = "bold café"
        var source = note(title: "Agenda", folder: summary, text: "Agenda\n" + prefix + sized + " after")
        var font = FontStyle(bold: true)
        font.pointSize = 23
        source.document?.runs = [
            AttributeRun(length: "Agenda\n".utf16.count, paragraph: ParagraphStyle(kind: .title)),
            AttributeRun(length: prefix.utf16.count),
            AttributeRun(length: sized.utf16.count, font: font),
            AttributeRun(length: " after".utf16.count)
        ]
        let payload = try EditorTemplateStore.payload(source)
        XCTAssertNil(payload.markdown)
        let encoded = try JSONEncoder().encode(payload)
        let roundTrip = try JSONDecoder().decode(EditorTemplatePayload.self, from: encoded)
        let rich = try XCTUnwrap(roundTrip.richText)
        try MainActor.assumeIsolated {
            let data = try rich.rtfd(expectedText: payload.text)
            let restored = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                  documentAttributes: nil)
            XCTAssertEqual(restored.string, prefix + sized + " after")
            let start = prefix.utf16.count
            let end = start + sized.utf16.count
            var range = NSRange()
            let font = try XCTUnwrap(restored.attribute(.font, at: start, effectiveRange: &range) as? NSFont)
            XCTAssertEqual(range, NSRange(location: start, length: sized.utf16.count))
            XCTAssertEqual(font.pointSize, 23, accuracy: 0.01)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            for position in [start - 1, end] {
                let adjacent = try XCTUnwrap(restored.attribute(.font, at: position, effectiveRange: nil) as? NSFont)
                XCTAssertNotEqual(adjacent.pointSize, font.pointSize)
            }
        }
    }

    func testNonMarkdownStylesUseRichPasteAndKeepTheirRanges() throws {
        let summary = folder("r", "Templates", account: Account(id: "a", name: "A", kind: "local"))
        let prefix = "🌱 Before "
        let styled = "coloured"
        let rtl = "שלום"
        let tail = " after\n"
        var source = note(title: "Agenda", folder: summary, text: "Agenda\n" + prefix + styled + tail + rtl)
        var paragraph = ParagraphStyle(kind: .body)
        paragraph.alignment = 1
        paragraph.writingDirection = 1
        var font = FontStyle(underline: true, superscript: 1)
        font.name = "Menlo-Regular"
        source.document?.runs = [
            AttributeRun(length: "Agenda\n".utf16.count, paragraph: ParagraphStyle(kind: .title)),
            AttributeRun(length: prefix.utf16.count),
            AttributeRun(length: styled.utf16.count, font: font, color: "#882244", highlight: .blue),
            AttributeRun(length: tail.utf16.count),
            AttributeRun(length: rtl.utf16.count, paragraph: paragraph)
        ]
        let payload = try EditorTemplateStore.payload(source)
        XCTAssertNil(payload.markdown)
        let rich = try XCTUnwrap(payload.richText)
        try MainActor.assumeIsolated {
            let data = try rich.rtfd(expectedText: payload.text)
            let restored = try NSAttributedString(data: data,
                                                  options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                  documentAttributes: nil)
            let index = prefix.utf16.count
            let textEnd = index + styled.utf16.count
            XCTAssertEqual(restored.string, prefix + styled + tail + rtl)
            XCTAssertEqual((restored.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.familyName, "Menlo")
            XCTAssertEqual(restored.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int, 1)
            XCTAssertEqual(restored.attribute(.superscript, at: index, effectiveRange: nil) as? Int, 1)
            for (key, expected) in [(NSAttributedString.Key.foregroundColor, 0x88), (.backgroundColor, 0x21)] {
                var effective = NSRange()
                let value = try XCTUnwrap(restored.attribute(key, at: index, effectiveRange: &effective) as? NSColor)
                let srgb = try XCTUnwrap(value.usingColorSpace(.sRGB))
                XCTAssertEqual(srgb.redComponent, CGFloat(expected) / 255, accuracy: 0.01)
                XCTAssertEqual(effective, NSRange(location: index, length: styled.utf16.count))
            }
            XCTAssertNil(restored.attribute(.backgroundColor, at: textEnd, effectiveRange: nil))
            let savedParagraph = try XCTUnwrap(restored.attribute(.paragraphStyle, at: textEnd + tail.utf16.count,
                                                                  effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(savedParagraph.alignment, .center)
            XCTAssertEqual(savedParagraph.baseWritingDirection, .rightToLeft)
        }
    }

    func testRichTemplatePreservesBlankParagraphsAndRepeatedSpaces() throws {
        let summary = folder("r", "Templates", account: Account(id: "a", name: "A", kind: "local"))
        let body = "\n  Before\t after\n\n\nLast \u{E000}  \n\n"
        var source = note(title: "Agenda", folder: summary, text: "Agenda\n" + body)
        source.document?.runs = [
            AttributeRun(length: "Agenda\n".utf16.count, paragraph: ParagraphStyle(kind: .title)),
            AttributeRun(length: body.utf16.count, font: FontStyle(underline: true))
        ]
        let payload = try EditorTemplateStore.payload(source)
        let rich = try XCTUnwrap(payload.richText)
        try MainActor.assumeIsolated {
            let data = try rich.rtfd(expectedText: payload.text)
            let restored = try NSAttributedString(data: data,
                                                  options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                  documentAttributes: nil)
            XCTAssertEqual(restored.string, body)
        }
    }

    func testStyledTextTemplateProvidesRichPasteWhenPasteAsMarkdownIsUnavailable() throws {
        let summary = folder("r", "Templates", account: Account(id: "a", name: "A", kind: "local"))
        var source = note(title: "Agenda", folder: summary, text: "Agenda\nRésumé\nDetails")
        source.document?.runs = [
            AttributeRun(length: "Agenda\n".utf16.count, paragraph: ParagraphStyle(kind: .title)),
            AttributeRun(length: "Résumé\n".utf16.count, paragraph: ParagraphStyle(kind: .heading)),
            AttributeRun(length: "Details".utf16.count, font: FontStyle(bold: true), link: "https://example.com/agenda")
        ]
        let payload = try EditorTemplateStore.payload(source)
        XCTAssertNotNil(payload.markdown)
        let fallback = try XCTUnwrap(payload.richText)
        XCTAssertTrue(fallback.images.isEmpty)
        try MainActor.assumeIsolated {
            let data = try fallback.rtfd(expectedText: payload.text)
            let rendered = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                  documentAttributes: nil)
            XCTAssertEqual(rendered.string, "Résumé\nDetails")
            let location = "Résumé\n".utf16.count
            let font = try XCTUnwrap(rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            XCTAssertEqual(rendered.attribute(.link, at: location, effectiveRange: nil) as? URL,
                           URL(string: "https://example.com/agenda"))
        }
    }

    func testImageTemplateKeepsTextAndImageInOrderInRichPasteData() throws {
        let filename = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: filename) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jNukAAAAASUVORK5CYII="))
        try png.write(to: filename, options: .withoutOverwriting)
        var source = note(title: "Agenda", folder: folder("r", "Templates",
                          account: Account(id: "a", name: "A", kind: "local")), text: "Agenda\nBefore \u{fffc} After")
        source.attachments = [Attachment(id: "image", typeUTI: "public.png", filename: "example.png", filePath: filename.path)]
        var imageTextFont = FontStyle(bold: true)
        imageTextFont.pointSize = 19
        source.document?.runs = [
            AttributeRun(length: "Agenda\n".utf16.count, paragraph: ParagraphStyle(kind: .title)),
            AttributeRun(length: "Before ".utf16.count, font: imageTextFont),
            AttributeRun(length: 1, attachment: InlineRef(id: "image", typeUTI: "public.png")),
            AttributeRun(length: " After".utf16.count, font: imageTextFont)
        ]
        let payload = try EditorTemplateStore.payload(source)
        let richText = try XCTUnwrap(payload.richText)
        source.document = NoteDocument(text: "Agenda\nBefore\n\n\u{fffc}\n\nAfter\n", runs: [
            AttributeRun(length: "Agenda\n".utf16.count, paragraph: ParagraphStyle(kind: .title)),
            AttributeRun(length: "Before\n\n".utf16.count),
            AttributeRun(length: 1, attachment: InlineRef(id: "image", typeUTI: "public.png")),
            AttributeRun(length: "\n\nAfter\n".utf16.count)
        ])
        let blockPayload = try EditorTemplateStore.payload(source)
        let block = try XCTUnwrap(blockPayload.richText)
        source.attachments[0].hasEmbeddedMarkup = true
        XCTAssertThrowsError(try EditorTemplateStore.payload(source)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "template_attachments_unsupported")
        }
        try MainActor.assumeIsolated {
            let data = try richText.rtfd(expectedText: payload.text)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let view = TemplatePasteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 140))
            view.isRichText = true
            view.importsGraphics = true
            view.allowsUndo = true
            view.string = "Prefix\n/agenda\nSuffix"
            let original = view.string
            let command = (original as NSString).range(of: "/agenda")
            view.setSelectedRange(command)
            try ClipboardCopy.write("original", to: board)
            try EditorTemplatePaste.withData(data, type: .rtfd, on: board) { stillStaged in
                XCTAssertTrue(stillStaged())
                XCTAssertEqual(board.pasteboardItems?.count, 1)
                XCTAssertEqual(board.data(forType: .rtfd), data)
                view.undoManager?.beginUndoGrouping()
                defer { view.undoManager?.endUndoGrouping() }
                XCTAssertTrue(view.readSelection(from: board, type: .rtfd))
            }
            XCTAssertEqual(board.string(forType: .string), "original")
            XCTAssertEqual(view.string, "Prefix\nBefore \u{fffc} After\nSuffix")
            let pastedImage = try XCTUnwrap(view.textStorage?.attribute(.attachment, at: command.location + 7,
                                                                       effectiveRange: nil) as? NSTextAttachment)
            XCTAssertEqual(pastedImage.fileWrapper?.regularFileContents, png)
            for offset in [0, 9] {
                let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: command.location + offset,
                                                                     effectiveRange: nil) as? NSFont)
                XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
                XCTAssertEqual(font.pointSize, 19, accuracy: 0.01)
            }
            XCTAssertTrue(view.undoManager?.canUndo == true)
            view.undoManager?.undo()
            XCTAssertEqual(view.string, original)
            let rendered = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                  documentAttributes: nil)
            XCTAssertEqual(rendered.string, "Before \u{fffc} After")
            let image = try XCTUnwrap(rendered.attribute(.attachment, at: 7, effectiveRange: nil) as? NSTextAttachment)
            XCTAssertEqual(image.fileWrapper?.regularFileContents, png)
            let bold = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
            XCTAssertEqual(bold.pointSize, 19, accuracy: 0.01)
            let afterImage = try XCTUnwrap(rendered.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(afterImage.pointSize, 19, accuracy: 0.01)
            let blockData = try block.rtfd(expectedText: blockPayload.text)
            let blockRendered = try NSAttributedString(data: blockData, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                       documentAttributes: nil)
            XCTAssertEqual(blockRendered.string, "Before\n\n\u{fffc}\n\nAfter\n")
        }
    }

    func testTemplateCatalogScopesSourceAndUsesStableIDs() throws {
        let work = Account(id: "a", name: "Work", kind: "local")
        let personal = Account(id: "b", name: "Personal", kind: "icloud")
        let folders = [
            folder("work", "Work", account: work),
            folder("a-templates", "Templates", account: work),
            folder("smart-templates", "Templates", account: work, smart: true),
            folder("b-templates", "Templates", account: personal),
        ]
        let destination = note(title: "Destination", folder: folders[0], text: "Destination\nReady")
        let first = note(title: "Café Plan", folder: folders[1], text: "Café Plan\nToday")
        let duplicate = note(title: "Café Plan", folder: folders[1], text: "Café Plan\nTomorrow")
        let locked = note(title: "Locked", folder: folders[1], text: "Locked\nHidden", locked: true)
        let smart = note(title: "Smart", folder: folders[2], text: "Smart\nNot here")
        let different = note(title: "Café Plan", folder: folders[3], text: "Café Plan\nOther account")
        let reader = InMemoryNotes(accounts: [work, personal], folders: folders,
                                   notes: [destination, first, duplicate, locked, smart, different])
        let store = EditorTemplateStore(reader: reader)
        let target = try XCTUnwrap(UUID(uuidString: destination.summary.id.uuid))
        let source = try XCTUnwrap(UUID(uuidString: first.summary.id.uuid))
        let catalog = try store.catalog(destination: target)
        XCTAssertEqual(catalog.count, 2)
        let choices = EditorTemplate.choices(catalog, matching: "template cafe")
        XCTAssertEqual(choices.count, 2)
        XCTAssertNotEqual(choices[0].label, choices[1].label)
        XCTAssertTrue(choices.map(\.action).contains(.template(source)))
        XCTAssertEqual(try store.render(source: source, destination: target).text, "Today")
        for excluded in [destination, different, locked, smart] {
            let excludedID = try XCTUnwrap(UUID(uuidString: excluded.summary.id.uuid))
            XCTAssertThrowsError(try store.render(source: excludedID, destination: target))
        }
        _ = try reader.moveNote("id:" + source.uuidString, toFolder: "work")
        XCTAssertThrowsError(try store.render(source: source, destination: target))
    }

    func testTemplateRemovesOnlyTitleAndExpandsWholeDateTokensAcrossRuns() throws {
        let title = "Résumé 👩🏽‍💻"
        let prefix = title + "\n"
        let remainder = "  @today,  @date.\n\nRésumé 👩🏽‍💻\nuser@today @todayish @@today @now"
        var source = note(title: title, folder: folder("r", "Templates", account: Account(id: "a", name: "A", kind: "local")),
                          text: prefix + remainder)
        source.document?.runs = [
            AttributeRun(length: prefix.utf16.count, paragraph: ParagraphStyle(kind: .title)),
            AttributeRun(length: 3, font: FontStyle(bold: true)),
            AttributeRun(length: 5, font: FontStyle(bold: true)),
            AttributeRun(length: remainder.utf16.count - 8),
        ]
        let date = Date(timeIntervalSince1970: 0)
        let locale = Locale(identifier: "en_US")
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let result = try EditorTemplateStore.payload(source, date: date, locale: locale, timeZone: zone)
        XCTAssertEqual(result.text, "  Jan 1, 1970,  Jan 1, 1970.\n\nRésumé 👩🏽‍💻\nuser@today @todayish @@today @now")
        let markdown = try XCTUnwrap(result.markdown)
        XCTAssertTrue(markdown.contains("Jan 1, 1970"))
        XCTAssertFalse(markdown.hasPrefix("# "))
        XCTAssertTrue(markdown.contains("Résumé 👩🏽‍💻"))
        source.document?.text += "\u{fffc}"
        XCTAssertThrowsError(try EditorTemplateStore.payload(source))
    }

    func testTemplatePasteRestoresClipboardAndKeepsNewerWrites() throws {
        try MainActor.assumeIsolated {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let custom = NSPasteboard.PasteboardType("org.notescli.test")
            let original = NSPasteboardItem()
            original.setString("original", forType: .string)
            original.setData(Data([1, 2, 3]), forType: custom)
            XCTAssertTrue(board.writeObjects([original]))
            try EditorTemplatePaste.withMarkdown("**template**", on: board) { stillStaged in
                XCTAssertTrue(stillStaged())
                XCTAssertEqual(board.string(forType: .string), "**template**")
            }
            XCTAssertEqual(board.string(forType: .string), "original")
            XCTAssertEqual(board.data(forType: custom), Data([1, 2, 3]))
            try EditorTemplatePaste.withMarkdown("**template**", on: board) { stillStaged in
                board.clearContents()
                XCTAssertTrue(board.setString("newer", forType: .string))
                XCTAssertFalse(stillStaged())
            }
            XCTAssertEqual(board.string(forType: .string), "newer")
        }
    }

    func testPasteWaitsForConsumptionWhenTheTemplateStartsWithTheSlashCommand() throws {
        try MainActor.assumeIsolated {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            try ClipboardCopy.write("original", to: board)
            let view = TemplatePasteTextView(frame: .zero)
            view.string = "Title\n/agenda"
            let trigger = (view.string as NSString).range(of: "/agenda")
            view.setSelectedRange(trigger)
            let insert = "/agenda\nNext steps"
            var pauses = 0

            try EditorTemplatePaste.withMarkdown(insert, on: board) { stillStaged in
                XCTAssertTrue(EditorTemplatePaste.confirmInsertion(sample: "/agenda", at: trigger.location,
                    stillStaged: stillStaged, read: { range in
                        (view.selectedRange(), (view.string as NSString).substring(with: range))
                    }, pause: {
                        pauses += 1
                        XCTAssertTrue(stillStaged())
                        guard let payload = board.string(forType: .string) else { return XCTFail("Payload was restored early") }
                        view.insertText(payload, replacementRange: view.selectedRange())
                    }))
                XCTAssertEqual(view.string, "Title\n/agenda\nNext steps")
            }
            XCTAssertEqual(pauses, 1)
            XCTAssertEqual(board.string(forType: .string), "original")
        }
    }

    func testTemplateDateExpansionLeavesLinksCodeAndEscapedTokensIntact() throws {
        let title = "Agenda\n"
        let ordinary = "Due: @date. https://example.com/@today \\@today\n"
        let linkLabel = "@date"
        let code = "\nlet token = \"@today\""
        var source = note(title: "Agenda", folder: folder("r", "Templates",
                          account: Account(id: "a", name: "A", kind: "local")),
                          text: title + ordinary + linkLabel + code)
        source.document?.runs = [
            AttributeRun(length: title.utf16.count, paragraph: ParagraphStyle(kind: .title)),
            AttributeRun(length: ordinary.utf16.count),
            AttributeRun(length: linkLabel.utf16.count, link: "https://example.com/guide"),
            AttributeRun(length: code.utf16.count, paragraph: ParagraphStyle(kind: .monospaced))
        ]
        let payload = try EditorTemplateStore.payload(source, date: Date(timeIntervalSince1970: 0),
                            locale: Locale(identifier: "en_US"), timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        XCTAssertEqual(payload.text, "Due: Jan 1, 1970. https://example.com/@today \\@today\n@date\nlet token = \"@today\"")
    }

    func testTemplateDateUsesLocalCalendarDay() throws {
        let source = note(title: "Agenda", folder: folder("r", "Templates",
                          account: Account(id: "a", name: "A", kind: "local")), text: "Agenda\n@today")
        let payload = try EditorTemplateStore.payload(source, date: Date(timeIntervalSince1970: 0),
                          locale: Locale(identifier: "en_GB"), timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")))
        XCTAssertEqual(payload.text, "31 Dec 1969")
    }

    func testTemplatePasteDoesNotRestoreOverCopyMadeDuringStaging() throws {
        try MainActor.assumeIsolated {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            try ClipboardCopy.write("original", to: board)
            let racing = TemplatePasteSecondWriter(board)
            racing.afterWrite = {
                board.clearContents()
                XCTAssertTrue(board.setString("a new copy", forType: .string))
            }
            XCTAssertThrowsError(try EditorTemplatePaste.withData(Data("template".utf8), type: .string, on: racing) { _ in
                XCTFail("Paste must not be dispatched")
            })
            XCTAssertEqual(board.string(forType: .string), "a new copy")
        }
    }

    func testTemplatePasteRestoresAllItemsWhenStagingOrPastingFails() throws {
        enum PasteFailure: Error { case dispatch }
        try MainActor.assumeIsolated {
            for rejectStage in [true, false] {
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                let flavor = NSPasteboard.PasteboardType("org.notescli.test")
                let original = (1...2).map { index in
                    let item = NSPasteboardItem()
                    XCTAssertTrue(item.setString("item \(index)", forType: .string))
                    XCTAssertTrue(item.setData(Data([UInt8(index)]), forType: flavor))
                    return item
                }
                XCTAssertTrue(board.writeObjects(original))
                let wrapped = TemplatePasteSecondWriter(board)
                wrapped.rejectNextWrite = rejectStage
                var dispatched = false
                XCTAssertThrowsError(try EditorTemplatePaste.withData(Data([0]), type: .rtfd, on: wrapped) { staged in
                    dispatched = true
                    XCTAssertTrue(staged())
                    throw PasteFailure.dispatch
                }) { error in
                    if rejectStage {
                        XCTAssertEqual((error as? NotesError)?.code, "template_pasteboard_unavailable")
                    } else {
                        XCTAssertTrue(error is PasteFailure)
                    }
                }
                XCTAssertEqual(dispatched, !rejectStage)
                let restored = try XCTUnwrap(board.pasteboardItems)
                XCTAssertEqual(restored.map { $0.string(forType: .string) }, ["item 1", "item 2"])
                XCTAssertEqual(restored.map { $0.data(forType: flavor) }, [Data([1]), Data([2])])
            }
        }
    }

    func testTemplatePasteDoesNotDispatchWhenClipboardCannotBeRestored() throws {
        try MainActor.assumeIsolated {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let promisedType = NSPasteboard.PasteboardType("org.notescli.test.promised-file")
            let data = Data([1, 2, 3])
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setData(data, forType: promisedType))
            XCTAssertTrue(board.writeObjects([item]))
            let change = board.changeCount
            XCTAssertThrowsError(try EditorTemplatePaste.withMarkdown("**template**", on: board) { _ in
                XCTFail("Paste must not be dispatched")
            }) { error in
                XCTAssertEqual((error as? NotesError)?.code, "template_pasteboard_unavailable")
            }
            XCTAssertEqual(board.changeCount, change)
            XCTAssertEqual(board.data(forType: promisedType), data)
        }
    }

    func testUnreadableClipboardFlavorStopsImagePasteBeforeAnyMutation() throws {
        try MainActor.assumeIsolated {
            let board = TemplatePasteUnreadableFlavor()
            XCTAssertTrue(board.item.setString("readable text", forType: .string))
            XCTAssertTrue(board.item.setDataProvider(board, forTypes: [board.flavor]))
            XCTAssertTrue(board.item.types.contains(board.flavor))
            XCTAssertThrowsError(try EditorTemplatePaste.withData(Data([1]), type: .rtfd, on: board) { _ in
                XCTFail("Paste must not be dispatched")
            }) {
                XCTAssertEqual(($0 as? NotesError)?.code, "template_pasteboard_unavailable")
            }
            XCTAssertEqual(board.clearCount, 0)
            XCTAssertEqual(board.writeCount, 0)
            XCTAssertEqual(board.item.string(forType: .string), "readable text")
        }
    }

    private func folder(_ id: String, _ name: String, account: Account, smart: Bool = false) -> Folder {
        Folder(id: id, name: name, accountID: account.id, parentID: nil, path: [name],
               isSmartFolder: smart, isRecentlyDeleted: false, noteCount: 0)
    }

    private func note(title: String, folder: Folder, text: String, locked: Bool = false) -> Note {
        let summary = NoteSummary(id: NoteID(uuid: UUID().uuidString), title: title, snippet: "not listed",
                                  folderID: folder.id, folderPath: folder.path, accountID: folder.accountID,
                                  created: nil, modified: nil, isPinned: false, isLocked: locked, isDeleted: false,
                                  hasChecklist: false, attachmentCount: 0, tags: [])
        return Note(summary: summary, document: NoteDocument(text: text, runs: []), attachments: [])
    }
}
