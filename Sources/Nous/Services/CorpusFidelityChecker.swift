import Foundation

/// Block 7 telemetry signal for the own-corpus path. Records two things
/// per turn so trends are visible:
///
/// - **Borrowed-authority leakage:** Did the reply name a famous framework
///   (Bezos Type 1/2, Kahneman System 1/2, Munger, "first principles", etc.)
///   even though Alex's own corpus was available? A non-empty `borrowedAuthorityHits`
///   means Block 5's posture didn't fully take.
///
/// - **Own-corpus citation rate:** What fraction of CitableEntries that the
///   builder admitted into the prompt actually showed up in the reply via
///   substring overlap? `ownCorpusCitationRate` of 0.0 with available cards
///   means the cards were ignored; a healthy turn surfaces ≥1 cited entry.
///
/// The signal is purely observational. Block 7 (telemetry-only) emits it
/// to GovernanceTelemetryStore; the rewrite path is deferred per
/// `project_own_corpus_deferred_items.md` until ≥4 weeks of baseline data.
struct CorpusFidelitySignal: Equatable {
    /// Borrowed-authority terms that matched. Empty = no leakage detected.
    let borrowedAuthorityHits: [String]
    /// IDs of CitableEntries the reply quoted (substring overlap detected).
    let ownCorpusCitedIds: [String]
    /// `ownCorpusCitedIds.count` / `available entries` — 0 when nothing
    /// was available, so callers can distinguish "no corpus" from "ignored
    /// the corpus" by looking at `ownCorpusAvailableCount`.
    let ownCorpusCitationRate: Double
    /// Total CitableEntries that were in the prompt. Pair with the rate to
    /// distinguish "ignored corpus" (rate 0, available > 0) from "no
    /// corpus available" (rate 0, available = 0).
    let ownCorpusAvailableCount: Int

    static let empty = CorpusFidelitySignal(
        borrowedAuthorityHits: [],
        ownCorpusCitedIds: [],
        ownCorpusCitationRate: 0.0,
        ownCorpusAvailableCount: 0
    )
}

/// Telemetry-only fidelity scanner. No mutation, no error throws, no
/// rewrite path. Caller logs the returned signal; the rewrite trigger is
/// deferred until a baseline leakage rate is established.
enum CorpusFidelityChecker {

    /// Borrowed-authority dictionary. Kept tight on purpose — false
    /// positives erode the signal. Each entry is matched case-insensitively.
    /// Add new entries only when dogfood reveals a real leakage pattern
    /// the current list misses; do not speculate.
    static let borrowedAuthorityTerms: [String] = [
        "Bezos",
        "Type 1/Type 2", "Type 1 / Type 2", "Type 1/2",
        "Kahneman",
        "System 1", "System 2", "System 1/2", "System 1 / System 2",
        "Munger",
        "first principles",
        "Naval Ravikant",
        "Buffett",
        "OODA loop",
        "Eisenhower matrix",
        "Pareto principle",
        "Dunning-Kruger",
        "Maslow"
    ]

    /// Minimum contiguous substring length for citation detection.
    /// 15 chars catches multi-word phrases (Cantonese: ~5 characters;
    /// English: ~3 words) without tripping on trivial common substrings.
    static let citationOverlapMinLength = 15

    /// Pure scan. Always returns a signal — even an empty corpus or empty
    /// reply produce a well-formed signal so telemetry rows are uniform.
    static func check(reply: String, corpusContext: CitableContext) -> CorpusFidelitySignal {
        let normalizedReply = reply.lowercased()
        let borrowedHits = borrowedAuthorityTerms.filter { term in
            normalizedReply.contains(term.lowercased())
        }

        var citedIds: [String] = []
        for entry in corpusContext.entries {
            if hasSubstringOverlap(
                reply: normalizedReply,
                entryText: entry.text.lowercased(),
                minLength: citationOverlapMinLength
            ) {
                citedIds.append(entry.id)
            }
        }

        let available = corpusContext.entries.count
        let rate = available > 0 ? Double(citedIds.count) / Double(available) : 0.0

        return CorpusFidelitySignal(
            borrowedAuthorityHits: borrowedHits,
            ownCorpusCitedIds: citedIds,
            ownCorpusCitationRate: rate,
            ownCorpusAvailableCount: available
        )
    }

    // MARK: - Internals

    /// True when the reply contains any contiguous substring of `entryText`
    /// at least `minLength` characters long. Short entries (below minLength)
    /// require a full-text match; long entries scan sliding windows.
    private static func hasSubstringOverlap(
        reply: String,
        entryText: String,
        minLength: Int
    ) -> Bool {
        let trimmedEntry = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEntry.isEmpty else { return false }
        let entryChars = Array(trimmedEntry)
        if entryChars.count <= minLength {
            // Tiny entries (say, "Bezos" — 5 chars): require the whole text
            // appear. Sliding window with len > entry length is undefined.
            return reply.contains(trimmedEntry)
        }
        for i in 0...(entryChars.count - minLength) {
            let window = String(entryChars[i..<(i + minLength)])
            if reply.contains(window) { return true }
        }
        return false
    }
}
