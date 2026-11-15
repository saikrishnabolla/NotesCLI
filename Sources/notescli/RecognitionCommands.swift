import ArgumentParser
import Foundation
import NotesCore
import NotesNative

struct OCRCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr",
        abstract: "Recognize text in a downloaded image attachment without changing Apple Notes."
    )

    @OptionGroup var options: GlobalOptions
    @Argument(help: "Note reference.") var note: String
    @Option(help: "Image attachment ID. Required when the note has more than one image.") var attachment: String?
    @Option(name: .customLong("language"), help: "Recognition language such as en-US. Repeat for multiple languages.")
    var languages: [String] = []
    @Option(help: "Optional title supplied to the recognizer.") var title: String?

    func run() throws {
        let backend = try options.backends()
        let loaded = try backend.reader.note(note)
        let selected = try OCRAttachmentResolver.resolve(loaded.attachments, attachmentID: attachment)
        guard let path = selected.filePath else {
            throw NotesError("attachment_unavailable", "The image attachment is not downloaded.")
        }
        let result = try OCRRecognition.recognize(
            fileURL: URL(fileURLWithPath: path),
            languages: languages.isEmpty ? nil : languages,
            title: title ?? selected.title
        )
        if options.json {
            try Output.json(result)
        } else if !options.quiet {
            print(result.text)
        }
    }
}

struct HandwritingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "handwriting",
        abstract: "Recognize and manage native Paper handwriting text.",
        subcommands: [HandwritingRecognize.self, HandwritingSet.self]
    )
}

struct HandwritingRecognize: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recognize",
        abstract: "Recognize editable Paper strokes, optionally storing the result in Notes."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Note reference.") var note: String
    @Option(help: "Paper attachment ID.") var attachment: String
    @Option(help: "Recognition locale, such as en-US.") var locale = "en-US"
    @Flag(help: "Store the recognized text in Apple Notes.") var persist = false

    func run() throws {
        let writer = NativeNotesWriter()
        if persist {
            try UnifiedNative.noteWrite(
                options: options,
                write: write,
                ref: note,
                operation: "recognizeHandwriting",
                arguments: ["attachment_id": attachment, "locale": locale],
                native: { stable in
                    NativeActionResult(try writer.recognizeAndPersistHandwriting(
                        stable,
                        attachmentID: attachment,
                        locale: locale,
                        allowShared: write.allowShared
                    ))
                }
            )
            return
        }
        try UnifiedNative.requireNative(options)
        let stable = try options.backends().reader.summary(note).id.uuid
        let value = try writer.recognizeHandwriting(stable, attachmentID: attachment, locale: locale)
        if options.json { try Output.json(value) }
        else if !options.quiet { print(value.text) }
    }
}

struct HandwritingSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Replace or clear the stored handwriting text for a Paper attachment."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Note reference.") var note: String
    @Option(help: "Paper attachment ID.") var attachment: String
    @Option(help: "Text to store. Omit with --clear.") var text: String?
    @Flag(help: "Clear the stored handwriting text.") var clear = false

    func validate() throws {
        guard clear != (text != nil) else {
            throw ValidationError("Provide exactly one of --text or --clear.")
        }
    }

    func run() throws {
        try UnifiedNative.noteWrite(
            options: options,
            write: write,
            ref: note,
            operation: "setHandwritingSummary",
            arguments: ["attachment_id": attachment, "summary": clear ? "" : text!],
            native: { stable in
                NativeActionResult(try NativeNotesWriter().setHandwritingSummary(
                    stable,
                    attachmentID: attachment,
                    summary: clear ? nil : text,
                    allowShared: write.allowShared
                ))
            }
        )
    }
}

struct PaperCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paper",
        abstract: "Manage native Paper PDF and scan attachments.",
        subcommands: [PaperAdd.self, PaperRegenerateFallback.self]
    )
}

struct PaperAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Convert a PDF or image into a native editable Paper document."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Note reference.") var note: String
    @Argument(help: "Local PDF or image path.") var file: String
    @Option(help: "Native Paper subtype: pdf or scan.") var subtype = "pdf"
    @Option(help: "UTF-16 insertion position. Defaults to the end.") var position: Int?

    func run() throws {
        let frozen = try FrozenAttachmentInput(file: URL(fileURLWithPath: file))
        try UnifiedNative.noteWrite(
            options: options,
            write: write,
            ref: note,
            operation: "addPaperDocument",
            arguments: ["path": frozen.url.path, "subtype": subtype, "position": position.map(String.init) ?? "end"],
            native: { stable in
                NativeActionResult(try NativeNotesWriter().insertPaperDocument(
                    stable,
                    frozen: frozen,
                    subtype: subtype,
                    position: position,
                    allowShared: write.allowShared
                ))
            }
        )
    }
}

struct PaperRegenerateFallback: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "regenerate-fallback",
        abstract: "Regenerate a Paper attachment's fallback PDF."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Note reference.") var note: String
    @Option(help: "Paper attachment ID.") var attachment: String

    func run() throws {
        try UnifiedNative.noteWrite(
            options: options,
            write: write,
            ref: note,
            operation: "regenerateFallbackPDF",
            arguments: ["attachment_id": attachment],
            native: { stable in
                NativeActionResult(try NativeNotesWriter().regenerateFallbackPDF(
                    stable,
                    attachmentID: attachment,
                    allowShared: write.allowShared
                ))
            }
        )
    }
}
