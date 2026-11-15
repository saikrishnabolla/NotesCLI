import Foundation
import NotesCore
import Darwin

struct LockedAttachmentResult {
    var row: StoreRow
    var filename: String?
    var filePath: String?
}

final class LockedAttachmentExtractionScope {
    let directory: URL
    private var cleaned = false

    init(fileManager: FileManager = .default) throws {
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("notescli-locked-attachments-" + UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    deinit { cleanup() }

    func write(_ data: Data, attachmentID: String, filename: String?) throws -> URL {
        let base = Self.safeComponent(attachmentID.isEmpty ? "attachment" : attachmentID)
        let ext = filename.map { URL(fileURLWithPath: $0).pathExtension }.flatMap { $0.isEmpty ? nil : $0 }
        let target = directory.appendingPathComponent(ext.map { base + "." + Self.safeComponent($0) } ?? base)
        guard FileManager.default.createFile(
            atPath: target.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw NotesError("locked_attachment_write_failed", "Cannot create the temporary attachment file.")
        }
        do {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw NotesError("locked_attachment_write_failed", "Cannot write the temporary attachment file.")
        }
    }

    func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        try? FileManager.default.removeItem(at: directory)
    }

    private static func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalar = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalar).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return result.isEmpty ? "attachment" : String(result.prefix(120))
    }
}

struct LockedAttachmentExtractor {
    let library: StoreLibrary
    let container: URL
    let accountID: String
    let password: String
    let scope: LockedAttachmentExtractionScope
    /// Verified V1-Neo main key from the owning note's body, if any.
    var noteMainKey: Data? = nil

    func extract(_ original: StoreRow) throws -> LockedAttachmentResult {
        try rejectUnappliedRecord(original)
        // Objects whose own password envelope opened, keyed by identifier.
        var sidecarOwners: [String: LockedNoteCrypto.NeoSidecarKeys] = [:]
        var row = try decryptedValues(in: original, owners: &sidecarOwners)
            .map { applying($0, to: original) } ?? original
        let media = row.int("ZMEDIA").flatMap { library.objects[$0] }
        if let media { try rejectUnappliedRecord(media) }
        let mediaValues = try media.flatMap { try decryptedValues(in: $0, owners: &sidecarOwners) }
        if let mediaValues { row = applying(mediaValues, to: row) }
        // Notes' parentEncryptableObject chain: media -> attachment -> note.
        let encryptableChain = [media, original].compactMap { $0 }
        let filename = mediaValues?["filename"] as? String ?? media?.string("ZFILENAME") ?? row.string("ZFILENAME")
        if let filename, !Self.safePathComponent(filename) {
            throw NotesError("locked_attachment_invalid", "The locked attachment filename is invalid.")
        }
        let choice = try fileChoice(row: row, media: media, filename: filename)
        guard let choice else { return LockedAttachmentResult(row: row, filename: filename, filePath: nil) }
        guard let (source, ciphertext) = try firstReadableFile(choice.candidates) else {
            throw NotesError(
                "locked_attachment_not_downloaded",
                "A locked attachment is not downloaded on this Mac.",
                hint: "Open the note in Notes, wait for the attachment to download, then retry.")
        }
        let plaintext: Data
        if ciphertext.starts(with: Data("bplist00".utf8)) {
            guard let expectedObjectIdentifier = choice.expectedObjectIdentifier else {
                throw NotesError("locked_attachment_invalid", "The locked attachment has no object identifier.")
            }
            plaintext = try openNeoEnvelope(
                ciphertext,
                expectedObjectIdentifier: expectedObjectIdentifier,
                sidecarKeys: sidecarKeys(
                    owner: expectedObjectIdentifier, chain: encryptableChain, verified: sidecarOwners),
                failureMessage: "A locked attachment could not be authenticated.")
        } else {
            guard let iv = choice.iv, let tag = choice.tag else {
                throw NotesError(
                    "locked_attachment_file_unsupported",
                    "A stored locked attachment has no supported file-encryption fields.")
            }
            do {
                plaintext = try LockedNoteCrypto.open(
                    password: password,
                    parameters: try parameters(
                        row: choice.cryptoRow, iv: iv, tag: tag, ciphertext: ciphertext),
                    allowEmptyCiphertext: true)
            } catch let error as NotesError where error.code == "wrong_password" {
                throw error
            } catch {
                throw NotesError(
                    "locked_attachment_decryption_failed",
                    "A locked attachment could not be authenticated.")
            }
        }
        let outputFilename = filename ?? Self.decryptedFilename(source.lastPathComponent)
        let path = try scope.write(
            plaintext,
            attachmentID: row.string("ZIDENTIFIER") ?? "attachment",
            filename: outputFilename)
        return LockedAttachmentResult(row: row, filename: outputFilename, filePath: path.path)
    }

    /// Mirrors Notes' strategy and key choice for a sidecar owner. The cipher
    /// version comes from the nearest object, starting at the owner, that has
    /// encrypted data (`ICCryptoStrategyFactory primaryEncryptedDataForObject:`).
    /// If that is the owner, only the key that opened its values works. If it
    /// is a parent, `cachedMainKeyForObject:` accepts that parent's verified
    /// key, because `mainKeyDecryptsPrimaryData:` returns YES for an owner
    /// with no wrapped key of its own. The chain is media, attachment, then
    /// the note body.
    private func sidecarKeys(owner identifier: String, chain: [StoreRow],
                             verified: [String: LockedNoteCrypto.NeoSidecarKeys]) -> LockedNoteCrypto.NeoSidecarKeys? {
        guard let start = chain.firstIndex(where: { $0.string("ZIDENTIFIER") == identifier }) else { return nil }
        for (offset, object) in chain[start...].enumerated() {
            guard Self.hasPrimaryEncryptedData(object) else { continue }
            guard let objectID = object.string("ZIDENTIFIER"), let keys = verified[objectID] else {
                // Legacy values select Notes' V1 strategy, whose sidecars are
                // raw tag, IV, and ciphertext, never cipher-3 envelopes.
                return nil
            }
            return offset == 0 ? keys : .init(mainKey: keys.mainKey, encryptedValues: nil)
        }
        return noteMainKey.map { .init(mainKey: $0, encryptedValues: nil) }
    }

    private static func hasPrimaryEncryptedData(_ row: StoreRow) -> Bool {
        row.data("ZENCRYPTEDVALUESJSON")?.isEmpty == false
    }

    private func rejectUnappliedRecord(_ row: StoreRow) throws {
        if row.data("ZUNAPPLIEDENCRYPTEDRECORDDATA", "ZUNAPPLIEDENCRYPTEDRECORD")?.isEmpty == false {
            throw NotesError(
                "locked_attachment_unapplied_record_unsupported",
                "This attachment has a pending encrypted CloudKit record that cannot be selected safely.")
        }
    }

    private func decryptedValues(in row: StoreRow,
                                 owners: inout [String: LockedNoteCrypto.NeoSidecarKeys]) throws -> [String: Any]? {
        guard let encrypted = row.data("ZENCRYPTEDVALUESJSON"), !encrypted.isEmpty else { return nil }
        let plaintext: Data
        var neoOwner: (identifier: String, mainKey: Data)?
        if encrypted.starts(with: Data("bplist00".utf8)) {
            guard let objectIdentifier = row.string("ZIDENTIFIER") else {
                throw NotesError("locked_attachment_invalid", "The locked attachment metadata has no object identifier.")
            }
            let opened = try mapNeoErrors("The locked attachment metadata could not be authenticated.") {
                try LockedNoteCrypto.openNeoEnvelopeVerifyingMainKey(
                    password: password,
                    data: encrypted,
                    expectedObjectIdentifier: objectIdentifier)
            }
            plaintext = opened.plaintext
            neoOwner = (objectIdentifier, opened.mainKey)
        } else {
            guard let iv = row.data("ZCRYPTOINITIALIZATIONVECTOR"),
                  let tag = row.data("ZCRYPTOTAG") else {
                throw NotesError(
                    "locked_attachment_invalid",
                    "The locked attachment metadata is missing encryption parameters.")
            }
            do {
                plaintext = try LockedNoteCrypto.open(
                    password: password,
                    parameters: try parameters(row: row, iv: iv, tag: tag, ciphertext: encrypted))
            } catch let error as NotesError where error.code == "wrong_password" {
                throw error
            } catch {
                throw NotesError(
                    "locked_attachment_decryption_failed",
                    "The locked attachment metadata could not be authenticated.")
            }
        }
        guard let values = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw NotesError("locked_attachment_invalid", "The locked attachment metadata is not valid JSON.")
        }
        if let neoOwner {
            owners[neoOwner.identifier] = .init(mainKey: neoOwner.mainKey, encryptedValues: values)
        }
        return values
    }

    private func applying(_ values: [String: Any], to original: StoreRow) -> StoreRow {
        var row = original
        let strings = [
            "filename": "ZFILENAME", "title": "ZTITLE", "fallbackTitle": "ZFALLBACKTITLE",
            "altText": "ZALTTEXT", "displayText": "ZDISPLAYTEXT", "urlString": "ZURLSTRING"
        ]
        for (json, column) in strings where values[json] is String { row.strings[column] = values[json] as? String }
        let blobs = [
            "mergeableData": "ZMERGEABLEDATA",
            "mergeableData1": "ZMERGEABLEDATA1",
            "markupModelData": "ZMARKUPMODELDATA",
            "linkPresentationArchivedMetadata": "ZLINKPRESENTATIONARCHIVEDMETADATA",
            "synapseData": "ZSYNAPSEDATA",
        ]
        for (json, column) in blobs {
            if let encoded = values[json] as? String, let data = Data(base64Encoded: encoded) { row.blobs[column] = data }
        }
        return row
    }

    private struct FileChoice {
        let cryptoRow: StoreRow
        let iv: Data?
        let tag: Data?
        let expectedObjectIdentifier: String?
        let candidates: [URL]
    }

    private func fileChoice(row: StoreRow, media: StoreRow?, filename: String?) throws -> FileChoice? {
        let assetIV = media?.data("ZASSETCRYPTOINITIALIZATIONVECTOR")
        let assetTag = media?.data("ZASSETCRYPTOTAG")
        if assetIV != nil || assetTag != nil {
            guard let media, let assetIV, let assetTag else {
                throw NotesError("locked_attachment_invalid", "The locked asset has incomplete encryption parameters.")
            }
            return FileChoice(
                              cryptoRow: media, iv: assetIV, tag: assetTag,
                              expectedObjectIdentifier: media.string("ZIDENTIFIER"),
                              candidates: assetCandidates(row: row, media: media, filename: filename))
        }
        let imageIV = row.data("ZFALLBACKIMAGECRYPTOINITIALIZATIONVECTOR")
        let imageTag = row.data("ZFALLBACKIMAGECRYPTOTAG")
        if imageIV != nil || imageTag != nil {
            guard let imageIV, let imageTag else {
                throw NotesError("locked_attachment_invalid", "The locked fallback image has incomplete encryption parameters.")
            }
            return FileChoice(
                              cryptoRow: row, iv: imageIV, tag: imageTag,
                              expectedObjectIdentifier: row.string("ZIDENTIFIER"),
                              candidates: fallbackImageCandidates(row: row))
        }
        let pdfIV = row.data("ZFALLBACKPDFCRYPTOINITIALIZATIONVECTOR")
        let pdfTag = row.data("ZFALLBACKPDFCRYPTOTAG")
        if pdfIV != nil || pdfTag != nil {
            guard let pdfIV, let pdfTag else {
                throw NotesError("locked_attachment_invalid", "The locked fallback PDF has incomplete encryption parameters.")
            }
            return FileChoice(
                              cryptoRow: row, iv: pdfIV, tag: pdfTag,
                              expectedObjectIdentifier: row.string("ZIDENTIFIER"),
                              candidates: fallbackPDFCandidates(row: row))
        }
        if row.data("ZENCRYPTEDVALUESJSON") == nil,
           row.string("ZFALLBACKPDFGENERATION") != nil,
           let iv = row.data("ZCRYPTOINITIALIZATIONVECTOR"),
           let tag = row.data("ZCRYPTOTAG") {
            return FileChoice(
                cryptoRow: row, iv: iv, tag: tag,
                expectedObjectIdentifier: row.string("ZIDENTIFIER"),
                candidates: fallbackPDFCandidates(row: row))
        }
        let previews = previewCandidates(row: row)
        if row.data("ZENCRYPTEDVALUESJSON") == nil,
           try containsReadableFile(previews),
           let iv = row.data("ZCRYPTOINITIALIZATIONVECTOR"),
           let tag = row.data("ZCRYPTOTAG") {
            return FileChoice(
                cryptoRow: row, iv: iv, tag: tag,
                expectedObjectIdentifier: row.string("ZIDENTIFIER"),
                candidates: previews)
        }
        let unencryptedCandidates = (media.map { assetCandidates(row: row, media: $0, filename: filename) } ?? [])
            + fallbackImageCandidates(row: row) + fallbackPDFCandidates(row: row) + previews
        if try containsReadableFile(unencryptedCandidates) {
            throw NotesError(
                "locked_attachment_file_unsupported",
                "A stored locked attachment has no supported file-encryption fields.")
        }
        return nil
    }

    private func openNeoEnvelope(_ data: Data, expectedObjectIdentifier: String,
                                 sidecarKeys: LockedNoteCrypto.NeoSidecarKeys?,
                                 failureMessage: String) throws -> Data {
        try mapNeoErrors(failureMessage) {
            try LockedNoteCrypto.openNeoEnvelope(
                password: password,
                data: data,
                expectedObjectIdentifier: expectedObjectIdentifier,
                sidecarKeys: sidecarKeys)
        }
    }

    private func mapNeoErrors<T>(_ failureMessage: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as NotesError {
            switch error.code {
            case "wrong_password", "locked_attachment_identity_mismatch",
                 "device_key_locked_unsupported", "locked_attachment_malformed_envelope",
                 "locked_attachment_sidecar_unsupported":
                throw error
            default:
                throw NotesError("locked_attachment_decryption_failed", failureMessage)
            }
        }
    }

    private func parameters(row: StoreRow, iv: Data, tag: Data, ciphertext: Data) throws -> LockedNoteCrypto.Parameters {
        guard let salt = row.data("ZCRYPTOSALT"),
              let iterations = row.int("ZCRYPTOITERATIONCOUNT").map(Int.init),
              let wrapped = row.data("ZCRYPTOWRAPPEDKEY", "ZCRYPTOVERIFIER") else {
            throw NotesError("locked_attachment_invalid", "The locked attachment is missing key parameters.")
        }
        return .init(salt: salt, iterations: iterations, wrappedKey: wrapped, iv: iv, tag: tag,
                     ciphertext: ciphertext, authenticatedData: nil)
    }

    private func roots() -> [URL] {
        if Self.safePathComponent(accountID) {
            return [container.appendingPathComponent("Accounts").appendingPathComponent(accountID), container]
        }
        return [container]
    }

    private func assetCandidates(row: StoreRow, media: StoreRow, filename: String?) -> [URL] {
        guard let mediaID = media.string("ZIDENTIFIER"), Self.safePathComponent(mediaID) else { return [] }
        let generation = media.string("ZGENERATION1", "ZGENERATION") ?? row.string("ZGENERATION1", "ZGENERATION")
        return roots().flatMap { root -> [URL] in
            let base = root.appendingPathComponent("Media").appendingPathComponent(mediaID)
            var values = [base.appendingPathComponent(mediaID)]
            if let filename { values.append(base.appendingPathComponent(filename)) }
            if let generation, Self.safePathComponent(generation) {
                values.insert(base.appendingPathComponent(generation).appendingPathComponent(mediaID), at: 0)
                if let filename { values.append(base.appendingPathComponent(generation).appendingPathComponent(filename)) }
            }
            return values
        }
    }

    private func fallbackImageCandidates(row: StoreRow) -> [URL] {
        guard let id = row.string("ZIDENTIFIER"), Self.safePathComponent(id) else { return [] }
        let generation = row.string("ZFALLBACKIMAGEGENERATION")
        return roots().flatMap { root -> [URL] in
            let base = root.appendingPathComponent("FallbackImages").appendingPathComponent(id)
            return ["png", "jpg", "jpeg"].flatMap { ext in
                var values = [base.appendingPathComponent("FallbackImage.\(ext).encrypted"),
                              root.appendingPathComponent("FallbackImages/\(id).\(ext).encrypted"),
                              base.appendingPathComponent("FallbackImage.\(ext)"),
                              root.appendingPathComponent("FallbackImages/\(id).\(ext)")]
                if let generation, Self.safePathComponent(generation) {
                    values.insert(base.appendingPathComponent(generation).appendingPathComponent("FallbackImage.\(ext).encrypted"), at: 0)
                    values.insert(base.appendingPathComponent(generation).appendingPathComponent("FallbackImage.\(ext)"), at: 1)
                }
                return values
            }
        }
    }

    private func fallbackPDFCandidates(row: StoreRow) -> [URL] {
        guard let id = row.string("ZIDENTIFIER"), Self.safePathComponent(id) else { return [] }
        let generation = row.string("ZFALLBACKPDFGENERATION")
        return roots().flatMap { root -> [URL] in
            let base = root.appendingPathComponent("FallbackPDFs").appendingPathComponent(id)
            var values = [base.appendingPathComponent("FallbackPDF.pdf.encrypted"),
                          root.appendingPathComponent("FallbackPDFs/\(id).pdf.encrypted"),
                          base.appendingPathComponent("FallbackPDF.pdf"),
                          root.appendingPathComponent("FallbackPDFs/\(id).pdf")]
            if let generation, Self.safePathComponent(generation) {
                values.insert(base.appendingPathComponent(generation).appendingPathComponent("FallbackPDF.pdf.encrypted"), at: 0)
                values.insert(base.appendingPathComponent(generation).appendingPathComponent("FallbackPDF.pdf"), at: 1)
            }
            return values
        }
    }

    private func previewCandidates(row: StoreRow) -> [URL] {
        guard let id = row.string("ZIDENTIFIER"), Self.safePathComponent(id) else { return [] }
        let generation = row.string("ZGENERATION1", "ZGENERATION")
        return roots().flatMap { root -> [URL] in
            let previews = root.appendingPathComponent("Previews")
            return ["png", "jpg", "jpeg"].flatMap { ext in
                var values = [previews.appendingPathComponent("\(id).\(ext).encrypted")]
                if let generation, Self.safePathComponent(generation) {
                    let base = previews.appendingPathComponent(id).appendingPathComponent(generation)
                    values += [base.appendingPathComponent("Preview.\(ext).encrypted"),
                               base.appendingPathComponent("OrientedPreview.\(ext).encrypted")]
                }
                return values
            }
        }
    }

    private func firstReadableFile(_ candidates: [URL]) throws -> (URL, Data)? {
        for candidate in candidates {
            if let data = try readFile(candidate) { return (candidate, data) }
        }
        return nil
    }

    private func containsReadableFile(_ candidates: [URL]) throws -> Bool {
        for candidate in candidates where try readFile(candidate, readContents: false) != nil { return true }
        return false
    }

    /// Opens every path component relative to the Notes container. `O_NOFOLLOW`
    /// on each descriptor keeps a path swap from redirecting the read through a
    /// symlink after the boundary check.
    private func readFile(_ candidate: URL, readContents: Bool = true) throws -> Data? {
        let root = container.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        let boundary = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(boundary) else {
            throw NotesError("locked_attachment_unsafe_file", "A locked attachment path leaves the Notes container.")
        }
        let relative = String(path.dropFirst(boundary.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw NotesError("locked_attachment_unsafe_file", "A locked attachment path is invalid.")
        }

        let rootDescriptor = root.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else {
            throw NotesError("locked_attachment_read_failed", "The Notes attachment container could not be opened safely.")
        }
        defer { Darwin.close(rootDescriptor) }

        var parentDescriptor = rootDescriptor
        var ownedParentDescriptor: Int32?
        defer { if let ownedParentDescriptor { Darwin.close(ownedParentDescriptor) } }

        for component in components.dropLast() {
            let descriptor = component.withCString {
                Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if descriptor < 0 {
                if errno == ENOENT { return nil }
                if errno == ELOOP || errno == ENOTDIR {
                    throw NotesError("locked_attachment_unsafe_file", "A locked attachment path contains a symlink or non-directory component.")
                }
                throw NotesError("locked_attachment_read_failed", "A locked attachment directory could not be opened safely.")
            }
            if let ownedParentDescriptor { Darwin.close(ownedParentDescriptor) }
            ownedParentDescriptor = descriptor
            parentDescriptor = descriptor
        }

        let descriptor = components.last!.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP || errno == ENOTDIR {
                throw NotesError("locked_attachment_unsafe_file", "A locked attachment file is a symlink or has an unsafe path.")
            }
            throw NotesError("locked_attachment_read_failed", "A locked attachment file could not be opened safely.")
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw NotesError("locked_attachment_unsafe_file", "A locked attachment source is not a regular file.")
        }
        if !readContents { return Data() }

        var data = Data()
        if metadata.st_size > 0, metadata.st_size <= Int.max {
            data.reserveCapacity(Int(metadata.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw NotesError("locked_attachment_read_failed", "A locked attachment file could not be read safely.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func safePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value == URL(fileURLWithPath: value).lastPathComponent
            && value != "." && value != ".." && !value.contains("\0")
    }

    private static func decryptedFilename(_ filename: String) -> String {
        filename.hasSuffix(".encrypted") ? String(filename.dropLast(".encrypted".count)) : filename
    }
}
