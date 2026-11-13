import Foundation
import XCTest
@testable import NotesAutomation

private nonisolated(unsafe) var observedThrows = 0

final class ProtectedFoldersTests: XCTestCase {
    private func makeFramework(locales: [String: String], emptyLocaleDirectories: [String]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("NotesShared.framework/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.NotesShared"], format: .xml, options: 0)
        try info.write(to: resources.appendingPathComponent("Info.plist"))
        let table = locales.mapValues { ["Recently Deleted": $0] }
        let data = try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
        try data.write(to: resources.appendingPathComponent("Localizable.loctable"))
        for locale in emptyLocaleDirectories {
            try FileManager.default.createDirectory(at: resources.appendingPathComponent(locale + ".lproj"), withIntermediateDirectories: true)
        }
        return try XCTUnwrap(Bundle(path: root.appendingPathComponent("NotesShared.framework").path))
    }

    /// Counts every Swift error raised inside `body`, including ones a `try?` swallows.
    /// Test runners such as XCTest observe the same hook and can report a swallowed error.
    private func countThrows<T>(_ body: () -> T) throws -> (T, Int) {
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_swift_willThrow"))
        typealias Hook = @convention(c) (UnsafeMutableRawPointer?) -> Void
        let hook = symbol.assumingMemoryBound(to: Optional<Hook>.self)
        let previous = hook.pointee
        observedThrows = 0
        hook.pointee = { _ in observedThrows += 1 }
        defer { hook.pointee = previous }
        let value = body()
        return (value, observedThrows)
    }

    func testLocaleDirectoryWithoutStringsFileRaisesNoErrorAndKeepsTableNames() throws {
        let bundle = try makeFramework(locales: ["en": "Recently Deleted", "ca": "Eliminades fa poc"],
                                       emptyLocaleDirectories: ["ca", "en"])
        let (names, throwsSeen) = try countThrows { ProtectedFolders.loadNames(from: bundle) }
        XCTAssertEqual(throwsSeen, 0)
        XCTAssertEqual(names, ["Eliminades fa poc", "Recently Deleted", "Trash"])
    }

    func testLocaleStringsFileStillAddsItsName() throws {
        let bundle = try makeFramework(locales: ["en": "Recently Deleted"], emptyLocaleDirectories: ["fr"])
        let strings = try XCTUnwrap(bundle.resourceURL).appendingPathComponent("fr.lproj/Localizable.strings")
        try #""Recently Deleted" = "Suppr. récentes";"#.write(to: strings, atomically: true, encoding: .utf16)
        XCTAssertEqual(ProtectedFolders.loadNames(from: bundle), ["Recently Deleted", "Suppr. récentes", "Trash"])
    }

    func testInstalledNotesFrameworkLoadsWithoutRaisingErrors() throws {
        let bundle = Bundle(path: "/System/Library/PrivateFrameworks/NotesShared.framework")
        let (names, throwsSeen) = try countThrows { ProtectedFolders.loadNames(from: bundle) }
        XCTAssertEqual(throwsSeen, 0)
        XCTAssertTrue(try XCTUnwrap(names).contains("Recently Deleted"))
    }
}
