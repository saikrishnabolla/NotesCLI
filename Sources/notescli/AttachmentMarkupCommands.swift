import ArgumentParser
import Foundation
import NotesCore
import NotesNative

struct AttachmentMarkupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "markup",
        abstract: "Inspect, export, set, copy, or clear editable image and PDF markup.",
        subcommands: [AttachmentMarkupInspect.self, AttachmentMarkupExport.self, AttachmentMarkupSet.self,
                      AttachmentMarkupCopy.self, AttachmentMarkupClear.self]
    )
}

struct AttachmentMarkupInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Inspect bounded editable markup metadata.")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Argument var attachmentID: String

    func run() throws {
        let backend = try options.backends()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        guard !backend.isFake else { throw NotesError("native_unavailable", "Editable markup is unavailable with the fake backend.") }
        let stableRef = try backend.reader.summary(ref).id.uuid
        try Output.json(EngineMarkupReadResponse(engine: "native", result: try NativeNotesWriter()
            .attachmentMarkupMetadata(stableRef, attachmentID: attachmentID)))
    }
}

private struct EngineMarkupReadResponse<T: Encodable>: Encodable {
    var engine: String
    var result: T
}

private struct AttachmentMarkupExportResponse: Encodable {
    var metadata: NativeAttachmentMarkupMetadata
    var path: String
}

struct AttachmentMarkupExport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export an attachment's bounded editable markup payload.")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Argument var attachmentID: String
    @Argument var output: String

    func run() throws {
        let backend = try options.backends()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        guard !backend.isFake else { throw NotesError("native_unavailable", "Editable markup is unavailable with the fake backend.") }
        let stableRef = try backend.reader.summary(ref).id.uuid
        let value = try NativeNotesWriter().attachmentMarkupData(stableRef, attachmentID: attachmentID)
        let target = try value.write(to: URL(fileURLWithPath: NSString(string: output).expandingTildeInPath))
        let response = AttachmentMarkupExportResponse(metadata: value.metadata, path: target.path)
        if options.json { try Output.json(response) }
        else { Output.table(["ATTACHMENT", "BYTES", "SHA256", "PATH"],
                            [[value.metadata.attachmentID, String(value.metadata.byteCount),
                              value.metadata.sha256 ?? "", target.path]]) }
    }
}

struct AttachmentMarkupSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set recognized editable markup from a frozen file.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var attachmentID: String
    @Argument var path: String
    @Flag(help: "Mark the payload as embedded in the attachment.") var embedded = false

    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        guard !backend.isFake else { throw NotesError("native_unavailable", "Editable markup is unavailable with the fake backend.") }
        let source = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let frozen = try FrozenAttachmentMarkup(file: source)
        try UnifiedNative.noteWrite(
            options: options, write: write, ref: ref, operation: "attachmentMarkupSet",
            arguments: ["attachment_id": attachmentID, "markup_sha256": frozen.sha256,
                        "markup_bytes": String(frozen.byteCount), "embedded": String(embedded)]
        ) { stableRef in
            NativeActionResult(try NativeNotesWriter().setAttachmentMarkup(
                stableRef, attachmentID: attachmentID, payload: frozen,
                embedded: embedded, allowShared: write.allowShared
            ))
        }
    }
}

struct AttachmentMarkupCopy: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "copy", abstract: "Copy recognized editable markup from another attachment.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var attachmentID: String
    @Argument var sourceRef: String
    @Argument var sourceAttachmentID: String

    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        guard !backend.isFake else { throw NotesError("native_unavailable", "Editable markup is unavailable with the fake backend.") }
        let stableSourceRef = try backend.reader.summary(sourceRef).id.uuid
        try UnifiedNative.noteWrite(
            options: options, write: write, ref: ref, operation: "attachmentMarkupCopy",
            arguments: ["attachment_id": attachmentID, "source_ref": stableSourceRef,
                        "source_attachment_id": sourceAttachmentID]
        ) { stableRef in
            NativeActionResult(try NativeNotesWriter().copyAttachmentMarkup(
                stableRef, attachmentID: attachmentID, sourceRef: stableSourceRef,
                sourceAttachmentID: sourceAttachmentID, allowShared: write.allowShared
            ))
        }
    }
}

struct AttachmentMarkupClear: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Clear editable markup from an image or PDF attachment.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var attachmentID: String

    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        guard !backend.isFake else { throw NotesError("native_unavailable", "Editable markup is unavailable with the fake backend.") }
        try UnifiedNative.noteWrite(
            options: options, write: write, ref: ref, operation: "attachmentMarkupClear",
            arguments: ["attachment_id": attachmentID]
        ) { stableRef in
            NativeActionResult(try NativeNotesWriter().clearAttachmentMarkup(
                stableRef, attachmentID: attachmentID, allowShared: write.allowShared
            ))
        }
    }
}
