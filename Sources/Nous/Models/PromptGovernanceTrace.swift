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
}
