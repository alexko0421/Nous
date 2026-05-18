import Foundation

enum TopicContextLane: String, CaseIterable, Codable, Sendable {
    case nousProduct = "nous_product"
    case aiResearch = "ai_research"
    case education
    case finance
    case personalReflection = "personal_reflection"
    case travelLogistics = "travel_logistics"
    case general

    var displayName: String {
        switch self {
        case .nousProduct:
            return "Nous Product"
        case .aiResearch:
            return "AI Research"
        case .education:
            return "Education"
        case .finance:
            return "Finance"
        case .personalReflection:
            return "Personal Reflection"
        case .travelLogistics:
            return "Travel Logistics"
        case .general:
            return "General"
        }
    }
}

enum TopicContextAssignmentTargetType: String, Codable, Sendable {
    case conversation
    case source
    case memoryAtom = "memory_atom"
}

enum TopicContextClassificationSource: String, Codable, Sendable {
    case deterministic
    case llm
    case fallback
}

struct TopicContextClassification: Equatable, Codable, Sendable {
    let primaryLane: TopicContextLane
    let secondaryLanes: [TopicContextLane]
    let subtopicLabel: String
    let confidence: Double
    let source: TopicContextClassificationSource
}

struct TopicContextAssignment: Identifiable, Equatable, Codable, Sendable {
    var id: String { "\(targetType.rawValue):\(targetId.uuidString)" }

    let targetType: TopicContextAssignmentTargetType
    let targetId: UUID
    let primaryLane: TopicContextLane
    let secondaryLanes: [TopicContextLane]
    let subtopicLabel: String?
    let confidence: Double
    let source: TopicContextClassificationSource
    let createdAt: Date
    let updatedAt: Date
}

struct TopicContextTrace: Equatable, Codable, Sendable {
    let primaryLane: TopicContextLane
    let secondaryLanes: [TopicContextLane]
    let subtopicLabel: String
    let confidence: Double
    let matchedAssignmentCount: Int
}
