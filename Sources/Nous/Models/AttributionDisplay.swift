import Foundation

/// Cascade decision for the chat citation chip area. Mirrors the prompt-side
/// cascade in `PromptContextAssembler` (Block 4a/4b): when the corpus lane
/// has entries, atom cards become the primary surface; the legacy
/// conversation-level citations are the fallback. UI consumes
/// `ChatViewModel.primaryAttribution`; tests assert the cascade rule
/// directly without instantiating any view.
enum AttributionDisplay: Equatable {
    case atomCards([ResolvedCitableEntry])
    case legacyCitations([SearchResult])
    case none
}

extension AttributionDisplay {
    static func == (lhs: AttributionDisplay, rhs: AttributionDisplay) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.atomCards(l), .atomCards(r)):
            return l.map(\.entry.id) == r.map(\.entry.id)
        case let (.legacyCitations(l), .legacyCitations(r)):
            return l.map(\.node.id) == r.map(\.node.id)
        default:
            return false
        }
    }

    /// Pure cascade decision used by `ChatViewModel.primaryAttribution`.
    /// Flag off → legacy is the only path. Flag on → atom cards win when
    /// the corpus lane has entries that clear the UI confidence floor and
    /// fit under the UI cap; otherwise legacy citations are the fallback.
    /// Both empty → `.none` so the chip area collapses cleanly.
    ///
    /// Floor + cap are stricter than the prompt-side gates by design:
    /// - Prompt floor 0.6 (`CitableContextBuilder` default): broader recall
    ///   helps the model stay grounded even on near-threshold atoms.
    /// - UI floor 0.7 (this default): a wrong card is worse than no card —
    ///   we'd rather collapse the chip area than mislead the reader.
    /// - UI cap 5: matches the legacy `topK=5` so the chip bar visual
    ///   weight stays consistent across the cascade switch.
    static func cascade(
        flagEnabled: Bool,
        resolvedCorpusEntries: [ResolvedCitableEntry],
        citations: [SearchResult],
        minConfidence: Double = 0.7,
        maxAtomCards: Int = 5
    ) -> AttributionDisplay {
        guard flagEnabled else {
            return citations.isEmpty ? .none : .legacyCitations(citations)
        }
        let displayable = resolvedCorpusEntries
            .filter { ($0.entry.confidence ?? 1.0) >= minConfidence }
            .prefix(maxAtomCards)
        if !displayable.isEmpty {
            return .atomCards(Array(displayable))
        }
        return citations.isEmpty ? .none : .legacyCitations(citations)
    }
}
