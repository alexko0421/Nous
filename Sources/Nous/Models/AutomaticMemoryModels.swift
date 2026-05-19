import Foundation

enum MemoryTensionKind: String, Codable, CaseIterable {
    case anchorConflict = "anchor_conflict"
    case durableConflict = "durable_conflict"
}

enum MemoryTensionStatus: String, Codable, CaseIterable {
    case open
    case resolved
}

struct MemoryTension: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: MemoryTensionKind
    var status: MemoryTensionStatus
    var existingAtomId: UUID?
    var challengerAtomId: UUID?
    var summary: String
    var createdAt: Date
    var resolvedAt: Date?

    init(
        id: UUID = UUID(),
        kind: MemoryTensionKind,
        status: MemoryTensionStatus = .open,
        existingAtomId: UUID?,
        challengerAtomId: UUID?,
        summary: String,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.existingAtomId = existingAtomId
        self.challengerAtomId = challengerAtomId
        self.summary = summary
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

struct MemoryScene: Identifiable, Codable, Equatable {
    let id: UUID
    var scope: MemoryScope
    var scopeRefId: UUID?
    var title: String
    var summary: String
    var status: MemoryStatus
    var authority: MemoryAuthority
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        scope: MemoryScope,
        scopeRefId: UUID? = nil,
        title: String,
        summary: String,
        status: MemoryStatus = .active,
        authority: MemoryAuthority = .tentative,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.scopeRefId = scopeRefId
        self.title = title
        self.summary = summary
        self.status = status
        self.authority = authority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct LivingSelfModel: Identifiable, Codable, Equatable {
    let id: UUID
    var scope: MemoryScope
    var scopeRefId: UUID?
    var summary: String
    var authority: MemoryAuthority
    var sourceSceneIds: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        scope: MemoryScope,
        scopeRefId: UUID? = nil,
        summary: String,
        authority: MemoryAuthority = .tentative,
        sourceSceneIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.scopeRefId = scopeRefId
        self.summary = summary
        self.authority = authority
        self.sourceSceneIds = sourceSceneIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct DerivedMemorySceneContext: Equatable {
    let scene: MemoryScene
    let sourceAtomIds: [UUID]
}

struct DerivedMemoryPromptContext: Equatable {
    static let empty = DerivedMemoryPromptContext()

    var scenes: [DerivedMemorySceneContext]
    var selfModel: LivingSelfModel?

    init(
        scenes: [DerivedMemorySceneContext] = [],
        selfModel: LivingSelfModel? = nil
    ) {
        self.scenes = scenes
        self.selfModel = selfModel
    }

    var isEmpty: Bool {
        scenes.isEmpty && selfModel == nil
    }

    var promptBlock: String? {
        guard !isEmpty else { return nil }

        var lines: [String] = [
            "DERIVED MEMORY CONTEXT:",
            "Use this as sourced, provisional synthesis. It may help connect patterns, but it must never replace anchor.md, durable memory, explicit corrections, or direct source evidence."
        ]

        for (index, item) in scenes.prefix(3).enumerated() {
            lines.append("")
            lines.append("[Scene \(index + 1)] \(item.scene.title) authority=\(item.scene.authority.rawValue) scope=\(item.scene.scope.rawValue)")
            lines.append(item.scene.summary)
            if !item.sourceAtomIds.isEmpty {
                lines.append("source_atom_ids=\(item.sourceAtomIds.map(\.uuidString).joined(separator: ","))")
            }
        }

        if let selfModel {
            lines.append("")
            lines.append("[Living self-model] authority=\(selfModel.authority.rawValue)")
            lines.append(selfModel.summary)
            if !selfModel.sourceSceneIds.isEmpty {
                lines.append("source_scene_ids=\(selfModel.sourceSceneIds.map(\.uuidString).joined(separator: ","))")
            }
        }

        return lines.joined(separator: "\n")
    }
}

struct AutomaticMemoryDigestRequest {
    let turnId: UUID
    let conversationId: UUID
    let projectId: UUID?
    let userMessage: Message
    let assistantMessage: Message
    let sourceMaterials: [SourceMaterialContext]
}

struct AutomaticMemoryDigestResult: Equatable {
    static let empty = AutomaticMemoryDigestResult(activeCount: 0, pendingCount: 0, rejectedCount: 0)

    let activeCount: Int
    let pendingCount: Int
    let rejectedCount: Int

    var insertedCount: Int {
        activeCount + pendingCount
    }

    init(activeCount: Int, pendingCount: Int, rejectedCount: Int) {
        self.activeCount = activeCount
        self.pendingCount = pendingCount
        self.rejectedCount = rejectedCount
    }

    init(insertedCount: Int, rejectedCount: Int) {
        self.init(activeCount: insertedCount, pendingCount: 0, rejectedCount: rejectedCount)
    }
}

enum MemoryActivitySource: String, Equatable, Sendable {
    case automatic
    case sourceLearning
}

enum MemoryActivityStage: String, Equatable, Sendable {
    case idle
    case queued
    case completed
    case skipped
}

struct MemoryActivityEvent: Equatable, Sendable {
    let source: MemoryActivitySource
    let turnId: UUID?
    let conversationId: UUID
    let activeCount: Int
    let pendingCount: Int
    let rejectedCount: Int
    let recordedAt: Date
}

struct MemoryActivitySnapshot: Equatable, Sendable {
    static let empty = MemoryActivitySnapshot(
        stage: .idle,
        turnId: nil,
        conversationId: nil,
        automaticQueued: false,
        sourceLearningQueued: false,
        conversationRefreshQueued: false,
        activeCount: 0,
        pendingCount: 0,
        rejectedCount: 0,
        skippedReason: nil,
        recordedSources: [],
        updatedAt: nil
    )

    var stage: MemoryActivityStage
    var turnId: UUID?
    var conversationId: UUID?
    var automaticQueued: Bool
    var sourceLearningQueued: Bool
    var conversationRefreshQueued: Bool
    var activeCount: Int
    var pendingCount: Int
    var rejectedCount: Int
    var skippedReason: MemorySuppressionReason?
    var recordedSources: Set<MemoryActivitySource>
    var updatedAt: Date?

    var isVisible: Bool {
        stage != .idle
    }

    var summaryText: String {
        switch stage {
        case .idle:
            return ""
        case .queued:
            if automaticQueued || sourceLearningQueued {
                return "Memory check queued"
            }
            return conversationRefreshQueued ? "Conversation memory refresh queued" : "Memory check queued"
        case .completed:
            let savedText = activeCount == 1 ? "1 saved" : "\(activeCount) saved"
            let reviewText = pendingCount == 1 ? "1 for review" : "\(pendingCount) for review"
            let skippedText = rejectedCount > 0 ? " · \(rejectedCount) skipped" : ""
            return "Memory updated: \(savedText) · \(reviewText)\(skippedText)"
        case .skipped:
            return "Memory skipped: \(skippedReason?.displayText ?? "not persisted")"
        }
    }

    static func queued(from plan: ContextContinuationPlan, now: Date = Date()) -> MemoryActivitySnapshot {
        if let reason = plan.memorySuppressionReason {
            return MemoryActivitySnapshot(
                stage: .skipped,
                turnId: plan.turnId,
                conversationId: plan.conversationId,
                automaticQueued: false,
                sourceLearningQueued: false,
                conversationRefreshQueued: false,
                activeCount: 0,
                pendingCount: 0,
                rejectedCount: 0,
                skippedReason: reason,
                recordedSources: [],
                updatedAt: now
            )
        }

        let hasQueuedWork = plan.automaticMemoryDigest != nil ||
            plan.sourceLearningDigest != nil ||
            plan.memoryRefresh != nil
        guard hasQueuedWork else { return .empty }

        return MemoryActivitySnapshot(
            stage: .queued,
            turnId: plan.turnId,
            conversationId: plan.conversationId,
            automaticQueued: plan.automaticMemoryDigest != nil,
            sourceLearningQueued: plan.sourceLearningDigest != nil,
            conversationRefreshQueued: plan.memoryRefresh != nil,
            activeCount: 0,
            pendingCount: 0,
            rejectedCount: 0,
            skippedReason: nil,
            recordedSources: [],
            updatedAt: now
        )
    }

    func recording(_ event: MemoryActivityEvent) -> MemoryActivitySnapshot {
        guard stage == .queued || stage == .completed else {
            return self
        }
        if let conversationId, conversationId != event.conversationId {
            return self
        }
        if let turnId, event.turnId != turnId {
            return self
        }
        if recordedSources.contains(event.source) {
            return self
        }

        var copy = self
        copy.stage = .completed
        copy.turnId = turnId ?? event.turnId
        copy.conversationId = conversationId ?? event.conversationId
        copy.activeCount += event.activeCount
        copy.pendingCount += event.pendingCount
        copy.rejectedCount += event.rejectedCount
        copy.recordedSources.insert(event.source)
        copy.updatedAt = event.recordedAt
        return copy
    }
}

private extension MemorySuppressionReason {
    var displayText: String {
        switch self {
        case .hardOptOut:
            return "opted out"
        case .sensitiveConsentRequired:
            return "needs consent"
        case .fastLatencyTier:
            return "fast mode"
        case .unspecified:
            return "not persisted"
        }
    }
}

struct AutomaticDerivedMemoryResult: Equatable {
    static let empty = AutomaticDerivedMemoryResult(sceneCount: 0, selfModelCount: 0)

    let sceneCount: Int
    let selfModelCount: Int
}
