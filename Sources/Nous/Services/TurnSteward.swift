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
        let text = request.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased()
        let memoryOptOut = Self.hasMemoryOptOutCue(normalized)
        let hasSourceContext = !request.attachments.isEmpty || !request.sourceMaterials.isEmpty
        let distress = !Self.isTextTransformRequest(normalized)
            && containsAny(normalized, in: Self.distressCues)

        if let activeMode = request.snapshot.activeQuickActionMode {
            return decision(
                forActiveMode: activeMode,
                normalizedText: normalized,
                memoryOptOut: memoryOptOut,
                hasSourceContext: hasSourceContext,
                distress: distress,
                request: request
            )
        }

        if !request.sourceMaterials.isEmpty {
            let sourceMeaningSignal = reflectiveMeaningSignal(
                for: normalized,
                route: .sourceAnalysis,
                request: request,
                memoryOptOut: memoryOptOut,
                distress: distress,
                allowSourceAnalysis: true
            )
            if distress {
                return TurnStewardDecision(
                    route: .sourceAnalysis,
                    memoryPolicy: memoryOptOut ? .lean : .full,
                    challengeStance: .supportFirst,
                    responseShape: .answerNow,
                    source: .deterministic,
                    reason: memoryOptOut ? "source material distress with memory opt-out" : "source material distress cue",
                    responseStance: .supportFirst,
                    judgePolicy: .off,
                    latencyTier: .deep
                )
            }
            return TurnStewardDecision(
                route: .sourceAnalysis,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: .surfaceTension,
                responseShape: .answerNow,
                source: .deterministic,
                reason: memoryOptOut ? "source material attached with memory opt-out" : "source material attached",
                reflectiveMeaningSignal: sourceMeaningSignal,
                latencyTier: .deep
            )
        }

        let route = route(for: normalized)
        let meaningSignal = reflectiveMeaningSignal(
            for: normalized,
            route: route,
            request: request,
            memoryOptOut: memoryOptOut,
            distress: distress
        )
        let patternSignal = meaningSignal == nil
            ? inTurnPatternSignal(
                for: normalized,
                route: route,
                request: request,
                memoryOptOut: memoryOptOut,
                distress: distress
            )
            : nil

        if distress, route == .ordinaryChat {
            return TurnStewardDecision(
                route: .ordinaryChat,
                memoryPolicy: memoryOptOut ? .lean : .conversationOnly,
                challengeStance: .supportFirst,
                responseShape: .answerNow,
                source: .deterministic,
                reason: memoryOptOut ? "emotional distress with memory opt-out" : "emotional distress cue"
            )
        }

        if route == .ordinaryChat, !memoryOptOut, analysisGateMatches(normalized) {
            return TurnStewardDecision(
                route: .ordinaryChat,
                memoryPolicy: .full,
                challengeStance: .surfaceTension,
                responseShape: .answerNow,
                source: .deterministic,
                reason: "analysis skill cue",
                inTurnPatternSignal: patternSignal,
                reflectiveMeaningSignal: meaningSignal,
                latencyTier: .deep
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
                reason: memoryOptOut ? "explicit brainstorm with memory opt-out" : "explicit brainstorm cue",
                latencyTier: hasSourceContext || hasExplicitDeepLatencyCue(normalized) ? .deep : .normal
            )
        case .plan:
            return TurnStewardDecision(
                route: .plan,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: distress ? .supportFirst : .surfaceTension,
                responseShape: distress ? .answerNow : .producePlan,
                source: .deterministic,
                reason: "explicit plan cue",
                inTurnPatternSignal: patternSignal,
                reflectiveMeaningSignal: meaningSignal,
                latencyTier: .deep
            )
        case .direction:
            return TurnStewardDecision(
                route: .direction,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: distress ? .supportFirst : .surfaceTension,
                responseShape: distress ? .answerNow : .narrowNextStep,
                source: .deterministic,
                reason: "explicit direction cue",
                inTurnPatternSignal: patternSignal,
                reflectiveMeaningSignal: meaningSignal,
                latencyTier: .deep
            )
        case .sourceAnalysis:
            return TurnStewardDecision(
                route: .sourceAnalysis,
                memoryPolicy: .full,
                challengeStance: .surfaceTension,
                responseShape: .answerNow,
                source: .deterministic,
                reason: "source material attached",
                reflectiveMeaningSignal: meaningSignal,
                latencyTier: .deep
            )
        case .ordinaryChat:
            let latencyTier = latencyTier(
                for: request,
                text: text,
                normalized: normalized,
                route: route,
                memoryOptOut: memoryOptOut,
                distress: distress
            )
            return TurnStewardDecision(
                route: .ordinaryChat,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: distress ? .supportFirst : .useSilently,
                responseShape: .answerNow,
                source: .deterministic,
                reason: memoryOptOut ? "memory opt-out cue" : "ordinary chat default",
                inTurnPatternSignal: patternSignal,
                reflectiveMeaningSignal: meaningSignal,
                latencyTier: latencyTier
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
        if !Self.isTextTransformRequest(normalized),
           containsAny(normalized, in: Self.distressCues) {
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
        let memoryOptOut = Self.hasMemoryOptOutCue(normalizedText)

        switch routing.stance {
        case .supportFirst:
            let hasDeterministicDistress = containsAny(normalizedText, in: Self.distressCues)
            let preserveDistressRoute = legacy.challengeStance == .supportFirst
                || (hasDeterministicDistress && (legacy.route == .plan || legacy.route == .direction))
            return TurnStewardDecision(
                route: preserveDistressRoute ? legacy.route : .ordinaryChat,
                memoryPolicy: preserveDistressRoute ? legacy.memoryPolicy : (memoryOptOut ? .lean : .conversationOnly),
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
                routerReason: routing.reason,
                inTurnPatternSignal: nil,
                reflectiveMeaningSignal: nil,
                latencyTier: preserveDistressRoute ? legacy.latencyTier : .normal
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
                routerReason: routing.reason,
                inTurnPatternSignal: legacy.inTurnPatternSignal,
                reflectiveMeaningSignal: legacy.reflectiveMeaningSignal,
                latencyTier: legacy.latencyTier
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
                routerReason: routing.reason,
                inTurnPatternSignal: legacy.inTurnPatternSignal,
                reflectiveMeaningSignal: legacy.reflectiveMeaningSignal,
                latencyTier: .deep
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
                routerReason: routing.reason,
                inTurnPatternSignal: legacy.inTurnPatternSignal,
                reflectiveMeaningSignal: legacy.reflectiveMeaningSignal,
                latencyTier: .deep
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

    private func decision(
        forActiveMode mode: QuickActionMode,
        normalizedText: String,
        memoryOptOut: Bool,
        hasSourceContext: Bool,
        distress: Bool,
        request: TurnRequest
    ) -> TurnStewardDecision {
        if distress {
            return distressDecisionForActiveMode(
                mode,
                memoryOptOut: memoryOptOut,
                hasSourceContext: hasSourceContext
            )
        }

        switch mode {
        case .direction:
            let meaningSignal = reflectiveMeaningSignal(
                for: normalizedText,
                route: .direction,
                request: request,
                memoryOptOut: memoryOptOut,
                distress: distress
            )
            let patternSignal = meaningSignal == nil
                ? inTurnPatternSignal(
                    for: normalizedText,
                    route: .direction,
                    request: request,
                    memoryOptOut: memoryOptOut,
                    distress: distress
                )
                : nil
            return TurnStewardDecision(
                route: .direction,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: .surfaceTension,
                responseShape: .narrowNextStep,
                source: .deterministic,
                reason: memoryOptOut ? "active quick action mode with memory opt-out" : "active quick action mode",
                inTurnPatternSignal: patternSignal,
                reflectiveMeaningSignal: meaningSignal,
                latencyTier: .deep
            )
        case .brainstorm:
            return TurnStewardDecision(
                route: .brainstorm,
                memoryPolicy: .lean,
                challengeStance: .useSilently,
                responseShape: .listDirections,
                source: .deterministic,
                reason: memoryOptOut ? "active quick action mode with memory opt-out" : "active quick action mode",
                latencyTier: hasSourceContext || hasExplicitDeepLatencyCue(normalizedText) ? .deep : .normal
            )
        case .plan:
            let meaningSignal = reflectiveMeaningSignal(
                for: normalizedText,
                route: .plan,
                request: request,
                memoryOptOut: memoryOptOut,
                distress: distress
            )
            let patternSignal = meaningSignal == nil
                ? inTurnPatternSignal(
                    for: normalizedText,
                    route: .plan,
                    request: request,
                    memoryOptOut: memoryOptOut,
                    distress: distress
                )
                : nil
            return TurnStewardDecision(
                route: .plan,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: .surfaceTension,
                responseShape: .producePlan,
                source: .deterministic,
                reason: memoryOptOut ? "active quick action mode with memory opt-out" : "active quick action mode",
                inTurnPatternSignal: patternSignal,
                reflectiveMeaningSignal: meaningSignal,
                latencyTier: .deep
            )
        case .study:
            let meaningSignal = reflectiveMeaningSignal(
                for: normalizedText,
                route: .sourceAnalysis,
                request: request,
                memoryOptOut: memoryOptOut,
                distress: distress,
                allowSourceAnalysis: true
            )
            return TurnStewardDecision(
                route: .sourceAnalysis,
                memoryPolicy: memoryOptOut ? .lean : .full,
                challengeStance: .useSilently,
                responseShape: .answerNow,
                source: .deterministic,
                reason: memoryOptOut ? "active quick action mode with memory opt-out" : "active quick action mode",
                judgePolicy: .off,
                reflectiveMeaningSignal: meaningSignal,
                latencyTier: .deep
            )
        }
    }

    private func distressDecisionForActiveMode(
        _ mode: QuickActionMode,
        memoryOptOut: Bool,
        hasSourceContext: Bool
    ) -> TurnStewardDecision {
        let memoryPolicy: TurnMemoryPolicyPreset = memoryOptOut ? .lean : .full
        let reason = memoryOptOut
            ? "active quick action distress with memory opt-out"
            : "active quick action distress cue"

        switch mode {
        case .direction:
            return TurnStewardDecision(
                route: .direction,
                memoryPolicy: memoryPolicy,
                challengeStance: .supportFirst,
                responseShape: .answerNow,
                source: .deterministic,
                reason: reason,
                responseStance: .supportFirst,
                judgePolicy: .off,
                latencyTier: .deep
            )
        case .plan:
            return TurnStewardDecision(
                route: .plan,
                memoryPolicy: memoryPolicy,
                challengeStance: .supportFirst,
                responseShape: .answerNow,
                source: .deterministic,
                reason: reason,
                responseStance: .supportFirst,
                judgePolicy: .off,
                latencyTier: .deep
            )
        case .study where hasSourceContext:
            return TurnStewardDecision(
                route: .sourceAnalysis,
                memoryPolicy: memoryPolicy,
                challengeStance: .supportFirst,
                responseShape: .answerNow,
                source: .deterministic,
                reason: reason,
                responseStance: .supportFirst,
                judgePolicy: .off,
                latencyTier: .deep
            )
        case .brainstorm, .study:
            return TurnStewardDecision(
                route: .ordinaryChat,
                memoryPolicy: memoryOptOut ? .lean : .conversationOnly,
                challengeStance: .supportFirst,
                responseShape: .answerNow,
                source: .deterministic,
                reason: reason,
                responseStance: .supportFirst,
                judgePolicy: .off,
                latencyTier: .normal
            )
        }
    }

    private func inTurnPatternSignal(
        for normalized: String,
        route: TurnRoute,
        request: TurnRequest,
        memoryOptOut: Bool,
        distress: Bool
    ) -> InTurnPatternSignal? {
        guard route == .ordinaryChat || route == .direction || route == .plan else {
            return nil
        }
        guard request.sourceMaterials.isEmpty,
              request.attachments.isEmpty,
              !memoryOptOut,
              !distress,
              !Self.isTextTransformRequest(normalized),
              !containsAny(normalized, in: Self.patternSafetyBypassCues)
        else {
            return nil
        }

        let candidates = [
            comparisonLoopCandidate(normalized),
            identityPressureCandidate(normalized),
            learningInsteadOfShippingCandidate(normalized),
            notReadyRationalizationCandidate(normalized),
            bigSystemEscapeCandidate(normalized),
            planningAsAvoidanceCandidate(normalized),
            externalJudgmentSensitivityCandidate(normalized),
            overTrustingSystemCandidate(normalized)
        ].compactMap { $0 }

        guard let candidate = candidates.first(where: { $0.confidence >= Self.patternConfidenceThreshold }) else {
            return nil
        }
        return InTurnPatternSignal(
            kind: candidate.kind,
            confidence: candidate.confidence,
            surfacePolicy: candidate.confidence >= Self.directPatternConfidenceThreshold ? .directName : .softName,
            reasonCode: candidate.reasonCode
        )
    }

    private func reflectiveMeaningSignal(
        for normalized: String,
        route: TurnRoute,
        request: TurnRequest,
        memoryOptOut: Bool,
        distress: Bool,
        allowSourceAnalysis: Bool = false
    ) -> ReflectiveMeaningSignal? {
        let sourceEligible = route == .sourceAnalysis
            && allowSourceAnalysis
            && !request.sourceMaterials.isEmpty
        let ordinaryEligible = route == .ordinaryChat || route == .direction || route == .plan
        guard sourceEligible || ordinaryEligible else {
            return nil
        }
        guard !memoryOptOut,
              !distress,
              !Self.isTextTransformRequest(normalized),
              !containsAny(normalized, in: Self.patternSafetyBypassCues)
        else {
            return nil
        }
        if ordinaryEligible,
           !request.sourceMaterials.isEmpty {
            return nil
        }
        guard hasSelfReference(normalized) else {
            return nil
        }

        let hasMeaningIntent = hasReflectiveMeaningIntent(normalized)
        let hasRegretIntent = hasRegretMeaningAnalysis(normalized)
        guard hasMeaningIntent || hasRegretIntent else {
            return nil
        }

        let surfacePolicy: ReflectiveMeaningSurfacePolicy = containsAny(
            normalized,
            in: Self.reflectiveMeaningLayeredCues
        ) ? .layered : .compact
        let reasonCode: String
        if sourceEligible {
            reasonCode = "source_personal_meaning_request"
        } else if hasRegretIntent {
            reasonCode = "regret_meaning_request"
        } else if surfacePolicy == .layered {
            reasonCode = "reflective_meaning_layered_request"
        } else {
            reasonCode = "reflective_meaning_request"
        }

        return ReflectiveMeaningSignal(
            confidence: Self.reflectiveMeaningConfidence,
            surfacePolicy: surfacePolicy,
            reasonCode: reasonCode
        )
    }

    private func hasReflectiveMeaningIntent(_ text: String) -> Bool {
        containsAny(text, in: Self.reflectiveMeaningIntentCues)
            || (
                containsAny(text, in: Self.reflectiveMeaningClarityCues)
                    && containsAny(text, in: Self.reflectiveMeaningQuestionCues)
            )
    }

    private func hasRegretMeaningAnalysis(_ text: String) -> Bool {
        containsAny(text, in: Self.reflectiveMeaningRegretCues)
            && containsAny(text, in: Self.reflectiveMeaningAnalysisCues)
    }

    private func comparisonLoopCandidate(_ text: String) -> PatternCandidate? {
        guard hasSelfReference(text) else { return nil }
        let comparisonSignal = containsAnyPatternCue(text, in: Self.comparisonLoopCues)
        let statusSignal = containsAnyPatternCue(text, in: Self.comparisonStatusCues)
        guard comparisonSignal && statusSignal else { return nil }
        return PatternCandidate(kind: .comparisonLoop, confidence: 0.90, reasonCode: "comparison_status_progress")
    }

    private func identityPressureCandidate(_ text: String) -> PatternCandidate? {
        guard hasSelfReference(text),
              containsAnyPatternCue(text, in: Self.identityConstraintCues),
              containsAnyPatternCue(text, in: Self.identityJudgmentCues) else {
            return nil
        }
        return PatternCandidate(kind: .identityPressure, confidence: 0.88, reasonCode: "identity_constraint_judgment")
    }

    private func learningInsteadOfShippingCandidate(_ text: String) -> PatternCandidate? {
        guard containsAnyPatternCue(text, in: Self.learningDelayCues),
              containsAnyPatternCue(text, in: Self.shippingEvidenceCues) else {
            return nil
        }
        return PatternCandidate(kind: .learningInsteadOfShipping, confidence: 0.88, reasonCode: "learning_shipping_delay")
    }

    private func externalJudgmentSensitivityCandidate(_ text: String) -> PatternCandidate? {
        guard hasSelfReference(text),
              containsAnyPatternCue(text, in: Self.externalJudgmentCues) else {
            return nil
        }
        let hasProductTruthCue = containsAnyPatternCue(text, in: Self.productTruthCues)
        let hasSelfPresentationCue = containsAnyPatternCue(text, in: Self.externalJudgmentSelfPresentationCues)
        guard hasProductTruthCue || hasSelfPresentationCue else {
            return nil
        }
        let reasonCode = hasProductTruthCue
            ? "external_judgment_over_product_truth"
            : "external_judgment_self_presentation"
        return PatternCandidate(kind: .externalJudgmentSensitivity, confidence: 0.88, reasonCode: reasonCode)
    }

    private func notReadyRationalizationCandidate(_ text: String) -> PatternCandidate? {
        guard hasSelfReference(text),
              containsAnyPatternCue(text, in: Self.notReadyDelayCues),
              containsAnyPatternCue(text, in: Self.shippableReadinessCues) else {
            return nil
        }
        return PatternCandidate(kind: .notReadyRationalization, confidence: 0.87, reasonCode: "not_ready_delay_with_shippable_slice")
    }

    private func bigSystemEscapeCandidate(_ text: String) -> PatternCandidate? {
        guard containsAnyPatternCue(text, in: Self.bigSystemExpansionCues),
              containsAnyPatternCue(text, in: Self.exposedStepCues) else {
            return nil
        }
        return PatternCandidate(kind: .bigSystemEscape, confidence: 0.88, reasonCode: "big_system_before_exposed_step")
    }

    private func planningAsAvoidanceCandidate(_ text: String) -> PatternCandidate? {
        guard containsAnyPatternCue(text, in: Self.planningExpansionCues),
              containsAnyPatternCue(text, in: Self.availableActionCues) else {
            return nil
        }
        return PatternCandidate(kind: .planningAsAvoidance, confidence: 0.86, reasonCode: "planning_before_action")
    }

    private func overTrustingSystemCandidate(_ text: String) -> PatternCandidate? {
        guard containsAnyPatternCue(text, in: Self.systemDeferenceCues),
              containsAnyPatternCue(text, in: Self.ownEvidenceCues) else {
            return nil
        }
        return PatternCandidate(kind: .overTrustingSystem, confidence: 0.88, reasonCode: "over_trusting_system")
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

    private func latencyTier(
        for request: TurnRequest,
        text: String,
        normalized: String,
        route: TurnRoute,
        memoryOptOut: Bool,
        distress: Bool
    ) -> TurnLatencyTier {
        guard route == .ordinaryChat,
              request.snapshot.activeQuickActionMode == nil
        else {
            return .normal
        }

        if !request.attachments.isEmpty || !request.sourceMaterials.isEmpty {
            return .deep
        }

        if distress {
            return .normal
        }

        if hasExplicitDeepLatencyCue(normalized)
            || containsAny(normalized, in: Self.ambiguousDecisionCues)
            || containsAny(normalized, in: Self.broadOpinionCues)
            || containsAny(normalized, in: Self.memoryRecallCues)
            || containsAny(normalized, in: Self.contextDependentCues) {
            return .deep
        }

        if memoryOptOut {
            return .normal
        }

        guard (1...160).contains(text.count),
              isExplicitFastUtilityRequest(normalized)
        else {
            return .normal
        }
        return .fast
    }

    private func hasExplicitDeepLatencyCue(_ normalized: String) -> Bool {
        hasExplicitHardJudgeCue(normalized)
            || containsAny(normalized, in: Self.deepAnalysisCues)
            || containsAny(normalized, in: Self.softAnalysisCues)
    }

    private func isExplicitFastUtilityRequest(_ normalized: String) -> Bool {
        if normalized == "ping" {
            return true
        }
        if Self.isTextTransformRequest(normalized) {
            return true
        }
        if normalized.hasPrefix("define ") {
            return true
        }
        if normalized.range(
            of: #"^what does [a-z0-9][a-z0-9 ._/\-]{1,80} mean\??$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return containsAny(normalized, in: Self.fastMeaningCues)
    }

    private func containsAny(_ text: String, in cues: [String]) -> Bool {
        cues.contains { text.contains($0) }
    }

    private func containsAnyPatternCue(_ text: String, in cues: [String]) -> Bool {
        cues.contains { patternCue($0, matches: text) }
    }

    private func patternCue(_ cue: String, matches text: String) -> Bool {
        let cue = cue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cue.isEmpty else { return false }
        guard Self.isBareASCIIToken(cue) else {
            return text.contains(cue)
        }

        let escapedCue = NSRegularExpression.escapedPattern(for: cue)
        return text.range(
            of: "(?<![A-Za-z0-9])\(escapedCue)(?![A-Za-z0-9])",
            options: .regularExpression
        ) != nil
    }

    private func hasSelfReference(_ text: String) -> Bool {
        if text.contains("我") || text.contains("自己") {
            return true
        }
        return text.range(
            of: #"(?<![A-Za-z0-9])(i|me|my|mine|myself)(?![A-Za-z0-9])"#,
            options: .regularExpression
        ) != nil
    }

    private static func isBareASCIIToken(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
        }
    }

    static func hasMemoryOptOutCue(_ normalizedText: String) -> Bool {
        memoryOptOutCues.contains { cue in
            let cue = cue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cue.isEmpty else { return false }
            guard Self.isBareASCIIToken(cue) else {
                return normalizedText.contains(cue)
            }

            let escapedCue = NSRegularExpression.escapedPattern(for: cue)
            return normalizedText.range(
                of: "(?<![A-Za-z0-9])\(escapedCue)(?![A-Za-z0-9])",
                options: .regularExpression
            ) != nil
        }
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

    private static let deepAnalysisCues = [
        "深度",
        "深入",
        "认真拆",
        "認真拆",
        "仔细拆",
        "仔細拆",
        "deep analysis",
        "deep reasoning",
        "think deeply",
        "seriously unpack"
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
        "崩",
        "想死",
        "唔想活",
        "不想活",
        "轻生",
        "輕生",
        "结束生命",
        "結束生命",
        "end my life",
        "don't want to live",
        "dont want to live"
    ]

    private static let memoryRecallCues = [
        "你记得",
        "你記得",
        "记得",
        "記得",
        "上次",
        "last time",
        "remember",
        "memory"
    ]

    private static let contextDependentCues = [
        "继续",
        "繼續",
        "接住",
        "上面",
        "前面",
        "之前",
        "刚才",
        "剛才",
        "啱先",
        "呢个",
        "呢個",
        "这个",
        "這個",
        "what does this mean",
        "what does that mean",
        "what is this",
        "what is that",
        "this one",
        "that one",
        "above",
        "previous"
    ]

    private static let textTransformCues = [
        "翻译",
        "翻譯",
        "translate",
        "改短",
        "shorten",
        "rewrite",
        "润色",
        "潤色",
        "polish"
    ]

    private static let fastMeaningCues = [
        "咩意思",
        "什么意思",
        "什麼意思",
        "甚麼意思"
    ]

    private static let patternConfidenceThreshold = 0.75
    private static let directPatternConfidenceThreshold = 0.85
    private static let reflectiveMeaningConfidence = 0.86

    private static let reflectiveMeaningIntentCues = [
        "点解我咁在意",
        "點解我咁在意",
        "点解我会咁在意",
        "點解我會咁在意",
        "为什么我这么在意",
        "為什麼我這麼在意",
        "真正牵住",
        "真正牽住",
        "真正牵动",
        "真正牽動",
        "真正代表",
        "真正係咩",
        "真正系咩",
        "咁有感觉",
        "咁有感覺",
        "这么有感觉",
        "這麼有感覺",
        "会让我这么在意",
        "會讓我這麼在意",
        "why did this matter",
        "why did it matter",
        "why do i care",
        "why did missing",
        "matter so much to me",
        "what did this mean to me",
        "meaning behind this for me"
    ]

    private static let reflectiveMeaningClarityCues = [
        "帮我睇清楚",
        "幫我睇清楚",
        "帮我看清楚",
        "幫我看清楚",
        "复盘",
        "復盤"
    ]

    private static let reflectiveMeaningQuestionCues = [
        "点解",
        "點解",
        "为什么",
        "為什麼",
        "在意",
        "真正",
        "牵住",
        "牽住",
        "牵动",
        "牽動",
        "代表",
        "感觉",
        "感覺",
        "matter",
        "mean to me",
        "why"
    ]

    private static let reflectiveMeaningRegretCues = [
        "后悔",
        "後悔",
        "错过",
        "錯過",
        "missed",
        "missing",
        "regret",
        "missed opportunity"
    ]

    private static let reflectiveMeaningAnalysisCues = [
        "分析",
        "睇清楚",
        "看清楚",
        "复盘",
        "復盤",
        "点解",
        "點解",
        "为什么",
        "為什麼",
        "why",
        "真正",
        "understand"
    ]

    private static let reflectiveMeaningLayeredCues = [
        "分析清楚啲",
        "分析清楚d",
        "分析清楚",
        "分析得再清楚",
        "分析再清楚",
        "睇清楚啲",
        "睇清楚d",
        "看清楚一点",
        "看清楚一點",
        "更清楚",
        "deeper",
        "break down"
    ]

    private static let patternSafetyBypassCues = [
        "self-harm",
        "suicide",
        "kill myself",
        "end my life",
        "don't want to live",
        "dont want to live",
        "hurt myself",
        "伤害自己",
        "傷害自己",
        "自杀",
        "自殺",
        "想死",
        "唔想活",
        "不想活",
        "轻生",
        "輕生",
        "结束生命",
        "結束生命",
        "安唔安全",
        "不安全",
        "diagnose",
        "diagnosis",
        "诊断",
        "診斷",
        "depression",
        "medication",
        "treatment",
        "食药",
        "食藥",
        "药",
        "藥",
        "psychosis",
        "eating disorder",
        "substance"
    ]

    private static let comparisonLoopCues = [
        "compare",
        "comparing",
        "comparison",
        "其他人",
        "别人",
        "別人",
        "同龄",
        "同齡",
        "everyone seems ahead",
        "they are ahead",
        "others are ahead",
        "other people are ahead",
        "peer",
        "peers",
        "落后",
        "落後",
        "慢好多",
        "量自己"
    ]

    private static let comparisonStatusCues = [
        "school",
        "学校",
        "學校",
        "usc",
        "berkeley",
        "credentials",
        "founder",
        "founders",
        "progress",
        "进度",
        "進度",
        "shipping",
        "够唔够格",
        "夠唔夠格",
        "够格",
        "夠格"
    ]

    private static let identityConstraintCues = [
        "f-1",
        "visa",
        "school",
        "smc",
        "学校",
        "學校",
        "大学",
        "大學",
        "英文",
        "english",
        "技术",
        "技術",
        "technical",
        "成绩",
        "成績",
        "19",
        "age",
        "身份"
    ]

    private static let identityJudgmentCues = [
        "legitimate",
        "legitimacy",
        "real enough",
        "真正 founder",
        "唔似一个真正",
        "唔似一個真正",
        "够格",
        "夠格",
        "证明",
        "證明",
        "not real",
        "唔配",
        "不配",
        "蚀底",
        "蝕底",
        "差学生",
        "差學生",
        "好失败",
        "好失敗",
        "羞耻",
        "羞恥"
    ]

    private static let learningDelayCues = [
        "research",
        "研究",
        "pdf",
        "pdfs",
        "docs",
        "model docs",
        "realtime docs",
        "read a few more",
        "provider comparison"
    ]

    private static let shippingEvidenceCues = [
        "shipping",
        "ship",
        "prototype",
        "slice",
        "shippable",
        "交付",
        "已經清楚",
        "已经清楚",
        "之后先决定",
        "之後先決定",
        "before shipping"
    ]

    private static let externalJudgmentCues = [
        "别人觉得",
        "別人覺得",
        "别人点睇",
        "別人點睇",
        "人哋觉得",
        "人哋覺得",
        "人哋点睇",
        "人哋點睇",
        "what people on twitter will think",
        "what people think",
        "twitter will think",
        "audience will think",
        "look stupid",
        "not impressive",
        "唔够高级",
        "唔夠高級",
        "不够高级",
        "不夠高級"
    ]

    private static let externalJudgmentSelfPresentationCues = [
        "无所事事",
        "無所事事",
        "不务正业",
        "不務正業",
        "唔务正业",
        "唔務正業",
        "wasting time",
        "not doing real work"
    ]

    private static let productTruthCues = [
        "user pain",
        "product truth",
        "observable signal",
        "real signal",
        "live evidence",
        "用户反应",
        "用戶反應",
        "用户痛点",
        "用戶痛點",
        "真实反应",
        "真實反應",
        "真实 evidence",
        "真實 evidence"
    ]

    private static let notReadyDelayCues = [
        "not ready",
        "not-ready",
        "未准备好",
        "未準備好",
        "唔 ready",
        "未 ready",
        "等到 ready",
        "ready 先",
        "准备好先",
        "準備好先"
    ]

    private static let shippableReadinessCues = [
        "shipping",
        "ship",
        "prototype",
        "smallest",
        "minimum",
        "最小版本",
        "最小 slice",
        "small slice",
        "可以发出去",
        "可以發出去",
        "发出去",
        "發出去"
    ]

    private static let bigSystemExpansionCues = [
        "whole system",
        "complete system",
        "grand system",
        "full platform",
        "whole operating system",
        "memory operating system",
        "build the whole system",
        "完整 system",
        "完整系统",
        "完整系統",
        "完整 memory operating system"
    ]

    private static let exposedStepCues = [
        "exposed next step",
        "smallest next step",
        "rough slice",
        "show the rough slice",
        "small slice",
        "small step",
        "first real move",
        "今日测试",
        "今日測試",
        "今日 test"
    ]

    private static let planningExpansionCues = [
        "whole architecture",
        "full framework",
        "system design",
        "完整 roadmap",
        "whole operating system",
        "redesign the whole",
        "replace the small step with architecture"
    ]

    private static let availableActionCues = [
        "before shipping",
        "before doing",
        "小 demo",
        "demo",
        "30-minute",
        "30 分钟",
        "30 分鐘",
        "exposed next step",
        "small slice",
        "今日做",
        "先排",
        "又想先"
    ]

    private static let systemDeferenceCues = [
        "你直接帮我决定",
        "你直接幫我決定",
        "替我定案",
        "tell me the product decision",
        "choose for me",
        "帮我定案",
        "幫我定案"
    ]

    private static let ownEvidenceCues = [
        "live evidence",
        "product taste",
        "用户反应",
        "用戶反應",
        "已经见到",
        "已經見到",
        "already know",
        "已经知道",
        "已經知道",
        "我其实已经知道",
        "我其實已經知道"
    ]

    private static func isTextTransformRequest(_ normalized: String) -> Bool {
        textTransformCues.contains { normalized.contains($0) }
    }
}

private struct PatternCandidate {
    let kind: InTurnPatternKind
    let confidence: Double
    let reasonCode: String
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
            routerReason: routing.reason,
            inTurnPatternSignal: inTurnPatternSignal,
            reflectiveMeaningSignal: reflectiveMeaningSignal,
            latencyTier: latencyTier
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
