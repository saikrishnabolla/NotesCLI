import CryptoKit
import Compression
import Darwin
import Foundation
import NotesCore
import NotesNativeObjC
import UniformTypeIdentifiers

public enum AttachmentMarkupAnnotationKind: String, Codable, Sendable, CaseIterable {
    case text, rectangle, oval, arrow, line, ink, highlight
}

public struct AttachmentMarkupAnnotation: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var page: Int
    public var index: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var text: String?

    public init(id: String, type: String, page: Int, index: Int, x: Double, y: Double,
                width: Double, height: Double, text: String? = nil) {
        self.id = id; self.type = type; self.page = page; self.index = index
        self.x = x; self.y = y; self.width = width; self.height = height; self.text = text
    }
}

public struct AttachmentMarkupAnnotationInput: Sendable, Equatable {
    public var kind: AttachmentMarkupAnnotationKind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var text: String?
    public var points: [ScanPoint]
    public var strokeWidth: Double
    public var color: String

    public init(kind: AttachmentMarkupAnnotationKind, x: Double = 0, y: Double = 0,
                width: Double = 0, height: Double = 0, text: String? = nil,
                points: [ScanPoint] = [], strokeWidth: Double = 2,
                color: String = "007aff") {
        self.kind = kind; self.x = x; self.y = y; self.width = width; self.height = height
        self.text = text; self.points = points; self.strokeWidth = strokeWidth; self.color = color
    }

    public func validate() throws {
        let values = [x, y, width, height, strokeWidth] + points.flatMap { [$0.x, $0.y] }
        guard values.allSatisfy(\.isFinite), x >= 0, y >= 0, width >= 0, height >= 0,
              strokeWidth > 0, strokeWidth <= 1_000 else {
            throw NotesError("invalid_markup_geometry", "Markup geometry must be finite and nonnegative, with a positive stroke width.")
        }
        if kind == .ink, points.count < 2 {
            throw NotesError("invalid_markup_geometry", "Ink annotations require at least two x,y points.")
        }
        if kind != .ink, (width <= 0 || height <= 0) {
            throw NotesError("invalid_markup_geometry", "This annotation requires positive width and height.")
        }
        if kind == .text, text?.isEmpty != false {
            throw NotesError("invalid_markup_text", "Text annotations require nonempty text.")
        }
        let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard [6, 8].contains(hex.count), UInt64(hex, radix: 16) != nil else {
            throw NotesError("invalid_markup_color", "Markup color must be an RRGGBB or RRGGBBAA hex value.")
        }
    }
}

public enum AttachmentMarkupArchive {
    public static func adding(_ input: AttachmentMarkupAnnotationInput, to data: Data?) throws -> FrozenAttachmentMarkup {
        try input.validate()
        let points = input.points.flatMap { [NSNumber(value: $0.x), NSNumber(value: $0.y)] }
        do {
            let result = try NCNotesRuntime.attachmentMarkupData(
                adding: input.kind.rawValue, data: data, x: input.x, y: input.y,
                width: input.width, height: input.height, text: input.text,
                points: points, strokeWidth: input.strokeWidth, color: input.color
            )
            return try FrozenAttachmentMarkup(data: result)
        } catch { throw NotesError("markup_annotation_failed", error.localizedDescription) }
    }

    public static func annotations(in data: Data) throws -> [AttachmentMarkupAnnotation] {
        let values: [[String: Any]]
        do { values = try NCNotesRuntime.attachmentMarkupAnnotations(data: data) }
        catch { throw NotesError("markup_annotation_failed", error.localizedDescription) }
        return try values.map { value in
            guard let id = value["id"] as? String, let type = value["type"] as? String,
                  let page = (value["page"] as? NSNumber)?.intValue,
                  let index = (value["index"] as? NSNumber)?.intValue,
                  let x = (value["x"] as? NSNumber)?.doubleValue,
                  let y = (value["y"] as? NSNumber)?.doubleValue,
                  let width = (value["width"] as? NSNumber)?.doubleValue,
                  let height = (value["height"] as? NSNumber)?.doubleValue else {
                throw NotesError("invalid_attachment_markup", "MarkupUI returned incomplete annotation metadata.")
            }
            return AttachmentMarkupAnnotation(id: id, type: type, page: page, index: index,
                                              x: x, y: y, width: width, height: height,
                                              text: value["text"] as? String)
        }
    }

    public static func removing(_ identifier: String, from data: Data) throws -> FrozenAttachmentMarkup? {
        guard !identifier.isEmpty else { throw NotesError("invalid_markup_annotation_id", "Annotation ID cannot be empty.") }
        do {
            let result = try NCNotesRuntime.attachmentMarkupData(removing: identifier, data: data)
            return result.isEmpty ? nil : try FrozenAttachmentMarkup(data: result)
        } catch { throw NotesError("markup_annotation_failed", error.localizedDescription) }
    }

    public static func renderedPNG(data: Data, baseImageURL: URL) throws -> Data {
        do { return try NCNotesRuntime.renderAttachmentMarkup(data: data, baseImageURL: baseImageURL) }
        catch { throw NotesError("markup_render_failed", error.localizedDescription) }
    }

    public static func imageData(embedding data: Data?, baseImageURL: URL) throws -> Data {
        do { return try NCNotesRuntime.attachmentImageData(embedding: data, baseImageURL: baseImageURL) }
        catch { throw NotesError("markup_embed_failed", error.localizedDescription) }
    }

    public static func embeddedData(at imageURL: URL) throws -> Data {
        do { return try NCNotesRuntime.embeddedAttachmentMarkupData(at: imageURL) }
        catch { throw NotesError("attachment_markup_not_found", error.localizedDescription) }
    }
}

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
        (try? AttachmentMarkupArchiveValidator.validate(data, maximumBytes: maximumBytes)) != nil
    }
}

private enum AttachmentMarkupArchiveValidator {
    private static let maximumObjects = 100_000
    private static let maximumDepth = 64
    private static let xzMagic: [UInt8] = [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]

    static func validate(_ data: Data, maximumBytes: Int) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw InvalidArchive() }
        let outer = try KeyedArchive(data: data)
        try outer.validateGraph(rootKey: "AKComprArchiveRoot")
        let root = try outer.rootDictionary(
            key: "AKComprArchiveRoot", classes: Set(["NSDictionary", "NSMutableDictionary"])
        )
        let entries = try outer.dictionaryEntries(root)
        guard entries.count == 2,
              let size = entries["AKComprSizeKey"] as? NSNumber,
              size.int64Value > 0, size.int64Value <= maximumBytes,
              let compressed = entries["AKComprDataKey"] as? Data,
              compressed.count <= maximumBytes,
              compressed.starts(with: xzMagic) else { throw InvalidArchive() }

        let decoded = try decompress(compressed, expectedBytes: size.intValue, maximumBytes: maximumBytes)
        let archivePayloads = try dataPayloads(in: decoded, rootKey: "AKArchiveRoot")
        guard !archivePayloads.isEmpty else { throw InvalidArchive() }
        var annotationCount = 0
        for payload in archivePayloads {
            let annotationPayloads = try dataPayloads(in: payload, rootKey: "root")
            guard !annotationPayloads.isEmpty else { throw InvalidArchive() }
            for annotation in annotationPayloads {
                let archive = try KeyedArchive(data: annotation)
                try archive.validateGraph(rootKey: "root")
                let record = try archive.rootDictionary(key: "root")
                let descriptor = try archive.classDescriptor(of: record)
                guard descriptor.name.hasPrefix("AK"), descriptor.name.hasSuffix("Annotation"),
                      descriptor.classes.contains("AKAnnotation"),
                      descriptor.classes.last == "NSObject" else { throw InvalidArchive() }
                annotationCount += 1
                guard annotationCount <= maximumObjects else { throw InvalidArchive() }
            }
        }
        guard annotationCount > 0 else { throw InvalidArchive() }
    }

    private static func dataPayloads(in data: Data, rootKey: String) throws -> [Data] {
        let archive = try KeyedArchive(data: data)
        try archive.validateGraph(rootKey: rootKey)
        let root = try archive.rootDictionary(key: rootKey, classes: Set(["NSArray", "NSMutableArray"]))
        let values = try archive.arrayValues(root)
        guard !values.isEmpty, values.count <= maximumObjects else { throw InvalidArchive() }
        return try values.map { value in
            guard let record = try archive.resolve(value) as? [String: Any] else { throw InvalidArchive() }
            let descriptor = try archive.classDescriptor(of: record)
            guard ["NSData", "NSMutableData"].contains(descriptor.name),
                  let payload = try archive.resolve(record["NS.data"] as Any) as? Data,
                  !payload.isEmpty else { throw InvalidArchive() }
            return payload
        }
    }

    private static func decompress(_ data: Data, expectedBytes: Int, maximumBytes: Int) throws -> Data {
        guard expectedBytes > 0, expectedBytes <= maximumBytes else { throw InvalidArchive() }
        var output = [UInt8](repeating: 0, count: expectedBytes + 1)
        let result: (compression_status, Int, Int) = try data.withUnsafeBytes { source in
            try output.withUnsafeMutableBytes { destination in
                var stream = compression_stream(
                    dst_ptr: destination.bindMemory(to: UInt8.self).baseAddress!, dst_size: destination.count,
                    src_ptr: source.bindMemory(to: UInt8.self).baseAddress!, src_size: source.count,
                    state: nil
                )
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) != COMPRESSION_STATUS_ERROR else {
                    throw InvalidArchive()
                }
                defer { compression_stream_destroy(&stream) }
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                return (status, source.count - stream.src_size, destination.count - stream.dst_size)
            }
        }
        guard result.0 == COMPRESSION_STATUS_END,
              result.1 == data.count,
              result.2 == expectedBytes else { throw InvalidArchive() }
        return Data(output.prefix(expectedBytes))
    }

    private struct ClassDescriptor {
        var name: String
        var classes: [String]
    }

    private struct KeyedArchive {
        let objects: [Any]
        let top: [String: Any]

        init(data: Data) throws {
            guard data.count <= FrozenAttachmentMarkup.maximumBytes else { throw InvalidArchive() }
            let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let root = propertyList as? [String: Any],
                  root["$archiver"] as? String == "NSKeyedArchiver",
                  (root["$version"] as? NSNumber)?.intValue == 100_000,
                  let top = root["$top"] as? [String: Any], top.count == 1 else { throw InvalidArchive() }
            guard let objects = root["$objects"] as? [Any],
                  (2...maximumObjects).contains(objects.count),
                  objects.first as? String == "$null" else { throw InvalidArchive() }
            self.objects = objects
            self.top = top
        }

        func rootDictionary(key: String, classes: Set<String>? = nil) throws -> [String: Any] {
            guard top.count == 1, let value = top[key],
                  let root = try resolve(value) as? [String: Any] else { throw InvalidArchive() }
            if let classes {
                guard classes.contains(try classDescriptor(of: root).name) else { throw InvalidArchive() }
            }
            return root
        }

        func classDescriptor(of record: [String: Any]) throws -> ClassDescriptor {
            guard let reference = record["$class"],
                  let descriptor = try resolve(reference) as? [String: Any],
                  let name = descriptor["$classname"] as? String,
                  let classes = descriptor["$classes"] as? [String],
                  !name.isEmpty, !classes.isEmpty, classes.first == name else { throw InvalidArchive() }
            return ClassDescriptor(name: name, classes: classes)
        }

        func dictionaryEntries(_ record: [String: Any]) throws -> [String: Any] {
            let descriptor = try classDescriptor(of: record)
            guard ["NSDictionary", "NSMutableDictionary"].contains(descriptor.name),
                  let keys = record["NS.keys"] as? [Any],
                  let values = record["NS.objects"] as? [Any],
                  keys.count == values.count else { throw InvalidArchive() }
            var result: [String: Any] = [:]
            for (keyReference, valueReference) in zip(keys, values) {
                guard let key = try resolve(keyReference) as? String,
                      result[key] == nil else { throw InvalidArchive() }
                result[key] = try resolve(valueReference)
            }
            return result
        }

        func arrayValues(_ record: [String: Any]) throws -> [Any] {
            let descriptor = try classDescriptor(of: record)
            guard ["NSArray", "NSMutableArray"].contains(descriptor.name),
                  let values = record["NS.objects"] as? [Any] else { throw InvalidArchive() }
            return values
        }

        func resolve(_ value: Any) throws -> Any {
            guard let index = UID.value(value) else { return value }
            guard objects.indices.contains(index), index > 0 else { throw InvalidArchive() }
            return objects[index]
        }

        func validateGraph(rootKey: String) throws {
            guard let root = top[rootKey], top.count == 1,
                  UID.value(root) != nil else { throw InvalidArchive() }
            var visited = Set<Int>()
            var active = Set<Int>()
            var traversed = 0
            try visit(root, depth: 0, visited: &visited, active: &active, traversed: &traversed)
            guard visited == Set(objects.indices.dropFirst()) else { throw InvalidArchive() }
        }

        private func visit(_ value: Any, depth: Int, visited: inout Set<Int>,
                           active: inout Set<Int>, traversed: inout Int) throws {
            guard depth <= maximumDepth else { throw InvalidArchive() }
            traversed += 1
            guard traversed <= maximumObjects * 16 else { throw InvalidArchive() }
            if let index = UID.value(value) {
                guard objects.indices.contains(index) else { throw InvalidArchive() }
                if index == 0 { return }
                guard index > 0,
                      !active.contains(index) else { throw InvalidArchive() }
                if visited.contains(index) { return }
                active.insert(index)
                try visit(objects[index], depth: depth + 1, visited: &visited, active: &active, traversed: &traversed)
                active.remove(index)
                visited.insert(index)
                return
            }
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    guard !key.isEmpty else { throw InvalidArchive() }
                    try visit(child, depth: depth + 1, visited: &visited, active: &active, traversed: &traversed)
                }
                return
            }
            if let array = value as? [Any] {
                for child in array {
                    try visit(child, depth: depth + 1, visited: &visited, active: &active, traversed: &traversed)
                }
                return
            }
            guard value is String || value is NSNumber || value is Data || value is Date else {
                throw InvalidArchive()
            }
        }
    }

    private enum UID {
        private typealias GetTypeID = @convention(c) () -> CFTypeID
        private typealias GetValue = @convention(c) (CFTypeRef) -> UInt32
        private static let symbols: (CFTypeID, GetValue)? = {
            let handle = UnsafeMutableRawPointer(bitPattern: -2)
            guard let typeSymbol = dlsym(handle, "_CFKeyedArchiverUIDGetTypeID"),
                  let valueSymbol = dlsym(handle, "_CFKeyedArchiverUIDGetValue") else { return nil }
            let type = unsafeBitCast(typeSymbol, to: GetTypeID.self)()
            let value = unsafeBitCast(valueSymbol, to: GetValue.self)
            return (type, value)
        }()

        static func value(_ object: Any) -> Int? {
            guard let symbols else { return nil }
            let reference = object as CFTypeRef
            guard CFGetTypeID(reference) == symbols.0 else { return nil }
            return Int(symbols.1(reference))
        }
    }

    private struct InvalidArchive: Error {}
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

    static func embedsInMedia(_ typeUTI: String) -> Bool {
        UTType(typeUTI)?.conforms(to: .image) == true
    }
}
