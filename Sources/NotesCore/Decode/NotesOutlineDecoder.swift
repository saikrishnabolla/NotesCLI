import Foundation

public enum NotesOutlineDecoder {
    public static func decode(_ data: Data) throws -> [String] {
        guard let payload = try ProtobufMessage(data).data(2),
              let opening = payload.firstIndex(of: UInt8(ascii: "[")),
              let closing = payload.lastIndex(of: UInt8(ascii: "]")), opening <= closing else {
            throw DecodeError.invalidProtobuf
        }
        let json = payload[opening...closing]
        guard let values = try JSONSerialization.jsonObject(with: Data(json)) as? [String],
              values.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw DecodeError.invalidProtobuf }
        return values
    }
}
