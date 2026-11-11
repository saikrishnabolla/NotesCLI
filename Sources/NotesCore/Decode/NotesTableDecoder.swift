import Foundation

/// Reconstructs ICTable's ordered row/column identities and redirected cell references.
public enum NotesTableDecoder {
    public static func decode(_ data: Data, inlineText: (InlineRef) -> String? = { _ in nil }) throws -> [[String]] {
        let root = try ProtobufMessage(NotesInflate.decompressIfNeeded(data))
        let versions = try root.messages(2)
        guard versions.count == 1 else { throw DecodeError.invalidTable }
        let document = try versions[0].required(3)
        let objects = try document.messages(3)
        func strings(_ field: Int) -> [String] {
            (document.fields[field] ?? []).compactMap { if case .bytes(let d) = $0 { return String(data: d, encoding: .utf8) }; return nil }
        }
        let keys = strings(4), types = strings(5)
        let uuids: [Data] = (document.fields[6] ?? []).compactMap { if case .bytes(let d) = $0 { return d }; return nil }
        func object(_ ref: ProtobufMessage) throws -> ProtobufMessage {
            guard let i = ref.int(6), objects.indices.contains(i) else { throw DecodeError.invalidTable }; return objects[i]
        }
        func identity(_ ref: ProtobufMessage) throws -> Int {
            let map = try object(ref).required(13)
            guard let first = try map.messages(3).first, let i = try first.required(2).int(2), uuids.indices.contains(i) else { throw DecodeError.invalidTable }
            return i
        }
        func ordering(_ entry: ProtobufMessage) throws -> ([Int: Int], Int) {
            let order = try entry.required(16).required(1)
            let attachments = try order.required(1).messages(2)
            var index: [Int: Int] = [:]
            for (i, attachment) in attachments.enumerated() {
                guard let uuid = attachment.data(2), let key = uuids.firstIndex(of: uuid) else { throw DecodeError.invalidTable }
                index[key] = i
            }
            let redirects = try order.message(2)?.messages(1) ?? []
            // A redirect can itself point to an older identity; settle the whole chain.
            for _ in 0...redirects.count {
                var changed = false
                for redirect in redirects {
                    let key = try identity(redirect.required(1)), value = try identity(redirect.required(2))
                    if let position = index[key], index[value] != position { index[value] = position; changed = true }
                }
                if !changed { break }
            }
            return (index, attachments.count)
        }
        var table: ProtobufMessage?
        var rtl = false
        for entry in objects {
            if let map = try entry.message(13) {
                if let type = map.int(1), types.indices.contains(type), types[type] == "com.apple.notes.ICTable" { table = map }
                for item in try map.messages(3) {
                    if try item.required(2).string(4) == "CRTableColumnDirectionRightToLeft" { rtl = true }
                }
            }
            if try entry.message(1)?.message(2)?.string(4) == "CRTableColumnDirectionRightToLeft" { rtl = true }
        }
        guard let table else { throw DecodeError.invalidTable }
        var parts: [String: ProtobufMessage] = [:]
        for entry in try table.messages(3) {
            guard let key = entry.int(1), keys.indices.contains(key) else { throw DecodeError.invalidTable }
            if ["crRows", "crColumns", "cellColumns"].contains(keys[key]) { parts[keys[key]] = try object(entry.required(2)) }
        }
        guard let rows = parts["crRows"], let columns = parts["crColumns"], let cells = parts["cellColumns"] else { throw DecodeError.invalidTable }
        let (rowIndex, rowCount) = try ordering(rows), (columnIndex, columnCount) = try ordering(columns)
        guard rowCount <= 100_000, columnCount <= 100_000, rowCount * columnCount <= 1_000_000 else { throw DecodeError.sizeLimit }
        var result = [[String]](repeating: [String](repeating: "", count: columnCount), count: rowCount)
        for column in try cells.required(6).messages(1) {
            let columnID = try identity(column.required(1))
            let columnObject = try object(column.required(2))
            for row in try columnObject.required(6).messages(1) {
                let rowID = try identity(row.required(1))
                // Tombstoned cells remain in the CRDT but not in the visible ordering.
                guard let r = rowIndex[rowID], let c = columnIndex[columnID] else { continue }
                let cell = try object(row.required(2)).required(10)
                var document = try NotesDecoder.decodeNote(cell)
                for i in document.runs.indices {
                    if var ref = document.runs[i].attachment {
                        ref.displayText = inlineText(ref)
                        document.runs[i].attachment = ref
                    }
                }
                result[r][c] = document.plainText()
            }
        }
        return rtl ? result.map { Array($0.reversed()) } : result
    }
}
