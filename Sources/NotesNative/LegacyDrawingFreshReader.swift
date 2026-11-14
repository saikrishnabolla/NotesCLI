import CoreData
import Foundation
import NotesCore
import NotesNativeObjC

public enum LegacyDrawingFreshReader {
    public static func payload(attachmentID: String) throws -> Data {
        guard UUID(uuidString: attachmentID) != nil else {
            throw NotesError("invalid_attachment_id", "The legacy drawing attachment ID is invalid.")
        }
        let context: NSManagedObjectContext
        do { context = try NCNotesRuntime.sharedContext() }
        catch { throw NotesError("native_runtime_unavailable", error.localizedDescription) }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "ICAttachment")
            request.predicate = NSPredicate(format: "identifier == %@", attachmentID)
            request.fetchLimit = 1
            guard let attachment = try context.fetch(request).first else {
                throw NotesError("attachment_not_found", "The legacy drawing attachment was not found.")
            }
            do { return try NCNotesRuntime.legacyDrawingStrokes(for: attachment) }
            catch { throw NotesError("drawing_decode_failed", error.localizedDescription) }
        }
    }
}
