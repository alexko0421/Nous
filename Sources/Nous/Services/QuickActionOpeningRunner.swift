import Foundation

final class QuickActionOpeningRunner {
    private let conversationSessionStore: ConversationSessionStore
    private let memoryContextBuilder: TurnMemoryContextBuilder
    private let turnExecutor: TurnExecutor
    private let outcomeFactory: TurnOutcomeFactory
    private let currentProviderProvider: () -> LLMProvider
    private let quickActionAddendumResolver: QuickActionAddendumResolver
    private let cognitionReviewer: (any CognitionReviewing)?
    private let shouldSurfaceThinkingTraces: () -> Bool
    private let onPlanReady: (TurnPlan) -> Void
    private let onReviewArtifact: (CognitionArtifact) -> Void
    private let onTurnCognitionSnapshot: (TurnCognitionSnapshot) -> Void
    private let onContextManifest: (ContextManifestRecord) -> Void

    init(
        conversationSessionStore: ConversationSessionStore,
        memoryContextBuilder: TurnMemoryContextBuilder,
        turnExecutor: TurnExecutor,
        outcomeFactory: TurnOutcomeFactory,
        currentProviderProvider: @escaping () -> LLMProvider = { .local },
        skillStore: (any SkillStoring)? = nil,
        skillMatcher: any SkillMatching = SkillMatcher(),
        skillTracker: (any SkillTracking)? = nil,
        cognitionReviewer: (any CognitionReviewing)? = nil,
        shouldSurfaceThinkingTraces: @escaping () -> Bool = { true },
        onPlanReady: @escaping (TurnPlan) -> Void = { _ in },
        onReviewArtifact: @escaping (CognitionArtifact) -> Void = { _ in },
        onTurnCognitionSnapshot: @escaping (TurnCognitionSnapshot) -> Void = { _ in },
        onContextManifest: @escaping (ContextManifestRecord) -> Void = { _ in }
    ) {
        self.conversationSessionStore = conversationSessionStore
        self.memoryContextBuilder = memoryContextBuilder
        self.turnExecutor = turnExecutor
        self.outcomeFactory = outcomeFactory
        self.currentProviderProvider = currentProviderProvider
        self.quickActionAddendumResolver = QuickActionAddendumResolver(
            skillStore: skillStore,
            skillMatcher: skillMatcher,
            skillTracker: skillTracker
        )
        self.cognitionReviewer = cognitionReviewer
        self.shouldSurfaceThinkingTraces = shouldSurfaceThinkingTraces
        self.onPlanReady = onPlanReady
        self.onReviewArtifact = onReviewArtifact
        self.onTurnCognitionSnapshot = onTurnCognitionSnapshot
        self.onContextManifest = onContextManifest
    }

    func run(
        mode: QuickActionMode,
        node: NousNode,
        turnId: UUID,
        sink: TurnSequencedEventSink,
        abortReason: () -> TurnAbortReason
    ) async -> TurnCompletion? {
        let plan: TurnPlan
        do {
            plan = try makePlan(mode: mode, node: node, turnId: turnId)
        } catch {
            await sink.emit(.failed(TurnFailure(stage: .planning, message: error.localizedDescription)))
            return nil
        }

        onPlanReady(plan)
        await sink.emit(.prepared(outcomeFactory.makePrepared(from: plan)))

        do {
            try Task.checkCancellation()
        } catch {
            await sink.emit(.aborted(abortReason()))
            return nil
        }

        let executionResult: TurnExecutionResult
        do {
            guard let result = try await turnExecutor.execute(
                plan: plan,
                sink: sink,
                captureThinking: shouldSurfaceThinkingTraces()
            ) else {
                await sink.emit(.aborted(abortReason()))
                return nil
            }
            executionResult = result
        } catch let failure as TurnExecutionFailure {
            await sink.emit(.failed(turnFailure(from: failure)))
            return nil
        } catch {
            await sink.emit(.failed(TurnFailure(stage: .execution, message: error.localizedDescription)))
            return nil
        }

        let committed: CommittedAssistantTurn
        do {
            committed = try conversationSessionStore.commitAssistantTurn(
                nodeId: node.id,
                currentMessages: [],
                assistantContent: executionResult.assistantContent,
                thinkingContent: executionResult.persistedThinking,
                conversationTitle: executionResult.conversationTitle
            )
        } catch {
            await sink.emit(.failed(TurnFailure(stage: .commit, message: error.localizedDescription)))
            return nil
        }

        let reviewArtifact = runSilentReviewIfNeeded(
            plan: plan,
            executionResult: executionResult,
            committed: committed
        )
        onTurnCognitionSnapshot(TurnCognitionSnapshotFactory.make(
            plan: plan,
            committed: committed,
            reviewArtifact: reviewArtifact
        ))
        let contextManifest = ContextManifestFactory.make(
            plan: plan,
            assistantMessageId: committed.assistantMessage.id,
            assistantContent: executionResult.assistantContent,
            agentTraceJson: executionResult.agentTraceJson
        )
        if !contextManifest.resources.isEmpty {
            onContextManifest(contextManifest)
        }

        let completion = outcomeFactory.makeCompletion(
            turnId: turnId,
            nextQuickActionModeIfCompleted: mode,
            committed: committed,
            assistantContent: executionResult.assistantContent,
            stableSystem: plan.turnSlice.stable
        )
        await sink.emit(.completed(completion))
        return completion
    }

    private func runSilentReviewIfNeeded(
        plan: TurnPlan,
        executionResult: TurnExecutionResult,
        committed: CommittedAssistantTurn
    ) -> CognitionArtifact? {
        guard let cognitionReviewer else { return nil }

        do {
            if let artifact = try cognitionReviewer.review(
                plan: plan,
                executionResult: executionResult
            ) {
                let auditedArtifact = artifact.replacingHiddenOpeningPromptReference(
                    hiddenMessageId: plan.prepared.userMessage.id,
                    assistantMessage: committed.assistantMessage
                )
                onReviewArtifact(auditedArtifact)
                return auditedArtifact
            }
        } catch {
            #if DEBUG
            NSLog("[NousTurn] opening silent reviewer failed turn=%@ error=%@", plan.turnId.uuidString, error.localizedDescription)
            #endif
        }
        return nil
    }

    private func makePlan(mode: QuickActionMode, node: NousNode, turnId: UUID) throws -> TurnPlan {
        let agent = mode.agent()
        let openingText = agent.openingPrompt()
        let memoryContext = try memoryContextBuilder.build(
            retrievalQuery: openingText,
            promptQuery: openingText,
            node: node,
            policy: Self.openingPolicy(from: agent.memoryPolicy()),
            now: Date()
        )
        #if DEBUG
        DebugAblation.logActiveFlags(context: "quick-mode-opening:\(mode)")
        #endif

        let quickActionResolution = quickActionAddendumResolver.resolution(
            mode: mode,
            agent: agent,
            turnIndex: 0,
            conversationID: node.id
        )
        let quickActionAddendum = quickActionResolution.addendum
        let provider = currentProviderProvider()
        let agentCoordination = AgentCoordinationTrace(
            executionMode: .singleShot,
            quickActionMode: mode,
            provider: provider,
            reason: .modeSingleShotByContract,
            indexedSkillCount: 0
        )

        let turnSlice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: openingText,
            operatingContext: memoryContext.operatingContext,
            globalMemory: memoryContext.globalMemory,
            essentialStory: memoryContext.essentialStory,
            userModel: memoryContext.userModel,
            memoryEvidence: memoryContext.memoryEvidence,
            memoryGraphRecall: memoryContext.memoryGraphRecall,
            projectMemory: memoryContext.projectMemory,
            conversationMemory: memoryContext.conversationMemory,
            recentConversations: memoryContext.recentConversations,
            citations: memoryContext.citations,
            projectGoal: memoryContext.projectGoal,
            activeQuickActionMode: mode,
            loadedSkills: quickActionResolution.loadedSkills,
            matchedSkills: quickActionResolution.matchedSkills,
            quickActionAddendum: quickActionAddendum,
            allowSkillIndex: false,
            allowInteractiveClarification: false
        )
        let promptResourceIds = PromptContextAssembler.promptResourceIds(
            operatingContext: memoryContext.operatingContext,
            globalMemory: memoryContext.globalMemory,
            essentialStory: memoryContext.essentialStory,
            userModel: memoryContext.userModel,
            memoryEvidence: memoryContext.memoryEvidence,
            projectMemory: memoryContext.projectMemory,
            conversationMemory: memoryContext.conversationMemory,
            recentConversations: memoryContext.recentConversations,
            citations: memoryContext.citations,
            projectGoal: memoryContext.projectGoal
        )
        let promptTrace = PromptContextAssembler.governanceTrace(
            chatMode: .companion,
            currentUserInput: openingText,
            operatingContext: memoryContext.operatingContext,
            globalMemory: memoryContext.globalMemory,
            essentialStory: memoryContext.essentialStory,
            userModel: memoryContext.userModel,
            memoryEvidence: memoryContext.memoryEvidence,
            memoryGraphRecall: memoryContext.memoryGraphRecall,
            projectMemory: memoryContext.projectMemory,
            conversationMemory: memoryContext.conversationMemory,
            recentConversations: memoryContext.recentConversations,
            citations: memoryContext.citations,
            projectGoal: memoryContext.projectGoal,
            attachments: [],
            activeQuickActionMode: mode,
            quickActionAddendum: quickActionAddendum,
            allowInteractiveClarification: false,
            agentCoordination: agentCoordination
        )
        let syntheticUserMessage = Message(nodeId: node.id, role: .user, content: openingText)
        let prepared = PreparedConversationTurn(
            node: node,
            userMessage: syntheticUserMessage,
            messagesAfterUserAppend: []
        )

        return TurnPlan(
            turnId: turnId,
            prepared: prepared,
            citations: memoryContext.citations,
            promptTrace: promptTrace,
            effectiveMode: .companion,
            nextQuickActionModeIfCompleted: mode,
            judgeEventDraft: nil,
            turnSlice: turnSlice,
            transcriptMessages: [LLMMessage(role: "user", content: openingText)],
            focusBlock: nil,
            provider: provider,
            loadedSkillIds: Set(quickActionResolution.loadedSkills.map(\.skillID)),
            memoryEvidenceSourceIds: promptResourceIds.memoryEvidenceSourceIds,
            loadedCitationIds: promptResourceIds.citationIds
        )
    }

    private static func openingPolicy(from policy: QuickActionMemoryPolicy) -> QuickActionMemoryPolicy {
        policy.with(
            includeRecentConversations: false,
            includeCitations: false,
            includeContradictionRecall: false,
            includeJudgeFocus: false
        )
    }

    private func turnFailure(from failure: TurnExecutionFailure) -> TurnFailure {
        switch failure {
        case .invalidPlan(let message):
            return TurnFailure(stage: .planning, message: message)
        case .infrastructure(let message):
            return TurnFailure(stage: .execution, message: message)
        }
    }
}

private extension CognitionArtifact {
    func replacingHiddenOpeningPromptReference(
        hiddenMessageId: UUID,
        assistantMessage: Message
    ) -> CognitionArtifact {
        let hiddenId = hiddenMessageId.uuidString
        var changed = false
        let auditedRefs = evidenceRefs.map { ref in
            guard ref.source == .message, ref.id == hiddenId else { return ref }
            changed = true
            return CognitionEvidenceRef(
                source: .message,
                id: assistantMessage.id.uuidString,
                quote: assistantMessage.content
            )
        }

        guard changed else { return self }
        return CognitionArtifact(
            id: id,
            organ: organ,
            title: title,
            summary: summary,
            confidence: confidence,
            jurisdiction: jurisdiction,
            evidenceRefs: auditedRefs,
            suggestedSurfacing: suggestedSurfacing,
            riskFlags: riskFlags,
            trace: trace,
            createdAt: createdAt
        )
    }
}
