import Foundation
import XCTest
import NotesCore
import NotesStore
@testable import NotesIndex

final class NotesIndexTests: XCTestCase {
    func testIncrementalBooleanFieldAndTypoSearch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notes-index-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = LocalNotesIndex(url: directory.appendingPathComponent("index.sqlite"))
        let sample = InMemoryNotes.sample()
        let welcome = try sample.note("welcome")
        var shopping = try sample.note("shopping")
        shopping.attachments = [Attachment(id: "image", typeUTI: "public.png", ocrText: "receipt")]
        shopping.summary.attachmentCount = 1
        let reader = InMemoryNotes(accounts: try sample.accounts(), folders: try sample.folders(account: nil), notes: [welcome, shopping])
        let first = try index.update(from: reader, rebuild: true)
        XCTAssertEqual(first.noteCount, 2)
        XCTAssertGreaterThan(first.fileSize, 4_096)
        let fileMode = try XCTUnwrap((FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("index.sqlite").path)[.posixPermissions] as? NSNumber)?.intValue)
        let directoryMode = try XCTUnwrap((FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(try index.update(from: reader).noteCount, 2)
        XCTAssertEqual(try index.search("title:Welcome AND tag:demo").map(\.noteID), ["welcome"])
        XCTAssertEqual(try index.search("(coffee OR bread) NOT title:Welcome").map(\.noteID), ["shopping"])
        XCTAssertEqual(try index.search("has:attachment AND has:image").map(\.noteID), ["shopping"])
        XCTAssertEqual(try index.search("coffee", folder: "Notes").map(\.noteID), ["shopping"])
        XCTAssertTrue(try index.search("coffee", folder: "Missing").isEmpty)
        XCTAssertEqual(try index.search("Welcom").first?.noteID, "welcome")
        XCTAssertEqual(try index.search("Aples cofee").first?.noteID, "shopping")
        XCTAssertFalse(try index.search("\"Apples, coffee\"").first?.highlights.isEmpty ?? true)
    }

    func testLiveIndexCountsAndTiming() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_TESTS"] == "1" else { throw XCTSkip("Set NOTESCLI_LIVE_TESTS=1 for read-only library verification") }
        let reader = try SQLiteNotesStore(refresh: true), index = LocalNotesIndex()
        let started = Date(), status = try index.update(from: reader, rebuild: true), buildSeconds = Date().timeIntervalSince(started)
        let queryStart = Date(), hits = try index.search("pinned:true OR locked:true", limit: 500), querySeconds = Date().timeIntervalSince(queryStart)
        print("NOTESCLI_INDEX notes=\(status.noteCount) bytes=\(status.fileSize) build_seconds=\(buildSeconds) query_seconds=\(querySeconds) shape_hits=\(hits.count)")
        XCTAssertGreaterThan(status.noteCount, 0)
        XCTAssertGreaterThan(status.fileSize, 0)
        XCTAssertLessThanOrEqual(hits.count, status.noteCount)
    }
}
