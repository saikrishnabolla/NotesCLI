import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import NotesStore
import NotesCore

final class LockedAttachmentExtractionTests: XCTestCase {
    func testLegacyAssetDecryptsWithinSecureScopeAndCleansUp() throws {
        let fixture = try LockedAttachmentFixture(variant: .asset)
        let store = try fixture.store()
        var extractedPath: String?

        try store.withPasswordUnlockedNote("LOCKED", password: fixture.password) { note in
            let attachment = try XCTUnwrap(note.attachments.first)
            let path = try XCTUnwrap(attachment.filePath)
            extractedPath = path
            XCTAssertEqual(attachment.filename, "research.bin")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), fixture.plaintext)
            XCTAssertEqual(try permissions(URL(fileURLWithPath: path).deletingLastPathComponent()), 0o700)
            XCTAssertEqual(try permissions(URL(fileURLWithPath: path)), 0o600)
        }

        XCTAssertNotNil(extractedPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractedPath!))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: extractedPath!).deletingLastPathComponent().path))
        XCTAssertNotEqual(try fixture.sourceBytes(), fixture.plaintext)
    }

    func testLegacyFallbackImageUsesFallbackImageCryptoFields() throws {
        try assertExactExtraction(.fallbackImage, expectedFilename: "FallbackImage.png")
    }

    func testLegacyFallbackPDFUsesFallbackPDFCryptoFields() throws {
        try assertExactExtraction(.fallbackPDF, expectedFilename: "FallbackPDF.pdf")
    }

    func testOlderFallbackPDFUsesStandardCryptoFields() throws {
        try assertExactExtraction(.olderFallbackPDF, expectedFilename: "FallbackPDF.pdf")
    }

    func testLegacyPreviewUsesStandardCryptoFields() throws {
        try assertExactExtraction(.preview, expectedFilename: "attachment.png")
    }

    func testWrongPasswordAndTamperingFailClosed() throws {
        let wrongPasswordFixture = try LockedAttachmentFixture(variant: .asset)
        XCTAssertThrowsError(try wrongPasswordFixture.store().withPasswordUnlockedNote(
            "LOCKED", password: "wrong-password") { _ in XCTFail("The callback must not run.")
        }) {
            XCTAssertEqual(($0 as? NotesError)?.code, "wrong_password")
        }

        let tamperedFixture = try LockedAttachmentFixture(variant: .asset)
        try tamperedFixture.tamperSource()
        XCTAssertThrowsError(try tamperedFixture.store().withPasswordUnlockedNote(
            "LOCKED", password: tamperedFixture.password) { _ in XCTFail("The callback must not run.")
        }) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_decryption_failed")
        }
    }

    func testEncryptedAssetSymlinkIsRejectedWithoutFollowingIt() throws {
        let fixture = try LockedAttachmentFixture(variant: .asset)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-locked-attachment-outside-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try fixture.moveSourceAndReplaceWithSymlink(to: outside)

        XCTAssertThrowsError(try fixture.store().withPasswordUnlockedNote(
            "LOCKED", password: fixture.password) { _ in XCTFail("The callback must not run.")
        }) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_unsafe_file")
        }
        XCTAssertNotEqual(try Data(contentsOf: outside), fixture.plaintext)
    }

    func testEncryptedAssetParentSymlinkIsRejectedWithoutFollowingIt() throws {
        let fixture = try LockedAttachmentFixture(variant: .asset)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-locked-attachment-parent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try fixture.moveSourceParentAndReplaceWithSymlink(to: outside)

        XCTAssertThrowsError(try fixture.store().withPasswordUnlockedNote(
            "LOCKED", password: fixture.password) { _ in XCTFail("The callback must not run.")
        }) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_unsafe_file")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("media-id").path))
    }

    func testIncompleteAssetCryptoFailsExplicitly() throws {
        let fixture = try LockedAttachmentFixture(variant: .asset)
        try fixture.removeAssetTag()
        XCTAssertThrowsError(try fixture.store().withPasswordUnlockedNote(
            "LOCKED", password: fixture.password) { _ in XCTFail("The callback must not run.")
        }) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_invalid")
        }
    }

    func testTemporaryPlaintextIsRemovedWhenConsumerThrows() throws {
        struct ConsumerFailure: Error {}
        let fixture = try LockedAttachmentFixture(variant: .asset)
        var extractedPath: String?
        XCTAssertThrowsError(try fixture.store().withPasswordUnlockedNote(
            "LOCKED", password: fixture.password
        ) { note in
            extractedPath = try XCTUnwrap(note.attachments.first?.filePath)
            throw ConsumerFailure()
        }) { XCTAssertTrue($0 is ConsumerFailure) }
        XCTAssertNotNil(extractedPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractedPath!))
    }

    func testConsumerCanExportBeforeTemporaryPlaintextCleanup() throws {
        let fixture = try LockedAttachmentFixture(variant: .asset)
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-locked-attachment-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: exportDirectory) }
        let exported = exportDirectory.appendingPathComponent("research.bin")
        var temporaryPath: String?

        try fixture.store().withPasswordUnlockedNote("LOCKED", password: fixture.password) { note in
            temporaryPath = try XCTUnwrap(note.attachments.first?.filePath)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: temporaryPath!),
                to: exported)
        }

        XCTAssertEqual(try Data(contentsOf: exported), fixture.plaintext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(temporaryPath)))
    }

    func testNeoAssetDecryptsValuesAndFileWhileIgnoringLegacyDecoyColumns() throws {
        let fixture = try LockedAttachmentFixture(variant: .neoAsset)
        var extractedPath: String?

        try fixture.withExtractedAttachment { attachment in
            extractedPath = try XCTUnwrap(attachment.filePath)
            XCTAssertEqual(attachment.filename, "photo.png")
            XCTAssertEqual(attachment.row.data("ZMARKUPMODELDATA"), Data("markup".utf8))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: extractedPath!)), fixture.plaintext)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(extractedPath)))
    }

    func testNeoFallbackImageDecryptsWithAttachmentIdentity() throws {
        let fixture = try LockedAttachmentFixture(variant: .neoFallbackImage)
        try fixture.withExtractedAttachment { attachment in
            XCTAssertEqual(attachment.filename, "FallbackImage.png")
            XCTAssertEqual(
                try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(attachment.filePath))),
                fixture.plaintext)
        }
    }

    func testNeoFileWithWrongObjectIdentityFailsClosed() throws {
        let fixture = try LockedAttachmentFixture(variant: .neoAsset)
        try fixture.replaceNeoMediaFileWithFallbackEnvelope()
        XCTAssertThrowsError(try fixture.withExtractedAttachment { _ in
            XCTFail("The callback must not run.")
        }) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_identity_mismatch")
        }
    }

    func testDeviceKeyLockedAttachmentIsExplicitlyUnsupported() throws {
        let fixture = try LockedAttachmentFixture(variant: .deviceKeyAsset)
        XCTAssertThrowsError(try fixture.store().withPasswordUnlockedNote(
            "LOCKED", password: fixture.password) { _ in XCTFail("The callback must not run.")
        }) {
            XCTAssertEqual(($0 as? NotesError)?.code, "device_key_locked_unsupported")
        }
    }

    func testPendingEncryptedRecordIsExplicitlyUnsupported() throws {
        let fixture = try LockedAttachmentFixture(variant: .asset)
        try fixture.addPendingEncryptedRecord()
        XCTAssertThrowsError(try fixture.store().withPasswordUnlockedNote(
            "LOCKED", password: fixture.password) { _ in XCTFail("The callback must not run.")
        }) {
            XCTAssertEqual(($0 as? NotesError)?.code, "locked_attachment_unapplied_record_unsupported")
        }
    }

    private func assertExactExtraction(_ variant: LockedAttachmentFixture.Variant,
                                       expectedFilename: String) throws {
        let fixture = try LockedAttachmentFixture(variant: variant)
        var path: String?
        try fixture.store().withPasswordUnlockedNote("LOCKED", password: fixture.password) { note in
            let attachment = try XCTUnwrap(note.attachments.first)
            path = try XCTUnwrap(attachment.filePath)
            XCTAssertEqual(attachment.filename, expectedFilename)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path!)), fixture.plaintext)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path!))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class LockedAttachmentFixture {
    enum Variant {
        case asset, fallbackImage, fallbackPDF, olderFallbackPDF, preview
        case neoAsset, neoFallbackImage, deviceKeyAsset
    }

    let password: String
    let plaintext: Data
    let directory: URL
    let database: URL
    private var connection: OpaquePointer?
    private var source: URL!

    init(variant: Variant) throws {
        let isNeo = variant == .neoAsset || variant == .neoFallbackImage
        password = isNeo ? "Cafe\u{301}-neo" : "fixture-password"
        plaintext = isNeo
            ? Data(base64Encoded: "iVBORw0KGgoBAgMEBQYHCA==")!
            : Data("exact locked attachment bytes\u{0}\u{1}".utf8)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notescli-locked-attachment-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        database = directory.appendingPathComponent("NoteStore.sqlite")
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else {
            throw NotesError("fixture", "Cannot create locked attachment fixture.")
        }
        try sql("""
        CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, Z_NAME TEXT, Z_SUPER INTEGER);
        INSERT INTO Z_PRIMARYKEY VALUES
          (1,'ICNote',0),(2,'ICFolder',0),(3,'ICAccount',0),(4,'ICAttachment',0),(5,'ICMedia',0),(6,'ICNoteData',0);
        CREATE TABLE Z_METADATA (Z_UUID TEXT); INSERT INTO Z_METADATA VALUES ('LOCKED-FIXTURE');
        CREATE TABLE ZICCLOUDSYNCINGOBJECT (
          Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER TEXT, ZNAME TEXT, ZACCOUNTTYPE INTEGER,
          ZTITLE1 TEXT, ZTITLE2 TEXT, ZOWNER INTEGER, ZFOLDER INTEGER, ZNOTEDATA INTEGER,
          ZISPASSWORDPROTECTED INTEGER, ZMARKEDFORDELETION INTEGER, ZNOTE INTEGER, ZTYPEUTI TEXT,
          ZMEDIA INTEGER, ZFILENAME TEXT, ZGENERATION1 TEXT, ZFALLBACKIMAGEGENERATION TEXT,
          ZFALLBACKPDFGENERATION TEXT, ZCRYPTOSALT BLOB, ZCRYPTOITERATIONCOUNT INTEGER,
          ZCRYPTOWRAPPEDKEY BLOB, ZCRYPTOVERIFIER BLOB, ZCRYPTOINITIALIZATIONVECTOR BLOB,
          ZCRYPTOTAG BLOB, ZENCRYPTEDVALUESJSON BLOB, ZASSETCRYPTOINITIALIZATIONVECTOR BLOB,
          ZASSETCRYPTOTAG BLOB, ZFALLBACKIMAGECRYPTOINITIALIZATIONVECTOR BLOB,
          ZFALLBACKIMAGECRYPTOTAG BLOB, ZFALLBACKPDFCRYPTOINITIALIZATIONVECTOR BLOB,
          ZFALLBACKPDFCRYPTOTAG BLOB, ZUNAPPLIEDENCRYPTEDRECORDDATA BLOB);
        CREATE TABLE ZICNOTEDATA (
          Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZNOTE INTEGER, ZDATA BLOB,
          ZCRYPTOINITIALIZATIONVECTOR BLOB, ZCRYPTOTAG BLOB);
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZNAME,ZACCOUNTTYPE)
          VALUES (1,3,'account','Cloud',1);
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZTITLE2,ZOWNER)
          VALUES (2,2,'folder','Notes',1);
        INSERT INTO ZICCLOUDSYNCINGOBJECT
          (Z_PK,Z_ENT,ZIDENTIFIER,ZTITLE1,ZFOLDER,ZNOTEDATA,ZISPASSWORDPROTECTED,ZMARKEDFORDELETION)
          VALUES (3,1,'LOCKED','Locked',2,30,1,0);
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZNOTE,ZTYPEUTI,ZMEDIA)
          VALUES (4,4,'attachment',3,'public.data',5);
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZGENERATION1)
          VALUES (5,5,'media-id','generation');
        """)

        let body = Self.protobufBody("Locked body")
        if variant == .deviceKeyAsset {
            let envelope = try Self.currentEnvelope(
                password: password, body: body, deviceKey: true)
            try sql("""
            INSERT INTO ZICNOTEDATA (Z_PK,Z_ENT,ZNOTE,ZDATA)
              VALUES (30,6,3,X'\(envelope.hex)');
            """)
        } else {
            let bodyCrypto = try Self.crypto(password: password, seed: 1)
            let sealedBody = try bodyCrypto.seal(body, ivByte: 21)
            try sql("""
            UPDATE ZICCLOUDSYNCINGOBJECT SET
              ZCRYPTOSALT=X'\(bodyCrypto.salt.hex)', ZCRYPTOITERATIONCOUNT=\(bodyCrypto.iterations),
              ZCRYPTOWRAPPEDKEY=X'\(bodyCrypto.wrappedKey.hex)'
            WHERE Z_PK=3;
            INSERT INTO ZICNOTEDATA
              (Z_PK,Z_ENT,ZNOTE,ZDATA,ZCRYPTOINITIALIZATIONVECTOR,ZCRYPTOTAG)
            VALUES (30,6,3,X'\(sealedBody.ciphertext.hex)',X'\(sealedBody.iv.hex)',X'\(sealedBody.tag.hex)');
            """)
        }

        let mediaCrypto = try Self.crypto(password: password, seed: 70)
        let sealedAsset = try mediaCrypto.seal(plaintext, ivByte: 121)
        var sourceData = sealedAsset.ciphertext
        switch variant {
        case .asset, .deviceKeyAsset:
            let metadata = try JSONSerialization.data(withJSONObject: ["filename": "research.bin"])
            let sealedMetadata = try mediaCrypto.seal(metadata, ivByte: 101)
            try sql("""
            UPDATE ZICCLOUDSYNCINGOBJECT SET
              ZCRYPTOSALT=X'\(mediaCrypto.salt.hex)', ZCRYPTOITERATIONCOUNT=\(mediaCrypto.iterations),
              ZCRYPTOWRAPPEDKEY=X'\(mediaCrypto.wrappedKey.hex)',
              ZCRYPTOINITIALIZATIONVECTOR=X'\(sealedMetadata.iv.hex)', ZCRYPTOTAG=X'\(sealedMetadata.tag.hex)',
              ZENCRYPTEDVALUESJSON=X'\(sealedMetadata.ciphertext.hex)',
              ZASSETCRYPTOINITIALIZATIONVECTOR=X'\(sealedAsset.iv.hex)', ZASSETCRYPTOTAG=X'\(sealedAsset.tag.hex)'
            WHERE Z_PK=5;
            """)
            source = directory.appendingPathComponent("Accounts/account/Media/media-id/generation/media-id")
        case .fallbackImage:
            try setAttachmentCrypto(
                mediaCrypto, iv: sealedAsset.iv, tag: sealedAsset.tag,
                columns: ("ZFALLBACKIMAGECRYPTOINITIALIZATIONVECTOR", "ZFALLBACKIMAGECRYPTOTAG"),
                generationColumn: "ZFALLBACKIMAGEGENERATION")
            source = directory.appendingPathComponent("Accounts/account/FallbackImages/attachment/generation/FallbackImage.png.encrypted")
        case .fallbackPDF:
            try setAttachmentCrypto(
                mediaCrypto, iv: sealedAsset.iv, tag: sealedAsset.tag,
                columns: ("ZFALLBACKPDFCRYPTOINITIALIZATIONVECTOR", "ZFALLBACKPDFCRYPTOTAG"),
                generationColumn: "ZFALLBACKPDFGENERATION")
            source = directory.appendingPathComponent("Accounts/account/FallbackPDFs/attachment/generation/FallbackPDF.pdf.encrypted")
        case .olderFallbackPDF:
            try setAttachmentCrypto(
                mediaCrypto, iv: sealedAsset.iv, tag: sealedAsset.tag,
                columns: ("ZCRYPTOINITIALIZATIONVECTOR", "ZCRYPTOTAG"),
                generationColumn: "ZFALLBACKPDFGENERATION")
            source = directory.appendingPathComponent("Accounts/account/FallbackPDFs/attachment/generation/FallbackPDF.pdf.encrypted")
        case .preview:
            try setAttachmentCrypto(
                mediaCrypto, iv: sealedAsset.iv, tag: sealedAsset.tag,
                columns: ("ZCRYPTOINITIALIZATIONVECTOR", "ZCRYPTOTAG"), generationColumn: "ZGENERATION1")
            source = directory.appendingPathComponent("Accounts/account/Previews/attachment.png.encrypted")
        case .neoAsset:
            let values = Self.neoEnvelope("media.encryptedvaluesjson.bin")
            sourceData = Self.neoEnvelope("media.file.bin")
            try sql("""
            UPDATE ZICCLOUDSYNCINGOBJECT SET
              ZIDENTIFIER='MEDIA-ID',
              ZCRYPTOSALT=zeroblob(16), ZCRYPTOITERATIONCOUNT=1,
              ZCRYPTOWRAPPEDKEY=zeroblob(16),
              ZCRYPTOINITIALIZATIONVECTOR=zeroblob(16), ZCRYPTOTAG=zeroblob(16),
              ZENCRYPTEDVALUESJSON=X'\(values.hex)',
              ZASSETCRYPTOINITIALIZATIONVECTOR=zeroblob(16), ZASSETCRYPTOTAG=zeroblob(16)
            WHERE Z_PK=5;
            """)
            source = directory.appendingPathComponent("Accounts/account/Media/MEDIA-ID/generation/MEDIA-ID")
        case .neoFallbackImage:
            sourceData = Self.neoEnvelope("fallbackimage.encrypted.bin")
            try sql("""
            UPDATE ZICCLOUDSYNCINGOBJECT SET
              ZIDENTIFIER='ATTACHMENT-ID', ZMEDIA=NULL, ZFALLBACKIMAGEGENERATION='generation',
              ZCRYPTOSALT=zeroblob(16), ZCRYPTOITERATIONCOUNT=1,
              ZCRYPTOWRAPPEDKEY=zeroblob(16),
              ZCRYPTOINITIALIZATIONVECTOR=zeroblob(16), ZCRYPTOTAG=zeroblob(16),
              ZFALLBACKIMAGECRYPTOINITIALIZATIONVECTOR=zeroblob(16),
              ZFALLBACKIMAGECRYPTOTAG=zeroblob(16)
            WHERE Z_PK=4;
            """)
            source = directory.appendingPathComponent(
                "Accounts/account/FallbackImages/ATTACHMENT-ID/generation/FallbackImage.png.encrypted")
        }
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sourceData.write(to: source)
    }

    deinit {
        if let connection { sqlite3_close(connection) }
        try? FileManager.default.removeItem(at: directory)
    }

    func store() throws -> SQLiteNotesStore {
        try SQLiteNotesStore(databaseURL: database, groupContainerURL: directory, refresh: true)
    }

    func tamperSource() throws {
        var data = try Data(contentsOf: source)
        data[0] ^= 0xff
        try data.write(to: source)
    }

    func moveSourceAndReplaceWithSymlink(to target: URL) throws {
        try FileManager.default.moveItem(at: source, to: target)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
    }

    func moveSourceParentAndReplaceWithSymlink(to target: URL) throws {
        let parent = source.deletingLastPathComponent()
        try FileManager.default.moveItem(at: parent, to: target)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: target)
    }

    func sourceBytes() throws -> Data { try Data(contentsOf: source) }

    func withExtractedAttachment(_ body: (LockedAttachmentResult) throws -> Void) throws {
        let library = try SQLiteSnapshot.load(database)
        let row = try XCTUnwrap(library.objects[4])
        let scope = try LockedAttachmentExtractionScope()
        defer { scope.cleanup() }
        try body(try LockedAttachmentExtractor(
            library: library,
            container: directory,
            accountID: "account",
            password: password,
            scope: scope
        ).extract(row))
    }

    func replaceNeoMediaFileWithFallbackEnvelope() throws {
        try Self.neoEnvelope("fallbackimage.encrypted.bin").write(to: source)
    }

    func removeAssetTag() throws {
        try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZASSETCRYPTOTAG=NULL WHERE Z_PK=5;")
    }

    func addPendingEncryptedRecord() throws {
        try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZUNAPPLIEDENCRYPTEDRECORDDATA=X'01' WHERE Z_PK=4;")
    }

    private func setAttachmentCrypto(_ crypto: TestCrypto, iv: Data, tag: Data,
                                     columns: (String, String), generationColumn: String) throws {
        try sql("""
        UPDATE ZICCLOUDSYNCINGOBJECT SET
          ZMEDIA=NULL, \(generationColumn)='generation',
          ZCRYPTOSALT=X'\(crypto.salt.hex)', ZCRYPTOITERATIONCOUNT=\(crypto.iterations),
          ZCRYPTOWRAPPEDKEY=X'\(crypto.wrappedKey.hex)',
          \(columns.0)=X'\(iv.hex)', \(columns.1)=X'\(tag.hex)'
        WHERE Z_PK=4;
        """)
    }

    private func sql(_ statement: String) throws {
        guard sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK else {
            throw NotesError("fixture_sql", "Locked attachment fixture SQL failed.")
        }
    }

    private static func protobufBody(_ text: String) -> Data {
        bytes(2, bytes(3, string(2, text)))
    }

    private static func varint(_ value: Int) -> Data {
        var value = value
        var data = Data()
        repeat {
            let byte = UInt8(value & 127)
            value >>= 7
            data.append(value > 0 ? byte | 128 : byte)
        } while value > 0
        return data
    }

    private static func bytes(_ field: Int, _ value: Data) -> Data {
        varint(field << 3 | 2) + varint(value.count) + value
    }

    private static func string(_ field: Int, _ value: String) -> Data {
        bytes(field, Data(value.utf8))
    }

    private static func crypto(password: String, seed: UInt8) throws -> TestCrypto {
        let salt = Data((0..<16).map { seed &+ UInt8($0) })
        let dataKey = Data((0..<16).map { seed &+ 32 &+ UInt8($0) })
        let iterations = 1_000
        let kek = try derive(password: password, salt: salt, iterations: iterations, count: dataKey.count)
        return TestCrypto(salt: salt, iterations: iterations, dataKey: dataKey,
                          wrappedKey: try wrap(dataKey, with: kek))
    }

    private static func currentEnvelope(password: String, body: Data, deviceKey: Bool) throws -> Data {
        let salt = Data((0..<32).map(UInt8.init))
        let dataKey = Data((32..<64).map(UInt8.init))
        let iv = Data((64..<96).map(UInt8.init))
        var metadataValues: [String: Any] = ["cipherVersion": 2, "objectIdentifier": "fixture"]
        if deviceKey { metadataValues["accountKeyIdentifier"] = "fixture-device-key" }
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: metadataValues,
            format: .binary, options: 0)
        let unauthenticated = try PropertyListSerialization.data(
            fromPropertyList: ["passphraseSalt": salt, "passphraseIterationCount": 1_000],
            format: .binary, options: 0)
        let kek = try derive(password: password, salt: salt, iterations: 1_000, count: dataKey.count)
        let wrapped = try wrap(dataKey, with: kek)
        let sealed = try AES.GCM.seal(
            body, using: SymmetricKey(data: dataKey), nonce: AES.GCM.Nonce(data: iv),
            authenticating: metadata)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("ICCryptoEncryptionObject", for: LockedAttachmentEnvelopeFixture.self)
        archiver.encode(LockedAttachmentEnvelopeFixture(
            metadata: metadata, unauthenticatedMetadata: unauthenticated,
            wrappedEncryptionKey: wrapped, encryptedData: sealed.ciphertext + iv + sealed.tag),
            forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func neoEnvelope(_ name: String) -> Data {
        let fixtures = [
            "media.encryptedvaluesjson.bin": "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGnCwwXGBkaG1UkbnVsbNUNDg8QERITFBUWWG1ldGFkYXRhXxAXdW5hdXRoZW50aWNhdGVkTWV0YWRhdGFWJGNsYXNzXxAUd3JhcHBlZEVuY3J5cHRpb25LZXldZW5jcnlwdGVkRGF0YYADgAKABoAEgAVPEJpicGxpc3QwMNMBAgMEBQZecGFzc3BocmFzZVNhbHRfEBhwYXNzcGhyYXNlSXRlcmF0aW9uQ291bnRecGFzc3BocmFzZUhpbnRPECCgoaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+vxFOIFRoaW50CA8eOUhrbgAAAAAAAAEBAAAAAAAAAAcAAAAAAAAAAAAAAAAAAABzTxBeYnBsaXN0MDDSAQIDBF1jaXBoZXJWZXJzaW9uXxAQb2JqZWN0SWRlbnRpZmllchACWE1FRElBLUlECA0bLjAAAAAAAAABAQAAAAAAAAAFAAAAAAAAAAAAAAAAAAAAOU8QKDUdtYJ8KkbMtyGb4bXvmol4S1UdVXkpqQL1mqYum0OV+wDBRRI6ZSJPEGVRcGncMmj0V1xnuhX7nbZZW9NS6kX5h2Wj7sIIGH0z7dAz3YzuzizTbbpJgIWCo8tJHk1O9xxx+7UtIP1dPhInkxSBKmDCQiBd8o+0unp7YH9meJCSVUrC4fsP84DWQ1ia796oMtEcHVokY2xhc3NuYW1lXxAYSUNDcnlwdG9FbmNyeXB0aW9uT2JqZWN0AAgAEQAaACQAKQAyADcASQBMAFEAUwBbAGEAbAB1AI8AlgCtALsAvQC/AMEAwwDFAWIBwwHuAlYCWQJkAAAAAAAAAgEAAAAAAAAAHgAAAAAAAAAAAAAAAAAAAn8=",
            "media.file.bin": "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGnCwwXGBkaG1UkbnVsbNUNDg8QERITFBUWWG1ldGFkYXRhXxAXdW5hdXRoZW50aWNhdGVkTWV0YWRhdGFWJGNsYXNzXxAUd3JhcHBlZEVuY3J5cHRpb25LZXldZW5jcnlwdGVkRGF0YYADgAKABoAEgAVPEJpicGxpc3QwMNMBAgMEBQZecGFzc3BocmFzZVNhbHRfEBhwYXNzcGhyYXNlSXRlcmF0aW9uQ291bnRecGFzc3BocmFzZUhpbnRPECCgoaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+vxFOIFRoaW50CA8eOUhrbgAAAAAAAAEBAAAAAAAAAAcAAAAAAAAAAAAAAAAAAABzTxBeYnBsaXN0MDDSAQIDBF1jaXBoZXJWZXJzaW9uXxAQb2JqZWN0SWRlbnRpZmllchACWE1FRElBLUlECA0bLjAAAAAAAAABAQAAAAAAAAAFAAAAAAAAAAAAAAAAAAAAOU8QKDUdtYJ8KkbMtyGb4bXvmol4S1UdVXkpqQL1mqYum0OV+wDBRRI6ZSJPEECJiUN8zXPchbxyijw1AfG7uhfJUtTTReiXE2J6R+KMreVoLUj8Y0UmXW8ONyds69x64soQicuj0w95JptaAaOC0RwdWiRjbGFzc25hbWVfEBhJQ0NyeXB0b0VuY3J5cHRpb25PYmplY3QACAARABoAJAApADIANwBJAEwAUQBTAFsAYQBsAHUAjwCWAK0AuwC9AL8AwQDDAMUBYgHDAe4CMQI0Aj8AAAAAAAACAQAAAAAAAAAeAAAAAAAAAAAAAAAAAAACWg==",
            "fallbackimage.encrypted.bin": "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGnCwwXGBkaG1UkbnVsbNUNDg8QERITFBUWWG1ldGFkYXRhXxAXdW5hdXRoZW50aWNhdGVkTWV0YWRhdGFWJGNsYXNzXxAUd3JhcHBlZEVuY3J5cHRpb25LZXldZW5jcnlwdGVkRGF0YYADgAKABoAEgAVPEJpicGxpc3QwMNMBAgMEBQZecGFzc3BocmFzZVNhbHRfEBhwYXNzcGhyYXNlSXRlcmF0aW9uQ291bnRecGFzc3BocmFzZUhpbnRPECCgoaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+vxFOIFRoaW50CA8eOUhrbgAAAAAAAAEBAAAAAAAAAAcAAAAAAAAAAAAAAAAAAABzTxBjYnBsaXN0MDDSAQIDBF1jaXBoZXJWZXJzaW9uXxAQb2JqZWN0SWRlbnRpZmllchACXUFUVEFDSE1FTlQtSUQIDRsuMAAAAAAAAAEBAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAA+TxAoNR21gnwqRsy3IZvhte+aiXhLVR1VeSmpAvWapi6bQ5X7AMFFEjplIk8QQGTbILXvoQ9pF2vIYheoZDtfUJJ9nRBMG74J7HqWvlkl7nFH4EYH0u1+BjJ0KcOhMJhG0IFkUI5JaZoi599YRBTRHB1aJGNsYXNzbmFtZV8QGElDQ3J5cHRvRW5jcnlwdGlvbk9iamVjdAAIABEAGgAkACkAMgA3AEkATABRAFMAWwBhAGwAdQCPAJYArQC7AL0AvwDBAMMAxQFiAcgB8wI2AjkCRAAAAAAAAAIBAAAAAAAAAB4AAAAAAAAAAAAAAAAAAAJf",
        ]
        return Data(base64Encoded: fixtures[name]!)!
    }

    private static func derive(password: String, salt: Data, iterations: Int, count: Int) throws -> Data {
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
                        resultBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), count)
                }
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        return result
    }

    private static func wrap(_ key: Data, with kek: Data) throws -> Data {
        var output = Data(count: CCSymmetricWrappedSize(CCWrappingAlgorithm(kCCWRAPAES), key.count))
        var count = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            key.withUnsafeBytes { keyBytes in
                kek.withUnsafeBytes { kekBytes in
                    CCSymmetricKeyWrap(
                        CCWrappingAlgorithm(kCCWRAPAES), CCrfc3394_iv, CCrfc3394_ivLen,
                        kekBytes.baseAddress, kek.count, keyBytes.baseAddress, key.count,
                        outputBytes.baseAddress, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        return output.prefix(count)
    }
}

private struct TestCrypto {
    let salt: Data
    let iterations: Int
    let dataKey: Data
    let wrappedKey: Data

    func seal(_ plaintext: Data, ivByte: UInt8) throws -> (iv: Data, tag: Data, ciphertext: Data) {
        let iv = Data(repeating: ivByte, count: 16)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: dataKey),
            nonce: AES.GCM.Nonce(data: iv))
        return (iv, sealed.tag, sealed.ciphertext)
    }
}

@objc(NotesCLILockedAttachmentEnvelopeFixture)
private final class LockedAttachmentEnvelopeFixture: NSObject, NSSecureCoding {
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

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
