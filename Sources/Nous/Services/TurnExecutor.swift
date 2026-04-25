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
        sink: TurnSequencedEventSink
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
                captureThinking: true,
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
        if shouldPersistAssistantThinking() {
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
        let assistantContent = ClarificationCardParser.stripChatTitle(from: rawAssistantContent)
        let conversationTitle = Self.sanitizedConversationTitle(
            from: ClarificationCardParser.extractChatTitle(from: rawAssistantContent)
        )

        return TurnExecutionResult(
            rawAssistantContent: rawAssistantContent,
            assistantContent: assistantContent,
            persistedThinking: persistedThinking,
            conversationTitle: conversationTitle,
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

            guard captureThinking else { return gemini }

            gemini.thinkingBudgetTokens = 2000
            gemini.onThinkingDelta = { delta in
                await state.appendThinking(delta)
                await sink.emit(.thinkingDelta(delta))
            }
            gemini.onBudgetExhausted = {
                await state.markBudgetExhausted()
            }
            return gemini
        }

        if var claude = llm as? ClaudeLLMService {
            claude.cacheableSystemPrefix = cacheableSystemPrefix
            guard captureThinking else { return claude }
            claude.thinkingBudgetTokens = 1024
            claude.onThinkingDelta = { delta in
                await state.appendThinking(delta)
                await sink.emit(.thinkingDelta(delta))
            }
            return claude
        }

        guard captureThinking else { return llm }

        if var openRouter = llm as? OpenRouterLLMService {
            openRouter.reasoningBudgetTokens = 1024
            openRouter.onThinkingDelta = { delta in
                await state.appendThinking(delta)
                await sink.emit(.thinkingDelta(delta))
            }
            return openRouter
        }

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

    private static func sanitizedConversationTitle(from raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        title = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while title.contains("  ") {
            title = title.replacingOccurrences(of: "  ", with: " ")
        }

        while let first = title.first, first == "#" || first == "-" || first == "*" || first.isWhitespace {
            title.removeFirst()
        }

        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:。！？、，；："))

        let filteredScalars = title.unicodeScalars.filter { scalar in
            !CharacterSet(charactersIn: "<>|/\\").contains(scalar)
        }
        title = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if title.count > 48 {
            title = String(title.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return title.isEmpty ? nil : title
    }
}

actor TurnExecutionStreamState {
    private var thinking: String = ""
    private(set) var didHitBudgetExhaustion: Bool = false

    func appendThinking(_ delta: String) {
        thinking.append(delta)
    }

    func markBudgetExhausted() {
        didHitBudgetExhaustion = true
    }

    var persistedThinking: String? {
        let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : thinking
    }
}
