import Foundation

enum MemoryCuratorReviewIssue: String, Codable, Equatable {
    case expiredStillActive = "expired_still_active"
    case staleConfirmation = "stale_confirmation"
    case missingSourceEvidence = "missing_source_evidence"
    case lowConfidence = "low_confidence"
    case possibleDuplicate = "possible_duplicate"
}

enum MemoryCuratorRecommendedAction: String, Codable, Equatable {
    case archiveOrRefresh = "archive_or_refresh"
    case askForConfirmation = "ask_for_confirmation"
    case findEvidenceOrQuarantine = "find_evidence_or_quarantine"
    case reviewConfidence = "review_confidence"
    case mergeOrArchiveDuplicate = "merge_or_archive_duplicate"
}

struct MemoryCuratorReviewItem: Codable, Identifiable {
    var id: UUID { entry.id }
    let entry: MemoryEntry
    let issue: MemoryCuratorReviewIssue
    let recommendedAction: MemoryCuratorRecommendedAction
    let relatedEntryIds: [UUID]
    let reason: String
}

struct MemoryCuratorReviewPlan: Codable {
    let generatedAt: Date
    let items: [MemoryCuratorReviewItem]

    var isEmpty: Bool {
        items.isEmpty
    }
}

final class MemoryCuratorReviewPlanner {
    private let now: () -> Date
    private let staleConfirmationInterval: TimeInterval
    private let lowConfidenceThreshold: Double
    private let maxItems: Int

    init(
        now: @escaping () -> Date = Date.init,
        staleConfirmationInterval: TimeInterval = 45 * 24 * 60 * 60,
        lowConfidenceThreshold: Double = 0.55,
        maxItems: Int = 25
    ) {
        self.now = now
        self.staleConfirmationInterval = staleConfirmationInterval
        self.lowConfidenceThreshold = lowConfidenceThreshold
        self.maxItems = max(1, maxItems)
    }

    func plan(
        entries: [MemoryEntry],
        hasSourceEvidence: ((MemoryEntry) -> Bool)? = nil
    ) -> MemoryCuratorReviewPlan {
        let generatedAt = now()
        let activeEntries = entries
            .filter { $0.status == .active }
            .sorted { left, right in
                if left.updatedAt == right.updatedAt {
                    return left.id.uuidString < right.id.uuidString
                }
                return left.updatedAt < right.updatedAt
            }

        let duplicateIds = duplicateRelationships(in: activeEntries)
        let items = activeEntries.compactMap { entry -> MemoryCuratorReviewItem? in
            reviewItem(
                for: entry,
                duplicateIds: duplicateIds[entry.id] ?? [],
                generatedAt: generatedAt,
                hasSourceEvidence: hasSourceEvidence
            )
        }
        .sorted(by: Self.sortReviewItems)

        return MemoryCuratorReviewPlan(
            generatedAt: generatedAt,
            items: Array(items.prefix(maxItems))
        )
    }

    private func reviewItem(
        for entry: MemoryEntry,
        duplicateIds: [UUID],
        generatedAt: Date,
        hasSourceEvidence: ((MemoryEntry) -> Bool)?
    ) -> MemoryCuratorReviewItem? {
        if let expiresAt = entry.expiresAt, expiresAt <= generatedAt {
            return MemoryCuratorReviewItem(
                entry: entry,
                issue: .expiredStillActive,
                recommendedAction: .archiveOrRefresh,
                relatedEntryIds: [],
                reason: "temporary memory expired but is still active"
            )
        }

        if shouldRequireEvidence(entry) {
            let sourceEvidenceExists = hasSourceEvidence?(entry) ?? !entry.sourceNodeIds.isEmpty
            if !sourceEvidenceExists {
                return MemoryCuratorReviewItem(
                    entry: entry,
                    issue: .missingSourceEvidence,
                    recommendedAction: .findEvidenceOrQuarantine,
                    relatedEntryIds: [],
                    reason: "durable memory has no source node evidence"
                )
            }
        }

        if !duplicateIds.isEmpty {
            return MemoryCuratorReviewItem(
                entry: entry,
                issue: .possibleDuplicate,
                recommendedAction: .mergeOrArchiveDuplicate,
                relatedEntryIds: duplicateIds,
                reason: "same scope and kind contain the same normalized active memory"
            )
        }

        if entry.confidence < lowConfidenceThreshold {
            return MemoryCuratorReviewItem(
                entry: entry,
                issue: .lowConfidence,
                recommendedAction: .reviewConfidence,
                relatedEntryIds: [],
                reason: "confidence is below curator review threshold"
            )
        }

        let lastConfirmedAt = entry.lastConfirmedAt ?? entry.updatedAt
        if entry.stability == .stable,
           generatedAt.timeIntervalSince(lastConfirmedAt) >= staleConfirmationInterval {
            return MemoryCuratorReviewItem(
                entry: entry,
                issue: .staleConfirmation,
                recommendedAction: .askForConfirmation,
                relatedEntryIds: [],
                reason: "stable memory has not been confirmed recently"
            )
        }

        return nil
    }

    private func duplicateRelationships(in entries: [MemoryEntry]) -> [UUID: [UUID]] {
        var firstEntryByKey: [DuplicateKey: MemoryEntry] = [:]
        var duplicateIdsByEntryId: [UUID: [UUID]] = [:]

        for entry in entries {
            let key = DuplicateKey(entry: entry)
            guard !key.normalizedContent.isEmpty else { continue }

            if let first = firstEntryByKey[key] {
                duplicateIdsByEntryId[entry.id, default: []].append(first.id)
            } else {
                firstEntryByKey[key] = entry
            }
        }

        return duplicateIdsByEntryId
    }

    private func shouldRequireEvidence(_ entry: MemoryEntry) -> Bool {
        entry.stability == .stable &&
            entry.scope != .conversation &&
            entry.kind != .temporaryContext
    }

    private static func sortReviewItems(
        _ left: MemoryCuratorReviewItem,
        _ right: MemoryCuratorReviewItem
    ) -> Bool {
        if priority(left.issue) != priority(right.issue) {
            return priority(left.issue) < priority(right.issue)
        }
        if left.entry.updatedAt != right.entry.updatedAt {
            return left.entry.updatedAt > right.entry.updatedAt
        }
        return left.entry.id.uuidString < right.entry.id.uuidString
    }

    private static func priority(_ issue: MemoryCuratorReviewIssue) -> Int {
        switch issue {
        case .expiredStillActive:
            return 0
        case .missingSourceEvidence:
            return 1
        case .possibleDuplicate:
            return 2
        case .lowConfidence:
            return 3
        case .staleConfirmation:
            return 4
        }
    }
}

private struct DuplicateKey: Hashable {
    let scope: MemoryScope
    let scopeRefId: UUID?
    let kind: MemoryKind
    let normalizedContent: String

    init(entry: MemoryEntry) {
        self.scope = entry.scope
        self.scopeRefId = entry.scopeRefId
        self.kind = entry.kind
        self.normalizedContent = Self.normalized(entry.content)
    }

    private static func normalized(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let numberNormalized = lowered
            .replacingOccurrences(of: "phase one", with: "phase 1")
            .replacingOccurrences(of: "phase-one", with: "phase 1")
            .replacingOccurrences(of: "phase_one", with: "phase 1")
        let scalars = numberNormalized.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
