import Foundation

public struct AppleNotesLinkTarget: Equatable, Sendable {
    public var identifier: String
    public var paragraphID: String?

    public init(identifier: String, paragraphID: String?) {
        self.identifier = identifier
        self.paragraphID = paragraphID
    }

    public static func parse(_ token: String?) -> AppleNotesLinkTarget? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let nativePrefix = "applenotes:note/"
        if trimmed.lowercased().hasPrefix(nativePrefix) {
            let start = trimmed.index(trimmed.startIndex, offsetBy: nativePrefix.count)
            let suffix = trimmed[start...]
            let end = suffix.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? suffix.endIndex
            let identifier = String(suffix[..<end]).removingPercentEncoding ?? ""
            guard !identifier.isEmpty, !identifier.contains("/") else {
                return AppleNotesLinkTarget(identifier: trimmed, paragraphID: nil)
            }
            let query = end < suffix.endIndex && suffix[end] == "?" ? String(suffix[suffix.index(after: end)...]) : ""
            let paragraphID = URLComponents(string: "https://notes.invalid/?\(query)")?.queryItems?
                .first(where: { $0.name.caseInsensitiveCompare("paragraphID") == .orderedSame })?.value
            return AppleNotesLinkTarget(identifier: identifier, paragraphID: paragraphID)
        }
        guard let components = URLComponents(string: trimmed),
              components.scheme?.caseInsensitiveCompare("applenotes") == .orderedSame else {
            return AppleNotesLinkTarget(identifier: trimmed, paragraphID: nil)
        }
        if components.host?.caseInsensitiveCompare("showNote") == .orderedSame {
            let identifier = components.queryItems?
                .first(where: { $0.name.caseInsensitiveCompare("identifier") == .orderedSame })?.value ?? ""
            guard !identifier.isEmpty else { return AppleNotesLinkTarget(identifier: trimmed, paragraphID: nil) }
            let paragraphID = components.queryItems?
                .first(where: { $0.name.caseInsensitiveCompare("paragraphID") == .orderedSame })?.value
            return AppleNotesLinkTarget(identifier: identifier, paragraphID: paragraphID)
        }
        guard components.host?.caseInsensitiveCompare("note") == .orderedSame else {
            return AppleNotesLinkTarget(identifier: trimmed, paragraphID: nil)
        }
        let identifier = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .removingPercentEncoding ?? ""
        guard !identifier.isEmpty, !identifier.contains("/") else {
            return AppleNotesLinkTarget(identifier: trimmed, paragraphID: nil)
        }
        let paragraphID = components.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("paragraphID") == .orderedSame })?.value
        return AppleNotesLinkTarget(identifier: identifier, paragraphID: paragraphID)
    }

    public static func identifier(from token: String?) -> String? {
        parse(token)?.identifier
    }
}
