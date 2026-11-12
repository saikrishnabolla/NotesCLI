import Foundation

public enum SmartFolderRuleMatch: String, Codable, Sendable { case all, any }

public enum SmartFolderAttachmentSection: Int, Codable, Sendable, CaseIterable {
    case images = 1
    case drawings = 2
    case maps = 3
    case links = 4
    case audio = 5
    case documents = 6
    case scans = 7
    public init?(name: String) {
        switch name.lowercased() {
        case "images", "photos", "videos": self = .images
        case "drawings": self = .drawings
        case "maps": self = .maps
        case "links": self = .links
        case "audio": self = .audio
        case "documents", "attachments": self = .documents
        case "scans": self = .scans
        default: return nil
        }
    }
}

public struct SmartFolderRules: Sendable, Equatable {
    public var match: SmartFolderRuleMatch
    public var tags: [String]
    public var tagsMatch: SmartFolderRuleMatch
    public var createdFrom: Date?
    public var createdTo: Date?
    public var modifiedFrom: Date?
    public var modifiedTo: Date?
    public var folders: [String]
    public var checklists: Bool?
    public var attachmentSections: [SmartFolderAttachmentSection]
    public var shared: Bool?
    public var locked: Bool?
    public var mentions: Bool?
    public var quickNotes: Bool?

    public init(match: SmartFolderRuleMatch = .all, tags: [String] = [], tagsMatch: SmartFolderRuleMatch = .any,
                createdFrom: Date? = nil, createdTo: Date? = nil, modifiedFrom: Date? = nil, modifiedTo: Date? = nil,
                folders: [String] = [], checklists: Bool? = nil,
                attachmentSections: [SmartFolderAttachmentSection] = [], shared: Bool? = nil, locked: Bool? = nil,
                mentions: Bool? = nil, quickNotes: Bool? = nil) {
        self.match = match; self.tags = tags; self.tagsMatch = tagsMatch
        self.createdFrom = createdFrom; self.createdTo = createdTo; self.modifiedFrom = modifiedFrom; self.modifiedTo = modifiedTo
        self.folders = folders; self.checklists = checklists; self.attachmentSections = attachmentSections
        self.shared = shared; self.locked = locked; self.mentions = mentions; self.quickNotes = quickNotes
    }

    public func json() throws -> String {
        var clauses: [[String: Any]] = []
        let tagClauses = Set(tags.filter { !$0.isEmpty }).sorted().map { ["tag": $0] }
        if tagClauses.count == 1 { clauses.append(tagClauses[0]) }
        else if !tagClauses.isEmpty { clauses.append([tagsMatch == .all ? "and" : "or": tagClauses]) }
        try appendRange(key: "creationDateRange", from: createdFrom, to: createdTo, to: &clauses)
        try appendRange(key: "modificationDateRange", from: modifiedFrom, to: modifiedTo, to: &clauses)
        let folderClauses = Set(folders.filter { !$0.isEmpty }).sorted().map { ["folder": $0] }
        if folderClauses.count == 1 { clauses.append(folderClauses[0]) }
        else if !folderClauses.isEmpty { clauses.append(["or": folderClauses]) }
        if let checklists { clauses.append(["checklist": checklists]) }
        for section in Set(attachmentSections.map(\.rawValue)).sorted() { clauses.append(["attachmentSection": section]) }
        if let shared { clauses.append(["shared": shared]) }
        if let locked { clauses.append(["passwordProtected": locked]) }
        if let mentions { clauses.append(["mention": mentions]) }
        if let quickNotes { clauses.append(["quickNote": quickNotes]) }
        guard !clauses.isEmpty else { throw NotesError("invalid_smart_folder_rules", "At least one Smart Folder rule is required.") }
        let object: [String: Any] = [match == .all ? "and" : "or": clauses]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func appendRange(key: String, from: Date?, to: Date?, to clauses: inout [[String: Any]]) throws {
        guard from != nil || to != nil else { return }
        guard let from, let to, from <= to else {
            throw NotesError("invalid_smart_folder_date_range", "\(key) requires an ordered from and to date.")
        }
        clauses.append([key: ["fromDate": from.timeIntervalSinceReferenceDate, "toDate": to.timeIntervalSinceReferenceDate]])
    }
}
