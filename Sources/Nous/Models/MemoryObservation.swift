import Foundation

struct MemoryObservation: Identifiable, Codable, Equatable {
    let id: UUID
    var rawText: String
    var extractedType: MemoryAtomType?
    var confidence: Double
    var sourceNodeId: UUID?
    var sourceMessageId: UUID?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        rawText: String,
        extractedType: MemoryAtomType? = nil,
        confidence: Double = 0.5,
        sourceNodeId: UUID? = nil,
        sourceMessageId: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.rawText = rawText
        self.extractedType = extractedType
        self.confidence = confidence
        self.sourceNodeId = sourceNodeId
        self.sourceMessageId = sourceMessageId
        self.createdAt = createdAt
    }
}
