import Foundation
import NotesCore

public struct ScriptingNote: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var folderID: String
    public var folderPath: [String]
    public var accountID: String
}

/// All mutations use Notes.app. The caller's verifier must read a fresh store snapshot.
/// Instances serialize their own operations, including verification and attachment creation.
/// `noteID.coreDataID` is the scripting identity. `uuid` is empty unless the caller
/// supplied a UUID; scripting cannot discover the stable database UUID.
/// Create and replace prepend the title as h1. Replace removes prior body content.
/// Appending to notes with attachments is refused because HTML round-tripping can lose them.
/// On macOS 27.2, local images are downgraded: both tested AppleScript insertion
/// forms produced duplicate image placements. Other OS versions attempt attachment once.
public final class ScriptingNotesWriter: NotesWriting, Sendable {
    public typealias Resolver = @Sendable (String) throws -> String?
    public typealias Verifier = @Sendable (WriteResult) throws -> WriteOutcome
    private let runner: any ScriptRunning
    private let timeout: TimeInterval
    private let resolver: Resolver?
    private let verifier: Verifier?
    private let attachLocalImages: Bool
    private let permissionCheck: @Sendable () throws -> Void
    private let lock = NSRecursiveLock()

    public init(timeout: TimeInterval = 30, resolver: Resolver? = nil, verifier: Verifier? = nil) {
        self.runner = OSAScriptRunner(); self.timeout = timeout; self.resolver = resolver; self.verifier = verifier
        self.permissionCheck = { try NotesAutomationPermission.check() }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // Both documented AppleScript insertion forms duplicate images on 27.2.
        self.attachLocalImages = !(os.majorVersion == 27 && os.minorVersion == 2)
    }

    // Test injection is internal so production calls cannot accidentally skip consent checks.
    init(runner: any ScriptRunning, timeout: TimeInterval = 30, resolver: Resolver? = nil,
         verifier: Verifier? = nil, attachLocalImages: Bool = true, permissionCheck: @escaping @Sendable () throws -> Void = {}) {
        self.runner = runner; self.timeout = timeout; self.resolver = resolver; self.verifier = verifier
        self.permissionCheck = permissionCheck
        self.attachLocalImages = attachLocalImages
    }

    public func createNote(title: String, markdown: String, folder: String? = nil) throws -> WriteResult {
        try write("createNote", fields: ["title": title, "folder": folder], markdown: markdown)
    }
    public func appendToNote(_ ref: String, markdown: String) throws -> WriteResult {
        try write("appendToNote", fields: ["ref": resolve(ref)], markdown: markdown, uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func replaceBody(_ ref: String, markdown: String) throws -> WriteResult {
        try write("replaceBody", fields: ["ref": resolve(ref)], markdown: markdown, uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func renameNote(_ ref: String, title: String) throws -> WriteResult {
        try write("renameNote", fields: ["ref": resolve(ref), "title": title], uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func moveNote(_ ref: String, toFolder: String) throws -> WriteResult {
        try write("moveNote", fields: ["ref": resolve(ref), "folder": toFolder], uuid: UUID(uuidString: ref)?.uuidString)
    }
    /// On macOS 27.2.1 (26B131), live tests confirmed that `delete` moves the note
    /// to Recently Deleted. Notes still exposes it in app.notes, so each call
    /// checks its current folder and rejects a second delete. Trash is never emptied.
    /// Shared notes and accounts that are not upgraded are rejected.
    public func deleteNote(_ ref: String) throws -> WriteResult {
        try write("deleteNote", fields: ["ref": resolve(ref)], uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func createFolder(name: String, parent: String? = nil, account: String? = nil) throws -> WriteResult {
        try validateFolderName(name)
        return try write("createFolder", fields: ["name": name, "parent": parent, "account": account])
    }
    public func renameFolder(_ ref: String, name: String) throws -> WriteResult {
        try validateFolderName(name)
        return try write("renameFolder", fields: ["ref": ref, "name": name])
    }
    /// Deletes empty, non-system, unshared folders only; refuses recursive deletion.
    public func deleteFolder(_ ref: String) throws -> WriteResult {
        try write("deleteFolder", fields: ["ref": ref])
    }
    public func showInNotes(_ ref: String) throws {
        _ = try execute("show", fields: ["ref": resolve(ref)], isWrite: false)
    }
    public func listViaScripting() throws -> [ScriptingNote] {
        let result = try execute("list", fields: [:], isWrite: false)
        guard let notes = result.notes else { throw NotesError("invalid_script_response", "Notes returned no list.") }
        return notes
    }

    private func resolve(_ ref: String) throws -> String {
        if ref.hasPrefix("x-coredata://") { return ref }
        if let mapped = try resolver?(ref), mapped.hasPrefix("x-coredata://") { return mapped }
        throw NotesError("note_not_found", "The note reference could not be resolved.", hint: "Supply an x-coredata ID or a resolver backed by NotesReading.")
    }
    private func validateFolderName(_ name: String) throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.contains(">") {
            throw NotesError("invalid_folder_name", "Folder names must be nonempty and cannot contain >.")
        }
    }

    private func write(_ operation: String, fields: [String: String?], markdown: String? = nil, uuid: String? = nil) throws -> WriteResult {
        lock.lock(); defer { lock.unlock() }
        let converted = markdown.map(MarkdownToNotesHTML.convert)
        var fields = fields
        fields["html"] = converted?.html
        let reply = try execute(operation, fields: fields, isWrite: true)
        let ref = reply.id ?? (operation.hasSuffix("Note") || operation == "replaceBody" ? fields["ref"] ?? nil : nil)
        var result = WriteResult(outcome: reply.unknownOutcome ? .unknown : .unverified,
                                 noteID: ref.map { NoteID(uuid: uuid ?? "", coreDataID: $0) }, folderID: reply.folderID)
        var downgraded = Set(converted?.downgraded ?? [])
        if reply.unknownOutcome {
            result.message = "Write timed out or lost its response; its outcome is unknown. Do not retry."
            return result
        }
        if reply.changed == true && (reply.errorCode != nil || reply.errorNumber != nil) {
            result.message = "Notes changed, but the script could not complete its response. Do not retry."
            return result
        }
        if let converted, !converted.localImagePaths.isEmpty, !attachLocalImages {
            downgraded.insert("image")
        }
        if attachLocalImages, let ref = reply.id, let converted {
            for path in converted.localImagePaths {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
                      FileManager.default.isReadableFile(atPath: url.path) else {
                    downgraded.insert("image"); continue
                }
                let attachment: ScriptOutput
                do {
                    attachment = try runner.run(source: NotesScripts.attachment, language: .appleScript,
                                                arguments: [ref, url.path], timeout: timeout)
                } catch {
                    downgraded.insert("image")
                    continue
                }
                if attachment.timedOut || [-1712, -609].contains(Self.eventNumber(attachment.stderr) ?? 0) || (attachment.status != 0 && Self.eventNumber(attachment.stderr) == nil) {
                    result.outcome = .unknown
                    result.message = "Body written; attachment outcome is unknown. Do not retry."
                    return result
                }
                if attachment.status != 0 {
                    let number = Self.eventNumber(attachment.stderr)
                    if number == -1743 || number == -1744 {
                        result.message = "automation_denied (\(number!)): Body written; attachment not authorized. Do not retry. System Settings > Privacy & Security > Automation."
                        return result
                    }
                    downgraded.insert("image")
                }
            }
        }
        if !downgraded.isEmpty {
            let encoded = try JSONEncoder().encode(downgraded.sorted())
            result.message = "downgraded: " + String(decoding: encoded, as: UTF8.self)
            if !attachLocalImages, converted?.localImagePaths.isEmpty == false {
                result.message! += " (macOS 27.2 scripting duplicates image placements; files were not attached)"
            }
        }
        if let verifier {
            do { result.outcome = try verifier(result) }
            catch {
                result.outcome = .unverified
                result.message = [result.message, "Write completed; verification failed. Do not retry the write."].compactMap { $0 }.joined(separator: " ")
            }
        }
        return result
    }

    struct Reply: Decodable {
        var id: String?
        var folderID: String?
        var notes: [ScriptingNote]?
        var title: String?
        var body: String?
        var name: String?
        var noteCount: Int?
        var childCount: Int?
        var attachmentCount: Int?
        var errorCode: String?
        var errorNumber: Int?
        var changed: Bool?
        var unknownOutcome = false
        enum CodingKeys: String, CodingKey {
            case id, folderID, notes, title, body, name, noteCount, childCount, attachmentCount, errorCode, errorNumber, changed
        }
    }

    func execute(_ operation: String, fields: [String: String?], isWrite: Bool) throws -> Reply {
        lock.lock(); defer { lock.unlock() }
        try permissionCheck()
        var payload = fields.compactMapValues { $0 }
        payload["operation"] = operation
        guard let protectedNames = ProtectedFolders.names else {
            throw NotesError("trash_protection_unavailable", "Cannot identify localized Recently Deleted folders; no operation was dispatched.")
        }
        payload["protectedFolderNamesJSON"] = String(decoding: try JSONEncoder().encode(protectedNames), as: UTF8.self)
        let argument = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        for attempt in 0...1 {
            let output = try runner.run(source: NotesScripts.operation, language: .javaScript, arguments: [argument], timeout: timeout)
            if output.timedOut {
                if isWrite { var reply = Reply(); reply.unknownOutcome = true; return reply }
                throw NotesError("automation_timeout", "Notes read timed out.")
            }
            let reply: Reply
            if output.status == 0 {
                do { reply = try JSONDecoder().decode(Reply.self, from: Data(output.stdout.utf8)) }
                catch {
                    if isWrite { var unknown = Reply(); unknown.unknownOutcome = true; return unknown }
                    throw NotesError("invalid_script_response", "Notes returned an unreadable response.")
                }
            } else {
                let number = Self.eventNumber(output.stderr)
                if isWrite && number == nil { var unknown = Reply(); unknown.unknownOutcome = true; return unknown }
                reply = Reply(errorCode: "automation_error", errorNumber: number)
            }
            if reply.errorNumber == -1712 || reply.errorNumber == -609 {
                if isWrite { var unknown = reply; unknown.unknownOutcome = true; return unknown }
                throw NotesError("automation_timeout", "Notes read timed out or lost its connection.")
            }
            if reply.errorNumber == -600, !isWrite, attempt == 0 {
                let launched = try runner.run(source: NotesScripts.launch, language: .javaScript, arguments: [], timeout: timeout)
                if launched.timedOut { throw NotesError("automation_timeout", "Launching Notes timed out.") }
                guard launched.status == 0 else { throw Self.mappedError(Self.eventNumber(launched.stderr)) }
                continue
            }
            if reply.changed == true { return reply }
            if let number = reply.errorNumber { throw Self.mappedError(number) }
            if let code = reply.errorCode { throw NotesError(code, Self.errorMessage(code)) }
            return reply
        }
        throw NotesError("automation_error", "Notes read could not complete.")
    }

    static func eventNumber(_ stderr: String) -> Int? {
        guard let range = stderr.range(of: #"\(-\d+\)\s*$"#, options: .regularExpression) else { return nil }
        return Int(stderr[range].trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().dropLast())
    }
    private static func mappedError(_ number: Int?) -> NotesError {
        switch number {
        case -1743, -1744:
            return NotesError("automation_denied", "Notes Automation was not authorized (\(number!)).", hint: "System Settings > Privacy & Security > Automation")
        case -1728: return NotesError("note_not_found", "Notes could not find the requested object (-1728).")
        case -600: return NotesError("app_not_running", "Notes is not running (-600). Writes are never retried.")
        default: return NotesError("automation_error", "Notes scripting failed" + (number.map { " (\($0))." } ?? "."))
        }
    }
    private static func errorMessage(_ code: String) -> String {
        switch code {
        case "folder_not_found": return "The requested folder does not exist."
        case "ambiguous_folder": return "More than one folder matches. Use a full path or x-coredata ID."
        case "folder_not_empty": return "Only empty folders can be deleted."
        case "attachments_would_be_lost": return "Appending through HTML could remove existing attachments; the note was not changed."
        case "protected_folder": return "System folders and Recently Deleted cannot be changed."
        case "note_locked": return "The note is password protected."
        default: return "Notes operation stopped: \(code)."
        }
    }
}
