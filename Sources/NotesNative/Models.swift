import Foundation
import NotesCore

public struct NativeDoctorReport: Codable, Sendable {
    public var frameworkLoaded: Bool
    public var frameworkPath: String
    public var macOS: String
    public var missing: [String]
    public var error: String?
    public var classes: [String: NativeClassReport]
}

public struct NativeClassReport: Codable, Sendable {
    public var resolved: Bool
    public var selectors: [String: Bool]
}

public struct NativeVerification: Codable, Sendable {
    public var nativeReadback: [String: String]
    public var sqliteReadback: [String: String]?
}

public struct NativeWriteResult: Codable, Sendable {
    public var writeResult: WriteResult
    public var verification: NativeVerification
    public var operationID: String?

    public init(writeResult: WriteResult, verification: NativeVerification, operationID: String? = nil) {
        self.writeResult = writeResult
        self.verification = verification
        self.operationID = operationID
    }
}

public struct ChecklistItem: Codable, Sendable, Equatable {
    public var index: Int
    public var text: String
    public var done: Bool
    public var range: UTF16Range
}

public struct UTF16Range: Codable, Sendable, Equatable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}

public enum NativeParagraphStyle: String, Codable, Sendable, CaseIterable {
    case title, heading, subheading, body, monospaced, bulleted, dashed, numbered, checklist, blockquote
    public var number: Int {
        switch self {
        case .title: 0; case .heading: 1; case .subheading: 2; case .body, .blockquote: 3
        case .monospaced: 4; case .bulleted: 100; case .dashed: 101; case .numbered: 102; case .checklist: 103
        }
    }
}

public enum NativeParagraphAlignment: String, Codable, Sendable, CaseIterable {
    case left, right, center, justified, natural
    public var value: Int {
        switch self { case .left: 0; case .right: 1; case .center: 2; case .justified: 3; case .natural: 4 }
    }
}

public enum NativeWritingDirection: String, Codable, Sendable, CaseIterable {
    case natural, leftToRight = "left-to-right", rightToLeft = "right-to-left"
    public var value: Int {
        switch self { case .natural: -1; case .leftToRight: 0; case .rightToLeft: 1 }
    }
}

public struct InlineFormat: Codable, Sendable {
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strike: Bool?
    public var link: String?
    public var clearLink = false
    public var color: String?
    public var clearColor = false
    public var superscript: Int?
    public var fontName: String?
    public var fontSize: Double?
    public var highlight: HighlightColor?
    public var clearHighlight = false
    public init(bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, strike: Bool? = nil,
                link: String? = nil, clearLink: Bool = false, color: String? = nil, clearColor: Bool = false,
                superscript: Int? = nil, fontName: String? = nil, fontSize: Double? = nil,
                highlight: HighlightColor? = nil, clearHighlight: Bool = false) {
        self.bold = bold; self.italic = italic; self.underline = underline; self.strike = strike
        self.link = link; self.clearLink = clearLink; self.color = color; self.clearColor = clearColor
        self.superscript = superscript; self.fontName = fontName; self.fontSize = fontSize
        self.highlight = highlight; self.clearHighlight = clearHighlight
    }
}

public struct NativeNoteLink: Codable, Sendable, Equatable {
    public var sourceID: String
    public var targetID: String
    public var text: String
    public var attachmentID: String
    public var range: UTF16Range?
}

public struct NativeAttachmentResult: Codable, Sendable {
    public var attachmentID: String
    public var typeUTI: String
    public var position: Int
    public var sourceSHA256: String?
    public var storedSHA256: String?
    public var write: NativeWriteResult
    public init(attachmentID: String, typeUTI: String, position: Int, sourceSHA256: String? = nil,
                storedSHA256: String? = nil, write: NativeWriteResult) {
        self.attachmentID = attachmentID; self.typeUTI = typeUTI; self.position = position
        self.sourceSHA256 = sourceSHA256; self.storedSHA256 = storedSHA256; self.write = write
    }
}

public struct NativeCreateResult: Codable, Sendable {
    public var attachmentIDs: [String]
    public var attachmentSHA256: [String: String]
    public var write: NativeWriteResult
}

public struct NativeTable: Codable, Sendable, Equatable {
    public var attachmentID: String
    public var rows: [[String]]
}

public enum NativeFolderSortOrder: String, Codable, Sendable, CaseIterable {
    case `default`, modified, created, title
    public var value: Int { switch self { case .default: 0; case .modified: 1; case .created: 2; case .title: 3 } }
}
public enum NativeFolderSortDirection: String, Codable, Sendable, CaseIterable {
    case newest, oldest, ascending, descending
    public var value: Int { switch self { case .newest, .ascending: 0; case .oldest, .descending: 1 } }
}
public struct NativeFolderSortSetting: Codable, Sendable, Equatable {
    public var folderID: String
    public var order: NativeFolderSortOrder
    public var direction: NativeFolderSortDirection
    public var valueRepresentation: Int
    public var groupsByDate: Bool
}

public enum ChecklistSelection: Sendable {
    case index(Int)
    case text(String)
}

public protocol NotesNativeWriting {
    func doctor() -> NativeDoctorReport
    func checklistItems(_ ref: String) throws -> [ChecklistItem]
    func checklistAutoSortEnabled() -> Bool
    func setChecklistAutoSort(_ enabled: Bool) throws -> NativeWriteResult
    func insertChecklist(_ ref: String, text: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func toggleChecklist(_ ref: String, selection: ChecklistSelection, done: Bool?, allowShared: Bool) throws -> NativeWriteResult
    func setAllChecklist(_ ref: String, done: Bool, allowShared: Bool) throws -> NativeWriteResult
    func deleteCompleted(_ ref: String, allowShared: Bool) throws -> NativeWriteResult
    func setPinned(_ ref: String, pinned: Bool, allowShared: Bool) throws -> NativeWriteResult
    func addTag(_ ref: String, tag: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func removeTag(_ ref: String, tag: String, allowShared: Bool) throws -> NativeWriteResult
    func renameTag(_ tag: String, to: String, expectedCount: Int, allowShared: Bool) throws -> NativeWriteResult
    func deleteTag(_ tag: String, expectedCount: Int, allowShared: Bool) throws -> NativeWriteResult
    func insertNoteLink(_ ref: String, target: String, text: String?, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func insertDivider(_ ref: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func insertMathExpression(_ ref: String, expression: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func insertMention(_ ref: String, text: String, userRecordName: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func links(_ ref: String) throws -> [NativeNoteLink]
    func backlinks(_ ref: String) throws -> [NativeNoteLink]
    func insertText(_ ref: String, text: String, position: Int, allowShared: Bool) throws -> NativeWriteResult
    func deleteRange(_ ref: String, range: UTF16Range, allowShared: Bool) throws -> NativeWriteResult
    func replaceRange(_ ref: String, range: UTF16Range, text: String, allowShared: Bool) throws -> NativeWriteResult
    func searchOffsets(_ ref: String, text: String, caseInsensitive: Bool) throws -> [UTF16Range]
    func setParagraphStyle(_ ref: String, range: UTF16Range, style: NativeParagraphStyle, indent: Int?,
                           alignment: NativeParagraphAlignment?, writingDirection: NativeWritingDirection?, collapsed: Bool?,
                           allowShared: Bool) throws -> NativeWriteResult
    func setInlineFormat(_ ref: String, range: UTF16Range, format: InlineFormat, allowShared: Bool) throws -> NativeWriteResult
    func insertFile(_ ref: String, file: URL, position: Int?, imageView: String?, allowShared: Bool) throws -> NativeAttachmentResult
    func insertFrozenFile(_ ref: String, frozen: FrozenAttachmentInput, position: Int?, imageView: String?, allowShared: Bool) throws -> NativeAttachmentResult
    func createNote(title: String, markdown: String, folder: String?, attachments: [FrozenAttachmentInput], allowShared: Bool) throws -> NativeCreateResult
    func insertURL(_ ref: String, url: URL, card: Bool, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func deleteAttachment(_ ref: String, attachmentID: String, allowShared: Bool) throws -> NativeWriteResult
    func createTable(_ ref: String, rows: [[String]], position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func editTable(_ ref: String, attachmentID: String, row: Int, column: Int, text: String, allowShared: Bool) throws -> NativeWriteResult
    func formatTableCell(_ ref: String, attachmentID: String, row: Int, column: Int, range: UTF16Range, format: InlineFormat, allowShared: Bool) throws -> NativeWriteResult
    func resizeTable(_ ref: String, attachmentID: String, axis: String, index: Int, add: Bool, allowShared: Bool) throws -> NativeWriteResult
    func convertTableToText(_ ref: String, attachmentID: String, separator: String, allowShared: Bool) throws -> NativeWriteResult
    func duplicate(_ ref: String, title: String?, allowShared: Bool) throws -> NativeWriteResult
    func restore(_ ref: String, folder: String?, allowShared: Bool) throws -> NativeWriteResult
    func moveFolder(_ ref: String, parent: String?, allowShared: Bool) throws -> NativeWriteResult
    func folderSort(_ ref: String) throws -> NativeFolderSortSetting
    func setFolderSort(_ ref: String, order: NativeFolderSortOrder, direction: NativeFolderSortDirection) throws -> NativeWriteResult
    func defaultAccountIdentifier() throws -> String
    func setDefaultAccount(_ identifier: String) throws -> NativeWriteResult
    func createSmartFolder(name: String, tags: [String], matchAll: Bool) throws -> NativeWriteResult
    func renameSmartFolder(_ ref: String, name: String, expectedCount: Int) throws -> NativeWriteResult
    func smartFolderQuery(_ ref: String) throws -> String
    func editSmartFolderRules(_ ref: String, queryJSON: String, expectedCount: Int) throws -> NativeWriteResult
    func deleteSmartFolder(_ ref: String, expectedCount: Int) throws -> NativeWriteResult
    func writeMarkdown(_ ref: String, markdown: String, dryRun: Bool, backup: Bool, allowShared: Bool) throws -> NativeWriteResult
}
