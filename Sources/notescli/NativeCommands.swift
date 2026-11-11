import ArgumentParser
import Foundation
import NotesCore
import NotesNative

extension NativeParagraphStyle: ExpressibleByArgument {}

private func nativeWriter(_ options: GlobalOptions) throws -> NativeNotesWriter {
    guard !options.readOnly else { throw NotesError("read_only", "Writing is disabled by --read-only.") }
    return NativeNotesWriter()
}
private func nativePrint<T: Encodable>(_ value: T, options: GlobalOptions) throws {
    if options.json { try Output.json(value) } else { try Output.json(value) }
}

struct NativeDoctor: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-doctor")
    @OptionGroup var options: GlobalOptions
    func run() throws { try nativePrint(NativeNotesWriter().doctor(), options: options) }
}

enum ChecklistAction: String, ExpressibleByArgument { case list, insert, append, toggle, checkAll = "check-all", uncheckAll = "uncheck-all", deleteCompleted = "delete-completed" }
struct NativeChecklist: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-checklist")
    @OptionGroup var options: GlobalOptions
    @Argument var action: ChecklistAction
    @Argument var ref: String
    @Option var text: String?
    @Option var index: Int?
    @Option var position: Int?
    @Option var done: Bool?
    @Flag var allowShared = false
    func run() throws {
        let writer = try nativeWriter(options)
        switch action {
        case .list: try nativePrint(writer.checklistItems(ref), options: options)
        case .insert: try nativePrint(writer.insertChecklist(ref, text: try required(text, "--text"), position: position, allowShared: allowShared), options: options)
        case .append: try nativePrint(writer.insertChecklist(ref, text: try required(text, "--text"), position: nil, allowShared: allowShared), options: options)
        case .toggle:
            let selection: ChecklistSelection
            if let index { selection = .index(index) } else { selection = .text(try required(text, "--text or --index")) }
            try nativePrint(writer.toggleChecklist(ref, selection: selection, done: done, allowShared: allowShared), options: options)
        case .checkAll: try nativePrint(writer.setAllChecklist(ref, done: true, allowShared: allowShared), options: options)
        case .uncheckAll: try nativePrint(writer.setAllChecklist(ref, done: false, allowShared: allowShared), options: options)
        case .deleteCompleted: try nativePrint(writer.deleteCompleted(ref, allowShared: allowShared), options: options)
        }
    }
}

struct NativePin: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-pin")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Flag(name: .customLong("unpin")) var unpin = false
    @Flag var allowShared = false
    func run() throws { try nativePrint(nativeWriter(options).setPinned(ref, pinned: !unpin, allowShared: allowShared), options: options) }
}

enum TagAction: String, ExpressibleByArgument { case add, remove, rename, delete }
struct NativeTag: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-tag")
    @OptionGroup var options: GlobalOptions
    @Argument var action: TagAction
    @Argument var tag: String
    @Option var ref: String?
    @Option(name: .customLong("to")) var newName: String?
    @Option var position: Int?
    @Option var expectedCount: Int?
    @Flag var allowShared = false
    func run() throws {
        let writer = try nativeWriter(options)
        switch action {
        case .add: try nativePrint(writer.addTag(try required(ref, "--ref"), tag: tag, position: position, allowShared: allowShared), options: options)
        case .remove: try nativePrint(writer.removeTag(try required(ref, "--ref"), tag: tag, allowShared: allowShared), options: options)
        case .rename: try nativePrint(writer.renameTag(tag, to: try required(newName, "--to"), expectedCount: try required(expectedCount, "--expected-count")), options: options)
        case .delete: try nativePrint(writer.deleteTag(tag, expectedCount: try required(expectedCount, "--expected-count")), options: options)
        }
    }
}

enum LinkAction: String, ExpressibleByArgument { case add, list, backlinks }
struct NativeLink: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-link")
    @OptionGroup var options: GlobalOptions
    @Argument var action: LinkAction
    @Argument var ref: String
    @Option var target: String?
    @Option var text: String?
    @Option var position: Int?
    @Flag var allowShared = false
    func run() throws {
        let writer = try nativeWriter(options)
        switch action {
        case .add: try nativePrint(writer.insertNoteLink(ref, target: try required(target, "--target"), text: text, position: position, allowShared: allowShared), options: options)
        case .list: try nativePrint(writer.links(ref), options: options)
        case .backlinks: try nativePrint(writer.backlinks(ref), options: options)
        }
    }
}

enum TextAction: String, ExpressibleByArgument { case insert, delete, replace, search }
struct NativeText: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-text")
    @OptionGroup var options: GlobalOptions
    @Argument var action: TextAction
    @Argument var ref: String
    @Option var text: String?
    @Option var position: Int?
    @Option var start: Int?
    @Option var length: Int?
    @Flag var caseInsensitive = false
    @Flag var allowShared = false
    func run() throws {
        let writer = try nativeWriter(options)
        switch action {
        case .insert: try nativePrint(writer.insertText(ref, text: try required(text, "--text"), position: try required(position, "--position"), allowShared: allowShared), options: options)
        case .delete: try nativePrint(writer.deleteRange(ref, range: range(), allowShared: allowShared), options: options)
        case .replace: try nativePrint(writer.replaceRange(ref, range: range(), text: try required(text, "--text"), allowShared: allowShared), options: options)
        case .search: try nativePrint(writer.searchOffsets(ref, text: try required(text, "--text"), caseInsensitive: caseInsensitive), options: options)
        }
    }
    private func range() throws -> UTF16Range { UTF16Range(location: try required(start, "--start"), length: try required(length, "--length")) }
}

enum FormatAction: String, ExpressibleByArgument { case paragraph, inline }
struct NativeFormat: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-format")
    @OptionGroup var options: GlobalOptions
    @Argument var action: FormatAction
    @Argument var ref: String
    @Option var start: Int
    @Option var length: Int
    @Option var style: NativeParagraphStyle?
    @Option var indent: Int?
    @Option var bold: Bool?
    @Option var italic: Bool?
    @Option var underline: Bool?
    @Option var strike: Bool?
    @Option var link: String?
    @Option var color: String?
    @Flag var clearLink = false
    @Flag var clearColor = false
    @Flag var allowShared = false
    func run() throws {
        let writer = try nativeWriter(options), range = UTF16Range(location: start, length: length)
        switch action {
        case .paragraph: try nativePrint(writer.setParagraphStyle(ref, range: range, style: try required(style, "--style"), indent: indent, allowShared: allowShared), options: options)
        case .inline: try nativePrint(writer.setInlineFormat(ref, range: range, format: InlineFormat(bold: bold, italic: italic, underline: underline, strike: strike, link: link, clearLink: clearLink, color: color, clearColor: clearColor), allowShared: allowShared), options: options)
        }
    }
}

enum AttachmentAction: String, ExpressibleByArgument { case image, file, delete }
struct NativeAttachment: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-attachment")
    @OptionGroup var options: GlobalOptions
    @Argument var action: AttachmentAction
    @Argument var ref: String
    @Option var path: String?
    @Option var attachmentID: String?
    @Option var position: Int?
    @Option var view: String?
    @Flag var allowShared = false
    func run() throws {
        let writer = try nativeWriter(options)
        switch action {
        case .image, .file:
            let url = URL(fileURLWithPath: NSString(string: try required(path, "--path")).expandingTildeInPath)
            try nativePrint(writer.insertFile(ref, file: url, position: position, imageView: action == .image ? view : nil, allowShared: allowShared), options: options)
        case .delete: try nativePrint(writer.deleteAttachment(ref, attachmentID: try required(attachmentID, "--attachment-id"), allowShared: allowShared), options: options)
        }
    }
}

enum TableAction: String, ExpressibleByArgument { case create, edit, addRow = "add-row", removeRow = "remove-row", addColumn = "add-column", removeColumn = "remove-column" }
struct NativeTableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-table")
    @OptionGroup var options: GlobalOptions
    @Argument var action: TableAction
    @Argument var ref: String
    @Option var rows: String?
    @Option var attachmentID: String?
    @Option var row: Int?
    @Option var column: Int?
    @Option var text: String?
    @Option var index: Int?
    @Option var position: Int?
    @Flag var allowShared = false
    func run() throws {
        let writer = try nativeWriter(options)
        switch action {
        case .create:
            let data = Data(try required(rows, "--rows JSON").utf8), parsed = try JSONDecoder().decode([[String]].self, from: data)
            try nativePrint(writer.createTable(ref, rows: parsed, position: position, allowShared: allowShared), options: options)
        case .edit: try nativePrint(writer.editTable(ref, attachmentID: try required(attachmentID, "--attachment-id"), row: try required(row, "--row"), column: try required(column, "--column"), text: try required(text, "--text"), allowShared: allowShared), options: options)
        case .addRow, .removeRow, .addColumn, .removeColumn:
            let axis = action == .addRow || action == .removeRow ? "row" : "column", add = action == .addRow || action == .addColumn
            try nativePrint(writer.resizeTable(ref, attachmentID: try required(attachmentID, "--attachment-id"), axis: axis, index: try required(index, "--index"), add: add, allowShared: allowShared), options: options)
        }
    }
}

struct NativeDuplicate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-duplicate")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Option var title: String?
    @Flag var allowShared = false
    func run() throws { try nativePrint(nativeWriter(options).duplicate(ref, title: title, allowShared: allowShared), options: options) }
}
struct NativeRestore: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-restore")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Option var folder: String?
    @Flag var allowShared = false
    func run() throws { try nativePrint(nativeWriter(options).restore(ref, folder: folder, allowShared: allowShared), options: options) }
}
struct NativeMoveFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "native-move-folder")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Option var parent: String?
    @Flag var allowShared = false
    func run() throws { try nativePrint(nativeWriter(options).moveFolder(ref, parent: parent, allowShared: allowShared), options: options) }
}

struct NativeWriteMarkdown: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "write-markdown")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Option var body: String?
    @Flag var stdin = false
    @Option var file: String?
    @Flag var dryRun = false
    @Flag var backup = false
    @Flag var allowShared = false
    func validate() throws { try validateBodySources(body: body, stdin: stdin, file: file) }
    func run() throws { try nativePrint(nativeWriter(options).writeMarkdown(ref, markdown: try inputBody(body: body, stdin: stdin, file: file), dryRun: dryRun, backup: backup, allowShared: allowShared), options: options) }
}

private func required<T>(_ value: T?, _ option: String) throws -> T {
    guard let value else { throw ValidationError("Provide \(option).") }; return value
}
