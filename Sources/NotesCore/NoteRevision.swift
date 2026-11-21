import CryptoKit
import Foundation

public enum NoteRevision {
    /// An import is unchanged when its content and destination are unchanged.
    /// Opening the note or an iCloud acknowledgement is not a content edit.
    public static func importValue(_ note: Note) -> String {
        struct Content: Encodable {
            var title: String
            var folder: String?
            var locked: Bool
            var deleted: Bool
            var shared: Bool?
            var document: NoteDocument?
            var attachments: [[String]]
        }
        let value = Content(title: note.summary.title, folder: note.summary.folderID, locked: note.summary.isLocked,
                            deleted: note.summary.isDeleted, shared: note.summary.isShared, document: note.document,
                            attachments: note.attachments.map { [$0.id, $0.typeUTI, $0.filename ?? "", $0.title ?? ""] }.sorted {
                                $0[0] < $1[0]
                            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    public static func value(_ note: Note) -> String {
        var note = note
        note.attachments = note.attachments.map(canonicalAttachment)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(note)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalAttachment(_ attachment: Attachment) -> Attachment {
        var attachment = attachment
        attachment.synapseDataBytes = nil
        attachment.linkPreviewMetadataBytes = nil
        attachment.childAttachments = attachment.childAttachments?.map(canonicalAttachment)
        return attachment
    }
}
