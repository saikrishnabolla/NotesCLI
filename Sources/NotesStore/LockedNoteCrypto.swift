import CommonCrypto
import CryptoKit
import Foundation
import NotesCore

enum LockedNoteCrypto {
    enum Format: String, Sendable { case v1, v1Neo = "v1neo" }

    struct Parameters: Sendable {
        var salt: Data
        var iterations: Int
        var wrappedKey: Data
        var iv: Data
        var tag: Data
        var ciphertext: Data
        var authenticatedData: Data?
    }

    static func openV1(password: String, salt: Data, iterations: Int, wrappedKey: Data,
                       iv: Data, tag: Data, ciphertext: Data) throws -> Data {
        try open(password: password, parameters: Parameters(
            salt: salt, iterations: iterations, wrappedKey: wrappedKey,
            iv: iv, tag: tag, ciphertext: ciphertext, authenticatedData: nil
        ))
    }

    static func open(password: String, encryptedBody: Data, legacy: Parameters?) throws -> (Data, Format) {
        let opened = try openVerifyingMainKey(password: password, encryptedBody: encryptedBody, legacy: legacy)
        return (opened.plaintext, opened.format)
    }

    /// Opens a locked note body. For V1-Neo it also returns the verified
    /// password-derived main key. Child objects without their own encrypted
    /// values may use it for sidecars, as Notes' `cachedMainKeyForObject:`
    /// walks up to the note.
    static func openVerifyingMainKey(password: String, encryptedBody: Data, legacy: Parameters?) throws
        -> (plaintext: Data, format: Format, mainKey: Data?) {
        if encryptedBody.starts(with: Data("bplist00".utf8)) {
            let envelope = try neoEnvelope(encryptedBody)
            let opened = try openNeoEnvelopeVerifyingMainKey(
                password: password,
                data: encryptedBody,
                expectedObjectIdentifier: envelope.objectIdentifier)
            return (opened.plaintext, .v1Neo, opened.mainKey)
        }
        guard var legacy else {
            throw NotesError("locked_note_invalid", "The locked note is missing its encryption parameters.")
        }
        legacy.ciphertext = encryptedBody
        legacy.authenticatedData = nil
        return (try open(password: password, parameters: legacy), .v1, nil)
    }

    /// Keys for a cipher-3 sidecar envelope. `mainKey` must already be
    /// verified by opening one of the owner's password envelopes.
    /// `encryptedValues` is the owner's decrypted encrypted-values JSON, which
    /// may hold Apple's serialized `sidecarMainKey`.
    struct NeoSidecarKeys {
        var mainKey: Data
        var encryptedValues: [String: Any]?
    }

    static func openNeoEnvelope(password: String, data: Data,
                                expectedObjectIdentifier: String,
                                sidecarKeys: NeoSidecarKeys? = nil) throws -> Data {
        let envelope = try neoEnvelope(data)
        if envelope.cipherVersion == sidecarCipherVersion {
            guard let sidecarKeys else {
                throw NotesError(
                    "locked_attachment_sidecar_unsupported",
                    "This locked attachment uses a sidecar key, and no verified key for its owner was found.")
            }
            return try openSidecar(
                envelope: envelope,
                expectedObjectIdentifier: expectedObjectIdentifier,
                mainKey: sidecarKeys.mainKey,
                storedSidecarKey: storedSidecarMainKey(in: sidecarKeys.encryptedValues))
        }
        return try openNeoEnvelope(
            password: password,
            envelope: envelope,
            expectedObjectIdentifier: expectedObjectIdentifier).plaintext
    }

    /// Opens a password (cipher 2) envelope and returns the password-derived
    /// main key that authenticated it.
    static func openNeoEnvelopeVerifyingMainKey(password: String, data: Data,
                                                expectedObjectIdentifier: String) throws -> (plaintext: Data, mainKey: Data) {
        let envelope = try neoEnvelope(data)
        guard envelope.cipherVersion != sidecarCipherVersion else {
            throw NotesError(
                "locked_attachment_sidecar_unsupported",
                "This locked attachment uses a sidecar key, and no verified key for its owner was found.")
        }
        return try openNeoEnvelope(
            password: password,
            envelope: envelope,
            expectedObjectIdentifier: expectedObjectIdentifier)
    }

    /// Opens a cipher-3 sidecar envelope with Apple's key order: the stored
    /// `sidecarMainKey` first, then the verified main key.
    static func openNeoSidecarEnvelope(data: Data, expectedObjectIdentifier: String,
                                       mainKey: Data, storedSidecarKey: Data?) throws -> Data {
        let envelope = try neoEnvelope(data)
        guard envelope.cipherVersion == sidecarCipherVersion else { throw malformedEnvelope() }
        return try openSidecar(
            envelope: envelope,
            expectedObjectIdentifier: expectedObjectIdentifier,
            mainKey: mainKey,
            storedSidecarKey: storedSidecarKey)
    }

    /// Returns the key bytes from the owner's stored `sidecarMainKey`, or nil
    /// when none is stored or it is unusable. Notes treats an undecodable
    /// value as absent and falls back to the main key: invalid base64 becomes
    /// nil, and a failed `ICEncryptionKey initWithSerializedData:` only logs.
    static func storedSidecarMainKey(in values: [String: Any]?) -> Data? {
        guard let value = values?["sidecarMainKey"], !(value is NSNull) else { return nil }
        guard let encoded = value as? String,
              let serialized = Data(base64Encoded: encoded),
              !serialized.isEmpty else { return nil }
        return sidecarMainKey(serialized: serialized)
    }

    /// Decodes Apple's serialized `ICEncryptionKey` with the same acceptance
    /// rules as `initWithSerializedData:`, `ICEncryptionMetadata
    /// deserializeWithData:authenticatedData:`, and both `validate` methods.
    /// Returns nil when Notes would get no key. Notes never compares the key's
    /// object identifier with the owner, so neither do we. The key sits inside
    /// the owner's authenticated values; the sidecar envelope's own identifier
    /// and AES-GCM tag are still checked.
    static func sidecarMainKey(serialized: Data) -> Data? {
        guard let dictionary = plistDictionary(serialized),
              let key = dictionary["key"] as? Data, !key.isEmpty,
              let metadata = dictionary["metadata"] as? Data else { return nil }
        // An empty unauthenticated record deserializes as an empty dictionary.
        let unauthenticated: [String: Any]
        if metadata.isEmpty {
            unauthenticated = [:]
        } else {
            guard let values = plistDictionary(metadata) else { return nil }
            unauthenticated = values
        }
        // A missing or mistyped authenticatedData falls back to `metadata`.
        let authenticated = (dictionary["authenticatedData"] as? Data) ?? metadata
        guard !authenticated.isEmpty, let fields = plistDictionary(authenticated) else { return nil }
        let version = (fields["cipherVersion"] as? NSNumber)?.uint64Value ?? 0
        let objectIdentifier = fields["objectIdentifier"] as? String ?? ""
        let salt = unauthenticated["passphraseSalt"] as? Data ?? Data()
        let iterations = (unauthenticated["passphraseIterationCount"] as? NSNumber)?.uint64Value ?? 0
        let accountKeyIdentifier = fields["accountKeyIdentifier"] as? String ?? ""
        let valid: Bool
        switch version {
        case 0: valid = !salt.isEmpty
        case 1: valid = !accountKeyIdentifier.isEmpty
        case 2: valid = !objectIdentifier.isEmpty && !salt.isEmpty && iterations != 0
        case 3: valid = !objectIdentifier.isEmpty
        default: valid = true
        }
        return valid ? key : nil
    }

    private static func plistDictionary(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func open(password: String, parameters: Parameters, allowEmptyCiphertext: Bool = false) throws -> Data {
        let keyLength = parameters.wrappedKey.count - 8
        guard (keyLength == 16 || keyLength == 32),
              (8...64).contains(parameters.salt.count),
              parameters.iterations > 0,
              UInt32(exactly: parameters.iterations) != nil,
              (12...32).contains(parameters.iv.count),
              parameters.tag.count == 16,
              allowEmptyCiphertext || !parameters.ciphertext.isEmpty else {
            throw NotesError("locked_note_invalid", "The locked note has invalid encryption parameters.")
        }
        let kek = try derive(password: password, salt: parameters.salt,
                             iterations: parameters.iterations, count: keyLength)
        return try open(mainKey: kek, parameters: parameters)
    }

    private static func open(mainKey: Data, parameters: Parameters) throws -> Data {
        let dataKey = try unwrap(parameters.wrappedKey, with: mainKey)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: parameters.iv),
                ciphertext: parameters.ciphertext,
                tag: parameters.tag
            )
            let key = SymmetricKey(data: dataKey)
            if let authenticatedData = parameters.authenticatedData {
                return try AES.GCM.open(box, using: key, authenticating: authenticatedData)
            }
            return try AES.GCM.open(box, using: key)
        } catch {
            throw NotesError("locked_note_decryption_failed", "The locked note could not be authenticated.")
        }
    }

    private static func derive(password: String, salt: Data, iterations: Int, count: Int) throws -> Data {
        let passwordBytes = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var result = Data(count: count)
        let status = result.withUnsafeMutableBytes { resultBytes in
            passwordBytes.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordBytes.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        resultBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        count
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw NotesError("locked_note_decryption_failed", "The locked note key could not be derived.")
        }
        return result
    }

    private static func unwrap(_ wrapped: Data, with key: Data) throws -> Data {
        var outputCount = CCSymmetricUnwrappedSize(CCWrappingAlgorithm(kCCWRAPAES), wrapped.count)
        var output = Data(count: outputCount)
        let status = output.withUnsafeMutableBytes { outputBytes in
            wrapped.withUnsafeBytes { wrappedBytes in
                key.withUnsafeBytes { keyBytes in
                    guard let outputAddress = outputBytes.baseAddress,
                          let wrappedAddress = wrappedBytes.baseAddress,
                          let keyAddress = keyBytes.baseAddress else { return Int32(kCCParamError) }
                    return CCSymmetricKeyUnwrap(
                        CCWrappingAlgorithm(kCCWRAPAES),
                        CCrfc3394_iv,
                        CCrfc3394_ivLen,
                        keyAddress,
                        key.count,
                        wrappedAddress,
                        wrapped.count,
                        outputAddress,
                        &outputCount
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw NotesError("wrong_password", "The password did not unlock this note.")
        }
        return output.prefix(outputCount)
    }

    private static let sidecarCipherVersion = 3

    private struct NeoEnvelope {
        let objectIdentifier: String
        let cipherVersion: Int
        /// Salt and iteration count; present only for password envelopes.
        let passphrase: (salt: Data, iterations: Int)?
        let parameters: Parameters
    }

    private static func openNeoEnvelope(password: String, envelope: NeoEnvelope,
                                        expectedObjectIdentifier: String) throws -> (plaintext: Data, mainKey: Data) {
        try requireIdentity(envelope, expectedObjectIdentifier)
        guard let passphrase = envelope.passphrase else { throw malformedEnvelope() }
        let mainKey = try derive(password: password, salt: passphrase.salt,
                                 iterations: passphrase.iterations, count: 32)
        return (try open(mainKey: mainKey, parameters: envelope.parameters), mainKey)
    }

    private static func openSidecar(envelope: NeoEnvelope, expectedObjectIdentifier: String,
                                    mainKey: Data, storedSidecarKey: Data?) throws -> Data {
        try requireIdentity(envelope, expectedObjectIdentifier)
        guard mainKey.count == 32 else { throw invalidSidecarKey() }
        // Apple's decryptSidecarData: tries the stored key, then the main key.
        // A stored key that is not 32 bytes fails Notes' wrapper-length check
        // when unwrapping, so it falls back too. RFC 3394 and AES-GCM both
        // authenticate, so a wrong key cannot open the sidecar.
        let storedKey = storedSidecarKey.flatMap { $0.count == 32 ? $0 : nil }
        var unwrapped = false
        for key in [storedKey, mainKey].compactMap({ $0 }) {
            guard let contentKey = try? unwrap(envelope.parameters.wrappedKey, with: key),
                  contentKey.count == 32 else { continue }
            unwrapped = true
            if let plaintext = try? open(contentKey: contentKey, parameters: envelope.parameters) {
                return plaintext
            }
        }
        throw NotesError(
            "locked_attachment_decryption_failed",
            unwrapped
                ? "The locked sidecar could not be authenticated."
                : "No available key unwraps this locked sidecar.")
    }

    private static func open(contentKey: Data, parameters: Parameters) throws -> Data {
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: parameters.iv),
            ciphertext: parameters.ciphertext,
            tag: parameters.tag)
        return try AES.GCM.open(
            box,
            using: SymmetricKey(data: contentKey),
            authenticating: parameters.authenticatedData ?? Data())
    }

    private static func requireIdentity(_ envelope: NeoEnvelope, _ expectedObjectIdentifier: String) throws {
        guard envelope.objectIdentifier == expectedObjectIdentifier else {
            throw NotesError(
                "locked_attachment_identity_mismatch",
                "The locked attachment envelope belongs to a different Notes object.")
        }
    }

    private static func neoEnvelope(_ data: Data) throws -> NeoEnvelope {
        guard data.starts(with: Data("bplist00".utf8)) else {
            throw malformedEnvelope()
        }
        let unarchiver: NSKeyedUnarchiver
        do { unarchiver = try NSKeyedUnarchiver(forReadingFrom: data) }
        catch { throw malformedEnvelope() }
        let delegate = LockedEnvelopeDelegate()
        unarchiver.delegate = delegate
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let envelope = unarchiver.decodeObject(
            of: LockedEncryptionEnvelope.self,
            forKey: NSKeyedArchiveRootObjectKey
        ) else {
            throw malformedEnvelope()
        }
        guard let metadata = try? PropertyListSerialization.propertyList(from: envelope.metadata, format: nil) as? [String: Any] else {
            throw malformedEnvelope()
        }
        if metadata["accountKeyIdentifier"] != nil {
            throw NotesError("device_key_locked_unsupported", "This note is locked with the device passcode or login password.")
        }
        guard let cipherVersion = metadata["cipherVersion"] as? NSNumber,
              let objectIdentifier = metadata["objectIdentifier"] as? String,
              !objectIdentifier.isEmpty,
              envelope.wrappedEncryptionKey.count == 40 else {
            throw malformedEnvelope()
        }
        let unauthenticated: [String: Any]
        if let data = envelope.unauthenticatedMetadata, !data.isEmpty {
            guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw malformedEnvelope()
            }
            unauthenticated = values
        } else {
            unauthenticated = [:]
        }
        let passphrase: (salt: Data, iterations: Int)?
        switch cipherVersion.intValue {
        case 2:
            guard let salt = unauthenticated["passphraseSalt"] as? Data,
                  salt.count == 32,
                  let iterationNumber = unauthenticated["passphraseIterationCount"] as? NSNumber,
                  iterationNumber.int64Value > 0,
                  iterationNumber.uint64Value <= UInt64(UInt32.max),
                  envelope.encryptedData.count > 48 else {
                throw malformedEnvelope()
            }
            passphrase = (salt, Int(iterationNumber.uint64Value))
        case sidecarCipherVersion:
            // Sidecars carry no passphrase; an empty payload is valid.
            guard envelope.encryptedData.count >= 48 else { throw malformedEnvelope() }
            passphrase = nil
        default:
            throw malformedEnvelope()
        }
        let ciphertextEnd = envelope.encryptedData.count - 48
        return NeoEnvelope(
            objectIdentifier: objectIdentifier,
            cipherVersion: cipherVersion.intValue,
            passphrase: passphrase,
            parameters: Parameters(
                salt: passphrase?.salt ?? Data(),
                iterations: passphrase?.iterations ?? 0,
                wrappedKey: envelope.wrappedEncryptionKey,
                iv: envelope.encryptedData.subdata(in: ciphertextEnd..<(ciphertextEnd + 32)),
                tag: envelope.encryptedData.suffix(16),
                ciphertext: envelope.encryptedData.prefix(ciphertextEnd),
                authenticatedData: envelope.metadata
            )
        )
    }

    private static func invalidSidecarKey() -> NotesError {
        NotesError(
            "locked_attachment_sidecar_key_invalid",
            "The stored sidecar key for this locked attachment is invalid.")
    }

    private static func malformedEnvelope() -> NotesError {
        NotesError(
            "locked_attachment_malformed_envelope",
            "The locked attachment has an invalid encryption envelope.")
    }
}

@objc(NotesCLILockedEncryptionEnvelope)
private final class LockedEncryptionEnvelope: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let metadata: Data
    let unauthenticatedMetadata: Data?
    let wrappedEncryptionKey: Data
    let encryptedData: Data

    required init?(coder: NSCoder) {
        guard let metadata = coder.decodeObject(of: NSData.self, forKey: "metadata") as? Data,
              let wrappedEncryptionKey = coder.decodeObject(
                of: NSData.self,
                forKey: "wrappedEncryptionKey"
              ) as? Data,
              let encryptedData = coder.decodeObject(of: NSData.self, forKey: "encryptedData") as? Data else {
            return nil
        }
        self.metadata = metadata
        self.unauthenticatedMetadata = coder.decodeObject(
            of: NSData.self, forKey: "unauthenticatedMetadata") as? Data
        self.wrappedEncryptionKey = wrappedEncryptionKey
        self.encryptedData = encryptedData
    }

    func encode(with coder: NSCoder) {}
}

private final class LockedEnvelopeDelegate: NSObject, NSKeyedUnarchiverDelegate {
    func unarchiver(_ unarchiver: NSKeyedUnarchiver,
                    cannotDecodeObjectOfClassName name: String,
                    originalClasses: [String]) -> AnyClass? {
        let className = name.split(separator: ".").last.map(String.init) ?? name
        return className == "ICCryptoEncryptionObject" ? LockedEncryptionEnvelope.self : nil
    }
}
