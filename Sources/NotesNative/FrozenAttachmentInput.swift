import CryptoKit
import Foundation
import NotesCore

public final class FrozenAttachmentInput: @unchecked Sendable {
    public let url: URL
    public let sourceName: String
    public let sha256: String
    public let byteCount: Int
    private let directory: URL

    public static let maxBytes = 200 * 1024 * 1024

    public convenience init(file source: URL) throws {
        let resolved = try InputFile.validated(source, kind: "attachment", maxBytes: Self.maxBytes)
        let data = try InputFile.read(resolved, kind: "attachment", maxBytes: Self.maxBytes)
        try self.init(data: data, suggestedName: resolved.lastPathComponent)
    }

    public init(data: Data, suggestedName: String) throws {
        guard !data.isEmpty else { throw NotesError("empty_attachment", "The attachment has no bytes.") }
        guard data.count <= Self.maxBytes else { throw NotesError("attachment_too_large", "Attachments are limited to 200 MB.") }
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
            self.sha256 = Self.hash(data)
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

    public static func hash(file: URL) throws -> String {
        hash(try Data(contentsOf: file, options: .mappedIfSafe))
    }

    private static func safeName(_ name: String) -> String {
        let value = URL(fileURLWithPath: name).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "." || value == ".." ? "attachment.bin" : value
    }
}
