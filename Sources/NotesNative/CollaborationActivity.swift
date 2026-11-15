import CryptoKit
import Foundation
import NotesCore

/// Read-only export of a note's stored collaboration activity events.
///
/// Notes stores activity events as an `ICTTOrderedSetVersionedDocument` in `activityEventsData`.
/// Each event is an `ICCloudSyncingObjectActivityEvent` with opaque `data` and optional
/// `fallbackData`. No fixture with real events has been checked, so this export keeps every
/// payload raw and only adds a JSON tree when Foundation parses the bytes as JSON.
public struct CollaborationActivityExport: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// The note stores no activity data.
        case absent
        /// Activity data exists but the NotesShared decoder could not be reached.
        case decoderUnavailable = "decoder_unavailable"
        /// The document reports versions newer than this macOS can read. Events are best effort.
        case futureVersion = "future_version"
        /// The document decoded and every reachable event is listed.
        case decoded
    }

    public var noteID: String
    public var title: String
    public var status: Status
    public var statusDetail: String?
    public var blob: CollaborationActivityPayload?
    public var futureVersionCount: Int?
    public var totalEventCount: Int?
    public var events: [CollaborationActivityEvent]
    public var truncated: Bool
    public var limits: CollaborationActivityLimits

    public init(noteID: String, title: String, status: Status, statusDetail: String? = nil,
                blob: CollaborationActivityPayload? = nil, futureVersionCount: Int? = nil,
                totalEventCount: Int? = nil, events: [CollaborationActivityEvent] = [],
                truncated: Bool = false, limits: CollaborationActivityLimits) {
        self.noteID = noteID; self.title = title; self.status = status; self.statusDetail = statusDetail
        self.blob = blob; self.futureVersionCount = futureVersionCount; self.totalEventCount = totalEventCount
        self.events = events; self.truncated = truncated; self.limits = limits
    }
}

public struct CollaborationActivityEvent: Codable, Sendable, Equatable {
    public var index: Int
    public var runtimeClass: String
    public var data: CollaborationActivityPayload?
    public var fallbackData: CollaborationActivityPayload?
    /// Stable codes for fields that could not be read, such as `data_unexpected_type`.
    public var issues: [String]?

    public init(index: Int, runtimeClass: String, data: CollaborationActivityPayload?,
                fallbackData: CollaborationActivityPayload?, issues: [String]? = nil) {
        self.index = index; self.runtimeClass = runtimeClass; self.data = data
        self.fallbackData = fallbackData; self.issues = issues
    }
}

public struct CollaborationActivityPayload: Codable, Sendable, Equatable {
    public enum Omission: String, Codable, Sendable {
        /// The payload is larger than the per-payload inline limit.
        case tooLarge = "too_large"
        /// Earlier payloads used the whole inline output budget.
        case outputBudget = "output_budget"
    }
    public enum DecodeStatus: String, Codable, Sendable {
        case json
        case notJSON = "not_json"
        /// Too large to parse within the inline limit.
        case tooLarge = "too_large"
        /// Valid JSON nested deeper than the tree limit.
        case tooDeep = "too_deep"
        /// The blob is the Notes document itself and is never parsed as JSON.
        case notAttempted = "not_attempted"
    }

    public var byteCount: Int
    public var sha256: String
    public var base64: String?
    public var base64Omitted: Omission?
    public var decodeStatus: DecodeStatus
    public var json: CollaborationJSONValue?

    public init(byteCount: Int, sha256: String, base64: String?, base64Omitted: Omission?,
                decodeStatus: DecodeStatus, json: CollaborationJSONValue?) {
        self.byteCount = byteCount; self.sha256 = sha256; self.base64 = base64
        self.base64Omitted = base64Omitted; self.decodeStatus = decodeStatus; self.json = json
    }
}

/// Output caps. Defaults keep one result well inside the 4 MiB MCP stdio line limit.
public struct CollaborationActivityLimits: Codable, Sendable, Equatable {
    public static let defaultEventLimit = 100
    public static let maximumEventLimit = 500
    /// Matches `MCPServer.textLimit` (48 KiB).
    public static let defaultInlineBlobBytes = 48 * 1024
    public static let defaultInlinePayloadBytes = 16 * 1024
    /// Matches the 1 MiB MCP attachment resource chunk.
    public static let defaultInlineBudgetBytes = 1_048_576
    public static let maximumJSONDepth = 32

    public var eventLimit: Int
    public var inlineBlobBytes: Int
    public var inlinePayloadBytes: Int
    public var inlineBudgetBytes: Int

    public init(eventLimit: Int = defaultEventLimit,
                inlineBlobBytes: Int = defaultInlineBlobBytes,
                inlinePayloadBytes: Int = defaultInlinePayloadBytes,
                inlineBudgetBytes: Int = defaultInlineBudgetBytes) {
        self.eventLimit = eventLimit; self.inlineBlobBytes = inlineBlobBytes
        self.inlinePayloadBytes = inlinePayloadBytes; self.inlineBudgetBytes = inlineBudgetBytes
    }

    /// Validates a caller-supplied event limit.
    public static func events(_ requested: Int?) throws -> CollaborationActivityLimits {
        guard let requested else { return CollaborationActivityLimits() }
        guard (1...maximumEventLimit).contains(requested) else {
            throw NotesError("invalid_limit", "limit must be between 1 and \(maximumEventLimit).")
        }
        return CollaborationActivityLimits(eventLimit: requested)
    }
}

/// JSON-safe tree. Objects encode with keys in sorted order.
public indirect enum CollaborationJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([CollaborationJSONValue])
    case object([String: CollaborationJSONValue])

    private struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .integer(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .number(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .string(let value): var c = encoder.singleValueContainer(); try c.encode(value)
        case .array(let values):
            var c = encoder.unkeyedContainer()
            for value in values { try c.encode(value) }
        case .object(let values):
            var c = encoder.container(keyedBy: Key.self)
            for key in values.keys.sorted() { try c.encode(values[key]!, forKey: Key(key)) }
        }
    }

    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: Key.self) {
            var values: [String: CollaborationJSONValue] = [:]
            for key in c.allKeys { values[key.stringValue] = try c.decode(CollaborationJSONValue.self, forKey: key) }
            self = .object(values); return
        }
        if var c = try? decoder.unkeyedContainer() {
            var values: [CollaborationJSONValue] = []
            while !c.isAtEnd { values.append(try c.decode(CollaborationJSONValue.self)) }
            self = .array(values); return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else { self = .string(try c.decode(String.self)) }
    }

    /// Converts a `JSONSerialization` result. Returns nil past `depth` levels.
    static func make(_ value: Any, depth: Int) -> CollaborationJSONValue? {
        guard depth >= 0 else { return nil }
        switch value {
        case is NSNull: return .null
        case let text as String: return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            switch String(cString: number.objCType) {
            case "c", "s", "i", "l", "q", "C", "S", "I": return .integer(number.int64Value)
            case "L", "Q":
                return number.uint64Value <= UInt64(Int64.max) ? .integer(number.int64Value) : .number(number.doubleValue)
            default: return .number(number.doubleValue)
            }
        case let array as [Any]:
            var values: [CollaborationJSONValue] = []
            values.reserveCapacity(array.count)
            for item in array {
                guard let converted = make(item, depth: depth - 1) else { return nil }
                values.append(converted)
            }
            return .array(values)
        case let dictionary as [String: Any]:
            var values: [String: CollaborationJSONValue] = [:]
            for (key, item) in dictionary {
                guard let converted = make(item, depth: depth - 1) else { return nil }
                values[key] = converted
            }
            return .object(values)
        default: return nil
        }
    }
}

/// Raw values pulled from NotesShared before any formatting.
public struct CollaborationActivityRaw {
    public enum Document {
        case unavailable(String)
        case loaded(futureVersionCount: Int?, events: [Event])
    }
    public struct Event {
        public var runtimeClass: String
        public var data: Data?
        public var fallbackData: Data?
        public var issues: [String]
        public init(runtimeClass: String, data: Data?, fallbackData: Data?, issues: [String] = []) {
            self.runtimeClass = runtimeClass; self.data = data; self.fallbackData = fallbackData; self.issues = issues
        }
    }

    public var blob: Data?
    public var blobIssue: String?
    public var document: Document?

    public init(blob: Data?, blobIssue: String? = nil, document: Document?) {
        self.blob = blob; self.blobIssue = blobIssue; self.document = document
    }
}

/// Reads activity values through an injected key-value function so tests can run without NotesShared.
/// Every key it touches is a getter listed in `readKeys`.
public struct CollaborationActivityRuntimeReader {
    public static let readKeys: Set<String> = [
        "activityEventsData", "activityEventsDocument", "futureVersionCount", "orderedSet", "allObjects",
        "data", "fallbackData",
    ]

    public typealias ValueFunction = (_ object: AnyObject, _ key: String) -> Any?
    public typealias RespondsFunction = (_ object: AnyObject, _ key: String) -> Bool
    public typealias ClassNameFunction = (_ object: AnyObject) -> String

    private let value: ValueFunction
    private let responds: RespondsFunction
    private let className: ClassNameFunction

    public init(value: @escaping ValueFunction, responds: @escaping RespondsFunction,
                className: @escaping ClassNameFunction) {
        self.value = value; self.responds = responds; self.className = className
    }

    private func read(_ object: AnyObject, _ key: String) -> Any? {
        precondition(Self.readKeys.contains(key), "Collaboration activity reads only listed getters.")
        guard responds(object, key) else { return nil }
        return value(object, key)
    }

    public func read(note: AnyObject) throws -> CollaborationActivityRaw {
        guard responds(note, "activityEventsData") else {
            throw NotesError("collaboration_activity_unsupported",
                             "This version of Notes does not expose collaboration activity data.")
        }
        let stored = read(note, "activityEventsData")
        if stored == nil || stored is NSNull { return CollaborationActivityRaw(blob: nil, document: nil) }
        guard let blob = stored as? Data else {
            return CollaborationActivityRaw(blob: nil, blobIssue: "activity_data_unexpected_type", document: nil)
        }
        if blob.isEmpty { return CollaborationActivityRaw(blob: blob, document: nil) }
        guard responds(note, "activityEventsDocument") else {
            return CollaborationActivityRaw(blob: blob, document: .unavailable("activityEventsDocument is not available."))
        }
        guard let documentValue = read(note, "activityEventsDocument"), !(documentValue is NSNull) else {
            return CollaborationActivityRaw(blob: blob, document: .unavailable("Notes did not decode the activity document."))
        }
        let document = documentValue as AnyObject
        let future = (read(document, "futureVersionCount") as? NSNumber)?.intValue
        guard let setValue = read(document, "orderedSet"), !(setValue is NSNull) else {
            return CollaborationActivityRaw(blob: blob, document: .unavailable("The activity document has no ordered set."))
        }
        guard let objects = read(setValue as AnyObject, "allObjects") as? [AnyObject] else {
            return CollaborationActivityRaw(blob: blob, document: .unavailable("The activity ordered set could not be listed."))
        }
        let events = objects.map { object -> CollaborationActivityRaw.Event in
            var issues: [String] = []
            func payload(_ key: String) -> Data? {
                guard responds(object, key) else { issues.append("\(key)_selector_missing"); return nil }
                let raw = read(object, key)
                if raw == nil || raw is NSNull { return nil }
                guard let data = raw as? Data else { issues.append("\(key)_unexpected_type"); return nil }
                return data
            }
            return CollaborationActivityRaw.Event(runtimeClass: className(object), data: payload("data"),
                                                  fallbackData: payload("fallbackData"), issues: issues)
        }
        return CollaborationActivityRaw(blob: blob, document: .loaded(futureVersionCount: future, events: events))
    }
}

public enum CollaborationActivityExporter {
    public static func export(noteID: String, title: String, raw: CollaborationActivityRaw,
                              limits: CollaborationActivityLimits = CollaborationActivityLimits()) -> CollaborationActivityExport {
        var budget = limits.inlineBudgetBytes
        func payload(_ data: Data, inlineLimit: Int, parse: Bool) -> CollaborationActivityPayload {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var base64: String?, omitted: CollaborationActivityPayload.Omission?
            if data.count > inlineLimit { omitted = .tooLarge }
            else if data.count > budget { omitted = .outputBudget }
            else { base64 = data.base64EncodedString(); budget -= data.count }
            var status = CollaborationActivityPayload.DecodeStatus.notAttempted
            var json: CollaborationJSONValue?
            if parse {
                if data.count > limits.inlinePayloadBytes { status = .tooLarge }
                else if let object = try? JSONSerialization.jsonObject(with: data) {
                    json = CollaborationJSONValue.make(object, depth: CollaborationActivityLimits.maximumJSONDepth)
                    status = json == nil ? .tooDeep : .json
                } else { status = .notJSON }
            }
            return CollaborationActivityPayload(byteCount: data.count, sha256: hash, base64: base64,
                                                base64Omitted: omitted, decodeStatus: status, json: json)
        }

        let blob = raw.blob.map { payload($0, inlineLimit: limits.inlineBlobBytes, parse: false) }
        if let issue = raw.blobIssue {
            return CollaborationActivityExport(noteID: noteID, title: title, status: .decoderUnavailable,
                                               statusDetail: issue, limits: limits)
        }
        guard let stored = raw.blob, !stored.isEmpty else {
            return CollaborationActivityExport(noteID: noteID, title: title, status: .absent, blob: blob, limits: limits)
        }
        switch raw.document {
        case .none:
            return CollaborationActivityExport(noteID: noteID, title: title, status: .decoderUnavailable,
                                               statusDetail: "Notes did not decode the activity document.",
                                               blob: blob, limits: limits)
        case .unavailable(let detail)?:
            return CollaborationActivityExport(noteID: noteID, title: title, status: .decoderUnavailable,
                                               statusDetail: detail, blob: blob, limits: limits)
        case .loaded(let future, let rawEvents)?:
            let kept = rawEvents.prefix(limits.eventLimit)
            let events = kept.enumerated().map { index, event in
                CollaborationActivityEvent(
                    index: index, runtimeClass: event.runtimeClass,
                    data: event.data.map { payload($0, inlineLimit: limits.inlinePayloadBytes, parse: true) },
                    fallbackData: event.fallbackData.map { payload($0, inlineLimit: limits.inlinePayloadBytes, parse: true) },
                    issues: event.issues.isEmpty ? nil : event.issues)
            }
            let isFuture = (future ?? 0) > 0
            return CollaborationActivityExport(
                noteID: noteID, title: title, status: isFuture ? .futureVersion : .decoded,
                statusDetail: isFuture ? "The document holds versions newer than this macOS can read; events are best effort." : nil,
                blob: blob, futureVersionCount: future, totalEventCount: rawEvents.count, events: events,
                truncated: rawEvents.count > kept.count, limits: limits)
        }
    }
}
