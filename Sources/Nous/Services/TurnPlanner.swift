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
    private let sourceBriefingService: SourceBriefingService?
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
        sourceBriefingService: SourceBriefingService? = nil,
        provocationJudgeFactory: @escaping (any LLMService) -> any Judging = { ProvocationJudge(llmService: $0) },
        governanceTelemetry: GovernanceTelemetryStore = GovernanceTelemetryStore(),
        skillStore: (any SkillStoring)? = nil,
        skillMatcher: any SkillMatching = SkillMatcher(),
        skillTracker: (any SkillTracking)? = nil,
        skillDogfoodLogger: (any SkillDogfoodLogging)? = nil,
        shadowPatternPromptProvider: (any ShadowPatternPromptProviding)? = nil,
        slowCognitionArtifactProvider: (any SlowCognitionArtifactProviding)? = nil,
        agentLoopProviderSupportsToolUse: @escaping (LLMProvider) -> Bool = {
            ModelHarnessProfileCatalog.profile(for: $0).supportsAgentToolUse
        },
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
        self.sourceBriefingService = sourceBriefingService
        self.provocationJudgeFactory = provocationJudgeFactory
        self.governanceTelemetry = governanceTelemetry
        self.quickActionAddendumResolver = QuickActionAddendumResolver(
            skillStore: skillStore,
            skillMatcher: skillMatcher,
            skillTracker: skillTracker,
            dogfoodLogger: skillDogfoodLogger
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
        let sourceRetrievalText = request.sourceMaterials.flatMap { material in
            [material.title, material.originalURL, material.originalFilename].compactMap { $0 } +
                material.chunks.prefix(3).map(\.text)
        }
        let retrievalQuery = ([promptQuery] + attachmentNames + sourceRetrievalText).joined(separator: "\n")

        let snapshotQuickActionMode = request.snapshot.activeQuickActionMode
        let explicitQuickActionMode = Self.effectiveExplicitQuickActionMode(
            snapshotQuickActionMode,
            stewardship: stewardship
        )
        let inferredQuickActionMode = explicitQuickActionMode == nil
            && stewardship.challengeStance != .supportFirst
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
        let isFastLatencyTurn = stewardship.latencyTier == .fast
        let stewardPolicy = QuickActionMemoryPolicy.fromStewardPreset(stewardship.memoryPolicy)
        let stewardPolicyOverridesExplicitMode = Self.shouldUseStewardPolicyOverExplicitMode(
            stewardship: stewardship,
            inputText: request.inputText
        )
        let basePolicy: QuickActionMemoryPolicy = if isFastLatencyTurn {
            .lean
        } else if let explicitQuickActionMode, !stewardPolicyOverridesExplicitMode {
            explicitQuickActionMode.agent().memoryPolicy()
        } else if stewardship.memoryPolicy != .full {
            stewardPolicy
        } else {
            stewardPolicy
        }
        let policy = basePolicy
            .applyingChallengeStance(stewardship.challengeStance)
            .applyingJudgePolicy(stewardship.judgePolicy)

        let memoryContext = try memoryContextBuilder.build(
            retrievalQuery: retrievalQuery,
            promptQuery: promptQuery,
            node: prepared.node,
            policy: policy,
            citationSourceMaterials: request.sourceMaterials,
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
        let quickActionExperiment = QuickActionExperimentAssigner.assignment(
            mode: planningQuickActionMode,
            conversationID: prepared.node.id
        )
        let quickActionExperimentAddendum = QuickActionExperimentAssigner.candidateAddendum(
            for: quickActionExperiment
        )
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
        let turnGuidanceBlock = Self.turnGuidanceBlock(for: stewardship)
        let quickActionContextBlocks = [
            resolvedQuickActionAddendum,
            quickActionExperimentAddendum,
            turnGuidanceBlock
        ]
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
        let slowCognitionArtifacts = policy.includeSlowCognition
            ? (try? slowCognitionArtifactProvider?.artifacts(
                userId: "alex",
                currentInput: promptQuery,
                currentNode: prepared.node,
                projectId: prepared.node.projectId,
                now: request.now
            )) ?? []
            : []
        let sourceBriefing = await generateSourceBriefingIfNeeded(
            promptQuery: promptQuery,
            projectGoal: projectGoal,
            projectMemory: projectMemory,
            conversationMemory: conversationMemory,
            globalMemory: globalMemory,
            citations: citations,
            sourceMaterials: request.sourceMaterials
        )
        let recentTurnContinuityBlock = Self.recentTurnContinuityBlock(
            messagesAfterUserAppend: prepared.messagesAfterUserAppend,
            currentInput: promptQuery,
            allowsMemoryContinuity: policy != .lean
        )

        let turnSlice = PromptContextAssembler.assembleContext(
            chatMode: effectiveMode,
            currentUserInput: promptQuery,
            operatingContext: memoryContext.operatingContext,
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
            sourceMaterials: request.sourceMaterials,
            sourceBriefing: sourceBriefing,
            turnSteward: stewardship.trace,
            activeQuickActionMode: planningQuickActionMode,
            loadedSkills: quickActionResolution.loadedSkills,
            matchedSkills: quickActionResolution.matchedSkills,
            quickActionAddendum: quickActionContext,
            allowSkillIndex: allowSkillIndex,
            allowInteractiveClarification: shouldAllowInteractiveClarification,
            shadowLearningHints: shadowLearningHints,
            slowCognitionArtifacts: slowCognitionArtifacts,
            corpusContext: memoryContext.corpusContext,
            derivedMemoryContext: memoryContext.derivedMemoryContext,
            now: request.now
        )
        let promptResourceIds = PromptContextAssembler.promptResourceIds(
            operatingContext: memoryContext.operatingContext,
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
            currentUserInput: promptQuery,
            slowCognitionArtifacts: slowCognitionArtifacts,
            derivedMemoryContext: memoryContext.derivedMemoryContext,
            memoryProvenance: memoryContext.memoryProvenance
        )
        let basePromptTrace = PromptContextAssembler.governanceTrace(
            chatMode: effectiveMode,
            currentUserInput: promptQuery,
            operatingContext: memoryContext.operatingContext,
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
            sourceMaterials: request.sourceMaterials,
            sourceBriefing: sourceBriefing,
            activeQuickActionMode: planningQuickActionMode,
            quickActionAddendum: quickActionContext,
            allowInteractiveClarification: shouldAllowInteractiveClarification,
            turnSteward: stewardship.trace,
            agentCoordination: agentCoordinationTrace,
            quickActionExperiment: quickActionExperiment,
            shadowLearningHints: shadowLearningHints,
            slowCognitionArtifacts: slowCognitionArtifacts,
            corpusContext: memoryContext.corpusContext,
            derivedMemoryContext: memoryContext.derivedMemoryContext,
            now: request.now
        )
        let promptTrace = recentTurnContinuityBlock == nil
            ? basePromptTrace
            : Self.promptTrace(basePromptTrace, addingLayer: "recent_turn_continuity")

        var volatilePartsForTurn: [String] = [turnSlice.volatile]
        if let recentTurnContinuityBlock {
            volatilePartsForTurn.append(recentTurnContinuityBlock)
        }
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
        let plannedTranscriptMessages = transcriptMessages(
            from: isFastLatencyTurn ? [prepared.userMessage] : prepared.messagesAfterUserAppend
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
                sourceMaterials: request.sourceMaterials,
                sourceBriefing: sourceBriefing,
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
                transcriptMessages: plannedTranscriptMessages,
                focusBlock: focusBlock,
                provider: provider,
                latencyTier: stewardship.latencyTier,
                indexedSkillIds: indexedSkillIds,
                loadedSkillIds: Set(quickActionResolution.loadedSkills.map(\.skillID)),
                memoryEvidenceSourceIds: promptResourceIds.memoryEvidenceSourceIds,
                loadedCitationIds: promptResourceIds.citationIds,
                memoryUsageHints: promptResourceIds.memoryUsageHints,
                memoryProvenance: promptResourceIds.memoryProvenance,
                corpusContext: memoryContext.corpusContext,
                resolvedCorpusEntries: memoryContext.resolvedCorpusEntries
            )
        }

        return TurnPlan(
            turnId: request.turnId,
            prepared: prepared,
            citations: citations,
            sourceMaterials: request.sourceMaterials,
            sourceBriefing: sourceBriefing,
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
            transcriptMessages: plannedTranscriptMessages,
            focusBlock: focusBlock,
            provider: provider,
            latencyTier: stewardship.latencyTier,
            indexedSkillIds: indexedSkillIds,
            loadedSkillIds: Set(quickActionResolution.loadedSkills.map(\.skillID)),
            memoryEvidenceSourceIds: promptResourceIds.memoryEvidenceSourceIds,
            loadedCitationIds: promptResourceIds.citationIds,
            memoryUsageHints: promptResourceIds.memoryUsageHints,
            memoryProvenance: promptResourceIds.memoryProvenance,
            corpusContext: memoryContext.corpusContext,
            resolvedCorpusEntries: memoryContext.resolvedCorpusEntries
        )
    }

    private func generateSourceBriefingIfNeeded(
        promptQuery: String,
        projectGoal: String?,
        projectMemory: String?,
        conversationMemory: String?,
        globalMemory: String?,
        citations: [SearchResult],
        sourceMaterials: [SourceMaterialContext]
    ) async -> SourceBriefing {
        guard !sourceMaterials.isEmpty,
              let sourceBriefingService else {
            return .empty
        }

        let request = SourceBriefingRequest(
            currentFocus: promptQuery,
            projectContext: Self.briefingProjectContext(
                projectGoal: projectGoal,
                projectMemory: projectMemory
            ),
            rememberedTheses: Self.briefingRememberedTheses(
                conversationMemory: conversationMemory,
                globalMemory: globalMemory,
                citations: citations
            ),
            sourceMaterials: sourceMaterials,
            maxItems: 4
        )
        do {
            return try await sourceBriefingService.generateBriefing(request)
        } catch {
            return .empty
        }
    }

    private static func briefingProjectContext(
        projectGoal: String?,
        projectMemory: String?
    ) -> String? {
        let pieces = [
            projectGoal.map { "Project goal: \(briefingSnippet($0, limit: 280))" },
            projectMemory.map { "Project memory: \(briefingSnippet($0, limit: 520))" }
        ].compactMap { value -> String? in
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: "\n")
    }

    private static func briefingRememberedTheses(
        conversationMemory: String?,
        globalMemory: String?,
        citations: [SearchResult]
    ) -> [String] {
        var theses: [String] = []
        if let conversationMemory,
           !conversationMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            theses.append("Conversation memory: \(briefingSnippet(conversationMemory, limit: 520))")
        }
        if let globalMemory,
           !globalMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            theses.append("Global memory: \(briefingSnippet(globalMemory, limit: 520))")
        }
        theses.append(contentsOf: citations.prefix(3).map { citation in
            let snippet = briefingSnippet(citation.surfacedSnippet, limit: 360)
            return "Citation \(citation.node.title): \(snippet)"
        })
        return theses
    }

    private static func briefingSnippet(_ text: String, limit: Int) -> String {
        let normalized = SourceTextExtractor.normalizeWhitespace(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return "\(normalized.prefix(limit))..."
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
        if let thinkingHandler,
           let configurable = service as? any ThinkingDeltaConfigurableLLMService {
            return configurable.withThinkingDeltaHandler(thinkingHandler)
        }
        return configuredJudgeThinkingBudgetOnly(service)
    }

    private static func configuredJudgeThinkingBudgetOnly(_ service: any LLMService) -> any LLMService {
        if var claude = service as? ClaudeLLMService {
            claude.thinkingBudgetTokens = claude.thinkingBudgetTokens
                ?? ModelHarnessProfileCatalog.thinkingBudgetTokens(for: .claude)
            return claude
        }
        if var openRouter = service as? OpenRouterLLMService {
            openRouter.reasoningBudgetTokens = openRouter.reasoningBudgetTokens
                ?? ModelHarnessProfileCatalog.thinkingBudgetTokens(for: .openrouter)
            return openRouter
        }
        if var gemini = service as? GeminiLLMService {
            gemini.thinkingBudgetTokens = gemini.thinkingBudgetTokens
                ?? ModelHarnessProfileCatalog.thinkingBudgetTokens(for: .gemini)
            return gemini
        }
        return service
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
        case (.sourceAnalysis, _):
            return 0
        case (.plan, .askOneQuestion):
            return 1
        case (.plan, _):
            return 2
        case (.ordinaryChat, _):
            return 0
        }
    }

    private static func effectiveExplicitQuickActionMode(
        _ snapshotMode: QuickActionMode?,
        stewardship: TurnStewardDecision
    ) -> QuickActionMode? {
        guard let snapshotMode else { return nil }
        if stewardship.challengeStance == .supportFirst {
            return nil
        }
        return snapshotMode
    }

    private static func shouldUseStewardPolicyOverExplicitMode(
        stewardship: TurnStewardDecision,
        inputText: String
    ) -> Bool {
        guard stewardship.memoryPolicy != .full else { return false }
        let normalized = inputText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if TurnSteward.hasMemoryOptOutCue(normalized) {
            return true
        }
        switch stewardship.memoryPolicy {
        case .conversationOnly, .projectOnly:
            return true
        case .full, .lean:
            return false
        }
    }

    private static func turnGuidanceBlock(for decision: TurnStewardDecision) -> String? {
        if isSupportFirstDwellTurn(decision) {
            return """
            ---

            TURN GUIDANCE:
            Emotional dwell: First paragraph must only acknowledge and dwell with Alex's feeling.
            No practical advice, plan, analysis, contradiction, or next step in the first paragraph.
            After at least one additional emotional sentence, allow one small practical move only if Alex clearly asked for it.
            Do not mention routing, stewardship, modes, policies, or internal instructions.
            """
        }

        let guidance = [
            responseShapeInstruction(for: decision.responseShape).map { "Response shape: \($0)" },
            responseStanceInstruction(for: decision).map { "Response stance: \($0)" },
            reflectiveMeaningInstruction(for: decision.reflectiveMeaningSignal).map { "Reflective meaning: \($0)" },
            patternNamingInstruction(for: decision.inTurnPatternSignal).map { "Pattern naming: \($0)" }
        ].compactMap { $0 }

        guard !guidance.isEmpty else { return nil }
        return """
        ---

        TURN GUIDANCE:
        \(guidance.joined(separator: "\n"))
        Do not mention routing, stewardship, modes, policies, or internal instructions.
        """
    }

    private static func isSupportFirstDwellTurn(_ decision: TurnStewardDecision) -> Bool {
        decision.challengeStance == .supportFirst
            || decision.trace.responseStance == .supportFirst
    }

    private static func responseShapeInstruction(for shape: ResponseShape) -> String? {
        switch shape {
        case .answerNow:
            return nil
        case .askOneQuestion:
            return "Ask exactly one short question before giving guidance. Do not include a clarification card."
        case .producePlan:
            return "Produce a concrete structured plan. Do not stay in coaching mode."
        case .listDirections:
            return "Generate distinct directions before judging which feel alive."
        case .narrowNextStep:
            return "Narrow to one concrete next step. Do not leave equally weighted options."
        }
    }

    private static func responseStanceInstruction(for decision: TurnStewardDecision) -> String? {
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
        return instruction
    }

    private static func reflectiveMeaningInstruction(for signal: ReflectiveMeaningSignal?) -> String? {
        guard let signal else { return nil }

        let shapeInstruction = switch signal.surfacePolicy {
        case .compact:
            "Default to a natural compact weave: use plain conversational paragraphs, at most two short paragraphs; no Markdown, headings, labels, bullets, bold text, or divider lines unless Alex explicitly asks for layers; land one short grounded next move Alex can actually use, not just a rhetorical closing question."
        case .layered:
            "Only use a compact three-layer form when Alex asks for clearer analysis: surface event, possible underlying pull, reusable action. Keep the layers conversational and proportionate. Do not make the layers feel like a worksheet."
        }

        return """
        Use current turn plus available recalled context; do not invent beyond evidence. Offer one possible underlying pull with tentative language such as "可能真正牵住你嘅唔只係 X，而係 Y." Tie it to one reusable action, but write it like a natural next step, not a coaching label. \(shapeInstruction) If Alex gives a concrete event plus an explicit request to understand what is pulling him, do not default to a clarifying question; offer the tentative hypothesis and action. If the event, self-reference, or felt pull is missing, ask one clarifying question instead of naming a pull. Never diagnose, say "you always", mention routing, or turn this into therapy/coaching theater. Continue Alex's original task.
        """
    }

    private static func patternNamingInstruction(for signal: InTurnPatternSignal?) -> String? {
        guard let signal else { return nil }

        let surfaceInstruction = switch signal.surfacePolicy {
        case .softName:
            "Use soft hypothesis language; do not force the label."
        case .directName:
            "Name it directly but keep it proportionate."
        }

        return """
        Name at most one live pattern. Pattern: \(signal.kind.displayLabel). Action: \(signal.kind.pairedAction). \(surfaceInstruction) Use one sentence of evidence from Alex's current words, then give the action. Continue helping with Alex's original task. Never use always-style identity claims, diagnosis language, routing language, or clinical worksheets.
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
            let images = message.role == .user
                ? Self.imageAttachments(from: message.attachments)
                : []
            let documents = message.role == .user
                ? Self.documentAttachments(from: message.attachments)
                : []
            return LLMMessage(
                role: message.role == .user ? "user" : "assistant",
                content: message.content,
                imageAttachments: images,
                documentAttachments: documents
            )
        }
    }

    private static func recentTurnContinuityBlock(
        messagesAfterUserAppend: [Message],
        currentInput: String,
        allowsMemoryContinuity: Bool
    ) -> String? {
        guard allowsMemoryContinuity else { return nil }
        let trimmedInput = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let previousAssistant = messagesAfterUserAppend.dropLast().last,
              previousAssistant.role == .assistant
        else {
            return nil
        }

        let previousContent = previousAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeMemoryBackedAssistantAnswer(previousContent) else { return nil }
        guard isImmediateFollowUp(trimmedInput, after: previousContent) else { return nil }

        return """
        RECENT TURN CONTINUITY:
        Use the previous assistant answer only as immediate conversational context for this follow-up. Do not treat it as verified memory unless the same claim is also present in loaded memory evidence.
        Previous assistant: \(snippet(previousContent, limit: 420))
        Current follow-up: \(snippet(trimmedInput, limit: 180))
        """
    }

    private static func isImmediateFollowUp(_ input: String, after previousAssistantContent: String) -> Bool {
        guard (1...160).contains(input.count) else { return false }
        let normalized = input.lowercased()
        if hasExplicitProductTopic(normalized),
           !isProductRelatedMemoryAnswer(previousAssistantContent) {
            return false
        }
        if isMealRelatedMemoryAnswer(previousAssistantContent),
           !hasMealFollowUpAnchor(normalized) {
            return false
        }

        let directFollowUpCues = [
            "what should i eat",
            "what should we eat",
            "should i eat",
            "should we eat",
            "食咩",
            "做咩",
            "點做",
            "点做",
            "點算",
            "点算",
            "點揀",
            "点拣",
            "而家應該",
            "而家应该",
            "now what",
            "what now"
        ]
        if directFollowUpCues.contains(where: { normalized.contains($0) }) {
            return true
        }

        let mealFollowUpCues = [
            "what should i have",
            "what should we have",
            "should i have",
            "should we have"
        ]
        if mealFollowUpCues.contains(where: { normalized.contains($0) }),
           hasMealOrTimeAnchor(normalized) {
            return true
        }

        let timeAnchors = ["今晚", "today", "tonight", "而家", "now"]
        if timeAnchors.contains(where: { normalized.contains($0) }),
           hasFollowUpQuestionIntent(normalized) {
            return true
        }

        let startsWithConnective = normalized.hasPrefix("咁")
            || normalized.hasPrefix("甘")
            || normalized.hasPrefix("then ")
            || normalized.hasPrefix("then,")
            || normalized.hasPrefix("then.")
            || normalized.hasPrefix("then?")
            || normalized.hasPrefix("so ")
            || normalized.hasPrefix("so,")
            || normalized.hasPrefix("so.")
            || normalized.hasPrefix("so?")
        return startsWithConnective
            && hasFollowUpQuestionIntent(normalized)
            && hasContinuityAnchor(normalized)
    }

    private static func hasMealOrTimeAnchor(_ normalizedInput: String) -> Bool {
        let cjkAnchors = [
            "今晚",
            "食"
        ]
        if cjkAnchors.contains(where: { normalizedInput.contains($0) }) {
            return true
        }

        let anchors: Set<String> = [
            "today",
            "tonight",
            "breakfast",
            "lunch",
            "dinner",
            "meal",
            "food",
            "eat"
        ]
        return !englishTokens(in: normalizedInput).isDisjoint(with: anchors)
    }

    private static func hasMealFollowUpAnchor(_ normalizedInput: String) -> Bool {
        let cjkMealTerms = [
            "食",
            "吃",
            "飯",
            "饭"
        ]
        if cjkMealTerms.contains(where: { normalizedInput.contains($0) }) {
            return true
        }

        let tokens = englishTokens(in: normalizedInput)
        let directMealTerms: Set<String> = [
            "breakfast",
            "lunch",
            "dinner",
            "meal",
            "food",
            "eat"
        ]
        if !tokens.isDisjoint(with: directMealTerms) {
            return true
        }

        let timeTerms: Set<String> = ["today", "tonight"]
        return tokens.contains("have")
            && (normalizedInput.contains("今晚") || !tokens.isDisjoint(with: timeTerms))
    }

    private static func hasContinuityAnchor(_ normalizedInput: String) -> Bool {
        let cjkAnchors = [
            "今晚",
            "食",
            "做",
            "點",
            "点",
            "算",
            "揀",
            "拣"
        ]
        if cjkAnchors.contains(where: { normalizedInput.contains($0) }) {
            return true
        }

        let continuityAnchors: Set<String> = [
            "today",
            "tonight",
            "而家",
            "now",
            "eat",
            "food",
            "dinner",
            "meal"
        ]
        return !englishTokens(in: normalizedInput).isDisjoint(with: continuityAnchors)
    }

    private static func hasFollowUpQuestionIntent(_ normalizedInput: String) -> Bool {
        let directQuestionCues = [
            "?",
            "？",
            "咩",
            "乜",
            "點",
            "点",
            "邊",
            "边",
            "算",
            "揀",
            "拣"
        ]
        if directQuestionCues.contains(where: { normalizedInput.contains($0) }) {
            return true
        }

        let englishQuestionCues: Set<String> = [
            "what",
            "how",
            "should",
            "where",
            "recommend",
            "suggest"
        ]
        return !englishTokens(in: normalizedInput).isDisjoint(with: englishQuestionCues)
    }

    private static func looksLikeMemoryBackedAssistantAnswer(_ content: String) -> Bool {
        guard content.count >= 8 else { return false }
        let normalized = content.lowercased()
        let memoryCues = [
            "你尋晚",
            "你寻晚",
            "尋晚",
            "寻晚",
            "昨晚",
            "你之前",
            "你上次",
            "你講過",
            "你讲过",
            "你說",
            "你说",
            "你提到",
            "you said",
            "you mentioned",
            "you told me",
            "you ate",
            "last night",
            "previously",
            "remember"
        ]
        return memoryCues.contains { normalized.contains($0) }
    }

    private static func isMealRelatedMemoryAnswer(_ content: String) -> Bool {
        let normalized = content.lowercased()
        let cjkMealCues = [
            "食",
            "吃",
            "飯",
            "饭",
            "壽司",
            "寿司",
            "味噌",
            "湯",
            "汤"
        ]
        if cjkMealCues.contains(where: { normalized.contains($0) }) {
            return true
        }

        let englishMealTokens: Set<String> = [
            "ate",
            "eat",
            "food",
            "meal",
            "dinner",
            "lunch",
            "breakfast",
            "sushi"
        ]
        let tokens = englishTokens(in: normalized)
        return tokens.contains { englishMealTokens.contains($0) }
    }

    private static func hasExplicitProductTopic(_ normalizedInput: String) -> Bool {
        let cjkProductCues = [
            "產品",
            "产品",
            "功能",
            "介面",
            "網頁",
            "网页"
        ]
        if cjkProductCues.contains(where: { normalizedInput.contains($0) }) {
            return true
        }

        let productTokens: Set<String> = [
            "app",
            "product",
            "prototype",
            "feature",
            "ui",
            "ux",
            "website",
            "web",
            "platform",
            "macos",
            "windows",
            "nous"
        ]
        return !englishTokens(in: normalizedInput).isDisjoint(with: productTokens)
    }

    private static func isProductRelatedMemoryAnswer(_ content: String) -> Bool {
        let normalized = content.lowercased()
        let cjkProductCues = [
            "產品",
            "产品",
            "功能",
            "介面",
            "網頁",
            "网页"
        ]
        if cjkProductCues.contains(where: { normalized.contains($0) }) {
            return true
        }

        let productTokens: Set<String> = [
            "app",
            "product",
            "prototype",
            "feature",
            "ui",
            "ux",
            "website",
            "web",
            "platform",
            "macos",
            "windows",
            "nous"
        ]
        return !englishTokens(in: normalized).isDisjoint(with: productTokens)
    }

    private static func englishTokens(in normalizedInput: String) -> Set<String> {
        var tokens: Set<String> = []
        var currentToken = ""

        for scalar in normalizedInput.lowercased().unicodeScalars {
            let value = scalar.value
            if (48...57).contains(value) || (97...122).contains(value) {
                currentToken.unicodeScalars.append(scalar)
            } else if !currentToken.isEmpty {
                tokens.insert(currentToken)
                currentToken.removeAll(keepingCapacity: true)
            }
        }

        if !currentToken.isEmpty {
            tokens.insert(currentToken)
        }

        return tokens
    }

    private static func snippet(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return "\(trimmed[..<endIndex])..."
    }

    private static func promptTrace(
        _ trace: PromptGovernanceTrace,
        addingLayer layer: String
    ) -> PromptGovernanceTrace {
        guard !trace.promptLayers.contains(layer) else { return trace }
        return PromptGovernanceTrace(
            promptLayers: trace.promptLayers + [layer],
            evidenceAttached: trace.evidenceAttached,
            safetyPolicyInvoked: trace.safetyPolicyInvoked,
            highRiskQueryDetected: trace.highRiskQueryDetected,
            turnSteward: trace.turnSteward,
            agentCoordination: trace.agentCoordination,
            citationTrace: trace.citationTrace,
            slowCognitionTrace: trace.slowCognitionTrace,
            quickActionExperiment: trace.quickActionExperiment,
            visibleResponseLanguageTarget: trace.visibleResponseLanguageTarget,
            visibleResponseLanguageSource: trace.visibleResponseLanguageSource
        )
    }

    static func imageAttachments(from attachments: [AttachedFileContext]) -> [LLMImageAttachment] {
        attachments.compactMap { attachment in
            guard attachment.kind == .image,
                  let data = attachment.imageData,
                  !data.isEmpty else { return nil }
            return LLMImageAttachment(
                data: data,
                mimeType: attachment.imageMimeType ?? "image/png"
            )
        }
    }

    static func documentAttachments(from attachments: [AttachedFileContext]) -> [LLMDocumentAttachment] {
        attachments.compactMap { attachment in
            guard attachment.kind == .pdf,
                  let data = attachment.pdfData,
                  !data.isEmpty else { return nil }
            return LLMDocumentAttachment(
                data: data,
                mimeType: "application/pdf",
                filename: attachment.name
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
