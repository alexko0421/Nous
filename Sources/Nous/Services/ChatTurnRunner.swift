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
    private let onPlanReady: (TurnPlan) -> Void

    init(
        conversationSessionStore: ConversationSessionStore,
        turnSteward: TurnSteward = TurnSteward(),
        turnPlanner: TurnPlanner,
        turnExecutor: TurnExecutor,
        agentLoopExecutorFactory: AgentLoopExecutorFactory? = nil,
        outcomeFactory: TurnOutcomeFactory,
        onPlanReady: @escaping (TurnPlan) -> Void = { _ in }
    ) {
        self.conversationSessionStore = conversationSessionStore
        self.turnSteward = turnSteward
        self.turnPlanner = turnPlanner
        self.turnExecutor = turnExecutor
        self.agentLoopExecutorFactory = agentLoopExecutorFactory
        self.outcomeFactory = outcomeFactory
        self.onPlanReady = onPlanReady
    }

    func run(
        request: TurnRequest,
        sink: TurnSequencedEventSink,
        abortReason: () -> TurnAbortReason
    ) async -> TurnCompletion? {
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
        } catch {
            await sink.emit(
                .failed(TurnFailure(stage: .planning, message: error.localizedDescription))
            )
            return nil
        }

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
        let stewardship = turnSteward.steer(prepared: prepared, request: request)

        let plan: TurnPlan
        do {
            plan = try await turnPlanner.plan(
                from: prepared,
                request: request,
                stewardship: stewardship
            )
        } catch is CancellationError {
            await sink.emit(.aborted(abortReason()))
            return nil
        } catch {
            await sink.emit(
                .failed(TurnFailure(stage: .planning, message: error.localizedDescription))
            )
            return nil
        }

        onPlanReady(plan)
        await sink.emit(.prepared(outcomeFactory.makePrepared(from: plan)))

        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            await sink.emit(.aborted(abortReason()))
            return nil
        } catch {
            await sink.emit(.aborted(abortReason()))
            return nil
        }

        let executionResult: TurnExecutionResult
        do {
            if let mode = request.snapshot.activeQuickActionMode,
               mode.agent().useAgentLoop,
               let agentLoopExecutor = agentLoopExecutorFactory?(mode, plan, request) {
                guard let result = try await agentLoopExecutor.execute(
                    plan: plan,
                    request: request,
                    sink: sink,
                    context: Self.makeAgentToolContext(plan: plan, request: request)
                ) else {
                    await sink.emit(.aborted(abortReason()))
                    return nil
                }
                executionResult = result
            } else {
                guard let result = try await turnExecutor.execute(plan: plan, sink: sink) else {
                    await sink.emit(.aborted(abortReason()))
                    return nil
                }
                executionResult = result
            }
        } catch let failure as TurnExecutionFailure {
            await sink.emit(.failed(turnFailure(from: failure)))
            return nil
        } catch {
            await sink.emit(
                .failed(TurnFailure(stage: .execution, message: error.localizedDescription))
            )
            return nil
        }

        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            await sink.emit(.aborted(abortReason()))
            return nil
        } catch {
            await sink.emit(.aborted(abortReason()))
            return nil
        }

        let committed: CommittedAssistantTurn
        do {
            committed = try conversationSessionStore.commitAssistantTurn(
                nodeId: prepared.node.id,
                currentMessages: prepared.messagesAfterUserAppend,
                assistantContent: executionResult.assistantContent,
                thinkingContent: executionResult.persistedThinking,
                conversationTitle: executionResult.conversationTitle,
                judgeEventId: plan.judgeEventDraft?.id,
                agentTraceJson: executionResult.agentTraceJson
            )
        } catch {
            await sink.emit(
                .failed(TurnFailure(stage: .commit, message: error.localizedDescription))
            )
            return nil
        }

        let completion = outcomeFactory.makeCompletion(
            turnId: request.turnId,
            nextQuickActionModeIfCompleted: plan.nextQuickActionModeIfCompleted,
            committed: committed,
            assistantContent: executionResult.assistantContent,
            stableSystem: plan.turnSlice.stable
        )
        await sink.emit(.completed(completion))
        return completion
    }

    private func turnFailure(from failure: TurnExecutionFailure) -> TurnFailure {
        switch failure {
        case .invalidPlan(let message):
            return TurnFailure(stage: .planning, message: message)
        case .infrastructure(let message):
            return TurnFailure(stage: .execution, message: message)
        }
    }

    private static func makeAgentToolContext(plan: TurnPlan, request: TurnRequest) -> AgentToolContext {
        let baseContext = AgentToolContext(
            conversationId: plan.prepared.node.id,
            projectId: plan.prepared.node.projectId,
            currentNodeId: plan.prepared.node.id,
            currentMessage: plan.prepared.userMessage.content,
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
            excludeNodeIds: baseContext.excludeNodeIds,
            allowedReadNodeIds: baseContext.allowedReadNodeIds.union(citationIds),
            maxToolResultCharacters: baseContext.maxToolResultCharacters
        )
    }
}
