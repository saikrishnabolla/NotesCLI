import Foundation
import XCTest
import NotesCore
@testable import NotesNative

/// Stand-in for NotesShared objects. Only keys present in `values` respond.
private final class FakeObject: NSObject {
    let name: String
    var values: [String: Any]
    init(_ name: String, _ values: [String: Any] = [:]) { self.name = name; self.values = values }
}

private final class AccessLog { var keys: [String] = [] }

private func reader(_ log: AccessLog) -> CollaborationActivityRuntimeReader {
    CollaborationActivityRuntimeReader(
        value: { object, key in log.keys.append(key); return (object as! FakeObject).values[key] },
        responds: { object, key in (object as! FakeObject).values.keys.contains(key) },
        className: { ($0 as! FakeObject).name })
}

private let unknownBytes = Data([0xde, 0xad, 0xbe, 0xef])
private let jsonBytes = Data(#"{"b":[1,true,null],"a":"x","n":1.5}"#.utf8)
private let storedBlob = Data("STORED".utf8)

private func note(events: [AnyObject]?, future: Int? = nil, blob: Any? = storedBlob) -> FakeObject {
    var document: [String: Any] = [:]
    if let future { document["futureVersionCount"] = NSNumber(value: future) }
    if let events { document["orderedSet"] = FakeObject("ICCROrderedSet", ["allObjects": events]) }
    var values: [String: Any] = ["activityEventsDocument": FakeObject("ICTTOrderedSetVersionedDocument", document)]
    values["activityEventsData"] = blob ?? NSNull()
    return FakeObject("ICNote", values)
}

private func event(_ data: Any?, fallback: Any? = nil) -> FakeObject {
    FakeObject("ICCloudSyncingObjectActivityEvent", ["data": data ?? NSNull(), "fallbackData": fallback ?? NSNull()])
}

private func export(_ object: FakeObject, limits: CollaborationActivityLimits = CollaborationActivityLimits(),
                    log: AccessLog = AccessLog()) throws -> CollaborationActivityExport {
    CollaborationActivityExporter.export(noteID: "NOTE-1", title: "Shared", raw: try reader(log).read(note: object), limits: limits)
}

final class CollaborationActivityTests: XCTestCase {
    func testAbsentDataReportsAbsentWithoutTouchingTheDocument() throws {
        let log = AccessLog()
        let result = try export(note(events: [], blob: nil), log: log)
        XCTAssertEqual(result.status, .absent)
        XCTAssertNil(result.blob)
        XCTAssertEqual(result.events, [])
        XCTAssertNil(result.totalEventCount)
        XCTAssertEqual(log.keys, ["activityEventsData"])

        let empty = try export(note(events: [], blob: Data()))
        XCTAssertEqual(empty.status, .absent)
        XCTAssertEqual(empty.blob?.byteCount, 0)
    }

    func testMissingActivitySelectorIsStableError() {
        XCTAssertThrowsError(try reader(AccessLog()).read(note: FakeObject("ICNote"))) { error in
            XCTAssertEqual((error as? NotesError)?.code, "collaboration_activity_unsupported")
        }
    }

    func testRawUnknownBytesStayRawAndHashed() throws {
        let result = try export(note(events: [event(unknownBytes)]))
        XCTAssertEqual(result.status, .decoded)
        XCTAssertEqual(result.blob, CollaborationActivityPayload(
            byteCount: 6, sha256: "1afc73e07986a0444e7c0c6597933b433f4ecd86863ae4754be1cbadbdbc4a53",
            base64: "U1RPUkVE", base64Omitted: nil, decodeStatus: .notAttempted, json: nil))
        XCTAssertEqual(result.totalEventCount, 1)
        XCTAssertEqual(result.events, [CollaborationActivityEvent(
            index: 0, runtimeClass: "ICCloudSyncingObjectActivityEvent",
            data: CollaborationActivityPayload(
                byteCount: 4, sha256: "5f78c33274e43fa9de5659265c1d917e25c03722dcb0b8d27db8d5feaa813953",
                base64: "3q2+7w==", base64Omitted: nil, decodeStatus: .notJSON, json: nil),
            fallbackData: nil)])
    }

    func testJSONPayloadDecodesToTreeAndKeepsRawBytes() throws {
        let result = try export(note(events: [event(jsonBytes, fallback: unknownBytes)]))
        let payload = try XCTUnwrap(result.events.first?.data)
        XCTAssertEqual(payload.decodeStatus, .json)
        XCTAssertEqual(payload.base64, "eyJiIjpbMSx0cnVlLG51bGxdLCJhIjoieCIsIm4iOjEuNX0=")
        XCTAssertEqual(payload.sha256, "d16e4b201452ae81adbc3b2240ce54a75eb1597a1a35f8edde10ae7d28265b42")
        XCTAssertEqual(payload.json, .object(["a": .string("x"), "b": .array([.integer(1), .bool(true), .null]), "n": .number(1.5)]))
        XCTAssertEqual(result.events.first?.fallbackData?.decodeStatus, .notJSON)
    }

    func testFutureVersionIsReportedAndEventsAreKept() throws {
        let result = try export(note(events: [event(unknownBytes)], future: 2))
        XCTAssertEqual(result.status, .futureVersion)
        XCTAssertEqual(result.futureVersionCount, 2)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(try export(note(events: [], future: 0)).status, .decoded)
    }

    func testDecoderUnavailableCasesAreStatusesNotCrashes() throws {
        XCTAssertEqual(try export(note(events: nil)).status, .decoderUnavailable)
        let noDocument = FakeObject("ICNote", ["activityEventsData": storedBlob])
        let missing = try export(noDocument)
        XCTAssertEqual(missing.status, .decoderUnavailable)
        XCTAssertEqual(missing.blob?.byteCount, 6)
        let nilDocument = FakeObject("ICNote", ["activityEventsData": storedBlob, "activityEventsDocument": NSNull()])
        XCTAssertEqual(try export(nilDocument).status, .decoderUnavailable)
        let noList = note(events: [])
        ((noList.values["activityEventsDocument"] as! FakeObject).values["orderedSet"] as! FakeObject).values = [:]
        XCTAssertEqual(try export(noList).status, .decoderUnavailable)
        let wrongType = try export(note(events: [], blob: "not data"))
        XCTAssertEqual(wrongType.status, .decoderUnavailable)
        XCTAssertEqual(wrongType.statusDetail, "activity_data_unexpected_type")
    }

    func testUnknownEventShapesAreKeptWithIssues() throws {
        let odd = FakeObject("SomeFutureEvent")
        let typed = event("text payload")
        let result = try export(note(events: [odd, typed]))
        XCTAssertEqual(result.events.map(\.runtimeClass), ["SomeFutureEvent", "ICCloudSyncingObjectActivityEvent"])
        XCTAssertEqual(result.events[0].issues, ["data_selector_missing", "fallbackData_selector_missing"])
        XCTAssertEqual(result.events[1].issues, ["data_unexpected_type"])
        XCTAssertNil(result.events[1].data)
    }

    func testCapsTruncateEventsAndOmitLargePayloads() throws {
        let big = Data(repeating: 0x41, count: 40)
        let limits = CollaborationActivityLimits(eventLimit: 3, inlineBlobBytes: 4, inlinePayloadBytes: 32, inlineBudgetBytes: 10)
        let result = try export(note(events: [event(big), event(unknownBytes), event(unknownBytes), event(unknownBytes)]), limits: limits)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.totalEventCount, 4)
        XCTAssertEqual(result.events.map(\.index), [0, 1, 2])
        XCTAssertEqual(result.blob?.base64Omitted, .tooLarge)
        XCTAssertNil(result.blob?.base64)
        XCTAssertEqual(result.blob?.sha256, "1afc73e07986a0444e7c0c6597933b433f4ecd86863ae4754be1cbadbdbc4a53")
        XCTAssertEqual(result.events[0].data?.base64Omitted, .tooLarge)
        XCTAssertEqual(result.events[0].data?.decodeStatus, .tooLarge)
        XCTAssertEqual(result.events[0].data?.byteCount, 40)
        XCTAssertEqual(result.events[1].data?.base64, "3q2+7w==")
        XCTAssertEqual(result.events[2].data?.base64, "3q2+7w==")
        XCTAssertNil(result.events[2].data?.base64Omitted)
        XCTAssertEqual(try export(note(events: [event(unknownBytes), event(unknownBytes), event(unknownBytes)]),
                                  limits: CollaborationActivityLimits(inlineBudgetBytes: 14)).events[2].data?.base64Omitted, .outputBudget)
    }

    func testDeepJSONIsRawOnly() throws {
        let deep = Data((String(repeating: "[", count: 40) + String(repeating: "]", count: 40)).utf8)
        let payload = try XCTUnwrap(try export(note(events: [event(deep)])).events.first?.data)
        XCTAssertEqual(payload.decodeStatus, .tooDeep)
        XCTAssertNil(payload.json)
        XCTAssertNotNil(payload.base64)
    }

    func testEventLimitValidation() throws {
        XCTAssertEqual(try CollaborationActivityLimits.events(nil).eventLimit, 100)
        XCTAssertEqual(try CollaborationActivityLimits.events(500).eventLimit, 500)
        for bad in [0, 501] {
            XCTAssertThrowsError(try CollaborationActivityLimits.events(bad)) { error in
                XCTAssertEqual((error as? NotesError)?.code, "invalid_limit")
            }
        }
    }

    func testSerializationIsStable() throws {
        let result = try export(note(events: [event(jsonBytes)]),
                                limits: CollaborationActivityLimits(eventLimit: 1, inlineBlobBytes: 0, inlinePayloadBytes: 64, inlineBudgetBytes: 64))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(result), second = try encoder.encode(result)
        XCTAssertEqual(first, second)
        XCTAssertEqual(String(decoding: first, as: UTF8.self), #"""
        {"blob":{"base64Omitted":"too_large","byteCount":6,"decodeStatus":"not_attempted","sha256":"1afc73e07986a0444e7c0c6597933b433f4ecd86863ae4754be1cbadbdbc4a53"},"events":[{"data":{"base64":"eyJiIjpbMSx0cnVlLG51bGxdLCJhIjoieCIsIm4iOjEuNX0=","byteCount":35,"decodeStatus":"json","json":{"a":"x","b":[1,true,null],"n":1.5},"sha256":"d16e4b201452ae81adbc3b2240ce54a75eb1597a1a35f8edde10ae7d28265b42"},"index":0,"runtimeClass":"ICCloudSyncingObjectActivityEvent"}],"limits":{"eventLimit":1,"inlineBlobBytes":0,"inlineBudgetBytes":64,"inlinePayloadBytes":64},"noteID":"NOTE-1","status":"decoded","title":"Shared","totalEventCount":1,"truncated":false}
        """#)
        XCTAssertEqual(try JSONDecoder().decode(CollaborationActivityExport.self, from: first), result)
    }

    func testReaderUsesOnlyListedGetters() throws {
        let log = AccessLog()
        _ = try export(note(events: [event(jsonBytes, fallback: unknownBytes), FakeObject("Odd")], future: 1), log: log)
        XCTAssertEqual(Set(log.keys), CollaborationActivityRuntimeReader.readKeys)
        let mutating = ["set", "persist", "remove", "merge", "add", "insert", "delete", "save", "update", "realize"]
        for key in CollaborationActivityRuntimeReader.readKeys {
            XCTAssertFalse(mutating.contains { key.hasPrefix($0) }, key)
        }
    }
}
