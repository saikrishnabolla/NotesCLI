import CryptoKit
import Foundation
import NotesCore

public enum ConcurrencyGuard {
    public static func revision(_ note: Note) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(note)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func require(_ note: Note, ifModified: String?, expectRevision: String?) throws {
        if ifModified != nil && expectRevision != nil {
            throw NotesError("invalid_concurrency_guard", "Use only one of --if-modified or --expect-revision.")
        }
        if let ifModified {
            guard let expected = date(ifModified) else { throw NotesError("invalid_date", "--if-modified must be an ISO 8601 date.") }
            guard let actual = note.summary.modified, abs(actual.timeIntervalSince(expected)) < 0.001 else {
                throw NotesError("stale_note", "The note changed after it was read.")
            }
        }
        if let expectRevision {
            let matches: Bool
            if let expectedDate = date(expectRevision), let modified = note.summary.modified {
                matches = abs(modified.timeIntervalSince(expectedDate)) < 0.001
            } else { matches = revision(note) == expectRevision }
            if !matches { throw NotesError("stale_note", "The note revision does not match.") }
        }
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
