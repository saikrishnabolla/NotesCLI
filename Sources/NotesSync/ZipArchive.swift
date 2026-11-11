import Foundation

struct ZipEntry {
    var path: String
    var data: Data
}

enum ZipArchive {
    static func write(_ entries: [ZipEntry], to url: URL) throws {
        var archive = Data()
        var central = Data()
        var offsets: [UInt32] = []

        for entry in entries {
            guard let name = entry.path.data(using: .utf8), name.count <= Int(UInt16.max),
                  entry.data.count <= Int(UInt32.max), archive.count <= Int(UInt32.max) else {
                throw NotesSyncError.invalidState("ZIP entry is too large: \(entry.path)")
            }
            offsets.append(UInt32(archive.count))
            let crc = CRC32.checksum(entry.data)
            archive.appendLE(UInt32(0x04034b50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
            archive.appendLE(crc)
            archive.appendLE(UInt32(entry.data.count)); archive.appendLE(UInt32(entry.data.count))
            archive.appendLE(UInt16(name.count)); archive.appendLE(UInt16(0))
            archive.append(name); archive.append(entry.data)
        }

        for (index, entry) in entries.enumerated() {
            let name = Data(entry.path.utf8), crc = CRC32.checksum(entry.data)
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(crc)
            central.appendLE(UInt32(entry.data.count)); central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(name.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0))
            central.appendLE(offsets[index]); central.append(name)
        }

        guard entries.count <= Int(UInt16.max), archive.count <= Int(UInt32.max), central.count <= Int(UInt32.max) else {
            throw NotesSyncError.invalidState("ZIP archive is too large.")
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.appendLE(UInt32(0x06054b50))
        archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count)); archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(central.count)); archive.appendLE(centralOffset); archive.appendLE(UInt16(0))
        try archive.write(to: url, options: .atomic)
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
