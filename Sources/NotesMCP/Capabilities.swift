import Carbon
import Foundation
import NotesCore
import NotesNative
import Speech

public struct FeatureDefinition: Codable, Sendable, Equatable {
    public var feature: String
    public var read: String
    public var write: String

    public init(feature: String, read: String, write: String) {
        self.feature = feature
        self.read = read
        self.write = write
    }
}

public struct CapabilityFeature: Codable, Sendable {
    public var feature: String
    public var read: String
    public var write: String
    public var readEngine: String
    public var writeEngine: String
    public var permissions: [String: String]
    public var nativeSelectors: String
    public var reasons: [String: CapabilityLimitation]
}

public struct CapabilityLimitation: Codable, Sendable, Equatable {
    public var reason: String
    public var detail: String

    public init(reason: String, detail: String) {
        self.reason = reason
        self.detail = detail
    }
}

public struct CapabilityReport: Codable, Sendable {
    public var macOS: String
    public var permissions: [String: String]
    public var nativeFrameworkLoaded: Bool
    public var nativeMissing: [String]
    public var features: [CapabilityFeature]
}

public enum CapabilityCatalog {
    public static let features: [FeatureDefinition] = [
        FeatureDefinition(feature: "Title style", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Heading style", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Subheading style", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Body style", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Monospaced style", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Block quote", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Paragraph indentation", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Left, center, right, and justified alignment", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Natural, left-to-right, and right-to-left writing direction", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Bold", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Italic", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Underline", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Strikethrough", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Superscript", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Subscript", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Font family", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Font size", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Foreground text color", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Purple highlight", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Pink highlight", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Orange highlight", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Mint highlight", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Blue highlight", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Clear inline formatting", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Collapsible headings and subheadings", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Bulleted lists", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Dashed lists", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Numbered lists and starting number", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Nested lists", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Checklists", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Checklist sorting preference", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Native tables", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Add or remove table rows and columns", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Table cell text", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Table cell rich formatting", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Convert table to text", read: "Done", write: "Done"),
        FeatureDefinition(feature: "External web links", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Native note-to-note links", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Paragraph links and persistent anchors", read: "Done", write: "Done"),
        FeatureDefinition(feature: "URL preview cards", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Native tags", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Mentions", read: "Done", write: "Partial"),
        FeatureDefinition(feature: "Photos and images", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Camera capture", read: "Done", write: "Partial"),
        FeatureDefinition(feature: "Editorial SVG and HTML diagrams", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Videos", read: "Done", write: "Done"),
        FeatureDefinition(feature: "PDFs", read: "Done", write: "Done"),
        FeatureDefinition(feature: "General file attachments", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Maps and location cards", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Contact cards", read: "Done", write: "Not possible"),
        FeatureDefinition(feature: "Scanned documents", read: "Done", write: "Partial"),
        FeatureDefinition(feature: "Image and PDF markup", read: "Done", write: "Partial"),
        FeatureDefinition(feature: "Classic drawings and sketches", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Modern Paper drawings", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Audio file attachments", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Native audio recordings", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Stored audio transcripts", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Recording summaries and call metadata", read: "Done", write: "Partial"),
        FeatureDefinition(feature: "Math expressions, results, and graphs", read: "Done", write: "Partial"),
        FeatureDefinition(feature: "Divider lines", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Pin and unpin", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Locked-note state", read: "Done", write: "Not possible"),
        FeatureDefinition(feature: "Share state and participants", read: "Done", write: "Not possible"),
        FeatureDefinition(feature: "Edit an existing shared note", read: "Partial", write: "Partial"),
        FeatureDefinition(feature: "Collaboration activity and changes", read: "Partial", write: "Not possible"),
        FeatureDefinition(feature: "Accounts and default location", read: "Done", write: "Partial"),
        FeatureDefinition(feature: "Folders and subfolders", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Recently Deleted", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Smart Folders and rules", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Quick Notes", read: "Done", write: "Partial"),
        FeatureDefinition(feature: "Folder list and gallery views", read: "Partial", write: "Not possible"),
        FeatureDefinition(feature: "Folder sort options", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Folder grouping by date", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Note display order", read: "Done", write: "Partial"),
        FeatureDefinition(feature: "Search by title and body", read: "Done", write: "Not possible"),
        FeatureDefinition(feature: "Search filters and Boolean queries", read: "Done", write: "Not possible"),
        FeatureDefinition(feature: "OCR and image labels", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Handwriting recognition", read: "Done", write: "Done"),
        FeatureDefinition(feature: "PDF text search", read: "Done", write: "Not possible"),
        FeatureDefinition(feature: "Audio transcript search", read: "Done", write: "Not possible"),
        FeatureDefinition(feature: "Import plain text, HTML, and Markdown", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Export Markdown and HTML", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Export JSON, NDJSON, and SQLite", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Export PDF, DOCX, RTF, and EPUB", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Export Bear, Joplin, Quiver, TextBundle, and ZIP", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Print", read: "Not possible", write: "Not possible"),
        FeatureDefinition(feature: "Widgets", read: "Not possible", write: "Not possible"),
        FeatureDefinition(feature: "Note notifications", read: "Partial", write: "Not possible"),
        FeatureDefinition(feature: "Notes settings", read: "Partial", write: "Partial"),
        FeatureDefinition(feature: "Default account", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Default paragraph style", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Note links and Share-sheet capture", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Open notes, folders, accounts, and attachments", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Sync and upload state", read: "Done", write: "Done"),
        FeatureDefinition(feature: "Version history, diff, undo, and revert", read: "Partial", write: "Partial"),
        FeatureDefinition(feature: "Multiple iCloud, local, and IMAP accounts", read: "Partial", write: "Partial"),
    ]

    private static func limitation(_ reason: String, _ detail: String) -> CapabilityLimitation {
        CapabilityLimitation(reason: reason, detail: detail)
    }

    private static func apple(_ evidence: String) -> CapabilityLimitation {
        limitation("apple_blocked", "macOS 27.2.1 (26B131) evidence: \(evidence)")
    }

    public static let limitations: [String: [String: CapabilityLimitation]] = [
        "Mentions": ["write": limitation("needs_fixture", "Mention insertion is implemented, but participant notification needs a shared-note fixture and second account.")],
        "Contact cards": ["write": apple("NotesShared and Notes.app expose contact display selectors but no checked contact-card attachment constructor; a public.vcard insert becomes a generic attachment.")],
        "Camera capture": ["write": limitation("needs_fixture", "Device listing and injected photo and scan writes passed live readback; physical frame capture needs camera permission for Notes CLI.")],
        "Scanned documents": ["write": limitation("partial_impl", "Native scan pages, filters, reorder, replacement, and correction are implemented; crop clearing, iPhone Scan Documents, and exported-PDF proof remain.")],
        "Image and PDF markup": ["write": limitation("needs_fixture", "Shape-level add, list, remove, and render pass native readback; select-and-move editing in Notes.app after reload is unverified.")],
        "Recording summaries and call metadata": ["write": limitation("needs_fixture", "Summary deletion is implemented, but this Mac has no recording with an Apple-generated summary.")],
        "Math expressions, results, and graphs": ["write": apple("Calculate and checked native insertion cover stored expressions and plain-text results; interactive recognition and graph rendering remain inside Notes.app.")],
        "Locked-note state": ["write": apple("ICNote exposes lock-state getters, but runtime inspection found no authenticated unlock or key-management contract for a background client.")],
        "Share state and participants": ["write": apple("share and participant objects expose read properties, but runtime selector inspection found no stable invitation, removal, or access-right mutation contract.")],
        "Edit an existing shared note": [
            "read": limitation("needs_fixture", "Shared-note reading is implemented, but this Mac has no active owner or participant fixture."),
            "write": limitation("needs_fixture", "Guarded native editing is implemented, but owner, read-write, read-only, and concurrent-edit fixtures have not run.")
        ],
        "Collaboration activity and changes": [
            "read": limitation("needs_fixture", "Raw activity export is implemented, but this Mac has no activity-bearing shared-note fixture."),
            "write": apple("collaboration records are managed by Notes and CloudKit; runtime inspection found no supported mutation contract.")
        ],
        "Accounts and default location": ["write": apple("Notes CLI can select the default account, but account creation and account settings remain system-owned.")],
        "Quick Notes": ["write": apple("Notes CLI can target the Quick Notes folder, but hot-corner and capture metadata are owned by Notes.app and system UI.")],
        "Folder list and gallery views": [
            "read": apple("the only readable value is Notes' last-saved windowStateArchive, not live window state."),
            "write": apple("Notes rewrites windowStateArchive, and the inspected write paths are Notes.app menu and link actions.")
        ],
        "Note display order": ["write": apple("SQLite stores ZSORTORDER, but runtime inspection found no checked ICNote.setSortOrder: selector.")],
        "Search by title and body": ["write": limitation("not_applicable", "Search is a read operation and has no persistent object to write.")],
        "Search filters and Boolean queries": ["write": limitation("not_applicable", "Filters and queries are read predicates, not writable Notes objects.")],
        "PDF text search": ["write": limitation("not_applicable", "PDF search reads Apple's cached index; there is no user-facing value to write.")],
        "Audio transcript search": ["write": limitation("not_applicable", "Transcript search is a read operation and has no persistent search object to write.")],
        "Print": [
            "read": apple("Notes.app exposes print-panel UI actions but no headless NotesShared print contract."),
            "write": apple("Notes.app exposes print-panel UI actions but no headless NotesShared print contract.")
        ],
        "Widgets": [
            "read": apple("widget state lives in system UI extensions and NotesShared exposes no widget state property."),
            "write": apple("widget state lives in system UI extensions and NotesShared exposes no widget mutation selector.")
        ],
        "Note notifications": [
            "read": apple("the mention-notification subscription state is a CloudKit subscription that needs Notes' entitlements."),
            "write": apple("ICCloudNotificationsController changes a CloudKit subscription using Notes' entitlements, not a writable preference.")
        ],
        "Notes settings": [
            "read": apple("the remaining settings require account lifecycle, locked-note authentication, or Notes-entitled CloudKit access."),
            "write": apple("the remaining settings require account lifecycle, locked-note authentication, or Notes-entitled CloudKit access.")
        ],
        "Version history, diff, undo, and revert": [
            "read": apple("Apple exposes no complete Notes version-history API for edits made outside Notes CLI."),
            "write": apple("Apple exposes no complete Notes version-history API for edits made outside Notes CLI.")
        ],
        "Multiple iCloud, local, and IMAP accounts": [
            "read": limitation("partial_impl", "The full-fidelity reader maps ZACCOUNTTYPE 3 to IMAP but opens only NoteStore.sqlite. This Mac also has a separate NotesV7.storedata legacy schema, and no IMAP fixture proves current placement."),
            "write": limitation("needs_fixture", "Account-aware writes route through Notes.app, but local and IMAP account fixtures have not run.")
        ],
    ]

    public static func requireWrite(_ featureName: String) throws {
        guard let feature = features.first(where: { $0.feature.caseInsensitiveCompare(featureName) == .orderedSame }) else {
            throw NotesError("feature_not_found", "No capability matches \"\(featureName)\".")
        }
        guard feature.write != "Done", let limitation = limitations[feature.feature]?["write"] else { return }
        if limitation.reason == "apple_blocked" {
            throw NotesError("apple_blocked", "\(feature.feature) is blocked by Apple. \(limitation.detail)")
        }
        throw NotesError(limitation.reason, limitation.detail)
    }

    private static let nativeWrites: Set<String> = [
        "Title style", "Heading style", "Subheading style", "Body style", "Monospaced style", "Block quote",
        "Paragraph indentation", "Left, center, right, and justified alignment",
        "Natural, left-to-right, and right-to-left writing direction", "Bold", "Italic", "Underline",
        "Strikethrough", "Superscript", "Subscript", "Font family", "Font size", "Foreground text color",
        "Purple highlight", "Pink highlight", "Orange highlight", "Mint highlight", "Blue highlight",
        "Clear inline formatting", "Collapsible headings and subheadings", "Bulleted lists", "Dashed lists",
        "Numbered lists and starting number", "Nested lists", "Checklists", "Checklist sorting preference",
        "Native tables", "Add or remove table rows and columns", "Table cell text", "Table cell rich formatting",
        "Convert table to text", "Native note-to-note links", "Paragraph links and persistent anchors",
        "URL preview cards", "Native tags", "Mentions",
        "Photos and images", "Editorial SVG and HTML diagrams", "Videos", "PDFs", "General file attachments",
        "Classic drawings and sketches", "Modern Paper drawings",
        "Audio file attachments", "Native audio recordings", "Stored audio transcripts",
        "Recording summaries and call metadata",
        "Math expressions, results, and graphs", "Divider lines", "Pin and unpin", "Edit an existing shared note",
        "Smart Folders and rules", "Folder sort options", "Folder grouping by date", "Notes settings", "Default account",
        "Default paragraph style", "Maps and location cards", "Scanned documents",
        "Note links and Share-sheet capture"
    ]

    private static let filesystemWrites: Set<String> = [
        "Export Markdown and HTML", "Export JSON, NDJSON, and SQLite",
        "Export PDF, DOCX, RTF, and EPUB", "Export Bear, Joplin, Quiver, TextBundle, and ZIP",
        "Version history, diff, undo, and revert"
    ]

    public static func readEngine(for feature: FeatureDefinition) -> String {
        feature.read == "Not possible" ? "unavailable" : "database"
    }

    public static func writeEngine(for feature: FeatureDefinition) -> String {
        if feature.write == "Not possible" { return "unavailable" }
        if filesystemWrites.contains(feature.feature) { return "filesystem" }
        if nativeWrites.contains(feature.feature) { return "native" }
        if feature.feature == "Sync and upload state" || feature.feature.hasPrefix("Open notes") { return "system" }
        return "scripting"
    }
}

extension CapabilityCatalog {
    /// Features that depend on one optional Notes selector. If that selector is missing, only the feature is unavailable.
    static let optionalSelectorFeatures: [String: [String]] = [
        "Divider lines": ["newDividerLineAttachmentWithIdentifier:"],
        "Math expressions, results, and graphs": ["newCalculateGraphExpressionAttachmentWithIdentifier:", "evaluate:options:error:", "formattedResult"],
        "Mentions": ["newMentionAttachmentWithIdentifier:"],
        "Paragraph links and persistent anchors": ["newParagraphLinkAttachmentWithIdentifier:"],
        "Collapsible headings and subheadings": ["ICOutlineState"],
        "Maps and location cards": ["addLocationIfNeeded"],
        "Scanned documents": ["addGalleryAttachmentWithIdentifier:", "ICDocCam", "createAndAddSubAttachmentsToGalleryAttachment:"],
        "Recording summaries and call metadata": ["deleteSummaryAndReturnError:"],
        "Folder grouping by date": ["applyDateHeadersType:", "isShowingDateHeaders"],
        "Default paragraph style": ["noteDefaultNamedStyle", "setNoteDefaultNamedStyle:"],
        "Note links and Share-sheet capture": ["SYContentItem", "addSynapseLinkAttachmentWithContentItem:",
                                                 "hasSynapseLink", "synapseData"],
    ]
    static func optionalSelectorsPresent(for feature: String, missing: [String]) -> Bool {
        guard let markers = optionalSelectorFeatures[feature] else { return true }
        return !missing.contains { item in markers.contains { item.contains($0) } }
    }
}

public enum CapabilityReporter {
    public static func report() -> CapabilityReport {
        let permissionStates = [
            "fullDiskAccess": fullDiskAccess(),
            "automation": automation(),
            "speech": speech()
        ]
        let doctor = NativeNotesWriter().doctor()
        let nativeAvailable = doctor.usable
        let rows = CapabilityCatalog.features.map { definition in
            let readEngine = CapabilityCatalog.readEngine(for: definition)
            let writeEngine = CapabilityCatalog.writeEngine(for: definition)
            let audioFeature = definition.feature.localizedCaseInsensitiveContains("audio") ||
                definition.feature.localizedCaseInsensitiveContains("recording") ||
                definition.feature.localizedCaseInsensitiveContains("transcript")
            return CapabilityFeature(
                feature: definition.feature,
                read: definition.read,
                write: definition.write,
                readEngine: readEngine,
                writeEngine: writeEngine,
                permissions: [
                    "fullDiskAccess": readEngine == "database" ? permissionStates["fullDiskAccess"]! : "not required",
                    "automation": writeEngine == "scripting" ? permissionStates["automation"]! : "not required",
                    "speech": audioFeature ? permissionStates["speech"]! : "not required"
                ],
                nativeSelectors: writeEngine == "native" ? (nativeAvailable && CapabilityCatalog.optionalSelectorsPresent(for: definition.feature, missing: doctor.missingOptional) ? "available" : "missing") : "not required",
                reasons: CapabilityCatalog.limitations[definition.feature] ?? [:]
            )
        }
        return CapabilityReport(macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                                permissions: permissionStates,
                                nativeFrameworkLoaded: doctor.frameworkLoaded,
                                nativeMissing: doctor.missing,
                                features: rows)
    }

    private static func fullDiskAccess() -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
        do {
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
            return "authorized"
        } catch {
            return (error as NSError).code == NSFileReadNoPermissionError ? "denied" : "unavailable"
        }
    }

    private static func automation() -> String {
        var target = AEAddressDesc()
        let bundle = "com.apple.Notes"
        let created = bundle.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, bundle.utf8.count, &target) }
        guard created == noErr else { return "unavailable" }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) {
        case noErr: return "authorized"
        case OSStatus(-1743): return "denied"
        case OSStatus(-1744): return "not determined"
        default: return "unavailable"
        }
    }

    private static func speech() -> String {
        switch AudioTranscriber.authorizationStatus {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unavailable"
        }
    }
}
