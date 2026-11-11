import Foundation

public final class InMemoryNotes: NotesReading, NotesWriting, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var accountStore: [Account]
    private var folderStore: [Folder]
    private var noteStore: [Note]
    private var sequence = 0

    public init(accounts: [Account] = [], folders: [Folder] = [], notes: [Note] = []) {
        accountStore = accounts; folderStore = folders; noteStore = notes
    }

    public static func sample() -> InMemoryNotes {
        let account = Account(id: "fake-account", name: "Demo", kind: "local")
        let folder = Folder(id: "fake-folder", name: "Notes", accountID: account.id, parentID: nil,
                            path: ["Notes"], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 2)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let notes = [("welcome", "Welcome", "Welcome to notectl. Browse your shopping notes. #demo"),
                     ("shopping", "Shopping", "Apples, coffee, and bread. #shopping")].map { id, title, body in
            Note(summary: NoteSummary(id: NoteID(uuid: id), title: title, snippet: body,
                 folderID: folder.id, folderPath: folder.path, accountID: account.id,
                 created: date, modified: date, isPinned: id == "welcome", isLocked: false,
                 isDeleted: false, hasChecklist: false, attachmentCount: 0,
                 tags: [id == "welcome" ? "demo" : "shopping"]),
                 document: NoteDocument(text: body, runs: []), attachments: [])
        }
        return InMemoryNotes(accounts: [account], folders: [folder], notes: notes)
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    private func account(_ ref: String?) throws -> Account {
        let matches = accountStore.filter { ref == nil || $0.id == ref || $0.name == ref }
        if ref == nil, let first = matches.first { return first }
        guard matches.count == 1 else { throw NotesError(matches.isEmpty ? "account_not_found" : "ambiguous_account", "Account must resolve uniquely.") }
        return matches[0]
    }
    private func folder(_ ref: String) throws -> Folder {
        let matches = folderStore.filter { $0.id == ref || $0.name == ref || $0.path.joined(separator: " > ") == ref }
        guard matches.count == 1 else { throw NotesError(matches.isEmpty ? "folder_not_found" : "ambiguous_folder", "Folder must resolve uniquely.") }
        return matches[0]
    }
    private func index(_ ref: String) throws -> Int {
        if let i = noteStore.firstIndex(where: { $0.summary.id.uuid == ref || $0.summary.id.coreDataID == ref }) { return i }
        let matches = noteStore.indices.filter { noteStore[$0].summary.title == ref }
        guard matches.count == 1 else { throw NotesError(matches.isEmpty ? "note_not_found" : "ambiguous_note", "Note must resolve uniquely.") }
        return matches[0]
    }
    public func accounts() throws -> [Account] { synchronized { accountStore } }
    public func folders(account ref: String?) throws -> [Folder] {
        try synchronized {
            let id = try ref.map { try account($0).id }
            return folderStore.filter { id == nil || $0.accountID == id }.map { f in
                var f = f; f.noteCount = noteStore.filter { $0.summary.folderID == f.id }.count; return f
            }.sorted { $0.path.joined(separator: "/") < $1.path.joined(separator: "/") }
        }
    }
    public func notes(_ query: NoteQuery) throws -> [NoteSummary] {
        try synchronized {
            let folderID = try query.folder.map { try folder($0).id }
            let accountID = try query.account.map { try account($0).id }
            let results = noteStore.filter { n in
                let s = n.summary
                return (query.includeDeleted || !s.isDeleted) && (!query.pinnedOnly || s.isPinned)
                    && (folderID == nil || s.folderID == folderID) && (accountID == nil || s.accountID == accountID)
                    && (query.tag == nil || s.tags.contains(query.tag!.trimmingCharacters(in: CharacterSet(charactersIn: "#"))))
                    && (query.modifiedAfter == nil || (s.modified ?? .distantPast) >= query.modifiedAfter!)
                    && (query.modifiedBefore == nil || (s.modified ?? .distantFuture) <= query.modifiedBefore!)
                    && (query.text == nil || (s.title + " " + s.snippet + " " + (n.document?.text ?? "")).localizedCaseInsensitiveContains(query.text!))
            }.map(\.summary).sorted {
                if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                return $0.id.uuid < $1.id.uuid
            }
            return Array(results.prefix(max(0, query.limit ?? results.count)))
        }
    }
    public func note(_ ref: String) throws -> Note { try synchronized { noteStore[try index(ref)] } }
    public func tags() throws -> [String: Int] {
        synchronized { var tags: [String: Int] = [:]; for n in noteStore where !n.summary.isDeleted {
            for tag in Set(n.summary.tags) { tags[tag, default: 0] += 1 }
        }; return tags }
    }
    private func nextID() -> String { sequence += 1; return "fake-\(sequence)-\(UUID().uuidString)" }
    private func update(_ ref: String, _ change: (inout Note) throws -> Void) throws -> WriteResult {
        try synchronized {
            let i = try index(ref)
            guard !noteStore[i].summary.isLocked else { throw NotesError("note_locked", "The note is locked.") }
            try change(&noteStore[i]); noteStore[i].summary.modified = Date()
            return WriteResult(outcome: .verified, noteID: noteStore[i].summary.id)
        }
    }
    private func setBody(_ note: inout Note, _ markdown: String) {
        note.document = NoteDocument(text: markdown, runs: [])
        note.summary.snippet = String(markdown.prefix(160))
        note.summary.tags = Array(Set(markdown.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("#") && !$0.hasPrefix("##") && $0.count > 1 }.map { String($0.dropFirst()) })).sorted()
    }
    public func createNote(title: String, markdown: String, folder ref: String?) throws -> WriteResult {
        try synchronized {
            let f: Folder
            if let ref { f = try folder(ref) }
            else if let first = folderStore.first(where: { !$0.isRecentlyDeleted && !$0.isSmartFolder }) { f = first }
            else { throw NotesError("folder_not_found", "Create a folder first.") }
            guard !f.isRecentlyDeleted && !f.isSmartFolder else { throw NotesError("invalid_folder", "Cannot create a note in this folder.") }
            let id = NoteID(uuid: nextID()); let now = Date()
            var n = Note(summary: NoteSummary(id: id, title: title, snippet: "", folderID: f.id,
                folderPath: f.path, accountID: f.accountID, created: now, modified: now, isPinned: false,
                isLocked: false, isDeleted: false, hasChecklist: false, attachmentCount: 0, tags: []), document: nil, attachments: [])
            setBody(&n, markdown); noteStore.append(n); return WriteResult(outcome: .verified, noteID: id)
        }
    }
    public func appendToNote(_ ref: String, markdown: String) throws -> WriteResult {
        try update(ref) { n in setBody(&n, (n.document?.text ?? "") + "\n" + markdown) }
    }
    public func replaceBody(_ ref: String, markdown: String) throws -> WriteResult {
        try update(ref) { n in setBody(&n, markdown); n.attachments = []; n.summary.attachmentCount = 0; n.summary.hasChecklist = false }
    }
    public func renameNote(_ ref: String, title: String) throws -> WriteResult { try update(ref) { $0.summary.title = title } }
    public func moveNote(_ ref: String, toFolder: String) throws -> WriteResult {
        try synchronized {
            let f = try folder(toFolder)
            guard !f.isSmartFolder else { throw NotesError("invalid_folder", "Cannot move into a smart folder.") }
            return try update(ref) { $0.summary.folderID = f.id; $0.summary.folderPath = f.path; $0.summary.accountID = f.accountID; $0.summary.isDeleted = f.isRecentlyDeleted }
        }
    }
    public func deleteNote(_ ref: String) throws -> WriteResult {
        try synchronized {
            let accountID = noteStore[try index(ref)].summary.accountID
            let trash: Folder
            if let f = folderStore.first(where: { $0.accountID == accountID && $0.isRecentlyDeleted }) { trash = f }
            else {
                trash = Folder(id: nextID(), name: "Recently Deleted", accountID: accountID, parentID: nil,
                               path: ["Recently Deleted"], isSmartFolder: false, isRecentlyDeleted: true, noteCount: 0)
                folderStore.append(trash)
            }
            return try moveNote(ref, toFolder: trash.id)
        }
    }
    public func createFolder(name: String, parent: String?, account ref: String?) throws -> WriteResult {
        try synchronized {
            let p = try parent.map { try folder($0) }
            let a = try account(ref ?? p?.accountID)
            guard p == nil || p?.accountID == a.id else { throw NotesError("invalid_parent", "Parent belongs to another account.") }
            guard !name.isEmpty else { throw NotesError("invalid_name", "Folder name is empty.") }
            guard !folderStore.contains(where: { $0.accountID == a.id && $0.parentID == p?.id && $0.name == name }) else { throw NotesError("folder_exists", "Folder already exists.") }
            let f = Folder(id: nextID(), name: name, accountID: a.id, parentID: p?.id, path: (p?.path ?? []) + [name], isSmartFolder: false, isRecentlyDeleted: false, noteCount: 0)
            folderStore.append(f); return WriteResult(outcome: .verified, folderID: f.id)
        }
    }
    public func renameFolder(_ ref: String, name: String) throws -> WriteResult {
        try synchronized {
            let f = try folder(ref)
            guard !name.isEmpty else { throw NotesError("invalid_name", "Folder name is empty.") }
            guard !folderStore.contains(where: { $0.id != f.id && $0.accountID == f.accountID && $0.parentID == f.parentID && $0.name == name }) else { throw NotesError("folder_exists", "Folder already exists.") }
            let newPath = Array(f.path.dropLast()) + [name]
            for i in folderStore.indices where folderStore[i].accountID == f.accountID && folderStore[i].path.starts(with: f.path) {
                folderStore[i].path = newPath + folderStore[i].path.dropFirst(f.path.count)
                if folderStore[i].id == f.id { folderStore[i].name = name }
            }
            for i in noteStore.indices where noteStore[i].summary.accountID == f.accountID && noteStore[i].summary.folderPath.starts(with: f.path) {
                noteStore[i].summary.folderPath = newPath + noteStore[i].summary.folderPath.dropFirst(f.path.count)
            }
            return WriteResult(outcome: .verified, folderID: f.id)
        }
    }
    public func deleteFolder(_ ref: String) throws -> WriteResult {
        try synchronized {
            let f = try folder(ref)
            guard !f.isRecentlyDeleted else { throw NotesError("invalid_folder", "Cannot delete Recently Deleted.") }
            let ids = Set(folderStore.filter { $0.accountID == f.accountID && $0.path.starts(with: f.path) }.map(\.id))
            let notes = noteStore.filter { ids.contains($0.summary.folderID ?? "") }.map { $0.summary.id.uuid }
            guard !noteStore.contains(where: { ids.contains($0.summary.folderID ?? "") && $0.summary.isLocked }) else { throw NotesError("note_locked", "Folder contains locked notes.") }
            for id in notes { _ = try deleteNote(id) }
            folderStore.removeAll { ids.contains($0.id) }
            return WriteResult(outcome: .verified, folderID: f.id)
        }
    }
}
