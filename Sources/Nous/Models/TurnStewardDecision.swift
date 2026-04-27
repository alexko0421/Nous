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
}

struct TurnStewardDecision: Codable, Equatable {
    let route: TurnRoute
    let memoryPolicy: TurnMemoryPolicyPreset
    let challengeStance: ChallengeStance
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
        reason: String
    ) {
        self.route = route
        self.memoryPolicy = memoryPolicy
        self.challengeStance = challengeStance
        self.responseShape = responseShape
        self.projectSignal = projectSignal
        self.trace = TurnStewardTrace(
            route: route,
            memoryPolicy: memoryPolicy,
            challengeStance: challengeStance,
            responseShape: responseShape,
            projectSignalKind: projectSignal?.kind,
            source: source,
            reason: reason
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
