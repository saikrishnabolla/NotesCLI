import ArgumentParser
import Foundation
import NotesCore
import NotesNative
import NotesSafety
import PencilKit

extension DrawingInk: ExpressibleByArgument {}
extension SVGFillMode: ExpressibleByArgument {}
extension SVGFit: ExpressibleByArgument {}

struct DrawingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "drawing", abstract: "Create and export editable Apple Notes drawings.",
                                                    subcommands: [DrawingAdd.self, DrawingCreate.self, DrawingExport.self])
}

struct DrawingInputOptions: ParsableArguments {
    @Option(help: "SVG file to convert.") var svg: String
    @Option(help: "Ink: pen, marker, pencil, or monoline.") var ink: DrawingInk = .pen
    @Option(help: "Override all stroke widths.") var width: Double?
    @Option(help: "Override all colors with #RRGGBB.") var color: String?
    @Flag(help: "Convert all strokes to black.") var bw = false
    @Option(help: "Output canvas size as WIDTHxHEIGHT.") var size: String?
    @Option(help: "Fit mode: contain or stretch.") var fit: SVGFit = .contain
    @Option(help: "Filled-shape mode: outline or hatch.") var fill: SVGFillMode = .outline

    func load() throws -> PKDrawing {
        if let width, width <= 0 { throw ValidationError("--width must be greater than zero.") }
        let url = URL(fileURLWithPath: NSString(string: svg).expandingTildeInPath)
        return try SVGDrawingConverter.drawing(contentsOf: url, options: SVGDrawingOptions(
            ink: ink, width: width, color: try color.map(Self.parseColor), blackAndWhite: bw,
            size: try size.map(Self.parseSize), fit: fit, fill: fill))
    }

    private static func parseSize(_ value: String) throws -> DrawingSize {
        let parts = value.lowercased().split(separator: "x", maxSplits: 1).compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw ValidationError("--size must be WIDTHxHEIGHT with positive numbers.") }
        return DrawingSize(width: parts[0], height: parts[1])
    }

    private static func parseColor(_ value: String) throws -> DrawingColor {
        let text = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard text.count == 6, let rgb = UInt32(text, radix: 16) else { throw ValidationError("--color must be a six-digit hex color.") }
        return DrawingColor(red: Double((rgb >> 16) & 255) / 255,
                            green: Double((rgb >> 8) & 255) / 255,
                            blue: Double(rgb & 255) / 255)
    }

    var journalArguments: [String: String] {
        ["svg": NSString(string: svg).expandingTildeInPath, "ink": ink.rawValue,
         "width": width.map { String($0) } ?? "", "color": color ?? "", "bw": String(bw),
         "size": size ?? "", "fit": fit.rawValue, "fill": fill.rawValue]
    }
}

struct DrawingAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add an editable Paper drawing to a note.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var note: String
    @OptionGroup var input: DrawingInputOptions

    func run() throws {
        let backend = try options.writable()
        guard UnifiedNative.nativeAvailable() else { throw NotesError("native_unavailable", "The native Notes framework check failed. Run notescli engine doctor --json.") }
        let target = try backend.reader.note(note), drawing = try input.load()
        let arguments = input.journalArguments.merging(["ref": target.summary.id.uuid, "engine": "native"]) { $1 }
        let plan = DryRunPlan(operation: "drawingAdd", target: target.summary.id.uuid, arguments: arguments,
                              resultingHTML: SafetyExecutor.html(target), engine: "native")
        var captured: NativeAttachmentResult?
        let result = try SafetyExecutor.run(options: write, operation: "drawingAdd", arguments: arguments,
            note: target, allowedPaths: [target.summary.folderPath], plan: plan) {
                let value = try NativeNotesWriter().insertDrawing(target.summary.id.uuid, drawing: drawing,
                                                                  position: nil, allowShared: write.allowShared)
                captured = value
                return value.write.writeResult
            }
        guard let result else { return }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.write.operationID,
                                                  verification: captured?.write.verification,
                                                  details: captured.map { ["attachment_id": $0.attachmentID, "type_uti": $0.typeUTI,
                                                                            "strokes": String(drawing.strokes.count)] }), options: options)
    }
}

struct DrawingCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a note containing an editable Paper drawing.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option var folder: String
    @Option var title: String
    @OptionGroup var input: DrawingInputOptions

    func run() throws {
        let backend = try options.writable()
        guard UnifiedNative.nativeAvailable() else { throw NotesError("native_unavailable", "The native Notes framework check failed. Run notescli engine doctor --json.") }
        let drawing = try input.load()
        let paths = try SafetyExecutor.folderPath(folder, reader: backend.reader).map { [$0] } ?? []
        let arguments = input.journalArguments.merging(["folder": folder, "title": title, "engine": "native"]) { $1 }
        let plan = DryRunPlan(operation: "drawingCreate", target: title, arguments: arguments,
                              resultingHTML: SafetyExecutor.bodyHTML(title: title, markdown: ""), engine: "native")
        var captured: NativeCreateResult?
        let result = try SafetyExecutor.run(options: write, operation: "drawingCreate", arguments: arguments,
            allowedPaths: paths, plan: plan) {
                let value = try NativeNotesWriter().createDrawingNote(title: title, folder: folder, drawing: drawing,
                                                                      allowShared: write.allowShared)
                captured = value
                return value.write.writeResult
            }
        guard let result else { return }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.write.operationID,
                                                  verification: captured?.write.verification,
                                                  details: ["attachment_id": captured?.attachmentIDs.first ?? "",
                                                            "strokes": String(drawing.strokes.count)]), options: options)
    }
}

enum DrawingExportFormat: String, ExpressibleByArgument { case svg, png }

struct DrawingExport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export editable Paper strokes.")
    @OptionGroup var options: GlobalOptions
    @Argument var note: String
    @Option var format: DrawingExportFormat = .svg
    @Option var attachment: String?
    @Option var output: String?

    func run() throws {
        guard UnifiedNative.nativeAvailable() else { throw NotesError("native_unavailable", "The native Notes framework check failed. Run notescli engine doctor --json.") }
        let stableID = try options.backends().reader.summary(note).id.uuid
        let attachments = try NativeNotesWriter().paperDrawings(stableID, attachmentID: attachment)
        let drawings = attachments.flatMap(\.drawings)
        let data: Data
        switch format {
        case .svg:
            data = Data(SVGDrawingConverter.svg(from: drawings).utf8)
        case .png:
            data = try SVGDrawingConverter.png(from: drawings)
        }
        if let output {
            let url = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
            try data.write(to: url, options: .atomic)
            if options.json { try Output.json(["output": url.path, "format": format.rawValue, "attachments": String(attachments.count)]) }
            else if !options.quiet { print(url.path) }
        } else if format == .svg {
            print(String(decoding: data, as: UTF8.self))
        } else {
            throw NotesError("invalid_output", "PNG export requires --output.")
        }
    }

}
