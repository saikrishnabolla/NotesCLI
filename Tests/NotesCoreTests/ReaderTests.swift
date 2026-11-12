import XCTest
@testable import NotesCore

private enum PB {
    static func varint(_ n: UInt64) -> Data {
        var n = n, result = Data()
        repeat { var byte = UInt8(n & 127); n >>= 7; if n != 0 { byte |= 128 }; result.append(byte) } while n != 0
        return result
    }
    static func int(_ field: Int, _ n: Int) -> Data { varint(UInt64(field << 3)) + varint(UInt64(bitPattern: Int64(n))) }
    static func bytes(_ field: Int, _ data: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(data.count)) + data }
    static func text(_ field: Int, _ text: String) -> Data { bytes(field, Data(text.utf8)) }
    static func float(_ field: Int, _ value: Float) -> Data {
        var bits = value.bitPattern.littleEndian
        return varint(UInt64(field << 3 | 5)) + withUnsafeBytes(of: &bits) { Data($0) }
    }
    static func note(_ text: String, _ runs: [Data] = []) -> Data { self.text(2, text) + runs.reduce(Data()) { $0 + bytes(5, $1) } }
    static func wrap(_ payload: Data) -> Data { bytes(2, int(2, 0) + bytes(3, payload)) }
    static func storedGzip(_ data: Data) -> Data {
        var result = Data([31,139,8,0,0,0,0,0,0,255,1])
        let count = UInt16(data.count)
        result += Data([UInt8(truncatingIfNeeded: count), UInt8(count >> 8), UInt8(truncatingIfNeeded: ~count), UInt8((~count) >> 8)]) + data
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        for value in [crc ^ 0xffffffff, UInt32(data.count)] { result += Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        return result
    }
}

final class ReaderDecodeTests: XCTestCase {
    func testEveryParagraphAndInlineStyle() throws {
        let kinds: [(Int, ParagraphStyle.Kind)] = [(0,.title),(1,.heading),(2,.subheading),(4,.monospaced),(100,.bulleted),(101,.dashed),(102,.numbered),(103,.checklist),(-1,.body)]
        for (number, kind) in kinds {
            let checklist = PB.bytes(1, Data(repeating: 0xab, count: 16)) + PB.int(2, 1)
            let paragraph = PB.int(1, number) + PB.int(2, 2) + PB.int(4, 2) + PB.bytes(5, checklist) + PB.int(7, 7)
            let run = PB.int(1, 3) + PB.bytes(2, paragraph)
            let doc = try NotesDecoder.decode(PB.storedGzip(PB.wrap(PB.note("😀x", [run]))))
            XCTAssertEqual(doc.text, "😀x")
            XCTAssertEqual(doc.runs.first?.length, 3)
            XCTAssertEqual(doc.runs.first?.paragraph?.kind, kind)
            XCTAssertEqual(doc.runs.first?.paragraph?.indent, 2)
            XCTAssertEqual(doc.runs.first?.paragraph?.alignment, 2)
            XCTAssertEqual(doc.runs.first?.paragraph?.startNumber, 7)
            XCTAssertEqual(doc.runs.first?.paragraph?.checked, true)
            XCTAssertEqual(doc.runs.first?.paragraph?.checklistID, "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")
        }
        let font = PB.text(1, "TestFont") + PB.float(2, 14) + PB.int(3, 3)
        let color = PB.float(1, 1) + PB.float(2, 0.5) + PB.float(3, 0)
        let attachment = PB.text(1, "image-id") + PB.text(2, "public.jpeg")
        let run = PB.int(1, 1) + PB.bytes(3, font) + PB.int(6, 1) + PB.int(7, 1) + PB.int(8, -1) + PB.text(9, "https://example.com") + PB.bytes(10, color) + PB.bytes(12, attachment)
        let doc = try NotesDecoder.decode(PB.wrap(PB.note("\u{fffc}", [run])))
        XCTAssertTrue(doc.runs[0].font.bold)
        XCTAssertTrue(doc.runs[0].font.italic)
        XCTAssertTrue(doc.runs[0].font.underline)
        XCTAssertTrue(doc.runs[0].font.strikethrough)
        XCTAssertEqual(doc.runs[0].font.superscript, -1)
        XCTAssertEqual(doc.runs[0].font.name, "TestFont")
        XCTAssertEqual(doc.runs[0].font.pointSize, 14)
        XCTAssertEqual(doc.runs[0].color, "#FF8000")
        XCTAssertEqual(doc.runs[0].link, "https://example.com")
        XCTAssertEqual(doc.runs[0].attachment?.id, "image-id")
        for done in [0, 1] {
            let p = PB.int(1, 103) + PB.bytes(5, PB.int(2, done))
            let d = try NotesDecoder.decode(PB.wrap(PB.note("x", [PB.int(1, 1) + PB.bytes(2, p)])))
            XCTAssertEqual(d.runs[0].paragraph?.checked, done == 1)
        }
        let quote = try NotesDecoder.decode(PB.wrap(PB.note("x", [PB.int(1, 1) + PB.bytes(2, PB.int(8, 2))])))
        XCTAssertEqual(quote.runs[0].paragraph?.kind, .blockquote)
        XCTAssertEqual(quote.runs[0].paragraph?.blockQuoteLevel, 2)
        let hints = try NotesDecoder.decode(PB.wrap(PB.note("x", [PB.int(1, 1) + PB.int(5, 3)])))
        XCTAssertTrue(hints.runs[0].font.bold && hints.runs[0].font.italic)
    }
    func testHighlightParagraphIdentityAndWritingDirection() throws {
        let paragraphID = Data([0x11,0x11,0x11,0x11,0x22,0x22,0x33,0x33,0x44,0x44,0x55,0x55,0x55,0x55,0x55,0x55])
        let paragraph = PB.int(1, 1) + PB.int(3, 2) + PB.bytes(9, paragraphID)
        let run = PB.int(1, 4) + PB.bytes(2, paragraph) + PB.int(14, 4)
        let document = try NotesDecoder.decode(PB.wrap(PB.note("mint", [run])))

        XCTAssertEqual(document.runs[0].highlight, .mint)
        XCTAssertEqual(document.runs[0].paragraph?.writingDirection, 1)
        XCTAssertEqual(document.runs[0].paragraph?.id, "11111111-2222-3333-4444-555555555555")
    }
    func testOutlineStateDecodingUsesLiteralArchiveValues() throws {
        let bytes = Data(hex: "09ce70675b9952c84112513a4f5b2241414141414141412d424242422d434343432d444444442d454545454545454545454545222c2231313131313131312d323232322d333333332d343434342d353535353535353535353535225d")
        XCTAssertEqual(try NotesOutlineDecoder.decode(bytes), [
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "11111111-2222-3333-4444-555555555555"
        ])
    }
    func testWireUnknownFieldsAndMalformedInput() throws {
        let message = try ProtobufMessage(PB.int(99, 42) + PB.text(100, "unknown") + PB.float(101, 1))
        XCTAssertEqual(message.int(99), 42)
        XCTAssertThrowsError(try ProtobufMessage(Data([0])))
        XCTAssertThrowsError(try ProtobufMessage(Data([10, 10, 1])))
        XCTAssertThrowsError(try ProtobufMessage(Data(repeating: 255, count: 11)))
        XCTAssertThrowsError(try NotesDecoder.decode(PB.wrap(PB.note("x", [PB.int(1, 2)]))))
        XCTAssertThrowsError(try NotesDecoder.decode(PB.wrap(PB.bytes(2, Data([255])))))
        XCTAssertThrowsError(try NotesDecoder.decode(PB.bytes(2, Data())))
    }
    func testCompressionVariantsAndChecksums() throws {
        let text = String(repeating: "Synthetic Notes body: αβγ 😀 tables and lists.\n", count: 300)
        let gzip = Data(base64Encoded: "H4sIAAAAAAAA/+3LsQ2CUBQAwJ4p3gQM4BA2TABCIgmB4r+GjjHonEHd48/iCDqE5dWX6/Y171POt7huOZUYtnG/RH3WV33H53Eekf2w/KBfx1jmkqVtOsdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxHMdxnD+cL61LU4PwPAAA")!
        let zlib = Data(base64Encoded: "eJzty7ENglAUAMCeKd4EDOAQNkwAQiIJgeK/ho4x6JxB3ePP4gg6hOXVl+v2Ne9Tzre4bjmVGLZxv0R91ld9x+dxHpH9sPygX8dY5pKlbTrHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcRzHcZw/nC8ReIfY")!
        XCTAssertEqual(try NotesInflate.decompress(gzip), Data(text.utf8))
        XCTAssertEqual(try NotesInflate.decompress(zlib), Data(text.utf8))
        XCTAssertEqual(try NotesInflate.decompress(Data(base64Encoded: "eAFLy6xITVFIy6woKS1KBdG4eABL1g/m")!), Data("fixed fixture fixed fixture fixed fixture".utf8))
        XCTAssertEqual(try NotesInflate.decompress(PB.storedGzip(Data("stored".utf8))), Data("stored".utf8))
        var corrupt = gzip; corrupt[corrupt.count - 8] ^= 1
        XCTAssertThrowsError(try NotesInflate.decompress(corrupt))
        XCTAssertThrowsError(try NotesInflate.decompress(gzip, maximumSize: 10))
        XCTAssertThrowsError(try NotesInflate.decompress(gzip.dropLast()))
        XCTAssertThrowsError(try NotesInflate.decompress(Data([0x78, 0x20, 0, 0, 0, 0])))
    }
    func testCRDTTableOrderingRedirectsAndRTL() throws {
        func ref(_ n: Int) -> Data { PB.int(6, n) }
        func entry(_ key: Data, _ value: Data) -> Data { PB.bytes(1, key) + PB.bytes(2, value) }
        func map(_ key: Int, _ value: Data) -> Data { PB.int(1, key) + PB.bytes(2, value) }
        func identity(_ n: Int) -> Data { PB.bytes(13, PB.int(1, 1) + PB.bytes(3, map(3, PB.int(2, n)))) }
        let uuids = (0..<5).map { Data(repeating: UInt8($0), count: 16) }
        func order(_ indices: [Int], redirects: Data = Data()) -> Data {
            let array = PB.bytes(1, PB.note(String(repeating: "\u{fffc}", count: indices.count))) + indices.enumerated().reduce(Data()) { $0 + PB.bytes(2, PB.int(1, $1.offset) + PB.bytes(2, uuids[$1.element])) }
            return PB.bytes(16, PB.bytes(1, PB.bytes(1, array) + PB.bytes(2, redirects)))
        }
        // Pool: root, row/column orders, cell columns, row/column identities, cell dictionaries, cells, redirect identity.
        let root = PB.bytes(13, PB.int(1, 0) + PB.bytes(3, map(0, ref(1))) + PB.bytes(3, map(1, ref(2))) + PB.bytes(3, map(2, ref(3))))
        let rows = order([1,0], redirects: PB.bytes(1, entry(ref(4), ref(14))))
        let columns = order([2,3])
        let cells = PB.bytes(6, PB.bytes(1, entry(ref(6), ref(8))) + PB.bytes(1, entry(ref(7), ref(9))))
        let columnA = PB.bytes(6, PB.bytes(1, entry(ref(14), ref(10))) + PB.bytes(1, entry(ref(5), ref(11))))
        let columnB = PB.bytes(6, PB.bytes(1, entry(ref(4), ref(12))) + PB.bytes(1, entry(ref(5), ref(13))))
        let objects = [root,rows,columns,cells,identity(0),identity(1),identity(2),identity(3),columnA,columnB,PB.bytes(10,PB.note("A")),PB.bytes(10,PB.note("B")),PB.bytes(10,PB.note("C")),PB.bytes(10,PB.note("D")),identity(4)]
        let header = ["crRows","crColumns","cellColumns","self"].reduce(Data()) { $0 + PB.text(4,$1) } + PB.text(5,"com.apple.notes.ICTable") + PB.text(5,"uuid") + uuids.reduce(Data()) { $0 + PB.bytes(6,$1) }
        let pool = objects.reduce(Data()) { $0 + PB.bytes(3,$1) }
        XCTAssertEqual(try NotesTableDecoder.decode(PB.storedGzip(PB.wrap(pool + header))), [["B","D"],["A","C"]])
        let rtl = PB.bytes(3, PB.bytes(1, PB.bytes(2, PB.text(4,"CRTableColumnDirectionRightToLeft"))))
        XCTAssertEqual(try NotesTableDecoder.decode(PB.wrap(pool + rtl + header)), [["D","B"],["C","A"]])
        var inlineObjects = objects
        let inline = PB.bytes(12,PB.text(1,"tag") + PB.text(2,"com.apple.notes.inlinetextattachment.hashtag"))
        inlineObjects[10] = PB.bytes(10,PB.note("\u{fffc}",[PB.int(1,1) + inline]))
        let inlinePool = inlineObjects.reduce(Data()) { $0 + PB.bytes(3,$1) }
        XCTAssertEqual(try NotesTableDecoder.decode(PB.wrap(inlinePool + header),inlineText:{ _ in "work" }),[["B","D"],["#work","C"]])
        XCTAssertThrowsError(try NotesTableDecoder.decode(PB.wrap(header)))
    }
}

final class ReaderRendererTests: XCTestCase {
    func testParagraphGolden() {
        let paragraphs: [(String, ParagraphStyle)] = [
            ("Title", .init(kind:.title)),("Heading",.init(kind:.heading)),("Subheading",.init(kind:.subheading)),
            ("Body",.init(kind:.body)),("Bullet",.init(kind:.bulleted)),("Nested",.init(kind:.dashed,indent:1)),
            ("Seven",.init(kind:.numbered,startNumber:7)),("Eight",.init(kind:.numbered)),
            ("Todo",.init(kind:.checklist,checked:false)),("Done",.init(kind:.checklist,checked:true)),
            ("Quote",.init(kind:.blockquote)),("let x = 1",.init(kind:.monospaced)),("print(x)",.init(kind:.monospaced))]
        let document = NoteDocument(text: paragraphs.map(\.0).joined(separator:"\n") + "\n", runs: paragraphs.map { AttributeRun(length:$0.0.utf16.count+1,paragraph:$0.1) })
        XCTAssertEqual(document.markdown(), "# Title\n## Heading\n### Subheading\nBody\n- Bullet\n    - Nested\n7. Seven\n8. Eight\n- [ ] Todo\n- [x] Done\n> Quote\n```\nlet x = 1\nprint(x)\n```\n")
        XCTAssertEqual(document.plainText(), document.text)
        XCTAssertEqual(document.html(), "<h1>Title</h1>\n<h2>Heading</h2>\n<h3>Subheading</h3>\n<p>Body</p>\n<ul><li>Bullet<ul><li>Nested</li></ul></li></ul>\n<ol start=\"7\"><li value=\"7\">Seven</li><li>Eight</li></ol>\n<ul><li><input type=\"checkbox\" disabled> Todo</li><li><input type=\"checkbox\" disabled checked> Done</li></ul>\n<blockquote><p>Quote</p></blockquote>\n<pre><code>let x = 1\nprint(x)</code></pre>")
    }
    func testInlineGoldenAndUTF16() {
        let document = NoteDocument(text:"😀 bold link",runs:[.init(length:3),.init(length:4,font:.init(bold:true,italic:true,underline:true,strikethrough:true)),.init(length:1),.init(length:4,link:"https://example.com/a(b)")])
        XCTAssertEqual(document.markdown(),"😀 <u>~~***bold***~~</u> [link](https://example.com/a%28b%29)")
        XCTAssertEqual(document.plainText(),"😀 bold link")
        XCTAssertEqual(document.html(),"<p>😀 <u><del><em><strong>bold</strong></em></del></u> <a href=\"https://example.com/a(b)\">link</a></p>")
        let unsafe = NoteDocument(text:"<script>&",runs:[.init(length:9,link:"javascript:alert(1)")])
        XCTAssertEqual(unsafe.html(),"<p><a href=\"\">&lt;script&gt;&amp;</a></p>")
    }
    func testHighlightRenderingPreservesPaletteColor() {
        let document = NoteDocument(text: "mint", runs: [.init(length: 4, highlight: .mint)])
        XCTAssertEqual(document.markdown(), "<mark data-apple-notes-highlight=\"mint\">mint</mark>")
        XCTAssertEqual(document.html(), "<p><mark data-apple-notes-highlight=\"mint\" style=\"background-color:#289C8ECC\">mint</mark></p>")
    }
    func testLiteralMarkdownAndUnsafeLinkNormalization() {
        let body = NoteDocument(text:"# Literal heading\n- Literal list\n1. Literal number\n#tag",runs:[])
        XCTAssertEqual(body.markdown(),"\\# Literal heading\n\\- Literal list\n1\\. Literal number\n#tag")
        let link = NoteDocument(text:"unsafe",runs:[.init(length:6,link:"java\nscript:alert(1)")])
        XCTAssertEqual(link.html(),"<p><a href=\"\">unsafe</a></p>")
    }
    func testInlineWhitespaceAndCodeFence() {
        let styled = NoteDocument(text:" leading and trailing ",runs:[.init(length:22,font:.init(bold:true))])
        XCTAssertEqual(styled.markdown()," **leading and trailing** ")
        let code = NoteDocument(text:"let x = ```",runs:[.init(length:11,paragraph:.init(kind:.monospaced))])
        XCTAssertEqual(code.markdown(),"````\nlet x = ```\n````")
    }
    func testAttachmentsTagsNoteLinksAndTableGolden() {
        var tag = InlineRef(id:"tag",typeUTI:"com.apple.notes.inlinetextattachment.hashtag"); tag.displayText = "work"
        var mention = InlineRef(id:"person",typeUTI:"com.apple.notes.inlinetextattachment.mention"); mention.displayText = "Pat"
        var link = InlineRef(id:"link",typeUTI:"com.apple.notes.inlinetextattachment.link"); link.displayText = "Other note"; link.url = "applenotes://showNote?identifier=ABC"
        let refs = [InlineRef(id:"photo",typeUTI:"public.jpeg"),InlineRef(id:"file",typeUTI:"public.data"),tag,mention,link,InlineRef(id:"table",typeUTI:"com.apple.notes.table")]
        var doc = NoteDocument(text:String(repeating:"\u{fffc}\n",count:refs.count),runs:refs.map { .init(length:2,attachment:$0) })
        doc.tables = ["table":[["Name","Value"],["A|B","C\nD"]]]
        let attachments = [Attachment(id:"photo",typeUTI:"public.jpeg",filename:"image.png",filePath:"/private/image.png")]
        XCTAssertEqual(doc.markdown(attachments:attachments),"![image.png](/private/image.png)\n[attachment: public.data](notescli-attachment:file)\n[#work](notescli-attachment:tag)\n[@Pat](notescli-attachment:person)\n[Other note](applenotes://showNote?identifier=ABC)\n| Name | Value |\n| --- | --- |\n| A\\|B | C<br>D |\n")
        XCTAssertEqual(doc.plainText(attachments:attachments),"image.png\nattachment: public.data\n#work\n@Pat\nOther note\nName\tValue\nA|B\tC\nD\n")
        XCTAssertTrue(doc.html().contains("<table><tr><td>Name</td><td>Value</td></tr><tr><td>A|B</td><td>C<br>D</td></tr></table>"))
    }
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
