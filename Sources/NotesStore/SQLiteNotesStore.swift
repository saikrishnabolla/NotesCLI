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
            summaries.append(NoteSummary(id: NoteID(uuid: uuid, coreDataID: coreDataID, shortID: "n\(pk)"), title: row.string("ZTITLE1", "ZTITLE2", "ZTITLE") ?? "", snippet: row.string("ZSNIPPET", "ZWIDGETSNIPPET") ?? "", folderID: folder?.id, folderPath: folder?.path ?? [], accountID: folder?.accountID.isEmpty == false ? folder!.accountID : account(row), created: row.date("ZCREATIONDATE3", "ZCREATIONDATE1", "ZCREATIONDATE"), modified: row.date("ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"), isPinned: row.int("ZISPINNED") == 1, isLocked: row.int("ZISPASSWORDPROTECTED") == 1, isDeleted: deleted, hasChecklist: row.int("ZHASCHECKLIST") == 1, attachmentCount: attachments.filter { !(($0.string("ZTYPEUTI1", "ZTYPEUTI") ?? "").contains("inlinetextattachment")) }.count, tags: tags, hasChecklistInProgress: flag("ZHASCHECKLISTINPROGRESS"), lastOpened: row.date("ZLASTOPENEDDATE"), displayOrder: row.double("ZSORTORDER", "ZCUSTOMNOTESORTTYPEVALUE"), isShared: shared, participants: participantList, syncState: sync, isSystemPaper: flag("ZISSYSTEMPAPER")))
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
    public func summary(_ ref: String) throws -> NoteSummary { try resolve(ref) }
    public func note(_ ref: String) throws -> Note {
        let summary = try resolve(ref)
        // Do not read or decode encrypted payloads, including attachments.
        if summary.isLocked { return Note(summary: summary, document: nil, attachments: []) }
        guard let pk = notePKs[summary.id.uuid.lowercased()], let data = library.bodies[pk], !data.isEmpty else {
            throw NotesError("body_unavailable", "The note body is not downloaded in this snapshot.", hint: "run notescli fetch")
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
        let deep = try self.attachments(summary.id.uuid)
        let deepIDs = Set(deep.map(\.id))
        attachments = deep + attachments.filter { !deepIDs.contains($0.id) }
        return Note(summary: summary, document: document, attachments: attachments)
    }

    private func resolve(_ ref: String) throws -> NoteSummary {
        let visible = summaries.filter { !placeholderIDs.contains($0.id.uuid.lowercased()) }
        let shortRef = ref.allSatisfy(\.isNumber) ? "n\(ref)" : ref
        let byID = visible.filter {
            $0.id.uuid.caseInsensitiveCompare(ref) == .orderedSame ||
            $0.id.coreDataID?.caseInsensitiveCompare(ref) == .orderedSame ||
            $0.id.shortID?.caseInsensitiveCompare(shortRef) == .orderedSame
        }
        let matches = byID.isEmpty ? visible.filter { $0.title == ref && !$0.isDeleted } : byID
        guard !matches.isEmpty else { throw NotesError("note_not_found", "No note matches the reference.") }
        guard matches.count == 1 else { throw NotesError("ambiguous_note", "More than one note has this title. Use a UUID.") }
        return matches[0]
    }
    public func tags() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for note in summaries where !note.isDeleted && !placeholderIDs.contains(note.id.uuid.lowercased()) { for tag in note.tags { counts[tag, default: 0] += 1 } }
        return counts
    }

    public func attachments(_ ref: String) throws -> [Attachment] {
        let summary = try resolve(ref)
        guard !summary.isLocked, let pk = notePKs[summary.id.uuid.lowercased()] else { return [] }
        var rows = attachmentRows[pk] ?? []
        let parentPKs = Set(rows.compactMap { $0.int("Z_PK") })
        rows += library.objects.values.filter { row in
            guard let parent = row.int("ZPARENTATTACHMENT", "ZPARENTATTACHMENT1") else { return false }
            return parentPKs.contains(parent)
        }
        var built: [Int64: Attachment] = [:]
        for row in rows {
            guard let rowPK = row.int("Z_PK") else { continue }
            built[rowPK] = makeAttachment(row, accountID: summary.accountID)
        }
        for parentPK in parentPKs {
            let childRows = rows.filter { $0.int("ZPARENTATTACHMENT", "ZPARENTATTACHMENT1") == parentPK }
            guard var parent = built[parentPK], !childRows.isEmpty else { continue }
            let childIDs = childRows.compactMap { $0.string("ZIDENTIFIER") }
            let ordered = galleryOrder(noteRows[parentPK]?.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA") ?? library.objects[parentPK]?.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA"), available: childIDs)
            let byID = Dictionary(uniqueKeysWithValues: childRows.compactMap { row -> (String, StoreRow)? in row.string("ZIDENTIFIER").map { ($0, row) } })
            let orderedRows = ordered.compactMap { byID[$0] } + childRows.filter { row in
                guard let id = row.string("ZIDENTIFIER") else { return true }; return !ordered.contains(id)
            }.sorted { ($0.double("ZSORTORDER", "ZCREATIONDATE") ?? 0) < ($1.double("ZSORTORDER", "ZCREATIONDATE") ?? 0) }
            let childAttachments = orderedRows.compactMap { $0.int("Z_PK").flatMap { built[$0] } }
            parent.childAttachmentIDs = childAttachments.map(\.id)
            parent.pageImagePaths = childAttachments.compactMap(\.filePath)
            if parent.filePath == nil, let original = childAttachments.first(where: { $0.kind == "audio" || $0.filename != nil }) {
                parent.filePath = original.filePath; parent.filename = parent.filename ?? original.filename
            }
            built[parentPK] = parent
        }
        return parentPKs.compactMap { built[$0] }.sorted { $0.id < $1.id }
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
            guard uti.contains("link"), row.string("ZTOKENCONTENTIDENTIFIER")?.caseInsensitiveCompare(target) == .orderedSame else { return nil }
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
            let unsupported = rule.map(Self.unsupportedRules) ?? ["invalid query"]
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
            let pdf = root.appendingPathComponent("FallbackPDFs").appendingPathComponent(id)
            if let generation = row.string("ZFALLBACKPDFGENERATION") { candidates.append(pdf.appendingPathComponent(generation).appendingPathComponent("FallbackPDF.pdf")) }
            candidates += [root.appendingPathComponent("FallbackPDFs/\(id).pdf"), pdf.appendingPathComponent("FallbackPDF.pdf")]
        }
        let boundary = container.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = candidates.first { url in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            var isDirectory: ObjCBool = false
            return resolved.hasPrefix(boundary) && FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) && !isDirectory.boolValue
        }?.path
        let uti = row.string("ZTYPEUTI1", "ZTYPEUTI") ?? "public.data"
        let recognized = row.string("ZOCRSUMMARY"), handwriting = row.string("ZHANDWRITINGSUMMARY"), extra = row.string("ZADDITIONALINDEXABLETEXT")
        let raster = uti.lowercased().contains("drawing") || uti.lowercased().contains("paper") ? path : nil
        let pdfText: String? = uti.lowercased().contains("pdf") ? path.flatMap { PDFDocument(url: URL(fileURLWithPath: $0))?.string } : nil
        var words: [TranscriptWord]?, recording: RecordingMetadata?, transcript: String?
        if let blob = row.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA"), let decoded = try? NotesRecordingDecoder.decode(blob), !decoded.words.isEmpty || decoded.metadata.summary != nil || decoded.metadata.topLineSummary != nil {
            words = decoded.words; recording = decoded.metadata; transcript = NotesRecordingDecoder.joined(decoded.words)
        }
        let lower = uti.lowercased(), token = row.string("ZTOKENCONTENTIDENTIFIER")
        let notePK = row.int("ZNOTE1", "ZNOTE")
        let participant = notePK.flatMap { library.participants[$0] }?.first {
            $0.participantID?.caseInsensitiveCompare(token ?? "") == .orderedSame ||
            $0.userID?.caseInsensitiveCompare(token ?? "") == .orderedSame
        }
        let isCalculation = lower.contains("math") || lower.contains("calculate")
        let display = row.string("ZALTTEXT", "ZDISPLAYTEXT", "ZSTANDARDIZEDCONTENT", "ZFALLBACKTITLE")
        let participantName = lower.contains("mention") ? (display ?? row.string("ZUSERTITLE") ?? participant?.displayName) : nil
        let participantEmail = participant?.email ?? (participantName?.contains("@") == true ? participantName : nil)
        let drawingSVG = lower.contains("drawing") ? row.data("ZMERGEABLEDATA1", "ZMERGEABLEDATA").flatMap { ClassicDrawingSVG.decode($0) ?? NotesDrawingDecoder.svg($0) } : nil
        return Attachment(id: id, typeUTI: uti, filename: filename, filePath: path,
                          title: row.string("ZTITLE", "ZFALLBACKTITLE", "ZALTTEXT", "ZDISPLAYTEXT"),
                          url: row.string("ZURLSTRING", "ZREMOTEFILEURLSTRING"), ocrText: recognized,
                          handwritingText: handwriting, additionalIndexableText: extra,
                          imageClassification: row.string("ZIMAGECLASSIFICATIONSUMMARY"), imageSummary: row.string("ZSUMMARY"),
                          pdfText: pdfText, transcriptText: transcript, transcriptWords: words, recording: recording,
                          duration: row.double("ZDURATION"), fallbackRasterPath: raster, displayText: display,
                          participantID: lower.contains("mention") ? (participant?.participantID ?? token) : nil,
                          participantName: participantName, participantEmail: participantEmail,
                          participantUserID: lower.contains("mention") ? participant?.userID : nil,
                          targetNoteID: lower.contains("link") ? token : nil,
                          mathExpression: isCalculation || lower.contains("graph") ? row.string("ZSTANDARDIZEDCONTENT", "ZALTTEXT") : nil,
                          mathResult: isCalculation ? row.string("ZDISPLAYTEXT", "ZFALLBACKTITLE") : nil,
                          graphExpression: lower.contains("graph") ? row.string("ZSTANDARDIZEDCONTENT", "ZALTTEXT") : nil,
                          isDivider: lower.contains("divider") ? true : nil, drawingSVG: drawingSVG)
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
        var pairs: [(Int, String)] = [], currentID: String?, currentOrder: Int?
        for entry in entries {
            if let map = try? entry.message(13),
               let items = try? map.messages(3), let item = items.first,
               let value = try? item.message(2),
               let id = value.string(4), available.contains(id) { currentID = id }
            if let order = try? entry.message(9)?.message(1)?.int(2) { currentOrder = order }
            if let id = currentID, let order = currentOrder { pairs.append((order, id)); currentID = nil; currentOrder = nil }
        }
        return pairs.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private enum SmartFlag: String {
        case deleted, checklist, checklistInProgress, checklistCompleted, attachment, pinned, systemPaper
        case passwordProtected, shared, mention, tagged
    }
    private enum SmartDateField { case created, modified }
    private indirect enum SmartRule {
        case all([SmartRule]), any([SmartRule]), not(SmartRule)
        case flag(SmartFlag, Bool), tag(String), folder(String), attachmentSection(Int)
        case sharedParticipant(String), mentionParticipant(String)
        case relativeDate(SmartDateField, type: Int, amount: Int?, unit: Int?)
        case dateRange(SmartDateField, from: Date, to: Date)
        case unsupported(String)
    }
    private struct SmartNote {
        var summary: NoteSummary
        var attachments: [Attachment]
        var document: NoteDocument?
    }

    private static func smartRule(_ json: String?) -> SmartRule? {
        guard let json, let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return smartRuleValue(object)
    }

    private static func smartRuleValue(_ value: Any) -> SmartRule {
        guard let dictionary = value as? [String: Any] else { return .unsupported("non-object clause") }
        if let type = dictionary["type"] { return smartRuleValue(type) }
        if dictionary.count != 1 { return .all(dictionary.keys.sorted().map { smartRuleValue([$0: dictionary[$0]!]) }) }
        let key = dictionary.keys.first!, value = dictionary[key]!
        if key == "and" || key == "or" {
            guard let values = value as? [Any] else { return .unsupported(key) }
            let rules = values.map(smartRuleValue)
            return key == "and" ? .all(rules) : .any(rules)
        }
        if key == "not" { return .not(smartRuleValue(value)) }
        if let flag = SmartFlag(rawValue: key) {
            guard let expected = value as? Bool else { return .unsupported(key) }
            return .flag(flag, expected)
        }
        if key == "tag", let tag = value as? String { return .tag(tag) }
        if key == "folder", let folder = value as? String { return .folder(folder) }
        if key == "sharedParticipant", let id = value as? String { return .sharedParticipant(id) }
        if key == "mentionParticipant", let id = value as? String { return .mentionParticipant(id) }
        if key == "attachmentSection", let section = (value as? NSNumber)?.intValue { return .attachmentSection(section) }
        if key == "creationDateRelativeRange" || key == "modificationDateRelativeRange",
           let values = value as? [String: Any], let type = (values["type"] as? NSNumber)?.intValue {
            let field: SmartDateField = key.hasPrefix("creation") ? .created : .modified
            return .relativeDate(field, type: type, amount: (values["customAmount"] as? NSNumber)?.intValue,
                                 unit: (values["customUnit"] as? NSNumber)?.intValue)
        }
        if key == "creationDateRange" || key == "modificationDateRange",
           let values = value as? [String: Any], let from = (values["fromDate"] as? NSNumber)?.doubleValue,
           let to = (values["toDate"] as? NSNumber)?.doubleValue {
            let field: SmartDateField = key.hasPrefix("creation") ? .created : .modified
            return .dateRange(field, from: Date(timeIntervalSinceReferenceDate: from), to: Date(timeIntervalSinceReferenceDate: to))
        }
        return .unsupported(key)
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
        case .unsupported(let key): return ["unsupported=\(key)"]
        }
    }

    private static func unsupportedRules(_ rule: SmartRule) -> [String] {
        switch rule {
        case .all(let rules), .any(let rules): return Array(Set(rules.flatMap(unsupportedRules))).sorted()
        case .not(let value): return unsupportedRules(value)
        case .unsupported(let key): return [key]
        default: return []
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
        case .unsupported: return false
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
