import CryptoKit
import Foundation
import NotesCore

public final class FrozenAttachmentInput: @unchecked Sendable {
    public let url: URL
    public let sourceName: String
    public let sha256: String
    public let byteCount: Int
    private let directory: URL

    public static let maxBytes = 512 * 1024 * 1024

    public init(file source: URL) throws {
        let resolved = try InputFile.validated(source, kind: "attachment", maxBytes: Self.maxBytes)
        guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw NotesError("invalid_file", "The attachment must be a regular file.")
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("notescli-attachment-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let name = Self.safeName(resolved.lastPathComponent)
        let url = directory.appendingPathComponent(name)
        do {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw NotesError("attachment_freeze_failed", "Could not create a private copy of the attachment.")
            }
            let input = try InputFile.openRegularSource(resolved, kind: "attachment", maxBytes: Self.maxBytes)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            var count = 0
            var hash = SHA256()
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                count += chunk.count
                guard count <= Self.maxBytes else { throw Self.tooLarge() }
                hash.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            guard count > 0 else { throw NotesError("empty_attachment", "The attachment has no bytes.") }
            try output.synchronize()
            self.directory = directory
            self.url = url
            self.sourceName = name
            self.sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
            self.byteCount = count
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    public convenience init(data: Data, suggestedName: String) throws {
        try self.init(data: data, suggestedName: suggestedName, verifiedSHA256: nil)
    }

    convenience init(notesFile source: URL) throws {
        let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw NotesError("scan_page_image_unavailable", "The scanned page image is unavailable.")
        }
        guard values.isRegularFile == true, let size = values.fileSize, size <= Self.maxBytes else {
            throw NotesError("scan_page_image_unavailable", "The scanned page image is unavailable or too large.")
        }
        let data: Data
        do { data = try Data(contentsOf: resolved, options: .mappedIfSafe) }
        catch { throw NotesError("scan_page_image_unavailable", "The scanned page image could not be read.") }
        guard data.count <= Self.maxBytes else {
            throw NotesError("scan_page_image_unavailable", "The scanned page image is too large.")
        }
        try self.init(data: data, suggestedName: resolved.lastPathComponent, verifiedSHA256: nil)
    }

    convenience init(verifiedData data: Data, suggestedName: String, sha256: String) throws {
        try self.init(data: data, suggestedName: suggestedName, verifiedSHA256: sha256)
    }

    private init(data: Data, suggestedName: String, verifiedSHA256: String?) throws {
        guard !data.isEmpty else { throw NotesError("empty_attachment", "The attachment has no bytes.") }
        guard data.count <= Self.maxBytes else { throw Self.tooLarge() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("notescli-attachment-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let name = Self.safeName(suggestedName)
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard fileManager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw NotesError("attachment_freeze_failed", "Could not create the private attachment copy.")
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            self.directory = directory
            self.url = url
            self.sourceName = name
            self.sha256 = verifiedSHA256 ?? Self.hash(data)
            self.byteCount = data.count
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(file: URL, maxBytes: Int? = nil) throws -> String {
        let input = try maxBytes.map { try InputFile.openRegularSource(file, kind: "attachment", maxBytes: $0) }
            ?? FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        var count = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            count += chunk.count
            if let maxBytes, count > maxBytes { throw tooLarge() }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func tooLarge() -> NotesError {
        NotesError("attachment_too_large", "Attachments are limited to \(InputFile.byteText(maxBytes)).")
    }

    private static func safeName(_ name: String) -> String {
        let value = URL(fileURLWithPath: name).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "." || value == ".." ? "attachment.bin" : value
    }
}
