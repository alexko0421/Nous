import Foundation

final class TurnSteward {
    func steer(
        prepared: PreparedTurnSession,
        request: TurnRequest
    ) -> TurnStewardDecision {
        if let activeMode = request.snapshot.activeQuickActionMode {
            return decision(forActiveMode: activeMode)
        }

        let text = request.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased()

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
