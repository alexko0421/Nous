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
                cacheableSystemPrefix: resolvedCacheEntry == nil ? plan.turnSlice.stable : nil,
                mode: plan.effectiveMode
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
        let assistantContent = Self.enforceQuestionDiscipline(
            on: ClarificationCardParser.stripChatTitle(from: rawAssistantContent)
        )
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
        cacheableSystemPrefix: String?,
        mode: ChatMode
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
            claude.thinkingBudgetTokens = mode.thinkingBudgetTokens
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

    /// Prompt-only question discipline has proven too soft in production: the model
    /// can still drift into interview mode and end every sentence with `?`. Enforce
    /// a minimal post-generation cap on visible reply text while leaving hidden tags
    /// intact. This mirrors the approved prompt rule (`max one ?`, with a narrow
    /// clarify-options exception) without touching `anchor.md`, which is frozen.
    static func enforceQuestionDiscipline(on text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard !trimmed.hasPrefix("Error:") else { return trimmed }
        guard ClarificationCardParser.extractSummary(from: trimmed) == nil else { return trimmed }
        guard trimmed.range(of: "<clarify>", options: [.caseInsensitive]) == nil else { return trimmed }

        let protected = protectBlocks(
            in: trimmed,
            patterns: [
                #"```[\s\S]*?```"#,
                #"`[^`\n]+`"#,
                #"<signature_moments>[\s\S]*?</signature_moments>\s*$"#,
                #"<signature_moments>[\s\S]*$"#
            ]
        )
        let visible = protected.text

        let questionIndices = visible.indices.filter {
            visible[$0] == "?" || visible[$0] == "？"
        }
        guard questionIndices.count > 1 else { return trimmed }

        let allowedQuestions = hasClarifyingOptionsException(in: visible, questionIndices: questionIndices) ? 2 : 1
        var normalized = ""
        var questionCount = 0
        normalized.reserveCapacity(visible.count)

        for character in visible {
            if character == "?" || character == "？" {
                questionCount += 1
                if questionCount <= allowedQuestions {
                    normalized.append(character)
                } else {
                    normalized.append(character == "？" ? "。" : ".")
                }
            } else {
                normalized.append(character)
            }
        }

        return restoreProtectedBlocks(in: normalized, replacements: protected.replacements)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func protectBlocks(
        in text: String,
        patterns: [String]
    ) -> (text: String, replacements: [String: String]) {
        var working = text
        var replacements: [String: String] = [:]

        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive, .dotMatchesLineSeparators]
                )
            else {
                continue
            }

            while let range = nsRange(for: working),
                  let match = regex.firstMatch(in: working, options: [], range: range),
                  let matchRange = Range(match.range, in: working) {
                let token = "__NOUS_PROTECTED_\(replacements.count)__"
                replacements[token] = String(working[matchRange])
                working.replaceSubrange(matchRange, with: token)
            }
        }

        return (working, replacements)
    }

    private static func restoreProtectedBlocks(
        in text: String,
        replacements: [String: String]
    ) -> String {
        replacements.reduce(into: text) { result, entry in
            result = result.replacingOccurrences(of: entry.key, with: entry.value)
        }
    }

    private static func hasClarifyingOptionsException(
        in text: String,
        questionIndices: [String.Index]
    ) -> Bool {
        guard questionIndices.count >= 2 else { return false }

        let firstQuestion = questionIndices[0]
        let secondQuestion = questionIndices[1]
        let start = text.index(after: firstQuestion)
        guard start < secondQuestion else { return false }

        let between = text[start..<secondQuestion]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !between.isEmpty else { return false }

        let optionPrefixes = [
            "系",
            "係",
            "定系",
            "定係",
            "还是",
            "還是",
            "or ",
            "is it ",
            "do you mean "
        ]

        return optionPrefixes.contains { prefix in
            between.lowercased().hasPrefix(prefix.lowercased())
        }
    }

    private static func nsRange(for text: String) -> NSRange? {
        NSRange(text.startIndex..<text.endIndex, in: text)
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
