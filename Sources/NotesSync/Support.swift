import Foundation

enum StableHash {
    static func hex(_ data: Data) -> String {
        var values: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let constants: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
        ]
        var message = [UInt8](data)
        let bitCount = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        message += (0..<8).reversed().map { UInt8((bitCount >> UInt64($0 * 8)) & 0xff) }
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = Array(repeating: UInt32(0), count: 64)
            for i in 0..<16 {
                let j = chunkStart + i * 4
                words[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let x = words[i - 15], y = words[i - 2]
                let s0 = x.rotatedRight(7) ^ x.rotatedRight(18) ^ (x >> 3)
                let s1 = y.rotatedRight(17) ^ y.rotatedRight(19) ^ (y >> 10)
                words[i] = words[i - 16] &+ s0 &+ words[i - 7] &+ s1
            }
            var a = values[0], b = values[1], c = values[2], d = values[3]
            var e = values[4], f = values[5], g = values[6], h = values[7]
            for i in 0..<64 {
                let s1 = e.rotatedRight(6) ^ e.rotatedRight(11) ^ e.rotatedRight(25)
                let choice = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ choice &+ constants[i] &+ words[i]
                let s0 = a.rotatedRight(2) ^ a.rotatedRight(13) ^ a.rotatedRight(22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            values[0] &+= a; values[1] &+= b; values[2] &+= c; values[3] &+= d
            values[4] &+= e; values[5] &+= f; values[6] &+= g; values[7] &+= h
        }
        return values.map { String(format: "%08x", $0) }.joined()
    }

    static func hex(_ text: String) -> String { hex(Data(text.utf8)) }
}

private extension UInt32 {
    func rotatedRight(_ amount: UInt32) -> UInt32 { (self >> amount) | (self << (32 - amount)) }
}

enum SafePath {
    static func component(_ text: String, limit: Int = 100) -> String {
        var value = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        value = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        while value.hasPrefix(".") { value.removeFirst() }
        if value.isEmpty { value = "untitled" }
        if value.utf8.count > limit {
            let suffix = String(StableHash.hex(value).prefix(10))
            value = String(value.prefix(max(1, limit - suffix.count - 1))) + "-" + suffix
        }
        return value
    }

    static func child(_ relative: String, of root: URL) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw NotesSyncError.invalidPath(relative)
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var component = root.standardizedFileURL
        for part in relative.split(separator: "/") {
            component.appendPathComponent(String(part))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) != nil {
                throw NotesSyncError.invalidPath(relative)
            }
        }
        let url = canonicalRoot.appendingPathComponent(relative).standardizedFileURL
        let rootPath = canonicalRoot.path
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else { throw NotesSyncError.invalidPath(relative) }
        return url
    }
}

public enum NotesSyncError: Error, CustomStringConvertible, Equatable {
    case invalidPath(String)
    case invalidState(String)
    case writeUnknown(String)
    case externalTool(String)

    public var description: String {
        switch self {
        case .invalidPath(let value): return "Path leaves the selected directory: \(value)"
        case .invalidState(let value): return value
        case .writeUnknown(let value): return value
        case .externalTool(let value): return value
        }
    }
}

extension FileManager {
    func createPrivateDirectory(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
