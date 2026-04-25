import Foundation

struct TurnPlanningError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class TurnPlanner {
    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let embeddingService: EmbeddingService
    private let memoryProjectionService: MemoryProjectionService
    private let contradictionMemoryService: ContradictionMemoryService
    private let currentProviderProvider: () -> LLMProvider
    private let judgeLLMServiceFactory: () -> (any LLMService)?
    private let provocationJudgeFactory: (any LLMService) -> any Judging
    private let governanceTelemetry: GovernanceTelemetryStore
    private let runJudge: (@escaping () async throws -> JudgeVerdict) async throws -> JudgeVerdict

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        embeddingService: EmbeddingService,
        memoryProjectionService: MemoryProjectionService,
        contradictionMemoryService: ContradictionMemoryService,
        currentProviderProvider: @escaping () -> LLMProvider,
        judgeLLMServiceFactory: @escaping () -> (any LLMService)?,
        provocationJudgeFactory: @escaping (any LLMService) -> any Judging = { ProvocationJudge(llmService: $0) },
        governanceTelemetry: GovernanceTelemetryStore = GovernanceTelemetryStore(),
        runJudge: @escaping (@escaping () async throws -> JudgeVerdict) async throws -> JudgeVerdict = { operation in
            try await operation()
        }
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.embeddingService = embeddingService
        self.memoryProjectionService = memoryProjectionService
        self.contradictionMemoryService = contradictionMemoryService
        self.currentProviderProvider = currentProviderProvider
        self.judgeLLMServiceFactory = judgeLLMServiceFactory
        self.provocationJudgeFactory = provocationJudgeFactory
        self.governanceTelemetry = governanceTelemetry
        self.runJudge = runJudge
    }

    @MainActor
    func plan(from prepared: PreparedTurnSession, request: TurnRequest) async throws -> TurnPlan {
        let promptQuery = Self.normalizedPromptQuery(
            inputText: request.inputText,
            attachments: request.attachments
        )
        let attachmentNames = request.attachments.map(\.name)
        let retrievalQuery = ([promptQuery] + attachmentNames).joined(separator: "\n")

        let citations = try retrieveCitations(
            retrievalQuery: retrievalQuery,
            excludingId: prepared.node.id
        )
        let projectGoal = try projectGoal(for: prepared.node.projectId)
        let recentConversations = try nodeStore.fetchRecentConversationMemories(
            limit: 2,
            excludingId: prepared.node.id
        )

        let globalMemory = memoryProjectionService.currentGlobal()
        let essentialStory = memoryProjectionService.currentEssentialStory(
            projectId: prepared.node.projectId,
            excludingConversationId: prepared.node.id
        )
        let userModel = memoryProjectionService.currentUserModel(
            projectId: prepared.node.projectId,
            conversationId: prepared.node.id
        )
        let memoryEvidence = memoryProjectionService.currentBoundedEvidence(
            projectId: prepared.node.projectId,
            excludingConversationId: prepared.node.id
        )
        let projectMemory = prepared.node.projectId.flatMap {
            memoryProjectionService.currentProject(projectId: $0)
        }
        let conversationMemory = memoryProjectionService.currentConversation(nodeId: prepared.node.id)

        let nodeHits = citations.map { $0.node.id }
        let hardRecallFacts = try contradictionMemoryService.contradictionRecallFacts(
            projectId: prepared.node.projectId,
            conversationId: prepared.node.id
        )
        let contradictionCandidateIds = Set(
            contradictionMemoryService
                .annotateContradictionCandidates(
                    currentMessage: promptQuery,
                    facts: hardRecallFacts
                )
                .filter(\.isContradictionCandidate)
                .map { $0.fact.id.uuidString }
        )
        let citablePool = try contradictionMemoryService.citableEntryPool(
            projectId: prepared.node.projectId,
            conversationId: prepared.node.id,
            nodeHits: nodeHits,
            hardRecallFacts: hardRecallFacts,
            contradictionCandidateIds: contradictionCandidateIds
        )

        let provider = currentProviderProvider()
        let feedbackLoop = buildJudgeFeedbackLoop(now: request.now)
        let judgeEventId = UUID()
        var verdictForLog: JudgeVerdict?
        var fallbackReason: JudgeFallbackReason = .ok
        var profile: BehaviorProfile = .supportive
        var focusBlock: String?
        var inferredMode: ChatMode?

        if provider == .local {
            fallbackReason = .providerLocal
        } else if let judgeLLM = judgeLLMServiceFactory() {
            let judge = provocationJudgeFactory(judgeLLM)
            do {
                let verdict = try await runJudge {
                    try await judge.judge(
                        userMessage: promptQuery,
                        citablePool: citablePool,
                        previousMode: request.snapshot.activeChatMode,
                        provider: provider,
                        feedbackLoop: feedbackLoop
                    )
                }
                verdictForLog = verdict
                inferredMode = verdict.inferredMode

                if verdict.shouldProvoke, let entryId = verdict.entryId {
                    if let matched = citablePool.first(where: { $0.id == entryId }),
                       !matched.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        profile = .provocative
                        focusBlock = Self.buildFocusBlock(entryId: matched.id, rawText: matched.text)
                    } else {
                        fallbackReason = .unknownEntryId
                    }
                }
            } catch JudgeError.timeout {
                fallbackReason = .timeout
            } catch JudgeError.badJSON {
                fallbackReason = .badJSON
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fallbackReason = .apiError
            }
        } else {
            fallbackReason = .judgeUnavailable
        }

        let effectiveMode = inferredMode ?? (request.snapshot.activeChatMode ?? .companion)
        let shouldAllowInteractiveClarification = ChatViewModel.shouldAllowInteractiveClarification(
            activeQuickActionMode: request.snapshot.activeQuickActionMode,
            messages: prepared.messagesAfterUserAppend
        )
        let turnSlice = ChatViewModel.assembleContext(
            chatMode: effectiveMode,
            currentUserInput: promptQuery,
            globalMemory: globalMemory,
            essentialStory: essentialStory,
            userModel: userModel,
            memoryEvidence: memoryEvidence,
            projectMemory: projectMemory,
            conversationMemory: conversationMemory,
            recentConversations: recentConversations,
            citations: citations,
            projectGoal: projectGoal,
            attachments: request.attachments,
            activeQuickActionMode: request.snapshot.activeQuickActionMode,
            allowInteractiveClarification: shouldAllowInteractiveClarification,
            now: request.now
        )
        let promptTrace = ChatViewModel.governanceTrace(
            chatMode: effectiveMode,
            currentUserInput: promptQuery,
            globalMemory: globalMemory,
            essentialStory: essentialStory,
            userModel: userModel,
            memoryEvidence: memoryEvidence,
            projectMemory: projectMemory,
            conversationMemory: conversationMemory,
            recentConversations: recentConversations,
            citations: citations,
            projectGoal: projectGoal,
            attachments: request.attachments,
            activeQuickActionMode: request.snapshot.activeQuickActionMode,
            allowInteractiveClarification: shouldAllowInteractiveClarification,
            now: request.now
        )

        var volatilePartsForTurn: [String] = [turnSlice.volatile, profile.contextBlock]
        if let focusBlock {
            volatilePartsForTurn.append(focusBlock)
        }
        let plannedSlice = TurnSystemSlice(
            stable: turnSlice.stable,
            volatile: volatilePartsForTurn.filter { !$0.isEmpty }.joined(separator: "\n\n")
        )

        if var verdictForLog {
            verdictForLog.provocationKind = ChatViewModel.deriveProvocationKind(
                verdict: verdictForLog,
                contradictionCandidateIds: contradictionCandidateIds
            )
            return TurnPlan(
                turnId: request.turnId,
                prepared: prepared,
                citations: citations,
                promptTrace: promptTrace,
                effectiveMode: effectiveMode,
                nextQuickActionModeIfCompleted: request.snapshot.activeQuickActionMode,
                judgeEventDraft: makeJudgeEvent(
                    id: judgeEventId,
                    nodeId: prepared.node.id,
                    provider: provider,
                    chatMode: effectiveMode,
                    verdict: verdictForLog,
                    fallbackReason: fallbackReason
                ),
                turnSlice: plannedSlice,
                transcriptMessages: transcriptMessages(from: prepared.messagesAfterUserAppend),
                focusBlock: focusBlock,
                provider: provider
            )
        }

        return TurnPlan(
            turnId: request.turnId,
            prepared: prepared,
            citations: citations,
            promptTrace: promptTrace,
            effectiveMode: effectiveMode,
            nextQuickActionModeIfCompleted: request.snapshot.activeQuickActionMode,
            judgeEventDraft: makeJudgeEvent(
                id: judgeEventId,
                nodeId: prepared.node.id,
                provider: provider,
                chatMode: effectiveMode,
                verdict: nil,
                fallbackReason: fallbackReason
            ),
            turnSlice: plannedSlice,
            transcriptMessages: transcriptMessages(from: prepared.messagesAfterUserAppend),
            focusBlock: focusBlock,
            provider: provider
        )
    }

    static func userMessageContent(inputText: String, attachments: [AttachedFileContext]) -> String {
        let promptQuery = normalizedPromptQuery(inputText: inputText, attachments: attachments)
        let attachmentNames = attachments.map(\.name)
        guard !attachmentNames.isEmpty else { return promptQuery }
        return "\(promptQuery)\n\nFiles: \(attachmentNames.joined(separator: ", "))"
    }

    private func retrieveCitations(retrievalQuery: String, excludingId: UUID) throws -> [SearchResult] {
        guard embeddingService.isLoaded else { return [] }
        do {
            let queryEmbedding = try embeddingService.embed(retrievalQuery)
            return try vectorStore.searchForChatCitations(
                query: queryEmbedding,
                queryText: retrievalQuery,
                topK: 5,
                excludeIds: [excludingId]
            )
        } catch {
            throw TurnPlanningError(message: "Failed to build retrieval context: \(error.localizedDescription)")
        }
    }

    private func projectGoal(for projectId: UUID?) throws -> String? {
        guard let projectId else { return nil }
        do {
            guard let project = try nodeStore.fetchProject(id: projectId) else { return nil }
            let trimmedGoal = project.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedGoal.isEmpty ? nil : trimmedGoal
        } catch {
            throw TurnPlanningError(message: "Failed to load project context: \(error.localizedDescription)")
        }
    }

    private func makeJudgeEvent(
        id: UUID,
        nodeId: UUID,
        provider: LLMProvider,
        chatMode: ChatMode,
        verdict: JudgeVerdict?,
        fallbackReason: JudgeFallbackReason
    ) -> JudgeEvent {
        let verdictJSON: String
        if let verdict,
           let data = try? JSONEncoder().encode(verdict),
           let string = String(data: data, encoding: .utf8) {
            verdictJSON = string
        } else {
            verdictJSON = "{}"
        }

        return JudgeEvent(
            id: id,
            ts: Date(),
            nodeId: nodeId,
            messageId: nil,
            chatMode: chatMode,
            provider: provider,
            verdictJSON: verdictJSON,
            fallbackReason: fallbackReason,
            userFeedback: nil,
            feedbackTs: nil
        )
    }

    private func transcriptMessages(from messages: [Message]) -> [LLMMessage] {
        messages.map { message in
            LLMMessage(
                role: message.role == .user ? "user" : "assistant",
                content: message.content
            )
        }
    }

    private static func normalizedPromptQuery(
        inputText: String,
        attachments: [AttachedFileContext]
    ) -> String {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty, !attachments.isEmpty {
            return "Please review the attached files."
        }
        return query
    }

    private static func buildFocusBlock(entryId: String, rawText: String) -> String {
        """
        RELEVANT PRIOR MEMORY (id=\(entryId)):
        \(rawText)

        Surface this memory in your reply. Name the tension with Alex's current claim in plain language.
        Quote one specific line from the memory faithfully if there is one to quote; otherwise paraphrase tightly.
        Do not reword the memory into a summary and pretend you remembered it differently.
        """
    }

    private func buildJudgeFeedbackLoop(limit: Int = 24, now: Date) -> JudgeFeedbackLoop? {
        let events = governanceTelemetry.recentJudgeEvents(limit: limit, filter: .none)
        guard !events.isEmpty else { return nil }

        var entryPenalty: [String: Double] = [:]
        var entryReasons: [String: [String: Double]] = [:]
        var kindPenalty: [ProvocationKind: Double] = [:]
        var kindReasons: [ProvocationKind: [String: Double]] = [:]
        var globalReasons: [String: Double] = [:]
        var noteHints: [(text: String, weight: Double)] = []

        for event in events {
            guard event.fallbackReason == .ok,
                  let feedback = event.userFeedback,
                  let verdict = Self.decodeJudgeVerdict(from: event.verdictJSON),
                  verdict.shouldProvoke
            else { continue }

            let referenceDate = event.feedbackTs ?? event.ts
            let ageHours = max(0, now.timeIntervalSince(referenceDate) / 3600)
            let decay = pow(0.82, ageHours / 24)
            let weight = (feedback == .down ? 2.0 : -1.0) * decay

            kindPenalty[verdict.provocationKind, default: 0] += weight
            if let entryId = verdict.entryId {
                entryPenalty[entryId, default: 0] += weight
            }

            guard feedback == .down else { continue }

            if let reasonLabel = Self.feedbackReasonLabel(event.feedbackReason) {
                globalReasons[reasonLabel, default: 0] += decay
                var reasonsForKind = kindReasons[verdict.provocationKind, default: [:]]
                reasonsForKind[reasonLabel, default: 0] += decay
                kindReasons[verdict.provocationKind] = reasonsForKind
                if let entryId = verdict.entryId {
                    var reasonsForEntry = entryReasons[entryId, default: [:]]
                    reasonsForEntry[reasonLabel, default: 0] += decay
                    entryReasons[entryId] = reasonsForEntry
                }
            }

            if let note = Self.feedbackNoteHint(event.feedbackNote) {
                noteHints.append((text: note, weight: decay))
            }
        }

        let entrySuppressions = entryPenalty
            .filter { $0.value > 0.45 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { entryId, penalty in
                JudgeFeedbackLoop.EntrySuppression(
                    entryId: entryId,
                    penalty: penalty,
                    reasonHints: Self.topReasonLabels(entryReasons[entryId], limit: 2)
                )
            }

        let kindAdjustments = kindPenalty
            .filter { $0.value > 0.35 }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key.rawValue < rhs.key.rawValue
                }
                return lhs.value > rhs.value
            }
            .prefix(3)
            .map { kind, penalty in
                JudgeFeedbackLoop.KindAdjustment(
                    kind: kind,
                    penalty: penalty,
                    reasonHints: Self.topReasonLabels(kindReasons[kind], limit: 2)
                )
            }

        let loop = JudgeFeedbackLoop(
            entrySuppressions: Array(entrySuppressions),
            kindAdjustments: Array(kindAdjustments),
            globalReasonHints: Self.topReasonLabels(globalReasons, limit: 3),
            noteHints: Self.topNoteHints(noteHints, limit: 2)
        )
        return loop.isEmpty ? nil : loop
    }

    private static func decodeJudgeVerdict(from json: String) -> JudgeVerdict? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JudgeVerdict.self, from: data)
    }

    private static func feedbackReasonLabel(_ reason: JudgeFeedbackReason?) -> String? {
        reason?.title.lowercased()
    }

    private static func topReasonLabels(_ weightedReasons: [String: Double]?, limit: Int) -> [String] {
        (weightedReasons ?? [:])
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(limit)
            .map(\.key)
    }

    private static func topNoteHints(_ notes: [(text: String, weight: Double)], limit: Int) -> [String] {
        var seen: Set<String> = []
        return notes
            .sorted { $0.weight > $1.weight }
            .compactMap { note in
                guard seen.insert(note.text).inserted else { return nil }
                return note.text
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func feedbackNoteHint(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }

        let singleLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= 96 {
            return singleLine
        }
        let endIndex = singleLine.index(singleLine.startIndex, offsetBy: 93)
        return String(singleLine[..<endIndex]) + "..."
    }
}
