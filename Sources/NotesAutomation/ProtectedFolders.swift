import Foundation
import NotesCore

/// Read localization data, not private framework code. Notes' dictionary has no trash flag.
/// Keep every translation so a per-app language override cannot permit a second delete.
enum ProtectedFolders {
    static let names: [String]? = loadNames()

    private static func loadNames() -> [String]? {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/NotesShared.framework"),
              let resources = bundle.resourceURL else { return nil }
        var names: Set<String> = ["Recently Deleted", "Trash"]
        var found = false
        let table = resources.appendingPathComponent("Localizable.loctable")
        if let data = try? Data(contentsOf: table),
           let locales = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] {
            for values in locales.values {
                if let name = values["Recently Deleted"] as? String { names.insert(name); found = true }
            }
        }
        for locale in bundle.localizations {
            let table = resources.appendingPathComponent(locale + ".lproj/Localizable.strings")
            if let data = try? Data(contentsOf: table),
               let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
               let name = values["Recently Deleted"] {
                names.insert(name); found = true
            }
        }
        return found ? names.sorted() : nil
    }
}
