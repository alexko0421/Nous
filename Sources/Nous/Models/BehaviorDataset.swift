import Foundation

enum BehaviorDatasetAxis: String, Codable, CaseIterable, Equatable, Sendable {
    case memory
    case source
    case sycophancy
    case intent
    case safety
    case voice
}

enum BehaviorDatasetOrigin: String, Codable, Equatable, Sendable {
    case incident
    case generated
}

struct BehaviorFailedTurn: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let axis: BehaviorDatasetAxis
    let user: String
    let assistant: String
    let expectedBehavior: String
    let failureReason: String
    let tags: [String]

    init(
        id: String,
        axis: BehaviorDatasetAxis,
        user: String,
        assistant: String,
        expectedBehavior: String,
        failureReason: String,
        tags: [String] = []
    ) {
        self.id = id
        self.axis = axis
        self.user = user
        self.assistant = assistant
        self.expectedBehavior = expectedBehavior
        self.failureReason = failureReason
        self.tags = tags
    }
}

struct BehaviorDatasetCase: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let axis: BehaviorDatasetAxis
    let origin: BehaviorDatasetOrigin
    let sourceCaseId: String?
    let user: String
    let assistant: String
    let expectedBehavior: String
    let failureReason: String
    let tags: [String]
    let createdAt: Date
    let generator: String?
    let variantIndex: Int?

    init(
        id: String,
        axis: BehaviorDatasetAxis,
        origin: BehaviorDatasetOrigin,
        sourceCaseId: String?,
        user: String,
        assistant: String,
        expectedBehavior: String,
        failureReason: String,
        tags: [String] = [],
        createdAt: Date,
        generator: String? = nil,
        variantIndex: Int? = nil
    ) {
        self.id = id
        self.axis = axis
        self.origin = origin
        self.sourceCaseId = sourceCaseId
        self.user = user
        self.assistant = assistant
        self.expectedBehavior = expectedBehavior
        self.failureReason = failureReason
        self.tags = tags
        self.createdAt = createdAt
        self.generator = generator
        self.variantIndex = variantIndex
    }

    var isSynthetic: Bool {
        origin == .generated
    }
}
