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
