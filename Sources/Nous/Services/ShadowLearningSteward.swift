import Foundation

enum ShadowLearningRunResult: Equatable {
    case skippedRecentlyRan
    case skippedInsufficientMessages(Int)
    case updated(patternCount: Int)
    case consolidated(patternCount: Int)
}

final class ShadowLearningSteward {
    private let store: any ShadowLearningStoring
    private let recorder: ShadowLearningSignalRecorder
    private let minNewMessages: Int
    private let maxPatternUpdates: Int
    private let dailyInterval: TimeInterval
    private let weeklyInterval: TimeInterval

    init(
        store: any ShadowLearningStoring,
        minNewMessages: Int = 15,
        maxPatternUpdates: Int = 3,
        dailyInterval: TimeInterval = 24 * 3600,
        weeklyInterval: TimeInterval = 7 * 24 * 3600
    ) {
        self.store = store
        self.recorder = ShadowLearningSignalRecorder(store: store)
        self.minNewMessages = minNewMessages
        self.maxPatternUpdates = maxPatternUpdates
        self.dailyInterval = dailyInterval
        self.weeklyInterval = weeklyInterval
    }

    func runIfDue(
        userId: String = "alex",
        now: Date = Date(),
        force: Bool = false
    ) async -> ShadowLearningRunResult {
        do {
            let state = try store.fetchState(userId: userId)
            if !force,
               let lastRunAt = state.lastRunAt,
               now.timeIntervalSince(lastRunAt) < dailyInterval {
                return .skippedRecentlyRan
            }

            let messages = try store.fetchRecentUserMessages(
                since: state.lastScannedMessageAt,
                afterMessageId: state.lastScannedMessageId,
                limit: 200
            )
            guard messages.count >= minNewMessages else {
                return .skippedInsufficientMessages(messages.count)
            }

            var updateCount = 0
            var lastProcessedMessageAt: Date?
            var lastProcessedMessageId: UUID?
            for message in messages {
                let remainingUpdates = maxPatternUpdates - updateCount
                guard remainingUpdates > 0 else { break }

                let before = try store.fetchPatterns(userId: userId)
                try recorder.recordSignals(
                    from: message,
                    userId: userId,
                    maxSignals: remainingUpdates
                )
                let after = try store.fetchPatterns(userId: userId)
                lastProcessedMessageAt = message.timestamp
                lastProcessedMessageId = message.id

                updateCount += min(changedCountFrom(before: before, after: after), remainingUpdates)
            }

            try store.saveState(ShadowLearningState(
                userId: userId,
                lastRunAt: now,
                lastScannedMessageAt: lastProcessedMessageAt ?? state.lastScannedMessageAt,
                lastScannedMessageId: lastProcessedMessageId ?? state.lastScannedMessageId,
                lastConsolidatedAt: state.lastConsolidatedAt
            ))
            return .updated(patternCount: min(updateCount, maxPatternUpdates))
        } catch {
            print("[ShadowLearning] steward run failed: \(error)")
            return .skippedInsufficientMessages(0)
        }
    }

    func consolidateIfDue(
        userId: String = "alex",
        now: Date = Date(),
        force: Bool = false
    ) async -> ShadowLearningRunResult {
        do {
            let state = try store.fetchState(userId: userId)
            if !force,
               let lastConsolidatedAt = state.lastConsolidatedAt,
               now.timeIntervalSince(lastConsolidatedAt) < weeklyInterval {
                return .skippedRecentlyRan
            }

            let patterns = try store.fetchPatterns(userId: userId)
            var changedCount = 0
            for pattern in patterns {
                let decayed = ShadowPatternLifecycle.afterDecay(pattern, at: now)
                guard decayed != pattern else { continue }

                try store.upsertPattern(decayed)
                try store.appendEvent(LearningEvent(
                    id: UUID(),
                    userId: userId,
                    patternId: decayed.id,
                    sourceMessageId: nil,
                    eventType: decayed.status == .retired ? .retired : .weakened,
                    note: decayed.status == .retired
                        ? "Pattern retired after stale low-weight period."
                        : "Pattern weakened after stale reinforcement period.",
                    createdAt: now
                ))
                changedCount += 1
            }

            try store.saveState(ShadowLearningState(
                userId: userId,
                lastRunAt: state.lastRunAt,
                lastScannedMessageAt: state.lastScannedMessageAt,
                lastScannedMessageId: state.lastScannedMessageId,
                lastConsolidatedAt: now
            ))
            return .consolidated(patternCount: changedCount)
        } catch {
            print("[ShadowLearning] consolidation failed: \(error)")
            return .consolidated(patternCount: 0)
        }
    }

    private func changedCountFrom(
        before: [ShadowLearningPattern],
        after: [ShadowLearningPattern]
    ) -> Int {
        let beforeById = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })

        return after.reduce(into: 0) { count, pattern in
            if beforeById[pattern.id] != pattern {
                count += 1
            }
        }
    }
}
