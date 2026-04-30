import Foundation

final class QuickActionAddendumResolver {
    private let skillStore: (any SkillStoring)?
    private let skillMatcher: any SkillMatching
    private let skillTracker: (any SkillTracking)?
    private let userId: String

    init(
        skillStore: (any SkillStoring)? = nil,
        skillMatcher: any SkillMatching = SkillMatcher(),
        skillTracker: (any SkillTracking)? = nil,
        userId: String = "alex"
    ) {
        self.skillStore = skillStore
        self.skillMatcher = skillMatcher
        self.skillTracker = skillTracker
        self.userId = userId
    }

    func addendum(
        mode: QuickActionMode?,
        agent: (any QuickActionAgent)?,
        turnIndex: Int
    ) -> String? {
        let agentAddendum = agent?.contextAddendum(turnIndex: turnIndex)
        let skillAddendum = resolvedSkillAddendum(mode: mode, turnIndex: turnIndex)
        let text = [agentAddendum, skillAddendum]
            .compactMap { $0 }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func resolvedSkillAddendum(
        mode: QuickActionMode?,
        turnIndex: Int
    ) -> String? {
        #if DEBUG
        if DebugAblation.skipModeAddendum {
            SkillTraceLogger.logSkipped(
                mode: mode,
                turnIndex: turnIndex,
                reason: "DebugAblation.skipModeAddendum"
            )
            return nil
        }
        #endif

        guard let skillStore else { return nil }
        let active = (try? skillStore.fetchActiveSkills(userId: userId)) ?? []
        let matched = skillMatcher.matchingSkills(
            from: active,
            context: SkillMatchContext(mode: mode, turnIndex: turnIndex),
            cap: 5
        )

        #if DEBUG
        SkillTraceLogger.log(matched: matched, mode: mode, turnIndex: turnIndex)
        #endif

        guard !matched.isEmpty else { return nil }

        if let skillTracker {
            let skillIds = matched.map(\.id)
            Task.detached {
                try? await skillTracker.recordFire(skillIds: skillIds)
            }
        }

        return matched.map { $0.payload.action.content }.joined(separator: "\n\n")
    }
}
