import Foundation
import XCTest
@testable import notescli

final class EditorDiagnosticsTests: XCTestCase {
    func testLocalExportOmitsStaleEventsAndFilesWithContent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = EditorDiagnostics(directory: root)
        defer { try? fm.removeItem(at: root) }
        XCTAssertTrue(try log.report().events.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: root.path))

        try log.record(.invalidConfiguration)
        try log.record(.invalidConfiguration)
        try log.record(.shortcutRegistrationFailed)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86_400)],
                             ofItemAtPath: root.appendingPathComponent("shortcutRegistrationFailed").path)
        try Data("never export this".utf8).write(to: root.appendingPathComponent("searchLoadFailed"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("clipboardRestoreFailed"),
                                  withDestinationURL: root.appendingPathComponent("invalidConfiguration"))
        XCTAssertEqual(try log.report().events.map(\.event), [.invalidConfiguration])
        let attributes = try fm.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testExportRefusesAWorldReadableDiagnosticsFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? fm.removeItem(at: root) }
        let log = EditorDiagnostics(directory: root)
        XCTAssertThrowsError(try log.record(.invalidConfiguration))
        XCTAssertThrowsError(try log.report())
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
