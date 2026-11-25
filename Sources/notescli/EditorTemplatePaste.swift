import AppKit
import NotesCore

@MainActor
protocol EditorTemplatePasteboard {
    var changeCount: Int { get }
    var pasteboardItems: [NSPasteboardItem]? { get }
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
    func data(forType dataType: NSPasteboard.PasteboardType) -> Data?
}

extension NSPasteboard: EditorTemplatePasteboard {}

enum EditorTemplateFailure: Equatable {
    case clipboard, unavailable, preparation, unconfirmed

    init(_ error: Error) {
        self = (error as? NotesError)?.code == "template_pasteboard_unavailable" ? .clipboard : .preparation
    }

    var message: String {
        switch self {
        case .clipboard: "Couldn’t preserve the clipboard. Try copying plain text first."
        case .unavailable: "Paste is unavailable in Notes."
        case .preparation: "Couldn’t prepare this template."
        case .unconfirmed: "Check the note before trying the template again."
        }
    }

    var event: EditorDiagnosticEvent {
        switch self {
        case .clipboard, .unavailable: .templatePasteUnavailable
        case .preparation: .templatePreparationFailed
        case .unconfirmed: .templateInsertionUnconfirmed
        }
    }
}

@MainActor
enum EditorTemplatePaste {
    static func confirmInsertion(sample: String, at location: Int, stillStaged: () -> Bool,
                                 read: (NSRange) -> (selection: NSRange, text: String?)?,
                                 pause: () -> Void = {
                                     _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.025))
                                 }) -> Bool {
        guard !sample.isEmpty else { return false }
        let range = NSRange(location: location, length: sample.utf16.count)
        let deadline = ContinuousClock.now + .milliseconds(900)
        repeat {
            // The untouched slash command can already match the sample while still selected.
            if let state = read(range), state.selection.length == 0,
               state.selection.location >= NSMaxRange(range), state.text == sample {
                return true
            }
            guard stillStaged() else { return false }
            pause()
        } while ContinuousClock.now < deadline
        return false
    }

    static func withMarkdown<T>(_ markdown: String, on board: NSPasteboard = .general,
                                perform: (_ stillStaged: () -> Bool) throws -> T) throws -> T {
        try withData(Data(markdown.utf8), type: .string, on: board, perform: perform)
    }

    static func withData<T>(_ data: Data, type: NSPasteboard.PasteboardType,
                            on board: any EditorTemplatePasteboard = NSPasteboard.general,
                            perform: (_ stillStaged: () -> Bool) throws -> T) throws -> T {
        let unavailable = NotesError("template_pasteboard_unavailable",
                                     "The clipboard could not be preserved. No template was pasted.")
        let initialChange = board.changeCount
        guard let items = board.pasteboardItems else { throw unavailable }
        var saved: [NSPasteboardItem] = []
        var bytes = 0
        for item in items {
            let copy = NSPasteboardItem()
            guard !item.types.isEmpty, item.types.count <= 64, saved.count < 128 else { throw unavailable }
            for type in item.types {
                guard !type.rawValue.localizedCaseInsensitiveContains("promised"),
                      let value = item.data(forType: type), value.count <= 16_777_216 - bytes,
                      copy.setData(value, forType: type) else { throw unavailable }
                bytes += value.count
            }
            saved.append(copy)
        }
        let payload = NSPasteboardItem()
        guard payload.setData(data, forType: type), board.changeCount == initialChange else { throw unavailable }
        // This count belongs to our clear operation. A later count may belong to another copy.
        let staged = board.prepareForNewContents(with: .currentHostOnly)
        defer {
            if board.changeCount == staged {
                let restoring = board.prepareForNewContents(with: .currentHostOnly)
                if !saved.isEmpty, board.changeCount == restoring, !board.writeObjects(saved) {
                    EditorDiagnostics.record(.clipboardRestoreFailed)
                    Output.error("The template was processed, but macOS could not restore the previous clipboard.")
                }
            }
        }
        guard board.changeCount == staged, board.writeObjects([payload]),
              board.changeCount == staged, board.data(forType: type) == data,
              board.changeCount == staged else { throw unavailable }
        return try perform { board.changeCount == staged }
    }
}
