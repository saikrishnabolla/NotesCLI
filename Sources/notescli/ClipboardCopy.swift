import AppKit
import Foundation
import NotesAutomation
import NotesCore
import NotesHost
import NotesMCP

enum ClipboardCopy {
    static func requireLocalSession(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard CapabilityHostRequest.isLocal(environment) else {
            throw NotesError("clipboard_unavailable", "Copy to the clipboard from a local macOS session.")
        }
    }

    static func write(_ text: String, to pasteboard: NSPasteboard = .general) throws {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else {
            throw NotesError("clipboard_write_failed", "Could not prepare text for the clipboard.")
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw NotesError("clipboard_write_failed", "Could not write to the clipboard.")
        }
    }

    static func report(format: String, fidelity: NotesReadFidelity, options: GlobalOptions) throws {
        if options.json { try Output.json(["copied": format, "fidelity": fidelity.rawValue]) }
        else if !options.quiet {
            print(format == "markdown" ? "Copied Markdown." : "Copied note link.")
        }
    }

    static func markdown(_ note: Note, includeAttachments: Bool) throws -> String {
        try NotePresentation.clipboardMarkdown(note, includeAttachments: includeAttachments)
    }

    static func noteLink(_ id: UUID) -> String {
        "applenotes://showNote?identifier=\(id.uuidString)"
    }

    static func noteLink(_ summary: NoteSummary) throws -> String {
        if let id = UUID(uuidString: summary.id.uuid) { return noteLink(id) }
        if let value = summary.deepLink, let parts = URLComponents(string: value),
           parts.scheme == "applenotes", parts.host == "showNote", parts.path.isEmpty,
           parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
           let query = parts.queryItems, query.count == 1, query[0].name == "identifier",
           let id = query[0].value.flatMap(UUID.init(uuidString:)) {
            return noteLink(id)
        }
        throw NotesError("editor_note_link_unavailable", "No verified URL for this note. Open it in Notes and use Copy Note Link there.")
    }
}
