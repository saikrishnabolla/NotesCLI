import AppKit
import Foundation
import NotesAutomation
import NotesCore
import NotesNative
import NotesStore
import PDFKit
import PencilKit

struct NativeContractCanaryReport: Codable {
    var folder: String
    var noteID: String
    var elements: [String: Bool]
    var deleted: Bool
}

enum NativeContractCanary {
    static let folderName = "NotesCLI Test hardening"

    static func run(doctor: NativeDoctorReport) throws -> NativeContractCanaryReport {
        guard let contract = doctor.contract else {
            throw NotesError("native_contract_probe_failed", "The native contract report was unavailable.")
        }
        try contract.require(.core)
        for feature in NativeContractFeature.allCases where feature != .core { try contract.require(feature) }

        let scripting = ScriptingNotesWriter()
        if try scripting.listFoldersViaScripting().contains(where: { $0.path.last == folderName }) == false {
            _ = try scripting.createFolder(name: folderName)
        }

        let writer = NativeNotesWriter()
        let title = "NotesCLI native canary \(UUID().uuidString.lowercased())"
        let created = try writer.createNote(
            title: title,
            input: NativeMarkdownInput(source: "# \(title)\n\nPlain **bold** text."),
            folder: folderName,
            allowShared: false
        )
        let noteID = try required(created.write.writeResult.noteID?.uuid, "native canary note ID")
        var deleted = false
        defer {
            if !deleted, (try? writer.deleteNote(noteID, allowShared: false)) != nil { deleted = true }
        }

        let checklist = try writer.insertChecklist(noteID, text: "Canary checklist", position: nil, allowShared: false)
        let tag = "notescli-hardening-\(UUID().uuidString.prefix(8).lowercased())"
        let tagged = try writer.addTag(noteID, tag: tag, position: nil, allowShared: false)
        let divided = try writer.insertDivider(noteID, position: nil, allowShared: false)
        let table = try writer.createTable(noteID, rows: [["A", "B"], ["1", "2"]], position: nil, allowShared: false)

        let png = try FrozenAttachmentInput(data: pngData(), suggestedName: "canary.png")
        let scan = try writer.insertScan(noteID, pages: [png], position: nil, allowShared: false)
        let audio = try FrozenAttachmentInput(data: wavData(), suggestedName: "canary.wav")
        let recording = try writer.insertRecording(noteID, frozen: audio, title: "Canary audio",
                                                   duration: 0.1, transcript: [], allowShared: false)
        let paper = try FrozenAttachmentInput(data: pdfData(), suggestedName: "canary.pdf")
        let paperResult = try writer.insertPaperDocument(noteID, frozen: paper, subtype: "pdf",
                                                        position: nil, allowShared: false)
        let drawing = try writer.insertDrawing(noteID, drawing: canaryDrawing(), position: nil, allowShared: false)
        let handwriting = try writer.recognizeHandwriting(noteID, attachmentID: drawing.attachmentID)

        let fresh = try SQLiteNotesStore(refresh: true).note(noteID)
        let attachmentIDs = Set(flatten(fresh.attachments).map(\.id))
        let elements: [String: Bool] = [
            "plain_rich_text": fresh.document?.text.contains("Plain bold text.") == true,
            "checklist": checklist.writeResult.outcome == .verified && fresh.document?.text.contains("Canary checklist") == true,
            "tag": tagged.writeResult.outcome == .verified && fresh.summary.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame },
            "divider": divided.writeResult.outcome == .verified,
            "table": table.writeResult.outcome == .verified && fresh.document?.tables?.values.contains([["A", "B"], ["1", "2"]]) == true,
            "scan": scan.write.writeResult.outcome == .verified && attachmentIDs.contains(scan.attachmentID),
            "recording": recording.write.writeResult.outcome == .verified && attachmentIDs.contains(recording.attachmentID),
            "paper": paperResult.write.writeResult.outcome == .verified && attachmentIDs.contains(paperResult.attachmentID),
            "paper_drawing": drawing.write.writeResult.outcome == .verified &&
                attachmentIDs.contains(drawing.attachmentID) && handwriting.strokeCount == 1,
        ]
        guard elements.values.allSatisfy({ $0 }) else {
            let failed = elements.filter { !$0.value }.keys.sorted().joined(separator: ", ")
            throw NotesError("native_canary_failed", "Native canary SQLite readback failed: \(failed).")
        }
        _ = try writer.deleteNote(noteID, allowShared: false)
        deleted = true
        return NativeContractCanaryReport(folder: folderName, noteID: noteID, elements: elements, deleted: deleted)
    }

    private static func required<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw NotesError("native_canary_failed", "Missing \(label).") }
        return value
    }

    private static func flatten(_ attachments: [Attachment]) -> [Attachment] {
        attachments.flatMap { [$0] + flatten($0.childAttachments ?? []) }
    }

    private static func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSColor.black.setFill(); NSRect(x: 8, y: 8, width: 16, height: 16).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NotesError("native_canary_failed", "Could not create the canary image.")
        }
        return data
    }

    private static func pdfData() throws -> Data {
        let image = NSImage(size: NSSize(width: 72, height: 72))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 72, height: 72).fill(); image.unlockFocus()
        guard let page = PDFPage(image: image) else {
            throw NotesError("native_canary_failed", "Could not create the canary PDF page.")
        }
        let document = PDFDocument(); document.insert(page, at: 0)
        guard let data = document.dataRepresentation() else {
            throw NotesError("native_canary_failed", "Could not create the canary PDF.")
        }
        return data
    }

    private static func wavData() -> Data {
        let sampleRate: UInt32 = 8_000, sampleCount: UInt32 = 800, dataSize = sampleCount * 2
        var data = Data("RIFF".utf8)
        data.appendLE(UInt32(36) + dataSize); data.append(Data("WAVEfmt ".utf8)); data.appendLE(UInt32(16))
        data.appendLE(UInt16(1)); data.appendLE(UInt16(1)); data.appendLE(sampleRate)
        data.appendLE(sampleRate * 2); data.appendLE(UInt16(2)); data.appendLE(UInt16(16))
        data.append(Data("data".utf8)); data.appendLE(dataSize); data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }

    private static func canaryDrawing() -> PKDrawing {
        let points = [
            PKStrokePoint(location: CGPoint(x: 4, y: 4), timeOffset: 0,
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 20, y: 20), timeOffset: 0.1,
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
