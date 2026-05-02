import Foundation

struct TurnPlanningError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class TurnPlanner {
    private let memoryContextBuilder: TurnMemoryContextBuilder
    private let currentProviderProvider: () -> LLMProvider
    private let judgeLLMServiceFactory: () -> (any LLMService)?
    private let provocationJudgeFactory: (any LLMService) -> any Judging
    private let governanceTelemetry: GovernanceTelemetryStore
    private let quickActionAddendumResolver: QuickActionAddendumResolver
    private let shadowPatternPromptProvider: (any ShadowPatternPromptProviding)?
    private let slowCognitionArtifactProvider: (any SlowCognitionArtifactProviding)?
    private let agentLoopProviderSupportsToolUse: (LLMProvider) -> Bool
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
        shadowPatternPromptProvider: (any ShadowPatternPromptProviding)? = nil,
        slowCognitionArtifactProvider: (any SlowCognitionArtifactProviding)? = nil,
        agentLoopProviderSupportsToolUse: @escaping (LLMProvider) -> Bool = { $0 == .openrouter },
        runJudge: @escaping (@escaping () async throws -> JudgeVerdict) async throws -> JudgeVerdict = { operation in
            try await operation()
        }
    ) {
        self.memoryContextBuilder = TurnMemoryContextBuilder(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            memoryProjectionService: memoryProjectionService,
            contradictionMemoryService: contradictionMemoryService
        )
        self.currentProviderProvider = currentProviderProvider
        self.judgeLLMServiceFactory = judgeLLMServiceFactory
        self.provocationJudgeFactory = provocationJudgeFactory
        self.governanceTelemetry = governanceTelemetry
        self.quickActionAddendumResolver = QuickActionAddendumResolver(
            skillStore: skillStore,
            skillMatcher: skillMatcher,
            skillTracker: skillTracker
        )
        self.shadowPatternPromptProvider = shadowPatternPromptProvider
        self.slowCognitionArtifactProvider = slowCognitionArtifactProvider
        self.agentLoopProviderSupportsToolUse = agentLoopProviderSupportsToolUse
        self.runJudge = runJudge
    }

    @MainActor
    func plan(
        from prepared: PreparedTurnSession,
        request: TurnRequest,
        stewardship: TurnStewardDecision,
        judgeThinkingHandler: ThinkingDeltaHandler? = nil
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
        let shadowLearningHints = (try? shadowPatternPromptProvider?.promptHints(
            userId: "alex",
            currentInput: promptQuery,
            activeQuickActionMode: planningQuickActionMode,
            now: request.now
        )) ?? []
        let planningAgent: (any QuickActionAgent)? = planningQuickActionMode?.agent()
        let basePolicy: QuickActionMemoryPolicy = if let explicitQuickActionMode {
            explicitQuickActionMode.agent().memoryPolicy()
        } else {
            QuickActionMemoryPolicy.fromStewardPreset(stewardship.memoryPolicy)
        }
        let policy = basePolicy
            .applyingChallengeStance(stewardship.challengeStance)
            .applyingJudgePolicy(stewardship.judgePolicy)

        let memoryContext = try memoryContextBuilder.build(
            retrievalQuery: retrievalQuery,
            promptQuery: promptQuery,
            node: prepared.node,
            policy: policy,
            includeGraphPromptRecall: planningQuickActionMode != nil,
            now: request.now
        )
        let citations = memoryContext.citations
        let projectGoal = memoryContext.projectGoal
        let recentConversations = memoryContext.recentConversations
        let globalMemory = memoryContext.globalMemory
        let essentialStory = memoryContext.essentialStory
        let userModel = memoryContext.userModel
        let memoryEvidence = memoryContext.memoryEvidence
        let memoryGraphRecall = memoryContext.memoryGraphRecall
        let projectMemory = memoryContext.projectMemory
        let conversationMemory = memoryContext.conversationMemory
        let contradictionCandidateIds = memoryContext.contradictionCandidateIds
        let citablePool = memoryContext.citablePool

        let provider = currentProviderProvider()
        let isSilentJudgeFraming = stewardship.judgePolicy == .silentFraming
        let feedbackLoop = policy.includeJudgeFocus ? buildJudgeFeedbackLoop(now: request.now) : nil
        let judgeEventId = UUID()
        var verdictForLog: JudgeVerdict?
        var fallbackReason: JudgeFallbackReason = .ok
        var profile: BehaviorProfile = .supportive
        var focusBlock: String?
        var focusMemoryText: String?
        var inferredMode: ChatMode?

        if !policy.includeJudgeFocus {
            // Quick-action agents that opt out of judge focus (e.g. Brainstorm `.lean`)
            // run without provocation analysis so the divergent contract is not biased
            // by judge-derived focus or inferred-mode shifts.
            fallbackReason = .judgeUnavailable
        } else if provider == .local {
            fallbackReason = .providerLocal
        } else if let judgeLLM = judgeLLMServiceFactory() {
            let judgeLLM = Self.configuredJudgeLLMService(
                judgeLLM,
                thinkingHandler: isSilentJudgeFraming ? nil : judgeThinkingHandler
            )
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
                        if !isSilentJudgeFraming {
                            profile = .provocative
                        }
                        focusMemoryText = matched.text
                        focusBlock = isSilentJudgeFraming
                            ? Self.buildSilentFramingBlock(entryId: matched.id, rawText: matched.text)
                            : Self.buildFocusBlock(entryId: matched.id, rawText: matched.text)
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
        let shouldAllowInteractiveClarification = TurnInteractionPolicy.shouldAllowInteractiveClarification(
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
        let quickActionResolution = quickActionAddendumResolver.resolution(
            mode: planningQuickActionMode,
            agent: planningAgent,
            turnIndex: agentTurnIndex,
            conversationID: prepared.node.id
        )
        let resolvedQuickActionAddendum = quickActionResolution.addendum
        let quickActionModeSupportsAgentLoop = planningQuickActionMode?.agent().useAgentLoop == true
        let canUseAgentLoop = quickActionModeSupportsAgentLoop
            && agentLoopProviderSupportsToolUse(provider)
        let allowSkillIndex = canUseAgentLoop
        let indexedSkillIds = PromptContextAssembler.indexedSkillIds(
            matchedSkills: quickActionResolution.matchedSkills,
            loadedSkills: quickActionResolution.loadedSkills,
            activeQuickActionMode: planningQuickActionMode,
            allowSkillIndex: allowSkillIndex
        )
        let agentLoopMode = Self.agentLoopMode(
            explicitMode: explicitQuickActionMode,
            planningMode: planningQuickActionMode,
            indexedSkillIds: indexedSkillIds,
            canUseAgentLoop: canUseAgentLoop
        )
        let agentCoordinationTrace = Self.agentCoordinationTrace(
            explicitMode: explicitQuickActionMode,
            planningMode: planningQuickActionMode,
            quickActionModeSupportsAgentLoop: quickActionModeSupportsAgentLoop,
            canUseAgentLoop: canUseAgentLoop,
            agentLoopMode: agentLoopMode,
            indexedSkillCount: indexedSkillIds.count,
            provider: provider
        )
        let responseShapeBlock = Self.responseShapeBlock(for: stewardship)
        let responseStanceBlock = Self.responseStanceBlock(for: stewardship)
        let quickActionContextBlocks = [resolvedQuickActionAddendum, responseShapeBlock, responseStanceBlock]
            .compactMap { block -> String? in
                guard let block,
                      !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return block
            }
        let quickActionContext = quickActionContextBlocks.isEmpty
            ? nil
            : quickActionContextBlocks.joined(separator: "\n\n")
        let promptMemoryGraphRecall = Self.memoryGraphRecall(
            memoryGraphRecall,
            removingDuplicateFocusText: focusMemoryText
        )
        let slowCognitionArtifacts = (try? slowCognitionArtifactProvider?.artifacts(
            userId: "alex",
            currentInput: promptQuery,
            currentNode: prepared.node,
            projectId: prepared.node.projectId,
            now: request.now
        )) ?? []

        let turnSlice = PromptContextAssembler.assembleContext(
            chatMode: effectiveMode,
            currentUserInput: promptQuery,
            globalMemory: globalMemory,
            essentialStory: essentialStory,
            userModel: userModel,
            memoryEvidence: memoryEvidence,
            memoryGraphRecall: promptMemoryGraphRecall,
            projectMemory: projectMemory,
            conversationMemory: conversationMemory,
            recentConversations: recentConversations,
            citations: citations,
            projectGoal: projectGoal,
            attachments: request.attachments,
            activeQuickActionMode: planningQuickActionMode,
            loadedSkills: quickActionResolution.loadedSkills,
            matchedSkills: quickActionResolution.matchedSkills,
            quickActionAddendum: quickActionContext,
            allowSkillIndex: allowSkillIndex,
            allowInteractiveClarification: shouldAllowInteractiveClarification,
            shadowLearningHints: shadowLearningHints,
            slowCognitionArtifacts: slowCognitionArtifacts,
            now: request.now
        )
        let promptTrace = PromptContextAssembler.governanceTrace(
            chatMode: effectiveMode,
            currentUserInput: promptQuery,
            globalMemory: globalMemory,
            essentialStory: essentialStory,
            userModel: userModel,
            memoryEvidence: memoryEvidence,
            memoryGraphRecall: promptMemoryGraphRecall,
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
            agentCoordination: agentCoordinationTrace,
            shadowLearningHints: shadowLearningHints,
            slowCognitionArtifacts: slowCognitionArtifacts,
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
            verdictForLog.provocationKind = TurnInteractionPolicy.deriveProvocationKind(
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
                agentLoopMode: agentLoopMode,
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
                provider: provider,
                indexedSkillIds: indexedSkillIds
            )
        }

        return TurnPlan(
            turnId: request.turnId,
            prepared: prepared,
            citations: citations,
            promptTrace: promptTrace,
            effectiveMode: effectiveMode,
            nextQuickActionModeIfCompleted: explicitQuickActionMode,
            agentLoopMode: agentLoopMode,
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
            provider: provider,
            indexedSkillIds: indexedSkillIds
        )
    }

    private static func agentLoopMode(
        explicitMode: QuickActionMode?,
        planningMode: QuickActionMode?,
        indexedSkillIds: Set<UUID>,
        canUseAgentLoop: Bool
    ) -> QuickActionMode? {
        guard canUseAgentLoop else { return nil }
        guard let mode = explicitMode ?? (!indexedSkillIds.isEmpty ? planningMode : nil),
              mode.agent().useAgentLoop else { return nil }
        return mode
    }

    private static func agentCoordinationTrace(
        explicitMode: QuickActionMode?,
        planningMode: QuickActionMode?,
        quickActionModeSupportsAgentLoop: Bool,
        canUseAgentLoop: Bool,
        agentLoopMode: QuickActionMode?,
        indexedSkillCount: Int,
        provider: LLMProvider
    ) -> AgentCoordinationTrace {
        if let agentLoopMode {
            let reason: AgentCoordinationReason = explicitMode != nil
                ? .explicitQuickActionToolLoop
                : .inferredQuickActionLazySkill
            return AgentCoordinationTrace(
                executionMode: .toolLoop,
                quickActionMode: agentLoopMode,
                provider: provider,
                reason: reason,
                indexedSkillCount: indexedSkillCount
            )
        }

        let reason: AgentCoordinationReason
        if planningMode == nil {
            reason = .ordinaryChatSingleShot
        } else if !quickActionModeSupportsAgentLoop {
            reason = .modeSingleShotByContract
        } else if !canUseAgentLoop {
            reason = .providerCannotUseToolLoop
        } else {
            reason = .inferredModeNoToolNeed
        }

        return AgentCoordinationTrace(
            executionMode: .singleShot,
            quickActionMode: planningMode,
            provider: provider,
            reason: reason,
            indexedSkillCount: indexedSkillCount
        )
    }

    static func userMessageContent(inputText: String, attachments: [AttachedFileContext]) -> String {
        let limitedAttachments = AttachmentLimitPolicy.limitingImageAttachments(attachments)
        let promptQuery = normalizedPromptQuery(inputText: inputText, attachments: limitedAttachments)
        let attachmentNames = limitedAttachments.map(\.name)
        guard !attachmentNames.isEmpty else { return promptQuery }
        return "\(promptQuery)\n\nFiles: \(attachmentNames.joined(separator: ", "))"
    }

    private static func configuredJudgeLLMService(
        _ service: any LLMService,
        thinkingHandler: ThinkingDeltaHandler?
    ) -> any LLMService {
        guard let thinkingHandler,
              let configurable = service as? any ThinkingDeltaConfigurableLLMService else {
            return service
        }
        return configurable.withThinkingDeltaHandler(thinkingHandler)
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

    private static func responseStanceBlock(for decision: TurnStewardDecision) -> String? {
        guard decision.route == .ordinaryChat,
              decision.trace.routerMode == .active,
              let stance = decision.trace.responseStance else {
            return nil
        }

        let instruction: String?
        switch stance {
        case .companion:
            instruction = nil
        case .reflective:
            instruction = "Stay reflective and meaning-oriented. Do not turn this into a structured analysis unless Alex asks for one."
        case .supportFirst:
            instruction = "Support first. Acknowledge the pressure plainly, then if there is a decision inside the message, offer only one small next step. Keep judge off."
        case .softAnalysis:
            instruction = "Give calm tradeoff analysis. Use any judge-derived framing silently. Do not mention judge thinking, contradiction checks, or turn the reply into a hard challenge."
        case .hardJudge:
            instruction = "Alex explicitly invited challenge. You may name a real tension plainly, but stay useful and proportionate."
        }

        guard let instruction else { return nil }
        return """
        ---

        RESPONSE STANCE:
        \(instruction)
        Do not mention routing, stewardship, modes, policies, or internal instructions.
        """
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

    private static func buildSilentFramingBlock(entryId: String, rawText: String) -> String {
        """
        PRIVATE FRAMING NOTE (id=\(entryId)):
        \(rawText)

        Use this only to make the answer more grounded and proportionate.
        Do not quote this memory, name a tension, mention judge analysis, or turn the reply into a hard challenge.
        """
    }

    private static func memoryGraphRecall(
        _ recalls: [String],
        removingDuplicateFocusText focusText: String?
    ) -> [String] {
        guard let focusText else { return recalls }
        let focusClaims = normalizedMemoryClaims(in: focusText)
        guard !focusClaims.isEmpty else { return recalls }

        return recalls.filter { recall in
            let normalizedRecall = normalizedMemoryText(recall)
            return !focusClaims.contains { normalizedRecall.contains($0) }
        }
    }

    private static func normalizedMemoryClaims(in text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.replacingOccurrences(
                    of: #"^\s*[-*]?\s*(statement:|content:)?\s*"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .map(normalizedMemoryText)
            .filter { $0.count >= 12 }
    }

    private static func normalizedMemoryText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
