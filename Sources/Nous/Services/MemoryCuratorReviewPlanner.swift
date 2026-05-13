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

struct MemoryAtomCuratorReviewItem: Codable, Identifiable {
    var id: UUID { atom.id }
    let atom: MemoryAtom
    let issue: MemoryCuratorReviewIssue
    let recommendedAction: MemoryCuratorRecommendedAction
    let relatedAtomIds: [UUID]
    let reason: String
}

struct MemoryAtomCuratorReviewPlan: Codable {
    let generatedAt: Date
    let items: [MemoryAtomCuratorReviewItem]

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

    func plan(
        atoms: [MemoryAtom],
        hasSourceEvidence: ((MemoryAtom) -> Bool)? = nil
    ) -> MemoryAtomCuratorReviewPlan {
        let generatedAt = now()
        let activeAtoms = atoms
            .filter { $0.status == .active }
            .sorted { left, right in
                if left.updatedAt == right.updatedAt {
                    return left.id.uuidString < right.id.uuidString
                }
                return left.updatedAt < right.updatedAt
            }

        let duplicateIds = duplicateRelationships(in: activeAtoms)
        let items = activeAtoms.compactMap { atom -> MemoryAtomCuratorReviewItem? in
            reviewItem(
                for: atom,
                duplicateIds: duplicateIds[atom.id] ?? [],
                generatedAt: generatedAt,
                hasSourceEvidence: hasSourceEvidence
            )
        }
        .sorted(by: Self.sortAtomReviewItems)

        return MemoryAtomCuratorReviewPlan(
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

    private func reviewItem(
        for atom: MemoryAtom,
        duplicateIds: [UUID],
        generatedAt: Date,
        hasSourceEvidence: ((MemoryAtom) -> Bool)?
    ) -> MemoryAtomCuratorReviewItem? {
        if let validUntil = atom.validUntil, validUntil <= generatedAt {
            return MemoryAtomCuratorReviewItem(
                atom: atom,
                issue: .expiredStillActive,
                recommendedAction: .archiveOrRefresh,
                relatedAtomIds: [],
                reason: "memory atom is past validUntil but still active"
            )
        }

        if shouldRequireEvidence(atom) {
            let sourceEvidenceExists = hasSourceEvidence?(atom)
                ?? (atom.sourceNodeId != nil || atom.sourceMessageId != nil)
            if !sourceEvidenceExists {
                return MemoryAtomCuratorReviewItem(
                    atom: atom,
                    issue: .missingSourceEvidence,
                    recommendedAction: .findEvidenceOrQuarantine,
                    relatedAtomIds: [],
                    reason: "durable memory atom has no source evidence"
                )
            }
        }

        if !duplicateIds.isEmpty {
            return MemoryAtomCuratorReviewItem(
                atom: atom,
                issue: .possibleDuplicate,
                recommendedAction: .mergeOrArchiveDuplicate,
                relatedAtomIds: duplicateIds,
                reason: "same scope and type contain the same normalized active memory atom"
            )
        }

        if atom.confidence < lowConfidenceThreshold {
            return MemoryAtomCuratorReviewItem(
                atom: atom,
                issue: .lowConfidence,
                recommendedAction: .reviewConfidence,
                relatedAtomIds: [],
                reason: "memory atom confidence is below curator review threshold"
            )
        }

        let lastTouchedAt = atom.lastSeenAt ?? atom.updatedAt
        if shouldRequireStaleConfirmation(atom),
           generatedAt.timeIntervalSince(lastTouchedAt) >= staleConfirmationInterval {
            return MemoryAtomCuratorReviewItem(
                atom: atom,
                issue: .staleConfirmation,
                recommendedAction: .askForConfirmation,
                relatedAtomIds: [],
                reason: "durable memory atom has not been seen or refreshed recently"
            )
        }

        return nil
    }

    private func duplicateRelationships(in atoms: [MemoryAtom]) -> [UUID: [UUID]] {
        var firstAtomByKey: [AtomDuplicateKey: MemoryAtom] = [:]
        var duplicateIdsByAtomId: [UUID: [UUID]] = [:]

        for atom in atoms {
            let key = AtomDuplicateKey(atom: atom)
            guard !key.normalizedStatement.isEmpty else { continue }

            if let first = firstAtomByKey[key] {
                duplicateIdsByAtomId[atom.id, default: []].append(first.id)
            } else {
                firstAtomByKey[key] = atom
            }
        }

        return duplicateIdsByAtomId
    }

    private func shouldRequireEvidence(_ entry: MemoryEntry) -> Bool {
        entry.stability == .stable &&
            entry.scope != .conversation &&
            entry.kind != .temporaryContext
    }

    private func shouldRequireEvidence(_ atom: MemoryAtom) -> Bool {
        atom.scope != .conversation &&
            atom.scope != .selfReflection &&
            Self.evidenceRequiredAtomTypes.contains(atom.type)
    }

    private func shouldRequireStaleConfirmation(_ atom: MemoryAtom) -> Bool {
        Self.staleConfirmationAtomTypes.contains(atom.type)
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

    private static func sortAtomReviewItems(
        _ left: MemoryAtomCuratorReviewItem,
        _ right: MemoryAtomCuratorReviewItem
    ) -> Bool {
        if priority(left.issue) != priority(right.issue) {
            return priority(left.issue) < priority(right.issue)
        }
        if left.atom.updatedAt != right.atom.updatedAt {
            return left.atom.updatedAt > right.atom.updatedAt
        }
        return left.atom.id.uuidString < right.atom.id.uuidString
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

    private static let evidenceRequiredAtomTypes: Set<MemoryAtomType> = [
        .identity,
        .preference,
        .rule,
        .boundary,
        .constraint,
        .goal,
        .plan,
        .belief
    ]

    private static let staleConfirmationAtomTypes: Set<MemoryAtomType> = [
        .identity,
        .preference,
        .rule,
        .boundary,
        .constraint,
        .goal,
        .plan,
        .belief,
        .currentPosition
    ]
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

private struct AtomDuplicateKey: Hashable {
    let scope: MemoryScope
    let scopeRefId: UUID?
    let type: MemoryAtomType
    let normalizedStatement: String

    init(atom: MemoryAtom) {
        self.scope = atom.scope
        self.scopeRefId = atom.scopeRefId
        self.type = atom.type
        self.normalizedStatement = Self.normalized(
            atom.normalizedKey.map(Self.statementPortion(from:)) ?? atom.statement
        )
    }

    private static func statementPortion(from normalizedKey: String) -> String {
        normalizedKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .first
            .map(String.init) ?? normalizedKey
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
