import Foundation
import NotesCore
import PencilKit

public struct NativeDoctorReport: Codable, Sendable {
    public var frameworkLoaded: Bool
    public var frameworkPath: String
    public var macOS: String
    /// Every checked selector that this macOS lacks, core and optional.
    public var missing: [String]
    public var error: String?
    public var classes: [String: NativeClassReport]

    /// Selectors used by only one feature. Each of those features checks its own selector before it runs,
    /// so a missing optional selector disables that feature alone, not the native engine.
    public static let optionalSelectors: Set<String> = [
        "+[ICInlineAttachment newDividerLineAttachmentWithIdentifier:note:parentAttachment:]",
        "+[ICInlineAttachment newCalculateGraphExpressionAttachmentWithIdentifier:altText:note:parentAttachment:rightToLeft:]",
        "+[Calculate evaluate:options:error:]",
        "-[CalculateResult formattedExpression]",
        "-[CalculateResult formattedResult]",
        "+[ICInlineAttachment newMentionAttachmentWithIdentifier:mentionText:userRecordName:note:parentAttachment:]",
        "+[ICInlineAttachment newParagraphLinkAttachmentWithIdentifier:toNote:paragraphName:paragraphID:fromNote:parentAttachment:]",
        "-[SYContentItem initWithDisplayTitle:sourceIdentifier:sourceName:itemURL:]",
        "-[SYContentItem dataRepresentationWithError:]",
        "-[SYContentItem initWithData:error:]",
        "-[SYContentItem displayTitle]",
        "-[SYContentItem sourceIdentifier]",
        "-[SYContentItem sourceLastKnownName]",
        "-[SYContentItem itemURL]",
        "-[ICNote addSynapseLinkAttachmentWithContentItem:]",
        "-[ICAttachment hasSynapseLink]",
        "-[ICAttachment synapseData]",
        "-[ICAttachment setOcrSummary:]",
        "-[ICAttachment setImageClassificationSummary:]",
        "-[ICOutlineState initWithCollapsedUUIDs:]",
        "-[ICOutlineState data]",
        "-[ICOutlineState collapsedUUIDStrings]",
        "+[ICTextStyle noteDefaultNamedStyle]",
        "+[ICTextStyle setNoteDefaultNamedStyle:]",
        "+[ICDocCamImageQuad quadFromCGRect:]",
        "+[ICGalleryAttachmentUtilities createAndAddSubAttachmentsToGalleryAttachment:fromDocuments:imageCache:context:]",
        "-[ICDocCamScannedDocumentEditor initWithGalleryAttachment:]",
        "-[ICDocCamScannedDocumentEditor applyFilter:forAttachmentWithIdentifier:]",
        "-[ICDocCamScannedDocumentEditor setOrientation:forAttachmentAtIndex:]",
        "-[ICDocCamScannedDocumentEditor setQuad:forAttachmentWithIdentifier:]",
        "-[ICDocCamScannedDocumentEditor setMarkupData:forAttachmentWithIdentifier:]",
        "-[ICDocCamScannedDocumentEditor moveObjectWithIdentifier:toIndex:]",
        "-[ICDocCamScannedDocumentEditor deletePagesAtIndexes:]",
        "-[ICDocCamScannedDocumentEditor undeleteSubAttachment:]",
        "-[ICDocCamScannedDocumentEditor galleryModel]",
        "-[ICDocCamScannedDocumentEditor saveAndUpdatePreview:]",
        "-[ICNote addGalleryAttachmentWithIdentifier:]",
        "-[ICAttachment addLocationIfNeeded]",
        "-[ICAttachmentGalleryModel subAttachmentCount]",
        "-[ICAttachmentGalleryModel subAttachmentIdentifierAtIndex:]",
        "-[ICAttachmentGalleryModel indexOfSubAttachmentWithIdentifier:]",
        "-[ICAttachmentGalleryModel insertSubAttachment:atIndex:]",
        "-[ICFolder applyDateHeadersType:]",
        "-[ICFolder isShowingDateHeaders]",
        "-[ICDocCamImageCache initWithDataCryptorDelegate:cachesDirectoryURL:]",
        "-[ICDocCamImageCache setImage:metaData:]",
        "-[ICDocCamImageCache getImageURL:]",
        "-[ICDocCamImageCache deleteAllImages]",
        "-[ICDocCamDocumentInfo init]",
        "-[ICDocCamDocumentInfo setFullImageUUID:]",
        "-[ICDocCamDocumentInfo setCroppedButNotFilteredImageUUID:]",
        "-[ICDocCamDocumentInfo setCroppedAndFilteredImageUUID:]",
        "-[ICDocCamDocumentInfo setImageQuad:]",
        "-[ICDocCamDocumentInfo setMetaData:]",
        "-[ICDocCamDocumentInfo setCurrentFilter:]",
        "-[ICDocCamDocumentInfo setCurrentOrientation:]",
        "-[ICAttachmentAudioModel deleteSummaryAndReturnError:]",
    ]
    /// Missing selectors that the whole native engine depends on.
    public var missingCore: [String] { missing.filter { !Self.optionalSelectors.contains($0) } }
    /// Missing selectors that disable only their own feature.
    public var missingOptional: [String] { missing.filter { Self.optionalSelectors.contains($0) } }
    /// True when native writes can run; individual features may still be unavailable.
    public var usable: Bool { frameworkLoaded && error == nil && missingCore.isEmpty }
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

/// The "New notes start with" choices in Notes settings. Notes offers no monospaced choice there.
public enum NativeDefaultParagraphStyle: String, Codable, Sendable, CaseIterable {
    case title, heading, subheading, body
    public var value: Int {
        switch self { case .title: 0; case .heading: 1; case .subheading: 2; case .body: 3 }
    }
    public init?(value: Int) {
        guard let style = Self.allCases.first(where: { $0.value == value }) else { return nil }
        self = style
    }
}

/// A stored Notes preference: an explicit on or off value, or no stored value (Notes uses its default).
public enum NativePreferenceState: String, Codable, Sendable, CaseIterable {
    case on, off, `default`
}

/// Simple Notes preferences that live in Notes' real container preference files.
public enum NativeNotesPreference: String, Codable, Sendable, CaseIterable {
    /// Date grouping for tag, search, and Smart Folder lists (`kICQueryDateHeadersTypeKey`: 0 default, 1 off, 2 on).
    case queryDateGrouping = "query-date-grouping"
    /// Automatic Markdown formatting while typing (`ICShouldAutoFormatMarkdownDefaultsKey`).
    case autoFormatMarkdown = "auto-format-markdown"
    /// "Use dark backgrounds for note content". Notes stores the inverse in `alwaysShowLightContent`.
    case darkBackgrounds = "dark-backgrounds"
    /// Note counts in the folder list (`showsNoteCount`).
    case showNoteCount = "show-note-count"

    public var key: String {
        switch self {
        case .queryDateGrouping: "kICQueryDateHeadersTypeKey"
        case .autoFormatMarkdown: "ICShouldAutoFormatMarkdownDefaultsKey"
        case .darkBackgrounds: "alwaysShowLightContent"
        case .showNoteCount: "showsNoteCount"
        }
    }
    public var inApplicationDomain: Bool { self == .darkBackgrounds || self == .showNoteCount }
    /// The value Notes uses when no value is stored. Each default was read from Notes 4.13 on macOS 27.2.1.
    public var defaultEnabled: Bool { true }

    public func storedValue(enabled: Bool) -> Int {
        switch self {
        case .queryDateGrouping: enabled ? 2 : 1
        case .darkBackgrounds: enabled ? 0 : 1
        case .autoFormatMarkdown, .showNoteCount: enabled ? 1 : 0
        }
    }

    public func state(stored: Any?) throws -> NativePreferenceState {
        guard let stored else { return .default }
        guard let number = stored as? NSNumber else {
            throw NotesError("unsupported_preference", "Notes stores an unexpected \(key) value.")
        }
        let value = number.intValue
        switch self {
        case .queryDateGrouping:
            switch value { case 0: return .default; case 1: return .off; case 2: return .on
            default: throw NotesError("unsupported_preference", "Notes stores unknown \(key) value \(value).") }
        case .darkBackgrounds:
            guard [0, 1].contains(value) else { throw NotesError("unsupported_preference", "Notes stores unknown \(key) value \(value).") }
            return value == 0 ? .on : .off
        case .autoFormatMarkdown, .showNoteCount:
            guard [0, 1].contains(value) else { throw NotesError("unsupported_preference", "Notes stores unknown \(key) value \(value).") }
            return value == 1 ? .on : .off
        }
    }
}

public struct NativePreferenceValue: Codable, Sendable, Equatable {
    public var setting: NativeNotesPreference
    public var state: NativePreferenceState
    /// The effective value: the stored value, or Notes' default when nothing is stored.
    public var enabled: Bool
    public init(setting: NativeNotesPreference, state: NativePreferenceState) {
        self.setting = setting
        self.state = state
        enabled = state == .default ? setting.defaultEnabled : state == .on
    }
}

/// Notes' list or gallery mode, read from the main window state Notes last saved.
public struct NativeNoteContainerViewState: Codable, Sendable, Equatable {
    public var mode: String
    public var preferredMode: String?
    public var galleryItemSizeRatio: Double?
    public init(mode: String, preferredMode: String?, galleryItemSizeRatio: Double?) {
        self.mode = mode
        self.preferredMode = preferredMode
        self.galleryItemSizeRatio = galleryItemSizeRatio
    }
    public static func mode(_ value: Int) -> String? {
        switch value { case 0: "list"; case 1: "gallery"; default: nil }
    }
}

public enum NativeGlobalNoteSort: String, Codable, Sendable, CaseIterable {
    case modified, created, title
    public var value: Int { switch self { case .modified: 0; case .created: 1; case .title: 2 } }
    public init?(value: Int) {
        guard let sort = Self.allCases.first(where: { $0.value == value }) else { return nil }
        self = sort
    }
}

public struct NativeNotesSettings: Codable, Sendable, Equatable {
    public var sort: NativeGlobalNoteSort
    public var groupsByDate: Bool
    public var defaultTextSize: Int
    public var resumesLastQuickNote: Bool
    public var autoConvertsToTags: Bool
    public var defaultParagraphStyle: NativeDefaultParagraphStyle?
    public var checklistAutoSort: Bool?
    public var defaultAccountID: String?
    public var queryDateGrouping: NativePreferenceValue?
    public var autoFormatMarkdown: NativePreferenceValue?
    public var darkBackgrounds: NativePreferenceValue?
    public var showNoteCount: NativePreferenceValue?
    public var noteContainerView: NativeNoteContainerViewState?
    public init(sort: NativeGlobalNoteSort, groupsByDate: Bool, defaultTextSize: Int, resumesLastQuickNote: Bool,
                autoConvertsToTags: Bool, defaultParagraphStyle: NativeDefaultParagraphStyle? = nil,
                checklistAutoSort: Bool? = nil, defaultAccountID: String? = nil,
                preferences: [NativePreferenceValue] = [], noteContainerView: NativeNoteContainerViewState? = nil) {
        self.sort = sort
        self.groupsByDate = groupsByDate
        self.defaultTextSize = defaultTextSize
        self.resumesLastQuickNote = resumesLastQuickNote
        self.autoConvertsToTags = autoConvertsToTags
        self.defaultParagraphStyle = defaultParagraphStyle
        self.checklistAutoSort = checklistAutoSort
        self.defaultAccountID = defaultAccountID
        self.noteContainerView = noteContainerView
        for preference in preferences { self[preference.setting] = preference }
    }
    public subscript(_ setting: NativeNotesPreference) -> NativePreferenceValue? {
        get {
            switch setting {
            case .queryDateGrouping: queryDateGrouping
            case .autoFormatMarkdown: autoFormatMarkdown
            case .darkBackgrounds: darkBackgrounds
            case .showNoteCount: showNoteCount
            }
        }
        set {
            switch setting {
            case .queryDateGrouping: queryDateGrouping = newValue
            case .autoFormatMarkdown: autoFormatMarkdown = newValue
            case .darkBackgrounds: darkBackgrounds = newValue
            case .showNoteCount: showNoteCount = newValue
            }
        }
    }
}

public enum NativeMapURL {
    public static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "maps.apple.com" else {
            throw NotesError("invalid_map_url", "Use an https://maps.apple.com URL.")
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
    public var targetParagraphID: String?
    public var targetParagraphName: String?
    public var text: String
    public var attachmentID: String
    public var range: UTF16Range?
    public init(sourceID: String, targetID: String, targetParagraphID: String? = nil,
                targetParagraphName: String? = nil, text: String, attachmentID: String,
                range: UTF16Range?) {
        self.sourceID = sourceID; self.targetID = targetID
        self.targetParagraphID = targetParagraphID; self.targetParagraphName = targetParagraphName
        self.text = text; self.attachmentID = attachmentID; self.range = range
    }
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

public struct NativeScanResult: Codable, Sendable {
    public var attachmentID: String
    public var pageAttachmentIDs: [String]
    public var position: Int
    public var write: NativeWriteResult

    public init(attachmentID: String, pageAttachmentIDs: [String], position: Int, write: NativeWriteResult) {
        self.attachmentID = attachmentID
        self.pageAttachmentIDs = pageAttachmentIDs
        self.position = position
        self.write = write
    }
}

public enum NativeScanFilter: String, Codable, Sendable, CaseIterable {
    case photo, color, grayscale, blackAndWhite = "black-and-white", whiteboard
    public var value: Int {
        switch self { case .photo: 0; case .color: 1; case .grayscale: 2; case .blackAndWhite: 3; case .whiteboard: 4 }
    }
    public init?(value: Int) { guard let item = Self.allCases.first(where: { $0.value == value }) else { return nil }; self = item }
}

public enum NativeScanOrientation: String, Codable, Sendable, CaseIterable {
    case upright, upsideDown = "upside-down", left, right
    public var value: Int { switch self { case .upright: 0; case .upsideDown: 1; case .left: 2; case .right: 3 } }
    public init?(value: Int) { guard let item = Self.allCases.first(where: { $0.value == value }) else { return nil }; self = item }
}

public struct NativeScanPageState: Codable, Sendable, Equatable {
    public var noteID: String
    public var attachmentID: String
    public var pageID: String
    public var pageIDs: [String]
    public var filter: NativeScanFilter
    public var orientation: NativeScanOrientation
    public var crop: ScanCrop?
    public var hasMarkup: Bool
    public var hasEmbeddedMarkup: Bool

    public init(noteID: String, attachmentID: String, pageID: String, pageIDs: [String],
                filter: NativeScanFilter, orientation: NativeScanOrientation,
                crop: ScanCrop?, hasMarkup: Bool, hasEmbeddedMarkup: Bool = false) {
        self.noteID = noteID
        self.attachmentID = attachmentID
        self.pageID = pageID
        self.pageIDs = pageIDs
        self.filter = filter
        self.orientation = orientation
        self.crop = crop
        self.hasMarkup = hasMarkup
        self.hasEmbeddedMarkup = hasEmbeddedMarkup
    }
}

public struct NativeCalculation: Codable, Sendable, Equatable {
    public var expression: String
    public var formattedExpression: String
    public var result: String
    public var renderedText: String

    public init(expression: String, formattedExpression: String, result: String, renderedText: String) {
        self.expression = expression
        self.formattedExpression = formattedExpression
        self.result = result
        self.renderedText = renderedText
    }
}

public struct NativeMathResult: Codable, Sendable {
    public var calculation: NativeCalculation
    public var position: Int
    public var write: NativeWriteResult

    public init(calculation: NativeCalculation, position: Int, write: NativeWriteResult) {
        self.calculation = calculation
        self.position = position
        self.write = write
    }
}

public struct NativeCreateResult: Codable, Sendable {
    public var attachmentIDs: [String]
    public var attachmentSHA256: [String: String]
    public var write: NativeWriteResult
}

public struct NativeRecordingResult: Codable, Sendable {
    public var attachmentID: String
    public var childAttachmentIDs: [String]
    public var duration: Double
    public var transcriptSegments: Int
    public var write: NativeWriteResult

    public init(attachmentID: String, childAttachmentIDs: [String], duration: Double,
                transcriptSegments: Int, write: NativeWriteResult) {
        self.attachmentID = attachmentID
        self.childAttachmentIDs = childAttachmentIDs
        self.duration = duration
        self.transcriptSegments = transcriptSegments
        self.write = write
    }
}

public struct NativePaperAttachment: Sendable {
    public var attachmentID: String
    public var typeUTI: String
    public var drawings: [PKDrawing]

    public init(attachmentID: String, typeUTI: String, drawings: [PKDrawing]) {
        self.attachmentID = attachmentID
        self.typeUTI = typeUTI
        self.drawings = drawings
    }
}

public struct NativeHandwritingResult: Codable, Sendable {
    public var attachmentID: String
    public var text: String
    public var rawText: String
    public var modelText: String
    public var score: Double
    public var strokeCount: Int
    public var pointCount: Int
    public var persisted: Bool
    public var write: NativeWriteResult?

    public init(attachmentID: String, text: String, rawText: String, modelText: String,
                score: Double, strokeCount: Int, pointCount: Int, persisted: Bool,
                write: NativeWriteResult? = nil) {
        self.attachmentID = attachmentID
        self.text = text
        self.rawText = rawText
        self.modelText = modelText
        self.score = score
        self.strokeCount = strokeCount
        self.pointCount = pointCount
        self.persisted = persisted
        self.write = write
    }
}

public struct NativeFallbackPDFResult: Codable, Sendable {
    public var attachmentID: String
    public var byteCount: Int
    public var path: String
    public var write: NativeWriteResult

    public init(attachmentID: String, byteCount: Int, path: String, write: NativeWriteResult) {
        self.attachmentID = attachmentID
        self.byteCount = byteCount
        self.path = path
        self.write = write
    }
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
    func setQuickNote(_ ref: String, enabled: Bool, allowShared: Bool) throws -> NativeWriteResult
    func addTag(_ ref: String, tag: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func removeTag(_ ref: String, tag: String, allowShared: Bool) throws -> NativeWriteResult
    func renameTag(_ tag: String, to: String, expectedCount: Int, allowShared: Bool) throws -> NativeWriteResult
    func deleteTag(_ tag: String, expectedCount: Int, allowShared: Bool) throws -> NativeWriteResult
    func insertNoteLink(_ ref: String, target: String, text: String?, paragraphID: String?,
                        paragraphName: String?, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func insertDivider(_ ref: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func insertMathExpression(_ ref: String, expression: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func evaluateMath(_ expression: String) throws -> NativeCalculation
    func insertMathResult(_ ref: String, expression: String, position: Int?, allowShared: Bool) throws -> NativeMathResult
    func insertMention(_ ref: String, text: String, userRecordName: String, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func insertMap(_ ref: String, url: URL, position: Int?, allowShared: Bool) throws -> NativeWriteResult
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
    func insertDrawing(_ ref: String, drawing: PKDrawing, position: Int?, allowShared: Bool) throws -> NativeAttachmentResult
    func insertLegacyDrawing(_ ref: String, records: [LegacyDrawingStrokeRecord], position: Int?, allowShared: Bool) throws -> NativeAttachmentResult
    func insertFrozenFile(_ ref: String, frozen: FrozenAttachmentInput, position: Int?, imageView: String?, allowShared: Bool) throws -> NativeAttachmentResult
    func insertScan(_ ref: String, pages: [FrozenAttachmentInput], position: Int?, allowShared: Bool) throws -> NativeScanResult
    func appendScanPages(_ ref: String, attachmentID: String, pages: [FrozenAttachmentInput],
                         expectedPageIDs: [String]?, allowShared: Bool) throws -> NativeScanResult
    func scanPageState(_ ref: String, attachmentID: String, pageID: String) throws -> NativeScanPageState
    func detectScanCrop(_ ref: String, attachmentID: String, pageID: String) throws -> ScanCrop
    func setScanFilter(_ ref: String, attachmentID: String, pageID: String, filter: NativeScanFilter,
                       expectedCurrent: NativeScanFilter?, allowShared: Bool) throws -> NativeWriteResult
    func setScanOrientation(_ ref: String, attachmentID: String, pageID: String, orientation: NativeScanOrientation,
                            expectedCurrent: NativeScanOrientation?, allowShared: Bool) throws -> NativeWriteResult
    func setScanCrop(_ ref: String, attachmentID: String, pageID: String, crop: ScanCrop,
                     expectedCurrent: ScanCrop?, allowShared: Bool) throws -> NativeWriteResult
    func moveScanPage(_ ref: String, attachmentID: String, pageID: String, toIndex: Int,
                      expectedPageIDs: [String]?, allowShared: Bool) throws -> NativeWriteResult
    func deleteScanPage(_ ref: String, attachmentID: String, pageID: String,
                        expectedPageIDs: [String]?, allowShared: Bool) throws -> NativeWriteResult
    func restoreScanPage(_ ref: String, attachmentID: String, pageID: String, toIndex: Int,
                         expectedPageIDs: [String]?, allowShared: Bool) throws -> NativeWriteResult
    func deleteScanPages(_ ref: String, attachmentID: String, pageIDs: [String],
                         expectedPageIDs: [String]?, allowShared: Bool) throws -> NativeWriteResult
    func createNote(title: String, markdown: String, folder: String?, attachments: [FrozenAttachmentInput], allowShared: Bool) throws -> NativeCreateResult
    func createQuickNote(title: String, markdown: String, folder: String?, allowShared: Bool) throws -> NativeCreateResult
    func insertRecording(_ ref: String, frozen: FrozenAttachmentInput, title: String?, duration: Double,
                         transcript: [TranscriptWord], allowShared: Bool) throws -> NativeRecordingResult
    func createRecordingNote(folder: String?, title: String, frozen: FrozenAttachmentInput, duration: Double,
                             transcript: [TranscriptWord], allowShared: Bool) throws -> NativeRecordingResult
    func writeRecordingTranscripts(_ ref: String, transcripts: [String: [TranscriptWord]], allowShared: Bool) throws -> NativeWriteResult
    func createDrawingNote(title: String, folder: String?, drawing: PKDrawing, allowShared: Bool) throws -> NativeCreateResult
    func insertURL(_ ref: String, url: URL, card: Bool, position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func insertSynapseLink(_ ref: String, url: URL, title: String,
                           position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func deleteAttachment(_ ref: String, attachmentID: String, allowShared: Bool) throws -> NativeWriteResult
    func createTable(_ ref: String, rows: [[String]], position: Int?, allowShared: Bool) throws -> NativeWriteResult
    func editTable(_ ref: String, attachmentID: String, row: Int, column: Int, text: String, allowShared: Bool) throws -> NativeWriteResult
    func formatTableCell(_ ref: String, attachmentID: String, row: Int, column: Int, range: UTF16Range, format: InlineFormat, allowShared: Bool) throws -> NativeWriteResult
    func resizeTable(_ ref: String, attachmentID: String, axis: String, index: Int, add: Bool, allowShared: Bool) throws -> NativeWriteResult
    func convertTableToText(_ ref: String, attachmentID: String, separator: String, allowShared: Bool) throws -> NativeWriteResult
    func duplicate(_ ref: String, title: String?, allowShared: Bool) throws -> NativeWriteResult
    func deleteNote(_ ref: String, allowShared: Bool) throws -> NativeWriteResult
    func restore(_ ref: String, folder: String?, allowShared: Bool) throws -> NativeWriteResult
    func moveFolder(_ ref: String, parent: String?, allowShared: Bool) throws -> NativeWriteResult
    func folderSort(_ ref: String) throws -> NativeFolderSortSetting
    func setFolderSort(_ ref: String, order: NativeFolderSortOrder, direction: NativeFolderSortDirection) throws -> NativeWriteResult
    func setFolderDateGrouping(_ ref: String, grouped: Bool, allowShared: Bool) throws -> NativeWriteResult
    func notesSettings() throws -> NativeNotesSettings
    func setGlobalNoteSort(_ sort: NativeGlobalNoteSort) throws -> NativeWriteResult
    func setGlobalDateGrouping(_ enabled: Bool) throws -> NativeWriteResult
    func setDefaultTextSize(_ points: Int) throws -> NativeWriteResult
    func setResumeLastQuickNote(_ enabled: Bool) throws -> NativeWriteResult
    func setAutoConvertToTags(_ enabled: Bool) throws -> NativeWriteResult
    func defaultParagraphStyle() throws -> NativeDefaultParagraphStyle
    func setDefaultParagraphStyle(_ style: NativeDefaultParagraphStyle) throws -> NativeWriteResult
    func defaultAccountIdentifier() throws -> String
    func setDefaultAccount(_ identifier: String) throws -> NativeWriteResult
    func createSmartFolder(name: String, tags: [String], matchAll: Bool) throws -> NativeWriteResult
    func renameSmartFolder(_ ref: String, name: String, expectedCount: Int) throws -> NativeWriteResult
    func smartFolderQuery(_ ref: String) throws -> String
    func editSmartFolderRules(_ ref: String, queryJSON: String, expectedCount: Int) throws -> NativeWriteResult
    func deleteSmartFolder(_ ref: String, expectedCount: Int) throws -> NativeWriteResult
    func writeMarkdown(_ ref: String, markdown: String, dryRun: Bool, backup: Bool, allowShared: Bool) throws -> NativeWriteResult
    func appendMarkdown(_ ref: String, markdown: String, allowShared: Bool) throws -> NativeWriteResult
    func prependMarkdown(_ ref: String, markdown: String, allowShared: Bool) throws -> NativeWriteResult
    func insertMarkdown(_ ref: String, underHeading heading: String, markdown: String, allowShared: Bool) throws -> NativeWriteResult
    func replaceSection(_ ref: String, heading: String, markdown: String, allowShared: Bool) throws -> NativeWriteResult
    func replaceText(_ ref: String, find: String, replacement: String, allowShared: Bool) throws -> NativeWriteResult
}
