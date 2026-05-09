import Foundation

struct SourceLearningDigestRequest {
    let conversationId: UUID
    let projectId: UUID?
    let userMessage: Message
    let assistantMessage: Message
    let sourceMaterials: [SourceMaterialContext]
}

struct SourceLearningMemoryCandidate {
    let type: MemoryAtomType
    let statement: String
    let scope: MemoryScope
    let confidence: Double
    let evidenceQuote: String
    let sourceNodeId: UUID?

    init(
        type: MemoryAtomType,
        statement: String,
        scope: MemoryScope,
        confidence: Double,
        evidenceQuote: String,
        sourceNodeId: UUID? = nil
    ) {
        self.type = type
        self.statement = statement
        self.scope = scope
        self.confidence = confidence
        self.evidenceQuote = evidenceQuote
        self.sourceNodeId = sourceNodeId
    }
}

struct SourceLearningDigestResult: Equatable {
    let insertedCount: Int
    let rejectedCount: Int

    static let empty = SourceLearningDigestResult(insertedCount: 0, rejectedCount: 0)
}
