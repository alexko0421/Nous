import Foundation

enum FailureSkillRepairRunStatus: String, Codable, CaseIterable {
    case requested
    case running
    case draftPROpened
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .requested:
            return "Requested"
        case .running:
            return "Running"
        case .draftPROpened:
            return "Draft PR opened"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var isActive: Bool {
        self == .requested || self == .running
    }
}

struct FailureSkillRepairRun: Identifiable, Equatable {
    let id: UUID
    let candidateId: UUID
    var status: FailureSkillRepairRunStatus
    var beadId: String?
    var branchName: String
    var commitSHA: String?
    var prURL: String?
    var logExcerpt: String?
    var error: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        candidateId: UUID,
        status: FailureSkillRepairRunStatus,
        beadId: String?,
        branchName: String,
        commitSHA: String?,
        prURL: String?,
        logExcerpt: String?,
        error: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.candidateId = candidateId
        self.status = status
        self.beadId = beadId?.boundedFailureRepairText()
        self.branchName = branchName.boundedFailureRepairText(limit: 180) ?? branchName
        self.commitSHA = commitSHA?.boundedFailureRepairText(limit: 80)
        self.prURL = prURL?.boundedFailureRepairText(limit: 240)
        self.logExcerpt = logExcerpt?.boundedFailureRepairText(limit: 500)
        self.error = error?.boundedFailureRepairText(limit: 500)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension String {
    func boundedFailureRepairText(limit: Int = 240) -> String? {
        let compacted = components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compacted.isEmpty else { return nil }
        if compacted.count <= limit { return compacted }
        return String(compacted.prefix(limit))
    }
}
