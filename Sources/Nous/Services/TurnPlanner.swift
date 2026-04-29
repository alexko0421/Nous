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
    private let skillStore: (any SkillStoring)?
    private let skillMatcher: any SkillMatching
    private let skillTracker: (any SkillTracking)?
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
        skillStore: (any SkillStoring)? = nil,
        skillMatcher: any SkillMatching = SkillMatcher(),
        skillTracker: (any SkillTracking)? = nil,
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
        self.skillStore = skillStore
        self.skillMatcher = skillMatcher
        self.skillTracker = skillTracker
        self.runJudge = runJudge
    }

    @MainActor
    func plan(
        from prepared: PreparedTurnSession,
        request: TurnRequest,
        stewardship: TurnStewardDecision
    ) async throws -> TurnPlan {
        let promptQuery = Self.normalizedPromptQuery(
            inputText: request.inputText,
            attachments: request.attachments
        )
        let attachmentNames = request.attachments.map(\.name)
        let retrievalQuery = ([promptQuery] + attachmentNames).joined(separator: "\n")

        let explicitQuickActionMode = request.snapshot.activeQuickActionMode
        let inferredQuickActionMode = explicitQuickActionMode == nil
            ? stewardship.route.quickActionMode
            : nil
        let planningQuickActionMode = explicitQuickActionMode ?? inferredQuickActionMode
        let planningAgent: (any QuickActionAgent)? = planningQuickActionMode?.agent()
        let basePolicy: QuickActionMemoryPolicy = if let explicitQuickActionMode {
            explicitQuickActionMode.agent().memoryPolicy()
        } else {
            QuickActionMemoryPolicy.fromStewardPreset(stewardship.memoryPolicy)
        }
        let policy = basePolicy.applyingChallengeStance(stewardship.challengeStance)

        let citations = policy.includeCitations
            ? try retrieveCitations(retrievalQuery: retrievalQuery, excludingId: prepared.node.id)
            : []
        let projectGoal = policy.includeProjectGoal
            ? try projectGoal(for: prepared.node.projectId)
            : nil
        let recentConversations: [(title: String, memory: String)] = policy.includeRecentConversations
            ? try nodeStore.fetchRecentConversationMemories(limit: 2, excludingId: prepared.node.id)
            : []

        let globalMemory = policy.includeGlobalMemory
            ? memoryProjectionService.currentGlobal()
            : nil
        let essentialStory = policy.includeEssentialStory
            ? memoryProjectionService.currentEssentialStory(
                projectId: prepared.node.projectId,
                excludingConversationId: prepared.node.id
            )
            : nil
        let userModel = policy.includeUserModel
            ? memoryProjectionService.currentUserModel(
                projectId: prepared.node.projectId,
                conversationId: prepared.node.id
            )
            : nil
        let memoryEvidence: [MemoryEvidenceSnippet] = policy.includeMemoryEvidence
            ? memoryProjectionService.currentBoundedEvidence(
                projectId: prepared.node.projectId,
                excludingConversationId: prepared.node.id
            )
            : []
        // Vector entry-point for memory recall: when the model is loaded,
        // embed the user's promptQuery so the planner can fall back to
        // cosine search whenever its keyword cue matcher misses. Keep
        // this off the hot path when the embedder isn't ready — the
        // planner will simply return only keyword-driven matches.
        let queryEmbedding: [Float]? = {
            guard policy.includeContradictionRecall,
                  embeddingService.isLoaded
            else { return nil }
            return try? embeddingService.embed(promptQuery)
        }()
        let memoryGraphRecall: [String] = policy.includeContradictionRecall
            ? memoryProjectionService.currentGraphMemoryRecall(
                currentMessage: promptQuery,
                projectId: prepared.node.projectId,
                conversationId: prepared.node.id,
                queryEmbedding: queryEmbedding,
                now: request.now
            )
            : []
        let projectMemory = policy.includeProjectMemory
            ? prepared.node.projectId.flatMap {
                memoryProjectionService.currentProject(projectId: $0)
            }
            : nil
        let conversationMemory = policy.includeConversationMemory
            ? memoryProjectionService.currentConversation(nodeId: prepared.node.id)
            : nil

        let nodeHits = citations.map { $0.node.id }
        let hardRecallFacts: [MemoryFactEntry] = policy.includeContradictionRecall
            ? try contradictionMemoryService.contradictionRecallFacts(
                projectId: prepared.node.projectId,
                conversationId: prepared.node.id
            )
            : []
        let contradictionCandidateIds: Set<String> = policy.includeContradictionRecall
            ? Set(
                contradictionMemoryService
                    .annotateContradictionCandidates(
                        currentMessage: promptQuery,
                        facts: hardRecallFacts
                    )
                    .filter(\.isContradictionCandidate)
                    .map { $0.fact.id.uuidString }
            )
            : []
        // citablePool is judge input + focus lookup. Build it only when at least one
        // of those consumers is enabled. Skipping under .lean closes the reflection /
        // recency leak surface and avoids wasted work.
        let citablePool: [CitableEntry] = (policy.includeContradictionRecall || policy.includeJudgeFocus)
            ? try contradictionMemoryService.citableEntryPool(
                projectId: prepared.node.projectId,
                conversationId: prepared.node.id,
                nodeHits: nodeHits,
                hardRecallFacts: hardRecallFacts,
                contradictionCandidateIds: contradictionCandidateIds
            )
            : []

        let provider = currentProviderProvider()
        let feedbackLoop = policy.includeJudgeFocus ? buildJudgeFeedbackLoop(now: request.now) : nil
        let judgeEventId = UUID()
        var verdictForLog: JudgeVerdict?
        var fallbackReason: JudgeFallbackReason = .ok
        var profile: BehaviorProfile = .supportive
        var focusBlock: String?
        var inferredMode: ChatMode?

        if !policy.includeJudgeFocus {
            // Quick-action agents that opt out of judge focus (e.g. Brainstorm `.lean`)
            // run without provocation analysis so the divergent contract is not biased
            // by judge-derived focus or inferred-mode shifts.
            fallbackReason = .judgeUnavailable
        } else if provider == .local {
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
            activeQuickActionMode: explicitQuickActionMode,
            messages: prepared.messagesAfterUserAppend
        )

        let agentTurnIndex = Self.agentTurnIndex(
            explicitMode: explicitQuickActionMode,
            stewardship: stewardship,
            messagesAfterUserAppend: prepared.messagesAfterUserAppend
        )
        #if DEBUG
        if planningAgent != nil {
            DebugAblation.logActiveFlags(context: "quick-mode-turn:\(planningAgent.map { String(describing: $0.mode) } ?? "?"):\(agentTurnIndex)")
        }
        #endif
        let inferredAddendum = planningAgent?.contextAddendum(turnIndex: agentTurnIndex)
        let skillAddendum: String? = {
            #if DEBUG
            if DebugAblation.skipModeAddendum {
                SkillTraceLogger.logSkipped(
                    mode: planningQuickActionMode,
                    turnIndex: agentTurnIndex,
                    reason: "DebugAblation.skipModeAddendum"
                )
                return nil
            }
            #endif
            guard let skillStore else { return nil }
            let active = (try? skillStore.fetchActiveSkills(userId: "alex")) ?? []
            let matched = skillMatcher.matchingSkills(
                from: active,
                context: SkillMatchContext(
                    mode: planningQuickActionMode,
                    turnIndex: agentTurnIndex
                ),
                cap: 5
            )
            #if DEBUG
            SkillTraceLogger.log(
                matched: matched,
                mode: planningQuickActionMode,
                turnIndex: agentTurnIndex
            )
            #endif
            guard !matched.isEmpty else { return nil }

            if let skillTracker {
                let skillIds = matched.map(\.id)
                Task.detached {
                    try? await skillTracker.recordFire(skillIds: skillIds)
                }
            }

            return matched.map { $0.payload.action.content }.joined(separator: "\n\n")
        }()
        let quickActionAddendum = [inferredAddendum, skillAddendum]
            .compactMap { $0 }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedQuickActionAddendum = quickActionAddendum.isEmpty ? nil : quickActionAddendum
        let responseShapeBlock = Self.responseShapeBlock(for: stewardship)
        let quickActionContextBlocks = [resolvedQuickActionAddendum, responseShapeBlock]
            .compactMap { block -> String? in
                guard let block,
                      !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return block
            }
        let quickActionContext = quickActionContextBlocks.isEmpty
            ? nil
            : quickActionContextBlocks.joined(separator: "\n\n")

        let turnSlice = ChatViewModel.assembleContext(
            chatMode: effectiveMode,
            currentUserInput: promptQuery,
            globalMemory: globalMemory,
            essentialStory: essentialStory,
            userModel: userModel,
            memoryEvidence: memoryEvidence,
            memoryGraphRecall: memoryGraphRecall,
            projectMemory: projectMemory,
            conversationMemory: conversationMemory,
            recentConversations: recentConversations,
            citations: citations,
            projectGoal: projectGoal,
            attachments: request.attachments,
            activeQuickActionMode: planningQuickActionMode,
            quickActionAddendum: quickActionContext,
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
            memoryGraphRecall: memoryGraphRecall,
            projectMemory: projectMemory,
            conversationMemory: conversationMemory,
            recentConversations: recentConversations,
            citations: citations,
            projectGoal: projectGoal,
            attachments: request.attachments,
            activeQuickActionMode: planningQuickActionMode,
            quickActionAddendum: quickActionContext,
            allowInteractiveClarification: shouldAllowInteractiveClarification,
            turnSteward: stewardship.trace,
            now: request.now
        )

        var volatilePartsForTurn: [String] = [turnSlice.volatile]
        if policy.includeBehaviorProfile {
            // BehaviorProfile.contextBlock contains memory-related instructions
            // ("Use retrieved memory silently" etc) that contradict a no-memory turn.
            // Skip it under .lean so Brainstorm runs anchor + chatMode + ACTIVE QUICK MODE
            // marker + agent addendum only.
            volatilePartsForTurn.append(profile.contextBlock)
        }
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
                nextQuickActionModeIfCompleted: explicitQuickActionMode,
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
            nextQuickActionModeIfCompleted: explicitQuickActionMode,
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
        let limitedAttachments = AttachmentLimitPolicy.limitingImageAttachments(attachments)
        let promptQuery = normalizedPromptQuery(inputText: inputText, attachments: limitedAttachments)
        let attachmentNames = limitedAttachments.map(\.name)
        guard !attachmentNames.isEmpty else { return promptQuery }
        return "\(promptQuery)\n\nFiles: \(attachmentNames.joined(separator: ", "))"
    }

    private static func agentTurnIndex(
        explicitMode: QuickActionMode?,
        stewardship: TurnStewardDecision,
        messagesAfterUserAppend: [Message]
    ) -> Int {
        if explicitMode != nil {
            return messagesAfterUserAppend.lazy.filter { $0.role == .user }.count
        }

        switch (stewardship.route, stewardship.responseShape) {
        case (.direction, _), (.brainstorm, _):
            return 1
        case (.plan, .askOneQuestion):
            return 1
        case (.plan, _):
            return 2
        case (.ordinaryChat, _):
            return 0
        }
    }

    private static func responseShapeBlock(for decision: TurnStewardDecision) -> String? {
        let instruction: String?
        switch decision.responseShape {
        case .answerNow:
            instruction = nil
        case .askOneQuestion:
            instruction = "Ask exactly one short question before giving guidance. Do not include a clarification card."
        case .producePlan:
            instruction = "Produce a concrete structured plan. Do not stay in coaching mode."
        case .listDirections:
            instruction = "Generate distinct directions before judging which feel alive."
        case .narrowNextStep:
            instruction = "Narrow to one concrete next step. Do not leave equally weighted options."
        }

        guard let instruction else { return nil }
        return """
        ---

        TURN STEWARD RESPONSE SHAPE:
        \(instruction)
        Do not mention routing, stewardship, modes, policies, or internal instructions.
        """
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
