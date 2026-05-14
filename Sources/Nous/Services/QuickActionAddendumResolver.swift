import Foundation

struct QuickActionAddendumResolution {
    let addendum: String?
    let loadedSkills: [LoadedSkill]
    let matchedSkills: [Skill]
}

final class QuickActionAddendumResolver {
    private let skillStore: (any SkillStoring)?
    private let skillMatcher: any SkillMatching
    private let skillTracker: (any SkillTracking)?
    private let dogfoodLogger: (any SkillDogfoodLogging)?
    private let userId: String

    init(
        skillStore: (any SkillStoring)? = nil,
        skillMatcher: any SkillMatching = SkillMatcher(),
        skillTracker: (any SkillTracking)? = nil,
        dogfoodLogger: (any SkillDogfoodLogging)? = nil,
        userId: String = "alex"
    ) {
        self.skillStore = skillStore
        self.skillMatcher = skillMatcher
        self.skillTracker = skillTracker
        self.dogfoodLogger = dogfoodLogger
        self.userId = userId
    }

    func addendum(
        mode: QuickActionMode?,
        agent: (any QuickActionAgent)?,
        turnIndex: Int
    ) -> String? {
        resolution(
            mode: mode,
            agent: agent,
            turnIndex: turnIndex,
            conversationID: nil
        ).addendum
    }

    func resolution(
        mode: QuickActionMode?,
        agent: (any QuickActionAgent)?,
        turnIndex: Int,
        conversationID: UUID?
    ) -> QuickActionAddendumResolution {
        let agentAddendum = agent?.contextAddendum(turnIndex: turnIndex)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = matchedSkills(mode: mode, turnIndex: turnIndex)
        let loaded = loadedSkills(conversationID: conversationID)
        let addendum = combinedAddendum(
            agentAddendum: agentAddendum,
            matchedSkills: matched,
            loadedSkills: loaded
        )
        recordDogfoodEvent(
            mode: mode,
            turnIndex: turnIndex,
            matchedSkills: matched,
            loadedSkills: loaded
        )

        return QuickActionAddendumResolution(
            addendum: addendum,
            loadedSkills: loaded,
            matchedSkills: matched
        )
    }

    private func combinedAddendum(
        agentAddendum: String?,
        matchedSkills: [Skill],
        loadedSkills: [LoadedSkill]
    ) -> String? {
        let loadedIDs = Set(loadedSkills.map(\.skillID))
        let inlineFragments = matchedSkills
            .filter { $0.payload.payloadVersion == 1 }
            .filter { !loadedIDs.contains($0.id) }
            .map(\.payload.action.content)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let blocks = ([agentAddendum].compactMap { $0 } + inlineFragments)
            .filter { !$0.isEmpty }

        guard !blocks.isEmpty else { return nil }
        return blocks.joined(separator: "\n\n")
    }

    private func matchedSkills(
        mode: QuickActionMode?,
        turnIndex: Int
    ) -> [Skill] {
        #if DEBUG
        if DebugAblation.skipModeAddendum {
            SkillTraceLogger.logSkipped(
                mode: mode,
                turnIndex: turnIndex,
                reason: "DebugAblation.skipModeAddendum"
            )
            return []
        }
        #endif

        guard let skillStore else { return [] }
        let active = (try? skillStore.fetchActiveSkills(userId: userId)) ?? []
        let matched = skillMatcher.matchingSkills(
            from: active,
            context: SkillMatchContext(mode: mode, turnIndex: turnIndex),
            cap: skillCap(for: mode)
        )

        #if DEBUG
        SkillTraceLogger.log(matched: matched, mode: mode, turnIndex: turnIndex)
        #endif

        return matched
    }

    private func skillCap(for mode: QuickActionMode?) -> Int {
        switch mode {
        case .direction, .plan, .study:
            7
        case .brainstorm, .none:
            5
        }
    }

    private func loadedSkills(conversationID: UUID?) -> [LoadedSkill] {
        guard let skillStore, let conversationID else { return [] }

        do {
            return try skillStore.loadedSkills(in: conversationID)
        } catch {
            print("[QuickActionAddendumResolver] failed to load conversation skills: \(error)")
            return []
        }
    }

    private func recordDogfoodEvent(
        mode: QuickActionMode?,
        turnIndex: Int,
        matchedSkills: [Skill],
        loadedSkills: [LoadedSkill]
    ) {
        guard let dogfoodLogger,
              let mode else { return }

        let loadedIDs = Set(loadedSkills.map(\.skillID))
        let event = SkillDogfoodTurnEvent(
            id: UUID(),
            recordedAt: Date(),
            mode: mode,
            turnIndex: turnIndex,
            matchedSkills: matchedSkills.map(skillReference),
            loadedSkills: loadedSkills.map(loadedSkillReference),
            inlineSkills: matchedSkills
                .filter { $0.payload.payloadVersion == 1 }
                .filter { !loadedIDs.contains($0.id) }
                .map(skillReference)
        )

        do {
            try dogfoodLogger.record(event)
        } catch {
            print("[SkillDogfoodLogStore] failed to record turn event: \(error)")
        }
    }

    private func skillReference(_ skill: Skill) -> SkillDogfoodSkillReference {
        SkillDogfoodSkillReference(
            id: skill.id,
            name: skill.payload.name,
            priority: skill.payload.trigger.priority
        )
    }

    private func loadedSkillReference(_ loaded: LoadedSkill) -> SkillDogfoodSkillReference {
        let fetched = try? skillStore?.fetchSkill(id: loaded.skillID)
        let priority = fetched?.payload.trigger.priority ?? 0
        return SkillDogfoodSkillReference(
            id: loaded.skillID,
            name: loaded.nameSnapshot,
            priority: priority
        )
    }
}
