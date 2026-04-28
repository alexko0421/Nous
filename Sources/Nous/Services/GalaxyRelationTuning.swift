import Foundation

enum GalaxyRelationTuning {
    static let semanticThreshold: Float = 0.75

    static let queuedRefinementCandidateLimit = 4
    static let manualRefinementCandidateLimit = 12

    static let minimumAtomConfidence: Float = 0.64
    static let maximumAtomConfidence: Float = 0.96
    static let atomOverlapConfidenceBoost: Float = 0.04

    static let minimumLLMConfidence = 0.62
}
