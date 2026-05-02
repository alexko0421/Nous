import Foundation

typealias AgentLoopExecutorFactory = (
    _ mode: QuickActionMode,
    _ plan: TurnPlan,
    _ request: TurnRequest
) -> AgentLoopExecutor?

final class ChatTurnRunner {
    private let conversationSessionStore: ConversationSessionStore
    private let turnSteward: TurnSteward
    private let turnPlanner: TurnPlanner
    private let turnExecutor: TurnExecutor
    private let agentLoopExecutorFactory: AgentLoopExecutorFactory?
    private let outcomeFactory: TurnOutcomeFactory
    private let shadowLearningSignalRecorder: ShadowLearningSignalRecorder?
    private let cognitionReviewer: (any CognitionReviewing)?
    private let onPlanReady: (TurnPlan) -> Void
    private let onReviewArtifact: (CognitionArtifact) -> Void
    private let onTurnCognitionSnapshot: (TurnCognitionSnapshot) -> Void

    init(
        conversationSessionStore: ConversationSessionStore,
        turnSteward: TurnSteward = TurnSteward(),
        turnPlanner: TurnPlanner,
        turnExecutor: TurnExecutor,
        agentLoopExecutorFactory: AgentLoopExecutorFactory? = nil,
        outcomeFactory: TurnOutcomeFactory,
        shadowLearningSignalRecorder: ShadowLearningSignalRecorder? = nil,
        cognitionReviewer: (any CognitionReviewing)? = nil,
        onPlanReady: @escaping (TurnPlan) -> Void = { _ in },
        onReviewArtifact: @escaping (CognitionArtifact) -> Void = { _ in },
        onTurnCognitionSnapshot: @escaping (TurnCognitionSnapshot) -> Void = { _ in }
    ) {
        self.conversationSessionStore = conversationSessionStore
        self.turnSteward = turnSteward
        self.turnPlanner = turnPlanner
        self.turnExecutor = turnExecutor
        self.agentLoopExecutorFactory = agentLoopExecutorFactory
        self.outcomeFactory = outcomeFactory
        self.shadowLearningSignalRecorder = shadowLearningSignalRecorder
        self.cognitionReviewer = cognitionReviewer
        self.onPlanReady = onPlanReady
        self.onReviewArtifact = onReviewArtifact
        self.onTurnCognitionSnapshot = onTurnCognitionSnapshot
    }

    func run(
        request: TurnRequest,
        sink: TurnSequencedEventSink,
        abortReason: () -> TurnAbortReason
    ) async -> TurnCompletion? {
        Self.debugLog("run start turn=\(request.turnId)")
        let userMessageContent = TurnPlanner.userMessageContent(
            inputText: request.inputText,
            attachments: request.attachments
        )

        let prepared: PreparedTurnSession
        do {
            prepared = try conversationSessionStore.prepareUserTurn(
                currentNode: request.snapshot.currentNode,
                currentMessages: request.snapshot.messages,
                defaultProjectId: request.snapshot.defaultProjectId,
                userMessageContent: userMessageContent
            )
            Self.debugLog("prepared user turn=\(request.turnId) node=\(prepared.node.id) message=\(prepared.userMessage.id)")
        } catch {
            Self.debugLog("prepare failed turn=\(request.turnId) error=\(error.localizedDescription)")
            await sink.emit(
                .failed(TurnFailure(stage: .planning, message: error.localizedDescription))
            )
            return nil
        }

        await sink.emit(
            .userMessageAppended(
                TurnUserMessageAppended(
                    turnId: request.turnId,
                    node: prepared.node,
                    userMessage: prepared.userMessage,
                    messagesAfterUserAppend: prepared.messagesAfterUserAppend
                )
            )
        )

        return await runPreparedTurn(
            prepared: prepared,
            request: request,
            sink: sink,
            abortReason: abortReason
        )
    }

    func runPreparedTurn(
        prepared: PreparedTurnSession,
        request: TurnRequest,
        sink: TurnSequencedEventSink,
        abortReason: () -> TurnAbortReason
    ) async -> TurnCompletion? {
        let stewardship = await turnSteward.steerForTurn(prepared: prepared, request: request)
        if let shadowLearningSignalRecorder {
            do {
                try shadowLearningSignalRecorder.recordSignals(from: prepared.userMessage)
            } catch {
                print("[ShadowLearning] failed to record user signal: \(error)")
            }
        }

        var plan: TurnPlan
        let judgeThinkingTrace = ThinkingTraceStore()
        do {
            Self.debugLog("planning start turn=\(request.turnId)")
            plan = try await turnPlanner.plan(
                from: prepared,
                request: request,
                stewardship: stewardship,
                judgeThinkingHandler: { delta in
                    if let displayDelta = await judgeThinkingTrace.append(
                        delta,
                        title: ThinkingTraceTitles.judge
                    ) {
                        await sink.emit(.thinkingDelta(displayDelta))
                    }
                }
            )
            Self.debugLog("planning ready turn=\(request.turnId) provider=\(plan.provider) fallback=\(plan.judgeEventDraft?.fallbackReason.rawValue ?? "none")")
        } catch is CancellationError {
            Self.debugLog("planning cancelled turn=\(request.turnId) abort=\(abortReason())")
            await sink.emit(.aborted(abortReason()))
            return nil
        } catch {
            Self.debugLog("planning failed turn=\(request.turnId) error=\(error.localizedDescription)")
            await sink.emit(
                .failed(TurnFailure(stage: .planning, message: error.localizedDescription))
            )
            return nil
        }

        var resolvedAgentLoopExecutor: AgentLoopExecutor?
        if let mode = plan.agentLoopMode {
            resolvedAgentLoopExecutor = agentLoopExecutorFactory?(mode, plan, request)
            if resolvedAgentLoopExecutor == nil, plan.indexedSkillIds.isEmpty {
                plan = plan.withSingleShotAgentFallbackTrace()
            }
        }

        onPlanReady(plan)
        await sink.emit(.prepared(outcomeFactory.makePrepared(from: plan)))
        Self.debugLog("prepared emitted turn=\(request.turnId)")

        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            Self.debugLog("cancelled after prepared turn=\(request.turnId) abort=\(abortReason())")
            await sink.emit(.aborted(abortReason()))
            return nil
        } catch {
            Self.debugLog("unknown cancellation after prepared turn=\(request.turnId) abort=\(abortReason())")
            await sink.emit(.aborted(abortReason()))
            return nil
        }

        var executionResult: TurnExecutionResult
        do {
            Self.debugLog("execute start turn=\(request.turnId)")
            if plan.agentLoopMode != nil {
                if let agentLoopExecutor = resolvedAgentLoopExecutor {
                    guard let result = try await agentLoopExecutor.execute(
                        plan: plan,
                        request: request,
                        sink: sink,
                        context: Self.makeAgentToolContext(plan: plan, request: request)
                    ) else {
                        Self.debugLog("agent execute nil turn=\(request.turnId) abort=\(abortReason())")
                        await sink.emit(.aborted(abortReason()))
                        return nil
                    }
                    executionResult = result
                } else if !plan.indexedSkillIds.isEmpty {
                    throw TurnExecutionFailure.infrastructure(
                        "Agent tool loop is unavailable for a turn that rendered lazy skills."
                    )
                } else {
                    guard let result = try await turnExecutor.execute(plan: plan, sink: sink) else {
                        Self.debugLog("execute nil turn=\(request.turnId) abort=\(abortReason())")
                        await sink.emit(.aborted(abortReason()))
                        return nil
                    }
                    executionResult = result
                }
            } else {
                guard let result = try await turnExecutor.execute(plan: plan, sink: sink) else {
                    Self.debugLog("execute nil turn=\(request.turnId) abort=\(abortReason())")
                    await sink.emit(.aborted(abortReason()))
                    return nil
                }
                executionResult = result
            }
            Self.debugLog("execute ready turn=\(request.turnId) assistantChars=\(executionResult.assistantContent.count)")
        } catch let failure as TurnExecutionFailure {
            Self.debugLog("execute failure turn=\(request.turnId) failure=\(failure)")
            await sink.emit(.failed(turnFailure(from: failure)))
            return nil
        } catch {
            Self.debugLog("execute error turn=\(request.turnId) error=\(error.localizedDescription)")
            await sink.emit(
                .failed(TurnFailure(stage: .execution, message: error.localizedDescription))
            )
            return nil
        }
        executionResult = executionResult.withPersistedThinkingPrefix(
            await judgeThinkingTrace.persistedThinking
        )

        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            Self.debugLog("cancelled before commit turn=\(request.turnId) abort=\(abortReason())")
            await sink.emit(.aborted(abortReason()))
            return nil
        } catch {
            Self.debugLog("unknown cancellation before commit turn=\(request.turnId) abort=\(abortReason())")
            await sink.emit(.aborted(abortReason()))
            return nil
        }

        let committed: CommittedAssistantTurn
        do {
            Self.debugLog("commit start turn=\(request.turnId)")
            committed = try conversationSessionStore.commitAssistantTurn(
                nodeId: prepared.node.id,
                currentMessages: prepared.messagesAfterUserAppend,
                assistantContent: executionResult.assistantContent,
                thinkingContent: executionResult.persistedThinking,
                conversationTitle: executionResult.conversationTitle,
                judgeEventId: plan.judgeEventDraft?.id,
                agentTraceJson: executionResult.agentTraceJson
            )
            Self.debugLog("commit ready turn=\(request.turnId) assistant=\(committed.assistantMessage.id)")
        } catch {
            Self.debugLog("commit failed turn=\(request.turnId) error=\(error.localizedDescription)")
            await sink.emit(
                .failed(TurnFailure(stage: .commit, message: error.localizedDescription))
            )
            return nil
        }

        let reviewArtifact = runSilentReviewIfNeeded(plan: plan, executionResult: executionResult)
        onTurnCognitionSnapshot(makeTurnCognitionSnapshot(
            request: request,
            plan: plan,
            committed: committed,
            reviewArtifact: reviewArtifact
        ))

        let completion = outcomeFactory.makeCompletion(
            turnId: request.turnId,
            nextQuickActionModeIfCompleted: plan.nextQuickActionModeIfCompleted,
            committed: committed,
            assistantContent: executionResult.assistantContent,
            stableSystem: plan.turnSlice.stable
        )
        await sink.emit(.completed(completion))
        Self.debugLog("completed emitted turn=\(request.turnId)")
        return completion
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        NSLog("[NousTurn] %@", message)
        #endif
    }

    private func turnFailure(from failure: TurnExecutionFailure) -> TurnFailure {
        switch failure {
        case .invalidPlan(let message):
            return TurnFailure(stage: .planning, message: message)
        case .infrastructure(let message):
            return TurnFailure(stage: .execution, message: message)
        }
    }

    private func runSilentReviewIfNeeded(
        plan: TurnPlan,
        executionResult: TurnExecutionResult
    ) -> CognitionArtifact? {
        guard let cognitionReviewer else { return nil }

        do {
            if let artifact = try cognitionReviewer.review(
                plan: plan,
                executionResult: executionResult
            ) {
                onReviewArtifact(artifact)
                return artifact
            }
        } catch {
            Self.debugLog("silent reviewer failed turn=\(plan.turnId) error=\(error.localizedDescription)")
        }
        return nil
    }

    private func makeTurnCognitionSnapshot(
        request: TurnRequest,
        plan: TurnPlan,
        committed: CommittedAssistantTurn,
        reviewArtifact: CognitionArtifact?
    ) -> TurnCognitionSnapshot {
        let recoveryEvent = plan.prepared.recoveryEvent
        return TurnCognitionSnapshot(
            turnId: request.turnId,
            conversationId: committed.node.id,
            assistantMessageId: committed.assistantMessage.id,
            promptLayers: plan.promptTrace.promptLayers,
            slowCognitionAttached: plan.promptTrace.promptLayers.contains("slow_cognition"),
            reviewArtifactId: reviewArtifact?.id,
            reviewRiskFlags: reviewArtifact?.riskFlags ?? [],
            reviewConfidence: reviewArtifact?.confidence,
            conversationRecoveryReason: recoveryEvent?.reason.rawValue,
            conversationRecoveryOriginalNodeId: recoveryEvent?.originalNodeId,
            conversationRecoveryRecoveredNodeId: recoveryEvent?.recoveredNodeId,
            conversationRecoveryRebasedMessageCount: recoveryEvent?.rebasedMessageCount ?? 0
        )
    }

    private static func makeAgentToolContext(plan: TurnPlan, request: TurnRequest) -> AgentToolContext {
        let baseContext = AgentToolContext(
            conversationId: plan.prepared.node.id,
            projectId: plan.prepared.node.projectId,
            currentNodeId: plan.prepared.node.id,
            currentMessage: plan.prepared.userMessage.content,
            activeQuickActionMode: plan.agentLoopMode ?? request.snapshot.activeQuickActionMode,
            indexedSkillIds: plan.indexedSkillIds,
            excludeNodeIds: [plan.prepared.node.id],
            allowedReadNodeIds: [plan.prepared.node.id],
            maxToolResultCharacters: 1200
        )
        let citationIds = plan.citations.reduce(into: Set<UUID>()) { ids, citation in
            if AgentRawNodeReadAuthorizer.canReadRawNode(
                citation.node,
                context: baseContext,
                allowAlreadyDiscoveredIds: false
            ) {
                ids.insert(citation.node.id)
            }
        }
        return AgentToolContext(
            conversationId: baseContext.conversationId,
            projectId: baseContext.projectId,
            currentNodeId: baseContext.currentNodeId,
            currentMessage: request.inputText.isEmpty ? baseContext.currentMessage : request.inputText,
            activeQuickActionMode: baseContext.activeQuickActionMode,
            indexedSkillIds: baseContext.indexedSkillIds,
            excludeNodeIds: baseContext.excludeNodeIds,
            allowedReadNodeIds: baseContext.allowedReadNodeIds.union(citationIds),
            maxToolResultCharacters: baseContext.maxToolResultCharacters
        )
    }
}

private extension TurnExecutionResult {
    func withPersistedThinkingPrefix(_ prefix: String?) -> TurnExecutionResult {
        let hasPrefix = prefix?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let combinedThinking: String?
        if hasPrefix, let persistedThinking {
            combinedThinking = [prefix, persistedThinking]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        } else if hasPrefix {
            combinedThinking = prefix
        } else {
            combinedThinking = persistedThinking
        }

        return TurnExecutionResult(
            rawAssistantContent: rawAssistantContent,
            assistantContent: assistantContent,
            persistedThinking: combinedThinking,
            conversationTitle: conversationTitle,
            didHitBudgetExhaustion: didHitBudgetExhaustion,
            agentTraceJson: agentTraceJson
        )
    }
}

private extension TurnPlan {
    func withSingleShotAgentFallbackTrace() -> TurnPlan {
        let coordination = AgentCoordinationTrace(
            executionMode: .singleShot,
            quickActionMode: promptTrace.agentCoordination?.quickActionMode ?? agentLoopMode,
            provider: provider,
            reason: .providerCannotUseToolLoop,
            indexedSkillCount: indexedSkillIds.count
        )
        let trace = PromptGovernanceTrace(
            promptLayers: promptTrace.promptLayers,
            evidenceAttached: promptTrace.evidenceAttached,
            safetyPolicyInvoked: promptTrace.safetyPolicyInvoked,
            highRiskQueryDetected: promptTrace.highRiskQueryDetected,
            turnSteward: promptTrace.turnSteward,
            agentCoordination: coordination,
            citationTrace: promptTrace.citationTrace
        )
        return TurnPlan(
            turnId: turnId,
            prepared: prepared,
            citations: citations,
            promptTrace: trace,
            effectiveMode: effectiveMode,
            nextQuickActionModeIfCompleted: nextQuickActionModeIfCompleted,
            agentLoopMode: nil,
            judgeEventDraft: judgeEventDraft,
            turnSlice: turnSlice,
            transcriptMessages: transcriptMessages,
            focusBlock: focusBlock,
            provider: provider,
            indexedSkillIds: indexedSkillIds
        )
    }
}
