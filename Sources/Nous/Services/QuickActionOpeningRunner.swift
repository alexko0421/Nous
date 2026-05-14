import Foundation

final class QuickActionOpeningRunner {
    private let conversationSessionStore: ConversationSessionStore
    private let outcomeFactory: TurnOutcomeFactory

    init(
        conversationSessionStore: ConversationSessionStore,
        memoryContextBuilder: TurnMemoryContextBuilder,
        turnExecutor: TurnExecutor,
        outcomeFactory: TurnOutcomeFactory,
        currentProviderProvider: @escaping () -> LLMProvider = { .local },
        skillStore: (any SkillStoring)? = nil,
        skillMatcher: any SkillMatching = SkillMatcher(),
        skillTracker: (any SkillTracking)? = nil,
        skillDogfoodLogger: (any SkillDogfoodLogging)? = nil,
        cognitionReviewer: (any CognitionReviewing)? = nil,
        shouldSurfaceThinkingTraces: @escaping () -> Bool = { true },
        onPlanReady: @escaping (TurnPlan) -> Void = { _ in },
        onReviewArtifact: @escaping (CognitionArtifact) -> Void = { _ in },
        onTurnCognitionSnapshot: @escaping (TurnCognitionSnapshot) -> Void = { _ in },
        onContextManifest: @escaping (ContextManifestRecord) -> Void = { _ in }
    ) {
        self.conversationSessionStore = conversationSessionStore
        self.outcomeFactory = outcomeFactory
    }

    func run(
        mode: QuickActionMode,
        node: NousNode,
        turnId: UUID,
        sink: TurnSequencedEventSink,
        abortReason: () -> TurnAbortReason
    ) async -> TurnCompletion? {
        do {
            try Task.checkCancellation()
        } catch {
            await sink.emit(.aborted(abortReason()))
            return nil
        }

        let visibleOpening = mode.openingMessage
        let policyOpening = "<phase>understanding</phase>\n\(visibleOpening)"

        let committed: CommittedAssistantTurn
        do {
            committed = try conversationSessionStore.commitAssistantTurn(
                nodeId: node.id,
                currentMessages: [],
                assistantContent: visibleOpening,
                thinkingContent: nil,
                conversationTitle: mode.label
            )
        } catch {
            await sink.emit(.failed(TurnFailure(stage: .commit, message: error.localizedDescription)))
            return nil
        }

        let completion = outcomeFactory.makeCompletion(
            turnId: turnId,
            nextQuickActionModeIfCompleted: mode,
            committed: committed,
            assistantContent: policyOpening,
            stableSystem: "",
            latencyTier: .fast
        )
        await sink.emit(.completed(completion))
        return completion
    }
}
