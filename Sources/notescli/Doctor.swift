import ArgumentParser
import Foundation
import NotesCore
import NotesMCP
import Carbon

func automationPermission() -> String {
    var target = AEAddressDesc()
    let bundle = "com.apple.Notes"
    let created = bundle.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, bundle.utf8.count, &target) }
    guard created == noErr else { return "unknown (cannot address Notes.app)" }
    defer { AEDisposeDesc(&target) }
    let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
    switch status {
    case noErr: return "authorized"
    case OSStatus(-1743): return "denied"
    case OSStatus(-1744): return "not determined (permission prompt required)"
    default: return "unknown (OSStatus \(status))"
    }
}

struct Doctor: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    func run() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
        let access: String
        do {
            let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
            _ = try handle.read(upToCount: 16); access = "readable"
        } catch { access = "unreadable: \((error as NSError).localizedDescription)" }
        var report = ["macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                      "full_disk_access": access,
                      "database_path": path.path,
                      "automation": automationPermission(),
                      "notes_app": FileManager.default.fileExists(atPath: "/System/Applications/Notes.app") || FileManager.default.fileExists(atPath: "/Applications/Notes.app") ? "present" : "missing"]
        do {
            let backend = try options.backends()
            report["accounts"] = String(try backend.reader.accounts().count)
            report["folders"] = String(try backend.reader.folders(account: nil).count)
            report["notes"] = String(try backend.reader.notes(NoteQuery()).count)
        } catch { report["backend_error"] = String(describing: error) }
        if options.json { try Output.json(report) } else { Output.table(["CHECK", "RESULT"], report.keys.sorted().map { [$0, report[$0]!] }) }
    }
}
