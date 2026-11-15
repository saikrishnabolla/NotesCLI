import Foundation
import XCTest
import NotesCore
@testable import NotesNative

final class NativeWriteLeaseTests: XCTestCase {
    func testRejectsSymlinkLockFile() throws {
        let directory = temporaryDirectory()
        let targetDirectory = temporaryDirectory()
        let target = targetDirectory.appendingPathComponent("target")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: targetDirectory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("native-write.lock"),
            withDestinationURL: target
        )

        XCTAssertThrowsError(try NativeWriteLease.acquire(directory: directory, timeout: 0.1)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "native_write_lock_failed")
        }
    }

    func testRejectsSymlinkDirectoryWithoutChangingItsTarget() throws {
        let parent = temporaryDirectory()
        let target = temporaryDirectory()
        let link = parent.appendingPathComponent("NotesCLI", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try NativeWriteLease.acquire(directory: link, timeout: 0.1)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "native_write_lock_failed")
        }
        XCTAssertEqual(permissions(target), 0o755)
    }

    func testSecondLeaseTimesOut() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try NativeWriteLease.acquire(directory: directory, timeout: 0.1)
        defer { first.release() }

        XCTAssertThrowsError(try NativeWriteLease.acquire(directory: directory, timeout: 0.05)) { error in
            XCTAssertEqual((error as? NotesError)?.code, "native_write_busy")
        }
    }

    func testLeaseCorrectsDirectoryAndFilePermissions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
        let lock = directory.appendingPathComponent("native-write.lock")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: lock.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o666]
        ))

        let lease = try NativeWriteLease.acquire(directory: directory, timeout: 0.1)
        defer { lease.release() }
        XCTAssertEqual(permissions(directory), 0o700)
        XCTAssertEqual(permissions(lock), 0o600)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func permissions(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
