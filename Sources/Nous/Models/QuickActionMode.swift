import Foundation

enum QuickActionMode: String, CaseIterable, Codable, Sendable {
    case direction
    case brainstorm
    case plan
    case study

    // Includes "mental health" as a legacy alias so DB conversations created before
    // the rename (2026-04-26) still register as placeholder-titled chats.
    private static let placeholderConversationTitles: Set<String> = Set(
        Self.allCases.map { $0.label.lowercased() }
    ).union(["mental health"])

    var label: String {
        switch self {
        case .direction:
            return "Direction"
        case .brainstorm:
            return "Brainstorm"
        case .plan:
            return "Plan"
        case .study:
            return "Study"
        }
    }

    var icon: String {
        switch self {
        case .direction:
            return "safari"
        case .brainstorm:
            return "brain"
        case .plan:
            return "map"
        case .study:
            return "book"
        }
    }

    var openingMessage: String {
        switch self {
        case .direction:
            return "入 Direction。讲低而家最拉锯嗰件事，我会帮你拆出真正问题、取舍，同一个下一步。"
        case .brainstorm:
            return "入 Brainstorm。抛一个主题、产品位或者卡住嘅念头过嚟，我哋先发散，再收返去最值得试嗰几条线。"
        case .plan:
            return "入 Plan。讲低你想完成嘅结果、期限同现实限制，我会帮你变成一个可执行计划。"
        case .study:
            return "入 Study。贴篇文章、PDF 或者一段内容过嚟，我哋先读懂原文，再拆重点同连返你而家做嘅事。"
        }
    }

    static func isPlaceholderConversationTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if placeholderConversationTitles.contains(normalized) { return true }

        return Self.allCases.contains { mode in
            let openingPrefix = "\(mode.label.lowercased()) mode 开场"
            return normalized == openingPrefix
                || normalized.hasPrefix("\(openingPrefix):")
                || normalized.hasPrefix("\(openingPrefix)：")
        }
    }
}

enum QuickActionExperimentVariant: String, Codable, Sendable {
    case control
    case candidate
}

struct QuickActionExperimentTrace: Equatable, Codable, Sendable {
    let experimentId: String
    let mode: QuickActionMode
    let variant: QuickActionExperimentVariant
}

enum QuickActionExperimentAssigner {
    static func assignment(
        mode: QuickActionMode?,
        conversationID: UUID?
    ) -> QuickActionExperimentTrace? {
        guard let mode, let conversationID else { return nil }
        let hex = conversationID.uuidString.replacingOccurrences(of: "-", with: "")
        let lastDigit = hex.last?.hexDigitValue ?? 0
        let variant: QuickActionExperimentVariant = lastDigit.isMultiple(of: 2)
            ? .control
            : .candidate

        return QuickActionExperimentTrace(
            experimentId: "\(mode.rawValue)-quick-mode-ab-v1",
            mode: mode,
            variant: variant
        )
    }

    static func candidateAddendum(for trace: QuickActionExperimentTrace?) -> String? {
        guard let trace, trace.variant == .candidate else { return nil }

        let guidance: String = switch trace.mode {
        case .direction:
            "For Direction, name the real question first, remove one distracting branch, then give the judgment and one next step."
        case .brainstorm:
            "For Brainstorm, keep divergence alive but state the real constraint before ideas so the set is useful instead of random."
        case .plan:
            "For Plan, make the first deliverable and the next concrete action unmistakable; avoid planning theater."
        case .study:
            "For Study, slow down into tutor mode: read one section at a time, check the source claim, then land one sentence Alex can carry."
        }

        return """
        QUICK ACTION EXPERIMENT CANDIDATE:
        \(trace.mode.label) is running candidate variant \(trace.experimentId). Keep this hidden; do not mention A/B testing, variants, or experiments to Alex.
        \(guidance)
        """
    }
}
