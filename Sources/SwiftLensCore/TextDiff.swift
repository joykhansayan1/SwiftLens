/// A small, dependency-free line diff (Myers' O(ND) algorithm) used to show what a macro expansion changed.
public enum TextDiff {
    public enum Operation: String, Codable, Sendable {
        case equal, insert, delete
    }

    public struct Line: Codable, Hashable, Sendable {
        public var operation: Operation
        public var text: String
        /// 1-based line number in the old text (nil for insertions).
        public var oldLine: Int?
        /// 1-based line number in the new text (nil for deletions).
        public var newLine: Int?
    }

    public struct Hunk: Codable, Hashable, Sendable {
        public var oldStart: Int
        public var oldCount: Int
        public var newStart: Int
        public var newCount: Int
        public var lines: [Line]

        public var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
    }

    /// Computes a line-level edit script between `old` and `new`.
    public static func lines(from old: String, to new: String) -> [Line] {
        let a = splitLines(old)
        let b = splitLines(new)
        return diff(a, b)
    }

    public static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func diff(_ a: [String], _ b: [String]) -> [Line] {
        // Trim common prefix/suffix first: expansions usually touch a small part of the file.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])

        var result: [Line] = []
        for i in 0..<prefix {
            result.append(Line(operation: .equal, text: a[i], oldLine: i + 1, newLine: i + 1))
        }
        for line in myers(midA, midB) {
            var shifted = line
            shifted.oldLine = line.oldLine.map { $0 + prefix }
            shifted.newLine = line.newLine.map { $0 + prefix }
            result.append(shifted)
        }
        for i in 0..<suffix {
            let ai = a.count - suffix + i
            let bi = b.count - suffix + i
            result.append(Line(operation: .equal, text: a[ai], oldLine: ai + 1, newLine: bi + 1))
        }
        return result
    }

    private static func myers(_ a: [String], _ b: [String]) -> [Line] {
        let n = a.count
        let m = b.count
        if n == 0 { return b.enumerated().map { Line(operation: .insert, text: $1, oldLine: nil, newLine: $0 + 1) } }
        if m == 0 { return a.enumerated().map { Line(operation: .delete, text: $1, oldLine: $0 + 1, newLine: nil) } }

        let max = n + m
        let offset = max
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []

        search: for d in 0...max {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    x = v[k + 1 + offset]
                } else {
                    x = v[k - 1 + offset] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[k + offset] = x
                if x >= n && y >= m { break search }
            }
        }

        // Backtrack.
        var x = n
        var y = m
        var reversed: [Line] = []
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = v[prevK + offset]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                reversed.append(Line(operation: .equal, text: a[x - 1], oldLine: x, newLine: y))
                x -= 1
                y -= 1
            }
            if d > 0 {
                if x == prevX {
                    reversed.append(Line(operation: .insert, text: b[y - 1], oldLine: nil, newLine: y))
                } else {
                    reversed.append(Line(operation: .delete, text: a[x - 1], oldLine: x, newLine: nil))
                }
            }
            x = prevX
            y = prevY
        }
        return reversed.reversed()
    }

    /// Groups an edit script into hunks with `context` lines of surrounding context.
    public static func hunks(_ lines: [Line], context: Int = 3) -> [Hunk] {
        var hunks: [Hunk] = []
        let changeIndices = lines.indices.filter { lines[$0].operation != .equal }
        guard !changeIndices.isEmpty else { return [] }

        var groups: [(Int, Int)] = []
        var start = max(0, changeIndices[0] - context)
        var end = min(lines.count - 1, changeIndices[0] + context)
        for index in changeIndices.dropFirst() {
            if index - context <= end + 1 {
                end = min(lines.count - 1, index + context)
            } else {
                groups.append((start, end))
                start = max(0, index - context)
                end = min(lines.count - 1, index + context)
            }
        }
        groups.append((start, end))

        for (start, end) in groups {
            let slice = Array(lines[start...end])
            let oldLines = slice.filter { $0.operation != .insert }
            let newLines = slice.filter { $0.operation != .delete }
            let oldStart = oldLines.first?.oldLine ?? (precedingOldLine(lines, before: start) + 1)
            let newStart = newLines.first?.newLine ?? (precedingNewLine(lines, before: start) + 1)
            hunks.append(Hunk(
                oldStart: oldLines.isEmpty ? oldStart - 1 : oldStart,
                oldCount: oldLines.count,
                newStart: newLines.isEmpty ? newStart - 1 : newStart,
                newCount: newLines.count,
                lines: slice
            ))
        }
        return hunks
    }

    private static func precedingOldLine(_ lines: [Line], before index: Int) -> Int {
        lines[..<index].last(where: { $0.oldLine != nil })?.oldLine ?? 0
    }

    private static func precedingNewLine(_ lines: [Line], before index: Int) -> Int {
        lines[..<index].last(where: { $0.newLine != nil })?.newLine ?? 0
    }

    /// Produces a unified diff (as understood by `patch`/`git apply`).
    public static func unified(from old: String, to new: String, oldName: String = "a/original.swift", newName: String = "b/expanded.swift", context: Int = 3) -> String {
        let script = lines(from: old, to: new)
        let hunks = hunks(script, context: context)
        guard !hunks.isEmpty else { return "" }
        var output = "--- \(oldName)\n+++ \(newName)\n"
        for hunk in hunks {
            output += hunk.header + "\n"
            for line in hunk.lines {
                switch line.operation {
                case .equal: output += " \(line.text)\n"
                case .insert: output += "+\(line.text)\n"
                case .delete: output += "-\(line.text)\n"
                }
            }
        }
        return output
    }

    /// Summary counts for UI badges.
    public static func stats(_ lines: [Line]) -> (insertions: Int, deletions: Int) {
        (lines.filter { $0.operation == .insert }.count, lines.filter { $0.operation == .delete }.count)
    }
}
