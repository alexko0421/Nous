import Foundation

struct SkillMatchContext {
    let mode: QuickActionMode?
    let turnIndex: Int
}

protocol SkillMatching {
    func matchingSkills(
        from skills: [Skill],
        context: SkillMatchContext,
        cap: Int
    ) -> [Skill]
}

final class SkillMatcher: SkillMatching {
    func matchingSkills(
        from skills: [Skill],
        context: SkillMatchContext,
        cap: Int = 5
    ) -> [Skill] {
        guard let mode = context.mode else { return [] }

        return skills
            .filter { $0.state == .active }
            .filter { $0.payload.trigger.modes.contains(mode) }
            .filter { skill in
                if context.turnIndex == 0 && skill.payload.trigger.kind == .mode {
                    return false
                }
                return true
            }
            .sorted(by: Self.skillOrdering)
            .prefix(cap)
            .map { $0 }
    }

    private static func skillOrdering(_ lhs: Skill, _ rhs: Skill) -> Bool {
        let lhsPriority = lhs.payload.trigger.priority
        let rhsPriority = rhs.payload.trigger.priority
        if lhsPriority != rhsPriority {
            return lhsPriority > rhsPriority
        }

        let lhsName = lhs.payload.name
        let rhsName = rhs.payload.name
        if lhsName != rhsName {
            return lhsName < rhsName
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }
}

#if DEBUG
enum SkillTraceLogger {
    static func log(matched: [Skill], mode: QuickActionMode?, turnIndex: Int) {
        lines(matched: matched, mode: mode, turnIndex: turnIndex).forEach { print($0) }
    }

    static func logSkipped(mode: QuickActionMode?, turnIndex: Int, reason: String) {
        print("[SkillTrace] Turn \(turnIndex) (mode: \(modeLabel(mode))) skipped: \(reason)")
    }

    static func lines(matched: [Skill], mode: QuickActionMode?, turnIndex: Int) -> [String] {
        var output = ["[SkillTrace] Turn \(turnIndex) (mode: \(modeLabel(mode)))"]
        output.append("  Active skills (\(matched.count) fired):")
        output.append(
            contentsOf: matched.map { skill in
                let fired = skill.firedCount
                let suffix = fired == 1 ? "time" : "times"
                return "  - \(skill.payload.name) (priority \(skill.payload.trigger.priority), fired \(fired) \(suffix))"
            }
        )
        return output
    }

    private static func modeLabel(_ mode: QuickActionMode?) -> String {
        mode?.rawValue ?? "none"
    }
}
#endif
