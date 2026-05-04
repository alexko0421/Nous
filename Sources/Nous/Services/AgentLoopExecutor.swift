import Foundation

enum AgentLoopError: LocalizedError {
    case timeout(String, Double)

    var errorDescription: String? {
        switch self {
        case .timeout(let label, let seconds):
            return "\(label) timed out after \(Int(seconds))s."
        }
    }
}

final class AgentLoopExecutor {
    static let maxIterations = 8

    private let llmService: any ToolCallingLLMService
    private let registry: AgentToolRegistry
    private let perToolTimeoutSeconds: Double
    private let totalTurnTimeoutSeconds: Double
    private let shouldPersistAssistantThinking: () -> Bool

    init(
        llmService: any ToolCallingLLMService,
        registry: AgentToolRegistry,
        perToolTimeoutSeconds: Double = 5,
        totalTurnTimeoutSeconds: Double = 60,
        shouldPersistAssistantThinking: @escaping () -> Bool = { true }
    ) {
        self.llmService = llmService
        self.registry = registry
        self.perToolTimeoutSeconds = perToolTimeoutSeconds
        self.totalTurnTimeoutSeconds = totalTurnTimeoutSeconds
        self.shouldPersistAssistantThinking = shouldPersistAssistantThinking
    }

    func execute(
        plan: TurnPlan,
        request: TurnRequest,
        sink: TurnSequencedEventSink,
        context: AgentToolContext,
        captureThinking: Bool = true
    ) async throws -> TurnExecutionResult? {
        do {
            try Task.checkCancellation()
            let deadline = Date().addingTimeInterval(totalTurnTimeoutSeconds)
            var transcript = plan.transcriptMessages.map {
                AgentLoopMessage.text(role: $0.role, content: $0.content)
            }
            var trace: [AgentTraceRecord] = []
            var toolContext = context
            var thinkingContent = ""
            var thinkingTrace = ThinkingTraceAccumulator()

            for iterationIndex in 0..<Self.maxIterations {
                let iteration = iterationIndex + 1
                try Self.checkDeadline(deadline, totalSeconds: totalTurnTimeoutSeconds)
                let messagesForCall = transcript
                let response = try await Self.withTimeout(
                    label: "Agent LLM call",
                    seconds: Self.remainingSeconds(until: deadline, cap: totalTurnTimeoutSeconds)
                ) {
                    try await self.llmService.callWithTools(
                        systemBlocks: plan.turnSlice.blocks,
                        messages: messagesForCall,
                        tools: self.registry.declarations,
                        allowToolCalls: true
                    )
                }
                await Self.appendThinking(
                    response.thinkingContent,
                    trace: &thinkingTrace,
                    to: &thinkingContent,
                    sink: sink,
                    captureThinking: captureThinking
                )
                transcript.append(response.assistantMessage)

                guard !response.toolCalls.isEmpty else {
                    await sink.emit(.textDelta(response.text))
                    return Self.executionResult(
                        from: response.text,
                        trace: trace,
                        thinkingContent: persistedThinking(from: thinkingContent)
                    )
                }

                var batchDiscoveredNodeIds: Set<UUID> = []
                for toolCall in response.toolCalls {
                    let callRecord = Self.toolCallRecord(
                        toolCall,
                        provider: plan.provider,
                        quickActionMode: toolContext.activeQuickActionMode,
                        iteration: iteration
                    )
                    trace.append(callRecord)
                    await sink.emit(.agentTraceDelta(callRecord))

                    let toolResultMessage: AgentLoopMessage
                    let toolStartedAt = Date()
                    do {
                        let input = try AgentToolInput(argumentsJSON: toolCall.argumentsJSON)
                        guard let tool = registry.tool(named: toolCall.name) else {
                            throw AgentToolError.notFound(toolCall.name)
                        }
                        try Self.checkDeadline(deadline, totalSeconds: totalTurnTimeoutSeconds)
                        let contextForTool = toolContext
                        let result = try await Self.withTimeout(
                            label: toolCall.name,
                            seconds: min(perToolTimeoutSeconds, Self.remainingSeconds(until: deadline, cap: perToolTimeoutSeconds))
                        ) {
                            try await tool.execute(input: input, context: contextForTool)
                        }
                        batchDiscoveredNodeIds.formUnion(result.discoveredNodeIds)
                        toolResultMessage = .toolResult(
                            toolCallId: toolCall.id,
                            name: toolCall.name,
                            content: result.summary,
                            isError: false
                        )
                        let resultRecord = Self.toolResultRecord(
                            toolCall: toolCall,
                            result: result,
                            provider: plan.provider,
                            quickActionMode: toolContext.activeQuickActionMode,
                            iteration: iteration,
                            durationMilliseconds: Self.durationMilliseconds(since: toolStartedAt)
                        )
                        trace.append(resultRecord)
                        await sink.emit(.agentTraceDelta(resultRecord))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let message = error.localizedDescription
                        toolResultMessage = .toolResult(
                            toolCallId: toolCall.id,
                            name: toolCall.name,
                            content: "Tool error: \(message)",
                            isError: true
                        )
                        let errorRecord = Self.toolErrorRecord(
                            toolCall: toolCall,
                            errorDescription: message,
                            errorCategory: Self.errorCategory(for: error),
                            provider: plan.provider,
                            quickActionMode: toolContext.activeQuickActionMode,
                            iteration: iteration,
                            durationMilliseconds: Self.durationMilliseconds(since: toolStartedAt)
                        )
                        trace.append(errorRecord)
                        await sink.emit(.agentTraceDelta(errorRecord))
                    }
                    transcript.append(toolResultMessage)
                }
                toolContext = Self.context(toolContext, adding: batchDiscoveredNodeIds)
            }

            let capRecord = AgentTraceRecord(
                kind: .capReached,
                title: "Reached 8 steps",
                detail: "Synthesizing now."
            )
            trace.append(capRecord)
            await sink.emit(.agentTraceDelta(capRecord))
            let messagesForFinalCall = transcript
            let finalResponse = try await Self.withTimeout(
                label: "Final agent LLM call",
                seconds: Self.remainingSeconds(until: deadline, cap: totalTurnTimeoutSeconds)
            ) {
                try await self.llmService.callWithTools(
                    systemBlocks: plan.turnSlice.blocks,
                    messages: messagesForFinalCall,
                    tools: self.registry.declarations,
                    allowToolCalls: false
                    )
                }
            await Self.appendThinking(
                finalResponse.thinkingContent,
                trace: &thinkingTrace,
                to: &thinkingContent,
                sink: sink,
                captureThinking: captureThinking
            )
            await sink.emit(.textDelta(finalResponse.text))
            return Self.executionResult(
                from: finalResponse.text,
                trace: trace,
                thinkingContent: persistedThinking(from: thinkingContent)
            )
        } catch is CancellationError {
            return nil
        }
    }

    private func persistedThinking(from thinkingContent: String) -> String? {
        guard shouldPersistAssistantThinking() else { return nil }
        let trimmed = thinkingContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : thinkingContent
    }

    private static func executionResult(
        from rawAssistantContent: String,
        trace: [AgentTraceRecord],
        thinkingContent: String?
    ) -> TurnExecutionResult {
        let normalized = AssistantTurnNormalizer.normalize(rawAssistantContent)
        return TurnExecutionResult(
            rawAssistantContent: normalized.rawAssistantContent,
            assistantContent: normalized.assistantContent,
            persistedThinking: thinkingContent,
            conversationTitle: normalized.conversationTitle,
            didHitBudgetExhaustion: false,
            agentTraceJson: AgentTraceCodec.encode(trace)
        )
    }

    private static func appendThinking(
        _ delta: String?,
        trace: inout ThinkingTraceAccumulator,
        to thinkingContent: inout String,
        sink: TurnSequencedEventSink,
        captureThinking: Bool
    ) async {
        guard captureThinking else { return }
        guard let delta, !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard let displayDelta = trace.append(delta, title: ThinkingTraceTitles.agentLoop) else {
            return
        }
        thinkingContent.append(displayDelta)
        await sink.emit(.thinkingDelta(displayDelta))
    }

    private static func context(_ context: AgentToolContext, adding nodeIds: Set<UUID>) -> AgentToolContext {
        AgentToolContext(
            conversationId: context.conversationId,
            projectId: context.projectId,
            currentNodeId: context.currentNodeId,
            currentMessage: context.currentMessage,
            activeQuickActionMode: context.activeQuickActionMode,
            indexedSkillIds: context.indexedSkillIds,
            excludeNodeIds: context.excludeNodeIds,
            allowedReadNodeIds: context.allowedReadNodeIds.union(nodeIds),
            maxToolResultCharacters: context.maxToolResultCharacters
        )
    }

    private static func toolCallRecord(
        _ toolCall: AgentToolCall,
        provider: LLMProvider,
        quickActionMode: QuickActionMode?,
        iteration: Int
    ) -> AgentTraceRecord {
        AgentTraceRecord(
            kind: .toolCall,
            toolName: toolCall.name,
            title: title(for: toolCall.name, isCall: true),
            detail: "",
            inputJSON: toolCall.argumentsJSON,
            provider: provider,
            quickActionMode: quickActionMode,
            iteration: iteration
        )
    }

    private static func toolResultRecord(
        toolCall: AgentToolCall,
        result: AgentToolResult,
        provider: LLMProvider,
        quickActionMode: QuickActionMode?,
        iteration: Int,
        durationMilliseconds: Int
    ) -> AgentTraceRecord {
        AgentTraceRecord(
            kind: .toolResult,
            toolName: toolCall.name,
            title: title(for: toolCall.name, isCall: false),
            detail: result.traceContent,
            inputJSON: toolCall.argumentsJSON,
            provider: provider,
            quickActionMode: quickActionMode,
            durationMilliseconds: durationMilliseconds,
            iteration: iteration,
            outcome: .success
        )
    }

    private static func toolErrorRecord(
        toolCall: AgentToolCall,
        errorDescription: String,
        errorCategory: AgentTraceRecord.ToolErrorCategory,
        provider: LLMProvider,
        quickActionMode: QuickActionMode?,
        iteration: Int,
        durationMilliseconds: Int
    ) -> AgentTraceRecord {
        AgentTraceRecord(
            kind: .toolError,
            toolName: toolCall.name,
            title: "\(toolCall.name) failed",
            detail: errorDescription,
            inputJSON: toolCall.argumentsJSON,
            provider: provider,
            quickActionMode: quickActionMode,
            durationMilliseconds: durationMilliseconds,
            iteration: iteration,
            outcome: .failure,
            errorCategory: errorCategory
        )
    }

    private static func durationMilliseconds(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
    }

    private static func errorCategory(for error: Error) -> AgentTraceRecord.ToolErrorCategory {
        if let toolError = error as? AgentToolError {
            switch toolError {
            case .missingArgument, .invalidArgument:
                return .invalidArguments
            case .notFound:
                return .notFound
            case .unauthorized:
                return .unauthorized
            case .unavailable:
                return .unexpectedEnvironment
            }
        }
        if error is AgentLoopError {
            return .timeout
        }
        if error is LLMError || error is URLError {
            return .providerError
        }
        return .unknown
    }

    private static func title(for toolName: String, isCall: Bool) -> String {
        switch (toolName, isCall) {
        case (AgentToolNames.searchMemory, true):
            return "Searching memory..."
        case (AgentToolNames.searchMemory, false):
            return "Memory results"
        case (AgentToolNames.recallRecentConversations, true):
            return "Recalling recent conversations..."
        case (AgentToolNames.recallRecentConversations, false):
            return "Recent conversations"
        case (AgentToolNames.findContradictions, true):
            return "Checking contradictions..."
        case (AgentToolNames.findContradictions, false):
            return "Contradiction candidates"
        case (AgentToolNames.searchConversationsByTopic, true):
            return "Searching conversations..."
        case (AgentToolNames.searchConversationsByTopic, false):
            return "Conversation results"
        case (AgentToolNames.readNote, true):
            return "Reading note..."
        case (AgentToolNames.readNote, false):
            return "Read result"
        default:
            return isCall ? "Running \(toolName)..." : "\(toolName) result"
        }
    }

    private static func checkDeadline(_ deadline: Date, totalSeconds: Double) throws {
        if Date() >= deadline {
            throw AgentLoopError.timeout("Agent turn", totalSeconds)
        }
    }

    private static func remainingSeconds(until deadline: Date, cap: Double) -> Double {
        max(0.1, min(cap, deadline.timeIntervalSinceNow))
    }

    private static func withTimeout<T: Sendable>(
        label: String,
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AgentLoopError.timeout(label, seconds)
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
