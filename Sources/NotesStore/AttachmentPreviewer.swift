import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import NotesCore

public struct AttachmentPreview: Codable, Sendable, Hashable {
    public var attachmentID: String
    public var path: String
    public var kind: String
}

public enum AttachmentPreviewer {
    public static func write(_ attachments: [Attachment], to directory: URL, maximumDimension: Int = 1600) throws -> [AttachmentPreview] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var output: [AttachmentPreview] = []
        for attachment in attachments {
            guard let path = attachment.filePath else { continue }
            let source = URL(fileURLWithPath: path)
            let target = directory.appendingPathComponent(safe(attachment.id) + "-preview.png")
            let lower = attachment.typeUTI.lowercased()
            let wrote: Bool
            if attachment.kind == "image" { wrote = try image(source, to: target, maximumDimension: maximumDimension) }
            else if attachment.kind == "pdf" { wrote = try pdf(source, to: target, maximumDimension: maximumDimension) }
            else if lower.contains("video") || lower.contains("movie") { wrote = try video(source, to: target, maximumDimension: maximumDimension) }
            else { wrote = false }
            if wrote { output.append(AttachmentPreview(attachmentID: attachment.id, path: target.path, kind: attachment.kind)) }
        }
        return output
    }

    private static func image(_ source: URL, to target: URL, maximumDimension: Int) throws -> Bool {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
              ] as CFDictionary) else { return false }
        try writePNG(image, to: target); return true
    }

    private static func pdf(_ source: URL, to target: URL, maximumDimension: Int) throws -> Bool {
        guard let document = PDFDocument(url: source), let page = document.page(at: 0) else { return false }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(CGFloat(maximumDimension) / max(1, bounds.width), CGFloat(maximumDimension) / max(1, bounds.height), 1)
        let preview = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let data = preview.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        try png.write(to: target, options: .atomic); return true
    }

    private final class FrameBox: @unchecked Sendable {
        let lock = NSLock()
        var image: CGImage?
        var error: Error?
    }
    private static func video(_ source: URL, to target: URL, maximumDimension: Int) throws -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        let box = FrameBox(), semaphore = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: .zero) { image, _, error in
            box.lock.lock(); box.image = image; box.error = error; box.lock.unlock(); semaphore.signal()
        }
        semaphore.wait()
        box.lock.lock(); defer { box.lock.unlock() }
        if let error = box.error { throw error }
        guard let image = box.image else { return false }
        try writePNG(image, to: target); return true
    }

    private static func writePNG(_ image: CGImage, to target: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NotesError("preview_failed", "Cannot create the preview image.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NotesError("preview_failed", "Cannot write the preview image.") }
    }
    private static func safe(_ value: String) -> String {
        value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
    }
}
