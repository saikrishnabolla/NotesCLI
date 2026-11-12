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

public enum SmartFolderQueryFlag: String, Sendable, Equatable {
    case deleted, checklist, checklistInProgress, checklistCompleted, attachment, pinned, systemPaper
    case passwordProtected, shared, mention, tagged, quickNote
}

public enum SmartFolderDateField: Sendable, Equatable { case created, modified }

public indirect enum SmartFolderQueryRule: Sendable, Equatable {
    case all([SmartFolderQueryRule]), any([SmartFolderQueryRule]), not(SmartFolderQueryRule)
    case flag(SmartFolderQueryFlag, Bool), tag(String), folder(String), attachmentSection(Int)
    case sharedParticipant(String), mentionParticipant(String)
    case relativeDate(SmartFolderDateField, type: Int, amount: Int?, unit: Int?)
    case dateRange(SmartFolderDateField, from: Date, to: Date)
}

public enum SmartFolderQueryGrammar {
    public static func validate(_ json: String) throws { _ = try parse(json) }

    public static func parse(_ json: String) throws -> SmartFolderQueryRule {
        guard let data = json.data(using: .utf8) else { throw invalid("The query is not UTF-8.") }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw invalid("The query is not valid JSON.") }
        guard value is [String: Any] else { throw invalid("The top-level query must be an object.") }
        return try clause(value, path: "query")
    }

    private static func clause(_ value: Any, path: String) throws -> SmartFolderQueryRule {
        guard let object = value as? [String: Any], !object.isEmpty else {
            throw invalid("\(path) must be a nonempty rule object.")
        }
        if object["type"] != nil, object.count != 1 { throw invalid("\(path).type cannot have sibling rules.") }
        if object.count > 1 {
            return .all(try object.keys.sorted().map { key in
                try entry(key: key, value: object[key]!, path: "\(path).\(key)")
            })
        }
        let key = object.keys.first!
        return try entry(key: key, value: object[key]!, path: "\(path).\(key)")
    }

    private static func entry(key: String, value: Any, path: String) throws -> SmartFolderQueryRule {
        if key == "type" { return try clause(value, path: path) }
        if key == "and" || key == "or" {
            guard let values = value as? [Any], !values.isEmpty else {
                throw invalid("\(path) must be a nonempty array of rules.")
            }
            let rules = try values.enumerated().map { try clause($0.element, path: "\(path)[\($0.offset)]") }
            return key == "and" ? .all(rules) : .any(rules)
        }
        if key == "not" { return .not(try clause(value, path: path)) }
        if let flag = SmartFolderQueryFlag(rawValue: key) {
            guard let expected = value as? Bool else { throw invalid("\(path) must be true or false.") }
            return .flag(flag, expected)
        }
        if ["tag", "folder", "sharedParticipant", "mentionParticipant"].contains(key) {
            guard let text = value as? String, !text.isEmpty else { throw invalid("\(path) must be a nonempty string.") }
            switch key {
            case "tag": return .tag(text)
            case "folder": return .folder(text)
            case "sharedParticipant": return .sharedParticipant(text)
            default: return .mentionParticipant(text)
            }
        }
        if key == "attachmentSection" {
            guard let section = integer(value), (1...7).contains(section) else {
                throw invalid("\(path) must be an integer from 1 through 7.")
            }
            return .attachmentSection(section)
        }
        if key == "creationDateRange" || key == "modificationDateRange" {
            guard let range = value as? [String: Any], Set(range.keys) == Set(["fromDate", "toDate"]),
                  let from = number(range["fromDate"]), let to = number(range["toDate"]), from <= to else {
                throw invalid("\(path) must contain ordered numeric fromDate and toDate values.")
            }
            let field: SmartFolderDateField = key.hasPrefix("creation") ? .created : .modified
            return .dateRange(field, from: Date(timeIntervalSinceReferenceDate: from),
                              to: Date(timeIntervalSinceReferenceDate: to))
        }
        if key == "creationDateRelativeRange" || key == "modificationDateRelativeRange" {
            guard let range = value as? [String: Any], !range.isEmpty,
                  Set(range.keys).isSubset(of: Set(["type", "customAmount", "customUnit"])),
                  let type = integer(range["type"]),
                  range["customAmount"].map({ integer($0) != nil }) ?? true,
                  range["customUnit"].map({ integer($0) != nil }) ?? true else {
                throw invalid("\(path) has an invalid relative-date rule.")
            }
            let field: SmartFolderDateField = key.hasPrefix("creation") ? .created : .modified
            return .relativeDate(field, type: type, amount: integer(range["customAmount"]),
                                 unit: integer(range["customUnit"]))
        }
        throw invalid("Unknown Smart Folder rule at \(path).")
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.rounded() == number,
              number >= Double(Int.min), number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func invalid(_ message: String) -> NotesError {
        NotesError("invalid_smart_folder_query", message)
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
