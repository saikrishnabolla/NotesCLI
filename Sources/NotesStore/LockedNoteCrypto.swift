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
        if encryptedBody.starts(with: Data("bplist00".utf8)) {
            let envelope = try neoEnvelope(encryptedBody)
            return (try openNeoEnvelope(
                password: password,
                envelope: envelope,
                expectedObjectIdentifier: envelope.objectIdentifier), .v1Neo)
        }
        guard var legacy else {
            throw NotesError("locked_note_invalid", "The locked note is missing its encryption parameters.")
        }
        legacy.ciphertext = encryptedBody
        legacy.authenticatedData = nil
        return (try open(password: password, parameters: legacy), .v1)
    }

    static func openNeoEnvelope(password: String, data: Data,
                                expectedObjectIdentifier: String) throws -> Data {
        try openNeoEnvelope(
            password: password,
            envelope: neoEnvelope(data),
            expectedObjectIdentifier: expectedObjectIdentifier)
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
        let dataKey = try unwrap(parameters.wrappedKey, with: kek)
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

    private struct NeoEnvelope {
        let objectIdentifier: String
        let parameters: Parameters
    }

    private static func openNeoEnvelope(password: String, envelope: NeoEnvelope,
                                        expectedObjectIdentifier: String) throws -> Data {
        guard envelope.objectIdentifier == expectedObjectIdentifier else {
            throw NotesError(
                "locked_attachment_identity_mismatch",
                "The locked attachment envelope belongs to a different Notes object.")
        }
        return try open(password: password, parameters: envelope.parameters)
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
        guard let cipherVersion = metadata["cipherVersion"] as? NSNumber else {
            throw malformedEnvelope()
        }
        if cipherVersion.intValue == 3 {
            throw NotesError(
                "locked_attachment_sidecar_unsupported",
                "This locked attachment uses a sidecar key that cannot be verified safely.")
        }
        guard cipherVersion.intValue == 2,
              let objectIdentifier = metadata["objectIdentifier"] as? String,
              !objectIdentifier.isEmpty,
              let passphrase = try? PropertyListSerialization.propertyList(
                  from: envelope.unauthenticatedMetadata,
                  format: nil
              ) as? [String: Any],
              let salt = passphrase["passphraseSalt"] as? Data,
              salt.count == 32,
              let iterationNumber = passphrase["passphraseIterationCount"] as? NSNumber,
              iterationNumber.int64Value > 0,
              iterationNumber.uint64Value <= UInt64(UInt32.max),
              envelope.wrappedEncryptionKey.count == 40,
              envelope.encryptedData.count > 48 else {
            throw malformedEnvelope()
        }
        let ciphertextEnd = envelope.encryptedData.count - 48
        return NeoEnvelope(
            objectIdentifier: objectIdentifier,
            parameters: Parameters(
                salt: salt,
                iterations: Int(iterationNumber.uint64Value),
                wrappedKey: envelope.wrappedEncryptionKey,
                iv: envelope.encryptedData.subdata(in: ciphertextEnd..<(ciphertextEnd + 32)),
                tag: envelope.encryptedData.suffix(16),
                ciphertext: envelope.encryptedData.prefix(ciphertextEnd),
                authenticatedData: envelope.metadata
            )
        )
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
    let unauthenticatedMetadata: Data
    let wrappedEncryptionKey: Data
    let encryptedData: Data

    required init?(coder: NSCoder) {
        guard let metadata = coder.decodeObject(of: NSData.self, forKey: "metadata") as? Data,
              let unauthenticatedMetadata = coder.decodeObject(
                of: NSData.self,
                forKey: "unauthenticatedMetadata"
              ) as? Data,
              let wrappedEncryptionKey = coder.decodeObject(
                of: NSData.self,
                forKey: "wrappedEncryptionKey"
              ) as? Data,
              let encryptedData = coder.decodeObject(of: NSData.self, forKey: "encryptedData") as? Data else {
            return nil
        }
        self.metadata = metadata
        self.unauthenticatedMetadata = unauthenticatedMetadata
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
