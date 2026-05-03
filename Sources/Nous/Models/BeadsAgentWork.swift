import Foundation

struct BeadsAgentWorkSnapshot: Equatable {
    var beadsPath: String
    var ready: [BeadsIssue]
    var inProgress: [BeadsIssue]
    var recentClosed: [BeadsIssue]
    var harness: HarnessHealthSnapshot
    var runtimeHarness: RuntimeHarnessSnapshot
    var loadedAt: Date

    static let empty = BeadsAgentWorkSnapshot(
        beadsPath: "",
        ready: [],
        inProgress: [],
        recentClosed: [],
        harness: .empty,
        runtimeHarness: .empty,
        loadedAt: .distantPast
    )

    var hasLoaded: Bool {
        loadedAt != .distantPast
    }
}

struct BeadsAgentWorkCommand: Identifiable, Equatable {
    let title: String
    let command: String
    let detail: String
    let systemImage: String

    var id: String { command }

    static let defaultCommands: [BeadsAgentWorkCommand] = [
        BeadsAgentWorkCommand(
            title: "Prime",
            command: "bd prime",
            detail: "Load rules and engineering memories.",
            systemImage: "sparkles"
        ),
        BeadsAgentWorkCommand(
            title: "Ready",
            command: "bd ready --json",
            detail: "Inspect unblocked agent work.",
            systemImage: "checklist"
        ),
        BeadsAgentWorkCommand(
            title: "Quick Gate",
            command: "scripts/nous_harness_check.sh quick",
            detail: "Run fast protected-file and targeted quality checks.",
            systemImage: "shield.lefthalf.filled"
        ),
        BeadsAgentWorkCommand(
            title: "Full Gate",
            command: "scripts/nous_harness_check.sh full",
            detail: "Run release-grade build, tests, and fixture checks.",
            systemImage: "checkmark.shield"
        ),
        BeadsAgentWorkCommand(
            title: "Setup",
            command: "scripts/setup_beads_agent_memory.sh",
            detail: "Point this workspace at shared Beads.",
            systemImage: "externaldrive"
        )
    ]
}

enum BeadsAgentWorkSetupHint {
    static func message(errorMessage: String?, beadsPath: String) -> String {
        if let errorMessage, looksLikeMissingBd(errorMessage) {
            return "bd is missing. Run scripts/setup_beads_agent_memory.sh --install."
        }

        if let errorMessage, !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Beads needs attention. The panel is read-only; fix the CLI setup, then refresh."
        }

        if beadsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Run scripts/setup_beads_agent_memory.sh from the repo root."
        }

        return "Shared Beads store connected. Nous memory stays separate."
    }

    private static func looksLikeMissingBd(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("could not launch bd") ||
            lowercased.contains("no such file") ||
            lowercased.contains("env: bd")
    }
}

struct BeadsIssue: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let description: String
    let status: String
    let priority: Int
    let issueType: String?
    let assignee: String?
    let createdAt: String?
    let createdBy: String?
    let updatedAt: String?
    let startedAt: String?
    let closedAt: String?
    let closeReason: String?
    let dependencyCount: Int
    let dependentCount: Int
    let commentCount: Int
    let dependencies: [BeadsDependency]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case status
        case priority
        case issueType = "issue_type"
        case assignee
        case createdAt = "created_at"
        case createdBy = "created_by"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case closedAt = "closed_at"
        case closeReason = "close_reason"
        case dependencyCount = "dependency_count"
        case dependentCount = "dependent_count"
        case commentCount = "comment_count"
        case dependencies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        issueType = try container.decodeIfPresent(String.self, forKey: .issueType)
        assignee = try container.decodeIfPresent(String.self, forKey: .assignee)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        closedAt = try container.decodeIfPresent(String.self, forKey: .closedAt)
        closeReason = try container.decodeIfPresent(String.self, forKey: .closeReason)
        dependencyCount = try container.decodeIfPresent(Int.self, forKey: .dependencyCount) ?? 0
        dependentCount = try container.decodeIfPresent(Int.self, forKey: .dependentCount) ?? 0
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        dependencies = try container.decodeIfPresent([BeadsDependency].self, forKey: .dependencies) ?? []
    }
}

struct BeadsDependency: Identifiable, Decodable, Equatable {
    let id: String
    let issueId: String?
    let dependsOnId: String?
    let title: String
    let status: String
    let priority: Int?
    let issueType: String?
    let relation: String?

    enum CodingKeys: String, CodingKey {
        case id
        case issueId = "issue_id"
        case dependsOnId = "depends_on_id"
        case title
        case status
        case priority
        case issueType = "issue_type"
        case type
        case dependencyType = "dependency_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let directId = try container.decodeIfPresent(String.self, forKey: .id)
        issueId = try container.decodeIfPresent(String.self, forKey: .issueId)
        dependsOnId = try container.decodeIfPresent(String.self, forKey: .dependsOnId)
        relation = try container.decodeIfPresent(String.self, forKey: .dependencyType)
            ?? container.decodeIfPresent(String.self, forKey: .type)
        id = directId ?? dependsOnId ?? issueId ?? "unknown"
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        issueType = try container.decodeIfPresent(String.self, forKey: .issueType)
    }
}
