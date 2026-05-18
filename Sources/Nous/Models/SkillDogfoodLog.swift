import Foundation

struct SkillDogfoodSkillReference: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let priority: Int

    init(id: UUID, name: String, priority: Int) {
        self.id = id
        self.name = Self.safeLogName(id: id, rawName: name)
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let priority = try container.decode(Int.self, forKey: .priority)
        self.init(id: id, name: name, priority: priority)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(priority, forKey: .priority)
    }

    private static func safeLogName(id: UUID, rawName: String) -> String {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedScalars = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        let isSafeName = !trimmedName.isEmpty
            && trimmedName.unicodeScalars.count <= 80
            && trimmedName.unicodeScalars.allSatisfy { allowedScalars.contains($0) }

        if isSafeName {
            return trimmedName
        }

        return "skill-\(String(id.uuidString.prefix(8)).lowercased())"
    }
}

struct SkillDogfoodTurnEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordedAt: Date
    let mode: QuickActionMode?
    let turnIndex: Int
    let matchedSkills: [SkillDogfoodSkillReference]
    let loadedSkills: [SkillDogfoodSkillReference]
    let inlineSkills: [SkillDogfoodSkillReference]

    init(
        id: UUID = UUID(),
        recordedAt: Date = Date(),
        mode: QuickActionMode?,
        turnIndex: Int,
        matchedSkills: [SkillDogfoodSkillReference],
        loadedSkills: [SkillDogfoodSkillReference],
        inlineSkills: [SkillDogfoodSkillReference]
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.mode = mode
        self.turnIndex = turnIndex
        self.matchedSkills = matchedSkills
        self.loadedSkills = loadedSkills
        self.inlineSkills = inlineSkills
    }
}

struct SkillDogfoodTopSkill: Codable, Equatable, Sendable {
    let name: String
    let count: Int
}

struct SkillDogfoodSummary: Codable, Equatable, Sendable {
    let turnCount: Int
    let activeDayCount: Int
    let zeroSignalDayCount: Int
    let topSkills: [SkillDogfoodTopSkill]
}

struct QuickActionExperimentDogfoodEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordedAt: Date
    let experimentId: String
    let mode: QuickActionMode
    let variant: QuickActionExperimentVariant

    init(
        id: UUID = UUID(),
        recordedAt: Date = Date(),
        experimentId: String,
        mode: QuickActionMode,
        variant: QuickActionExperimentVariant
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.experimentId = experimentId
        self.mode = mode
        self.variant = variant
    }
}

struct QuickActionExperimentDogfoodExperimentSummary: Codable, Equatable, Sendable {
    let experimentId: String
    let mode: QuickActionMode
    let controlCount: Int
    let candidateCount: Int
}

struct QuickActionExperimentDogfoodSummary: Codable, Equatable, Sendable {
    let turnCount: Int
    let activeDayCount: Int
    let zeroSignalDayCount: Int
    let experiments: [QuickActionExperimentDogfoodExperimentSummary]
}
