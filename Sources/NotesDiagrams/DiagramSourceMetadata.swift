import Foundation

public enum DiagramSourceMetadata {
    private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    private static let keyword = "notescli.diagram.source"

    private struct Payload: Codable {
        let version: Int
        let filename: String
        let mediaType: String
        let sourceBase64: String
    }

    public static func embed(source: Data, filename: String, mediaType: String, in png: Data) throws -> Data {
        let chunks = try parse(png)
        let payload = Payload(version: 1, filename: filename, mediaType: mediaType, sourceBase64: source.base64EncodedString())
        let json = try JSONEncoder.sorted.encode(payload)
        var text = Data(keyword.utf8)
        text.append(0)
        text.append(contentsOf: [0, 0, 0, 0])
        text.append(json)
        let sourceChunk = chunk(type: "iTXt", data: text)

        var result = signature
        var inserted = false
        for item in chunks where item.type != "iTXt" || metadataKeyword(item.data) != keyword {
            if item.type == "IEND", !inserted {
                result.append(sourceChunk)
                inserted = true
            }
            result.append(item.raw)
        }
        guard inserted else { throw DiagramError.invalidPNG }
        return result
    }

    public static func extract(from png: Data) throws -> DiagramSource? {
        for item in try parse(png) where item.type == "iTXt" && metadataKeyword(item.data) == keyword {
            guard let keywordEnd = item.data.firstIndex(of: 0) else { throw DiagramError.invalidPNG }
            let payloadStart = keywordEnd + 5
            guard payloadStart <= item.data.count,
                  item.data[keywordEnd + 1] == 0,
                  item.data[keywordEnd + 2] == 0,
                  item.data[keywordEnd + 3] == 0,
                  item.data[keywordEnd + 4] == 0,
                  let payload = try? JSONDecoder().decode(Payload.self, from: item.data[payloadStart...]),
                  payload.version == 1,
                  let source = Data(base64Encoded: payload.sourceBase64) else {
                throw DiagramError.invalidPNG
            }
            return DiagramSource(data: source, filename: payload.filename, mediaType: payload.mediaType)
        }
        return nil
    }

    private struct PNGChunk {
        let type: String
        let data: Data
        let raw: Data
    }

    private static func parse(_ png: Data) throws -> [PNGChunk] {
        guard png.starts(with: signature) else { throw DiagramError.invalidPNG }
        var offset = signature.count
        var chunks: [PNGChunk] = []
        while offset + 12 <= png.count {
            let start = offset
            let length = Int(readUInt32(png, at: offset))
            offset += 4
            guard length >= 0, offset + 4 + length + 4 <= png.count else { throw DiagramError.invalidPNG }
            let typeData = png[offset..<(offset + 4)]
            guard let type = String(data: typeData, encoding: .ascii) else { throw DiagramError.invalidPNG }
            offset += 4
            let data = Data(png[offset..<(offset + length)])
            offset += length + 4
            chunks.append(PNGChunk(type: type, data: data, raw: Data(png[start..<offset])))
            if type == "IEND" {
                guard offset == png.count else { throw DiagramError.invalidPNG }
                return chunks
            }
        }
        throw DiagramError.invalidPNG
    }

    private static func metadataKeyword(_ data: Data) -> String? {
        guard let end = data.firstIndex(of: 0) else { return nil }
        return String(data: data[..<end], encoding: .isoLatin1)
    }

    private static func chunk(type: String, data: Data) -> Data {
        let typeData = Data(type.utf8)
        var result = uint32(UInt32(data.count))
        result.append(typeData)
        result.append(data)
        result.append(uint32(crc32(typeData + data)))
        return result
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        return crc ^ 0xffff_ffff
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
