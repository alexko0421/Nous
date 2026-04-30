import Foundation

enum TurnInteractionPolicy {
    static func updatedQuickActionMode(
        currentMode: QuickActionMode?,
        assistantContent: String,
        turnIndex: Int
    ) -> QuickActionMode? {
        guard let currentMode else { return nil }
        let parsed = ClarificationCardParser.parse(assistantContent)
        let directive = currentMode.agent().turnDirective(parsed: parsed, turnIndex: turnIndex)
        return directive == .keepActive ? currentMode : nil
    }

    static func shouldAllowInteractiveClarification(
        activeQuickActionMode: QuickActionMode?,
        messages: [Message]
    ) -> Bool {
        guard let activeQuickActionMode else { return false }
        guard activeQuickActionMode == .plan else { return false }
        let userTurnCount = messages.lazy.filter { $0.role == .user }.count
        return userTurnCount <= 1
    }

    static func deriveProvocationKind(
        verdict: JudgeVerdict,
        contradictionCandidateIds: Set<String>
    ) -> ProvocationKind {
        guard verdict.shouldProvoke else { return .neutral }
        if let id = verdict.entryId, contradictionCandidateIds.contains(id) {
            return .contradiction
        }
        return .spark
    }
}
