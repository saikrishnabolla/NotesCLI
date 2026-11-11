import Foundation

/// RFC 1951 inflater with RFC 1950/1952 wrappers. No platform frameworks or subprocesses.
public enum NotesInflate {
    public static func decompress(_ data: Data, maximumSize: Int = 128 * 1024 * 1024) throws -> Data {
        let bytes = Array(data)
        guard bytes.count >= 2, maximumSize >= 0 else { throw DecodeError.truncated }
        if bytes[0] == 0x1f && bytes[1] == 0x8b {
            guard bytes.count >= 18, bytes[2] == 8, bytes[3] & 0xe0 == 0 else { throw DecodeError.invalidCompression }
            var start = 10
            let flags = bytes[3]
            if flags & 4 != 0 {
                guard start + 2 <= bytes.count else { throw DecodeError.truncated }
                let length = Int(bytes[start]) | Int(bytes[start + 1]) << 8
                start += 2 + length
            }
            for flag: UInt8 in [8, 16] where flags & flag != 0 {
                while start < bytes.count && bytes[start] != 0 { start += 1 }
                guard start < bytes.count else { throw DecodeError.truncated }; start += 1
            }
            if flags & 2 != 0 {
                guard start + 2 <= bytes.count else { throw DecodeError.truncated }
                let expected = UInt32(bytes[start]) | UInt32(bytes[start + 1]) << 8
                guard crc32(Array(bytes[..<start])) & 0xffff == expected else { throw DecodeError.checksumMismatch }
                start += 2
            }
            guard start <= bytes.count - 8 else { throw DecodeError.truncated }
            let (output, consumed) = try inflate(Array(bytes[start..<(bytes.count - 8)]), maximumSize)
            guard start + consumed + 8 == bytes.count else { throw DecodeError.invalidCompression }
            func little(_ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[i + $1]) << ($1 * 8) } }
            guard crc32(output) == little(bytes.count - 8), UInt32(truncatingIfNeeded: output.count) == little(bytes.count - 4) else { throw DecodeError.checksumMismatch }
            return Data(output)
        }
        guard bytes[0] & 15 == 8, bytes[0] >> 4 <= 7,
              (Int(bytes[0]) * 256 + Int(bytes[1])) % 31 == 0,
              bytes[1] & 32 == 0, bytes.count >= 6 else { throw DecodeError.invalidCompression }
        let (output, consumed) = try inflate(Array(bytes[2..<(bytes.count - 4)]), maximumSize)
        guard consumed + 6 == bytes.count else { throw DecodeError.invalidCompression }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in output { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let checksum = bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard b << 16 | a == checksum else { throw DecodeError.checksumMismatch }
        return Data(output)
    }
    public static func decompressIfNeeded(_ data: Data) throws -> Data {
        let b = Array(data.prefix(2))
        if b.count == 2 && ((b[0] == 31 && b[1] == 139) || (b[0] & 15 == 8 && (Int(b[0]) * 256 + Int(b[1])) % 31 == 0)) {
            return try decompress(data)
        }
        return data
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var c = UInt32(value)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1 }; return c
    }
    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xffffffff
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 255)] ^ (c >> 8) }; return c ^ 0xffffffff
    }
    private struct Bits {
        let bytes: [UInt8]
        var position = 0
        mutating func read(_ count: Int) throws -> Int {
            guard count <= bytes.count * 8 - position else { throw DecodeError.truncated }
            var result = 0
            for i in 0..<count { result |= Int((bytes[position / 8] >> (position % 8)) & 1) << i; position += 1 }
            return result
        }
    }
    private struct Huffman {
        let symbols: [Int: Int]
        let maxLength: Int
        init(_ lengths: [Int]) throws {
            guard lengths.allSatisfy({ (0...15).contains($0) }) else { throw DecodeError.invalidCompression }
            let maxLength = lengths.max() ?? 0
            var counts = [Int](repeating: 0, count: 16)
            for length in lengths where length > 0 { counts[length] += 1 }
            var left = 1
            for length in 1...15 { left = left * 2 - counts[length]; if left < 0 { throw DecodeError.invalidCompression } }
            var next = [Int](repeating: 0, count: 16), code = 0
            for length in 1...15 { code = (code + counts[length - 1]) << 1; next[length] = code }
            var symbols: [Int: Int] = [:]
            for (symbol, length) in lengths.enumerated() where length > 0 {
                symbols[(1 << length) | next[length]] = symbol; next[length] += 1
            }
            self.symbols = symbols; self.maxLength = maxLength
        }
        func decode(_ bits: inout Bits) throws -> Int {
            guard maxLength > 0 else { throw DecodeError.invalidCompression }
            var code = 0
            for length in 1...maxLength {
                code = code << 1 | (try bits.read(1))
                if let symbol = symbols[(1 << length) | code] { return symbol }
            }
            throw DecodeError.invalidCompression
        }
    }
    private static func inflate(_ bytes: [UInt8], _ limit: Int) throws -> ([UInt8], Int) {
        var bits = Bits(bytes: bytes), output: [UInt8] = [], final = false
        let lengthBase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
        let lengthExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
        let distanceBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
        let distanceExtra = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]
        while !final {
            final = try bits.read(1) == 1
            let type = try bits.read(2)
            if type == 0 {
                bits.position = (bits.position + 7) / 8 * 8
                let length = try bits.read(16), inverse = try bits.read(16)
                guard length ^ inverse == 65535 else { throw DecodeError.invalidCompression }
                guard length <= limit - output.count else { throw DecodeError.sizeLimit }
                for _ in 0..<length { output.append(UInt8(try bits.read(8))) }; continue
            }
            let literal: Huffman, distance: Huffman
            if type == 1 {
                literal = try Huffman((0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })
                distance = try Huffman([Int](repeating: 5, count: 32))
            } else if type == 2 {
                let nl = try bits.read(5) + 257, nd = try bits.read(5) + 1, nc = try bits.read(4) + 4
                guard nl <= 286 else { throw DecodeError.invalidCompression }
                let order = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]
                var codes = [Int](repeating: 0, count: 19)
                for i in 0..<nc { codes[order[i]] = try bits.read(3) }
                let tree = try Huffman(codes)
                var lengths: [Int] = []
                while lengths.count < nl + nd {
                    let symbol = try tree.decode(&bits)
                    if symbol < 16 { lengths.append(symbol) }
                    else {
                        let count: Int, value: Int
                        switch symbol {
                        case 16:
                            guard let last = lengths.last else { throw DecodeError.invalidCompression }
                            count = try bits.read(2) + 3; value = last
                        case 17: count = try bits.read(3) + 3; value = 0
                        case 18: count = try bits.read(7) + 11; value = 0
                        default: throw DecodeError.invalidCompression
                        }
                        guard count <= nl + nd - lengths.count else { throw DecodeError.invalidCompression }
                        lengths += [Int](repeating: value, count: count)
                    }
                }
                guard lengths[256] > 0 else { throw DecodeError.invalidCompression }
                literal = try Huffman(Array(lengths[..<nl])); distance = try Huffman(Array(lengths[nl...]))
            } else { throw DecodeError.invalidCompression }
            while true {
                let symbol = try literal.decode(&bits)
                if symbol == 256 { break }
                if symbol < 256 {
                    guard output.count < limit else { throw DecodeError.sizeLimit }; output.append(UInt8(symbol)); continue
                }
                guard symbol <= 285 else { throw DecodeError.invalidCompression }
                let index = symbol - 257, length = try lengthBase[index] + bits.read(lengthExtra[index])
                let d = try distance.decode(&bits)
                guard d < 30 else { throw DecodeError.invalidCompression }
                let offset = try distanceBase[d] + bits.read(distanceExtra[d])
                guard offset <= output.count else { throw DecodeError.invalidCompression }
                guard length <= limit - output.count else { throw DecodeError.sizeLimit }
                for _ in 0..<length { output.append(output[output.count - offset]) }
            }
        }
        return (output, (bits.position + 7) / 8)
    }
}
