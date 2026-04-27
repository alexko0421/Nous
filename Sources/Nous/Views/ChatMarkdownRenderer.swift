import SwiftUI

enum Segment: Equatable {
    case heading(level: Int, text: String)
    case bulletBlock([String])
    case table(headers: [String], rows: [[String]])
    case prose(String)
    case verbatim(String)
}

enum ChatMarkdownRenderer {

    /// Parses raw assistant text into typed segments. Line-based parsing.
    static func parse(_ text: String) -> [Segment] {
        // `"".components(separatedBy:)` returns [""], which would produce [.prose("")].
        // Blank-line rendering policy is deferred to Task 7; guard here to preserve
        // the Task 1 contract that parse("") returns [].
        guard !text.isEmpty else { return [] }

        var segments: [Segment] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let heading = parseHeading(line: line) {
                segments.append(heading)
                i += 1
                continue
            }
            if isBulletLine(line) {
                var bullets: [String] = []
                while i < lines.count, isBulletLine(lines[i]) {
                    bullets.append(bulletContent(lines[i]))
                    i += 1
                }
                segments.append(.bulletBlock(bullets))
                continue  // `i` was advanced inside the inner while; do not increment here.
            }
            if let (tableSegment, nextIndex) = parseTable(lines: lines, startIndex: i) {
                segments.append(tableSegment)
                i = nextIndex
                continue  // `i` advanced to nextIndex by parseTable; do not increment here.
            }
            // Fallback: prose (single line for now; fence in later tasks).
            segments.append(.prose(line))
            i += 1
        }
        return segments
    }

    private static let escapedPipeSentinel = "\u{0001}"  // ASCII SOH, won't appear in chat

    private static func splitPipes(_ line: String) -> [String]? {
        // Returns nil if line is not pipe-bordered (no leading | or no trailing |).
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\\|", with: escapedPipeSentinel)
        var cells = escaped.components(separatedBy: "|")
        // Bordering pipes produce empty leading and trailing fields — drop them.
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.map {
            $0.replacingOccurrences(of: escapedPipeSentinel, with: "|")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private static func isSeparatorRow(_ line: String, expectedColumns: Int) -> Bool {
        guard let cells = splitPipes(line), cells.count == expectedColumns else { return false }
        let pattern = "^:?-+:?$"
        return cells.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    private static func parseTable(lines: [String], startIndex: Int) -> (Segment, Int)? {
        // Returns the table segment and the index of the next non-table line, or nil if not a table.
        guard startIndex + 1 < lines.count,
              let headers = splitPipes(lines[startIndex]),
              headers.count >= 2 else { return nil }
        guard isSeparatorRow(lines[startIndex + 1], expectedColumns: headers.count) else { return nil }

        var rows: [[String]] = []
        var i = startIndex + 2
        while i < lines.count, var cells = splitPipes(lines[i]) {
            // Normalize column count to header count.
            if cells.count < headers.count {
                cells.append(contentsOf: Array(repeating: "", count: headers.count - cells.count))
            } else if cells.count > headers.count {
                cells = Array(cells.prefix(headers.count))
            }
            rows.append(cells)
            i += 1
        }
        guard !rows.isEmpty else { return nil }
        return (.table(headers: headers, rows: rows), i)
    }

    private static func isBulletLine(_ line: String) -> Bool {
        // Must start with "- " (dash-space; content trimmed separately).
        return line.hasPrefix("- ")
    }

    private static func bulletContent(_ line: String) -> String {
        return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func parseHeading(line: String) -> Segment? {
        if line.hasPrefix("## ") {
            let body = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return .heading(level: 2, text: body)
        }
        if line.hasPrefix("# ") {
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return .heading(level: 1, text: body)
        }
        return nil
    }
}
