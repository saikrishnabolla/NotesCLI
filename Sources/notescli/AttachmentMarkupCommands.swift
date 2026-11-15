import ArgumentParser
import Foundation
import NotesCore
import NotesNative

struct AttachmentMarkupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "markup",
        abstract: "Inspect or edit image and PDF markup.",
        subcommands: [AttachmentMarkupInspect.self, AttachmentMarkupExport.self, AttachmentMarkupSet.self,
                      AttachmentMarkupCopy.self, AttachmentMarkupClear.self, AttachmentMarkupList.self,
                      AttachmentMarkupAdd.self, AttachmentMarkupRemove.self, AttachmentMarkupRender.self]
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

struct AttachmentMarkupList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List individual editable markup annotations.")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Argument var attachmentID: String

    func run() throws {
        let backend = try options.backends()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        guard !backend.isFake else { throw NotesError("native_unavailable", "Editable markup is unavailable with the fake backend.") }
        let stableRef = try backend.reader.summary(ref).id.uuid
        let values = try NativeNotesWriter().attachmentMarkupAnnotations(stableRef, attachmentID: attachmentID)
        if options.json { try Output.json(EngineMarkupReadResponse(engine: "native", result: values)) }
        else { Output.table(["ID", "TYPE", "PAGE", "X", "Y", "WIDTH", "HEIGHT", "TEXT"], values.map {
            [$0.id, $0.type, String($0.page), String($0.x), String($0.y), String($0.width), String($0.height), $0.text ?? ""]
        }) }
    }
}

struct AttachmentMarkupAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a basic editable markup annotation.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var attachmentID: String
    @Argument(help: "text, rectangle, oval, arrow, line, ink, or highlight.") var kind: String
    @Option var x: Double = 0
    @Option var y: Double = 0
    @Option var width: Double = 0
    @Option var height: Double = 0
    @Option var text: String?
    @Option(help: "Ink point as X,Y. Repeat at least twice.") var point: [String] = []
    @Option(name: .customLong("stroke-width")) var strokeWidth: Double = 2
    @Option(help: "RRGGBB or RRGGBBAA.") var color = "007aff"

    func run() throws {
        let points = try point.map { value -> ScanPoint in
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                throw ValidationError("Each --point must be X,Y.")
            }
            return ScanPoint(x: x, y: y)
        }
        guard let annotationKind = AttachmentMarkupAnnotationKind(rawValue: kind) else {
            throw ValidationError("Use text, rectangle, oval, arrow, line, ink, or highlight.")
        }
        let input = AttachmentMarkupAnnotationInput(kind: annotationKind, x: x, y: y, width: width, height: height,
                                                     text: text, points: points, strokeWidth: strokeWidth, color: color)
        try input.validate()
        try UnifiedNative.noteWrite(
            options: options, write: write, ref: ref, operation: "attachmentMarkupAdd",
            arguments: ["attachment_id": attachmentID, "kind": annotationKind.rawValue, "color": color]
        ) { stableRef in
            NativeActionResult(try NativeNotesWriter().addAttachmentMarkupAnnotation(
                stableRef, attachmentID: attachmentID, input: input, allowShared: write.allowShared
            ))
        }
    }
}

struct AttachmentMarkupRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove one editable markup annotation.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Argument var attachmentID: String
    @Argument var annotationID: String

    func run() throws {
        try UnifiedNative.noteWrite(
            options: options, write: write, ref: ref, operation: "attachmentMarkupRemove",
            arguments: ["attachment_id": attachmentID, "annotation_id": annotationID]
        ) { stableRef in
            NativeActionResult(try NativeNotesWriter().removeAttachmentMarkupAnnotation(
                stableRef, attachmentID: attachmentID, identifier: annotationID, allowShared: write.allowShared
            ))
        }
    }
}

private struct AttachmentMarkupRenderResponse: Encodable { var path: String; var byteCount: Int }

struct AttachmentMarkupRender: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "render", abstract: "Render editable markup to a PNG preview.")
    @OptionGroup var options: GlobalOptions
    @Argument var ref: String
    @Argument var attachmentID: String
    @Argument var output: String

    func run() throws {
        let backend = try options.backends()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        guard !backend.isFake else { throw NotesError("native_unavailable", "Editable markup is unavailable with the fake backend.") }
        let stableRef = try backend.reader.summary(ref).id.uuid
        let data = try NativeNotesWriter().renderAttachmentMarkup(stableRef, attachmentID: attachmentID)
        let target = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath).standardizedFileURL
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: target, options: .withoutOverwriting) }
        catch CocoaError.fileWriteFileExists { throw NotesError("file_exists", "Refusing to replace an existing render file.") }
        let response = AttachmentMarkupRenderResponse(path: target.path, byteCount: data.count)
        if options.json { try Output.json(response) }
        else { Output.table(["BYTES", "PATH"], [[String(data.count), target.path]]) }
    }
}
