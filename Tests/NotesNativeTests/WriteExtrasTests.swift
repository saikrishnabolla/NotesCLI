import Foundation
import XCTest
@testable import NotesNative

final class WriteExtrasTests: XCTestCase {
    func testFrozenAttachmentKeepsOriginalBytesAndPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-frozen-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.txt")
        try Data("original".utf8).write(to: source)

        let frozen = try FrozenAttachmentInput(file: source)
        try Data("changed".utf8).write(to: source)

        XCTAssertEqual(try Data(contentsOf: frozen.url), Data("original".utf8))
        XCTAssertEqual(frozen.sha256, "0682c5f2076f099c34cfdd15a9e063849ed437a49677e6fcc5b4198c76575be5")
        XCTAssertEqual(frozen.byteCount, 8)
        let directoryMode = try XCTUnwrap((FileManager.default.attributesOfItem(atPath: frozen.url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue)
        let fileMode = try XCTUnwrap((FileManager.default.attributesOfItem(atPath: frozen.url.path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
    }

    func testFrozenAttachmentCanOwnPasteboardBytes() throws {
        let frozen = try FrozenAttachmentInput(data: Data("pasteboard-bytes".utf8), suggestedName: "pasteboard.txt")
        XCTAssertEqual(frozen.sourceName, "pasteboard.txt")
        XCTAssertEqual(frozen.sha256, "0d849d064eeebde66da1b26d566193b38399f4035aba859eda4722c15c7fc84a")
        XCTAssertEqual(try Data(contentsOf: frozen.url), Data("pasteboard-bytes".utf8))
    }
}
