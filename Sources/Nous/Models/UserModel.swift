import Foundation

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
