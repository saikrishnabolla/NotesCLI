import Foundation
import NotesCore

public enum SnapshotRestorePolicy {
    public static func destinationFolderPath(current: [String], snapshot: [String],
                                             snapshotIsDeleted: Bool) -> [String]? {
        guard !snapshotIsDeleted, current != snapshot else { return nil }
        return snapshot
    }

    public static func nativeRequiredFeatures(_ note: Note) -> [String] {
        NativeOnlyFeatures.detect(in: note)
    }

    public static func requireScriptingRestoreAllowed(_ note: Note, allowDowngrade: Bool) throws {
        let features = nativeRequiredFeatures(note)
        guard allowDowngrade || features.isEmpty else {
            throw NotesError(
                "native_required",
                "This snapshot contains native-only features: \(features.joined(separator: ", ")).",
                hint: "Remove --engine scripting for a lossless native restore, or pass --allow-downgrade to permit conversion."
            )
        }
    }

    public static func requireScriptingBodyRewriteAllowed(_ note: Note, allowDowngrade: Bool) throws {
        let features = nativeRequiredFeatures(note)
        guard allowDowngrade || features.isEmpty else {
            throw NotesError(
                "native_required",
                "This note contains native-only features: \(features.joined(separator: ", ")).",
                hint: "Remove --engine scripting for a lossless native write, or pass --allow-downgrade to permit conversion."
            )
        }
    }

}
