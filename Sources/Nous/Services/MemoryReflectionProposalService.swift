import Foundation

struct MemoryReflectionApprovalResult: Equatable {
    let approvedAtom: MemoryAtom?
    let reflectionProposal: MemoryReflectionProposalResult?
}

final class MemoryReflectionProposalService {
    private let nodeStore: NodeStore
    private let llmServiceProvider: () -> (any LLMService)?
    private let embed: (String) -> [Float]?
    private let sourceLimit: Int
    private let minimumSources: Int
    private let synthesizeInsight: (([MemoryAtom]) -> String?)?

    init(
        nodeStore: NodeStore,
        llmServiceProvider: @escaping () -> (any LLMService)? = { nil },
        embed: @escaping (String) -> [Float]? = { _ in nil },
        sourceLimit: Int = 8,
        minimumSources: Int = 3,
        synthesizeInsight: (([MemoryAtom]) -> String?)? = nil
    ) {
        self.nodeStore = nodeStore
        self.llmServiceProvider = llmServiceProvider
        self.embed = embed
        self.sourceLimit = sourceLimit
        self.minimumSources = minimumSources
        self.synthesizeInsight = synthesizeInsight
    }

    @discardableResult
    func approveAndPropose(
        _ atomId: UUID,
        now: Date = Date()
    ) async throws -> MemoryReflectionApprovalResult {
        let lifecycle = MemoryLifecycleEngine(
            nodeStore: nodeStore,
            embed: embed,
            automaticReflectionMinimumSources: 0,
            reflectionSynthesizeInsight: synthesizeInsight
        )
        guard let approved = try lifecycle.approve(atomId, now: now) else {
            return MemoryReflectionApprovalResult(approvedAtom: nil, reflectionProposal: nil)
        }

        guard approved.status == .active,
              MemoryReflectionEngine.isAutomaticReflectionSource(approved),
              Self.isCurrentlyValid(approved, now: now),
              let context = try reflectionContext(for: approved)
        else {
            return MemoryReflectionApprovalResult(approvedAtom: approved, reflectionProposal: nil)
        }

        let proposal = try await proposeFromApprovedMemory(
            projectId: context.projectId,
            conversationId: context.conversationId,
            now: now
        )
        return MemoryReflectionApprovalResult(approvedAtom: approved, reflectionProposal: proposal)
    }

    @discardableResult
    func proposeFromApprovedMemory(
        projectId: UUID?,
        conversationId: UUID?,
        sourceLimit: Int? = nil,
        minimumSources: Int? = nil,
        now: Date = Date()
    ) async throws -> MemoryReflectionProposalResult? {
        guard try !hasPendingReflectionProposal() else { return nil }

        let summarizer = llmServiceProvider().map { llmService in
            let bridge = MemoryReflectionLLMSummarizer(llmService: llmService)
            return { sources in
                try await bridge.summarize(sources)
            } as MemoryReflectionInsightSummarizer
        }

        return try await MemoryReflectionEngine(
            nodeStore: nodeStore,
            embed: embed,
            synthesizeInsight: synthesizeInsight
        ).proposeSummarizedFromActiveMemory(
            projectId: projectId,
            conversationId: conversationId,
            sourceLimit: sourceLimit ?? self.sourceLimit,
            minimumSources: minimumSources ?? self.minimumSources,
            now: now,
            summarizeInsight: summarizer
        )
    }

    private func reflectionContext(for atom: MemoryAtom) throws -> (projectId: UUID?, conversationId: UUID?)? {
        switch atom.scope {
        case .global:
            return (nil, nil)
        case .project:
            guard let projectId = atom.scopeRefId else { return nil }
            return (projectId, nil)
        case .conversation:
            guard let conversationId = atom.scopeRefId else { return nil }
            let projectId = try nodeStore.fetchNode(id: conversationId)?.projectId
            return (projectId, conversationId)
        case .selfReflection:
            return nil
        }
    }

    private func hasPendingReflectionProposal() throws -> Bool {
        try !nodeStore.fetchMemoryAtoms(
            types: [.insight],
            statuses: [.pending],
            scope: .selfReflection,
            scopeRefId: nil,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: 1
        ).isEmpty
    }

    private static func isCurrentlyValid(_ atom: MemoryAtom, now: Date) -> Bool {
        if let validFrom = atom.validFrom, validFrom > now { return false }
        if let validUntil = atom.validUntil, validUntil <= now { return false }
        return true
    }
}
