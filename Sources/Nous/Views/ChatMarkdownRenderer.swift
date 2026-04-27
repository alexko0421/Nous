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
            // Fallback: prose (single line for now; bullet/table/fence in later tasks).
            segments.append(.prose(line))
            i += 1
        }
        return segments
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
