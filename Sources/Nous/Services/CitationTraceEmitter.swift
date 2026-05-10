import Foundation

/// Phase A chat-side telemetry helper. ChatViewModel calls
/// `emit(...)` once per assistant reply turn, after the
/// `AttributionDisplay.cascade` has resolved which corpus entries
/// became chips. Writes one `citation_judge_trace` row per
/// candidate atom — including those filtered out by the UI confidence
/// floor — so Phase A2 can study the full cascade decision, not just
/// the chips that survived.
final class CitationTraceEmitter {
    private let traceStore: CitationJudgeTraceStore

    init(traceStore: CitationJudgeTraceStore) {
        self.traceStore = traceStore
    }

    func emit(
        conversationId: UUID,
        turnId: UUID,
        candidates: [(atomId: UUID, confidence: Double)],
        displayedIds: Set<UUID>
    ) throws {
        for candidate in candidates {
            try traceStore.append(
                conversationId: conversationId,
                turnId: turnId,
                atomId: candidate.atomId,
                confidence: candidate.confidence,
                wasDisplayed: displayedIds.contains(candidate.atomId)
            )
        }
    }
}
