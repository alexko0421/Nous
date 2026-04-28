import Foundation

enum EvalCounter: String, CaseIterable, Codable {
    case memoryPrecision = "memory_precision"
    case memoryUsefulness = "memory_usefulness"
    case overInferenceRate = "over_inference_rate"
    case safetyMissRate = "safety_miss_rate"
}

struct PromptGovernanceTrace: Equatable, Codable {
    let promptLayers: [String]
    let evidenceAttached: Bool
    let safetyPolicyInvoked: Bool
    let highRiskQueryDetected: Bool
    let turnSteward: TurnStewardTrace?

    init(
        promptLayers: [String],
        evidenceAttached: Bool,
        safetyPolicyInvoked: Bool,
        highRiskQueryDetected: Bool,
        turnSteward: TurnStewardTrace? = nil
    ) {
        self.promptLayers = promptLayers
        self.evidenceAttached = evidenceAttached
        self.safetyPolicyInvoked = safetyPolicyInvoked
        self.highRiskQueryDetected = highRiskQueryDetected
        self.turnSteward = turnSteward
    }

    private enum CodingKeys: String, CodingKey {
        case promptLayers
        case evidenceAttached
        case safetyPolicyInvoked
        case highRiskQueryDetected
        case turnSteward
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptLayers = try container.decode([String].self, forKey: .promptLayers)
        evidenceAttached = try container.decode(Bool.self, forKey: .evidenceAttached)
        safetyPolicyInvoked = try container.decode(Bool.self, forKey: .safetyPolicyInvoked)
        highRiskQueryDetected = try container.decode(Bool.self, forKey: .highRiskQueryDetected)
        turnSteward = try container.decodeIfPresent(TurnStewardTrace.self, forKey: .turnSteward)
    }
}
