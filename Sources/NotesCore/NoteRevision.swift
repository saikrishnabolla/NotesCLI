import CryptoKit
import Foundation

public enum NoteRevision {
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
