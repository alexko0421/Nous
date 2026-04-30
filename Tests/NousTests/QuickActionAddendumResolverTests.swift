import XCTest
@testable import Nous

final class QuickActionAddendumResolverTests: XCTestCase {
    func testCombinesAgentAddendumWithMatchedSkillContent() {
        let skill = makeSkill(
            name: "direction-skill",
            mode: .direction,
            content: "Use one concrete next step."
        )
        let resolver = QuickActionAddendumResolver(
            skillStore: StubSkillStore(activeSkills: [skill]),
            skillMatcher: SkillMatcher(),
            skillTracker: nil
        )

        let addendum = resolver.addendum(
            mode: .direction,
            agent: StubAgent(mode: .direction, addendum: "Agent turn rule."),
            turnIndex: 1
        )

        XCTAssertEqual(addendum, "Agent turn rule.\n\nUse one concrete next step.")
    }

    func testReturnsNilWhenNoAgentAddendumAndNoSkillMatches() {
        let resolver = QuickActionAddendumResolver(
            skillStore: StubSkillStore(activeSkills: []),
            skillMatcher: SkillMatcher(),
            skillTracker: nil
        )

        let addendum = resolver.addendum(
            mode: .direction,
            agent: StubAgent(mode: .direction, addendum: nil),
            turnIndex: 1
        )

        XCTAssertNil(addendum)
    }

    private func makeSkill(
        id: UUID = UUID(),
        name: String,
        mode: QuickActionMode,
        content: String
    ) -> Skill {
        Skill(
            id: id,
            userId: "alex",
            payload: SkillPayload(
                payloadVersion: 1,
                name: name,
                source: .alex,
                trigger: SkillTrigger(kind: .always, modes: [mode], priority: 70),
                action: SkillAction(kind: .promptFragment, content: content)
            ),
            state: .active,
            firedCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastModifiedAt: Date(timeIntervalSince1970: 1_000),
            lastFiredAt: nil
        )
    }
}

private struct StubAgent: QuickActionAgent {
    let mode: QuickActionMode
    let addendum: String?

    func openingPrompt() -> String {
        "Opening"
    }

    func contextAddendum(turnIndex: Int) -> String? {
        addendum
    }

    func memoryPolicy() -> QuickActionMemoryPolicy {
        .lean
    }

    func turnDirective(
        parsed: ClarificationContent,
        turnIndex: Int
    ) -> QuickActionTurnDirective {
        .complete
    }
}

private final class StubSkillStore: SkillStoring {
    private let activeSkills: [Skill]

    init(activeSkills: [Skill]) {
        self.activeSkills = activeSkills
    }

    func fetchAllSkills(userId: String) throws -> [Skill] {
        activeSkills
    }

    func fetchActiveSkills(userId: String) throws -> [Skill] {
        activeSkills
    }

    func fetchSkill(id: UUID) throws -> Skill? {
        activeSkills.first { $0.id == id }
    }

    func insertSkill(_ skill: Skill) throws {}
    func updateSkill(_ skill: Skill) throws {}
    func setSkillState(id: UUID, state: SkillState) throws {}
    func incrementFiredCount(id: UUID, firedAt: Date) throws {}
}
