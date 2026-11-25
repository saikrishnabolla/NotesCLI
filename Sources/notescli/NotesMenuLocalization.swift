import Foundation

struct NotesMenuLocalization {
    let tables: [[String: String]]

    static let system: Self = {
        let app = URL(fileURLWithPath: "/System/Applications/Notes.app/Contents/Resources", isDirectory: true)
        let framework = URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/NotesShared.framework/Versions/A/Resources", isDirectory: true)
        let menus = load("MainMenu", at: app)
        let commands = load("Localizable", at: framework)
        return Self(tables: menus.keys.sorted().compactMap { locale in
            guard var menu = menus[locale] else { return nil }
            menu["Edit Link"] = commands[locale]?["Edit Link"]
            return menu
        })
    }()

    // MainMenu.nib links these title keys to the base English items. Use the
    // menu item's key, not the separate title of its attached NSMenu.
    private static let keys: [String: String] = [
        "Format": "GEO-Iw-cKr.title",
        "Edit": "W48-6f-4Dl.title",
        "Font": "WyT-9z-bfY.title",
        "Title": "oce-6a-cN8.title",
        "Heading": "5IP-Ek-bcg.title",
        "Subheading": "emP-7O-okD.title",
        "Body": "fII-oV-esn.title",
        "Monostyled": "REH-G2-7es.title",
        "Bulleted List": "5h3-qH-Ju1.title",
        "Dashed List": "rHH-0v-VPf.title",
        "Numbered List": "Z9N-gZ-asb.title",
        "Block Quote": "SYb-re-FAl.title",
        "Checklist": "0k5-yT-OP8.title",
        "Table": "Zi8-wQ-nUp.title",
        "Bold": "NM1-sI-BQl.title",
        "Italic": "W2n-hZ-JWD.title",
        "Underline": "8NR-c7-aM6.title",
        "Strikethrough": "RYE-hr-XlQ.title",
        "Bigger": "AnI-ls-S7p.title",
        "Smaller": "TeX-vA-egv.title",
        "Alignment": "6Np-fE-QeT.title",
        "Text": "6Np-fE-QeT.title",
        "Align Left": "lD1-Ya-q1h.title",
        "Center": "nEa-qR-E4M.title",
        "Align Right": "dRi-1l-P91.title",
        "Justify": "JH3-Y8-f2v.title",
        "Highlight": "pXe-i9-USr.title",
        "Add Link…": "lrv-AU-get.title",
        "Edit Link": "Edit Link",
        "Paste": "gVA-U4-sdL.title",
        "Paste as Markdown": "6Ta-KT-c2V.title",
    ]

    func paths(for english: [String]) -> [[String]] {
        let pathKeys = english.compactMap { Self.keys[$0] }
        guard pathKeys.count == english.count else { return [english] }
        var paths: [[String]] = [english]
        for table in tables {
            let translated = pathKeys.compactMap { table[$0] }.filter { !$0.isEmpty }
            if translated.count == english.count, !paths.contains(translated) { paths.append(translated) }
        }
        return paths
    }

    private static func load(_ name: String, at resources: URL) -> [String: [String: String]] {
        func propertyList(_ file: URL) -> Any? {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        if let locales = propertyList(resources.appendingPathComponent(name + ".loctable")) as? [String: Any] {
            return locales.reduce(into: [:]) { result, entry in
                if entry.key != "LocProvenance", let values = entry.value as? [String: String] {
                    result[entry.key] = values
                }
            }
        }
        let directories = (try? FileManager.default.contentsOfDirectory(at: resources,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return directories.filter { $0.pathExtension == "lproj" }.reduce(into: [:]) { result, locale in
            result[locale.deletingPathExtension().lastPathComponent] =
                propertyList(locale.appendingPathComponent(name + ".strings")) as? [String: String]
        }
    }
}
