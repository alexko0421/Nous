import SwiftUI

enum Segment: Equatable {
    case heading(level: Int, text: String)
    case bulletBlock([String])
    case table(headers: [String], rows: [[String]])
    case prose(String)
    case verbatim(String)
}

enum ChatMarkdownRenderer {

    private static let boldPairRegex = try! NSRegularExpression(pattern: #"\*\*([^\*]+)\*\*"#)
    private static let italicAsteriskRegex = try! NSRegularExpression(
        pattern: #"(?<!\*)\*([^\*\s][^\*]*?)\*(?!\*)"#
    )
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
    private static let orderedListPrefixRegex = try! NSRegularExpression(pattern: #"^\d+\.\s+"#)
    private static let quotePrefixRegex = try! NSRegularExpression(pattern: #"^>\s+"#)

    /// Strips unsupported markdown delimiters from a single line of prose.
    /// Underscores are NEVER touched (preserves snake_case_var, __init__).
    private static func sanitizeProse(_ line: String) -> String {
        var result = line

        // Line-start prefixes first (always strip).
        result = applyRegex(orderedListPrefixRegex, to: result, replacement: "")
        result = applyRegex(quotePrefixRegex, to: result, replacement: "")

        // Balanced-pair stripping.
        result = applyRegex(boldPairRegex, to: result, replacement: "$1")
        result = applyRegex(italicAsteriskRegex, to: result, replacement: "$1")
        result = applyRegex(inlineCodeRegex, to: result, replacement: "$1")

        return result
    }

    private static func applyRegex(
        _ regex: NSRegularExpression,
        to input: String,
        replacement: String
    ) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
    }

    private static func isFenceOpen(_ line: String) -> Bool {
        // Triple backtick at line start, possibly followed by language tag.
        return line.hasPrefix("```")
    }

    /// Returns either (verbatim segment, indexAfterClosingFence) on closed fence,
    /// or nil if the fence is unclosed (caller falls back to re-parsing).
    private static func parseFence(lines: [String], startIndex: Int) -> (Segment, Int)? {
        guard startIndex < lines.count, isFenceOpen(lines[startIndex]) else { return nil }
        var captured: [String] = []
        var i = startIndex + 1
        while i < lines.count {
            if lines[i].hasPrefix("```") {
                // Closing fence found.
                return (.verbatim(captured.joined(separator: "\n")), i + 1)
            }
            captured.append(lines[i])
            i += 1
        }
        // Reached EOF without closing fence — caller handles fallback.
        return nil
    }

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

            // Try fence first (must be checked before prose fallback).
            if isFenceOpen(line) {
                if let (verbatim, nextIndex) = parseFence(lines: lines, startIndex: i) {
                    segments.append(verbatim)
                    i = nextIndex
                    continue  // `i` advanced to nextIndex by parseFence; do not increment here.
                } else {
                    // Unclosed fence: bare ``` line as prose; captured content re-parsed
                    // by main loop on subsequent iterations (no recursion needed — just
                    // continue past the ``` line and let normal parsing handle the rest).
                    segments.append(.prose(sanitizeProse(line)))
                    i += 1
                    continue
                }
            }

            if let heading = parseHeading(line: line) {
                segments.append(heading)
                i += 1
                continue
            }
            if isBulletLine(line) {
                var bullets: [String] = []
                while i < lines.count, isBulletLine(lines[i]) {
                    bullets.append(sanitizeProse(bulletContent(lines[i])))
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
            segments.append(.prose(sanitizeProse(line)))
            i += 1
        }
        return segments
    }

    private static let escapedPipeSentinel = "\u{0001}"  // ASCII SOH, won't appear in chat

    private static func splitPipes(_ line: String) -> [String]? {
        // Returns nil if line is not pipe-bordered (no leading | or no trailing |).
        // Strip any stray SOH first — converts the "LLMs don't emit U+0001" assumption
        // into an enforced invariant so the sentinel-substitute trick can't silently
        // corrupt input that happens to contain SOH.
        let trimmed = line
            .replacingOccurrences(of: escapedPipeSentinel, with: "")
            .trimmingCharacters(in: .whitespaces)
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
