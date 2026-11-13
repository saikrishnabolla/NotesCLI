import Foundation
import NotesCore

/// Read localization data, not private framework code. Notes' dictionary has no trash flag.
/// Keep every translation so a per-app language override cannot permit a second delete.
enum ProtectedFolders {
    static let names: [String]? = loadNames(from: Bundle(path: "/System/Library/PrivateFrameworks/NotesShared.framework"))

    /// Locale folders may hold no `Localizable.strings` once Apple moves strings into the
    /// `.loctable`. Look files up through the bundle and read them with `NSDictionary`, so a
    /// missing file is skipped without raising an error a test runner could report.
    static func loadNames(from bundle: Bundle?) -> [String]? {
        guard let bundle else { return nil }
        var names: Set<String> = ["Recently Deleted", "Trash"]
        var found = false
        if let url = bundle.url(forResource: "Localizable", withExtension: "loctable"),
           let locales = NSDictionary(contentsOf: url) as? [String: Any] {
            for case let values as [String: Any] in locales.values {
                if let name = values["Recently Deleted"] as? String { names.insert(name); found = true }
            }
        }
        for locale in bundle.localizations {
            if let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: locale),
               let values = NSDictionary(contentsOf: url) as? [String: Any],
               let name = values["Recently Deleted"] as? String {
                names.insert(name); found = true
            }
        }
        return found ? names.sorted() : nil
    }
}
