import Foundation
import SQLite3
import NotesCore

struct StoreRow: Sendable {
    var integers: [String: Int64] = [:]
    var numbers: [String: Double] = [:]
    var strings: [String: String] = [:]
    var blobs: [String: Data] = [:]
    func int(_ names: String...) -> Int64? { names.lazy.compactMap { integers[$0] }.first }
    func double(_ names: String...) -> Double? { names.lazy.compactMap { numbers[$0] ?? integers[$0].map(Double.init) }.first }
    func string(_ names: String...) -> String? { names.lazy.compactMap { strings[$0] }.first }
    func data(_ names: String...) -> Data? { names.lazy.compactMap { blobs[$0] }.first }
    func date(_ names: String...) -> Date? {
        names.lazy.compactMap { numbers[$0] ?? integers[$0].map(Double.init) }.first.map(Date.init(timeIntervalSinceReferenceDate:))
    }
}

struct StoreLibrary: Sendable {
    let entities: [String: Set<Int64>]
    let objects: [Int64: StoreRow]
    let bodies: [Int64: Data]
    let participants: [Int64: [NoteParticipant]]
    let cloudStates: [Int64: StoreCloudState]
    let storeUUID: String
    func rows(_ entity: String) -> [StoreRow] {
        let ids = entities[entity] ?? []
        return objects.values.filter { ids.contains($0.int("Z_ENT") ?? -1) }.sorted { ($0.int("Z_PK") ?? 0) < ($1.int("Z_PK") ?? 0) }
    }
}

struct StoreCloudState: Sendable {
    var currentLocalVersion: Int?
    var latestVersionSyncedToCloud: Int?
    var isInCloud: Bool?
}

/// The cache holds only values, never a live connection or a copied database on disk.
final class SnapshotCache: @unchecked Sendable {
    static let shared = SnapshotCache()
    private let lock = NSLock()
    private var libraries: [String: StoreLibrary] = [:]
    func load(_ source: URL, refresh: Bool) throws -> StoreLibrary {
        lock.lock(); defer { lock.unlock() }
        let key = source.standardizedFileURL.path
        if !refresh, let library = libraries[key] { return library }
        let library = try SQLiteSnapshot.load(source)
        libraries[key] = library
        return library
    }
}

enum SQLiteSnapshot {
    static func load(_ source: URL) throws -> StoreLibrary {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: source.path) else {
            throw NotesError("full_disk_access_denied", "Cannot read the Notes database.", hint: "Grant Full Disk Access to the terminal or app running notescli.")
        }
        let directory = fm.temporaryDirectory.appendingPathComponent("notescli-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("NoteStore.sqlite")
        func fingerprint() throws -> [String] {
            try ["", "-wal", "-shm"].map { suffix in
                let path = source.path + suffix
                guard fm.fileExists(atPath: path) else { return "missing" }
                let a = try fm.attributesOfItem(atPath: path)
                let modified = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                return "\(a[.size] ?? 0):\(modified):\(a[.systemFileNumber] ?? 0)"
            }
        }
        var stable = false
        for _ in 0..<3 {
            let before = try fingerprint()
            for suffix in ["", "-wal", "-shm"] {
                let target = destination.path + suffix
                if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
                if fm.fileExists(atPath: source.path + suffix) {
                    try fm.copyItem(atPath: source.path + suffix, toPath: target)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
                }
            }
            if before == (try fingerprint()) { stable = true; break }
        }
        guard stable else { throw NotesError("snapshot_busy", "Notes changed while the snapshot was copied. Try again.") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection = db else {
            if let db { sqlite3_close(db) }
            throw NotesError("snapshot_open_failed", "Cannot open the Notes snapshot.")
        }
        defer { sqlite3_close(connection) }
        func query(_ sql: String) throws -> [StoreRow] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NotesError("unsupported_schema", "Cannot query the Notes snapshot.") }
            defer { sqlite3_finalize(statement) }
            var rows: [StoreRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW else { throw NotesError("snapshot_read_failed", "Cannot read the Notes snapshot.") }
                var row = StoreRow()
                for i in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, i))
                    switch sqlite3_column_type(statement, i) {
                    case SQLITE_INTEGER: row.integers[name] = sqlite3_column_int64(statement, i)
                    case SQLITE_FLOAT: row.numbers[name] = sqlite3_column_double(statement, i)
                    case SQLITE_TEXT:
                        if let text = sqlite3_column_text(statement, i) {
                            row.strings[name] = String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, i))), as: UTF8.self)
                        }
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, i))
                        if let bytes = sqlite3_column_blob(statement, i) { row.blobs[name] = Data(bytes: bytes, count: count) }
                        else { row.blobs[name] = Data() }
                    default: break
                    }
                }
                rows.append(row)
            }
        }
        guard try query("PRAGMA quick_check").first?.string("quick_check") == "ok" else { throw NotesError("snapshot_inconsistent", "The Notes snapshot failed its integrity check.") }
        let primary = try query("SELECT Z_ENT, Z_NAME, Z_SUPER FROM Z_PRIMARYKEY")
        var entities: [String: Set<Int64>] = [:]
        for row in primary {
            if let name = row.string("Z_NAME"), let id = row.int("Z_ENT") { entities[name] = [id] }
        }
        // Include subclasses by walking Z_SUPER, without relying on entity numbers.
        for _ in primary.indices {
            for row in primary {
                guard let id = row.int("Z_ENT"), let parent = row.int("Z_SUPER") else { continue }
                for key in Array(entities.keys) where entities[key]?.contains(parent) == true { entities[key]?.insert(id) }
            }
        }
        guard entities["ICNote"] != nil else { throw NotesError("unsupported_schema", "This database has no ICNote entity.") }
        let objectColumns = try query("PRAGMA table_info(ZICCLOUDSYNCINGOBJECT)").compactMap { $0.string("name") }
        let exact: Set<String> = ["Z_PK", "Z_ENT", "ZIDENTIFIER", "ZNAME", "ZSNIPPET", "ZWIDGETSNIPPET", "ZFOLDER", "ZPARENT", "ZPARENTATTACHMENT", "ZPARENTATTACHMENT1", "ZOWNER", "ZNOTEDATA", "ZOUTLINESTATEDATA", "ZISPASSWORDPROTECTED", "ZMARKEDFORDELETION", "ZISPINNED", "ZHASCHECKLIST", "ZHASCHECKLISTINPROGRESS", "ZISSYSTEMPAPER", "ZACCOUNTTYPE", "ZFOLDERTYPE", "ZSMARTFOLDERQUERYJSON", "ZISSYSTEMFOLDER", "ZISRECENTLYDELETED", "ZISTRASH", "ZMEDIA", "ZFILENAME", "ZFALLBACKTITLE", "ZFALLBACKIMAGEGENERATION", "ZFALLBACKPDFGENERATION", "ZURLSTRING", "ZREMOTEFILEURLSTRING", "ZOCRSUMMARY", "ZHANDWRITINGSUMMARY", "ZADDITIONALINDEXABLETEXT", "ZIMAGECLASSIFICATIONSUMMARY", "ZSUMMARY", "ZDISPLAYTEXT", "ZALTTEXT", "ZSTANDARDIZEDCONTENT", "ZTOKENCONTENTIDENTIFIER", "ZTYPE", "ZMERGEABLEDATA", "ZMERGEABLEDATA1", "ZMERGEABLEDATA2", "ZDURATION", "ZFILESIZE", "ZNEEDSINITIALFETCHFROMCLOUD", "ZNEEDSTOBEFETCHEDFROMCLOUD", "ZNEEDSTOFETCHUSERSPECIFICRECORDASSETS", "ZNEEDSTOSAVEUSERSPECIFICRECORD", "ZNOTEHASCHANGES", "ZVERSIONOUTOFDATE", "ZCLOUDSTATE", "ZLASTSYNCDATE", "ZLASTOPENEDDATE", "ZSORTORDER", "ZCUSTOMNOTESORTTYPEVALUE", "ZISSHAREDIRTY", "ZSERVERSHAREDATA", "ZUSERRECORDNAME", "ZUSERTITLE"]
        let families = ["ZACCOUNT", "ZTITLE", "ZTYPEUTI", "ZNOTE", "ZATTACHMENT", "ZGENERATION", "ZCREATIONDATE", "ZMODIFICATIONDATE"]
        let selected = objectColumns.filter { name in
            exact.contains(name) || families.contains { prefix in name.hasPrefix(prefix) && name.dropFirst(prefix.count).allSatisfy(\.isNumber) }
        }
        guard ["Z_PK", "Z_ENT", "ZIDENTIFIER"].allSatisfy(selected.contains) else { throw NotesError("unsupported_schema", "Required Notes columns are missing.") }
        let objectRows = try query("SELECT " + selected.map { "\"\($0)\"" }.joined(separator: ",") + " FROM ZICCLOUDSYNCINGOBJECT")
        var objects: [Int64: StoreRow] = [:]
        for row in objectRows { if let pk = row.int("Z_PK") { objects[pk] = row } }
        let bodyColumns = Set(try query("PRAGMA table_info(ZICNOTEDATA)").compactMap { $0.string("name") })
        guard bodyColumns.contains("ZDATA"), bodyColumns.contains("Z_PK") else { throw NotesError("unsupported_schema", "Note body columns are missing.") }
        let bodyRows = try query("SELECT Z_PK, ZDATA" + (bodyColumns.contains("ZNOTE") ? ", ZNOTE" : "") + " FROM ZICNOTEDATA")
        var bodies: [Int64: Data] = [:]
        var bodyByPK: [Int64: Data] = [:]
        for row in bodyRows {
            if let data = row.data("ZDATA") {
                if let pk = row.int("Z_PK") { bodyByPK[pk] = data }
                if let note = row.int("ZNOTE") { bodies[note] = data }
            }
        }
        for (pk, row) in objects { if let body = row.int("ZNOTEDATA"), let data = bodyByPK[body] { bodies[pk] = data } }
        var participants: [Int64: [NoteParticipant]] = [:]
        let tables = Set(try query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.string("name") })
        if tables.contains("ZICNOTEPARTICIPANT") {
            for row in try query("SELECT ZNOTE, ZPARTICIPANTID, ZUSERID FROM ZICNOTEPARTICIPANT") {
                guard let note = row.int("ZNOTE") else { continue }
                participants[note, default: []].append(NoteParticipant(participantID: row.string("ZPARTICIPANTID"), userID: row.string("ZUSERID")))
            }
        }
        var cloudStates: [Int64: StoreCloudState] = [:]
        if tables.contains("ZICCLOUDSTATE") {
            let columns = Set(try query("PRAGMA table_info(ZICCLOUDSTATE)").compactMap { $0.string("name") })
            let relation = columns.contains("ZCLOUDSYNCINGOBJECT") ? "ZCLOUDSYNCINGOBJECT" : "Z3_CLOUDSYNCINGOBJECT"
            if columns.contains(relation) {
                let selected = [relation, "ZCURRENTLOCALVERSION", "ZLATESTVERSIONSYNCEDTOCLOUD", "ZINCLOUD"].filter(columns.contains)
                for row in try query("SELECT " + selected.joined(separator: ",") + " FROM ZICCLOUDSTATE") {
                    guard let object = row.int(relation) else { continue }
                    cloudStates[object] = StoreCloudState(
                        currentLocalVersion: row.int("ZCURRENTLOCALVERSION").map(Int.init),
                        latestVersionSyncedToCloud: row.int("ZLATESTVERSIONSYNCEDTOCLOUD").map(Int.init),
                        isInCloud: row.int("ZINCLOUD").map { $0 == 1 })
                }
            }
        }
        let metadataColumns = Set(try query("PRAGMA table_info(Z_METADATA)").compactMap { $0.string("name") })
        var uuid: String?
        if metadataColumns.contains("Z_UUID") { uuid = try query("SELECT Z_UUID FROM Z_METADATA").first?.string("Z_UUID") }
        if uuid == nil, metadataColumns.contains("Z_PLIST"), let data = try query("SELECT Z_PLIST FROM Z_METADATA").first?.data("Z_PLIST"),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { uuid = plist["NSStoreUUID"] as? String }
        guard let uuid, !uuid.isEmpty else { throw NotesError("unsupported_schema", "The Notes store UUID is missing.") }
        return StoreLibrary(entities: entities, objects: objects, bodies: bodies, participants: participants,
                            cloudStates: cloudStates, storeUUID: uuid)
    }
}
