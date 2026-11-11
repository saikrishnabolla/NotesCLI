import Foundation

/// Decodes the CRDT object graph Notes stores for audio transcripts and summaries.
public enum NotesRecordingDecoder {
    private enum ObjectID { case ref(Int), string(String), number(Double), integer(Int) }
    private enum Value { case string(String), number(Double), integer(Int), map(String, [String: Value]), note(String) }

    public static func decode(_ data: Data) throws -> (words: [TranscriptWord], metadata: RecordingMetadata) {
        var root = try ProtobufMessage(NotesInflate.decompressIfNeeded(data))
        if (root.fields[3] ?? []).isEmpty, let wrapped = try root.message(2)?.message(3) { root = wrapped }
        let entries = try root.messages(3)
        guard !entries.isEmpty, entries.count <= 2_000_000 else { throw DecodeError.invalidProtobuf }
        let keys = strings(root, 4), types = strings(root, 5)
        let uuids = (root.fields[6] ?? []).compactMap { if case .bytes(let data) = $0 { return data }; return nil }

        func objectID(_ message: ProtobufMessage) -> ObjectID? {
            if let value = message.string(4) { return .string(value) }
            if case .fixed64(let bits) = message.fields[3]?.last { return .number(Double(bitPattern: bits)) }
            if let value = message.int(6) { return .ref(value) }
            if let value = message.int(2) { return .integer(value) }
            if let value = message.int(1) { return .integer(value) }
            return nil
        }
        func customIDs(_ entry: ProtobufMessage) throws -> (type: String, values: [String: ObjectID])? {
            guard let map = try entry.message(13) else { return nil }
            let typeIndex = map.int(1) ?? 0
            let type = types.indices.contains(typeIndex) ? types[typeIndex] : ""
            var values: [String: ObjectID] = [:]
            for item in try map.messages(3) {
                guard let keyIndex = item.int(1), keys.indices.contains(keyIndex), let id = try item.message(2).flatMap(objectID) else { continue }
                values[keys[keyIndex]] = id
            }
            return (type, values)
        }
        func custom(_ entry: ProtobufMessage, _ depth: Int, _ visited: Set<Int>) throws -> Value? {
            guard depth <= 16, let map = try customIDs(entry) else { return nil }
            var values: [String: Value] = [:]
            for (key, id) in map.values {
                if let value = try resolve(id, depth + 1, visited) { values[key] = value }
            }
            if map.type == "com.apple.CRDT.NSString" || map.type == "com.apple.CRDT.NSUUID" { return values["self"] }
            if map.type == "com.apple.CRDT.NSNumber" || map.type == "com.apple.CRDT.NSDate" {
                return values["doubleValue"] ?? values["integerValue"]
            }
            return .map(map.type, values)
        }
        func resolve(_ id: ObjectID, _ depth: Int, _ visited: Set<Int>) throws -> Value? {
            switch id {
            case .string(let value): return .string(value)
            case .number(let value): return .number(value)
            case .integer(let value): return .integer(value)
            case .ref(let index):
                guard entries.indices.contains(index), !visited.contains(index), depth <= 16 else { return nil }
                let entry = entries[index], seen = visited.union([index])
                if let value = try custom(entry, depth, seen) { return value }
                if let register = try entry.message(1), let target = try register.message(2), let id = objectID(target) {
                    return try resolve(id, depth + 1, seen)
                }
                if let note = try entry.message(10)?.string(2) { return .note(note.trimmingCharacters(in: .newlines)) }
                return nil
            }
        }
        func maps(_ type: String) throws -> [[String: Value]] {
            try entries.compactMap { entry in
                guard case .map(let found, let values) = try custom(entry, 0, []) else { return nil }
                return found == type ? values : nil
            }
        }
        func string(_ value: Value?) -> String? {
            switch value { case .string(let value), .note(let value): return value; default: return nil }
        }
        func number(_ value: Value?) -> Double? {
            switch value { case .number(let value): return value; case .integer(let value): return Double(value); default: return nil }
        }
        func integer(_ value: Value?) -> Int? {
            switch value { case .integer(let value): return value; case .number(let value): return Int(value); default: return nil }
        }
        func reference(_ id: ObjectID?) -> Int? { if case .ref(let index) = id { return index }; return nil }
        func primitive(_ id: ObjectID?) throws -> Value? { guard let id else { return nil }; return try resolve(id, 0, []) }

        let fallbackSegments = try maps("com.apple.notes.ICTTTranscriptSegment").compactMap { segment -> TranscriptWord? in
            guard let text = string(segment["text"]) else { return nil }
            return TranscriptWord(text: text, start: number(segment["timestamp"]), duration: number(segment["duration"]), speaker: string(segment["speaker"]))
        }.sorted { ($0.start ?? .greatestFiniteMagnitude) < ($1.start ?? .greatestFiniteMagnitude) }
        let recordingEntry = try entries.first { try customIDs($0)?.type == "com.apple.notes.ICTTAudioRecording" }
        let recordingIDs = try recordingEntry.flatMap(customIDs)?.values ?? [:]
        var orderedSegments: [TranscriptWord] = []
        if let fragmentsIndex = reference(recordingIDs["fragments"]), entries.indices.contains(fragmentsIndex),
           let list = try entries[fragmentsIndex].message(5) {
            for (fragmentNumber, item) in try list.messages(1).enumerated() {
                guard let fragmentIndex = try item.message(2).flatMap(objectID).flatMap(reference), entries.indices.contains(fragmentIndex),
                      let fragment = try customIDs(entries[fragmentIndex]), fragment.type == "com.apple.notes.ICTTAudioRecording.Fragment",
                      let transcriptIndex = reference(fragment.values["transcript"]), entries.indices.contains(transcriptIndex),
                      let set = try entries[transcriptIndex].message(15) else { continue }
                var bySlot: [Int: Int] = [:]
                if let dictionary = try set.message(2) {
                    for element in try dictionary.messages(1) {
                        guard let keyIndex = try element.message(1).flatMap(objectID).flatMap(reference), entries.indices.contains(keyIndex),
                              let key = try customIDs(entries[keyIndex]), let slot = integer(try primitive(key.values["UUIDIndex"])),
                              let segmentIndex = try element.message(2).flatMap(objectID).flatMap(reference) else { continue }
                        bySlot[slot] = segmentIndex
                    }
                }
                var order: [(Int, Int)] = []
                if let ordering = try set.message(1) {
                    let slots = Dictionary(uniqueKeysWithValues: uuids.enumerated().map { ($0.element.base64EncodedString(), $0.offset) })
                    for pair in try ordering.messages(2) {
                        guard let position = pair.int(1), let uuid = pair.data(2), let slot = slots[uuid.base64EncodedString()],
                              let segmentIndex = bySlot[slot] else { continue }
                        order.append((position, segmentIndex))
                    }
                }
                for (_, segmentIndex) in order.sorted(by: { $0.0 < $1.0 }) where entries.indices.contains(segmentIndex) {
                    guard let segment = try customIDs(entries[segmentIndex]), segment.type == "com.apple.notes.ICTTTranscriptSegment",
                          let text = string(try primitive(segment.values["text"])) else { continue }
                    orderedSegments.append(TranscriptWord(text: text, start: number(try primitive(segment.values["timestamp"])),
                                                          duration: number(try primitive(segment.values["duration"])),
                                                          speaker: string(try primitive(segment.values["speaker"])), fragment: fragmentNumber))
                }
            }
        }
        let segments = orderedSegments.isEmpty ? fallbackSegments : orderedSegments
        let recording = try maps("com.apple.notes.ICTTAudioRecording").first ?? [:]
        let start = number(recording["callRecordingStartTime"]).map(Date.init(timeIntervalSince1970:))
        let metadata = RecordingMetadata(summary: string(recording["summary"]), topLineSummary: string(recording["topLineSummary"]),
                                         localSpeakerHandle: string(recording["callLocalSpeakerHandle"]),
                                         remoteSpeakerHandle: string(recording["callRemoteSpeakerHandle"]),
                                         callType: integer(recording["callType"]),
                                         isCallRecording: integer(recording["callRecording"]).map { $0 != 0 }, startTime: start)
        return (segments, metadata)
    }

    public static func joined(_ words: [TranscriptWord]) -> String {
        var result = ""
        for word in words where !word.text.isEmpty {
            let punctuation = word.text.range(of: #"^[.,!?;:%)\]}…'’]"#, options: .regularExpression) != nil
            if !result.isEmpty, !result.last!.isWhitespace, !word.text.first!.isWhitespace, !punctuation { result += " " }
            result += word.text
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strings(_ message: ProtobufMessage, _ field: Int) -> [String] {
        (message.fields[field] ?? []).compactMap { if case .bytes(let data) = $0 { return String(data: data, encoding: .utf8) }; return nil }
    }
}
