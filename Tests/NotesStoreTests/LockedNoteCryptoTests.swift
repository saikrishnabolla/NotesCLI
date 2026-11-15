import CommonCrypto
import CryptoKit
import Foundation
import NotesCore
import XCTest
@testable import NotesStore

final class LockedNoteCryptoTests: XCTestCase {
    func testOpensIndependentAppleNotesV1Vector() throws {
        let plaintext = try LockedNoteCrypto.openV1(
            password: "Bramble-NO1-test",
            salt: try hex("000102030405060708090a0b0c0d0e0f"),
            iterations: 20_000,
            wrappedKey: try hex("e16d0282d92b1764468de34f30d2005670e4f59505ceaef3"),
            iv: try hex("6555f78ff2fe9c5c44511d4db1a900a0"),
            tag: try hex("4d82c681c75fae683a92153f55a31804"),
            ciphertext: try hex("79cd8f8dd2a5481d7355314db16b7dac8fffa0518ed725221aa41867c18f3a6af5a40b1f3367781236802571995475f0ea9bd50cb2cf357d8d2976bd4820d683131f5896aa82fac16cef7c593b9f59d403feb81dd8073755594907184e133605ae8108401d74ca0896d8fc781bb7ac70fc7a38b8778834c25d6e8f5346ce9d7af8ff3cc6dcb45504f4df6e2123eb957c0aba4bab0f3dffed530852ceaa9c8b097b1a7783ef")
        )

        XCTAssertEqual(plaintext.count, 165)
        XCTAssertEqual(SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined(),
                       "46959ea8672362ae28f0a878a4f7eeed727c2f8de59c9b9e00ce5a72ed0cc2e1")
    }

    func testWrongPasswordAndInvalidParametersAreDistinct() throws {
        XCTAssertThrowsError(try LockedNoteCrypto.openV1(
            password: "wrong",
            salt: try hex("000102030405060708090a0b0c0d0e0f"),
            iterations: 20_000,
            wrappedKey: try hex("e16d0282d92b1764468de34f30d2005670e4f59505ceaef3"),
            iv: try hex("6555f78ff2fe9c5c44511d4db1a900a0"),
            tag: try hex("4d82c681c75fae683a92153f55a31804"),
            ciphertext: Data([0])
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "wrong_password")
        }
        XCTAssertThrowsError(try LockedNoteCrypto.openV1(
            password: "x", salt: Data(), iterations: 0, wrappedKey: Data(),
            iv: Data(), tag: Data(), ciphertext: Data()
        )) { error in
            XCTAssertEqual((error as? NotesError)?.code, "locked_note_invalid")
        }
    }

    func testOpensCurrentPasswordEnvelopeAndAuthenticatesMetadata() throws {
        let body = Data("current locked body".utf8)
        let envelope = try currentEnvelope(password: "modern-password", body: body)

        let opened = try LockedNoteCrypto.open(password: "modern-password", encryptedBody: envelope, legacy: nil)
        XCTAssertEqual(opened.0, body)
        XCTAssertEqual(opened.1, .v1Neo)
        XCTAssertThrowsError(try LockedNoteCrypto.open(password: "wrong", encryptedBody: envelope, legacy: nil)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "wrong_password")
        }
    }

    func testAppleRuntimeNeoEnvelopesOpenByteExactlyWithDecomposedPassword() throws {
        let password = "Cafe\u{301}-neo"
        let expectedFile = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoBAgMEBQYHCA=="))
        let expectedValues = Data(#"{"filename":"photo.png","markupModelData":"bWFya3Vw"}"#.utf8)

        XCTAssertEqual(
            try LockedNoteCrypto.openNeoEnvelope(
                password: password,
                data: appleEnvelope("media.encryptedvaluesjson.bin"),
                expectedObjectIdentifier: "MEDIA-ID"),
            expectedValues)
        XCTAssertEqual(
            try LockedNoteCrypto.openNeoEnvelope(
                password: password,
                data: appleEnvelope("media.file.bin"),
                expectedObjectIdentifier: "MEDIA-ID"),
            expectedFile)
        XCTAssertEqual(
            try LockedNoteCrypto.openNeoEnvelope(
                password: password,
                data: appleEnvelope("fallbackimage.encrypted.bin"),
                expectedObjectIdentifier: "ATTACHMENT-ID"),
            expectedFile)
    }

    func testNeoEnvelopeRejectsWrongIdentityAndTamperedAuthenticatedMetadata() throws {
        XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
            password: "Cafe\u{301}-neo",
            data: appleEnvelope("fallbackimage.encrypted.bin"),
            expectedObjectIdentifier: "MEDIA-ID"
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_identity_mismatch")
        }

        let body = Data("authenticated body".utf8)
        let metadata = try metadata(objectIdentifier: "fixture", extra: ["tampered": true])
        let envelope = try currentEnvelope(
            password: "password",
            body: body,
            archivedMetadata: metadata)
        XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
            password: "password", data: envelope, expectedObjectIdentifier: "fixture"
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_note_decryption_failed")
        }
    }

    func testNeoEnvelopeRejectsMalformedSaltWrappedKeyIterationAndSidecarVersion() throws {
        let malformedSalt = try currentEnvelope(
            password: "password", body: Data("body".utf8), salt: Data(repeating: 1, count: 16))
        XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
            password: "password", data: malformedSalt, expectedObjectIdentifier: "fixture"
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_malformed_envelope")
        }

        let malformedKey = try currentEnvelope(
            password: "password", body: Data("body".utf8), archivedWrappedKey: Data(repeating: 2, count: 39))
        XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
            password: "password", data: malformedKey, expectedObjectIdentifier: "fixture"
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_malformed_envelope")
        }

        for count in [NSNumber(value: 0), NSNumber(value: UInt64(UInt32.max) + 1)] {
            let malformedIteration = try currentEnvelope(
                password: "password",
                body: Data("body".utf8),
                archivedIterationCount: count)
            XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
                password: "password", data: malformedIteration, expectedObjectIdentifier: "fixture"
            )) {
                XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_malformed_envelope")
            }
        }

        let sidecar = try currentEnvelope(
            password: "password",
            body: Data("body".utf8),
            archivedMetadata: try metadata(objectIdentifier: "fixture", cipherVersion: 3))
        XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
            password: "password", data: sidecar, expectedObjectIdentifier: "fixture"
        )) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_sidecar_unsupported")
        }
    }

    func testLegacyV1UsesNFCNormalizedPassword() throws {
        let decomposed = "Cafe\u{301}-legacy"
        let salt = Data((0..<16).map(UInt8.init))
        let dataKey = Data((16..<32).map(UInt8.init))
        let iv = Data((32..<48).map(UInt8.init))
        let kek = try derive(
            password: decomposed.precomposedStringWithCanonicalMapping,
            salt: salt,
            iterations: 1_000,
            count: dataKey.count)
        let plaintext = Data("legacy normalized password".utf8)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: dataKey),
            nonce: AES.GCM.Nonce(data: iv))

        XCTAssertEqual(try LockedNoteCrypto.openV1(
            password: decomposed,
            salt: salt,
            iterations: 1_000,
            wrappedKey: try wrap(dataKey, with: kek),
            iv: iv,
            tag: sealed.tag,
            ciphertext: sealed.ciphertext
        ), plaintext)
    }

    func testCurrentDeviceKeyEnvelopeIsExplicitlyUnsupported() throws {
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["cipherVersion": 1, "accountKeyIdentifier": "device-key"],
            format: .binary,
            options: 0
        )
        let envelope = try archivedEnvelope(
            metadata: metadata,
            unauthenticated: try PropertyListSerialization.data(
                fromPropertyList: ["passphraseSalt": Data(repeating: 1, count: 32),
                                   "passphraseIterationCount": 20_000],
                format: .binary,
                options: 0
            ),
            wrappedKey: Data(repeating: 2, count: 40),
            encryptedData: Data(repeating: 3, count: 49)
        )
        XCTAssertThrowsError(try LockedNoteCrypto.open(password: "x", encryptedBody: envelope, legacy: nil)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "device_key_locked_unsupported")
        }
    }

    // MARK: Cipher-3 sidecars (Apple runtime fixtures)

    func testAppleMainKeyDerivationMatchesNotesShared() throws {
        let opened = try LockedNoteCrypto.openNeoEnvelopeVerifyingMainKey(
            password: AppleSidecarFixtures.password,
            data: AppleSidecarFixtures.valuesWithSidecarKey,
            expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier)
        XCTAssertEqual(opened.mainKey, AppleSidecarFixtures.mainKey)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: opened.plaintext) as? [String: Any])
        XCTAssertEqual(values["filename"] as? String, "drawing.png")
        XCTAssertEqual(
            LockedNoteCrypto.storedSidecarMainKey(in: values),
            AppleSidecarFixtures.sidecarKey)

        // Opening a V1-Neo body returns the same verified main key.
        let body = try LockedNoteCrypto.openVerifyingMainKey(
            password: AppleSidecarFixtures.password,
            encryptedBody: AppleSidecarFixtures.valuesWithSidecarKey,
            legacy: nil)
        XCTAssertEqual(body.format, .v1Neo)
        XCTAssertEqual(body.mainKey, AppleSidecarFixtures.mainKey)
    }

    func testSidecarOpensWithStoredSidecarKey() throws {
        let keys = try sidecarKeys(AppleSidecarFixtures.valuesWithSidecarKey)
        XCTAssertEqual(
            try LockedNoteCrypto.openNeoEnvelope(
                password: AppleSidecarFixtures.password,
                data: AppleSidecarFixtures.sidecarWrappedWithStoredKey,
                expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
                sidecarKeys: keys),
            AppleSidecarFixtures.storedPayload)

        // The main key alone cannot open a sidecar wrapped with the stored key.
        XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
            password: AppleSidecarFixtures.password,
            data: AppleSidecarFixtures.sidecarWrappedWithStoredKey,
            expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
            sidecarKeys: try sidecarKeys(AppleSidecarFixtures.valuesWithoutSidecarKey))) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_decryption_failed")
        }
    }

    func testSidecarFallsBackToMainKey() throws {
        for values in [AppleSidecarFixtures.valuesWithSidecarKey, AppleSidecarFixtures.valuesWithoutSidecarKey] {
            XCTAssertEqual(
                try LockedNoteCrypto.openNeoEnvelope(
                    password: AppleSidecarFixtures.password,
                    data: AppleSidecarFixtures.sidecarWrappedWithMainKey,
                    expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
                    sidecarKeys: try sidecarKeys(values)),
                AppleSidecarFixtures.fallbackPayload)
        }
        XCTAssertEqual(
            try LockedNoteCrypto.openNeoSidecarEnvelope(
                data: AppleSidecarFixtures.sidecarWrappedWithMainKey,
                expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
                mainKey: AppleSidecarFixtures.mainKey,
                storedSidecarKey: nil),
            AppleSidecarFixtures.fallbackPayload)
    }

    func testSidecarRejectsWrongObjectIdentity() throws {
        let keys = try sidecarKeys(AppleSidecarFixtures.valuesWithSidecarKey)
        XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
            password: AppleSidecarFixtures.password,
            data: AppleSidecarFixtures.sidecarWrappedWithMainKey,
            expectedObjectIdentifier: "OTHER-OBJECT",
            sidecarKeys: keys)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_identity_mismatch")
        }

    }

    func testStoredSidecarKeyFromRenamedObjectStillOpens() throws {
        // Notes never rewrites a stored sidecarMainKey or checks its object
        // identifier, so an object whose identifier changed keeps the old one.
        let renamedKey = try serializedSidecarKey(authenticated: [
            "cipherVersion": 3, "objectIdentifier": "OTHER-OBJECT",
        ])
        XCTAssertEqual(try LockedNoteCrypto.openNeoEnvelope(
            password: AppleSidecarFixtures.password,
            data: AppleSidecarFixtures.sidecarWrappedWithStoredKey,
            expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
            sidecarKeys: .init(
                mainKey: AppleSidecarFixtures.mainKey,
                encryptedValues: ["sidecarMainKey": renamedKey.base64EncodedString()])),
            AppleSidecarFixtures.storedPayload)
    }

    func testSidecarRejectsTamperedMetadataTagAndWrappedKey() throws {
        let keys = try sidecarKeys(AppleSidecarFixtures.valuesWithSidecarKey)
        var fields = try appleEnvelopeFields(AppleSidecarFixtures.sidecarWrappedWithStoredKey)
        fields.metadata = try PropertyListSerialization.data(
            fromPropertyList: ["cipherVersion": 3, "objectIdentifier": AppleSidecarFixtures.objectIdentifier,
                               "tampered": true],
            format: .binary, options: 0)
        let tamperedMetadata = try archivedEnvelope(fields)

        fields = try appleEnvelopeFields(AppleSidecarFixtures.sidecarWrappedWithStoredKey)
        fields.encryptedData[fields.encryptedData.count - 1] ^= 0x01
        let tamperedTag = try archivedEnvelope(fields)

        fields = try appleEnvelopeFields(AppleSidecarFixtures.sidecarWrappedWithStoredKey)
        fields.wrappedEncryptionKey[0] ^= 0x01
        let tamperedWrappedKey = try archivedEnvelope(fields)

        // The untouched re-archive still opens, so failures come from tampering.
        XCTAssertEqual(
            try LockedNoteCrypto.openNeoEnvelope(
                password: AppleSidecarFixtures.password,
                data: archivedEnvelope(appleEnvelopeFields(AppleSidecarFixtures.sidecarWrappedWithStoredKey)),
                expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
                sidecarKeys: keys),
            AppleSidecarFixtures.storedPayload)
        for envelope in [tamperedMetadata, tamperedTag, tamperedWrappedKey] {
            XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
                password: AppleSidecarFixtures.password,
                data: envelope,
                expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
                sidecarKeys: keys)) {
                XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_decryption_failed")
            }
        }
    }

    func testUnusableStoredSidecarKeyFallsBackToMainKey() throws {
        // Notes gets no usable stored key from any of these, so
        // decryptSidecarData: falls back to the main key. Each entry uses the
        // real sidecar key bytes where its shape allows, to prove it is ignored.
        let key = AppleSidecarFixtures.sidecarKey
        let cipher3: [String: Any] = ["cipherVersion": 3, "objectIdentifier": AppleSidecarFixtures.objectIdentifier]
        let unusable: [String: Any] = [
            "invalid base64": "not base64 !",
            "not a string": 42,
            "empty": "",
            "not a plist": Data("not a plist".utf8).base64EncodedString(),
            "empty key": try serializedSidecarKey(key: Data(), authenticated: cipher3).base64EncodedString(),
            "16-byte key": try serializedSidecarKey(key: key.prefix(16), authenticated: cipher3).base64EncodedString(),
            "missing metadata": try plist(["key": key, "authenticatedData": try plist(cipher3)]).base64EncodedString(),
            "metadata not a dictionary": try plist([
                "key": key, "metadata": Data("bad".utf8), "authenticatedData": try plist(cipher3),
            ]).base64EncodedString(),
            "authenticated data not a plist": try plist([
                "key": key, "metadata": try plist([String: Any]()), "authenticatedData": Data("bad".utf8),
            ]).base64EncodedString(),
            "cipher 3 without object ID": try serializedSidecarKey(authenticated: ["cipherVersion": 3])
                .base64EncodedString(),
            "cipher 2 without passphrase": try serializedSidecarKey(authenticated: [
                "cipherVersion": 2, "objectIdentifier": AppleSidecarFixtures.objectIdentifier,
            ]).base64EncodedString(),
            "cipher 1 without account key": try serializedSidecarKey(authenticated: ["cipherVersion": 1])
                .base64EncodedString(),
            "cipher 0 without salt": try serializedSidecarKey(authenticated: ["objectIdentifier": "X"])
                .base64EncodedString(),
        ]
        for (name, value) in unusable {
            let keys = LockedNoteCrypto.NeoSidecarKeys(
                mainKey: AppleSidecarFixtures.mainKey, encryptedValues: ["sidecarMainKey": value])
            XCTAssertEqual(
                try LockedNoteCrypto.openNeoEnvelope(
                    password: AppleSidecarFixtures.password,
                    data: AppleSidecarFixtures.sidecarWrappedWithMainKey,
                    expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
                    sidecarKeys: keys),
                AppleSidecarFixtures.fallbackPayload, name)
            // A payload only the stored key could open still fails safely.
            XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
                password: AppleSidecarFixtures.password,
                data: AppleSidecarFixtures.sidecarWrappedWithStoredKey,
                expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
                sidecarKeys: keys)) {
                XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_decryption_failed", name)
            }
        }
    }

    func testStoredSidecarKeyUsesNotesAcceptanceRules() throws {
        // ICEncryptionKey only needs key data and metadata that validates for
        // its own cipher version, so Notes still tries these stored keys.
        let salted = ["passphraseSalt": Data(repeating: 1, count: 32), "passphraseIterationCount": 1_000] as [String: Any]
        let usable: [String: Data] = [
            "cipher 3 with account key": try serializedSidecarKey(authenticated: [
                "cipherVersion": 3, "objectIdentifier": "X", "accountKeyIdentifier": "device",
            ]),
            "cipher 2 with passphrase": try serializedSidecarKey(
                authenticated: ["cipherVersion": 2, "objectIdentifier": "X"], unauthenticated: salted),
            "cipher 1 with account key": try serializedSidecarKey(authenticated: [
                "cipherVersion": 1, "accountKeyIdentifier": "device",
            ]),
            "cipher 0 with salt": try serializedSidecarKey(authenticated: ["objectIdentifier": "X"],
                                                           unauthenticated: salted),
            "unknown cipher version": try serializedSidecarKey(authenticated: ["cipherVersion": 7]),
            "metadata only": try plist([
                "key": AppleSidecarFixtures.sidecarKey,
                "metadata": try plist(["cipherVersion": 3, "objectIdentifier": "X"]),
            ]),
        ]
        for (name, serialized) in usable {
            XCTAssertEqual(LockedNoteCrypto.sidecarMainKey(serialized: serialized), AppleSidecarFixtures.sidecarKey, name)
            XCTAssertEqual(
                try LockedNoteCrypto.openNeoEnvelope(
                    password: AppleSidecarFixtures.password,
                    data: AppleSidecarFixtures.sidecarWrappedWithStoredKey,
                    expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
                    sidecarKeys: .init(
                        mainKey: AppleSidecarFixtures.mainKey,
                        encryptedValues: ["sidecarMainKey": serialized.base64EncodedString()])),
                AppleSidecarFixtures.storedPayload, name)
        }
    }

    func testSidecarWrongPasswordAndWrongMainKeyFail() throws {
        XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelopeVerifyingMainKey(
            password: "wrong",
            data: AppleSidecarFixtures.valuesWithSidecarKey,
            expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "wrong_password")
        }
        XCTAssertThrowsError(try LockedNoteCrypto.openNeoSidecarEnvelope(
            data: AppleSidecarFixtures.sidecarWrappedWithMainKey,
            expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
            mainKey: Data(repeating: 9, count: 32),
            storedSidecarKey: nil)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_decryption_failed")
        }
        XCTAssertThrowsError(try LockedNoteCrypto.openNeoSidecarEnvelope(
            data: AppleSidecarFixtures.sidecarWrappedWithMainKey,
            expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
            mainKey: Data(repeating: 9, count: 16),
            storedSidecarKey: nil)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_sidecar_key_invalid")
        }
    }

    func testSidecarDeviceKeyAndPasswordOnlyPathsStayRejected() throws {
        var fields = try appleEnvelopeFields(AppleSidecarFixtures.sidecarWrappedWithMainKey)
        fields.metadata = try PropertyListSerialization.data(
            fromPropertyList: ["cipherVersion": 3, "objectIdentifier": AppleSidecarFixtures.objectIdentifier,
                               "accountKeyIdentifier": "device-key"],
            format: .binary, options: 0)
        XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
            password: AppleSidecarFixtures.password,
            data: archivedEnvelope(fields),
            expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier,
            sidecarKeys: try sidecarKeys(AppleSidecarFixtures.valuesWithSidecarKey))) {
            XCTAssertEqual(($0 as? NotesError)?.code, "device_key_locked_unsupported")
        }

        XCTAssertThrowsError(try LockedNoteCrypto.openNeoEnvelope(
            password: AppleSidecarFixtures.password,
            data: AppleSidecarFixtures.sidecarWrappedWithMainKey,
            expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_sidecar_unsupported")
        }
        XCTAssertThrowsError(try LockedNoteCrypto.open(
            password: AppleSidecarFixtures.password,
            encryptedBody: AppleSidecarFixtures.sidecarWrappedWithMainKey,
            legacy: nil)) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_sidecar_unsupported")
        }
    }

    private func sidecarKeys(_ valuesEnvelope: Data) throws -> LockedNoteCrypto.NeoSidecarKeys {
        let opened = try LockedNoteCrypto.openNeoEnvelopeVerifyingMainKey(
            password: AppleSidecarFixtures.password,
            data: valuesEnvelope,
            expectedObjectIdentifier: AppleSidecarFixtures.objectIdentifier)
        return .init(
            mainKey: opened.mainKey,
            encryptedValues: try JSONSerialization.jsonObject(with: opened.plaintext) as? [String: Any])
    }

    private func serializedSidecarKey(key: Data = AppleSidecarFixtures.sidecarKey,
                                      authenticated: [String: Any],
                                      unauthenticated: [String: Any] = [:]) throws -> Data {
        try plist([
            "key": key,
            "metadata": try plist(unauthenticated),
            "authenticatedData": try plist(authenticated),
        ])
    }

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private struct EnvelopeFields {
        var metadata: Data
        var unauthenticatedMetadata: Data
        var wrappedEncryptionKey: Data
        var encryptedData: Data
    }

    private func appleEnvelopeFields(_ data: Data) throws -> EnvelopeFields {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.setClass(EnvelopeFieldsReader.self, forClassName: "ICCryptoEncryptionObject")
        let reader = try XCTUnwrap(unarchiver.decodeObject(
            of: EnvelopeFieldsReader.self, forKey: NSKeyedArchiveRootObjectKey))
        return EnvelopeFields(
            metadata: reader.metadata,
            unauthenticatedMetadata: reader.unauthenticatedMetadata,
            wrappedEncryptionKey: reader.wrappedEncryptionKey,
            encryptedData: reader.encryptedData)
    }

    private func archivedEnvelope(_ fields: EnvelopeFields) throws -> Data {
        try archivedEnvelope(
            metadata: fields.metadata,
            unauthenticated: fields.unauthenticatedMetadata,
            wrappedKey: fields.wrappedEncryptionKey,
            encryptedData: fields.encryptedData)
    }

    private func hex(_ value: String) throws -> Data {
        guard value.count.isMultiple(of: 2) else { throw CocoaError(.coderInvalidValue) }
        return try stride(from: 0, to: value.count, by: 2).map { offset -> UInt8 in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: 2)
            guard let byte = UInt8(value[start..<end], radix: 16) else { throw CocoaError(.coderInvalidValue) }
            return byte
        }.reduce(into: Data()) { $0.append($1) }
    }

    private func currentEnvelope(password: String, body: Data,
                                 salt: Data = Data((0..<32).map(UInt8.init)),
                                 archivedMetadata: Data? = nil,
                                 archivedWrappedKey: Data? = nil,
                                 archivedIterationCount: NSNumber = 1_000) throws -> Data {
        let contentKey = Data((32..<64).map(UInt8.init))
        let iv = Data((64..<96).map(UInt8.init))
        let metadata = try metadata(objectIdentifier: "fixture")
        let passphrase = try PropertyListSerialization.data(
            fromPropertyList: [
                "passphraseSalt": salt,
                "passphraseIterationCount": archivedIterationCount,
            ],
            format: .binary,
            options: 0
        )
        let kek = try derive(password: password, salt: salt, iterations: 1_000, count: 32)
        let wrapped = try wrap(contentKey, with: kek)
        let sealed = try AES.GCM.seal(
            body,
            using: SymmetricKey(data: contentKey),
            nonce: AES.GCM.Nonce(data: iv),
            authenticating: metadata
        )
        return try archivedEnvelope(
            metadata: archivedMetadata ?? metadata,
            unauthenticated: passphrase,
            wrappedKey: archivedWrappedKey ?? wrapped,
            encryptedData: sealed.ciphertext + iv + sealed.tag
        )
    }

    private func metadata(objectIdentifier: String, cipherVersion: Int = 2,
                          extra: [String: Any] = [:]) throws -> Data {
        var values: [String: Any] = [
            "cipherVersion": cipherVersion,
            "objectIdentifier": objectIdentifier,
        ]
        for (key, value) in extra { values[key] = value }
        return try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .binary,
            options: 0)
    }

    private func appleEnvelope(_ name: String) -> Data {
        let fixtures = [
            "media.encryptedvaluesjson.bin": "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGnCwwXGBkaG1UkbnVsbNUNDg8QERITFBUWWG1ldGFkYXRhXxAXdW5hdXRoZW50aWNhdGVkTWV0YWRhdGFWJGNsYXNzXxAUd3JhcHBlZEVuY3J5cHRpb25LZXldZW5jcnlwdGVkRGF0YYADgAKABoAEgAVPEJpicGxpc3QwMNMBAgMEBQZecGFzc3BocmFzZVNhbHRfEBhwYXNzcGhyYXNlSXRlcmF0aW9uQ291bnRecGFzc3BocmFzZUhpbnRPECCgoaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+vxFOIFRoaW50CA8eOUhrbgAAAAAAAAEBAAAAAAAAAAcAAAAAAAAAAAAAAAAAAABzTxBeYnBsaXN0MDDSAQIDBF1jaXBoZXJWZXJzaW9uXxAQb2JqZWN0SWRlbnRpZmllchACWE1FRElBLUlECA0bLjAAAAAAAAABAQAAAAAAAAAFAAAAAAAAAAAAAAAAAAAAOU8QKDUdtYJ8KkbMtyGb4bXvmol4S1UdVXkpqQL1mqYum0OV+wDBRRI6ZSJPEGVRcGncMmj0V1xnuhX7nbZZW9NS6kX5h2Wj7sIIGH0z7dAz3YzuzizTbbpJgIWCo8tJHk1O9xxx+7UtIP1dPhInkxSBKmDCQiBd8o+0unp7YH9meJCSVUrC4fsP84DWQ1ia796oMtEcHVokY2xhc3NuYW1lXxAYSUNDcnlwdG9FbmNyeXB0aW9uT2JqZWN0AAgAEQAaACQAKQAyADcASQBMAFEAUwBbAGEAbAB1AI8AlgCtALsAvQC/AMEAwwDFAWIBwwHuAlYCWQJkAAAAAAAAAgEAAAAAAAAAHgAAAAAAAAAAAAAAAAAAAn8=",
            "media.file.bin": "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGnCwwXGBkaG1UkbnVsbNUNDg8QERITFBUWWG1ldGFkYXRhXxAXdW5hdXRoZW50aWNhdGVkTWV0YWRhdGFWJGNsYXNzXxAUd3JhcHBlZEVuY3J5cHRpb25LZXldZW5jcnlwdGVkRGF0YYADgAKABoAEgAVPEJpicGxpc3QwMNMBAgMEBQZecGFzc3BocmFzZVNhbHRfEBhwYXNzcGhyYXNlSXRlcmF0aW9uQ291bnRecGFzc3BocmFzZUhpbnRPECCgoaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+vxFOIFRoaW50CA8eOUhrbgAAAAAAAAEBAAAAAAAAAAcAAAAAAAAAAAAAAAAAAABzTxBeYnBsaXN0MDDSAQIDBF1jaXBoZXJWZXJzaW9uXxAQb2JqZWN0SWRlbnRpZmllchACWE1FRElBLUlECA0bLjAAAAAAAAABAQAAAAAAAAAFAAAAAAAAAAAAAAAAAAAAOU8QKDUdtYJ8KkbMtyGb4bXvmol4S1UdVXkpqQL1mqYum0OV+wDBRRI6ZSJPEECJiUN8zXPchbxyijw1AfG7uhfJUtTTReiXE2J6R+KMreVoLUj8Y0UmXW8ONyds69x64soQicuj0w95JptaAaOC0RwdWiRjbGFzc25hbWVfEBhJQ0NyeXB0b0VuY3J5cHRpb25PYmplY3QACAARABoAJAApADIANwBJAEwAUQBTAFsAYQBsAHUAjwCWAK0AuwC9AL8AwQDDAMUBYgHDAe4CMQI0Aj8AAAAAAAACAQAAAAAAAAAeAAAAAAAAAAAAAAAAAAACWg==",
            "fallbackimage.encrypted.bin": "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGnCwwXGBkaG1UkbnVsbNUNDg8QERITFBUWWG1ldGFkYXRhXxAXdW5hdXRoZW50aWNhdGVkTWV0YWRhdGFWJGNsYXNzXxAUd3JhcHBlZEVuY3J5cHRpb25LZXldZW5jcnlwdGVkRGF0YYADgAKABoAEgAVPEJpicGxpc3QwMNMBAgMEBQZecGFzc3BocmFzZVNhbHRfEBhwYXNzcGhyYXNlSXRlcmF0aW9uQ291bnRecGFzc3BocmFzZUhpbnRPECCgoaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+vxFOIFRoaW50CA8eOUhrbgAAAAAAAAEBAAAAAAAAAAcAAAAAAAAAAAAAAAAAAABzTxBjYnBsaXN0MDDSAQIDBF1jaXBoZXJWZXJzaW9uXxAQb2JqZWN0SWRlbnRpZmllchACXUFUVEFDSE1FTlQtSUQIDRsuMAAAAAAAAAEBAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAA+TxAoNR21gnwqRsy3IZvhte+aiXhLVR1VeSmpAvWapi6bQ5X7AMFFEjplIk8QQGTbILXvoQ9pF2vIYheoZDtfUJJ9nRBMG74J7HqWvlkl7nFH4EYH0u1+BjJ0KcOhMJhG0IFkUI5JaZoi599YRBTRHB1aJGNsYXNzbmFtZV8QGElDQ3J5cHRvRW5jcnlwdGlvbk9iamVjdAAIABEAGgAkACkAMgA3AEkATABRAFMAWwBhAGwAdQCPAJYArQC7AL0AvwDBAMMAxQFiAcgB8wI2AjkCRAAAAAAAAAIBAAAAAAAAAB4AAAAAAAAAAAAAAAAAAAJf",
        ]
        return Data(base64Encoded: fixtures[name]!)!
    }

    private func archivedEnvelope(metadata: Data, unauthenticated: Data,
                                  wrappedKey: Data, encryptedData: Data) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("ICCryptoEncryptionObject", for: EnvelopeFixture.self)
        archiver.encode(EnvelopeFixture(
            metadata: metadata,
            unauthenticatedMetadata: unauthenticated,
            wrappedEncryptionKey: wrappedKey,
            encryptedData: encryptedData
        ), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private func derive(password: String, salt: Data, iterations: Int, count: Int) throws -> Data {
        let password = Data(password.utf8)
        var result = Data(count: count)
        let status = result.withUnsafeMutableBytes { resultBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        resultBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        return result
    }

    private func wrap(_ key: Data, with kek: Data) throws -> Data {
        var output = Data(count: CCSymmetricWrappedSize(CCWrappingAlgorithm(kCCWRAPAES), key.count))
        var count = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            key.withUnsafeBytes { keyBytes in
                kek.withUnsafeBytes { kekBytes in
                    CCSymmetricKeyWrap(
                        CCWrappingAlgorithm(kCCWRAPAES), CCrfc3394_iv, CCrfc3394_ivLen,
                        kekBytes.baseAddress, kek.count, keyBytes.baseAddress, key.count,
                        outputBytes.baseAddress, &count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        return output.prefix(count)
    }
}

@objc(NotesCLILockedEnvelopeFixture)
private final class EnvelopeFixture: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let metadata: Data
    let unauthenticatedMetadata: Data
    let wrappedEncryptionKey: Data
    let encryptedData: Data

    init(metadata: Data, unauthenticatedMetadata: Data, wrappedEncryptionKey: Data, encryptedData: Data) {
        self.metadata = metadata
        self.unauthenticatedMetadata = unauthenticatedMetadata
        self.wrappedEncryptionKey = wrappedEncryptionKey
        self.encryptedData = encryptedData
    }

    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        coder.encode(metadata as NSData, forKey: "metadata")
        coder.encode(unauthenticatedMetadata as NSData, forKey: "unauthenticatedMetadata")
        coder.encode(wrappedEncryptionKey as NSData, forKey: "wrappedEncryptionKey")
        coder.encode(encryptedData as NSData, forKey: "encryptedData")
    }
}

@objc(NotesCLILockedEnvelopeFieldsReader)
private final class EnvelopeFieldsReader: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let metadata: Data
    let unauthenticatedMetadata: Data
    let wrappedEncryptionKey: Data
    let encryptedData: Data

    required init?(coder: NSCoder) {
        guard let metadata = coder.decodeObject(of: NSData.self, forKey: "metadata") as? Data,
              let unauthenticated = coder.decodeObject(of: NSData.self, forKey: "unauthenticatedMetadata") as? Data,
              let wrapped = coder.decodeObject(of: NSData.self, forKey: "wrappedEncryptionKey") as? Data,
              let encrypted = coder.decodeObject(of: NSData.self, forKey: "encryptedData") as? Data else {
            return nil
        }
        self.metadata = metadata
        unauthenticatedMetadata = unauthenticated
        wrappedEncryptionKey = wrapped
        encryptedData = encrypted
    }

    func encode(with coder: NSCoder) {}
}
