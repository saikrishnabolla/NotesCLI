import AppKit
import ImageIO
import NotesCore
import UniformTypeIdentifiers

package struct EditorTemplateRichText: Codable, Equatable, Sendable {
    package struct Image: Codable, Equatable, Sendable {
        package let marker: String
        package let filename: String
        package let bytes: Data
    }

    struct FontSize: Codable, Equatable, Sendable {
        let range: NSRange
        let points: Float
    }

    struct RunStyle: Codable, Equatable, Sendable {
        let range: NSRange
        let fontName: String?
        let color: String?
        let highlight: HighlightColor?
        let alignment: Int?
        let direction: Int?
        let underline: Bool
        let superscript: Int

        static func needsRichPaste(_ run: AttributeRun) -> Bool {
            customFontName(run) != nil || run.font.pointSize != nil || run.font.underline || run.font.superscript != 0
                || run.color != nil || run.highlight != nil || run.paragraph?.alignment != nil
                || run.paragraph?.writingDirection == 1
        }

        private static func customFontName(_ run: AttributeRun) -> String? {
            guard let name = run.font.name, !name.hasPrefix(".AppleSystemUIFont") else { return nil }
            return name
        }

        init(range: NSRange, run: AttributeRun) {
            self.range = range
            fontName = Self.customFontName(run)
            color = run.color
            highlight = run.highlight
            alignment = run.paragraph?.alignment
            direction = run.paragraph?.writingDirection
            underline = run.font.underline
            superscript = run.font.superscript
        }
    }

    struct Whitespace: Codable, Equatable, Sendable {
        let space: String
        let tab: String
        let blankLine: String

        init?(_ text: String) {
            let used = Set(text.unicodeScalars)
            let markers = Array((0xE000...0xF8FF).lazy.compactMap(Unicode.Scalar.init)
                .filter { !used.contains($0) }.prefix(3).map(String.init))
            guard markers.count == 3 else { return nil }
            (space, tab, blankLine) = (markers[0], markers[1], markers[2])
        }

        func protect(_ document: NoteDocument) -> NoteDocument {
            // The HTML importer collapses spaces and omits empty blocks. Protect
            // them until the attributed string has recovered its UTF-16 offsets.
            let source = document.text as NSString
            var text = ""
            var runs: [AttributeRun] = []
            var offset = 0
            var atLineStart = true
            for var run in document.runs {
                let piece = source.substring(with: NSRange(location: offset, length: run.length))
                offset += run.length
                var encoded = ""
                for scalar in piece.unicodeScalars {
                    switch scalar {
                    case " ": encoded += space
                    case "\t": encoded += tab
                    case "\n":
                        if atLineStart { encoded += blankLine }
                        encoded += "\n"
                    default: encoded.unicodeScalars.append(scalar)
                    }
                    atLineStart = scalar == "\n"
                }
                run.length = encoded.utf16.count
                text += encoded
                runs.append(run)
            }
            return NoteDocument(text: text, runs: runs)
        }

        func restore(_ result: NSMutableAttributedString) {
            for (marker, value) in [(space, " "), (tab, "\t"), (blankLine, "")] {
                result.mutableString.replaceOccurrences(of: marker, with: value, options: .literal,
                    range: NSRange(location: 0, length: result.length))
            }
        }
    }

    let html: String
    package let images: [Image]
    let endsWithNewline: Bool
    let fontSizes: [FontSize]
    let styles: [RunStyle]?
    let whitespace: Whitespace?

    private static var unsupported: NotesError {
        NotesError("template_attachments_unsupported", "Only downloaded, unmarked image attachments can be pasted in templates.")
    }

    static func make(_ document: NoteDocument, attachments: [Attachment]) throws -> Self {
        var byID: [String: Attachment] = [:]
        for attachment in attachments {
            guard byID.updateValue(attachment, forKey: attachment.id) == nil else { throw unsupported }
        }
        var images: [Image] = []
        var used = Set<String>()
        var text = ""
        var runs: [AttributeRun] = []
        var cursor = 0
        let original = document.text as NSString
        var remainingBytes = 12 * 1024 * 1024
        for originalRun in document.runs {
            var run = originalRun
            guard run.length >= 0, run.length <= original.length - cursor else { throw unsupported }
            var part = original.substring(with: NSRange(location: cursor, length: run.length))
            cursor += run.length
            if let ref = run.attachment {
                let chunks = part.components(separatedBy: "\u{fffc}")
                guard chunks.count == 2, images.count < 32, let attachment = byID[ref.id],
                      let type = UTType(attachment.typeUTI), type.conforms(to: .image),
                      attachment.hasEmbeddedMarkup != true, (attachment.markupDataBytes ?? 0) == 0,
                      (attachment.childAttachments ?? []).isEmpty, (attachment.childAttachmentIDs ?? []).isEmpty,
                      let path = attachment.filePath, remainingBytes > 0 else { throw unsupported }
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? file.close() }
                guard let bytes = try file.read(upToCount: remainingBytes + 1), !bytes.isEmpty, bytes.count <= remainingBytes,
                      let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      CGImageSourceGetCount(source) > 0, let actualUTI = CGImageSourceGetType(source),
                      let actual = UTType(actualUTI as String), actual.conforms(to: .image),
                      let suffix = actual.preferredFilenameExtension else { throw unsupported }
                remainingBytes -= bytes.count
                let marker = "NotesCLIImage" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let stem = (attachment.filename as NSString?)?.lastPathComponent
                let safeName = stem.flatMap { name -> String? in
                    guard !name.isEmpty, name.utf8.count <= 200,
                          let namedType = UTType(filenameExtension: (name as NSString).pathExtension),
                          namedType == actual else { return nil }
                    return name
                } ?? "Image.\(suffix)"
                part = chunks[0] + marker + chunks[1]
                run.attachment = nil
                run.length = part.utf16.count
                images.append(Image(marker: marker, filename: safeName, bytes: bytes))
                used.insert(ref.id)
            } else if part.contains("\u{fffc}") {
                throw unsupported
            }
            text += part
            runs.append(run)
        }
        guard !images.isEmpty, cursor == original.length, used == Set(byID.keys) else { throw unsupported }
        let marked = NoteDocument(text: text, runs: runs)
        let whitespace = Whitespace(text)
        let html = NoteRenderer.html(whitespace?.protect(marked) ?? marked)
        return Self(html: html, images: images, endsWithNewline: document.text.hasSuffix("\n"),
                    fontSizes: sizes(in: document), styles: styles(in: document), whitespace: whitespace)
    }

    static func styledText(_ document: NoteDocument) -> Self {
        let whitespace = Whitespace(document.text)
        return Self(html: NoteRenderer.html(whitespace?.protect(document) ?? document),
                    images: [], endsWithNewline: document.text.hasSuffix("\n"),
                    fontSizes: sizes(in: document), styles: styles(in: document), whitespace: whitespace)
    }

    private static func styles(in document: NoteDocument) -> [RunStyle] {
        var offset = 0
        return document.runs.compactMap { run in
            defer { offset += run.length }
            guard run.length > 0, RunStyle.needsRichPaste(run) else { return nil }
            return RunStyle(range: NSRange(location: offset, length: run.length), run: run)
        }
    }

    private static func sizes(in document: NoteDocument) -> [FontSize] {
        var offset = 0
        return document.runs.compactMap { run in
            defer { offset += run.length }
            guard run.length > 0, let points = run.font.pointSize else { return nil }
            return FontSize(range: NSRange(location: offset, length: run.length), points: points)
        }
    }

    @MainActor
    package func rtfd(expectedText: String) throws -> Data {
        let markup = Data(("<meta charset=\"utf-8\">" + html).utf8)
        let result = try NSMutableAttributedString(data: markup, options: [.documentType: NSAttributedString.DocumentType.html],
                                                   documentAttributes: nil)
        for image in images {
            let range = (result.string as NSString).range(of: image.marker)
            guard range.location != NSNotFound else { throw Self.unsupported }
            let file = FileWrapper(regularFileWithContents: image.bytes)
            file.preferredFilename = image.filename
            result.replaceCharacters(in: range, with: NSAttributedString(attachment: NSTextAttachment(fileWrapper: file)))
        }
        whitespace?.restore(result)
        // The HTML importer terminates the final block even if the template did not.
        if !endsWithNewline, result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        guard result.string == expectedText else {
            throw NotesError("template_rich_text_changed", "Could not preserve the template text and image positions.")
        }
        for style in styles ?? [] {
            try Self.apply(style, to: result)
        }
        // Apply Notes-only font sizes after HTML conversion and image placement,
        // when the attributed string again uses the original UTF-16 offsets.
        for size in fontSizes {
            guard size.range.location >= 0, size.range.location <= result.length,
                  size.range.length > 0, size.range.length <= result.length - size.range.location,
                  size.points.isFinite, size.points > 0 else {
                throw NotesError("template_font_size_invalid", "Could not preserve the template’s font size.")
            }
            result.enumerateAttribute(.font, in: size.range) { value, range, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                result.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: CGFloat(size.points)), range: range)
            }
        }
        return try result.data(from: NSRange(location: 0, length: result.length),
                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    @MainActor
    private static func apply(_ style: RunStyle, to result: NSMutableAttributedString) throws {
        let range = style.range
        guard range.location >= 0, range.location <= result.length, range.length > 0,
              range.length <= result.length - range.location else {
            throw NotesError("template_rich_text_changed", "Could not preserve the template’s formatting ranges.")
        }
        if let name = style.fontName {
            guard let named = NSFont(name: name, size: NSFont.systemFontSize) else {
                throw NotesError("template_font_unavailable", "A font in this template is not installed.")
            }
            let manager = NSFontManager.shared
            result.enumerateAttribute(.font, in: range) { value, span, _ in
                let existing = value as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let traits = manager.traits(of: existing).intersection([.boldFontMask, .italicFontMask])
                let sized = manager.convert(named, toSize: existing.pointSize)
                result.addAttribute(.font, value: manager.convert(sized, toHaveTrait: traits), range: span)
            }
        }
        if let value = style.color, value.utf8.count == 7, value.hasPrefix("#"),
           let rgb = UInt32(value.dropFirst(), radix: 16) {
            result.addAttribute(.foregroundColor, value: rgbColor(rgb), range: range)
        }
        if let color = style.highlight {
            let colors: [HighlightColor: UInt32] = [
                .purple: 0xBA55D3, .pink: 0xD50000, .orange: 0xFF6F00, .mint: 0x289C8E, .blue: 0x2196F3
            ]
            let alpha: [HighlightColor: CGFloat] = [.purple: 0.2, .pink: 0.267, .orange: 0.133, .mint: 0.8, .blue: 1]
            if let rgb = colors[color], let a = alpha[color] {
                result.addAttribute(.backgroundColor, value: rgbColor(rgb, alpha: a), range: range)
            }
        }
        if style.underline {
            result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        if style.superscript != 0 {
            result.addAttribute(.superscript, value: style.superscript, range: range)
        }
        if style.alignment != nil || style.direction != nil {
            let paragraph = (result.string as NSString).paragraphRange(for: range)
            result.enumerateAttribute(.paragraphStyle, in: paragraph) { value, span, _ in
                let updated = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                if let alignment = style.alignment, let mode = [0: NSTextAlignment.left, 1: .center, 2: .right, 3: .justified][alignment] {
                    updated.alignment = mode
                }
                if let direction = style.direction, let mode = NSWritingDirection(rawValue: direction) {
                    updated.baseWritingDirection = mode
                }
                result.addAttribute(.paragraphStyle, value: updated, range: span)
            }
        }
    }

    private static func rgbColor(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }
}
