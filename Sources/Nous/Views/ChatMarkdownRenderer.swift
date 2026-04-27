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
        return []
    }
}
