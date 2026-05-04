import Foundation

struct OperatingContext: Equatable, Codable {
    var identity: String
    var currentWork: String
    var communicationStyle: String
    var boundaries: String
    var updatedAt: Date

    init(
        identity: String = "",
        currentWork: String = "",
        communicationStyle: String = "",
        boundaries: String = "",
        updatedAt: Date = Date()
    ) {
        self.identity = identity
        self.currentWork = currentWork
        self.communicationStyle = communicationStyle
        self.boundaries = boundaries
        self.updatedAt = updatedAt
    }

    var isEmpty: Bool {
        identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        currentWork.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        communicationStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        boundaries.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func normalized(updatedAt: Date? = nil) -> OperatingContext {
        OperatingContext(
            identity: Self.trimmed(identity),
            currentWork: Self.trimmed(currentWork),
            communicationStyle: Self.trimmed(communicationStyle),
            boundaries: Self.trimmed(boundaries),
            updatedAt: updatedAt ?? self.updatedAt
        )
    }

    func promptBlock() -> String? {
        let context = normalized()
        guard !context.isEmpty else { return nil }

        var sections = [
            "USER-AUTHORED OPERATING CONTEXT:",
            "This is Alex's manually written global profile. Treat Identity, Current Work / Goals, and Communication Style as strong guidance. Treat Hard Boundaries as hard constraints. If this conflicts with learned memory, surface the tension instead of silently rewriting either source."
        ]

        if let identity = Self.section(title: "Identity", text: context.identity) {
            sections.append(identity)
        }
        if let currentWork = Self.section(title: "Current Work / Goals", text: context.currentWork) {
            sections.append(currentWork)
        }
        if let style = Self.section(title: "Communication Style", text: context.communicationStyle) {
            sections.append(style)
        }
        if let boundaries = Self.section(title: "Hard Boundaries", text: context.boundaries) {
            sections.append(boundaries)
        }

        return sections.joined(separator: "\n\n")
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func section(title: String, text: String) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map(trimmedMemoryLine)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return "\(title):\n\(lines.map { "- \($0)" }.joined(separator: "\n"))"
    }

    private static func trimmedMemoryLine(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["- ", "* ", "• "] {
            if trimmed.hasPrefix(marker) {
                trimmed = String(trimmed.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return trimmed
    }
}

struct UserModel: Equatable {
    var identity: [String]
    var goals: [String]
    var workStyle: [String]
    var memoryBoundary: [String]

    var isEmpty: Bool {
        identity.isEmpty && goals.isEmpty && workStyle.isEmpty && memoryBoundary.isEmpty
    }

    func promptBlock(includeIdentity: Bool) -> String? {
        var sections: [String] = []

        if includeIdentity, !identity.isEmpty {
            sections.append(Self.section(title: "Identity", lines: identity))
        }
        if !goals.isEmpty {
            sections.append(Self.section(title: "Goals", lines: goals))
        }
        if !workStyle.isEmpty {
            sections.append(Self.section(title: "Work Style", lines: workStyle))
        }
        if !memoryBoundary.isEmpty {
            sections.append(Self.section(title: "Memory Boundary", lines: memoryBoundary))
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    private static func section(title: String, lines: [String]) -> String {
        let bulletLines = lines.map { "- \($0)" }.joined(separator: "\n")
        return "\(title):\n\(bulletLines)"
    }
}
