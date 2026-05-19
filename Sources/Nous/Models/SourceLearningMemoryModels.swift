import Foundation

struct SourceLearningDigestRequest {
    let turnId: UUID?
    let conversationId: UUID
    let projectId: UUID?
    let userMessage: Message
    let assistantMessage: Message
    let sourceMaterials: [SourceMaterialContext]

    init(
        turnId: UUID? = nil,
        conversationId: UUID,
        projectId: UUID?,
        userMessage: Message,
        assistantMessage: Message,
        sourceMaterials: [SourceMaterialContext]
    ) {
        self.turnId = turnId
        self.conversationId = conversationId
        self.projectId = projectId
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.sourceMaterials = sourceMaterials
    }
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
    let activeCount: Int
    let pendingCount: Int
    let rejectedCount: Int

    var insertedCount: Int {
        activeCount + pendingCount
    }

    static let empty = SourceLearningDigestResult(activeCount: 0, pendingCount: 0, rejectedCount: 0)

    init(activeCount: Int, pendingCount: Int, rejectedCount: Int) {
        self.activeCount = activeCount
        self.pendingCount = pendingCount
        self.rejectedCount = rejectedCount
    }

    init(insertedCount: Int, rejectedCount: Int) {
        self.init(activeCount: insertedCount, pendingCount: 0, rejectedCount: rejectedCount)
    }
}
