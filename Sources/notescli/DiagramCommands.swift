import ArgumentParser
import Foundation
import NotesCore
import NotesDiagrams
import NotesNative
import NotesSafety
import PencilKit

enum DiagramInsertionMode: String, ExpressibleByArgument {
    case image
    case drawing
}

extension DiagramBackground: ExpressibleByArgument {}

struct DiagramOptions: ParsableArguments {
    @Option(name: .customLong("as"), help: "Insert as image or editable drawing.") var insertion: DiagramInsertionMode = .image
    @Option(help: "Diagram width in CSS pixels.") var width = 700
    @Option(help: "Raster scale: 2 or 3.") var scale = 2
    @Option(help: "Page background: white, transparent, or auto.") var background: DiagramBackground = .auto
    @Flag(help: "Render dark-mode CSS and use a dark automatic fallback.") var dark = false

    func renderOptions() throws -> DiagramRenderOptions {
        do { return try DiagramRenderOptions(width: width, scale: scale, background: background, dark: dark) }
        catch let error as DiagramError { throw ValidationError(error.description) }
    }
}

protocol DiagramDrawingAttaching {
    func add(source: DiagramSource, to noteID: String, options: DiagramRenderOptions, allowShared: Bool) throws -> NativeAttachmentResult
    func create(source: DiagramSource, title: String, folder: String, options: DiagramRenderOptions, allowShared: Bool) throws -> NativeCreateResult
}

struct NativeDiagramDrawingAttacher: DiagramDrawingAttaching {
    func add(source: DiagramSource, to noteID: String, options: DiagramRenderOptions, allowShared: Bool) throws -> NativeAttachmentResult {
        try NativeNotesWriter().insertDrawing(noteID, drawing: drawing(source, options: options), position: nil,
                                              allowShared: allowShared)
    }

    func create(source: DiagramSource, title: String, folder: String, options: DiagramRenderOptions, allowShared: Bool) throws -> NativeCreateResult {
        try NativeNotesWriter().createDrawingNote(title: title, folder: folder, drawing: drawing(source, options: options),
                                                  allowShared: allowShared)
    }

    private func drawing(_ source: DiagramSource, options: DiagramRenderOptions) throws -> PKDrawing {
        guard source.mediaType == "image/svg+xml" else {
            throw NotesError("drawing_requires_svg", "Editable Paper diagrams require an SVG file.")
        }
        do {
            let svg = try DiagramDrawingSource.paperCompatibleSVG(source.data)
            let parsed = try SVGDrawingConverter.parse(svg)
            let height = Double(options.width) * parsed.size.height / parsed.size.width
            return try SVGDrawingConverter.drawing(
                from: svg,
                options: SVGDrawingOptions(size: DrawingSize(width: Double(options.width), height: height))
            )
        } catch {
            throw NotesError("invalid_diagram_drawing", error.localizedDescription)
        }
    }
}

struct DiagramWriteService {
    let drawing: any DiagramDrawingAttaching

    init(drawing: any DiagramDrawingAttaching = NativeDiagramDrawingAttacher()) {
        self.drawing = drawing
    }

    func add(file: URL, to noteID: String, options: DiagramRenderOptions, mode: DiagramInsertionMode,
             allowShared: Bool) throws -> (NativeAttachmentResult, DiagramPixelSize?) {
        let source = try diagramSource(file)
        if mode == .drawing { return (try drawing.add(source: source, to: noteID, options: options, allowShared: allowShared), nil) }
        let rendered = try diagramRender(file, options: options)
        let frozen = try FrozenAttachmentInput(data: rendered.png, suggestedName: file.deletingPathExtension().lastPathComponent + ".png")
        return (try NativeNotesWriter().insertFrozenFile(noteID, frozen: frozen, position: nil, imageView: "large", allowShared: allowShared), rendered.pixelSize)
    }

    func create(file: URL, title: String, folder: String, options: DiagramRenderOptions, mode: DiagramInsertionMode,
                allowShared: Bool) throws -> (NativeCreateResult, DiagramPixelSize?) {
        let source = try diagramSource(file)
        if mode == .drawing { return (try drawing.create(source: source, title: title, folder: folder, options: options, allowShared: allowShared), nil) }
        let rendered = try diagramRender(file, options: options)
        let frozen = try FrozenAttachmentInput(data: rendered.png, suggestedName: file.deletingPathExtension().lastPathComponent + ".png")
        return (try NativeNotesWriter().createNote(title: title, markdown: "", folder: folder, attachments: [frozen], allowShared: allowShared), rendered.pixelSize)
    }

    private func diagramSource(_ file: URL) throws -> DiagramSource {
        do { return try DiagramSource(file: file) }
        catch let error as DiagramError { throw NotesError("invalid_diagram", error.description) }
    }

    private func diagramRender(_ file: URL, options: DiagramRenderOptions) throws -> RenderedDiagram {
        do { return try DiagramRenderer().render(file: file, options: options) }
        catch let error as DiagramError { throw NotesError("diagram_render_failed", error.description) }
    }
}

struct DiagramCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagram",
        abstract: "Render SVG or HTML diagrams into Apple Notes.",
        subcommands: [DiagramAdd.self, DiagramCreate.self, DiagramExport.self]
    )
}

struct DiagramAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Render and add a diagram to a note.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @OptionGroup var diagram: DiagramOptions
    @Argument var note: String
    @Option var file: String

    func validate() throws { _ = try diagram.renderOptions() }

    func run() throws {
        let backend = try options.writable()
        try requireDiagramNative()
        let target = try backend.reader.note(note)
        let renderOptions = try diagram.renderOptions()
        let path = diagramFile(file)
        let arguments = diagramArguments(path: path, options: renderOptions, mode: diagram.insertion)
        let plan = DryRunPlan(operation: "diagramAdd", target: target.summary.id.uuid, arguments: arguments,
                              resultingHTML: SafetyExecutor.html(target), engine: "native")
        var captured: NativeAttachmentResult?
        var pixels: DiagramPixelSize?
        let result = try SafetyExecutor.run(options: write, operation: "diagramAdd", arguments: arguments,
            note: target, allowedPaths: [target.summary.folderPath], destructive: true, plan: plan) {
                let value = try DiagramWriteService().add(file: path, to: target.summary.id.uuid, options: renderOptions,
                                                          mode: diagram.insertion, allowShared: write.allowShared)
                captured = value.0
                pixels = value.1
                return value.0.write.writeResult
            }
        guard let result else { return }
        var details = ["attachment_id": captured?.attachmentID ?? "", "source_sha256": captured?.sourceSHA256 ?? "",
                       "stored_sha256": captured?.storedSHA256 ?? ""]
        if let pixels { details["pixels"] = "\(pixels.width)x\(pixels.height)" }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.write.operationID,
                                                  verification: captured?.write.verification, details: details), options: options)
    }
}

struct DiagramCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a note containing a rendered diagram.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @OptionGroup var diagram: DiagramOptions
    @Option var folder: String
    @Option var title: String
    @Option var file: String

    func validate() throws { _ = try diagram.renderOptions() }

    func run() throws {
        let backend = try options.writable()
        try requireDiagramNative()
        let renderOptions = try diagram.renderOptions()
        let path = diagramFile(file)
        var arguments = diagramArguments(path: path, options: renderOptions, mode: diagram.insertion)
        arguments["folder"] = folder
        arguments["title"] = title
        let targetPath = try SafetyExecutor.folderPath(folder, reader: backend.reader)
        let plan = DryRunPlan(operation: "diagramCreate", target: title, arguments: arguments,
                              resultingHTML: SafetyExecutor.bodyHTML(title: title, markdown: ""), engine: "native")
        var captured: NativeCreateResult?
        var pixels: DiagramPixelSize?
        let result = try SafetyExecutor.run(options: write, operation: "diagramCreate", arguments: arguments,
            allowedPaths: targetPath.map { [$0] } ?? [], plan: plan) {
                let value = try DiagramWriteService().create(file: path, title: title, folder: folder, options: renderOptions,
                                                             mode: diagram.insertion, allowShared: write.allowShared)
                captured = value.0
                pixels = value.1
                return value.0.write.writeResult
            }
        guard let result else { return }
        var details = ["attachment_ids": captured?.attachmentIDs.joined(separator: ",") ?? ""]
        if let pixels { details["pixels"] = "\(pixels.width)x\(pixels.height)" }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.write.operationID,
                                                  verification: captured?.write.verification, details: details), options: options)
    }
}

struct DiagramExport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Recover embedded SVG or HTML source from a diagram image.")
    @OptionGroup var options: GlobalOptions
    @Argument var note: String
    @Option var output: String
    @Option var attachmentID: String?

    func run() throws {
        let reader = try options.backends().reader
        let attachments = try reader.attachments(note).filter { attachmentID == nil || $0.id == attachmentID }
        let sources = attachments.compactMap { attachment -> (Attachment, DiagramSource)? in
            guard let path = attachment.filePath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let source = try? DiagramSourceMetadata.extract(from: data) else { return nil }
            return (attachment, source)
        }
        guard !sources.isEmpty else { throw NotesError("diagram_source_not_found", "No diagram image with embedded source was found.") }
        guard sources.count == 1 else {
            throw NotesError("ambiguous_diagram", "The note has more than one diagram. Pass --attachment-id.")
        }
        let target = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: target.path) else { throw NotesError("file_exists", "Refusing to replace an existing file.") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sources[0].1.data.write(to: target, options: .atomic)
        if options.json { try Output.json(["attachment_id": sources[0].0.id, "path": target.path, "filename": sources[0].1.filename]) }
        else { Output.table(["ATTACHMENT", "PATH"], [[sources[0].0.id, target.path]]) }
    }
}

func diagramFile(_ path: String) -> URL {
    URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
}

private func requireDiagramNative() throws {
    guard UnifiedNative.nativeAvailable() else {
        throw NotesError("native_unavailable", "The native Notes framework check failed. Run notescli engine doctor --json.")
    }
}

private func diagramArguments(path: URL, options: DiagramRenderOptions, mode: DiagramInsertionMode) -> [String: String] {
    ["file": path.path, "as": mode.rawValue, "width": String(options.width), "scale": String(options.scale),
     "background": options.background.rawValue, "dark": String(options.dark), "engine": "native"]
}
