import Foundation
import NotesCore

public struct WriteAllowlist: Sendable {
    public let roots: [[String]]

    public init(_ value: String?) {
        roots = (value ?? "").split(separator: ",").compactMap { item in
            let parts = item.split(separator: ">").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return parts.isEmpty || parts.contains(where: \ .isEmpty) ? nil : parts
        }
    }

    public var isRestricted: Bool { !roots.isEmpty }

    public func allows(_ path: [String]) -> Bool {
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
