import Foundation

enum BehaviorFineTuneRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
}

struct BehaviorFineTuneMessage: Codable, Equatable, Sendable {
    let role: BehaviorFineTuneRole
    let content: String
}

struct BehaviorFineTuneMetadata: Codable, Equatable, Sendable {
    let caseId: String
    let axis: BehaviorDatasetAxis
    let origin: BehaviorDatasetOrigin
    let sourceCaseId: String?
    let tags: [String]
    let generator: String?
    let variantIndex: Int?
    let failureReason: String
    let createdAt: Date
}

struct BehaviorFineTuneRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let messages: [BehaviorFineTuneMessage]
    let metadata: BehaviorFineTuneMetadata
}

struct BehaviorFineTuneExportSummary: Equatable, Sendable {
    let recordCount: Int
    let incidentCount: Int
    let generatedCount: Int
    let outputURL: URL
}
