import Foundation
import NotesCore

public struct ScriptingNote: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var folderID: String
    public var folderPath: [String]
    public var accountID: String
}

public struct ScriptingFolder: Codable, Equatable, Sendable {
    public var id: String
    public var path: [String]
    public var accountID: String
}

public enum WriteOperation: String, Codable, Sendable {
    case createNote, appendToNote, replaceBody, renameNote, moveNote, deleteNote
    case createFolder, renameFolder, moveFolder, deleteFolder
    case prependToNote, insertUnderHeading, replaceSection, replaceText
}

public struct WriteVerificationRequest: Sendable {
    public var operation: WriteOperation
    public var ref: String?
    public var title: String?
    public var markdown: String?
    public var bodyBefore: String?
    public var expectedBody: String?
    public var expectedBodyIncludesTitle: Bool
    public var folder: String?
    public var name: String?
    public var parent: String?
    public var account: String?
    public var expectedFolderPath: [String]?
    public var result: WriteResult
    public init(operation: WriteOperation, ref: String? = nil, title: String? = nil, markdown: String? = nil, bodyBefore: String? = nil,
                expectedBody: String? = nil, expectedBodyIncludesTitle: Bool = false,
                folder: String? = nil, name: String? = nil, parent: String? = nil, account: String? = nil,
                expectedFolderPath: [String]? = nil, result: WriteResult) {
        self.operation = operation; self.ref = ref; self.title = title; self.markdown = markdown; self.folder = folder
        self.bodyBefore = bodyBefore; self.expectedBody = expectedBody; self.expectedBodyIncludesTitle = expectedBodyIncludesTitle
        self.name = name; self.parent = parent; self.account = account
        self.expectedFolderPath = expectedFolderPath; self.result = result
    }
}

public struct WriteVerificationResult: Sendable {
    public var outcome: WriteOutcome
    public var noteID: NoteID?
    public var folderID: String?
    public var mismatch: String?
    public init(outcome: WriteOutcome, noteID: NoteID? = nil, folderID: String? = nil, mismatch: String? = nil) {
        self.outcome = outcome; self.noteID = noteID; self.folderID = folderID; self.mismatch = mismatch
    }
}

/// All mutations use Notes.app. The caller's verifier must read a fresh store snapshot.
/// Instances serialize their own operations, including verification and attachment creation.
/// `noteID.coreDataID` is the scripting identity. A fresh-snapshot verifier resolves
/// the stable database UUID after the write.
/// Create and replace prepend the title as h1. Replace removes prior body content.
/// Appending to notes with attachments is refused because HTML round-tripping can lose them.
/// On macOS 27.2, local images are downgraded: both tested AppleScript insertion
/// forms produced duplicate image placements. Other OS versions attempt attachment once.
public final class ScriptingNotesWriter: NotesWriting, Sendable {
    public typealias Resolver = @Sendable (String) throws -> String?
    public typealias Verifier = @Sendable (WriteVerificationRequest) throws -> WriteVerificationResult
    private let runner: any ScriptRunning
    private let timeout: TimeInterval
    private let resolver: Resolver?
    /// Maps folder UUIDs (ZIDENTIFIER) to x-coredata ids. Notes.app scripting only knows the latter,
    /// so without this a UUID would be matched as a folder name and never resolve.
    private let folderResolver: Resolver?
    private let verifier: Verifier?
    private let attachLocalImages: Bool
    private let permissionCheck: @Sendable () throws -> Void
    private let lock = NSRecursiveLock()

    public init(timeout: TimeInterval = 30, resolver: Resolver? = nil, folderResolver: Resolver? = nil, verifier: Verifier? = nil) {
        self.runner = OSAScriptRunner(); self.timeout = timeout; self.resolver = resolver; self.folderResolver = folderResolver; self.verifier = verifier
        self.permissionCheck = { try NotesAutomationPermission.check() }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // Both documented AppleScript insertion forms duplicate images on 27.2.
        self.attachLocalImages = !(os.majorVersion == 27 && os.minorVersion == 2)
    }

    // Test injection is internal so production calls cannot accidentally skip consent checks.
    init(runner: any ScriptRunning, timeout: TimeInterval = 30, resolver: Resolver? = nil, folderResolver: Resolver? = nil,
         verifier: Verifier? = nil, attachLocalImages: Bool = true, permissionCheck: @escaping @Sendable () throws -> Void = {}) {
        self.runner = runner; self.timeout = timeout; self.resolver = resolver; self.folderResolver = folderResolver; self.verifier = verifier
        self.permissionCheck = permissionCheck
        self.attachLocalImages = attachLocalImages
    }

    public func createNote(title: String, markdown: String, folder: String? = nil) throws -> WriteResult {
        try write("createNote", fields: ["title": title, "folder": try folderRef(folder)], markdown: markdown)
    }
    public func appendToNote(_ ref: String, markdown: String) throws -> WriteResult {
        try write("appendToNote", fields: ["ref": resolve(ref)], markdown: markdown, uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func replaceBody(_ ref: String, markdown: String) throws -> WriteResult {
        try replaceBody(ref, markdown: markdown, allowAttachmentLoss: false)
    }
    public func replaceBody(_ ref: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult {
        try write("replaceBody", fields: ["ref": resolve(ref), "allowAttachmentLoss": allowAttachmentLoss ? "true" : "false"], markdown: markdown, uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func renameNote(_ ref: String, title: String) throws -> WriteResult {
        try write("renameNote", fields: ["ref": resolve(ref), "title": title], uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func moveNote(_ ref: String, toFolder: String) throws -> WriteResult {
        try write("moveNote", fields: ["ref": resolve(ref), "folder": try folderRef(toFolder)], uuid: UUID(uuidString: ref)?.uuidString)
    }
    /// On macOS 27.2.1 (26B131), live tests confirmed that `delete` moves the note
    /// to Recently Deleted. Notes still exposes it in app.notes, so each call
    /// checks its current folder and rejects a second delete. Trash is never emptied.
    /// Shared notes and accounts that are not upgraded are rejected.
    public func deleteNote(_ ref: String) throws -> WriteResult {
        try write("deleteNote", fields: ["ref": resolve(ref)], uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func deleteNote(_ ref: String, allowedFolderIDs: [String]) throws -> WriteResult {
        guard !allowedFolderIDs.isEmpty else { throw NotesError("stale_folder", "The allowed folder subtree is empty.") }
        let encoded = String(decoding: try JSONEncoder().encode(allowedFolderIDs), as: UTF8.self)
        return try write("deleteNote", fields: ["ref": resolve(ref), "allowedFolderIDsJSON": encoded], uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func createFolder(name: String, parent: String? = nil, account: String? = nil) throws -> WriteResult {
        try validateFolderName(name)
        return try write("createFolder", fields: ["name": name, "parent": try folderRef(parent), "account": account])
    }
    public func renameFolder(_ ref: String, name: String) throws -> WriteResult {
        try validateFolderName(name)
        return try write("renameFolder", fields: ["ref": try folderRef(ref), "name": name])
    }
    /// Deletes empty, non-system, unshared folders only; refuses recursive deletion.
    public func deleteFolder(_ ref: String) throws -> WriteResult {
        try write("deleteFolder", fields: ["ref": try folderRef(ref)])
    }
    public func moveFolder(_ ref: String, toParent: String?, account: String? = nil) throws -> WriteResult {
        try write("moveFolder", fields: ["ref": try folderRef(ref), "parent": try folderRef(toParent), "account": account])
    }
    public func prependToNote(_ ref: String, markdown: String, allowAttachmentLoss: Bool = false) throws -> WriteResult {
        let target = try resolve(ref), current = try editableHTML(target, allowAttachmentLoss: allowAttachmentLoss)
        let addition = MarkdownToNotesHTML.convert(markdown).html
        let titleRange = try headingMatches(current).first(where: { $0.level == 1 }).flatMap { Range($0.range, in: current) }
        let boundary = current.range(of: "</h1>", options: .caseInsensitive)?.upperBound ?? titleRange?.upperBound ?? current.startIndex
        let html = String(current[..<boundary]) + addition + String(current[boundary...])
        return try writeHTML("prependToNote", ref: target, html: html, allowAttachmentLoss: allowAttachmentLoss, uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func insertUnderHeading(_ ref: String, heading: String, markdown: String, allowAttachmentLoss: Bool = false) throws -> WriteResult {
        let target = try resolve(ref), current = try editableHTML(target, allowAttachmentLoss: allowAttachmentLoss)
        let headings = try headingMatches(current)
        guard let match = headings.first(where: { $0.text == heading }) else { throw NotesError("heading_not_found", "Heading \(heading) was not found.") }
        guard let matchedRange = Range(match.range, in: current) else { throw NotesError("invalid_note_html", "The note heading range was invalid.") }
        let index = matchedRange.upperBound
        let html = String(current[..<index]) + MarkdownToNotesHTML.convert(markdown).html + String(current[index...])
        return try writeHTML("insertUnderHeading", ref: target, html: html, allowAttachmentLoss: allowAttachmentLoss, uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func replaceSection(_ ref: String, heading: String, markdown: String, allowAttachmentLoss: Bool = false) throws -> WriteResult {
        let target = try resolve(ref), current = try editableHTML(target, allowAttachmentLoss: allowAttachmentLoss)
        let headings = try headingMatches(current)
        guard let index = headings.firstIndex(where: { $0.text == heading }) else { throw NotesError("heading_not_found", "Heading \(heading) was not found.") }
        let match = headings[index]
        guard let matchedRange = Range(match.range, in: current) else { throw NotesError("invalid_note_html", "The note heading range was invalid.") }
        let start = matchedRange.upperBound
        let next = headings.dropFirst(index + 1).first(where: { $0.level <= match.level })?.range.lowerBound ?? current.utf16.count
        guard let end = Range(NSRange(location: next, length: 0), in: current)?.lowerBound else { throw NotesError("invalid_note_html", "The note section range was invalid.") }
        let html = String(current[..<start]) + MarkdownToNotesHTML.convert(markdown).html + String(current[end...])
        return try writeHTML("replaceSection", ref: target, html: html, allowAttachmentLoss: allowAttachmentLoss, uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func replaceText(_ ref: String, find: String, replacement: String, allowAttachmentLoss: Bool = false) throws -> WriteResult {
        guard !find.isEmpty else { throw NotesError("invalid_find", "Find text cannot be empty.") }
        let target = try resolve(ref), current = try editableHTML(target, allowAttachmentLoss: allowAttachmentLoss)
        let escapedFind = MarkdownToNotesHTML.escape(find), escapedReplacement = MarkdownToNotesHTML.escape(replacement)
        guard current.contains(escapedFind) else { throw NotesError("text_not_found", "The requested text was not found in one HTML text run.") }
        let html = current.replacingOccurrences(of: escapedFind, with: escapedReplacement)
        return try writeHTML("replaceText", ref: target, html: html, allowAttachmentLoss: allowAttachmentLoss, uuid: UUID(uuidString: ref)?.uuidString)
    }
    public func showInNotes(_ ref: String) throws {
        _ = try execute("show", fields: ["ref": resolve(ref)], isWrite: false)
    }
    public func listViaScripting() throws -> [ScriptingNote] {
        let result = try execute("list", fields: [:], isWrite: false)
        guard let notes = result.notes else { throw NotesError("invalid_script_response", "Notes returned no list.") }
        return notes
    }
    public func listFoldersViaScripting() throws -> [ScriptingFolder] {
        let result = try execute("listFolders", fields: [:], isWrite: false)
        guard let folders = result.folders else { throw NotesError("invalid_script_response", "Notes returned no folder list.") }
        return folders
    }
    public func htmlBody(_ ref: String) throws -> String {
        let reply = try execute("read", fields: ["ref": resolve(ref)], isWrite: false)
        guard let body = reply.body else { throw NotesError("note_locked", "The note body is unavailable.") }
        return body
    }
    public func validateFolderDelete(_ ref: String, expectedCount: Int) throws {
        _ = try execute("validateFolderDelete", fields: ["ref": try folderRef(ref), "expectCount": String(expectedCount)], isWrite: false)
    }
    public func isDeletedViaScripting(_ ref: String) throws -> Bool {
        let reply = try execute("deletionStatus", fields: ["ref": ref], isWrite: false)
        guard let isDeleted = reply.isDeleted else { throw NotesError("invalid_script_response", "Notes returned no deletion status.") }
        return isDeleted
    }

    private func resolve(_ ref: String) throws -> String {
        if ref.hasPrefix("x-coredata://") { return ref }
        if let mapped = try resolver?(ref), mapped.hasPrefix("x-coredata://") { return mapped }
        throw NotesError("note_not_found", "The note reference could not be resolved.", hint: "Supply an x-coredata ID or a resolver backed by NotesReading.")
    }
    /// Folder refs may be a name, "A > B" path, x-coredata id, or UUID; UUIDs become x-coredata ids.
    private func folderRef(_ ref: String?) throws -> String? {
        guard let ref, UUID(uuidString: ref) != nil, let mapped = try folderResolver?(ref), mapped.hasPrefix("x-coredata://") else { return ref }
        return mapped
    }
    private func validateFolderName(_ name: String) throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.contains(">") {
            throw NotesError("invalid_folder_name", "Folder names must be nonempty and cannot contain >.")
        }
    }

    private func write(_ operation: String, fields: [String: String?], markdown: String? = nil, rawHTML: String? = nil, uuid: String? = nil) throws -> WriteResult {
        lock.lock(); defer { lock.unlock() }
        let converted = markdown.map(MarkdownToNotesHTML.convert)
        var fields = fields
        if let rawHTML { fields.updateValue(rawHTML, forKey: "html") }
        else if let converted { fields.updateValue(converted.html, forKey: "html") }
        let reply = try execute(operation, fields: fields, isWrite: true)
        let ref = reply.id ?? (operation.hasSuffix("Note") || operation == "replaceBody" ? fields["ref"] ?? nil : nil)
        var result = WriteResult(outcome: reply.unknownOutcome ? .unknown : .unverified,
                                 noteID: ref.map { NoteID(uuid: uuid ?? "", coreDataID: $0) }, folderID: reply.folderID)
        var downgraded = Set(converted?.downgraded ?? [])
        if reply.unknownOutcome {
            result.message = "Write timed out or lost its response; its outcome is unknown. Do not retry."
            return result
        }
        let incompleteResponse = reply.changed == true && (reply.errorCode != nil || reply.errorNumber != nil)
        if incompleteResponse {
            result.message = "Notes changed, but the script could not complete its response. Do not retry."
        }
        if !incompleteResponse {
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
        }
        if let verifier, let kind = WriteOperation(rawValue: operation) {
            let exactHTML = rawHTML ?? converted?.html
            let exactBody: String?
            let exactBodyIncludesTitle: Bool
            switch kind {
            case .appendToNote:
                exactBody = reply.bodyBefore.flatMap { before in
                    exactHTML.map { MarkdownToNotesHTML.exactPlainText(html: before + $0) }
                }
                exactBodyIncludesTitle = true
            case .prependToNote, .insertUnderHeading, .replaceSection, .replaceText:
                exactBody = exactHTML.map { MarkdownToNotesHTML.exactPlainText(html: $0) }
                exactBodyIncludesTitle = true
            case .createNote, .replaceBody:
                exactBody = exactHTML.map { MarkdownToNotesHTML.exactPlainText(html: $0) }
                exactBodyIncludesTitle = false
            default:
                exactBody = nil
                exactBodyIncludesTitle = false
            }
            let request = WriteVerificationRequest(operation: kind, ref: fields["ref"] ?? nil, title: fields["title"] ?? nil,
                markdown: markdown, bodyBefore: reply.bodyBefore.map { MarkdownToNotesHTML.exactPlainText(html: $0) },
                expectedBody: exactBody, expectedBodyIncludesTitle: exactBodyIncludesTitle,
                folder: fields["folder"] ?? nil, name: fields["name"] ?? nil,
                parent: fields["parent"] ?? nil, account: fields["account"] ?? nil,
                expectedFolderPath: reply.folderPath ?? Self.expectedFolderPath(operation: kind, fields: fields), result: result)
            do {
                let verification = try verifier(request)
                result.outcome = verification.outcome
                result.noteID = verification.noteID ?? result.noteID
                result.folderID = verification.folderID ?? result.folderID
                if let mismatch = verification.mismatch {
                    result.message = [result.message, "mismatch: \(mismatch)"].compactMap { $0 }.joined(separator: " ")
                }
            }
            catch {
                result.outcome = .unverified
                result.message = [result.message, "Write completed; verification failed. Do not retry the write."].compactMap { $0 }.joined(separator: " ")
            }
        }
        return result
    }

    private static func expectedFolderPath(operation: WriteOperation, fields: [String: String?]) -> [String]? {
        func components(_ value: String?) -> [String]? {
            guard let value, !value.hasPrefix("x-coredata://") else { return nil }
            let parts = value.split(separator: ">").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return parts.isEmpty || parts.contains(where: \.isEmpty) ? nil : parts
        }
        switch operation {
        case .createNote, .moveNote:
            return components(fields["folder"] ?? nil)
        case .createFolder:
            guard let name = fields["name"] ?? nil, !name.isEmpty else { return nil }
            return (components(fields["parent"] ?? nil) ?? []) + [name]
        case .renameFolder:
            guard var path = components(fields["ref"] ?? nil), let name = fields["name"] ?? nil else { return nil }
            path[path.count - 1] = name
            return path
        case .moveFolder:
            guard let name = components(fields["ref"] ?? nil)?.last else { return nil }
            return (components(fields["parent"] ?? nil) ?? []) + [name]
        case .deleteFolder:
            return components(fields["ref"] ?? nil)
        default:
            return nil
        }
    }

    private func editableHTML(_ ref: String, allowAttachmentLoss: Bool) throws -> String {
        let reply = try execute("read", fields: ["ref": ref], isWrite: false)
        if (reply.attachmentCount ?? 0) > 0 && !allowAttachmentLoss {
            throw NotesError("attachments_would_be_lost", "Editing through HTML could remove existing attachments; the note was not changed.")
        }
        guard let body = reply.body else { throw NotesError("note_locked", "The note body is unavailable.") }
        return body
    }

    private func writeHTML(_ operation: String, ref: String, html: String, allowAttachmentLoss: Bool, uuid: String?) throws -> WriteResult {
        let expected = MarkdownToNotesHTML.plainText(html: html)
        return try write(operation, fields: ["ref": ref, "allowAttachmentLoss": allowAttachmentLoss ? "true" : "false"],
                         markdown: expected, rawHTML: html, uuid: uuid)
    }

    private func headingMatches(_ html: String) throws -> [(level: Int, text: String, range: NSRange)] {
        let expression = try NSRegularExpression(pattern: #"<h([1-6])\b[^>]*>(.*?)</h\1>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let range = NSRange(html.startIndex..., in: html)
        var matches: [(level: Int, text: String, range: NSRange)] = expression.matches(in: html, range: range).compactMap { match in
            guard let levelRange = Range(match.range(at: 1), in: html), let bodyRange = Range(match.range(at: 2), in: html),
                  let level = Int(html[levelRange]) else { return nil }
            return (level, MarkdownToNotesHTML.plainText(html: String(html[bodyRange])), match.range)
        }
        let blocks = try NSRegularExpression(pattern: #"<div\b[^>]*>(.*?)</div>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let sizes = try NSRegularExpression(pattern: #"font-size:\s*([0-9]+(?:\.[0-9]+)?)px"#, options: .caseInsensitive)
        for block in blocks.matches(in: html, range: range) {
            guard let bodyRange = Range(block.range(at: 1), in: html) else { continue }
            let body = String(html[bodyRange])
            guard body.range(of: #"<b\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let sizeMatch = sizes.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let sizeRange = Range(sizeMatch.range(at: 1), in: body), let size = Double(body[sizeRange]) else { continue }
            let level = size >= 22 ? 1 : size >= 17 ? 2 : 3
            matches.append((level, MarkdownToNotesHTML.plainText(html: body), block.range))
        }
        return matches.sorted { $0.range.location < $1.range.location }
    }

    struct Reply: Decodable {
        var id: String?
        var folderID: String?
        var folderPath: [String]?
        var notes: [ScriptingNote]?
        var folders: [ScriptingFolder]?
        var title: String?
        var body: String?
        var bodyBefore: String?
        var name: String?
        var noteCount: Int?
        var childCount: Int?
        var attachmentCount: Int?
        var isDeleted: Bool?
        var errorCode: String?
        var errorNumber: Int?
        var changed: Bool?
        var unknownOutcome = false
        enum CodingKeys: String, CodingKey {
            case id, folderID, folderPath, notes, folders, title, body, bodyBefore, name, noteCount, childCount, attachmentCount, isDeleted, errorCode, errorNumber, changed
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
        case "shared_folder": return "Shared folders cannot be deleted."
        case "shared_note": return "Shared notes cannot be deleted recursively."
        case "unsupported_account": return "The account does not support safe deletion."
        case "stale_folder": return "The folder contents changed after the deletion preflight."
        default: return "Notes operation stopped: \(code)."
        }
    }
}
