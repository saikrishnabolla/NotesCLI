import Foundation

public struct MergeResult: Equatable, Sendable {
    public var text: String
    public var hadConflicts: Bool
    public init(text: String, hadConflicts: Bool) { self.text = text; self.hadConflicts = hadConflicts }
}

public enum Diff3 {
    private struct Hunk: Equatable {
        var range: Range<Int>
        var replacement: [String]
    }

    public static func merge(base: String, local: String, remote: String) -> MergeResult {
        if local == remote { return MergeResult(text: local, hadConflicts: false) }
        if local == base { return MergeResult(text: remote, hadConflicts: false) }
        if remote == base { return MergeResult(text: local, hadConflicts: false) }
        let baseLines = lines(base), localLines = lines(local), remoteLines = lines(remote)
        let left = hunks(from: baseLines, to: localLines), right = hunks(from: baseLines, to: remoteLines)
        var li = 0, ri = 0, cursor = 0, output: [String] = [], conflict = false
        while li < left.count || ri < right.count {
            if ri == right.count || li < left.count && strictlyBefore(left[li], right[ri]) {
                append(left[li], base: baseLines, cursor: &cursor, output: &output); li += 1; continue
            }
            if li == left.count || strictlyBefore(right[ri], left[li]) {
                append(right[ri], base: baseLines, cursor: &cursor, output: &output); ri += 1; continue
            }
            let start = min(left[li].range.lowerBound, right[ri].range.lowerBound)
            var end = max(left[li].range.upperBound, right[ri].range.upperBound)
            var leftGroup: [Hunk] = [], rightGroup: [Hunk] = []
            var changed = true
            while changed {
                changed = false
                while li < left.count && touches(left[li], start: start, end: end) {
                    end = max(end, left[li].range.upperBound); leftGroup.append(left[li]); li += 1; changed = true
                }
                while ri < right.count && touches(right[ri], start: start, end: end) {
                    end = max(end, right[ri].range.upperBound); rightGroup.append(right[ri]); ri += 1; changed = true
                }
            }
            output += baseLines[cursor..<start]
            let leftText = apply(leftGroup, to: baseLines, range: start..<end)
            let rightText = apply(rightGroup, to: baseLines, range: start..<end)
            if leftText == rightText { output += leftText }
            else {
                conflict = true
                output.append("<<<<<<< LOCAL")
                output += leftText
                output.append("||||||| BASE")
                output += baseLines[start..<end]
                output.append("=======")
                output += rightText
                output.append(">>>>>>> NOTES")
            }
            cursor = end
        }
        output += baseLines[cursor...]
        return MergeResult(text: output.joined(separator: "\n"), hadConflicts: conflict)
    }

    private static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    private static func hunks(from base: [String], to target: [String]) -> [Hunk] {
        let n = base.count, m = target.count
        guard n * m <= 2_000_000 else {
            var prefix = 0
            while prefix < min(n, m), base[prefix] == target[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(n - prefix, m - prefix), base[n - suffix - 1] == target[m - suffix - 1] { suffix += 1 }
            return [Hunk(range: prefix..<(n - suffix), replacement: Array(target[prefix..<(m - suffix)]))]
        }
        let width = m + 1
        var lengths = Array(repeating: Int32(0), count: (n + 1) * width)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lengths[i * width + j] = base[i] == target[j]
                        ? lengths[(i + 1) * width + j + 1] + 1
                        : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
                }
            }
        }
        var result: [Hunk] = [], i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, base[i] == target[j] { i += 1; j += 1; continue }
            let start = i
            var replacement: [String] = []
            while i < n || j < m {
                if i < n, j < m, base[i] == target[j] { break }
                if j < m && (i == n || lengths[i * width + j + 1] >= lengths[(i + 1) * width + j]) {
                    replacement.append(target[j]); j += 1
                } else { i += 1 }
            }
            result.append(Hunk(range: start..<i, replacement: replacement))
        }
        return result
    }

    private static func strictlyBefore(_ a: Hunk, _ b: Hunk) -> Bool {
        if a.range.isEmpty && b.range.isEmpty && a.range.lowerBound == b.range.lowerBound { return false }
        return a.range.upperBound <= b.range.lowerBound && !(a.range.isEmpty && a.range.lowerBound == b.range.lowerBound)
    }

    private static func touches(_ hunk: Hunk, start: Int, end: Int) -> Bool {
        if start == end { return hunk.range.lowerBound == start }
        if hunk.range.isEmpty { return hunk.range.lowerBound >= start && hunk.range.lowerBound < end }
        return hunk.range.lowerBound < end && hunk.range.upperBound > start
    }

    private static func append(_ hunk: Hunk, base: [String], cursor: inout Int, output: inout [String]) {
        output += base[cursor..<hunk.range.lowerBound]
        output += hunk.replacement
        cursor = hunk.range.upperBound
    }

    private static func apply(_ hunks: [Hunk], to base: [String], range: Range<Int>) -> [String] {
        var output: [String] = [], cursor = range.lowerBound
        for hunk in hunks {
            output += base[cursor..<hunk.range.lowerBound]
            output += hunk.replacement
            cursor = hunk.range.upperBound
        }
        output += base[cursor..<range.upperBound]
        return output
    }
}
