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
                continue
            }
            // Fallback: prose (single line for now; table/fence in later tasks).
            segments.append(.prose(line))
            i += 1
        }
        return segments
    }

    private static func isBulletLine(_ line: String) -> Bool {
        // Must start with "- " (dash followed by at least one space).
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
