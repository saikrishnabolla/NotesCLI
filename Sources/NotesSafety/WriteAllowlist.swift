import Foundation
import NotesCore

public struct WriteAllowlist: Sendable {
    public let roots: [[String]]
    public let isValid: Bool

    public init(_ value: String?) {
        let source = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            roots = []
            isValid = true
            return
        }
        let items = source.split(separator: ",", omittingEmptySubsequences: false)
        let parsed = items.compactMap { item -> [String]? in
            let parts = item.split(separator: ">", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return parts.contains(where: \.isEmpty) ? nil : parts
        }
        isValid = parsed.count == items.count
        roots = isValid ? parsed : []
    }

    public var isRestricted: Bool { !isValid || !roots.isEmpty }

    public func allows(_ path: [String]) -> Bool {
        guard isValid else { return false }
        guard isRestricted else { return true }
        return roots.contains { root in
            guard path.count >= root.count else { return false }
            return zip(path, root).allSatisfy { value, expected in
                value.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(expected.precomposedStringWithCanonicalMapping) == .orderedSame
            }
        }
    }

    public func require(_ path: [String]) throws {
        guard allows(path) else {
            throw NotesError("write_not_allowed", "Writes are not allowed in folder \(path.joined(separator: " > ")).")
        }
    }
}
