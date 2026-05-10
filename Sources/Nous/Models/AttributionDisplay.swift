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
    /// the corpus lane has entries, legacy citations are the fallback.
    /// Both empty → `.none` so the chip area collapses cleanly.
    static func cascade(
        flagEnabled: Bool,
        resolvedCorpusEntries: [ResolvedCitableEntry],
        citations: [SearchResult]
    ) -> AttributionDisplay {
        guard flagEnabled else {
            return citations.isEmpty ? .none : .legacyCitations(citations)
        }
        if !resolvedCorpusEntries.isEmpty {
            return .atomCards(resolvedCorpusEntries)
        }
        return citations.isEmpty ? .none : .legacyCitations(citations)
    }
}
