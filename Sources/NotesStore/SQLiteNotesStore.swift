import Foundation
import NotesCore

public final class SQLiteNotesStore: NotesReading, Sendable {
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }
    private let library: StoreLibrary
    private let container: URL
    private let accountList: [Account]
    private let folderList: [Folder]
    private let summaries: [NoteSummary]
    private let notePKs: [String: Int64]
    private let objectsByID: [String: StoreRow]
    private let attachmentRows: [Int64: [StoreRow]]

    /// A process-wide snapshot is reused. `refresh` is for explicit refresh/read-back after automation.
    public init(databaseURL: URL = SQLiteNotesStore.defaultDatabaseURL, groupContainerURL: URL? = nil, refresh: Bool = false) throws {
        let library = try SnapshotCache.shared.load(databaseURL, refresh: refresh)
        self.library = library
        self.container = groupContainerURL ?? databaseURL.deletingLastPathComponent()
        let accounts = library.rows("ICAccount")
        var accountByPK: [Int64: Account] = [:]
        for row in accounts {
            guard let pk = row.int("Z_PK"), let id = row.string("ZIDENTIFIER") else { continue }
            let kind: String
            switch row.int("ZACCOUNTTYPE") { case 1: kind = "icloud"; case 2: kind = "local"; case 3: kind = "imap"; case 4: kind = "exchange"; default: kind = "unknown" }
            accountByPK[pk] = Account(id: id, name: row.string("ZNAME", "ZTITLE", "ZIDENTIFIER") ?? "", kind: kind)
        }
        self.accountList = accountByPK.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        func account(_ row: StoreRow) -> String {
            if let owner = row.int("ZOWNER"), let account = accountByPK[owner] { return account.id }
            for key in row.integers.keys.sorted() where key.hasPrefix("ZACCOUNT") && key.dropFirst(8).allSatisfy(\.isNumber) {
                if let id = row.integers[key], let account = accountByPK[id] { return account.id }
            }
            return ""
        }
        let folders = library.rows("ICFolder")
        var folderByPK: [Int64: Folder] = [:]
        for row in folders {
            guard let pk = row.int("Z_PK"), let id = row.string("ZIDENTIFIER") else { continue }
            let name = row.string("ZTITLE2", "ZTITLE1", "ZTITLE", "ZNAME") ?? ""
            let parent = row.int("ZPARENT").flatMap { library.objects[$0]?.string("ZIDENTIFIER") }
            let deleted = row.int("ZFOLDERTYPE") == 1 || row.int("ZISRECENTLYDELETED", "ZISTRASH") == 1 || id.lowercased().contains("recentlydeleted")
            folderByPK[pk] = Folder(id: id, name: name, accountID: account(row), parentID: parent, path: [], isSmartFolder: !(row.string("ZSMARTFOLDERQUERYJSON") ?? "").isEmpty, isRecentlyDeleted: deleted, noteCount: 0)
        }
        for pk in Array(folderByPK.keys) {
            var path: [String] = [], current: Int64? = pk, visited: Set<Int64> = [], inheritedAccount = ""
            while let key = current, let folder = folderByPK[key], visited.insert(key).inserted {
                path.insert(folder.name, at: 0)
                if !folder.accountID.isEmpty { inheritedAccount = folder.accountID }
                current = library.objects[key]?.int("ZPARENT")
            }
            folderByPK[pk]?.path = path
            if folderByPK[pk]?.accountID.isEmpty == true { folderByPK[pk]?.accountID = inheritedAccount }
        }
        var objectsByID: [String: StoreRow] = [:], attachmentRows: [Int64: [StoreRow]] = [:]
        for row in library.objects.values { if let id = row.string("ZIDENTIFIER") { objectsByID[id.lowercased()] = row } }
        let noteEntities = library.entities["ICNote"] ?? []
        let noteKeys = Set(library.objects.compactMap { noteEntities.contains($0.value.int("Z_ENT") ?? -1) ? $0.key : nil })
        for row in library.rows("ICAttachment") + library.rows("ICInlineAttachment") where row.int("ZMARKEDFORDELETION") != 1 {
            let parent = row.int("ZNOTE1", "ZNOTE")
            if let parent, noteKeys.contains(parent) { attachmentRows[parent, default: []].append(row) }
        }
        self.objectsByID = objectsByID; self.attachmentRows = attachmentRows
        var summaries: [NoteSummary] = [], pks: [String: Int64] = [:]
        for row in library.rows("ICNote") {
            guard let pk = row.int("Z_PK"), let uuid = row.string("ZIDENTIFIER") else { continue }
            let folderPK = row.int("ZFOLDER"), folder = folderPK.flatMap { folderByPK[$0] }
            let deleted = row.int("ZMARKEDFORDELETION") == 1 || folder?.isRecentlyDeleted == true
            let attachments = attachmentRows[pk] ?? []
            let tags = Set(attachments.compactMap { item -> String? in
                guard (item.string("ZTYPEUTI1", "ZTYPEUTI") ?? "").contains("hashtag") else { return nil }
                guard let label = item.string("ZALTTEXT", "ZDISPLAYTEXT", "ZSTANDARDIZEDCONTENT", "ZTOKENCONTENTIDENTIFIER") else { return nil }
                return label.hasPrefix("#") ? String(label.dropFirst()) : label
            }).sorted()
            let coreDataID = "x-coredata://\(library.storeUUID)/ICNote/p\(pk)"
            summaries.append(NoteSummary(id: NoteID(uuid: uuid, coreDataID: coreDataID), title: row.string("ZTITLE1", "ZTITLE2", "ZTITLE") ?? "", snippet: row.string("ZSNIPPET", "ZWIDGETSNIPPET") ?? "", folderID: folder?.id, folderPath: folder?.path ?? [], accountID: folder?.accountID.isEmpty == false ? folder!.accountID : account(row), created: row.date("ZCREATIONDATE3", "ZCREATIONDATE1", "ZCREATIONDATE"), modified: row.date("ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"), isPinned: row.int("ZISPINNED") == 1, isLocked: row.int("ZISPASSWORDPROTECTED") == 1, isDeleted: deleted, hasChecklist: row.int("ZHASCHECKLIST") == 1, attachmentCount: attachments.filter { !(($0.string("ZTYPEUTI1", "ZTYPEUTI") ?? "").contains("inlinetextattachment")) }.count, tags: tags))
            pks[uuid.lowercased()] = pk
            if !deleted, let folderPK { folderByPK[folderPK]?.noteCount += 1 }
            else if folder?.isRecentlyDeleted == true, row.int("ZMARKEDFORDELETION") != 1, let folderPK { folderByPK[folderPK]?.noteCount += 1 }
        }
        self.summaries = summaries.sorted {
            if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return $0.id.uuid < $1.id.uuid
        }
        self.notePKs = pks
        self.folderList = folderByPK.values.sorted { $0.path.joined(separator: " > ").localizedStandardCompare($1.path.joined(separator: " > ")) == .orderedAscending }
    }
    public func accounts() throws -> [Account] { accountList }
    public func folders(account: String? = nil) throws -> [Folder] {
        guard let account else { return folderList }
        let ids = Set(accountList.filter { $0.id.caseInsensitiveCompare(account) == .orderedSame || $0.name == account }.map(\.id))
        return folderList.filter { ids.contains($0.accountID) }
    }
    public func notes(_ query: NoteQuery = NoteQuery()) throws -> [NoteSummary] {
        if let limit = query.limit, limit < 0 { throw NotesError("invalid_limit", "The limit must be zero or greater.") }
        if query.limit == 0 { return [] }
        let accountIDs = query.account.map { account in Set(accountList.filter { $0.id.caseInsensitiveCompare(account) == .orderedSame || $0.name == account }.map(\.id)) }
        let folderIDs = query.folder.map { ref in Set(folderList.filter { $0.id.caseInsensitiveCompare(ref) == .orderedSame || $0.name == ref || $0.path.joined(separator: " > ") == ref }.map(\.id)) }
        let tag = query.tag.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        var result: [NoteSummary] = []
        for summary in summaries {
            if !query.includeDeleted && summary.isDeleted { continue }
            if query.pinnedOnly && !summary.isPinned { continue }
            if let ids = accountIDs, !ids.contains(summary.accountID) { continue }
            if let ids = folderIDs, !ids.contains(summary.folderID ?? "") { continue }
            if let tag, !summary.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { continue }
            if let date = query.modifiedAfter, (summary.modified ?? .distantPast) <= date { continue }
            if let date = query.modifiedBefore, (summary.modified ?? .distantFuture) >= date { continue }
            if let text = query.text, !text.isEmpty {
                func matches(_ value: String) -> Bool { value.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                if !matches(summary.title) && !matches(summary.snippet) {
                    guard !summary.isLocked, let pk = notePKs[summary.id.uuid.lowercased()], library.bodies[pk] != nil else { continue }
                    let note = try self.note(summary.id.uuid)
                    let searchable = note.document?.plainText(attachments: note.attachments) ?? ""
                    if !matches(searchable) && !note.attachments.contains(where: { matches($0.ocrText ?? "") }) { continue }
                }
            }
            result.append(summary)
            if let limit = query.limit, result.count >= limit { break }
        }
        return result
    }
    public func note(_ ref: String) throws -> Note {
        let byID = summaries.filter { $0.id.uuid.caseInsensitiveCompare(ref) == .orderedSame || $0.id.coreDataID?.caseInsensitiveCompare(ref) == .orderedSame }
        let matches = byID.isEmpty ? summaries.filter { $0.title == ref && !$0.isDeleted } : byID
        guard !matches.isEmpty else { throw NotesError("note_not_found", "No note matches the reference.") }
        guard matches.count == 1 else { throw NotesError("ambiguous_note", "More than one note has this title. Use a UUID.") }
        let summary = matches[0]
        // Do not read or decode encrypted payloads, including attachments.
        if summary.isLocked { return Note(summary: summary, document: nil, attachments: []) }
        guard let pk = notePKs[summary.id.uuid.lowercased()], let data = library.bodies[pk], !data.isEmpty else {
            throw NotesError("body_unavailable", "The note body is not downloaded in this snapshot.", hint: "Open the note in Notes, wait for it to download, then refresh the snapshot.")
        }
        var document: NoteDocument
        do { document = try NotesDecoder.decode(data) }
        catch let error as DecodeError { throw NotesError("decode_\(error.rawValue)", "Cannot decode the note body.") }
        var rows = attachmentRows[pk] ?? []
        let known = Set(rows.compactMap { $0.string("ZIDENTIFIER")?.lowercased() })
        for ref in document.runs.compactMap(\.attachment) where !known.contains(ref.id.lowercased()) {
            if let row = objectsByID[ref.id.lowercased()] { rows.append(row) }
        }
        var attachments: [Attachment] = [], seen: Set<String> = []
        for row in rows {
            guard let id = row.string("ZIDENTIFIER"), seen.insert(id).inserted else { continue }
            let attachment = makeAttachment(row, accountID: summary.accountID)
            attachments.append(attachment)
            if attachment.typeUTI == "com.apple.notes.table", let tableData = row.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA") {
                do {
                    if document.tables == nil { document.tables = [:] }
                    document.tables?[id] = try NotesTableDecoder.decode(tableData) { ref in
                        self.objectsByID[ref.id.lowercased()]?.string("ZALTTEXT", "ZDISPLAYTEXT", "ZTITLE", "ZFALLBACKTITLE", "ZFILENAME")
                    }
                } catch let error as DecodeError { throw NotesError("table_\(error.rawValue)", "Cannot decode an embedded table.") }
            }
        }
        for i in document.runs.indices {
            guard var ref = document.runs[i].attachment, let row = objectsByID[ref.id.lowercased()] else { continue }
            ref.typeUTI = row.string("ZTYPEUTI1", "ZTYPEUTI") ?? ref.typeUTI
            ref.displayText = row.string("ZALTTEXT", "ZDISPLAYTEXT", "ZTITLE", "ZFALLBACKTITLE")
            if ref.typeUTI == "com.apple.notes.inlinetextattachment.link", let target = row.string("ZTOKENCONTENTIDENTIFIER") {
                ref.url = target.hasPrefix("applenotes:") ? target : "applenotes://showNote?identifier=\(target)"
            } else { ref.url = row.string("ZURLSTRING") }
            document.runs[i].attachment = ref
        }
        return Note(summary: summary, document: document, attachments: attachments)
    }
    public func tags() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for note in summaries where !note.isDeleted { for tag in note.tags { counts[tag, default: 0] += 1 } }
        return counts
    }
    private func makeAttachment(_ row: StoreRow, accountID: String) -> Attachment {
        let media = row.int("ZMEDIA").flatMap { library.objects[$0] }
        let id = row.string("ZIDENTIFIER") ?? ""
        let filename = media?.string("ZFILENAME") ?? row.string("ZFILENAME")
        let mediaID = media?.string("ZIDENTIFIER")
        let generation = media?.string("ZGENERATION1", "ZGENERATION") ?? row.string("ZGENERATION1", "ZGENERATION")
        var candidates: [URL] = []
        let roots = [container.appendingPathComponent("Accounts").appendingPathComponent(accountID), container]
        for root in roots {
            if let mediaID, let filename {
                let directory = root.appendingPathComponent("Media").appendingPathComponent(mediaID)
                if let generation { candidates.append(directory.appendingPathComponent(generation).appendingPathComponent(filename)) }
                candidates.append(directory.appendingPathComponent(filename))
            }
            let fallback = root.appendingPathComponent("FallbackImages").appendingPathComponent(id)
            for ext in ["png", "jpg", "jpeg"] {
                if let generation = row.string("ZFALLBACKIMAGEGENERATION") {
                    candidates.append(fallback.appendingPathComponent(generation).appendingPathComponent("FallbackImage.\(ext)"))
                }
                candidates += [fallback.appendingPathComponent("FallbackImage.\(ext)"), root.appendingPathComponent("FallbackImages/\(id).\(ext)")]
            }
        }
        let boundary = container.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = candidates.first { url in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            var isDirectory: ObjCBool = false
            return resolved.hasPrefix(boundary) && FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) && !isDirectory.boolValue
        }?.path
        let ocr = [row.string("ZOCRSUMMARY"), row.string("ZHANDWRITINGSUMMARY"), row.string("ZADDITIONALINDEXABLETEXT")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return Attachment(id: id, typeUTI: row.string("ZTYPEUTI1", "ZTYPEUTI") ?? "public.data", filename: filename, filePath: path, title: row.string("ZTITLE", "ZFALLBACKTITLE", "ZALTTEXT", "ZDISPLAYTEXT"), url: row.string("ZURLSTRING", "ZREMOTEFILEURLSTRING"), ocrText: ocr.isEmpty ? nil : ocr)
    }
}
