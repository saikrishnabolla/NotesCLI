import Foundation
import XCTest
import SQLite3
@testable import NotesStore
import NotesCore

private final class SyntheticLibrary {
    let directory: URL
    let database: URL
    var connection: OpaquePointer?
    init(alternateColumns: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = directory.appendingPathComponent("NoteStore.sqlite")
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else { throw NotesError("fixture", "Cannot create fixture") }
        try sql("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try sql("""
        CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, Z_NAME TEXT, Z_SUPER INTEGER);
        INSERT INTO Z_PRIMARYKEY VALUES (201,'ICNote',0),(202,'ICFolder',0),(203,'ICAccount',0),(204,'ICAttachment',0),(205,'ICInlineAttachment',0),(206,'ICMedia',0),(207,'ICHashtag',0),(208,'ICNoteData',0);
        CREATE TABLE Z_METADATA (Z_UUID TEXT); INSERT INTO Z_METADATA VALUES ('STORE-UUID');
        CREATE TABLE ZICCLOUDSYNCINGOBJECT (
          Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER TEXT, ZNAME TEXT, ZACCOUNTTYPE INTEGER,
          ZTITLE TEXT, ZTITLE1 TEXT, ZTITLE2 TEXT, ZSNIPPET TEXT, ZACCOUNT7 INTEGER, ZACCOUNT8 INTEGER, ZOWNER INTEGER,
          ZFOLDER INTEGER, ZPARENT INTEGER, ZFOLDERTYPE INTEGER, ZSMARTFOLDERQUERYJSON TEXT,
          ZNOTEDATA INTEGER, ZISPASSWORDPROTECTED INTEGER, ZMARKEDFORDELETION INTEGER, ZISPINNED INTEGER, ZHASCHECKLIST INTEGER,
          ZCREATIONDATE3 REAL, ZMODIFICATIONDATE1 REAL, ZNOTE INTEGER, ZNOTE1 INTEGER,
          ZTYPEUTI TEXT, ZTYPEUTI1 TEXT, ZALTTEXT TEXT, ZDISPLAYTEXT TEXT, ZTOKENCONTENTIDENTIFIER TEXT,
          ZMEDIA INTEGER, ZFILENAME TEXT, ZGENERATION1 TEXT, ZFALLBACKIMAGEGENERATION TEXT,
          ZURLSTRING TEXT, ZFALLBACKTITLE TEXT, ZOCRSUMMARY TEXT, ZHANDWRITINGSUMMARY TEXT, ZADDITIONALINDEXABLETEXT TEXT,
          ZIMAGECLASSIFICATIONSUMMARY TEXT, ZSUMMARY TEXT, ZDURATION REAL, ZPARENTATTACHMENT INTEGER,
          ZFALLBACKPDFGENERATION TEXT, ZLASTOPENEDDATE REAL, ZSORTORDER REAL,
          ZNEEDSINITIALFETCHFROMCLOUD INTEGER, ZNEEDSTOBEFETCHEDFROMCLOUD INTEGER, ZNEEDSTOSAVEUSERSPECIFICRECORD INTEGER,
          ZVERSIONOUTOFDATE INTEGER, ZCLOUDSTATE INTEGER, ZLASTSYNCDATE REAL, ZISSHAREDIRTY INTEGER, ZSERVERSHAREDATA BLOB,
          ZMERGEABLEDATA1 BLOB, ZMERGEABLEDATA BLOB);
        CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY,Z_ENT INTEGER,ZNOTE INTEGER,ZDATA BLOB);
        CREATE TABLE ZICNOTEPARTICIPANT (Z_PK INTEGER PRIMARY KEY,Z_ENT INTEGER,ZNOTE INTEGER,ZPARTICIPANTID TEXT,ZUSERID TEXT);
        CREATE TABLE ZICCLOUDSTATE (Z_PK INTEGER PRIMARY KEY,ZCURRENTLOCALVERSION INTEGER,ZLATESTVERSIONSYNCEDTOCLOUD INTEGER,ZINCLOUD INTEGER,ZCLOUDSYNCINGOBJECT INTEGER);
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZNAME,ZACCOUNTTYPE) VALUES (1,203,'account','Cloud',1),(2,203,'local','On My Mac',2);
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZTITLE2,ZOWNER,ZPARENT,ZFOLDERTYPE,ZSMARTFOLDERQUERYJSON) VALUES
          (10,202,'root','Work',1,NULL,0,NULL),(11,202,'child','Archive',1,10,0,NULL),(12,202,'trash','Deleted localized',1,NULL,1,NULL),(13,202,'smart','Tagged',1,NULL,2,'{"type":{"and":[{"deleted":false},{"tag":"work"}]}}');
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZTITLE1,ZSNIPPET,ZACCOUNT7,ZFOLDER,ZNOTEDATA,ZISPASSWORDPROTECTED,ZMARKEDFORDELETION,ZISPINNED,ZHASCHECKLIST,ZCREATIONDATE3,ZMODIFICATIONDATE1) VALUES
          (20,201,'N1','First','preview',1,11,120,0,0,1,1,100,200),
          (21,201,'N2','Second','preview',1,10,121,0,0,0,0,101,201),
          (22,201,'LOCKED','Secret title','Locked preview',1,10,122,1,0,0,0,102,202),
          (23,201,'DELETED','Trash note','',1,12,123,0,0,0,0,103,203),
          (24,201,'TOMBSTONE','Removed','',1,10,124,0,1,0,0,104,204),
          (25,201,'MISSING','Not downloaded','',1,10,NULL,0,0,0,0,105,205),
          (26,201,'DUP1','Duplicate','',1,10,126,0,0,0,0,106,206),
          (27,201,'DUP2','Duplicate','',1,10,127,0,0,0,0,107,207);
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZNOTE1,ZTYPEUTI1,ZALTTEXT,ZTOKENCONTENTIDENTIFIER) VALUES
          (30,205,'tag',20,'com.apple.notes.inlinetextattachment.hashtag','#work','work'),
          (31,205,'mention',20,'com.apple.notes.inlinetextattachment.mention','Pat','person'),
          (32,205,'link',20,'com.apple.notes.inlinetextattachment.link','Second','N2');
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZNOTE,ZTYPEUTI,ZMEDIA,ZOCRSUMMARY,ZHANDWRITINGSUMMARY,ZADDITIONALINDEXABLETEXT) VALUES
          (33,204,'photo',20,'public.jpeg',34,'recognized','handwriting','extra');
        UPDATE ZICCLOUDSYNCINGOBJECT SET ZIMAGECLASSIFICATIONSUMMARY='document',ZSUMMARY='image summary' WHERE Z_PK=33;
        UPDATE ZICCLOUDSYNCINGOBJECT SET ZLASTOPENEDDATE=300,ZSORTORDER=2,ZNEEDSINITIALFETCHFROMCLOUD=0,ZNEEDSTOBEFETCHEDFROMCLOUD=0,ZNEEDSTOSAVEUSERSPECIFICRECORD=1,ZVERSIONOUTOFDATE=0,ZLASTSYNCDATE=250,ZISSHAREDIRTY=1 WHERE Z_PK=20;
        INSERT INTO ZICCLOUDSTATE VALUES (1,4,3,1,20);
        INSERT INTO ZICNOTEPARTICIPANT VALUES (1,0,20,'participant','user');
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZFILENAME,ZGENERATION1) VALUES (34,206,'media','image.jpg','v1');
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZNOTE,ZTYPEUTI,ZURLSTRING,ZTITLE) VALUES (35,204,'preview',20,'public.url','https://example.com','Example');
        """)
        let runs = ["tag","mention","link","photo"].map { id in
            Self.int(1,2) + Self.bytes(12,Self.string(1,id) + Self.string(2,"public.data"))
        }
        try body(20, "\u{fffc} \u{fffc} \u{fffc} \u{fffc}\n", runs)
        try body(21, "Second\nBody-only needle 😀")
        try sql("INSERT INTO ZICNOTEDATA VALUES (122,208,22,X'FFFF');")
        for pk in [23,24,26,27] { try body(pk,"Synthetic body") }
        if alternateColumns {
            try sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZTITLE=ZTITLE1, ZTITLE1=ZTITLE2, ZTITLE2=ZTITLE; ALTER TABLE ZICCLOUDSYNCINGOBJECT RENAME COLUMN ZACCOUNT7 TO ZACCOUNT9;")
        }
        let media = directory.appendingPathComponent("Accounts/account/Media/media/v1")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data([0,1,2]).write(to:media.appendingPathComponent("image.jpg"))
    }
    deinit { sqlite3_close(connection); try? FileManager.default.removeItem(at:directory) }
    func sql(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw NotesError("fixture_sql", "Synthetic fixture SQL failed") }
    }
    static func varint(_ value: Int) -> Data {
        var value = value, data = Data()
        repeat { let byte = UInt8(value & 127); value >>= 7; data.append(value > 0 ? byte | 128 : byte) } while value > 0
        return data
    }
    static func int(_ field: Int, _ value: Int) -> Data { varint(field << 3) + varint(value) }
    static func bytes(_ field: Int, _ data: Data) -> Data { varint(field << 3 | 2) + varint(data.count) + data }
    static func string(_ field: Int, _ value: String) -> Data { bytes(field,Data(value.utf8)) }
    func body(_ pk: Int, _ text: String, _ runs: [Data] = []) throws {
        let note = Self.string(2,text) + runs.reduce(Data()) { $0 + Self.bytes(5,$1) }
        let data = Self.bytes(2,Self.bytes(3,note))
        try sql("INSERT INTO ZICNOTEDATA VALUES (\(pk+100),208,\(pk),X'\(data.map { String(format:"%02x",$0) }.joined())');")
    }
    func store() throws -> SQLiteNotesStore { try SQLiteNotesStore(databaseURL:database) }
}

final class SQLiteNotesStoreTests: XCTestCase {
    func testAttachmentReadbackIncludesNestedIDsTypesAndParents() throws {
        let fixture = try SyntheticLibrary()
        try fixture.sql("""
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZNOTE,ZTYPEUTI)
          VALUES (40,204,'scan',20,'com.apple.notes.gallery');
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZTYPEUTI,ZPARENTATTACHMENT)
          VALUES (41,204,'scan-page', 'public.jpeg',40),
                 (42,205,'cell-image','public.png',41);
        """)

        let scan = try XCTUnwrap(try fixture.store().note("N1").attachments.first { $0.id == "scan" })
        XCTAssertEqual(scan.typeUTI, "com.apple.notes.gallery")
        XCTAssertEqual(scan.childAttachments?.map(\.id), ["scan-page"])
        XCTAssertEqual(scan.childAttachments?.map(\.typeUTI), ["public.jpeg"])
        XCTAssertEqual(scan.childAttachments?.first?.childAttachments?.map(\.id), ["cell-image"])
        XCTAssertEqual(scan.childAttachments?.first?.childAttachments?.map(\.typeUTI), ["public.png"])
    }

    func testHashTitleCollidingWithNoteNumberIsAmbiguousAndExplicitSyntaxResolves() throws {
        let fixture = try SyntheticLibrary()
        try fixture.sql("""
        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZTITLE1,ZSNIPPET,ZACCOUNT7,ZFOLDER,ZNOTEDATA,ZISPASSWORDPROTECTED,ZMARKEDFORDELETION,ZISPINNED,ZHASCHECKLIST,ZCREATIONDATE3,ZMODIFICATIONDATE1) VALUES
          (40,201,'HASH-TITLE','#20','',1,10,NULL,0,0,0,0,108,208);
        """)
        let store = try fixture.store()
        XCTAssertThrowsError(try store.summary("#20")) { error in
            let error = error as? NotesError
            XCTAssertEqual(error?.code, "ambiguous_reference")
            XCTAssertEqual(error?.message, ##"Reference "#20" matches more than one note: #20 N1 "First" (number), #40 HASH-TITLE "#20" (title)."##)
            XCTAssertEqual(error?.hint, "Use id:20 for the note number or title:#20 for the exact title.")
        }
        XCTAssertEqual(try store.summary("title:#20").id.uuid, "HASH-TITLE")
        XCTAssertEqual(try store.summary("id:20").id.uuid, "N1")
        XCTAssertEqual(try store.summary("n20").id.uuid, "N1")
        XCTAssertEqual(try store.summary("#40").id.uuid, "HASH-TITLE")
        XCTAssertThrowsError(try store.summary("Duplicate")) { error in
            XCTAssertEqual((error as? NotesError)?.code, "ambiguous_note")
            XCTAssertEqual((error as? NotesError)?.message, ##"Reference "Duplicate" matches more than one note: #26 DUP1 "Duplicate" (title), #27 DUP2 "Duplicate" (title)."##)
        }
    }

    func testNotesInDeletedFolderStayDeleted() throws {
        let fixture = try SyntheticLibrary()
        try fixture.sql("""
        INSERT INTO ZICCLOUDSYNCINGOBJECT
          (Z_PK,Z_ENT,ZIDENTIFIER,ZTITLE2,ZOWNER,ZFOLDERTYPE,ZMARKEDFORDELETION)
          VALUES (14,202,'deleted-folder','Gone',1,0,1);
        INSERT INTO ZICCLOUDSYNCINGOBJECT
          (Z_PK,Z_ENT,ZIDENTIFIER,ZTITLE1,ZACCOUNT7,ZFOLDER,ZNOTEDATA,ZISPASSWORDPROTECTED,ZMARKEDFORDELETION,ZISPINNED,ZHASCHECKLIST,ZCREATIONDATE3,ZMODIFICATIONDATE1)
          VALUES (28,201,'IN-DELETED-FOLDER','Hidden child',1,14,128,0,0,0,0,108,208);
        """)
        try fixture.body(28, "Hidden body")

        let store = try fixture.store()
        XCTAssertFalse(try store.notes().contains { $0.id.uuid == "IN-DELETED-FOLDER" })
        let deleted = try XCTUnwrap(store.notes(.init(includeDeleted: true)).first { $0.id.uuid == "IN-DELETED-FOLDER" })
        XCTAssertTrue(deleted.isDeleted)
        XCTAssertNil(deleted.folderID)
    }

    func testInitialFetchRowsAreHiddenUnlessExplicitlyIncluded() throws {
        let fixture = try SyntheticLibrary()
        try fixture.sql("""
        INSERT INTO ZICCLOUDSYNCINGOBJECT
          (Z_PK,Z_ENT,ZIDENTIFIER,ZTITLE1,ZSNIPPET,ZACCOUNT7,ZFOLDER,ZNOTEDATA,ZISPASSWORDPROTECTED,ZMARKEDFORDELETION,ZISPINNED,ZHASCHECKLIST,ZCREATIONDATE3,ZMODIFICATIONDATE1,ZNEEDSINITIALFETCHFROMCLOUD)
          VALUES (29,201,'CACHED-PLACEHOLDER','Cached title','Cached snippet',1,10,NULL,0,0,0,0,109,209,1);
        """)

        let store = try fixture.store()
        XCTAssertEqual(store.placeholderCount, 1)
        XCTAssertFalse(try store.notes(.init(includeDeleted: true)).contains { $0.id.uuid == "CACHED-PLACEHOLDER" })
        XCTAssertEqual(
            try store.notes(.init(includeDeleted: true), includePlaceholders: true).filter { $0.id.uuid == "CACHED-PLACEHOLDER" }.count,
            1
        )
    }

    func testMetadataFiltersAndReferencesFromWAL() throws {
        let fixture = try SyntheticLibrary()
        let beforeDB = try Data(contentsOf: fixture.database)
        let beforeWAL = try Data(contentsOf: URL(fileURLWithPath: fixture.database.path + "-wal"))
        let store = try fixture.store()
        XCTAssertEqual(try store.accounts().map(\.kind).sorted(),["icloud","local"])
        XCTAssertEqual(try store.accounts().filter(\.isDefault).first?.name,"Cloud")
        XCTAssertEqual(try store.defaultLocation()?.folderName,"Work")
        let child = try XCTUnwrap(store.folders(account:"Cloud").first { $0.id == "child" })
        XCTAssertEqual(child.path,["Work","Archive"])
        XCTAssertEqual(child.parentID,"root")
        XCTAssertEqual(child.noteCount,1)
        XCTAssertTrue(try XCTUnwrap(store.folders().first { $0.id == "smart" }).isSmartFolder)
        XCTAssertTrue(try XCTUnwrap(store.folders().first { $0.id == "trash" }).isRecentlyDeleted)
        XCTAssertEqual(try store.notes().count,6)
        XCTAssertEqual(try store.notes(.init(includeDeleted:true)).count,8)
        XCTAssertEqual(try store.notes(.init(folder:"Work > Archive")).map(\.id.uuid),["N1"])
        XCTAssertEqual(try store.notes(.init(account:"local")).count,0)
        XCTAssertEqual(try store.notes(.init(pinnedOnly:true)).map(\.id.uuid),["N1"])
        XCTAssertEqual(try store.notes(.init(tag:"#WORK")).map(\.id.uuid),["N1"])
        XCTAssertEqual(try store.tags(),["work":1])
        XCTAssertEqual(try store.notes(.init(text:"body-only NEEDLE")).map(\.id.uuid),["N2"])
        XCTAssertEqual(try store.notes(.init(modifiedAfter:Date(timeIntervalSinceReferenceDate:200),modifiedBefore:Date(timeIntervalSinceReferenceDate:202))).map(\.id.uuid),["N2"])
        XCTAssertEqual(try store.notes(.init(limit:2)).count,2)
        XCTAssertEqual(try store.notes(.init(limit:0)).count,0)
        XCTAssertThrowsError(try store.notes(.init(limit:-1)))
        let note = try store.note("n1")
        XCTAssertEqual(note.summary.id.coreDataID,"x-coredata://STORE-UUID/ICNote/p20")
        XCTAssertEqual(note.summary.id.shortID,"n20")
        XCTAssertEqual(try store.note("n20").summary.id.uuid,"N1")
        XCTAssertEqual(try store.note("20").summary.id.uuid,"N1")
        XCTAssertEqual(try store.note("x-coredata://STORE-UUID/ICNote/p20").summary.id.uuid,"N1")
        XCTAssertEqual(try store.note("Second").summary.id.uuid,"N2")
        XCTAssertThrowsError(try store.note("Duplicate")) { XCTAssertEqual(($0 as? NotesError)?.code,"ambiguous_note") }
        XCTAssertThrowsError(try store.note("absent"))
        XCTAssertThrowsError(try store.note("MISSING")) { XCTAssertEqual(($0 as? NotesError)?.code,"body_unavailable"); XCTAssertEqual(($0 as? NotesError)?.hint,"run notescli fetch") }
        let locked = try store.note("LOCKED")
        XCTAssertNil(locked.document)
        XCTAssertEqual(locked.summary.title,"Secret title")
        XCTAssertThrowsError(try store.rawNote("LOCKED")) { XCTAssertEqual(($0 as? NotesError)?.code,"note_locked") }
        XCTAssertEqual(note.summary.attachmentCount,2)
        let image = try XCTUnwrap(note.attachments.first { $0.id == "photo" })
        XCTAssertEqual(image.filename,"image.jpg")
        XCTAssertEqual(image.filePath,fixture.directory.appendingPathComponent("Accounts/account/Media/media/v1/image.jpg").path)
        XCTAssertEqual(image.ocrText,"recognized")
        XCTAssertEqual(image.handwritingText,"handwriting")
        XCTAssertEqual(image.additionalIndexableText,"extra")
        XCTAssertEqual(image.imageClassification,"document")
        XCTAssertEqual(note.summary.lastOpened,Date(timeIntervalSinceReferenceDate:300))
        XCTAssertEqual(note.summary.displayOrder,2)
        XCTAssertEqual(note.summary.participants?.first?.participantID,"participant")
        XCTAssertEqual(note.summary.syncState?.needsSave,true)
        XCTAssertEqual(note.summary.syncState?.currentLocalVersion,4)
        XCTAssertEqual(note.summary.syncState?.latestVersionSyncedToCloud,3)
        XCTAssertEqual(try store.notes(.init(attachmentKinds:["image"])).map(\.id.uuid),["N1"])
        XCTAssertEqual(try store.notes(.init(),sort:.opened).first?.id.uuid,"N1")
        XCTAssertEqual(try store.backlinks("N2").map(\.id.uuid),["N1"])
        let smart = try XCTUnwrap(store.smartFolders(evaluate:true).first)
        XCTAssertEqual(smart.rules,["deleted=false","tag=work"])
        XCTAssertTrue(smart.unsupportedRules.isEmpty)
        XCTAssertEqual(smart.matchingNoteIDs,["N1"])
        XCTAssertEqual(note.attachments.first { $0.id == "preview" }?.url,"https://example.com")
        XCTAssertEqual(note.document?.runs[2].attachment?.url,"applenotes://showNote?identifier=N2")
        XCTAssertTrue(note.document?.markdown(attachments:note.attachments).contains("[#work](notescli-attachment:tag) [@Pat](notescli-attachment:mention) [Second](applenotes://showNote?identifier=N2)") == true)
        XCTAssertEqual(try Data(contentsOf:fixture.database),beforeDB)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:fixture.database.path + "-wal")),beforeWAL)
        try fixture.sql("UPDATE ZICCLOUDSYNCINGOBJECT SET ZTITLE1='Changed' WHERE Z_PK=21")
        XCTAssertEqual(try fixture.store().note("N2").summary.title,"Second")
        XCTAssertEqual(try SQLiteNotesStore(databaseURL:fixture.database,refresh:true).note("N2").summary.title,"Changed")
    }
    func testTableBlobFallbackImageAndMetadataPlist() throws {
        let fixture = try SyntheticLibrary()
        typealias P = SyntheticLibrary
        func ref(_ n: Int) -> Data { P.int(6,n) }
        func pair(_ key: Data, _ value: Data) -> Data { P.bytes(1,key) + P.bytes(2,value) }
        func map(_ key: Int, _ value: Data) -> Data { P.int(1,key) + P.bytes(2,value) }
        func identity(_ n: Int) -> Data { P.bytes(13,P.int(1,1) + P.bytes(3,map(3,P.int(2,n)))) }
        let rowUUID = Data(repeating:1,count:16), columnUUID = Data(repeating:2,count:16)
        func order(_ uuid: Data) -> Data {
            P.bytes(16,P.bytes(1,P.bytes(1,P.bytes(2,P.int(1,0) + P.bytes(2,uuid)))))
        }
        let root = P.bytes(13,P.int(1,0) + P.bytes(3,map(0,ref(1))) + P.bytes(3,map(1,ref(2))) + P.bytes(3,map(2,ref(3))))
        let objects = [root,order(rowUUID),order(columnUUID),P.bytes(6,P.bytes(1,pair(ref(5),ref(6)))),identity(0),identity(1),P.bytes(6,P.bytes(1,pair(ref(4),ref(7)))),P.bytes(10,P.string(2,"Cell"))]
        let pool = objects.reduce(Data()) { $0 + P.bytes(3,$1) }
        let keys = ["crRows","crColumns","cellColumns","self"].reduce(Data()) { $0 + P.string(4,$1) }
        let data = P.bytes(2,P.bytes(3,pool + keys + P.string(5,"com.apple.notes.ICTable") + P.string(5,"uuid") + P.bytes(6,rowUUID) + P.bytes(6,columnUUID)))
        let hex = data.map { String(format:"%02x",$0) }.joined()
        try fixture.sql("INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZNOTE,ZTYPEUTI,ZMERGEABLEDATA) VALUES (40,204,'table',21,'com.apple.notes.table',X'\(hex)'); DELETE FROM ZICNOTEDATA WHERE ZNOTE=21;")
        try fixture.body(21,"\u{fffc}",[P.int(1,1) + P.bytes(12,P.string(1,"table") + P.string(2,"com.apple.notes.table"))])
        let drawingJSON = try JSONSerialization.data(withJSONObject: ["strokes": [[["x": 0, "y": 0], ["x": 2, "y": 2]]]])
        let drawingHex = drawingJSON.map { String(format:"%02x",$0) }.joined()
        try fixture.sql("INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK,Z_ENT,ZIDENTIFIER,ZNOTE,ZTYPEUTI,ZFALLBACKIMAGEGENERATION,ZMERGEABLEDATA) VALUES (41,204,'drawing',21,'com.apple.drawing','generation',X'\(drawingHex)');")
        let fallback = fixture.directory.appendingPathComponent("Accounts/account/FallbackImages/drawing/generation")
        try FileManager.default.createDirectory(at:fallback,withIntermediateDirectories:true)
        try Data([1]).write(to:fallback.appendingPathComponent("FallbackImage.jpeg"))
        let plist = try PropertyListSerialization.data(fromPropertyList:["NSStoreUUID":"PLIST-UUID"],format:.binary,options:0)
        try fixture.sql("ALTER TABLE Z_METADATA RENAME COLUMN Z_UUID TO OLD_UUID; ALTER TABLE Z_METADATA ADD COLUMN Z_PLIST BLOB; UPDATE Z_METADATA SET Z_PLIST=X'\(plist.map { String(format:"%02x",$0) }.joined())';")
        let note = try fixture.store().note("N2")
        XCTAssertEqual(note.summary.id.coreDataID,"x-coredata://PLIST-UUID/ICNote/p21")
        XCTAssertEqual(note.document?.tables?["table"],[["Cell"]])
        XCTAssertEqual(note.document?.markdown(),"| Cell |\n| --- |")
        XCTAssertEqual(note.attachments.first { $0.id == "drawing" }?.filePath,fallback.appendingPathComponent("FallbackImage.jpeg").path)
        XCTAssertTrue(note.attachments.first { $0.id == "drawing" }?.drawingSVG?.contains("<path") == true)
    }
    func testColumnVariantsAndSnapshotReuse() throws {
        let fixture = try SyntheticLibrary(alternateColumns:true)
        let store = try fixture.store()
        XCTAssertEqual(try store.note("N1").summary.title,"First")
        XCTAssertEqual(try store.note("N1").summary.folderPath,["Work","Archive"])
        try FileManager.default.removeItem(at:fixture.database)
        XCTAssertEqual(try fixture.store().notes().count,6)
    }
}

final class LiveNotesStoreTests: XCTestCase {
    func testDecodeEveryNoteAndBenchmark() throws {
        guard ProcessInfo.processInfo.environment["NOTESCLI_LIVE_TESTS"] == "1" else { throw XCTSkip("Set NOTESCLI_LIVE_TESTS=1 for read-only library verification") }
        let coldStart = Date()
        let store = try SQLiteNotesStore(refresh:true)
        let notes = try store.notes(.init(includeDeleted:true))
        let coldSeconds = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        for _ in 0..<100 { _ = try store.notes(.init(includeDeleted:true)) }
        let warmSeconds = Date().timeIntervalSince(warmStart) / 100
        var decoded = 0, locked = 0, reasons: [String:Int] = [:]
        for summary in notes {
            do {
                let note = try store.note(summary.id.uuid)
                if summary.isLocked {
                    locked += 1
                    if note.document != nil { reasons["locked_has_document",default:0] += 1 }
                } else if let document = note.document {
                    decoded += 1
                    // Exercise each public renderer without emitting text.
                    _ = document.markdown(attachments:note.attachments)
                    _ = document.plainText(attachments:note.attachments)
                    _ = document.html(attachments:note.attachments)
                } else { reasons["missing_document",default:0] += 1 }
            } catch let error as NotesError { reasons[error.code,default:0] += 1 }
            catch { reasons["unexpected_error",default:0] += 1 }
        }
        let failures = reasons.values.reduce(0,+)
        let unexpected = reasons.filter { $0.key != "body_unavailable" }.values.reduce(0,+)
        let kinds = try store.attachmentKindCounts()
        print("NOTESCLI_LIVE total=\(notes.count) decoded=\(decoded) locked=\(locked) failures=\(failures) reasons=\(reasons.sorted { $0.key < $1.key }) attachment_kinds=\(kinds.sorted { $0.key < $1.key }) cold_list_seconds=\(coldSeconds) warm_list_seconds=\(warmSeconds)")
        XCTAssertEqual(notes.count,decoded+locked+failures)
        XCTAssertEqual(unexpected,0,"Library verification had unexpected failures; see aggregate reason counts")
    }
}
