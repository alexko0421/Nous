import Foundation

struct Skill: Identifiable, Equatable {
    let id: UUID
    let userId: String
    let payload: SkillPayload
    var state: SkillState
    var firedCount: Int
    let createdAt: Date
    var lastModifiedAt: Date
    var lastFiredAt: Date?
}

enum SkillState: String, Codable {
    case active
    case retired
    case disabled
}

enum SkillSource: String, Codable {
    case alex
    case importedFromAnchor
}

struct SkillPayload: Codable, Equatable {
    let payloadVersion: Int
    let name: String
    let description: String?
    let source: SkillSource
    let trigger: SkillTrigger
    let action: SkillAction
    let rationale: String?
    let antiPatternExamples: [String]

    init(
        payloadVersion: Int,
        name: String,
        description: String? = nil,
        source: SkillSource,
        trigger: SkillTrigger,
        action: SkillAction,
        rationale: String? = nil,
        antiPatternExamples: [String] = []
    ) {
        self.payloadVersion = payloadVersion
        self.name = name
        self.description = description
        self.source = source
        self.trigger = trigger
        self.action = action
        self.rationale = rationale
        self.antiPatternExamples = antiPatternExamples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .payloadVersion)

        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .payloadVersion,
                in: container,
                debugDescription: "SkillStore accepts payloadVersion=1 only"
            )
        }

        payloadVersion = version
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        source = try container.decode(SkillSource.self, forKey: .source)
        trigger = try container.decode(SkillTrigger.self, forKey: .trigger)
        action = try container.decode(SkillAction.self, forKey: .action)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
        antiPatternExamples = try container.decodeIfPresent([String].self, forKey: .antiPatternExamples) ?? []
    }
}

struct SkillTrigger: Codable, Equatable {
    enum Kind: String, Codable {
        case always
        case mode
    }

    let kind: Kind
    let modes: [QuickActionMode]
    let priority: Int
}

struct SkillAction: Codable, Equatable {
    enum Kind: String, Codable {
        case promptFragment
    }

    let kind: Kind
    let content: String
}
