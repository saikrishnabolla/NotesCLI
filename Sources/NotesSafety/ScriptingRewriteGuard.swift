import NotesCore

public final class ScriptingRewriteGuard: NotesWriting, @unchecked Sendable {
    private let writer: any NotesWriting
    private let reader: any NotesReading
    private let allowDowngrade: Bool

    public init(writer: any NotesWriting, reader: any NotesReading, allowDowngrade: Bool) {
        self.writer = writer
        self.reader = reader
        self.allowDowngrade = allowDowngrade
    }

    private func guardRewrite(_ ref: String) throws {
        try SnapshotRestorePolicy.requireScriptingBodyRewriteAllowed(reader.note(ref), allowDowngrade: allowDowngrade)
    }

    public func createNote(title: String, markdown: String, folder: String?) throws -> WriteResult { try writer.createNote(title: title, markdown: markdown, folder: folder) }
    public func appendToNote(_ ref: String, markdown: String) throws -> WriteResult { try guardRewrite(ref); return try writer.appendToNote(ref, markdown: markdown) }
    public func replaceBody(_ ref: String, markdown: String) throws -> WriteResult { try guardRewrite(ref); return try writer.replaceBody(ref, markdown: markdown) }
    public func replaceBody(_ ref: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult { try guardRewrite(ref); return try writer.replaceBody(ref, markdown: markdown, allowAttachmentLoss: allowAttachmentLoss) }
    public func prependToNote(_ ref: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult { try guardRewrite(ref); return try writer.prependToNote(ref, markdown: markdown, allowAttachmentLoss: allowAttachmentLoss) }
    public func insertUnderHeading(_ ref: String, heading: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult { try guardRewrite(ref); return try writer.insertUnderHeading(ref, heading: heading, markdown: markdown, allowAttachmentLoss: allowAttachmentLoss) }
    public func replaceSection(_ ref: String, heading: String, markdown: String, allowAttachmentLoss: Bool) throws -> WriteResult { try guardRewrite(ref); return try writer.replaceSection(ref, heading: heading, markdown: markdown, allowAttachmentLoss: allowAttachmentLoss) }
    public func replaceText(_ ref: String, find: String, replacement: String, allowAttachmentLoss: Bool) throws -> WriteResult { try guardRewrite(ref); return try writer.replaceText(ref, find: find, replacement: replacement, allowAttachmentLoss: allowAttachmentLoss) }
    public func renameNote(_ ref: String, title: String) throws -> WriteResult { try writer.renameNote(ref, title: title) }
    public func moveNote(_ ref: String, toFolder: String) throws -> WriteResult { try writer.moveNote(ref, toFolder: toFolder) }
    public func deleteNote(_ ref: String) throws -> WriteResult { try writer.deleteNote(ref) }
    public func createFolder(name: String, parent: String?, account: String?) throws -> WriteResult { try writer.createFolder(name: name, parent: parent, account: account) }
    public func renameFolder(_ ref: String, name: String) throws -> WriteResult { try writer.renameFolder(ref, name: name) }
    public func deleteFolder(_ ref: String) throws -> WriteResult { try writer.deleteFolder(ref) }
    public func moveFolder(_ ref: String, toParent: String?, account: String?) throws -> WriteResult { try writer.moveFolder(ref, toParent: toParent, account: account) }
    public func htmlBody(_ ref: String) throws -> String { try writer.htmlBody(ref) }
}
