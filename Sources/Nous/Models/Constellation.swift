import Foundation

struct Constellation: Identifiable, Equatable {
    let id: UUID                       // = ReflectionClaim.id
    let claimId: UUID
    let label: String                  // = ReflectionClaim.claim (verbatim)
    let derivedShortLabel: String      // computed from `label`, see below
    let confidence: Double
    let memberNodeIds: [UUID]          // post-K=2-cap; distinct, ≥ 2
    let centroidEmbedding: [Float]?    // mean of member embeddings; nil if any member missing embedding
    let isDominant: Bool               // at most one true per Galaxy load
}

extension Constellation {
    /// Deterministic short-label derivation. No NLP, no extra LLM call.
    /// Pattern A → first quoted phrase in 「」 or "" if ≤22 chars.
    /// Pattern B → substring after first colon/em-dash, trimmed at first
    ///             sentence delimiter or 22 chars (whichever first).
    /// Fallback → first 22 chars + ellipsis.
    static func derivedShortLabel(from claim: String) -> String {
        let trimmed = claim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Pattern A: 「...」 corner brackets first
        if let cornerStart = trimmed.firstIndex(of: "「"),
           let cornerEnd = trimmed[trimmed.index(after: cornerStart)...].firstIndex(of: "」") {
            let inner = String(trimmed[trimmed.index(after: cornerStart)..<cornerEnd])
            if inner.count <= 22 && !inner.isEmpty {
                return inner
            }
        }
        // Pattern A: "..." straight quotes
        if let q1 = trimmed.firstIndex(of: "\""),
           let q2 = trimmed[trimmed.index(after: q1)...].firstIndex(of: "\"") {
            let inner = String(trimmed[trimmed.index(after: q1)..<q2])
            if inner.count <= 22 && !inner.isEmpty {
                return inner
            }
        }

        // Pattern B: split on first delimiter, take the substring after
        let delimiters: [String] = ["：", ":", "——", "—"]
        for delim in delimiters {
            if let range = trimmed.range(of: delim) {
                let after = trimmed[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty {
                    let stoppers: [Character] = ["，", "。", ",", ".", "\n"]
                    var end = after.startIndex
                    for ch in after {
                        if stoppers.contains(ch) { break }
                        end = after.index(after: end)
                    }
                    let candidate = String(after[..<end])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidate.isEmpty {
                        return candidate
                    }
                }
            }
        }

        // Fallback
        if trimmed.count > 22 {
            return String(trimmed.prefix(22)) + "…"
        }
        return trimmed
    }
}
