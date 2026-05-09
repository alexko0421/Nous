import Foundation

final class TurnExecutor {
    private let llmServiceProvider: () -> (any LLMService)?
    private let geminiPromptCache: GeminiPromptCacheService
    private let shouldUseGeminiHistoryCache: () -> Bool
    private let shouldPersistAssistantThinking: () -> Bool
    private let recordGeminiUsage: @Sendable (GeminiUsageMetadata) -> Void

    init(
        llmServiceProvider: @escaping () -> (any LLMService)?,
        geminiPromptCache: GeminiPromptCacheService = GeminiPromptCacheService(),
        shouldUseGeminiHistoryCache: @escaping () -> Bool = { true },
        shouldPersistAssistantThinking: @escaping () -> Bool = { true },
        recordGeminiUsage: @escaping @Sendable (GeminiUsageMetadata) -> Void = { _ in }
    ) {
        self.llmServiceProvider = llmServiceProvider
        self.geminiPromptCache = geminiPromptCache
        self.shouldUseGeminiHistoryCache = shouldUseGeminiHistoryCache
        self.shouldPersistAssistantThinking = shouldPersistAssistantThinking
        self.recordGeminiUsage = recordGeminiUsage
    }

    func execute(
        plan: TurnPlan,
        sink: TurnSequencedEventSink,
        captureThinking: Bool = true
    ) async throws -> TurnExecutionResult? {
        guard let latestMessage = plan.transcriptMessages.last, latestMessage.role == "user" else {
            throw TurnExecutionFailure.invalidPlan(
                "Turn plan must end with the current user message before execution."
            )
        }

        guard let llm = llmServiceProvider() else {
            return normalizedResult(
                from: "Please configure an LLM in Settings.",
                persistedThinking: nil,
                didHitBudgetExhaustion: false
            )
        }

        let resolvedCacheEntry = activeGeminiHistoryCache(
            nodeId: plan.prepared.node.id,
            llm: llm,
            stableSystem: plan.turnSlice.stable,
            transcriptMessages: plan.transcriptMessages
        )
        let requestMessages = requestMessages(
            forSlice: plan.turnSlice,
            transcriptMessages: plan.transcriptMessages,
            cacheEntry: resolvedCacheEntry
        )
        let requestSystem = requestSystem(
            forSlice: plan.turnSlice,
            cacheEntry: resolvedCacheEntry
        )

        let state = TurnExecutionStreamState()
        var streamedText = ""
        do {
            let stream = try await configuredStreamingService(
                from: configuredGeminiService(from: llm, cacheEntry: resolvedCacheEntry),
                sink: sink,
                state: state,
                captureThinking: captureThinking,
                cacheableSystemPrefix: resolvedCacheEntry == nil ? plan.turnSlice.stable : nil
            ).generate(
                messages: requestMessages,
                system: requestSystem
            )
            try Task.checkCancellation()

            for try await chunk in stream {
                try Task.checkCancellation()
                streamedText += chunk
                await sink.emit(.textDelta(chunk))
            }
        } catch is CancellationError {
            return nil
        } catch {
            if resolvedCacheEntry != nil {
                geminiPromptCache.removeEntry(for: plan.prepared.node.id)
            }
            return normalizedResult(
                from: "Error: \(error.localizedDescription)",
                persistedThinking: nil,
                didHitBudgetExhaustion: false
            )
        }

        let didHitBudgetExhaustion = await state.didHitBudgetExhaustion
        if didHitBudgetExhaustion && streamedText.isEmpty {
            streamedText = "(I ran out of thinking budget on that one. Try asking again, maybe a touch simpler.)"
        }
        let persistedThinking: String?
        if captureThinking && shouldPersistAssistantThinking() {
            persistedThinking = await state.persistedThinking
        } else {
            persistedThinking = nil
        }

        return normalizedResult(
            from: streamedText,
            persistedThinking: persistedThinking,
            didHitBudgetExhaustion: didHitBudgetExhaustion
        )
    }

    private func normalizedResult(
        from rawAssistantContent: String,
        persistedThinking: String?,
        didHitBudgetExhaustion: Bool
    ) -> TurnExecutionResult {
        let normalized = AssistantTurnNormalizer.normalize(rawAssistantContent)

        return TurnExecutionResult(
            rawAssistantContent: normalized.rawAssistantContent,
            assistantContent: normalized.assistantContent,
            persistedThinking: persistedThinking,
            conversationTitle: normalized.conversationTitle,
            didHitBudgetExhaustion: didHitBudgetExhaustion
        )
    }

    private func configuredGeminiService(
        from llm: any LLMService,
        cacheEntry: GeminiConversationCacheEntry?
    ) -> any LLMService {
        guard var gemini = llm as? GeminiLLMService, let entry = cacheEntry else { return llm }
        gemini.cachedContentName = entry.name
        return gemini
    }

    private func requestMessages(
        forSlice slice: TurnSystemSlice,
        transcriptMessages: [LLMMessage],
        cacheEntry: GeminiConversationCacheEntry?
    ) -> [LLMMessage] {
        guard cacheEntry != nil,
              let latestMessage = transcriptMessages.last,
              latestMessage.role == "user" else {
            return transcriptMessages
        }

        let prefixedContent = Self.prefixedUserMessageContent(
            volatile: slice.volatile,
            userContent: latestMessage.content
        )
        return [LLMMessage(role: "user", content: prefixedContent)]
    }

    private func requestSystem(
        forSlice slice: TurnSystemSlice,
        cacheEntry: GeminiConversationCacheEntry?
    ) -> String? {
        if cacheEntry != nil { return nil }
        return slice.combined
    }

    private func activeGeminiHistoryCache(
        nodeId: UUID,
        llm: any LLMService,
        stableSystem: String,
        transcriptMessages: [LLMMessage]
    ) -> GeminiConversationCacheEntry? {
        guard shouldUseGeminiHistoryCache() else {
            clearGeminiHistoryCacheIfPresent(nodeId: nodeId, llm: llm)
            return nil
        }
        guard let gemini = llm as? GeminiLLMService else { return nil }
        guard transcriptMessages.count >= 2 else { return nil }
        let prefixHash = GeminiPromptCacheService.promptHash(
            system: stableSystem,
            messages: Array(transcriptMessages.dropLast())
        )
        return geminiPromptCache.activeCache(
            for: nodeId,
            model: gemini.model,
            promptHash: prefixHash
        )
    }

    private func configuredStreamingService(
        from llm: any LLMService,
        sink: TurnSequencedEventSink,
        state: TurnExecutionStreamState,
        captureThinking: Bool,
        cacheableSystemPrefix: String?
    ) -> any LLMService {
        if var gemini = llm as? GeminiLLMService {
            gemini.onUsageMetadata = { [recordGeminiUsage] usage in
                recordGeminiUsage(usage)
            }
            gemini.thinkingBudgetTokens = ModelHarnessProfileCatalog.thinkingBudgetTokens(for: .gemini)
            gemini.onBudgetExhausted = {
                await state.markBudgetExhausted()
            }

            guard captureThinking else { return gemini }

            gemini.onThinkingDelta = { delta in
                if let displayDelta = await state.appendThinking(
                    delta,
                    title: ThinkingTraceTitles.assistant
                ) {
                    await sink.emit(.thinkingDelta(displayDelta))
                }
            }
            return gemini
        }

        if var claude = llm as? ClaudeLLMService {
            claude.cacheableSystemPrefix = cacheableSystemPrefix
            claude.thinkingBudgetTokens = ModelHarnessProfileCatalog.thinkingBudgetTokens(for: .claude)
            guard captureThinking else { return claude }
            claude.onThinkingDelta = { delta in
                if let displayDelta = await state.appendThinking(
                    delta,
                    title: ThinkingTraceTitles.assistant
                ) {
                    await sink.emit(.thinkingDelta(displayDelta))
                }
            }
            return claude
        }

        if var openRouter = llm as? OpenRouterLLMService {
            openRouter.reasoningBudgetTokens = ModelHarnessProfileCatalog.thinkingBudgetTokens(for: .openrouter)
            guard captureThinking else { return openRouter }
            openRouter.onThinkingDelta = { delta in
                if let displayDelta = await state.appendThinking(
                    delta,
                    title: ThinkingTraceTitles.assistant
                ) {
                    await sink.emit(.thinkingDelta(displayDelta))
                }
            }
            return openRouter
        }

        guard captureThinking else { return llm }

        return llm
    }

    private func clearGeminiHistoryCacheIfPresent(nodeId: UUID, llm: any LLMService) {
        let existingEntry = geminiPromptCache.removeEntry(for: nodeId)
        guard let gemini = llm as? GeminiLLMService, let existingEntry else { return }
        Task {
            try? await gemini.deleteCachedContent(name: existingEntry.name)
        }
    }

    private static func prefixedUserMessageContent(volatile: String, userContent: String) -> String {
        guard !volatile.isEmpty else { return userContent }
        return """
        <turn-context>
        \(volatile)
        </turn-context>

        \(userContent)
        """
    }

}

actor TurnExecutionStreamState {
    private var thinking: String = ""
    private var thinkingTrace = ThinkingTraceAccumulator()
    private(set) var didHitBudgetExhaustion: Bool = false

    func appendThinking(_ delta: String, title: String) -> String? {
        guard let displayDelta = thinkingTrace.append(delta, title: title) else {
            return nil
        }
        thinking.append(displayDelta)
        return displayDelta
    }

    func markBudgetExhausted() {
        didHitBudgetExhaustion = true
    }

    var persistedThinking: String? {
        let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : thinking
    }
}
