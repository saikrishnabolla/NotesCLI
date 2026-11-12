import Foundation
import NotesCore

public enum NotesReadFidelity: String, Codable, Sendable {
    case full
    case limited
}

/// A read-only fallback through Notes.app's scripting dictionary.
/// It intentionally exposes less data than NoteStore.sqlite and reports those gaps.
public final class ScriptingNotesReader: NotesReading, @unchecked Sendable {
    public let fidelity = NotesReadFidelity.limited
    public let unavailableFields = [
        "stable_note_id", "note_number", "pins", "tags", "checklists", "attachments",
        "formatting", "smart_folders", "backlinks", "deleted_notes", "sharing", "sync_state",
    ]

    private let runner: any ScriptRunning
    private let timeout: TimeInterval
    private let permissionCheck: @Sendable () throws -> Void
    private let lock = NSLock()
    private var cachedSnapshot: ScriptingSnapshot?

    public init(timeout: TimeInterval = 30) {
        runner = OSAScriptRunner()
        self.timeout = timeout
        permissionCheck = { try NotesAutomationPermission.check() }
    }

    init(runner: any ScriptRunning, timeout: TimeInterval = 30,
         permissionCheck: @escaping @Sendable () throws -> Void) {
        self.runner = runner
        self.timeout = timeout
        self.permissionCheck = permissionCheck
    }

    public func accounts() throws -> [Account] {
        let value = try snapshot()
        return value.accounts.map { account in
            Account(id: account.id, name: account.name, kind: "unknown", isDefault: account.isDefault,
                    defaultFolderID: account.defaultFolderID,
                    defaultFolderName: value.folders.first { folder in
                        folder.id == account.defaultFolderID && folder.accountID == account.id
                    }?.name)
        }
    }

    public func folders(account: String?) throws -> [Folder] {
        let value = try snapshot()
        let accountIDs = try matchingAccountIDs(account, in: value)
        let counts = Dictionary(grouping: value.notes, by: \.folderID).mapValues(\.count)
        return value.folders.filter { accountIDs == nil || accountIDs!.contains($0.accountID) }.map {
            Folder(id: $0.id, name: $0.name, accountID: $0.accountID, parentID: $0.parentID,
                   path: $0.path, isSmartFolder: false, isRecentlyDeleted: $0.isRecentlyDeleted,
                   noteCount: counts[$0.id, default: 0], coreDataID: $0.id)
        }
    }

    public func notes(_ query: NoteQuery) throws -> [NoteSummary] {
        try validate(query)
        let value = try snapshot()
        let accountIDs = try matchingAccountIDs(query.account, in: value)
        let folderIDs = try matchingFolderIDs(query.folder, accountIDs: accountIDs, in: value)
        let foldedText = query.text?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var notes = value.notes.filter { item in
            if !query.includeDeleted, value.folders.first(where: { $0.id == item.folderID })?.isRecentlyDeleted == true { return false }
            if let accountIDs, !accountIDs.contains(item.accountID) { return false }
            if let folderIDs, !folderIDs.contains(item.folderID) { return false }
            if let after = query.modifiedAfter, (item.modified ?? .distantPast) < after { return false }
            if let before = query.modifiedBefore, (item.modified ?? .distantFuture) > before { return false }
            if let foldedText {
                let haystack = (item.title + "\n" + limitedPlainText(item.bodyHTML ?? ""))
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if !haystack.contains(foldedText) { return false }
            }
            return true
        }.map(summary)
        notes.sort { ($0.modified ?? .distantPast, $0.id.uuid) > ($1.modified ?? .distantPast, $1.id.uuid) }
        if let limit = query.limit { notes = Array(notes.prefix(limit)) }
        return notes
    }

    public func note(_ ref: String) throws -> Note {
        let value = try snapshot()
        let item = try NoteReference.resolve(ref, identifiers: { candidate in
            value.notes.filter { $0.id.caseInsensitiveCompare(candidate) == .orderedSame }
        }, number: { _ in [] }, title: { title in
            value.notes.filter { $0.title == title }
        }, key: \.id, describe: { NoteReference.describe(number: nil, uuid: $0.id, title: $0.title) })
        guard !item.isLocked, let html = item.bodyHTML else {
            throw NotesError("note_locked", "The note body is unavailable.")
        }
        return Note(summary: summary(item), document: NoteDocument(text: limitedPlainText(html), runs: []), attachments: [])
    }

    public func tags() throws -> [String: Int] { throw unsupported("tags") }
    public func attachments(_ ref: String) throws -> [Attachment] { throw unsupported("attachments") }
    public func rawNote(_ ref: String) throws -> RawProtobufMessage { throw unsupported("raw note data") }
    public func backlinks(_ ref: String) throws -> [NoteSummary] { throw unsupported("backlinks") }
    public func smartFolders(evaluate: Bool) throws -> [SmartFolderResult] { throw unsupported("smart folders") }
    public func attachmentKindCounts() throws -> [String: Int] { throw unsupported("attachment kinds") }

    private func validate(_ query: NoteQuery) throws {
        if query.pinnedOnly { throw unsupported("pinned-note filtering") }
        if query.tag != nil { throw unsupported("tag filtering") }
        if !query.attachmentKinds.isEmpty { throw unsupported("attachment filtering") }
        if query.includeDeleted { throw unsupported("deleted notes") }
    }

    private func unsupported(_ feature: String) -> NotesError {
        NotesError("limited_read_unsupported", "\(feature.capitalized) is unavailable through the limited Notes Automation reader.",
                   hint: "Grant Full Disk Access for full-fidelity reads.")
    }

    private func summary(_ item: ScriptingSnapshot.NoteValue) -> NoteSummary {
        let body = limitedPlainText(item.bodyHTML ?? "")
        let snippet = body.split(separator: "\n").dropFirst().joined(separator: " ")
        return NoteSummary(id: NoteID(uuid: item.id, coreDataID: item.id), title: item.title,
                           snippet: String(snippet.prefix(240)), folderID: item.folderID,
                           folderPath: item.folderPath, accountID: item.accountID,
                           created: item.created, modified: item.modified, isPinned: false,
                           isLocked: item.isLocked, isDeleted: false, hasChecklist: false,
                           attachmentCount: 0, tags: [], deepLink: nil)
    }

    private func matchingAccountIDs(_ ref: String?, in value: ScriptingSnapshot) throws -> Set<String>? {
        guard let ref else { return nil }
        let matches = value.accounts.filter {
            $0.id.caseInsensitiveCompare(ref) == .orderedSame || $0.name.compare(ref, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard !matches.isEmpty else { throw NotesError("account_not_found", "No account matches the reference.") }
        guard matches.count == 1 else { throw NotesError("ambiguous_account", "More than one account matches the reference.") }
        return [matches[0].id]
    }

    private func matchingFolderIDs(_ ref: String?, accountIDs: Set<String>?, in value: ScriptingSnapshot) throws -> Set<String>? {
        guard let ref else { return nil }
        let path = ref.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        let matches = value.folders.filter { folder in
            guard accountIDs == nil || accountIDs!.contains(folder.accountID) else { return false }
            return folder.id.caseInsensitiveCompare(ref) == .orderedSame || folder.path == path ||
                (path.count == 1 && folder.name.compare(ref, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame)
        }
        guard !matches.isEmpty else { throw NotesError("folder_not_found", "No folder matches the reference.") }
        if path.count == 1, matches.count > 1 { throw NotesError("ambiguous_folder", "More than one folder matches the reference.") }
        return Set(matches.map(\.id))
    }

    private func snapshot() throws -> ScriptingSnapshot {
        try lock.withLock {
            if let cachedSnapshot { return cachedSnapshot }
            let value = try loadSnapshot()
            cachedSnapshot = value
            return value
        }
    }

    private func loadSnapshot() throws -> ScriptingSnapshot {
        try permissionCheck()
        var output = try runner.run(source: Self.source, language: .javaScript, arguments: [], timeout: timeout)
        if Self.errorNumber(output) == -600 {
            _ = try runner.run(source: NotesScripts.launch, language: .javaScript, arguments: [], timeout: min(timeout, 10))
            output = try runner.run(source: Self.source, language: .javaScript, arguments: [], timeout: timeout)
        }
        if output.timedOut { throw NotesError("automation_timeout", "Notes Automation timed out.") }
        if output.status != 0 { throw Self.scriptError(output) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response: ScriptingSnapshot
        do { response = try decoder.decode(ScriptingSnapshot.self, from: Data(output.stdout.utf8)) }
        catch { throw Self.scriptError(output) }
        if let number = response.errorNumber { throw Self.scriptError(number: number, code: response.errorCode) }
        guard response.accounts != nil, response.folders != nil, response.notes != nil else {
            throw NotesError("invalid_script_response", "Notes returned an incomplete limited-read response.")
        }
        return response
    }

    private static func errorNumber(_ output: ScriptOutput) -> Int? {
        (try? JSONDecoder().decode(ScriptingSnapshot.self, from: Data(output.stdout.utf8)))?.errorNumber
    }

    private static func scriptError(_ output: ScriptOutput) -> NotesError {
        if let number = errorNumber(output) { return scriptError(number: number, code: nil) }
        if output.stderr.contains("-1743") { return scriptError(number: -1743, code: nil) }
        return NotesError("automation_failed", "Notes Automation could not complete the limited read.")
    }

    private static func scriptError(number: Int, code: String?) -> NotesError {
        if number == -1743 || number == -1744 {
            return NotesError("automation_denied", "Notes Automation is not authorized.",
                              hint: "System Settings > Privacy & Security > Automation")
        }
        if number == -600 { return NotesError("app_not_running", "Notes.app is not running.") }
        if code == "note_not_found" || number == -1728 { return NotesError("note_not_found", "The note was not found.") }
        return NotesError(code ?? "automation_failed", "Notes Automation could not complete the limited read.")
    }

    private static let source = #"""
    function run() {
      const app = Application('com.apple.Notes');
      const result = {accounts: [], folders: [], notes: []};
      function id(value) { return String(value.id()); }
      function same(a, b) { return String(a).normalize('NFC') === String(b).normalize('NFC'); }
      function children(parent) {
        const parentID = id(parent);
        return parent.folders().filter(folder => {
          try { return id(folder.container()) === parentID; }
          catch (error) { if ((error.errorNumber || error.number) === -1728) return false; throw error; }
        });
      }
      function descendants(parent, seen) {
        seen = seen || {};
        let found = [];
        children(parent).forEach(folder => {
          const key = id(folder);
          if (!seen[key]) { seen[key] = true; found.push(folder); found = found.concat(descendants(folder, seen)); }
        });
        return found;
      }
      function path(folder) {
        const parts = [], seen = {};
        let value = folder;
        while (value && !seen[id(value)]) {
          seen[id(value)] = true;
          if (app.accounts().some(account => id(account) === id(value))) break;
          parts.unshift(String(value.name())); value = value.container();
        }
        return parts;
      }
      function iso(value) { try { return value ? new Date(value).toISOString() : null; } catch (_) { return null; } }
      try {
        const defaultID = id(app.defaultAccount());
        app.accounts().forEach(account => {
          const accountID = id(account);
          let defaultFolderID = null;
          try { defaultFolderID = id(account.defaultFolder()); } catch (_) {}
          result.accounts.push({id: accountID, name: String(account.name()), isDefault: accountID === defaultID, defaultFolderID: defaultFolderID});
          descendants(account).forEach(folder => {
            const folderID = id(folder), folderPath = path(folder);
            const parent = folder.container();
            const parentID = app.accounts().some(candidate => id(candidate) === id(parent)) ? null : id(parent);
            const recentlyDeleted = ['Recently Deleted', 'Trash'].some(name => same(name, folder.name()));
            result.folders.push({id: folderID, name: String(folder.name()), accountID: accountID, parentID: parentID, path: folderPath, isRecentlyDeleted: recentlyDeleted});
            folder.notes().forEach(note => {
              try {
                if (id(note.container()) !== folderID) return;
                const locked = Boolean(note.passwordProtected());
                result.notes.push({id: id(note), title: String(note.name()), bodyHTML: locked ? null : String(note.body()), folderID: folderID,
                  folderPath: folderPath, accountID: accountID, created: iso(note.creationDate()), modified: iso(note.modificationDate()), isLocked: locked});
              } catch (error) { if ((error.errorNumber || error.number) !== -1728) throw error; }
            });
          });
        });
        return JSON.stringify(result);
      } catch (error) {
        return JSON.stringify({errorCode: error.code || null, errorNumber: error.errorNumber || error.number || null});
      }
    }
    """#
}

private struct ScriptingSnapshot: Decodable {
    struct AccountValue: Decodable {
        var id: String
        var name: String
        var isDefault: Bool
        var defaultFolderID: String?
    }
    struct FolderValue: Decodable {
        var id: String
        var name: String
        var accountID: String
        var parentID: String?
        var path: [String]
        var isRecentlyDeleted: Bool
    }
    struct NoteValue: Decodable {
        var id: String
        var title: String
        var bodyHTML: String?
        var folderID: String
        var folderPath: [String]
        var accountID: String
        var created: Date?
        var modified: Date?
        var isLocked: Bool
    }
    var accounts: [AccountValue]!
    var folders: [FolderValue]!
    var notes: [NoteValue]!
    var errorCode: String?
    var errorNumber: Int?
}

private func limitedPlainText(_ html: String) -> String {
    var value = html
    for pattern in ["(?i)<br\\s*/?>", "(?i)</(?:div|p|li|h[1-6])\\s*>"] {
        value = value.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
    }
    value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (entity, replacement) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
        value = value.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
    }
    return value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }.joined(separator: "\n")
}
