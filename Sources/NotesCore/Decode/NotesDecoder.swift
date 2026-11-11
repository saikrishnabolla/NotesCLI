import Foundation

/// Field numbers follow apple_cloud_notes_parser/notestore.proto and icloud-md/topotext.proto.
public enum NotesDecoder {
    public static func decode(_ data: Data) throws -> NoteDocument {
        let root = try ProtobufMessage(NotesInflate.decompressIfNeeded(data))
        let versions = try root.messages(2)
        guard versions.count == 1 else { throw DecodeError.invalidProtobuf }
        return try decodeNote(versions[0].required(3))
    }
    static func decodeNote(_ note: ProtobufMessage) throws -> NoteDocument {
        guard let bytes = note.data(2) else { throw DecodeError.missingField }
        guard let text = String(data: bytes, encoding: .utf8) else { throw DecodeError.invalidUTF8 }
        let textLength = text.utf16.count
        var total = 0
        let runs = try note.messages(5).map { run -> AttributeRun in
            guard let rawLength = run.uint(1), rawLength <= UInt64(textLength - total) else { throw DecodeError.invalidRunLength }
            let length = Int(rawLength); total += length
            var paragraph: ParagraphStyle?
            if let p = try run.message(2) {
                let kinds: [Int: ParagraphStyle.Kind] = [0: .title, 1: .heading, 2: .subheading, 4: .monospaced, 100: .bulleted, 101: .dashed, 102: .numbered, 103: .checklist]
                let checklist = try p.message(5)
                let quote = p.int(8) ?? 0
                var style = ParagraphStyle(kind: kinds[p.int(1) ?? -1] ?? (quote > 0 ? .blockquote : .body), indent: max(0, p.int(4) ?? 0), checked: checklist.map { ($0.int(2) ?? 0) != 0 }, checklistID: checklist?.data(1).map(uuid), startNumber: p.int(7))
                style.alignment = p.int(2); style.blockQuoteLevel = quote > 0 ? quote : nil
                paragraph = style
            }
            let f = try run.message(3)
            let hints = f?.int(3) ?? run.int(5) ?? 0
            var font = FontStyle(bold: hints & 1 != 0, italic: hints & 2 != 0, underline: (run.int(6) ?? 0) != 0, strikethrough: (run.int(7) ?? 0) != 0, superscript: run.int(8) ?? 0)
            font.name = f?.string(1); font.pointSize = f?.float(2)
            if let size = font.pointSize, !size.isFinite { throw DecodeError.invalidProtobuf }
            if let name = font.name?.lowercased() {
                font.bold = font.bold || name.contains("bold")
                font.italic = font.italic || name.contains("italic") || name.contains("oblique")
            }
            var color: String?
            if let c = try run.message(10) {
                let channels = [c.float(1) ?? 0, c.float(2) ?? 0, c.float(3) ?? 0]
                guard channels.allSatisfy(\.isFinite) else { throw DecodeError.invalidProtobuf }
                color = "#" + channels.map { String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
            }
            let a = try run.message(12)
            let attachment = a.map { InlineRef(id: $0.string(1) ?? "", typeUTI: $0.string(2) ?? "public.data") }
            return AttributeRun(length: length, paragraph: paragraph, font: font, link: run.string(9), color: color, attachment: attachment)
        }
        // Some versions omit runs for the trailing unstyled text.
        return NoteDocument(text: text, runs: runs)
    }
    private static func uuid(_ data: Data) -> String {
        let hex = data.map { String(format: "%02X", $0) }.joined()
        guard data.count == 16 else { return hex }
        let chars = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-")
    }
}
