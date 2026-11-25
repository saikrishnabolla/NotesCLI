import Foundation
import NotesCore

struct PaletteBodySearchAttempt {
    let query: String
    let matches: [EditorSearchMatch]?

    func failed(for current: EditorSearchQuery?) -> Bool {
        current?.text == query && matches == nil
    }
}

struct PaletteFolder: Hashable {
    let account: String
    let path: [String]
    let id: String?

    init(_ note: NoteSummary) {
        account = note.accountID
        path = note.folderPath
        id = note.folderID.flatMap { $0.isEmpty ? nil : $0 }
    }

    var label: String { path.joined(separator: " › ") }

    static func choices(in notes: [NoteSummary]) -> [Self] {
        Set(notes.lazy.filter { !$0.isDeleted && !$0.folderPath.isEmpty }.map(Self.init)).sorted {
            let order = $0.label.localizedStandardCompare($1.label)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.path != $1.path { return $0.path.lexicographicallyPrecedes($1.path) }
            if $0.account != $1.account { return $0.account < $1.account }
            return ($0.id ?? "") < ($1.id ?? "")
        }
    }
}

enum PaletteSort: String, CaseIterable {
    case editedNewest = "Edited: newest first"
    case editedOldest = "Edited: oldest first"
    case createdNewest = "Created: newest first"
    case createdOldest = "Created: oldest first"
    case titleAscending = "Title A–Z"
    case titleDescending = "Title Z–A"
    case folderAscending = "Folder A–Z"
    case folderDescending = "Folder Z–A"

    func precedes(_ lhs: NoteSummary, _ rhs: NoteSummary) -> Bool {
        switch self {
        case .editedNewest, .editedOldest, .createdNewest, .createdOldest:
            let created = self == .createdNewest || self == .createdOldest
            let descending = self == .createdNewest || self == .editedNewest
            let left = created ? lhs.created : lhs.modified
            let right = created ? rhs.created : rhs.modified
            switch (left, right) {
            case let (l?, r?) where l != r: return descending ? l > r : l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
        case .titleAscending, .titleDescending, .folderAscending, .folderDescending:
            let byFolder = self == .folderAscending || self == .folderDescending
            let left = byFolder ? PaletteFolder(lhs).label : lhs.title
            let right = byFolder ? PaletteFolder(rhs).label : rhs.title
            let order = left.localizedStandardCompare(right)
            let ascending = self == .titleAscending || self == .folderAscending
            if order != .orderedSame { return order == (ascending ? .orderedAscending : .orderedDescending) }
        }
        return lhs.id.uuid < rhs.id.uuid
    }
}

struct PaletteSearch {
    var query: String
    var titleOnly = false
    var folder: PaletteFolder? = nil
    var sort: PaletteSort? = nil

    func results(from notes: [NoteSummary], bodyMatches: Set<String> = []) -> [NoteSummary] {
        let empty = query.allSatisfy(\.isWhitespace)
        let matcher = EditorSearchQuery(query)
        let filtered = notes.filter { note in
            guard !note.isDeleted, folder == nil || folder == PaletteFolder(note) else { return false }
            if empty { return true }
            if matcher?.matches(note, titleOnly: titleOnly) == true { return true }
            return !titleOnly && !note.isLocked && bodyMatches.contains(EditorSearchQuery.identity(note))
        }
        return sort.map { filtered.sorted(by: $0.precedes) } ?? filtered
    }
}
