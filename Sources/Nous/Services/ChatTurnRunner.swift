import Foundation

final class ChatTurnRunner {
    private let conversationSessionStore: ConversationSessionStore
    private let turnPlanner: TurnPlanner
    private let turnExecutor: TurnExecutor
    private let outcomeFactory: TurnOutcomeFactory
    private let onPlanReady: (TurnPlan) -> Void

    init(
        conversationSessionStore: ConversationSessionStore,
        turnPlanner: TurnPlanner,
        turnExecutor: TurnExecutor,
        outcomeFactory: TurnOutcomeFactory,
        onPlanReady: @escaping (TurnPlan) -> Void = { _ in }
    ) {
        self.conversationSessionStore = conversationSessionStore
        self.turnPlanner = turnPlanner
        self.turnExecutor = turnExecutor
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

        let plan: TurnPlan
        do {
            plan = try await turnPlanner.plan(from: prepared, request: request)
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
            guard let result = try await turnExecutor.execute(plan: plan, sink: sink) else {
                await sink.emit(.aborted(abortReason()))
                return nil
            }
            executionResult = result
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
                judgeEventId: plan.judgeEventDraft?.id
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
}
