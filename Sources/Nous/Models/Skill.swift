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

struct LoadedSkill: Equatable {
    let skillID: UUID
    let nameSnapshot: String
    let contentSnapshot: String
    let stateAtLoad: SkillState
    let loadedAt: Date
}

enum MarkSkillLoadedResult: Equatable {
    case inserted(LoadedSkill)
    case alreadyLoaded(LoadedSkill)
    case missingSkill
    case unavailable(SkillState)
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
    let useWhen: String?
    let source: SkillSource
    let trigger: SkillTrigger
    let action: SkillAction
    let rationale: String?
    let antiPatternExamples: [String]

    init(
        payloadVersion: Int,
        name: String,
        description: String? = nil,
        useWhen: String? = nil,
        source: SkillSource,
        trigger: SkillTrigger,
        action: SkillAction,
        rationale: String? = nil,
        antiPatternExamples: [String] = []
    ) {
        self.payloadVersion = payloadVersion
        self.name = name
        self.description = description
        self.useWhen = useWhen
        self.source = source
        self.trigger = trigger
        self.action = action
        self.rationale = rationale
        self.antiPatternExamples = antiPatternExamples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .payloadVersion)

        guard (1...2).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .payloadVersion,
                in: container,
                debugDescription: "SkillStore accepts payloadVersion in 1...2"
            )
        }

        payloadVersion = version
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        useWhen = try container.decodeIfPresent(String.self, forKey: .useWhen)
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
        case analysisGate
        case mode
    }

    let kind: Kind
    let modes: [QuickActionMode]
    let priority: Int
    let cues: [String]

    init(
        kind: Kind,
        modes: [QuickActionMode],
        priority: Int,
        cues: [String] = []
    ) {
        self.kind = kind
        self.modes = modes
        self.priority = priority
        self.cues = cues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        modes = try container.decode([QuickActionMode].self, forKey: .modes)
        priority = try container.decode(Int.self, forKey: .priority)
        cues = try container.decodeIfPresent([String].self, forKey: .cues) ?? []
    }
}

struct SkillAction: Codable, Equatable {
    enum Kind: String, Codable {
        case promptFragment
    }

    let kind: Kind
    let content: String
}
