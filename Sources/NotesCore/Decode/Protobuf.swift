import Foundation

/// A bounded wire reader. Unknown fields are retained, including fixed-width values.
public struct ProtobufMessage: Sendable {
    public enum Value: Sendable, Equatable {
        case varint(UInt64), fixed64(UInt64), bytes(Data), fixed32(UInt32)
    }
    public let fields: [Int: [Value]]
    public init(_ data: Data) throws {
        let bytes = Array(data)
        var offset = 0
        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw DecodeError.truncated }
                let byte = bytes[offset]; offset += 1
                if shift == 63 && byte > 1 { throw DecodeError.invalidProtobuf }
                result |= UInt64(byte & 127) << shift
                if byte < 128 { return result }
            }
            throw DecodeError.invalidProtobuf
        }
        func readFixed(_ count: Int) throws -> UInt64 {
            guard count <= bytes.count - offset else { throw DecodeError.truncated }
            var result: UInt64 = 0
            for i in 0..<count { result |= UInt64(bytes[offset + i]) << (i * 8) }
            offset += count
            return result
        }
        var fields: [Int: [Value]] = [:]
        while offset < bytes.count {
            let key = try readVarint()
            guard key >> 3 > 0, key >> 3 <= 0x1fffffff else { throw DecodeError.invalidProtobuf }
            let value: Value
            switch key & 7 {
            case 0: value = .varint(try readVarint())
            case 1: value = .fixed64(try readFixed(8))
            case 2:
                let length = try readVarint()
                guard length <= UInt64(bytes.count - offset) else { throw DecodeError.truncated }
                value = .bytes(Data(bytes[offset..<(offset + Int(length))]))
                offset += Int(length)
            case 5: value = .fixed32(UInt32(try readFixed(4)))
            default: throw DecodeError.invalidProtobuf
            }
            fields[Int(key >> 3), default: []].append(value)
        }
        self.fields = fields
    }
    public func uint(_ field: Int) -> UInt64? {
        guard case .varint(let value) = fields[field]?.last else { return nil }; return value
    }
    public func int(_ field: Int) -> Int? { uint(field).map { Int(Int32(truncatingIfNeeded: $0)) } }
    public func data(_ field: Int) -> Data? {
        guard case .bytes(let value) = fields[field]?.last else { return nil }; return value
    }
    public func string(_ field: Int) -> String? { data(field).flatMap { String(data: $0, encoding: .utf8) } }
    public func float(_ field: Int) -> Float? {
        guard case .fixed32(let value) = fields[field]?.last else { return nil }; return Float(bitPattern: value)
    }
    public func message(_ field: Int) throws -> ProtobufMessage? { try data(field).map(ProtobufMessage.init) }
    public func messages(_ field: Int) throws -> [ProtobufMessage] {
        try (fields[field] ?? []).map {
            guard case .bytes(let bytes) = $0 else { throw DecodeError.invalidProtobuf }
            return try ProtobufMessage(bytes)
        }
    }
    func required(_ field: Int) throws -> ProtobufMessage {
        guard let value = try message(field) else { throw DecodeError.missingField }; return value
    }

    public var raw: RawProtobufMessage {
        raw(depth: 0)
    }

    private func raw(depth: Int) -> RawProtobufMessage {
        RawProtobufMessage(fields: fields.keys.sorted().flatMap { number in
            (fields[number] ?? []).map { value in
                switch value {
                case .varint(let value): return RawProtobufField(number: number, wireType: "varint", value: String(value))
                case .fixed64(let value): return RawProtobufField(number: number, wireType: "fixed64", value: String(value))
                case .fixed32(let value): return RawProtobufField(number: number, wireType: "fixed32", value: String(value))
                case .bytes(let data):
                    let text = String(data: data, encoding: .utf8).flatMap { value in
                        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || [10, 13, 9].contains(Int($0.value)) } ? value : nil
                    }
                    let nested = depth < 16 ? (try? ProtobufMessage(data))?.raw(depth: depth + 1) : nil
                    return RawProtobufField(number: number, wireType: "bytes", value: data.base64EncodedString(),
                                            utf8: text, message: nested)
                }
            }
        })
    }
}

public struct RawProtobufMessage: Codable, Sendable, Equatable {
    public var fields: [RawProtobufField]
    public init(fields: [RawProtobufField]) { self.fields = fields }
}

public struct RawProtobufField: Codable, Sendable, Equatable {
    public var number: Int
    public var wireType: String
    public var value: String
    public var utf8: String?
    public var message: RawProtobufMessage?
    public init(number: Int, wireType: String, value: String, utf8: String? = nil, message: RawProtobufMessage? = nil) {
        self.number = number; self.wireType = wireType; self.value = value; self.utf8 = utf8; self.message = message
    }
}

public enum DecodeError: String, Error, Sendable {
    case truncated, invalidProtobuf, missingField, invalidUTF8, invalidRunLength
    case invalidCompression, checksumMismatch, sizeLimit, invalidTable
}
