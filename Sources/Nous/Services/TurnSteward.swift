import Foundation

protocol SpeechActClassifying: AnyObject {
    func classify(text: String) async throws -> SpeechActClassifierOutput
}

final class TurnSteward {
    private let skillStore: (any SkillStoring)?
    private let userId: String
    private let routerModeProvider: () -> ResponseStanceRouterMode
    private let currentProviderProvider: () -> LLMProvider
    private let llmServiceProvider: () -> (any LLMService)?
    private let classifier: (any SpeechActClassifying)?

    init(
        skillStore: (any SkillStoring)? = nil,
        userId: String = "alex",
        routerModeProvider: @escaping () -> ResponseStanceRouterMode = { ResponseStanceRouterMode.current() },
        currentProviderProvider: @escaping () -> LLMProvider = { .local },
        llmServiceProvider: @escaping () -> (any LLMService)? = { nil },
        classifier: (any SpeechActClassifying)? = nil
    ) {
        self.skillStore = skillStore
        self.userId = userId
        self.routerModeProvider = routerModeProvider
        self.currentProviderProvider = currentProviderProvider
        self.llmServiceProvider = llmServiceProvider
        self.classifier = classifier
    }

    func steer(
        prepared: PreparedTurnSession,
        request: TurnRequest
    ) -> TurnStewardDecision {
        let legacy = steerLegacy(prepared: prepared, request: request)
        let mode = routerModeProvider()
        let normalized = request.inputText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let deterministic = deterministicResponseStance(for: normalized).result
        if deterministic.stance == .supportFirst {
            if legacy.route == .sourceAnalysis {
                return legacy.withRouterTrace(mode: mode, routing: deterministic)
            }
            if mode == .active {
                return activeDecision(
                    from: legacy,
                    normalizedText: normalized,
                    routing: deterministic,
                    mode: mode
                )
            }
            return legacy.withRouterTrace(mode: mode, routing: deterministic)
        }
        guard legacy.route == .ordinaryChat else {
            return legacy.withRouterTrace(
                mode: mode,
                routing: routingForLegacyRoute(legacy, normalizedText: normalized),
                traceJudgePolicy: legacy.judgePolicy
            )
        }

        let routing = deterministic
        if mode == .active {
            return activeDecision(
                from: legacy,
                normalizedText: normalized,
                routing: routing,
                mode: mode
            )
        }
        return legacy.withRouterTrace(mode: mode, routing: routing)
    }

    func steerForTurn(
        prepared: PreparedTurnSession,
        request: TurnRequest
    ) async -> TurnStewardDecision {
        let legacy = steerLegacy(prepared: prepared, request: request)
        let mode = routerModeProvider()
        let text = request.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased()
        let deterministic = deterministicResponseStance(for: normalized).result
        if deterministic.stance == .supportFirst {
            if legacy.route == .sourceAnalysis {
                return legacy.withRouterTrace(mode: mode, routing: deterministic)
            }
            if mode == .active {
                return activeDecision(
                    from: legacy,
                    normalizedText: normalized,
                    routing: deterministic,
                    mode: mode
                )
            }
            return legacy.withRouterTrace(mode: mode, routing: deterministic)
        }
        guard legacy.route == .ordinaryChat else {
            return legacy.withRouterTrace(
                mode: mode,
                routing: routingForLegacyRoute(legacy, normalizedText: normalized),
                traceJudgePolicy: legacy.judgePolicy
            )
        }

        let routing = await responseStanceRouting(for: normalized, mode: mode)

        switch mode {
        case .off, .shadow:
            return legacy.withRouterTrace(mode: mode, routing: routing)
        case .active:
            return activeDecision(
                from: legacy,
                normalizedText: normalized,
                routing: routing,
                mode: mode
            )
        }
    }

    private func steerLegacy(
        prepared: PreparedTurnSession,
        request: TurnRequest
    ) -> TurnStewardDecision {
        if let activeMode = request.snapshot.activeQuickActionMode {
            return decision(forActiveMode: activeMode)
        }

        let text = request.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased()

        if !request.sourceMaterials.isEmpty {
            return TurnStewardDecision(
                route: .sourceAnalysis,
                memoryPolicy: .full,
                challengeStance: .useSilently,
                responseShape: .answerNow,
                source: .deterministic,
                reason: "source material attached"
            )
        }

        let route = route(for: normalized)
        let memoryOptOut = containsAny(normalized, in: Self.memoryOptOutCues)
        let distress = containsAny(normalized, in: Self.distressCues)

        if distress, route == .ordinaryChat {
            return TurnStewardDecision(
                route: .ordinaryChat,
                memoryPolicy: .conversationOnly,
                challengeStance: .supportFirst,
                responseShape: .answerNow,
                source: .deterministic,
                reason: "emotional distress cue"
            )
        }

        if route == .ordinaryChat, !memoryOptOut, analysisGateMatches(normalized) {
            return TurnStewardDecision(
                route: .ordinaryChat,
                memoryPolicy: .full,
                challengeStance: .surfaceTension,
                responseShape: .answerNow,
                source: .deterministic,
                reason: "analysis skill cue"
            )
        }

        switch route {
        case .brainstorm:
            return TurnStewardDecision(
                route: .brainstorm,
                memoryPolicy: .lean,
                challengeStance: .useSilently,
                responseShape: .listDirections,
                source: .deterministic,
                reason: memoryOptOut ? "explicit brainstorm with memory opt-out" : "explicit brainstorm cue"
            )
        case .plan:
            return TurnStewardDecision(
                route: .plan,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: distress ? .supportFirst : .surfaceTension,
                responseShape: .producePlan,
                source: .deterministic,
                reason: "explicit plan cue"
            )
        case .direction:
            return TurnStewardDecision(
                route: .direction,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: distress ? .supportFirst : .surfaceTension,
                responseShape: .narrowNextStep,
                source: .deterministic,
                reason: "explicit direction cue"
            )
        case .sourceAnalysis:
            return TurnStewardDecision(
                route: .sourceAnalysis,
                memoryPolicy: .full,
                challengeStance: .useSilently,
                responseShape: .answerNow,
                source: .deterministic,
                reason: "source material attached"
            )
        case .ordinaryChat:
            return TurnStewardDecision(
                route: .ordinaryChat,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: distress ? .supportFirst : .useSilently,
                responseShape: .answerNow,
                source: .deterministic,
                reason: memoryOptOut ? "memory opt-out cue" : "ordinary chat default"
            )
        }
    }

    private func responseStanceRouting(
        for normalized: String,
        mode: ResponseStanceRouterMode
    ) async -> SpeechActRoutingResult {
        let deterministic = deterministicResponseStance(for: normalized)
        if deterministic.isTerminal || mode == .off {
            return deterministic.result
        }

        guard currentProviderProvider() != .local else {
            return deterministic.result
        }

        guard let classifier = classifier ?? makeCloudClassifier() else {
            return deterministic.result
                .with(source: .fallback, fallbackUsed: true, reason: "classifier unavailable")
        }

        do {
            let output = try await classifier.classify(text: normalized)
            return gatedClassifierResult(
                output,
                deterministicFallback: deterministic.result,
                explicitHardChallenge: hasExplicitHardJudgeCue(normalized)
            )
        } catch is CancellationError {
            return deterministic.result
                .with(source: .fallback, fallbackUsed: true, reason: "classifier cancelled")
        } catch {
            return deterministic.result
                .with(source: .fallback, fallbackUsed: true, reason: "classifier failed")
        }
    }

    private func deterministicResponseStance(for normalized: String) -> DeterministicStanceResult {
        if containsAny(normalized, in: Self.distressCues) {
            return DeterministicStanceResult(
                result: SpeechActRoutingResult(
                    stance: .supportFirst,
                    source: .deterministic,
                    confidence: nil,
                    softerFallback: nil,
                    fallbackUsed: false,
                    reason: "support-first distress cue"
                ),
                isTerminal: true
            )
        }

        if hasExplicitHardJudgeCue(normalized) {
            return DeterministicStanceResult(
                result: SpeechActRoutingResult(
                    stance: .hardJudge,
                    source: .deterministic,
                    confidence: nil,
                    softerFallback: .softAnalysis,
                    fallbackUsed: false,
                    reason: "explicit hard judge cue"
                ),
                isTerminal: true
            )
        }

        if containsAny(normalized, in: Self.softAnalysisCues) || analysisGateMatches(normalized) {
            return DeterministicStanceResult(
                result: SpeechActRoutingResult(
                    stance: .softAnalysis,
                    source: .deterministic,
                    confidence: nil,
                    softerFallback: .reflective,
                    fallbackUsed: false,
                    reason: "soft analysis cue"
                ),
                isTerminal: true
            )
        }

        if containsAny(normalized, in: Self.ambiguousDecisionCues) {
            return DeterministicStanceResult(
                result: SpeechActRoutingResult(
                    stance: .softAnalysis,
                    source: .fallback,
                    confidence: nil,
                    softerFallback: .reflective,
                    fallbackUsed: true,
                    reason: "ambiguous decision fallback"
                ),
                isTerminal: false
            )
        }

        if containsAny(normalized, in: Self.broadOpinionCues) {
            return DeterministicStanceResult(
                result: SpeechActRoutingResult(
                    stance: .companion,
                    source: .fallback,
                    confidence: nil,
                    softerFallback: .reflective,
                    fallbackUsed: true,
                    reason: "ambiguous opinion fallback"
                ),
                isTerminal: false
            )
        }

        if containsAny(normalized, in: Self.reflectiveCues) {
            return DeterministicStanceResult(
                result: SpeechActRoutingResult(
                    stance: .reflective,
                    source: .deterministic,
                    confidence: nil,
                    softerFallback: .companion,
                    fallbackUsed: false,
                    reason: "reflective cue"
                ),
                isTerminal: true
            )
        }

        return DeterministicStanceResult(
            result: SpeechActRoutingResult(
                stance: .companion,
                source: .deterministic,
                confidence: nil,
                softerFallback: nil,
                fallbackUsed: false,
                reason: "ordinary companion default"
            ),
            isTerminal: true
        )
    }

    private func gatedClassifierResult(
        _ output: SpeechActClassifierOutput,
        deterministicFallback: SpeechActRoutingResult,
        explicitHardChallenge: Bool
    ) -> SpeechActRoutingResult {
        let normalizedConfidence = min(max(output.confidence, 0), 1)
        let requestedStance = output.stance
        let softerFallback = output.softerFallback

        if requestedStance == .hardJudge, !explicitHardChallenge {
            let fallback = softerFallback == .hardJudge ? .softAnalysis : softerFallback
            return SpeechActRoutingResult(
                stance: fallback,
                source: .classifier,
                confidence: normalizedConfidence,
                softerFallback: fallback,
                fallbackUsed: true,
                reason: output.reason
            )
        }

        if normalizedConfidence >= 0.75 {
            return SpeechActRoutingResult(
                stance: requestedStance,
                source: .classifier,
                confidence: normalizedConfidence,
                softerFallback: softerFallback,
                fallbackUsed: false,
                reason: output.reason
            )
        }

        if normalizedConfidence >= 0.45 {
            let fallback = softerFallback == .hardJudge ? deterministicFallback.stance.softerFallback : softerFallback
            return SpeechActRoutingResult(
                stance: fallback,
                source: .classifier,
                confidence: normalizedConfidence,
                softerFallback: softerFallback,
                fallbackUsed: true,
                reason: output.reason
            )
        }

        let lowConfidenceFallback = deterministicFallback.softerFallback ?? deterministicFallback.stance.softerFallback
        return SpeechActRoutingResult(
            stance: lowConfidenceFallback,
            source: .fallback,
            confidence: normalizedConfidence,
            softerFallback: softerFallback,
            fallbackUsed: true,
            reason: output.reason
        )
    }

    private func activeDecision(
        from legacy: TurnStewardDecision,
        normalizedText: String,
        routing: SpeechActRoutingResult,
        mode: ResponseStanceRouterMode
    ) -> TurnStewardDecision {
        let memoryOptOut = containsAny(normalizedText, in: Self.memoryOptOutCues)

        switch routing.stance {
        case .supportFirst:
            return TurnStewardDecision(
                route: .ordinaryChat,
                memoryPolicy: .conversationOnly,
                challengeStance: .supportFirst,
                responseShape: .answerNow,
                source: legacy.trace.source,
                reason: routing.reason,
                responseStance: routing.stance,
                judgePolicy: .off,
                routerMode: mode,
                routerSource: routing.source,
                confidence: routing.confidence,
                softerFallback: routing.softerFallback,
                fallbackUsed: routing.fallbackUsed,
                routerReason: routing.reason
            )
        case .companion, .reflective:
            return TurnStewardDecision(
                route: .ordinaryChat,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: .useSilently,
                responseShape: .answerNow,
                source: legacy.trace.source,
                reason: legacy.trace.reason,
                responseStance: routing.stance,
                judgePolicy: .off,
                routerMode: mode,
                routerSource: routing.source,
                confidence: routing.confidence,
                softerFallback: routing.softerFallback,
                fallbackUsed: routing.fallbackUsed,
                routerReason: routing.reason
            )
        case .softAnalysis:
            let effectiveJudgePolicy: JudgePolicy = memoryOptOut ? .off : .silentFraming
            return TurnStewardDecision(
                route: .ordinaryChat,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: .useSilently,
                responseShape: .answerNow,
                source: legacy.trace.source,
                reason: legacy.trace.reason,
                responseStance: routing.stance,
                judgePolicy: effectiveJudgePolicy,
                traceJudgePolicy: effectiveJudgePolicy,
                routerMode: mode,
                routerSource: routing.source,
                confidence: routing.confidence,
                softerFallback: routing.softerFallback,
                fallbackUsed: routing.fallbackUsed,
                routerReason: routing.reason
            )
        case .hardJudge:
            let effectiveJudgePolicy: JudgePolicy = memoryOptOut ? .off : .visibleTension
            return TurnStewardDecision(
                route: .ordinaryChat,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: memoryOptOut ? .useSilently : .surfaceTension,
                responseShape: .answerNow,
                source: legacy.trace.source,
                reason: legacy.trace.reason,
                responseStance: routing.stance,
                judgePolicy: effectiveJudgePolicy,
                traceJudgePolicy: effectiveJudgePolicy,
                routerMode: mode,
                routerSource: routing.source,
                confidence: routing.confidence,
                softerFallback: routing.softerFallback,
                fallbackUsed: routing.fallbackUsed,
                routerReason: routing.reason
            )
        }
    }

    private func makeCloudClassifier() -> (any SpeechActClassifying)? {
        guard let llm = llmServiceProvider() else { return nil }
        return CloudSpeechActClassifier(llmService: llm)
    }

    private func routingForLegacyRoute(
        _ legacy: TurnStewardDecision,
        normalizedText: String
    ) -> SpeechActRoutingResult {
        let stance: ResponseStance
        let softerFallback: ResponseStance?

        if legacy.challengeStance == .supportFirst {
            stance = .supportFirst
            softerFallback = nil
        } else if hasExplicitHardJudgeCue(normalizedText) {
            stance = .hardJudge
            softerFallback = .softAnalysis
        } else {
            switch legacy.route {
            case .plan, .direction:
                stance = .softAnalysis
                softerFallback = .reflective
            case .sourceAnalysis:
                stance = .softAnalysis
                softerFallback = .reflective
            case .brainstorm, .ordinaryChat:
                stance = .companion
                softerFallback = nil
            }
        }

        return SpeechActRoutingResult(
            stance: stance,
            source: .deterministic,
            confidence: nil,
            softerFallback: softerFallback,
            fallbackUsed: false,
            reason: legacy.trace.reason
        )
    }

    private func decision(forActiveMode mode: QuickActionMode) -> TurnStewardDecision {
        switch mode {
        case .direction:
            return TurnStewardDecision(
                route: .direction,
                memoryPolicy: .full,
                challengeStance: .surfaceTension,
                responseShape: .narrowNextStep,
                source: .deterministic,
                reason: "active quick action mode"
            )
        case .brainstorm:
            return TurnStewardDecision(
                route: .brainstorm,
                memoryPolicy: .lean,
                challengeStance: .useSilently,
                responseShape: .listDirections,
                source: .deterministic,
                reason: "active quick action mode"
            )
        case .plan:
            return TurnStewardDecision(
                route: .plan,
                memoryPolicy: .full,
                challengeStance: .surfaceTension,
                responseShape: .producePlan,
                source: .deterministic,
                reason: "active quick action mode"
            )
        }
    }

    private func route(for text: String) -> TurnRoute {
        if containsAny(text, in: Self.planCues) {
            return .plan
        }
        if containsAny(text, in: Self.brainstormCues) {
            return .brainstorm
        }
        if containsAny(text, in: Self.directionCues) {
            return .direction
        }
        return .ordinaryChat
    }

    private func containsAny(_ text: String, in cues: [String]) -> Bool {
        cues.contains { text.contains($0) }
    }

    private func analysisGateMatches(_ text: String) -> Bool {
        guard let skillStore else { return false }

        do {
            return try skillStore.fetchActiveSkills(userId: userId)
                .filter { $0.payload.trigger.kind == .analysisGate }
                .contains { skill in
                    containsAny(text, in: normalizedAnalysisCues(from: skill))
                }
        } catch {
            #if DEBUG
            print("[TurnSteward] analysis gate unavailable: \(error)")
            #endif
            return false
        }
    }

    private func normalizedAnalysisCues(from skill: Skill) -> [String] {
        skill.payload.trigger.cues
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func hasExplicitHardJudgeCue(_ text: String) -> Bool {
        containsAny(text, in: Self.hardJudgeCues) || analysisGateHardJudgeMatches(text)
    }

    private func analysisGateHardJudgeMatches(_ text: String) -> Bool {
        guard let skillStore else { return false }

        do {
            return try skillStore.fetchActiveSkills(userId: userId)
                .filter { $0.payload.trigger.kind == .analysisGate }
                .flatMap(normalizedAnalysisCues)
                .filter { Self.hardJudgeCues.contains($0) }
                .contains { text.contains($0) }
        } catch {
            #if DEBUG
            print("[TurnSteward] hard judge gate unavailable: \(error)")
            #endif
            return false
        }
    }

    private static let brainstormCues = [
        "brainstorm",
        "ideas",
        "发散",
        "發散",
        "諗 idea",
        "諗几个",
        "諗幾個",
        "想几个方向",
        "想幾個方向"
    ]

    private static let planCues = [
        "plan",
        "schedule",
        "roadmap",
        "计划",
        "計劃",
        "排",
        "今个星期",
        "今個星期",
        "this week"
    ]

    private static let directionCues = [
        "direction",
        "下一步",
        "next step",
        "点拣",
        "點揀",
        "怎么选",
        "怎麼選",
        "which path"
    ]

    private static let hardJudgeCues = [
        "反驳",
        "反駁",
        "call me out",
        "challenge me",
        "push back",
        "盲点",
        "盲點",
        "blind spot",
        "blind spots",
        "am i wrong",
        "我係咪错",
        "我係咪錯",
        "我系咪错",
        "我系咪錯",
        "我有冇错",
        "我有冇錯",
        "我有没有错",
        "我有沒有錯"
    ]

    private static let softAnalysisCues = [
        "分析",
        "深度分析",
        "analysis",
        "analyze",
        "判断",
        "判斷",
        "tradeoff",
        "trade-off",
        "权衡",
        "權衡"
    ]

    private static let reflectiveCues = [
        "点解",
        "點解",
        "why",
        "我发现",
        "我發現",
        "变咗",
        "變咗",
        "meaning",
        "代表咩",
        "意味着",
        "意味住"
    ]

    private static let ambiguousDecisionCues = [
        "应该",
        "應該",
        "要唔要",
        "值唔值",
        "should",
        "worth",
        "点做",
        "點做"
    ]

    private static let broadOpinionCues = [
        "你觉得",
        "你覺得",
        "点睇",
        "點睇",
        "what do you think"
    ]

    private static let memoryOptOutCues = [
        "fresh",
        "don't use memory",
        "dont use memory",
        "唔好参考",
        "唔好參考",
        "不要参考",
        "不要參考",
        "from scratch"
    ]

    private static let distressCues = [
        "好攰",
        "累",
        "顶唔顺",
        "頂唔順",
        "撑不住",
        "撐不住",
        "anxious",
        "焦虑",
        "焦慮",
        "panic",
        "紧张",
        "緊張",
        "崩"
    ]
}

private struct DeterministicStanceResult {
    let result: SpeechActRoutingResult
    let isTerminal: Bool
}

private struct SpeechActRoutingResult {
    let stance: ResponseStance
    let source: ResponseStanceRouterSource
    let confidence: Double?
    let softerFallback: ResponseStance?
    let fallbackUsed: Bool
    let reason: String

    func with(
        source: ResponseStanceRouterSource? = nil,
        confidence: Double? = nil,
        softerFallback: ResponseStance? = nil,
        fallbackUsed: Bool? = nil,
        reason: String? = nil
    ) -> SpeechActRoutingResult {
        SpeechActRoutingResult(
            stance: stance,
            source: source ?? self.source,
            confidence: confidence ?? self.confidence,
            softerFallback: softerFallback ?? self.softerFallback,
            fallbackUsed: fallbackUsed ?? self.fallbackUsed,
            reason: reason ?? self.reason
        )
    }
}

private extension TurnStewardDecision {
    func withRouterTrace(
        mode: ResponseStanceRouterMode,
        routing: SpeechActRoutingResult,
        traceJudgePolicy: JudgePolicy? = nil
    ) -> TurnStewardDecision {
        TurnStewardDecision(
            route: route,
            memoryPolicy: memoryPolicy,
            challengeStance: challengeStance,
            responseShape: responseShape,
            projectSignal: projectSignal,
            source: trace.source,
            reason: trace.reason,
            responseStance: routing.stance,
            judgePolicy: judgePolicy,
            traceJudgePolicy: traceJudgePolicy ?? routing.stance.judgePolicy,
            routerMode: mode,
            routerSource: routing.source,
            confidence: routing.confidence,
            softerFallback: routing.softerFallback,
            fallbackUsed: routing.fallbackUsed,
            routerReason: routing.reason
        )
    }
}

final class CloudSpeechActClassifier: SpeechActClassifying {
    private let llmService: any LLMService
    private let timeout: TimeInterval

    init(llmService: any LLMService, timeout: TimeInterval = 4.0) {
        self.llmService = llmService
        self.timeout = timeout
    }

    func classify(text: String) async throws -> SpeechActClassifierOutput {
        let raw = try await withStanceRouterTimeout(seconds: timeout) {
            let stream = try await self.llmService.generate(
                messages: [LLMMessage(role: "user", content: text)],
                system: Self.systemPrompt
            )
            return try await self.collect(stream)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StanceClassifierError.emptyOutput }
        let jsonString = ProvocationJudge.extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonString.data(using: .utf8) else { throw StanceClassifierError.badJSON }
        do {
            return try JSONDecoder().decode(SpeechActClassifierOutput.self, from: data)
        } catch {
            throw StanceClassifierError.badJSON
        }
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var output = ""
        for try await chunk in stream {
            output += chunk
        }
        return output
    }

    private static let systemPrompt = """
    You are Nous's tiny speech-act router. Classify what Alex is asking Nous to do, not the topic.
    Return only one JSON object:
    {
      "stance": "companion" | "reflective" | "supportFirst" | "softAnalysis" | "hardJudge",
      "confidence": 0.0,
      "softerFallback": "companion" | "reflective" | "supportFirst" | "softAnalysis",
      "reason": "short reason"
    }

    Rules:
    - Topic is context only. Music, football, shoes, school, code, and startup topics do not decide stance.
    - companion: casual sharing, taste talk, ordinary chat.
    - reflective: meaning-making, identity shift, "why am I like this".
    - supportFirst: distress, tiredness, panic, anxiety, overload. Never challenge first.
    - softAnalysis: decisions, tradeoffs, choosing what to do.
    - hardJudge: only explicit challenge language such as "反驳我", "call me out", "am I wrong", "blind spot", "盲点".
    - If unsure, choose the softer reasonable stance and lower confidence.
    """
}

private enum StanceClassifierError: Error {
    case emptyOutput
    case badJSON
}

private struct StanceRouterTimeoutError: Error {}

private func withStanceRouterTimeout<T>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw StanceRouterTimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
