import Foundation
import NotesCore
import NotesNativeObjC
import UniformTypeIdentifiers

public struct OCRRecognitionResult: Codable, Equatable, Sendable {
    public var text: String
    public var title: String?

    public init(text: String, title: String? = nil) {
        self.text = text
        self.title = title
    }
}

public enum OCRRecognition {
    typealias Runtime = (URL, [String]?, String?) throws -> [String: String]

    public static func recognize(fileURL: URL, languages: [String]? = nil,
                                 title: String? = nil) throws -> OCRRecognitionResult {
        try recognize(fileURL: fileURL, languages: languages, title: title) { url, languages, title in
            try NCNotesRuntime.recognizeText(in: url, languages: languages, title: title)
        }
    }

    static func recognize(fileURL: URL, languages: [String]? = nil, title: String? = nil,
                          runtime: Runtime) throws -> OCRRecognitionResult {
        let source = try validatedFileURL(fileURL)
        let normalizedLanguages = languages?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: String]
        do {
            payload = try runtime(source, normalizedLanguages?.isEmpty == false ? normalizedLanguages : nil,
                                  normalizedTitle?.isEmpty == false ? normalizedTitle : nil)
        } catch let error as NotesError {
            throw error
        } catch {
            let nativeError = error as NSError
            if nativeError.domain == "NotesCLI.NotesNative", nativeError.code == 2 {
                throw NotesError("feature_unavailable", nativeError.localizedDescription)
            }
            throw NotesError("ocr_failed", "Apple Notes OCR failed: \(nativeError.localizedDescription)")
        }
        guard let text = payload["text"] else {
            throw NotesError("ocr_failed", "Apple Notes OCR returned an invalid result.")
        }
        let generatedTitle = payload["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return OCRRecognitionResult(text: text, title: generatedTitle?.isEmpty == false ? generatedTitle : normalizedTitle)
    }

    private static func validatedFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw NotesError("ocr_input_not_file_url", "OCR input must be a local file URL.")
        }
        let source = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw NotesError("ocr_input_missing", "OCR input does not exist: \(source.path)")
        }
        guard !isDirectory.boolValue else {
            throw NotesError("ocr_input_not_file", "OCR input must be a file: \(source.path)")
        }
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw NotesError("ocr_input_unreadable", "OCR input is not readable: \(source.path)")
        }
        return source
    }
}

public enum OCRAttachmentResolver {
    public static func resolve(_ attachments: [Attachment], attachmentID: String?) throws -> Attachment {
        func flattened(_ values: [Attachment]) -> [Attachment] {
            values.flatMap { [$0] + flattened($0.childAttachments ?? []) }
        }
        let attachments = flattened(attachments)
        let selected: Attachment
        if let attachmentID {
            guard let match = attachments.first(where: { $0.id.caseInsensitiveCompare(attachmentID) == .orderedSame }) else {
                throw NotesError("attachment_not_found", "No attachment matches \(attachmentID).")
            }
            selected = match
        } else {
            let images = attachments.filter(isImage)
            guard !images.isEmpty else {
                throw NotesError("ocr_attachment_not_found", "The note has no image attachment.")
            }
            guard images.count == 1 else {
                throw NotesError("ocr_attachment_ambiguous", "The note has more than one image attachment.",
                                 hint: "Use --attachment with an attachment ID.")
            }
            selected = images[0]
        }
        guard isImage(selected) else {
            throw NotesError("ocr_attachment_not_image", "Attachment \(selected.id) is not an image.")
        }
        guard selected.filePath != nil else {
            throw NotesError("attachment_unavailable", "The image attachment is not downloaded.")
        }
        return selected
    }

    private static func isImage(_ attachment: Attachment) -> Bool {
        UTType(attachment.typeUTI)?.conforms(to: .image) == true
    }
}

enum NativeImageMetadata {
    static func isImage(typeUTI: String) -> Bool {
        UTType(typeUTI)?.conforms(to: .image) == true
    }

    static func requireImage(typeUTI: String, attachmentID: String) throws {
        guard isImage(typeUTI: typeUTI) else {
            throw NotesError("image_metadata_attachment_not_image", "Attachment \(attachmentID) is not an image.")
        }
    }

    static func requireActive(markedForDeletion: Bool, attachmentID: String) throws {
        guard !markedForDeletion else {
            throw NotesError("attachment_not_found", "No active attachment matches \(attachmentID) in this note.")
        }
    }

    static func versionMatches(summary: String?, version: Int) -> Bool {
        summary == nil ? version == 0 : version > 0
    }
}
