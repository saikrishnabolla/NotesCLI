import Foundation
import NotesCore
import PDFKit

public final class SQLiteNotesStore: NotesReading, Sendable {
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }
    private let library: StoreLibrary
    private let container: URL
    private let accountList: [Account]
    private let folderList: [Folder]
    private let summaries: [NoteSummary]
    private let placeholderIDs: Set<String>
    /// Unfetched cloud placeholder rows that are hidden from every listing.
    public let placeholderCount: Int
    private let notePKs: [String: Int64]
    private let noteRows: [Int64: StoreRow]
    private let objectsByID: [String: StoreRow]
    private let attachmentRows: [Int64: [StoreRow]]
    private let canReadDefaultLocation: Bool

    /// A process-wide snapshot is reused. `refresh` is for explicit refresh/read-back after automation.
    public init(databaseURL: URL = SQLiteNotesStore.defaultDatabaseURL, groupContainerURL: URL? = nil, refresh: Bool = false) throws {
        let library = try SnapshotCache.shared.load(databaseURL, refresh: refresh)
        self.library = library
        self.container = groupContainerURL ?? databaseURL.deletingLastPathComponent()
        self.canReadDefaultLocation = databaseURL.standardizedFileURL == Self.defaultDatabaseURL.standardizedFileURL
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
        var deletedFolderPKs = Set(folders.compactMap { row in
            row.int("ZMARKEDFORDELETION") == 1 ? row.int("Z_PK") : nil
        })
        var changed = true
        while changed {
            changed = false
            for row in folders {
                guard let pk = row.int("Z_PK"), let parent = row.int("ZPARENT"), deletedFolderPKs.contains(parent) else { continue }
                changed = deletedFolderPKs.insert(pk).inserted || changed
            }
        }
        var folderByPK: [Int64: Folder] = [:]
        for row in folders {
            guard let pk = row.int("Z_PK"), let id = row.string("ZIDENTIFIER") else { continue }
            // Deleted folders stay as rows until iCloud confirms; unfetched ones are placeholders.
            // Notes.app shows neither, so neither is a folder to the user.
            if row.int("ZMARKEDFORDELETION") == 1 || row.int("ZNEEDSINITIALFETCHFROMCLOUD") == 1 { continue }
            let name = row.string("ZTITLE2", "ZTITLE1", "ZTITLE", "ZNAME") ?? ""
            let parent = row.int("ZPARENT").flatMap { library.objects[$0]?.string("ZIDENTIFIER") }
            let deleted = row.int("ZFOLDERTYPE") == 1 || row.int("ZISRECENTLYDELETED", "ZISTRASH") == 1 || id.lowercased().contains("recentlydeleted")
            let smartQuery = row.string("ZSMARTFOLDERQUERYJSON")
            folderByPK[pk] = Folder(id: id, name: name, accountID: account(row), parentID: parent, path: [], isSmartFolder: row.int("ZFOLDERTYPE") == 2 || !(smartQuery ?? "").isEmpty, isRecentlyDeleted: deleted, noteCount: 0, smartFolderQuery: smartQuery, coreDataID: "x-coredata://\(library.storeUUID)/ICFolder/p\(pk)")
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
        var summaries: [NoteSummary] = [], pks: [String: Int64] = [:], noteRows: [Int64: StoreRow] = [:]
        var placeholders = Set<String>()
        for row in library.rows("ICNote") {
            guard let pk = row.int("Z_PK"), let uuid = row.string("ZIDENTIFIER") else { continue }
            noteRows[pk] = row
            let folderPK = row.int("ZFOLDER"), folder = folderPK.flatMap { folderByPK[$0] }
            let deleted = row.int("ZMARKEDFORDELETION") == 1 || folder?.isRecentlyDeleted == true || folderPK.map(deletedFolderPKs.contains) == true
            let attachments = attachmentRows[pk] ?? []
            let tags = Set(attachments.compactMap { item -> String? in
                guard (item.string("ZTYPEUTI1", "ZTYPEUTI") ?? "").contains("hashtag") else { return nil }
                guard let label = item.string("ZALTTEXT", "ZDISPLAYTEXT", "ZSTANDARDIZEDCONTENT", "ZTOKENCONTENTIDENTIFIER") else { return nil }
                return label.hasPrefix("#") ? String(label.dropFirst()) : label
            }).sorted()
            let coreDataID = "x-coredata://\(library.storeUUID)/ICNote/p\(pk)"
            func flag(_ name: String) -> Bool? { row.integers[name].map { $0 == 1 } }
            let participantList = library.participants[pk]
            let shared = !(participantList ?? []).isEmpty || row.data("ZSERVERSHAREDATA") != nil
            let cloud = library.cloudStates[pk]
            let sync = NoteSyncState(needsInitialFetch: flag("ZNEEDSINITIALFETCHFROMCLOUD"),
                                     needsFetch: flag("ZNEEDSTOBEFETCHEDFROMCLOUD"),
                                     needsFetchAssets: flag("ZNEEDSTOFETCHUSERSPECIFICRECORDASSETS"),
                                     needsSave: flag("ZNEEDSTOSAVEUSERSPECIFICRECORD"), hasChanges: flag("ZNOTEHASCHANGES"),
                                     versionOutOfDate: flag("ZVERSIONOUTOFDATE"), cloudState: row.int("ZCLOUDSTATE").map(Int.init),
                                     lastSyncDate: row.date("ZLASTSYNCDATE"),
                                     currentLocalVersion: cloud?.currentLocalVersion,
                                     latestVersionSyncedToCloud: cloud?.latestVersionSyncedToCloud,
                                     isInCloud: cloud?.isInCloud)
            if sync.needsInitialFetch == true { placeholders.insert(uuid.lowercased()) }
            summaries.append(NoteSummary(id: NoteID(uuid: uuid, coreDataID: coreDataID, shortID: "n\(pk)"), title: row.string("ZTITLE1", "ZTITLE2", "ZTITLE") ?? "", snippet: row.string("ZSNIPPET", "ZWIDGETSNIPPET") ?? "", folderID: folder?.id, folderPath: folder?.path ?? [], accountID: folder?.accountID.isEmpty == false ? folder!.accountID : account(row), created: row.date("ZCREATIONDATE3", "ZCREATIONDATE1", "ZCREATIONDATE"), modified: row.date("ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"), isPinned: row.int("ZISPINNED") == 1, isLocked: row.int("ZISPASSWORDPROTECTED") == 1, isDeleted: deleted, hasChecklist: row.int("ZHASCHECKLIST") == 1, attachmentCount: attachments.filter { !(($0.string("ZTYPEUTI1", "ZTYPEUTI") ?? "").contains("inlinetextattachment")) }.count, tags: tags, hasChecklistInProgress: flag("ZHASCHECKLISTINPROGRESS"), lastOpened: row.date("ZLASTOPENEDDATE"), displayOrder: nil, isShared: shared, participants: participantList, syncState: sync, isSystemPaper: flag("ZISSYSTEMPAPER")))
            pks[uuid.lowercased()] = pk
            if !deleted, !placeholders.contains(uuid.lowercased()), let folderPK { folderByPK[folderPK]?.noteCount += 1 }
            else if folder?.isRecentlyDeleted == true, row.int("ZMARKEDFORDELETION") != 1, let folderPK { folderByPK[folderPK]?.noteCount += 1 }
        }
        self.placeholderCount = placeholders.count
        self.placeholderIDs = placeholders
        self.summaries = summaries.sorted {
            if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return $0.id.uuid < $1.id.uuid
        }
        self.notePKs = pks
        self.noteRows = noteRows
        self.folderList = folderByPK.values.sorted { $0.path.joined(separator: " > ").localizedStandardCompare($1.path.joined(separator: " > ")) == .orderedAscending }
    }

    public func attachmentHasStoredLocation(note ref: String, attachmentID: String) throws -> Bool {
        let summary = try summary(ref)
        guard let notePK = notePKs[summary.id.uuid.lowercased()] else {
            throw NotesError("note_not_found", "No note matches the reference.")
        }
        guard let row = attachmentRows[notePK]?.first(where: {
            $0.string("ZIDENTIFIER")?.caseInsensitiveCompare(attachmentID) == .orderedSame
        }) else {
            throw NotesError("attachment_not_found", "No attachment matches \(attachmentID).")
        }
        return row.int("ZLOCATION").map { $0 != 0 } ?? false
    }

    public func scanMarkupPayloads(_ ref: String) throws -> [String: Data] {
        let summary = try summary(ref)
        guard let notePK = notePKs[summary.id.uuid.lowercased()] else {
            throw NotesError("note_not_found", "No note matches the reference.")
        }
        var result: [String: Data] = [:]
        for row in attachmentRows[notePK] ?? [] {
            guard let data = row.data("ZMARKUPMODELDATA"), !data.isEmpty else { continue }
            guard let id = row.string("ZIDENTIFIER"), !id.isEmpty else {
                throw NotesError("scan_markup_unavailable", "A scan markup model has no page identifier.")
            }
            result[id] = data
        }
        return result
    }

    public func folderDateHeadersType(_ folderID: String) throws -> Int {
        guard let row = objectsByID[folderID.lowercased()],
              let value = row.int("ZDATEHEADERSTYPE") else {
            throw NotesError("folder_not_found", "No folder with stored date-header state matches the identifier.")
        }
        return Int(value)
    }

    public func noteDeletionState(_ ref: String) throws -> (markedForDeletion: Bool, folderType: Int?) {
        let summary = try resolve(ref)
        guard let notePK = notePKs[summary.id.uuid.lowercased()], let row = noteRows[notePK] else {
            throw NotesError("note_not_found", "No note matches the reference.")
        }
        let folderType = row.int("ZFOLDER").flatMap { library.objects[$0]?.int("ZFOLDERTYPE", "ZTYPE") }.map(Int.init)
        return (row.int("ZMARKEDFORDELETION") == 1, folderType)
    }
    public func accounts() throws -> [Account] {
        guard let location = try defaultLocation() else { return accountList }
        return accountList.map { account in
            var account = account
            if account.id == location.accountID {
                account.isDefault = true; account.defaultFolderID = location.folderID
                account.defaultFolderName = location.folderName
            }
            return account
        }
    }
    public func defaultLocation() throws -> DefaultNotesLocation? {
        if canReadDefaultLocation, let scripted = Self.scriptedDefaultLocation() {
            let account = accountList.first { $0.id.caseInsensitiveCompare(scripted.accountID) == .orderedSame || $0.name == scripted.accountName }
            let folders = folderList.filter { $0.accountID == account?.id }
            let folder = folders.first { $0.id.caseInsensitiveCompare(scripted.folderID ?? "") == .orderedSame }
                ?? folders.first { $0.name == scripted.folderName }
            if let account {
                return DefaultNotesLocation(accountID: account.id, accountName: account.name, folderID: folder?.id,
                                            folderName: folder?.name ?? scripted.folderName, folderPath: folder?.path ?? [])
            }
        }
        guard let account = accountList.first(where: { $0.kind == "icloud" }) ?? accountList.first else { return nil }
        let folders = folderList.filter { $0.accountID == account.id && !$0.isRecentlyDeleted && !$0.isSmartFolder }
        let folder = folders.first { $0.parentID == nil && $0.name == "Notes" } ?? folders.first { $0.parentID == nil } ?? folders.first
        return DefaultNotesLocation(accountID: account.id, accountName: account.name, folderID: folder?.id,
                                    folderName: folder?.name, folderPath: folder?.path ?? [])
    }
    public func folders(account: String? = nil) throws -> [Folder] {
        guard let account else { return folderList }
        let ids = Set(accountList.filter { $0.id.caseInsensitiveCompare(account) == .orderedSame || $0.name == account }.map(\.id))
        return folderList.filter { ids.contains($0.accountID) }
    }
    public func notes(_ query: NoteQuery = NoteQuery()) throws -> [NoteSummary] {
        try notes(query, includePlaceholders: false)
    }
    public func notes(_ query: NoteQuery, includePlaceholders: Bool) throws -> [NoteSummary] {
        if let limit = query.limit, limit < 0 { throw NotesError("invalid_limit", "The limit must be zero or greater.") }
        if query.limit == 0 { return [] }
        let accountIDs = query.account.map { account in Set(accountList.filter { $0.id.caseInsensitiveCompare(account) == .orderedSame || $0.name == account }.map(\.id)) }
        let folderIDs = query.folder.map { ref in Set(folderList.filter { $0.id.caseInsensitiveCompare(ref) == .orderedSame || $0.name == ref || $0.path.joined(separator: " > ") == ref }.map(\.id)) }
        let tag = query.tag.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        var result: [NoteSummary] = []
        for summary in summaries {
            if !includePlaceholders && placeholderIDs.contains(summary.id.uuid.lowercased()) { continue }
            if !query.includeDeleted && summary.isDeleted { continue }
            if query.pinnedOnly && !summary.isPinned { continue }
            if let ids = accountIDs, !ids.contains(summary.accountID) { continue }
            if let ids = folderIDs, !ids.contains(summary.folderID ?? "") { continue }
            if let tag, !summary.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { continue }
            if !query.attachmentKinds.isEmpty {
                let kinds = try Set(attachments(summary.id.uuid).map(\.kind))
                if !query.attachmentKinds.allSatisfy({ kind in
                    kind == "checklist" ? summary.hasChecklist : kinds.contains(kind) || (kind == "link" && kinds.contains("note-link"))
                }) { continue }
            }
            if let date = query.modifiedAfter, (summary.modified ?? .distantPast) <= date { continue }
            if let date = query.modifiedBefore, (summary.modified ?? .distantFuture) >= date { continue }
            if let text = query.text, !text.isEmpty {
                func matches(_ value: String) -> Bool { value.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                if !matches(summary.title) && !matches(summary.snippet) {
                    guard !summary.isLocked, let pk = notePKs[summary.id.uuid.lowercased()], library.bodies[pk] != nil else { continue }
                    let note = try self.note(summary.id.uuid)
                    let searchable = note.document?.plainText(attachments: note.attachments) ?? ""
                    if !matches(searchable) && !note.attachments.contains(where: { matches($0.searchableText) }) { continue }
                }
            }
            result.append(summary)
        }
        result.sort {
            if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return $0.id.uuid < $1.id.uuid
        }
        return Array(result.prefix(query.limit ?? result.count))
    }

    public func editorSearch(_ query: EditorSearchQuery) throws -> [EditorSearchMatch] {
        try notes(.init()).compactMap { summary in
            query.match(summary, body: {
                guard let pk = notePKs[summary.id.uuid.lowercased()], let data = library.bodies[pk] else { return nil }
                return try? NotesDecoder.plainText(data)
            })
        }
    }

    public func notes(_ query: NoteQuery, sort: NoteSort) throws -> [NoteSummary] {
        var unbounded = query
        let limit = unbounded.limit
        unbounded.limit = nil
        var result = try notes(unbounded)
        if result.isEmpty { return [] }

        switch sort {
        case .modified:
            result.sort { Self.compareDate($0.modified, $1.modified, newestFirst: true, lhsID: $0.id.uuid, rhsID: $1.id.uuid) }
        case .created:
            result.sort { Self.compareDate($0.created, $1.created, newestFirst: true, lhsID: $0.id.uuid, rhsID: $1.id.uuid) }
        case .opened:
            result.sort {
                if $0.lastOpened != $1.lastOpened {
                    return Self.compareDate($0.lastOpened, $1.lastOpened, newestFirst: true, lhsID: $0.id.uuid, rhsID: $1.id.uuid)
                }
                return Self.compareDate($0.modified, $1.modified, newestFirst: true, lhsID: $0.id.uuid, rhsID: $1.id.uuid)
            }
        case .title:
            result.sort { Self.compareTitle($0.title, $1.title, ascending: true, lhsID: $0.id.uuid, rhsID: $1.id.uuid) }
        case .display:
            let order = try effectiveDisplayOrder(for: unbounded)
            result.sort { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return order.precedes(lhs, rhs)
            }
            for index in result.indices { result[index].displayOrder = Double(index) }
        }

        return Array(result.prefix(limit ?? result.count))
    }

    private enum EffectiveDisplayOrder {
        case modified(newestFirst: Bool)
        case created(newestFirst: Bool)
        case title(ascending: Bool, modifiedTieBreak: Bool)

        func precedes(_ lhs: NoteSummary, _ rhs: NoteSummary) -> Bool {
            switch self {
            case .modified(let newestFirst):
                if lhs.modified != rhs.modified {
                    return SQLiteNotesStore.compareDate(lhs.modified, rhs.modified, newestFirst: newestFirst,
                                                        lhsID: lhs.id.uuid, rhsID: rhs.id.uuid)
                }
                return SQLiteNotesStore.compareTitle(lhs.title, rhs.title, ascending: newestFirst,
                                                     lhsID: lhs.id.uuid, rhsID: rhs.id.uuid)
            case .created(let newestFirst):
                if lhs.created != rhs.created {
                    return SQLiteNotesStore.compareDate(lhs.created, rhs.created, newestFirst: newestFirst,
                                                        lhsID: lhs.id.uuid, rhsID: rhs.id.uuid)
                }
                return SQLiteNotesStore.compareTitle(lhs.title, rhs.title, ascending: newestFirst,
                                                     lhsID: lhs.id.uuid, rhsID: rhs.id.uuid)
            case .title(let ascending, let modifiedTieBreak):
                let titleOrder = NoteTitleOrder.compare(lhs.title, rhs.title)
                if titleOrder != .orderedSame {
                    return ascending ? titleOrder == .orderedAscending : titleOrder == .orderedDescending
                }
                guard modifiedTieBreak else { return lhs.id.uuid < rhs.id.uuid }
                return SQLiteNotesStore.compareDate(lhs.modified, rhs.modified, newestFirst: ascending,
                                                    lhsID: lhs.id.uuid, rhsID: rhs.id.uuid)
            }
        }
    }

    private func effectiveDisplayOrder(for query: NoteQuery) throws -> EffectiveDisplayOrder {
        if let folderReference = query.folder {
            let matches = folderList.filter {
                $0.id.caseInsensitiveCompare(folderReference) == .orderedSame ||
                $0.name == folderReference ||
                $0.path.joined(separator: " > ") == folderReference
            }
            if matches.count > 1 {
                throw NotesError("ambiguous_folder", "More than one folder matches the display-order reference.")
            }
            if matches.count == 1,
               let folderID = matches.first?.id,
               let storedValue = objectsByID[folderID.lowercased()]?.int("ZCUSTOMNOTESORTTYPEVALUE") {
                switch storedValue {
                case 0: break
                case 10: return .modified(newestFirst: true)
                case 11: return .modified(newestFirst: false)
                case 20: return .created(newestFirst: true)
                case 21: return .created(newestFirst: false)
                case 30: return .title(ascending: true, modifiedTieBreak: true)
                case 31: return .title(ascending: false, modifiedTieBreak: true)
                default:
                    throw NotesError("unsupported_display_order", "The folder has an unknown Apple Notes sort value: \(storedValue).")
                }
            }
        }
        return try globalDisplayOrder()
    }

    private func globalDisplayOrder() throws -> EffectiveDisplayOrder {
        let url = container.appendingPathComponent("Library/Preferences/group.com.apple.notes.plist")
        let raw: Any?
        if let data = try? Data(contentsOf: url),
           let preferences = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            raw = preferences["kICSettingsNoteListSortTypeKey"]
        } else {
            raw = nil
        }
        guard let raw else { return .modified(newestFirst: true) }
        let value: Int?
        if let number = raw as? NSNumber { value = number.intValue }
        else if let string = raw as? String { value = Int(string) }
        else { value = nil }
        switch value {
        case 0: return .modified(newestFirst: true)
        case 1: return .created(newestFirst: true)
        case 2: return .title(ascending: true, modifiedTieBreak: false)
        default:
            throw NotesError("unsupported_display_order", "Apple Notes has an unknown global sort value.")
        }
    }

    private static func compareDate(_ lhs: Date?, _ rhs: Date?, newestFirst: Bool,
                                    lhsID: String, rhsID: String) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?) where left != right:
            return newestFirst ? left > right : left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            // Apple does not publish its secondary key. UUID is NotesCLI's stable pagination key.
            return lhsID < rhsID
        }
    }

    private static func compareTitle(_ lhs: String, _ rhs: String, ascending: Bool,
                                     lhsID: String, rhsID: String) -> Bool {
        let order = NoteTitleOrder.compare(lhs, rhs)
        guard order != .orderedSame else { return lhsID < rhsID }
        return ascending ? order == .orderedAscending : order == .orderedDescending
    }
    public func summary(_ ref: String) throws -> NoteSummary { try resolve(ref) }
    public func note(_ ref: String) throws -> Note {
        let summary = try resolve(ref)
        // Do not read or decode encrypted payloads, including attachments.
        if summary.isLocked { return Note(summary: summary, document: nil, attachments: []) }
        guard let pk = notePKs[summary.id.uuid.lowercased()], let data = library.bodies[pk], !data.isEmpty else {
            throw NotesError("body_unavailable", "The note body is not downloaded in this snapshot.", hint: "run notescli fetch")
        }
        return try decodedNote(summary: summary, notePK: pk, data: data, includeAttachments: true)
    }

    public func note(_ ref: String, password: String) throws -> Note {
        let opened = try openLockedNote(ref, password: password)
        return try decodedNote(summary: opened.summary, notePK: opened.notePK,
                               data: opened.data, includeAttachments: false)
    }

    public func withPasswordUnlockedNote(_ ref: String, password: String,
                                         _ body: (Note) throws -> Void) throws {
        let opened = try openLockedNote(ref, password: password)
        var note = try decodedNote(summary: opened.summary, notePK: opened.notePK,
                                   data: opened.data, includeAttachments: false)
        let attachmentEntities = (library.entities["ICAttachment"] ?? [])
            .union(library.entities["ICInlineAttachment"] ?? [])
        var rowsByPK = Dictionary(uniqueKeysWithValues: (attachmentRows[opened.notePK] ?? []).compactMap { row in
            row.int("Z_PK").map { ($0, row) }
        })
        let knownIDs = Set(rowsByPK.values.compactMap { $0.string("ZIDENTIFIER")?.lowercased() })
        for reference in note.document?.runs.compactMap(\.attachment) ?? []
            where !knownIDs.contains(reference.id.lowercased()) {
            guard let row = objectsByID[reference.id.lowercased()], let pk = row.int("Z_PK"),
                  attachmentEntities.contains(row.int("Z_ENT") ?? -1) else { continue }
            rowsByPK[pk] = row
        }
        var foundChild = true
        while foundChild {
            foundChild = false
            let known = Set(rowsByPK.keys)
            for row in library.objects.values where row.int("ZMARKEDFORDELETION") != 1 {
                guard let pk = row.int("Z_PK"), rowsByPK[pk] == nil,
                      attachmentEntities.contains(row.int("Z_ENT") ?? -1),
                      let parent = row.int("ZPARENTATTACHMENT", "ZPARENTATTACHMENT1"),
                      known.contains(parent) else { continue }
                rowsByPK[pk] = row
                foundChild = true
            }
        }
        let rows = Array(rowsByPK.values)
        guard !rows.isEmpty else { try body(note); return }
        let scope = try LockedAttachmentExtractionScope()
        defer { scope.cleanup() }
        var extractor = LockedAttachmentExtractor(
            library: library, container: container, accountID: opened.summary.accountID,
            password: password, scope: scope)
        extractor.noteMainKey = opened.mainKey
        var extractedByPK: [Int64: LockedAttachmentResult] = [:]
        for row in rows {
            guard let pk = row.int("Z_PK") else { continue }
            extractedByPK[pk] = try extractor.extract(row)
        }
        func build(_ pk: Int64, visited: Set<Int64>) -> Attachment? {
            guard !visited.contains(pk), let extracted = extractedByPK[pk] else { return nil }
            var attachment = makeAttachment(
                extracted.row,
                accountID: opened.summary.accountID,
                filenameOverride: extracted.filename,
                filePathOverride: extracted.filePath)
            let childPKs = extractedByPK.compactMap { key, value in
                value.row.int("ZPARENTATTACHMENT", "ZPARENTATTACHMENT1") == pk ? key : nil
            }
            let children = childPKs.sorted().compactMap { build($0, visited: visited.union([pk])) }
            if !children.isEmpty {
                attachment.childAttachmentIDs = children.map(\.id)
                attachment.childAttachments = children
                attachment.pageImagePaths = children.compactMap(\.filePath)
            }
            return attachment
        }
        let roots = extractedByPK.compactMap { pk, value -> Int64? in
            guard let parent = value.row.int("ZPARENTATTACHMENT", "ZPARENTATTACHMENT1") else { return pk }
            return extractedByPK[parent] == nil ? pk : nil
        }
        note.attachments = roots.sorted().compactMap { build($0, visited: []) }
        try body(note)
    }

    private func openLockedNote(_ ref: String, password: String) throws
        -> (summary: NoteSummary, notePK: Int64, data: Data, mainKey: Data?) {
        let summary = try resolve(ref)
        guard summary.isLocked else { throw NotesError("note_not_locked", "The note is not locked.") }
        guard let pk = notePKs[summary.id.uuid.lowercased()], let encrypted = library.bodies[pk], !encrypted.isEmpty else {
            throw NotesError("cloud_pending", "The locked note body is not downloaded on this Mac.", hint: "Open it in Notes, wait for it to download, then retry.")
        }
        let noteRow = noteRows[pk]
        let bodyRow = library.bodyRows[pk]
        let legacy: LockedNoteCrypto.Parameters?
        if let salt = noteRow?.data("ZCRYPTOSALT"),
           let iterations = noteRow?.int("ZCRYPTOITERATIONCOUNT").map(Int.init),
           let wrapped = noteRow?.data("ZCRYPTOWRAPPEDKEY", "ZCRYPTOVERIFIER"),
           let iv = bodyRow?.data("ZCRYPTOINITIALIZATIONVECTOR"),
           let tag = bodyRow?.data("ZCRYPTOTAG") {
            legacy = .init(salt: salt, iterations: iterations, wrappedKey: wrapped, iv: iv, tag: tag,
                           ciphertext: encrypted, authenticatedData: nil)
        } else { legacy = nil }
        let opened = try LockedNoteCrypto.openVerifyingMainKey(
            password: password, encryptedBody: encrypted, legacy: legacy)
        return (summary, pk, opened.plaintext, opened.mainKey)
    }

    private func decodedNote(summary: NoteSummary, notePK pk: Int64, data: Data,
                             includeAttachments: Bool) throws -> Note {
        var document: NoteDocument
        do { document = try NotesDecoder.decode(data) }
        catch let error as DecodeError { throw NotesError("decode_\(error.rawValue)", "Cannot decode the note body.") }
        if let outlineData = noteRows[pk]?.data("ZOUTLINESTATEDATA"), !outlineData.isEmpty {
            do { document.applyCollapsedParagraphIDs(try NotesOutlineDecoder.decode(outlineData)) }
            catch let error as DecodeError { throw NotesError("outline_\(error.rawValue)", "Cannot decode the note outline state.") }
        }
        guard includeAttachments else {
            return Note(summary: summary, document: document, attachments: [])
        }
        var rows = attachmentRows[pk] ?? []
        let known = Set(rows.compactMap { $0.string("ZIDENTIFIER")?.lowercased() })
        for ref in document.runs.compactMap(\.attachment) where !known.contains(ref.id.lowercased()) {
            if let row = objectsByID[ref.id.lowercased()] { rows.append(row) }
        }
        var attachments: [Attachment] = [], seen: Set<String> = []
        for row in rows {
            guard let id = row.string("ZIDENTIFIER"), seen.insert(id).inserted else { continue }
            var attachment = makeAttachment(row, accountID: summary.accountID)
            if attachment.typeUTI == "com.apple.notes.table", let tableData = row.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA") {
                do {
                    if document.tables == nil { document.tables = [:] }
                    if document.tableCells == nil { document.tableCells = [:] }
                    let decoded = try NotesTableDecoder.decodeTable(tableData) { ref in
                        self.objectsByID[ref.id.lowercased()]?.string("ZALTTEXT", "ZDISPLAYTEXT", "ZTITLE", "ZFALLBACKTITLE", "ZFILENAME")
                    }
                    let cells = decoded.cells
                    attachment.tableRightToLeft = decoded.rightToLeft
                    document.tableCells?[id] = cells
                    document.tables?[id] = cells.map { $0.map { $0.document.plainText() } }
                } catch let error as DecodeError { throw NotesError("table_\(error.rawValue)", "Cannot decode an embedded table.") }
            }
            attachments.append(attachment)
        }
        func hydrate(_ original: InlineRef) -> InlineRef {
            var ref = original
            guard let row = objectsByID[ref.id.lowercased()] else { return ref }
            ref.typeUTI = row.string("ZTYPEUTI1", "ZTYPEUTI") ?? ref.typeUTI
            ref.displayText = row.string("ZALTTEXT", "ZDISPLAYTEXT", "ZTITLE", "ZFALLBACKTITLE")
            if ref.typeUTI == "com.apple.notes.inlinetextattachment.link", let target = row.string("ZTOKENCONTENTIDENTIFIER") {
                ref.url = target.hasPrefix("applenotes:") ? target : "applenotes://showNote?identifier=\(target)"
            } else { ref.url = row.string("ZURLSTRING") }
            ref.parentAttachmentCaptured = true
            ref.parentAttachmentID = row.int("ZPARENTATTACHMENT1", "ZPARENTATTACHMENT")
                .flatMap { library.objects[$0]?.string("ZIDENTIFIER") }
            return ref
        }
        for i in document.runs.indices {
            guard let ref = document.runs[i].attachment else { continue }
            document.runs[i].attachment = hydrate(ref)
        }
        if var tables = document.tableCells {
            for tableID in tables.keys {
                guard var rows = tables[tableID] else { continue }
                for rowIndex in rows.indices {
                    for columnIndex in rows[rowIndex].indices {
                        for runIndex in rows[rowIndex][columnIndex].runs.indices {
                            guard let ref = rows[rowIndex][columnIndex].runs[runIndex].attachment else { continue }
                            rows[rowIndex][columnIndex].runs[runIndex].attachment = hydrate(ref)
                        }
                    }
                }
                tables[tableID] = rows
            }
            document.tableCells = tables
        }
        let deep = try self.attachments(summary.id.uuid)
        func attachmentIDs(_ values: [Attachment]) -> Set<String> {
            values.reduce(into: Set<String>()) { result, attachment in
                result.insert(attachment.id)
                result.formUnion(attachmentIDs(attachment.childAttachments ?? []))
            }
        }
        let deepIDs = attachmentIDs(deep)
        attachments = deep + attachments.filter { !deepIDs.contains($0.id) }
        return Note(summary: summary, document: document, attachments: attachments)
    }

    private func resolve(_ ref: String) throws -> NoteSummary {
        let visible = summaries.filter { !placeholderIDs.contains($0.id.uuid.lowercased()) }
        return try NoteReference.resolve(ref, identifiers: { value in
            visible.filter {
                $0.id.uuid.caseInsensitiveCompare(value) == .orderedSame ||
                $0.id.coreDataID?.caseInsensitiveCompare(value) == .orderedSame ||
                $0.id.shortID?.caseInsensitiveCompare(value) == .orderedSame
            }
        }, number: { number in visible.filter { $0.number == number } },
        title: { title in visible.filter { $0.title == title && !$0.isDeleted } },
        key: \.id.uuid, describe: { NoteReference.describe(number: $0.number, uuid: $0.id.uuid, title: $0.title) })
    }
    public func tags() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for note in summaries where !note.isDeleted && !placeholderIDs.contains(note.id.uuid.lowercased()) { for tag in note.tags { counts[tag, default: 0] += 1 } }
        return counts
    }

    public func attachments(_ ref: String) throws -> [Attachment] {
        let summary = try resolve(ref)
        guard !summary.isLocked, let pk = notePKs[summary.id.uuid.lowercased()] else { return [] }
        let attachmentEntities = (library.entities["ICAttachment"] ?? []).union(library.entities["ICInlineAttachment"] ?? [])
        var rowsByPK = Dictionary(uniqueKeysWithValues: (attachmentRows[pk] ?? []).compactMap { row in
            row.int("Z_PK").map { ($0, row) }
        })
        var changed = true
        while changed {
            changed = false
            let known = Set(rowsByPK.keys)
            for row in library.objects.values where row.int("ZMARKEDFORDELETION") != 1 {
                guard let rowPK = row.int("Z_PK"), rowsByPK[rowPK] == nil,
                      attachmentEntities.contains(row.int("Z_ENT") ?? -1),
                      let parent = row.int("ZPARENTATTACHMENT", "ZPARENTATTACHMENT1"), known.contains(parent) else { continue }
                rowsByPK[rowPK] = row
                changed = true
            }
        }
        let rootPKs = rowsByPK.compactMap { key, row -> Int64? in
            guard let parent = row.int("ZPARENTATTACHMENT", "ZPARENTATTACHMENT1") else { return key }
            return rowsByPK[parent] == nil ? key : nil
        }
        func build(_ parentPK: Int64, visited: Set<Int64>) -> Attachment? {
            guard !visited.contains(parentPK), let row = rowsByPK[parentPK] else { return nil }
            var parent = makeAttachment(row, accountID: summary.accountID)
            let childRows = rowsByPK.values.filter { $0.int("ZPARENTATTACHMENT", "ZPARENTATTACHMENT1") == parentPK }
            guard !childRows.isEmpty else { return parent }
            let childIDs = childRows.compactMap { $0.string("ZIDENTIFIER") }
            let mergeable = noteRows[parentPK]?.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA") ?? library.objects[parentPK]?.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA")
            // A recording lists its audio fragments in order; transcript fragment indices follow that order.
            let recordingData = parent.typeUTI.contains("audio") ? row.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA") : nil
            let decodedRecording = recordingData.flatMap { try? NotesRecordingDecoder.decode($0) }
            let completeFragmentOrder = decodedRecording?.fragments ?? []
            let fragmentOrder = completeFragmentOrder.filter(childIDs.contains)
            let storedGalleryOrder = galleryOrder(mergeable, available: childIDs)
            let ordered = fragmentOrder.isEmpty ? storedGalleryOrder : fragmentOrder
            let byID = Dictionary(uniqueKeysWithValues: childRows.compactMap { row -> (String, StoreRow)? in row.string("ZIDENTIFIER").map { ($0, row) } })
            let orderedRows = ordered.compactMap { byID[$0] } + childRows.filter { row in
                guard let id = row.string("ZIDENTIFIER") else { return true }; return !ordered.contains(id)
            }.sorted { ($0.double("ZSORTORDER", "ZCREATIONDATE") ?? 0) < ($1.double("ZSORTORDER", "ZCREATIONDATE") ?? 0) }
            let nextVisited = visited.union([parentPK])
            let childAttachments = orderedRows.compactMap { $0.int("Z_PK").flatMap { build($0, visited: nextVisited) } }
            parent.childAttachmentIDs = childAttachments.map(\.id)
            parent.childAttachments = childAttachments
            if !completeFragmentOrder.isEmpty {
                let availableIndices = Dictionary(uniqueKeysWithValues: childAttachments.enumerated().map { ($0.element.id, $0.offset) })
                parent.transcriptWords = parent.transcriptWords?.compactMap { word in
                    let oldIndex = word.fragment ?? 0
                    guard completeFragmentOrder.indices.contains(oldIndex),
                          let newIndex = availableIndices[completeFragmentOrder[oldIndex]] else { return nil }
                    var word = word
                    word.fragment = newIndex
                    return word
                }
                parent.transcriptText = parent.transcriptWords.map(NotesRecordingDecoder.joined)
            }
            parent.pageImagePaths = childAttachments.compactMap(\.filePath)
            if parent.filePath == nil, let original = childAttachments.first(where: { $0.kind == "audio" || $0.filename != nil }) {
                parent.filePath = original.filePath; parent.filename = parent.filename ?? original.filename
            }
            return parent
        }
        return rootPKs.compactMap { build($0, visited: []) }.sorted { $0.id < $1.id }
    }

    public func rawNote(_ ref: String) throws -> RawProtobufMessage {
        let summary = try resolve(ref)
        if summary.isLocked { throw NotesError("note_locked", "The note is locked.") }
        guard let pk = notePKs[summary.id.uuid.lowercased()], let data = library.bodies[pk], !data.isEmpty else {
            throw NotesError("body_unavailable", "The note body is not downloaded in this snapshot.", hint: "run notescli fetch")
        }
        do { return try ProtobufMessage(NotesInflate.decompressIfNeeded(data)).raw }
        catch { throw NotesError("decode_invalidProtobuf", "Cannot decode the note body.") }
    }

    public func backlinks(_ ref: String) throws -> [NoteSummary] {
        let target = try resolve(ref).id.uuid
        let noteEntities = library.entities["ICNote"] ?? []
        let pks = Set(library.rows("ICInlineAttachment").compactMap { row -> Int64? in
            let uti = row.string("ZTYPEUTI1", "ZTYPEUTI") ?? ""
            guard uti == "com.apple.notes.inlinetextattachment.link",
                  let token = row.string("ZTOKENCONTENTIDENTIFIER"),
                  AppleNotesLinkTarget.identifier(from: token)?.caseInsensitiveCompare(target) == .orderedSame else { return nil }
            return row.int("ZNOTE1", "ZNOTE")
        })
        return summaries.filter { summary in
            guard !placeholderIDs.contains(summary.id.uuid.lowercased()) else { return false }
            guard let pk = notePKs[summary.id.uuid.lowercased()], noteEntities.contains(noteRows[pk]?.int("Z_ENT") ?? -1) else { return false }
            return pks.contains(pk)
        }
    }

    public func smartFolders(evaluate: Bool = false) throws -> [SmartFolderResult] {
        let now = Date()
        return folderList.filter(\.isSmartFolder).map { folder in
            let rule = Self.smartRule(folder.smartFolderQuery)
            let labels = rule.map(Self.ruleLabels) ?? []
            let unsupported = rule == nil ? ["invalid query"] : []
            let ids: [String]?
            if evaluate, let rule, unsupported.isEmpty {
                ids = summaries.filter { summary in
                    guard !placeholderIDs.contains(summary.id.uuid.lowercased()) else { return false }
                    let attachments = (try? self.attachments(summary.id.uuid)) ?? []
                    let document = (try? self.note(summary.id.uuid))?.document
                    return Self.matches(SmartNote(summary: summary, attachments: attachments, document: document), rule: rule, now: now)
                }.map { $0.id.uuid }
            } else { ids = nil }
            return SmartFolderResult(folder: folder, rules: labels, unsupportedRules: unsupported, matchingNoteIDs: ids)
        }
    }

    public func attachmentKindCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for summary in summaries where !summary.isLocked && !placeholderIDs.contains(summary.id.uuid.lowercased()) {
            for attachment in try attachments(summary.id.uuid) { counts[attachment.kind, default: 0] += 1 }
        }
        return counts
    }

    private func makeAttachment(_ row: StoreRow, accountID: String,
                                filenameOverride: String? = nil, filePathOverride: String? = nil) -> Attachment {
        let media = row.int("ZMEDIA").flatMap { library.objects[$0] }
        let id = row.string("ZIDENTIFIER") ?? ""
        let filename = filenameOverride ?? media?.string("ZFILENAME") ?? row.string("ZFILENAME")
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
            let pdf = root.appendingPathComponent("FallbackPDFs").appendingPathComponent(id)
            if let generation = row.string("ZFALLBACKPDFGENERATION") { candidates.append(pdf.appendingPathComponent(generation).appendingPathComponent("FallbackPDF.pdf")) }
            candidates += [root.appendingPathComponent("FallbackPDFs/\(id).pdf"), pdf.appendingPathComponent("FallbackPDF.pdf")]
        }
        let boundary = container.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let resolvedPath = candidates.first { url in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            var isDirectory: ObjCBool = false
            return resolved.hasPrefix(boundary) && FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) && !isDirectory.boolValue
        }?.path
        let path = filePathOverride ?? resolvedPath
        let uti = row.string("ZTYPEUTI1", "ZTYPEUTI") ?? "public.data"
        let recognized = row.string("ZOCRSUMMARY"), handwriting = row.string("ZHANDWRITINGSUMMARY"), extra = row.string("ZADDITIONALINDEXABLETEXT")
        let raster = uti.lowercased().contains("drawing") || uti.lowercased().contains("paper") ? path : nil
        let pdfText: String? = uti.lowercased().contains("pdf") ? path.flatMap { PDFDocument(url: URL(fileURLWithPath: $0))?.string } : nil
        var words: [TranscriptWord]?, recording: RecordingMetadata?, recordingFragments: [RecordingFragmentMetadata]?, transcript: String?
        if let blob = row.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA"), let decoded = try? NotesRecordingDecoder.decode(blob),
           !decoded.words.isEmpty || !decoded.fragmentMetadata.isEmpty || decoded.metadata.summary != nil || decoded.metadata.topLineSummary != nil {
            words = decoded.words; recording = decoded.metadata; recordingFragments = decoded.fragmentMetadata
            transcript = NotesRecordingDecoder.joined(decoded.words)
        }
        let lower = uti.lowercased(), token = row.string("ZTOKENCONTENTIDENTIFIER")
        let parentAttachment = row.int("ZPARENTATTACHMENT1", "ZPARENTATTACHMENT").flatMap { library.objects[$0] }
        let parentUTI = parentAttachment?.string("ZTYPEUTI1", "ZTYPEUTI")?.lowercased()
        let isScanPage = lower.contains("scan") || parentUTI?.contains("gallery") == true || parentUTI?.contains("scan") == true
        let notePK = row.int("ZNOTE1", "ZNOTE")
        let participant = notePK.flatMap { library.participants[$0] }?.first {
            $0.participantID?.caseInsensitiveCompare(token ?? "") == .orderedSame ||
            $0.userID?.caseInsensitiveCompare(token ?? "") == .orderedSame
        }
        let isCalculation = lower.contains("math") || lower.contains("calculate")
        let display = row.string("ZALTTEXT", "ZDISPLAYTEXT", "ZSTANDARDIZEDCONTENT", "ZFALLBACKTITLE")
        let participantName = lower.contains("mention") ? (display ?? row.string("ZUSERTITLE") ?? participant?.displayName) : nil
        let participantEmail = participant?.email ?? (participantName?.contains("@") == true ? participantName : nil)
        let drawingSVG = (lower.contains("drawing") || lower.contains("paper"))
            ? row.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA").flatMap { ClassicDrawingSVG.decode($0) ?? NotesDrawingDecoder.svg($0) }
            : nil
        let cropValues = ["ZCROPPINGQUADBOTTOMLEFTX", "ZCROPPINGQUADBOTTOMLEFTY",
                          "ZCROPPINGQUADBOTTOMRIGHTX", "ZCROPPINGQUADBOTTOMRIGHTY",
                          "ZCROPPINGQUADTOPLEFTX", "ZCROPPINGQUADTOPLEFTY",
                          "ZCROPPINGQUADTOPRIGHTX", "ZCROPPINGQUADTOPRIGHTY"].map { row.double($0) }
        let scanCrop: ScanCrop?
        if isScanPage, cropValues.allSatisfy({ $0 != nil }), !cropValues.allSatisfy({ $0 == 0 }) {
            scanCrop = ScanCrop(
                bottomLeft: ScanPoint(x: cropValues[0]!, y: cropValues[1]!),
                bottomRight: ScanPoint(x: cropValues[2]!, y: cropValues[3]!),
                topLeft: ScanPoint(x: cropValues[4]!, y: cropValues[5]!),
                topRight: ScanPoint(x: cropValues[6]!, y: cropValues[7]!))
        } else { scanCrop = nil }
        let location = row.int("ZLOCATION").flatMap { library.locations[$0] }
        let tableRightToLeft = uti == "com.apple.notes.table"
            ? row.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA").flatMap { try? NotesTableDecoder.decodeTable($0).rightToLeft }
            : nil
        let linkTarget = lower.contains("link") ? AppleNotesLinkTarget.parse(token) : nil
        return Attachment(id: id, typeUTI: uti, filename: filename, filePath: path,
                          title: row.string("ZTITLE", "ZFALLBACKTITLE", "ZALTTEXT", "ZDISPLAYTEXT", "ZUSERTITLE"),
                          url: row.string("ZURLSTRING", "ZREMOTEFILEURLSTRING"),
                          synapseDataBytes: row.int("ZSYNAPSEDATABYTES").map(Int.init),
                          linkPreviewMetadataBytes: row.int("ZLINKPRESENTATIONARCHIVEDMETADATABYTES").map(Int.init),
                          hasMapLocation: location != nil,
                          mapLatitude: location?.double("ZLATITUDE"), mapLongitude: location?.double("ZLONGITUDE"),
                          mapAddress: lower.contains("url") ? row.string("ZSUMMARY") : nil,
                          mapPlaceUpdated: location?.date("ZPLACEUPDATED"),
                          ocrText: recognized, ocrSummaryVersion: row.int("ZOCRSUMMARYVERSION").map(Int.init),
                          handwritingText: handwriting, additionalIndexableText: extra,
                          imageClassification: row.string("ZIMAGECLASSIFICATIONSUMMARY"),
                          imageClassificationSummaryVersion: row.int("ZIMAGECLASSIFICATIONSUMMARYVERSION").map(Int.init),
                          imageSummary: row.string("ZSUMMARY"),
                          pdfText: pdfText, transcriptText: transcript, transcriptWords: words, recording: recording,
                          recordingFragments: recordingFragments,
                          duration: row.double("ZDURATION"), fallbackRasterPath: raster, displayText: display,
                          participantID: lower.contains("mention") ? (participant?.participantID ?? token) : nil,
                          participantName: participantName, participantEmail: participantEmail,
                          participantUserID: lower.contains("mention") ? participant?.userID : nil,
                          targetNoteID: linkTarget?.identifier,
                          targetParagraphID: linkTarget?.paragraphID,
                          targetParagraphName: nil,
                          mathExpression: isCalculation || lower.contains("graph") ? row.string("ZSTANDARDIZEDCONTENT", "ZALTTEXT") : nil,
                          mathResult: isCalculation ? row.string("ZDISPLAYTEXT", "ZFALLBACKTITLE") : nil,
                          graphExpression: lower.contains("graph") ? row.string("ZSTANDARDIZEDCONTENT", "ZALTTEXT") : nil,
                          isDivider: lower.contains("divider") ? true : nil, drawingSVG: drawingSVG,
                          markupDataBytes: row.data("ZMARKUPMODELDATA").map(\.count),
                          hasEmbeddedMarkup: row.int("ZHASMARKUPDATA").map { $0 != 0 },
                          scanFilter: isScanPage ? row.int("ZIMAGEFILTERTYPE").map(Int.init) : nil,
                          scanOrientation: isScanPage ? row.int("ZORIENTATION").map(Int.init) : nil,
                          scanCrop: scanCrop,
                          scanHasMarkup: isScanPage ? (row.data("ZMARKUPMODELDATA")?.isEmpty == false) : nil,
                          scanHasEmbeddedMarkup: isScanPage ? row.int("ZHASMARKUPDATA").map { $0 != 0 } : nil,
                          tableRightToLeft: tableRightToLeft)
    }

    private static func scriptedDefaultLocation() -> DefaultNotesLocation? {
        let source = #"function run(){const n=Application('com.apple.Notes');const a=n.defaultAccount();const f=a.defaultFolder();return JSON.stringify({accountID:String(a.id()),accountName:String(a.name()),folderID:String(f.id()),folderName:String(f.name())});}"#
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: String],
              let accountID = object["accountID"], let accountName = object["accountName"] else { return nil }
        return DefaultNotesLocation(accountID: accountID, accountName: accountName, folderID: object["folderID"],
                                    folderName: object["folderName"])
    }

    private func galleryOrder(_ data: Data?, available: [String]) -> [String] {
        guard let data, let root0 = try? ProtobufMessage(NotesInflate.decompressIfNeeded(data)) else { return [] }
        let root = ((root0.fields[3] ?? []).isEmpty ? (try? root0.message(2)?.message(3)) ?? nil : root0) ?? root0
        guard let entries = try? root.messages(3) else { return [] }
        var pairs: [(Int64, String)] = [], currentID: String?, currentOrder: Int64?
        for entry in entries {
            if let map = try? entry.message(13),
               let items = try? map.messages(3), let item = items.first,
               let value = try? item.message(2),
               let id = value.string(4), available.contains(id) { currentID = id }
            if let order = try? entry.message(9)?.message(1)?.uint(2) { currentOrder = Int64(bitPattern: order) }
            if let id = currentID, let order = currentOrder { pairs.append((order, id)); currentID = nil; currentOrder = nil }
        }
        return pairs.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private typealias SmartRule = SmartFolderQueryRule
    private struct SmartNote {
        var summary: NoteSummary
        var attachments: [Attachment]
        var document: NoteDocument?
    }

    private static func smartRule(_ json: String?) -> SmartRule? {
        guard let json else { return nil }
        return try? SmartFolderQueryGrammar.parse(json)
    }

    private static func ruleLabels(_ rule: SmartRule) -> [String] {
        switch rule {
        case .all(let rules): return rules.flatMap(ruleLabels)
        case .any(let rules): return ["match any"] + rules.flatMap(ruleLabels)
        case .not(let value): return ruleLabels(value).map { "not \($0)" }
        case .flag(let flag, let expected): return ["\(flag.rawValue)=\(expected)"]
        case .tag(let value): return ["tag=\(value)"]
        case .folder(let value): return ["folder=\(value)"]
        case .attachmentSection(let value): return ["attachmentSection=\(value)"]
        case .sharedParticipant(let value): return ["sharedParticipant=\(value)"]
        case .mentionParticipant(let value): return ["mentionParticipant=\(value)"]
        case .relativeDate(let field, let type, let amount, let unit):
            return ["\(field == .created ? "creation" : "modification")DateRelativeRange=\(type):\(amount.map(String.init) ?? ""): \(unit.map(String.init) ?? "")"]
        case .dateRange(let field, let from, let to):
            return ["\(field == .created ? "creation" : "modification")DateRange=\(from.timeIntervalSinceReferenceDate)...\(to.timeIntervalSinceReferenceDate)"]
        }
    }

    private static func matches(_ note: SmartNote, rule: SmartRule, now: Date) -> Bool {
        switch rule {
        case .all(let rules): return rules.allSatisfy { matches(note, rule: $0, now: now) }
        case .any(let rules): return rules.contains { matches(note, rule: $0, now: now) }
        case .not(let value): return !matches(note, rule: value, now: now)
        case .flag(let flag, let expected):
            let actual: Bool
            switch flag {
            case .deleted: actual = note.summary.isDeleted
            case .checklist: actual = note.summary.hasChecklist
            case .checklistInProgress:
                actual = note.summary.hasChecklistInProgress ?? note.document?.runs.contains { $0.paragraph?.kind == .checklist && $0.paragraph?.checked != true } ?? false
            case .checklistCompleted:
                actual = note.document?.runs.contains { $0.paragraph?.kind == .checklist && $0.paragraph?.checked == true } ?? false
            case .attachment: actual = note.summary.attachmentCount > 0
            case .pinned: actual = note.summary.isPinned
            case .systemPaper: actual = note.summary.isSystemPaper == true
            case .passwordProtected: actual = note.summary.isLocked
            case .shared: actual = note.summary.isShared == true
            case .mention: actual = note.attachments.contains { $0.kind == "mention" }
            case .tagged: actual = !note.summary.tags.isEmpty
            case .quickNote:
                actual = note.summary.isSystemPaper == true
            }
            return actual == expected
        case .tag(let tag): return note.summary.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        case .folder(let folder): return note.summary.folderID?.caseInsensitiveCompare(folder) == .orderedSame
        case .sharedParticipant(let id):
            return note.summary.participants?.contains { $0.participantID?.caseInsensitiveCompare(id) == .orderedSame || $0.userID?.caseInsensitiveCompare(id) == .orderedSame } == true
        case .mentionParticipant(let id):
            return note.attachments.contains { $0.participantID?.caseInsensitiveCompare(id) == .orderedSame }
        case .attachmentSection(let section): return note.attachments.contains { attachmentMatchesSection($0, section: section) }
        case .relativeDate(let field, let type, let amount, let unit):
            guard let date = field == .created ? note.summary.created : note.summary.modified else { return false }
            return dateMatchesRelativeRange(date, type: type, amount: amount, unit: unit, now: now)
        case .dateRange(let field, let from, let to):
            guard let date = field == .created ? note.summary.created : note.summary.modified else { return false }
            return date >= from && date <= to
        }
    }

    private static func attachmentMatchesSection(_ attachment: Attachment, section: Int) -> Bool {
        let value = attachment.typeUTI.lowercased()
        switch section {
        case 1: return attachment.kind == "image" || value.contains("video") || value.contains("movie")
        case 2: return attachment.kind == "drawing"
        case 3: return value.contains("map")
        case 4: return attachment.kind == "link"
        case 5: return attachment.kind == "audio"
        case 6: return attachment.kind == "pdf" || value.contains("document") || value.contains("text")
        case 7: return attachment.kind == "scan"
        default: return false
        }
    }

    private static func dateMatchesRelativeRange(_ date: Date, type: Int, amount: Int?, unit: Int?, now: Date) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        switch type {
        case 0: return date >= today && date <= now
        case 1:
            guard let start = calendar.date(byAdding: .day, value: -1, to: today) else { return false }
            return date >= start && date < today
        case 2, 3, 4, 5:
            let component: Calendar.Component = type >= 4 ? .month : .day
            let value = type == 2 ? -7 : type == 3 ? -30 : type == 4 ? -3 : -12
            guard let start = calendar.date(byAdding: component, value: value, to: now) else { return false }
            return date >= start && date <= now
        case 6:
            guard let amount, amount >= 0, let unit else { return false }
            let component: Calendar.Component
            switch unit { case 0: component = .hour; case 1: component = .day; case 2: component = .weekOfYear; case 3: component = .month; case 4: component = .year; default: return false }
            guard let start = calendar.date(byAdding: component, value: -amount, to: now) else { return false }
            return date >= start && date <= now
        default: return false
        }
    }
}
