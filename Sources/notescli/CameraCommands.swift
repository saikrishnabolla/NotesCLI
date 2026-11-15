import ArgumentParser
import Foundation
import NotesCore
import NotesNative
import NotesSafety

struct CameraCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "camera",
        abstract: "Capture photos from an AVCapture camera, including an iPhone exposed as a Continuity Camera webcam.",
        subcommands: [CameraDevices.self, CameraPhoto.self, CameraScan.self]
    )
}

struct CameraDevices: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "devices", abstract: "List AVCapture video devices.")
    @OptionGroup var options: GlobalOptions

    func run() throws {
        let devices = AVCaptureCameraImageSource().devices()
        if options.json { try Output.json(devices) }
        else {
            Output.table(["ID", "NAME", "KIND", "CONTINUITY", "STATE"], devices.map {
                [$0.id, $0.name, $0.kind, $0.continuityCamera ? "webcam" : "",
                 !$0.connected ? "disconnected" : ($0.suspended ? "suspended" : "ready")]
            })
        }
    }
}

struct CameraPhoto: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "photo", abstract: "Capture and insert native photo attachments.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Option(help: "AVCapture device ID or exact name.") var device: String?
    @Option(help: "Seconds to wait before each capture.") var delay: Double = 0
    @Option(help: "Number of photos to capture.") var count: Int = 1
    @Option var position: Int?
    @Option(help: "Use this image instead of a camera (test injection).") var sourceImage: String?

    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let note = try backend.reader.note(ref)
        let request = try CameraCaptureRequest(device: device, delay: delay, count: count)
        let arguments = ["ref": note.summary.id.uuid, "device": device ?? "default",
                         "delay": String(delay), "count": String(count),
                         "source": sourceImage == nil ? "avcapture" : "injected", "engine": "native"]
        let plan = DryRunPlan(operation: "cameraPhoto", target: note.summary.id.uuid, arguments: arguments,
                              resultingHTML: SafetyExecutor.html(note), engine: "native")
        var images: [FrozenAttachmentInput] = []
        var inserted: [NativeAttachmentResult] = []
        let result = try SafetyExecutor.run(options: write, operation: "cameraPhoto", arguments: arguments,
                                            note: note, allowedPaths: [note.summary.folderPath],
                                            destructive: true, plan: plan) {
            images = try cameraSource(sourceImage).capture(request)
            if backend.isFake { return FakeParityWrite.result(note, storing: "camera photos") }
            let writer = NativeNotesWriter()
            for (index, image) in images.enumerated() {
                inserted.append(try writer.insertFrozenFile(
                    note.summary.id.uuid, frozen: image,
                    position: position.map { $0 + index }, imageView: nil,
                    allowShared: write.allowShared
                ))
            }
            return inserted.last!.write.writeResult
        }
        guard let result else { return }
        let response = EngineWriteResponse(engine: "native", result: result,
                                           operationID: inserted.last?.write.operationID,
                                           verification: inserted.last?.write.verification,
                                           details: ["attachment_ids": inserted.map(\.attachmentID).joined(separator: ","),
                                                     "captured_count": String(images.count)])
        try outputEngineWrite(response, options: options)
    }
}

struct CameraScan: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scan", abstract: "Capture, detect edges, perspective-correct, and insert a native scanned document.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var ref: String
    @Option(help: "AVCapture device ID or exact name.") var device: String?
    @Option(help: "Seconds to wait before each capture.") var delay: Double = 0
    @Option(help: "Number of scan pages to capture.") var count: Int = 1
    @Option var position: Int?
    @Option(help: "Use this image instead of a camera (test injection).") var sourceImage: String?

    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let note = try backend.reader.note(ref)
        let request = try CameraCaptureRequest(device: device, delay: delay, count: count)
        let arguments = ["ref": note.summary.id.uuid, "device": device ?? "default",
                         "delay": String(delay), "count": String(count),
                         "source": sourceImage == nil ? "avcapture" : "injected",
                         "page_sha256": "", "engine": "native"]
        let plan = DryRunPlan(operation: "cameraScan", target: note.summary.id.uuid, arguments: arguments,
                              resultingHTML: SafetyExecutor.html(note), engine: "native")
        var pages: [FrozenAttachmentInput] = []
        var capturedResult: NativeScanResult?
        let result = try SafetyExecutor.run(options: write, operation: "cameraScan", arguments: arguments,
                                            note: note, allowedPaths: [note.summary.folderPath],
                                            destructive: true, plan: plan, capturePrivatePayloads: !backend.isFake,
                                            finishArguments: {
            ["page_sha256": pages.map(\.sha256).joined(separator: ",")]
        }) {
            pages = try cameraSource(sourceImage).capture(request).map(ScanCorrection.correctedPage)
            if backend.isFake { return FakeParityWrite.result(note, storing: "camera scans") }
            let value = try NativeNotesWriter().insertScan(
                note.summary.id.uuid, pages: pages, position: position, allowShared: write.allowShared
            )
            capturedResult = value
            return value.write.writeResult
        }
        guard let result else { return }
        let details = capturedResult.map { ["attachment_id": $0.attachmentID,
                                            "page_ids": $0.pageAttachmentIDs.joined(separator: ","),
                                            "page_count": String($0.pageAttachmentIDs.count)] }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result,
                                                  operationID: capturedResult?.write.operationID,
                                                  verification: capturedResult?.write.verification,
                                                  details: details), options: options)
    }
}

private func cameraSource(_ sourceImage: String?) throws -> any CameraImageSource {
    guard let sourceImage else { return AVCaptureCameraImageSource() }
    let path = try InputFile.validated(
        URL(fileURLWithPath: NSString(string: sourceImage).expandingTildeInPath),
        kind: "camera source image", maxBytes: FrozenAttachmentInput.maxBytes
    )
    return try InjectedCameraImageSource(file: path)
}
