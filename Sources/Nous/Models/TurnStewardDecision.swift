import Foundation

enum TurnRoute: String, Codable, Equatable {
    case ordinaryChat
    case direction
    case brainstorm
    case plan

    var quickActionMode: QuickActionMode? {
        switch self {
        case .ordinaryChat:
            return nil
        case .direction:
            return .direction
        case .brainstorm:
            return .brainstorm
        case .plan:
            return .plan
        }
    }
}

enum TurnMemoryPolicyPreset: String, Codable, Equatable {
    case full
    case lean
    case projectOnly
    case conversationOnly
}

enum ChallengeStance: String, Codable, Equatable {
    case supportFirst
    case useSilently
    case surfaceTension
}

enum ResponseStance: String, Codable, Equatable {
    case companion
    case reflective
    case supportFirst
    case softAnalysis
    case hardJudge

    var judgePolicy: JudgePolicy {
        switch self {
        case .companion, .reflective, .supportFirst:
            return .off
        case .softAnalysis:
            return .silentFraming
        case .hardJudge:
            return .visibleTension
        }
    }

    var softerFallback: ResponseStance {
        switch self {
        case .hardJudge:
            return .softAnalysis
        case .softAnalysis:
            return .reflective
        case .reflective, .supportFirst, .companion:
            return .companion
        }
    }
}

enum JudgePolicy: String, Codable, Equatable {
    case off
    case silentFraming
    case visibleTension

    init(challengeStance: ChallengeStance) {
        switch challengeStance {
        case .supportFirst, .useSilently:
            self = .off
        case .surfaceTension:
            self = .visibleTension
        }
    }
}

enum ResponseStanceRouterMode: String, Codable, Equatable {
    case off
    case shadow
    case active

    static let userDefaultsKey = "nous.response_stance.router_mode"

    static func current(defaults: UserDefaults = .standard) -> ResponseStanceRouterMode {
        guard let raw = defaults.string(forKey: userDefaultsKey),
              let mode = ResponseStanceRouterMode(rawValue: raw) else {
            return .shadow
        }
        return mode
    }
}

enum ResponseStanceRouterSource: String, Codable, Equatable {
    case deterministic
    case classifier
    case fallback
}

struct SpeechActClassifierOutput: Codable, Equatable {
    let stance: ResponseStance
    let confidence: Double
    let softerFallback: ResponseStance
    let reason: String

    init(
        stance: ResponseStance,
        confidence: Double,
        softerFallback: ResponseStance,
        reason: String
    ) {
        self.stance = stance
        self.confidence = confidence
        self.softerFallback = softerFallback
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case stance
        case confidence
        case softerFallback
        case softerFallbackSnake = "softer_fallback"
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stance = try container.decode(ResponseStance.self, forKey: .stance)
        confidence = try container.decode(Double.self, forKey: .confidence)
        softerFallback = try container.decodeIfPresent(ResponseStance.self, forKey: .softerFallback)
            ?? container.decode(ResponseStance.self, forKey: .softerFallbackSnake)
        reason = try container.decode(String.self, forKey: .reason)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stance, forKey: .stance)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(softerFallback, forKey: .softerFallback)
        try container.encode(reason, forKey: .reason)
    }
}

enum ResponseShape: String, Codable, Equatable {
    case answerNow
    case askOneQuestion
    case producePlan
    case listDirections
    case narrowNextStep
}

struct ProjectSignal: Codable, Equatable {
    let kind: ProjectSignalKind
    let summary: String
}

enum ProjectSignalKind: String, Codable, Equatable {
    case openLoop
    case directionDrift
    case repeatedStall
    case planNotFollowed
}

enum TurnStewardSource: String, Codable, Equatable {
    case deterministic
    case fallback
}

struct TurnStewardTrace: Codable, Equatable {
    let route: TurnRoute
    let memoryPolicy: TurnMemoryPolicyPreset
    let challengeStance: ChallengeStance
    let responseShape: ResponseShape
    let projectSignalKind: ProjectSignalKind?
    let source: TurnStewardSource
    let reason: String
    let responseStance: ResponseStance?
    let judgePolicy: JudgePolicy?
    let routerMode: ResponseStanceRouterMode?
    let routerSource: ResponseStanceRouterSource?
    let confidence: Double?
    let softerFallback: ResponseStance?
    let fallbackUsed: Bool?
    let routerReason: String?

    init(
        route: TurnRoute,
        memoryPolicy: TurnMemoryPolicyPreset,
        challengeStance: ChallengeStance,
        responseShape: ResponseShape,
        projectSignalKind: ProjectSignalKind?,
        source: TurnStewardSource,
        reason: String,
        responseStance: ResponseStance? = nil,
        judgePolicy: JudgePolicy? = nil,
        routerMode: ResponseStanceRouterMode? = nil,
        routerSource: ResponseStanceRouterSource? = nil,
        confidence: Double? = nil,
        softerFallback: ResponseStance? = nil,
        fallbackUsed: Bool? = nil,
        routerReason: String? = nil
    ) {
        self.route = route
        self.memoryPolicy = memoryPolicy
        self.challengeStance = challengeStance
        self.responseShape = responseShape
        self.projectSignalKind = projectSignalKind
        self.source = source
        self.reason = reason
        self.responseStance = responseStance
        self.judgePolicy = judgePolicy
        self.routerMode = routerMode
        self.routerSource = routerSource
        self.confidence = confidence
        self.softerFallback = softerFallback
        self.fallbackUsed = fallbackUsed
        self.routerReason = routerReason
    }
}

struct TurnStewardDecision: Codable, Equatable {
    let route: TurnRoute
    let memoryPolicy: TurnMemoryPolicyPreset
    let challengeStance: ChallengeStance
    let judgePolicy: JudgePolicy
    let responseShape: ResponseShape
    let projectSignal: ProjectSignal?
    let trace: TurnStewardTrace

    init(
        route: TurnRoute,
        memoryPolicy: TurnMemoryPolicyPreset,
        challengeStance: ChallengeStance,
        responseShape: ResponseShape,
        projectSignal: ProjectSignal? = nil,
        source: TurnStewardSource,
        reason: String,
        responseStance: ResponseStance? = nil,
        judgePolicy: JudgePolicy? = nil,
        traceJudgePolicy: JudgePolicy? = nil,
        routerMode: ResponseStanceRouterMode? = nil,
        routerSource: ResponseStanceRouterSource? = nil,
        confidence: Double? = nil,
        softerFallback: ResponseStance? = nil,
        fallbackUsed: Bool? = nil,
        routerReason: String? = nil
    ) {
        self.route = route
        self.memoryPolicy = memoryPolicy
        self.challengeStance = challengeStance
        self.judgePolicy = judgePolicy ?? JudgePolicy(challengeStance: challengeStance)
        self.responseShape = responseShape
        self.projectSignal = projectSignal
        self.trace = TurnStewardTrace(
            route: route,
            memoryPolicy: memoryPolicy,
            challengeStance: challengeStance,
            responseShape: responseShape,
            projectSignalKind: projectSignal?.kind,
            source: source,
            reason: reason,
            responseStance: responseStance,
            judgePolicy: traceJudgePolicy ?? judgePolicy,
            routerMode: routerMode,
            routerSource: routerSource,
            confidence: confidence,
            softerFallback: softerFallback,
            fallbackUsed: fallbackUsed,
            routerReason: routerReason
        )
    }

    static func fallback(reason: String) -> TurnStewardDecision {
        TurnStewardDecision(
            route: .ordinaryChat,
            memoryPolicy: .full,
            challengeStance: .useSilently,
            responseShape: .answerNow,
            source: .fallback,
            reason: reason
        )
    }
}
