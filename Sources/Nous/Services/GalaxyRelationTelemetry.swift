import Foundation

struct GalaxyRelationTelemetrySnapshot: Equatable {
    var relationCandidateCount = 0
    var refinedCandidateCount = 0
    var localVerdictCount = 0
    var localNilCount = 0
    var llmVerdictCount = 0
    var llmNilCount = 0
    var llmFallbackCount = 0
    var semanticEdgeWriteCount = 0
    var sharedEdgeWriteCount = 0
    var queueEnqueuedCount = 0
    var queueDedupedCount = 0
    var queueDisabledDropCount = 0
    var queueStartedCount = 0
    var queueRetryCount = 0
    var queuePermanentFailureCount = 0
    var queueBudgetWaitCount = 0
}

enum GalaxyRelationTelemetryEvent {
    case relationCandidates(Int)
    case refinedCandidates(Int)
    case localVerdict
    case localNil
    case llmVerdict
    case llmNil
    case llmFallback
    case semanticEdgeWrite
    case sharedEdgeWrites(Int)
    case queueEnqueued
    case queueDeduped
    case queueDisabledDrop(Int)
    case queueStarted
    case queueRetry
    case queuePermanentFailure
    case queueBudgetWait
}

final class GalaxyRelationTelemetry {
    private let lock = NSLock()
    private var counters = GalaxyRelationTelemetrySnapshot()

    func record(_ event: GalaxyRelationTelemetryEvent) {
        withLock {
            switch event {
            case .relationCandidates(let count):
                counters.relationCandidateCount += count
            case .refinedCandidates(let count):
                counters.refinedCandidateCount += count
            case .localVerdict:
                counters.localVerdictCount += 1
            case .localNil:
                counters.localNilCount += 1
            case .llmVerdict:
                counters.llmVerdictCount += 1
            case .llmNil:
                counters.llmNilCount += 1
            case .llmFallback:
                counters.llmFallbackCount += 1
            case .semanticEdgeWrite:
                counters.semanticEdgeWriteCount += 1
            case .sharedEdgeWrites(let count):
                counters.sharedEdgeWriteCount += count
            case .queueEnqueued:
                counters.queueEnqueuedCount += 1
            case .queueDeduped:
                counters.queueDedupedCount += 1
            case .queueDisabledDrop(let count):
                counters.queueDisabledDropCount += count
            case .queueStarted:
                counters.queueStartedCount += 1
            case .queueRetry:
                counters.queueRetryCount += 1
            case .queuePermanentFailure:
                counters.queuePermanentFailureCount += 1
            case .queueBudgetWait:
                counters.queueBudgetWaitCount += 1
            }
        }
    }

    func snapshot() -> GalaxyRelationTelemetrySnapshot {
        withLock { counters }
    }

    func resetForTesting() {
        withLock {
            counters = GalaxyRelationTelemetrySnapshot()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
