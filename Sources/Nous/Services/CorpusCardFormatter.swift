import Foundation

/// Renders `CitableEntry` instances as attributed prompt cards. Format:
///
///     [reflection · 2026-04-19 · conf 0.78]
///     "Your decisions tend to lag when meaning is unclear."
///
///     [decision · 2026-03-02 · conf 0.62]
///     You chose to ship the notch preview before TTS was ready, citing
///     "momentum over polish."
///
/// Block 3 of the own-corpus path (`~/.claude/plans/atomic-zooming-sphinx.md`).
/// Wiring into the prompt path is Block 4 — this formatter is "dark code"
/// until then. Verbose attribution is the structural lever against
/// borrowed-authority drift: when the model sees that own-corpus material
/// carries dates and confidence, the pull to reach for Bezos / Kahneman as
/// authoritative anchoring weakens.
enum CorpusCardFormatter {

    /// Format a single entry as an attributed card. Returns `nil` for entries
    /// that lack any attribution metadata (caller should fall back to legacy
    /// blob rendering for such entries — they're not own-corpus material).
    static func formatCard(_ entry: CitableEntry) -> String? {
        let header = formatHeader(entry)
        guard let header else { return nil }
        return "\(header)\n\(formatQuotedText(entry.text))"
    }

    /// Format a full context as a single prompt block. Returns `nil` when no
    /// entry produces a card (caller uses the legacy renderer in that case).
    /// `tokenBudget` is interpreted as approximate output characters via
    /// `tokenBudget * charsPerToken` — drops cards that would push past the
    /// limit, in admitted order. Set to nil to disable budget enforcement.
    static func formatContext(
        _ context: CitableContext,
        tokenBudget: Int? = 400,
        charsPerToken: Int = 4
    ) -> String? {
        let cards = context.entries.compactMap(formatCard(_:))
        guard !cards.isEmpty else { return nil }

        let limit = tokenBudget.map { $0 * charsPerToken }
        var admitted: [String] = []
        var runningChars = 0
        for card in cards {
            let added = card.count + 2 // +2 for the joining "\n\n"
            if let limit, runningChars + added > limit, !admitted.isEmpty {
                break
            }
            admitted.append(card)
            runningChars += added
        }
        return admitted.joined(separator: "\n\n")
    }

    // MARK: - Internals

    /// Produces lines like:
    ///   `[decision · 2026-03-02 · conf 0.62]`
    ///   `[reflection · 2026-04-19]`           (high confidence omits the suffix)
    ///   `[atom · 2026-02-14 · conf 0.55]`     (fallback type label)
    /// Returns `nil` when no type and no date are available — without either,
    /// there's nothing to attribute.
    static func formatHeader(_ entry: CitableEntry) -> String? {
        let typeLabel = headerTypeLabel(entry)
        let dateLabel = headerDateLabel(entry)
        let confLabel = headerConfidenceLabel(entry)

        var parts: [String] = []
        if let typeLabel { parts.append(typeLabel) }
        if let dateLabel { parts.append(dateLabel) }
        if let confLabel { parts.append(confLabel) }

        guard !parts.isEmpty else { return nil }
        // A header with only a confidence label has no attribution value;
        // require at least a type or a date to qualify as a card.
        if parts.count == 1, confLabel != nil { return nil }
        return "[\(parts.joined(separator: " · "))]"
    }

    private static func headerTypeLabel(_ entry: CitableEntry) -> String? {
        if entry.scope == .selfReflection || entry.promptAnnotation == "weekly-reflection" {
            return "reflection"
        }
        if let atomType = entry.atomType {
            return atomType.rawValue
        }
        return nil
    }

    private static func headerDateLabel(_ entry: CitableEntry) -> String? {
        let date = entry.eventTime ?? entry.recordedAt
        guard let date else { return nil }
        return Self.dateFormatter.string(from: date)
    }

    /// Confidence is suffix-only: dropped when ≥ 0.9 (treated as authoritative
    /// — the noise of "(conf 0.95)" everywhere weakens the signal of when
    /// confidence actually matters), formatted as `conf 0.NN` otherwise.
    private static func headerConfidenceLabel(_ entry: CitableEntry) -> String? {
        guard let confidence = entry.confidence else { return nil }
        if confidence >= 0.9 { return nil }
        let rounded = (confidence * 100).rounded() / 100
        return String(format: "conf %.2f", rounded)
    }

    private static func formatQuotedText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Don't double-quote text that already opens with a Cantonese-style
        // 「 or a regular quote — the source already attributes itself.
        if trimmed.first == "「" || trimmed.first == "\"" || trimmed.first == "“" {
            return trimmed
        }
        return "\"\(trimmed)\""
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
