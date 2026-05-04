import Foundation

enum QuickActionMode: String, CaseIterable, Codable, Sendable {
    case direction
    case brainstorm
    case plan

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
        }
    }

    static func isPlaceholderConversationTitle(_ title: String) -> Bool {
        placeholderConversationTitles.contains(
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}
