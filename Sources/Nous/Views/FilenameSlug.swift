import Foundation

/// Returns a `.md` filename derived from the first ATX H1 (`# ...`) in the given
/// markdown. Falls back to `Nous-Summary-YYYY-MM-DD.md` when no usable heading
/// exists. Strips filename-unsafe characters (`/\:*?"<>|` and control chars),
/// collapses whitespace to single dashes, and truncates the stem to 60 chars.
func filenameSlug(fromMarkdown markdown: String, fallbackDate: Date = Date()) -> String {
    let heading = extractFirstH1(from: markdown)
    if let slug = slugify(heading) {
        return "\(slug).md"
    }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return "Nous-Summary-\(formatter.string(from: fallbackDate)).md"
}

private func extractFirstH1(from markdown: String) -> String {
    for line in markdown.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("# "), !trimmed.hasPrefix("## ") else { continue }
        return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    return ""
}

private func slugify(_ raw: String) -> String? {
    guard !raw.isEmpty else { return nil }

    let disallowed: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
    var filtered = String(raw.unicodeScalars.compactMap { scalar -> Character? in
        if scalar.properties.generalCategory == .control { return nil }
        let ch = Character(scalar)
        if disallowed.contains(ch) { return nil }
        return ch
    })

    // Collapse whitespace runs to single dash.
    let whitespaceCollapsed = filtered
        .components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty }
        .joined(separator: "-")
    filtered = whitespaceCollapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    guard !filtered.isEmpty else { return nil }

    // Truncate stem to 60 chars (character count, not bytes — CJK stays readable).
    if filtered.count > 60 {
        let idx = filtered.index(filtered.startIndex, offsetBy: 60)
        filtered = String(filtered[..<idx])
    }
    return filtered
}
