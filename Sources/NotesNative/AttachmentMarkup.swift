import CryptoKit
import Darwin
import Foundation
import NotesCore
import UniformTypeIdentifiers

public struct FrozenAttachmentMarkup: Sendable {
    public static let maximumBytes = 50 * 1024 * 1024

    public let data: Data
    public let byteCount: Int
    public let sha256: String

    public init(file: URL) throws {
        let data = try InputFile.read(file, kind: "attachment markup", maxBytes: Self.maximumBytes)
        try self.init(data: data)
    }

    public init(data: Data) throws {
        guard !data.isEmpty else {
            throw NotesError("empty_attachment_markup", "Attachment markup data cannot be empty.")
        }
        guard data.count <= Self.maximumBytes else {
            throw NotesError("attachment_markup_too_large", "Attachment markup is limited to 50 MB.")
        }
        guard Self.isKnownArchive(data) else {
            throw NotesError("unknown_attachment_markup", "The file is not a recognized Apple Notes editable markup archive.")
        }
        self.data = data
        self.byteCount = data.count
        self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func isKnownArchive(_ data: Data) -> Bool {
        guard data.count <= maximumBytes,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["$archiver"] as? String == "NSKeyedArchiver",
              (root["$version"] as? NSNumber)?.intValue == 100_000,
              let top = root["$top"] as? [String: Any],
              top["AKComprArchiveRoot"] != nil,
              let objects = root["$objects"] as? [Any],
              objects.contains(where: { $0 as? String == "AKComprSizeKey" }),
              objects.contains(where: { $0 as? String == "AKComprDataKey" }),
              objects.contains(where: {
                  guard let size = $0 as? NSNumber else { return false }
                  return size.intValue > 0 && size.intValue <= maximumBytes
              }),
              let compressed = objects.compactMap({ $0 as? Data }).first,
              compressed.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) else { return false }
        return true
    }
}

public struct NativeAttachmentMarkupMetadata: Codable, Sendable, Equatable {
    public var noteID: String
    public var attachmentID: String
    public var typeUTI: String
    public var hasMarkup: Bool
    public var byteCount: Int
    public var sha256: String?
    public var embedded: Bool
    public var recognized: Bool

    public init(noteID: String, attachmentID: String, typeUTI: String, hasMarkup: Bool,
                byteCount: Int, sha256: String?, embedded: Bool, recognized: Bool) {
        self.noteID = noteID
        self.attachmentID = attachmentID
        self.typeUTI = typeUTI
        self.hasMarkup = hasMarkup
        self.byteCount = byteCount
        self.sha256 = sha256
        self.embedded = embedded
        self.recognized = recognized
    }
}

public struct NativeAttachmentMarkupExport: Sendable {
    public var metadata: NativeAttachmentMarkupMetadata
    public var data: Data

    public init(metadata: NativeAttachmentMarkupMetadata, data: Data) {
        self.metadata = metadata
        self.data = data
    }

    @discardableResult
    public func write(to output: URL) throws -> URL {
        let target = output.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw NotesError("file_exists", "Refusing to replace an existing markup file.")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                                     S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw NotesError("file_exists", "Refusing to replace an existing markup file.") }
            throw NotesError("markup_export_failed", "Could not create the markup file: \(String(cString: strerror(errno))).")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: target)
            throw NotesError("markup_export_failed", "Could not export attachment markup: \(error.localizedDescription)")
        }
        return target
    }
}

enum AttachmentMarkupPolicy {
    static func supports(_ typeUTI: String) -> Bool {
        guard let type = UTType(typeUTI) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }
}
