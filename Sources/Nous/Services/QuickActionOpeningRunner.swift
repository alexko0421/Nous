import Foundation

final class QuickActionOpeningRunner {
    private let conversationSessionStore: ConversationSessionStore
    private let memoryContextBuilder: TurnMemoryContextBuilder
    private let turnExecutor: TurnExecutor
    private let outcomeFactory: TurnOutcomeFactory
    private let currentProviderProvider: () -> LLMProvider
    private let quickActionAddendumResolver: QuickActionAddendumResolver
    private let onPlanReady: (TurnPlan) -> Void

    init(
        conversationSessionStore: ConversationSessionStore,
        memoryContextBuilder: TurnMemoryContextBuilder,
        turnExecutor: TurnExecutor,
        outcomeFactory: TurnOutcomeFactory,
        currentProviderProvider: @escaping () -> LLMProvider = { .local },
        skillStore: (any SkillStoring)? = nil,
        skillMatcher: any SkillMatching = SkillMatcher(),
        skillTracker: (any SkillTracking)? = nil,
        onPlanReady: @escaping (TurnPlan) -> Void = { _ in }
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
        self.onPlanReady = onPlanReady
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
                captureThinking: true
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

        let turnSlice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: openingText,
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
        let promptTrace = PromptContextAssembler.governanceTrace(
            chatMode: .companion,
            currentUserInput: openingText,
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
            allowInteractiveClarification: false
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
            provider: currentProviderProvider()
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
