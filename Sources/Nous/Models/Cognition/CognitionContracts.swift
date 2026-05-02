import Foundation

enum CognitionOrgan: String, Codable, Equatable, Sendable {
    case coordinator
    case singleTurnToolLoop = "single_turn_tool_loop"
    case patternAnalyst = "pattern_analyst"
    case behaviorLearner = "behavior_learner"
    case relationshipScout = "relationship_scout"
    case reviewer
    case externalSense = "external_sense"
}

enum CognitionJurisdiction: String, Codable, Equatable, Sendable {
    case alexIdentity = "alex_identity"
    case userModel = "user_model"
    case projectMemory = "project_memory"
    case conversationThread = "conversation_thread"
    case contradictionFacts = "contradiction_facts"
    case graphMemory = "graph_memory"
    case selfReflection = "self_reflection"
    case shadowLearning = "shadow_learning"
    case turnContext = "turn_context"
    case externalResource = "external_resource"

    var requiresEvidence: Bool {
        self != .turnContext
    }
}

enum CognitionPrivacyBoundary: String, Codable, Equatable, Sendable {
    case localOnly = "local_only"
    case cloudAllowed = "cloud_allowed"
    case externalConnector = "external_connector"
}

enum CognitionEvidenceSource: String, Codable, Equatable, Sendable {
    case message
    case assistantDraft = "assistant_draft"
    case node
    case memoryEntry = "memory_entry"
    case memoryAtom = "memory_atom"
    case memoryEdge = "memory_edge"
    case reflectionClaim = "reflection_claim"
    case shadowPattern = "shadow_pattern"
    case galaxyRelation = "galaxy_relation"
    case externalResource = "external_resource"
}

struct CognitionEvidenceRef: Codable, Equatable, Hashable, Sendable {
    let source: CognitionEvidenceSource
    let id: String
    let quote: String?

    init(source: CognitionEvidenceSource, id: String, quote: String? = nil) {
        self.source = source
        self.id = id
        self.quote = quote
    }
}

struct CognitionBudget: Codable, Equatable, Sendable {
    let maxInputCharacters: Int
    let maxOutputCharacters: Int
    let maxToolCalls: Int
}

struct CognitionOutputContract: Codable, Equatable, Sendable {
    let schemaName: String
    let requiresEvidence: Bool
    let maxArtifacts: Int
}

struct CognitionTrace: Codable, Equatable, Sendable {
    let runId: UUID
    let producer: CognitionOrgan
    let sourceJobId: String?
    let createdAt: Date

    init(
        runId: UUID = UUID(),
        producer: CognitionOrgan,
        sourceJobId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.runId = runId
        self.producer = producer
        self.sourceJobId = sourceJobId
        self.createdAt = createdAt
    }
}

struct TurnCognitionSnapshot: Codable, Equatable, Sendable {
    let turnId: UUID
    let conversationId: UUID
    let assistantMessageId: UUID
    let promptLayers: [String]
    let slowCognitionAttached: Bool
    let reviewArtifactId: UUID?
    let reviewRiskFlags: [String]
    let reviewConfidence: Double?
    let conversationRecoveryReason: String?
    let conversationRecoveryOriginalNodeId: UUID?
    let conversationRecoveryRecoveredNodeId: UUID?
    let conversationRecoveryRebasedMessageCount: Int
    let recordedAt: Date

    init(
        turnId: UUID,
        conversationId: UUID,
        assistantMessageId: UUID,
        promptLayers: [String],
        slowCognitionAttached: Bool,
        reviewArtifactId: UUID?,
        reviewRiskFlags: [String],
        reviewConfidence: Double?,
        conversationRecoveryReason: String? = nil,
        conversationRecoveryOriginalNodeId: UUID? = nil,
        conversationRecoveryRecoveredNodeId: UUID? = nil,
        conversationRecoveryRebasedMessageCount: Int = 0,
        recordedAt: Date = Date()
    ) {
        self.turnId = turnId
        self.conversationId = conversationId
        self.assistantMessageId = assistantMessageId
        self.promptLayers = promptLayers
        self.slowCognitionAttached = slowCognitionAttached
        self.reviewArtifactId = reviewArtifactId
        self.reviewRiskFlags = reviewRiskFlags
        self.reviewConfidence = reviewConfidence
        self.conversationRecoveryReason = conversationRecoveryReason
        self.conversationRecoveryOriginalNodeId = conversationRecoveryOriginalNodeId
        self.conversationRecoveryRecoveredNodeId = conversationRecoveryRecoveredNodeId
        self.conversationRecoveryRebasedMessageCount = conversationRecoveryRebasedMessageCount
        self.recordedAt = recordedAt
    }
}

struct CognitionContextPacket: Codable, Equatable, Sendable {
    let id: UUID
    let organ: CognitionOrgan
    let currentAsk: String
    let conversationId: UUID
    let projectId: UUID?
    let currentNodeId: UUID
    let threadSummary: String
    let jurisdiction: CognitionJurisdiction
    let evidenceRefs: [CognitionEvidenceRef]
    let allowedToolNames: [String]
    let budget: CognitionBudget
    let privacyBoundary: CognitionPrivacyBoundary
    let outputContract: CognitionOutputContract
    let createdAt: Date

    init(
        id: UUID = UUID(),
        organ: CognitionOrgan,
        currentAsk: String,
        conversationId: UUID,
        projectId: UUID?,
        currentNodeId: UUID,
        threadSummary: String,
        jurisdiction: CognitionJurisdiction,
        evidenceRefs: [CognitionEvidenceRef],
        allowedToolNames: [String],
        budget: CognitionBudget,
        privacyBoundary: CognitionPrivacyBoundary,
        outputContract: CognitionOutputContract,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.organ = organ
        self.currentAsk = currentAsk
        self.conversationId = conversationId
        self.projectId = projectId
        self.currentNodeId = currentNodeId
        self.threadSummary = threadSummary
        self.jurisdiction = jurisdiction
        self.evidenceRefs = evidenceRefs
        self.allowedToolNames = allowedToolNames
        self.budget = budget
        self.privacyBoundary = privacyBoundary
        self.outputContract = outputContract
        self.createdAt = createdAt
    }

    @discardableResult
    func validated() throws -> CognitionContextPacket {
        guard budget.maxInputCharacters > 0,
              budget.maxOutputCharacters > 0,
              budget.maxToolCalls >= 0,
              outputContract.maxArtifacts > 0 else {
            throw CognitionValidationError.invalidBudget
        }
        guard !currentAsk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !outputContract.schemaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CognitionValidationError.emptySummary
        }
        if outputContract.requiresEvidence, jurisdiction.requiresEvidence, evidenceRefs.isEmpty {
            throw CognitionValidationError.missingEvidenceForDurableArtifact
        }
        return self
    }
}

struct CognitionArtifact: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let organ: CognitionOrgan
    let title: String
    let summary: String
    let confidence: Double
    let jurisdiction: CognitionJurisdiction
    let evidenceRefs: [CognitionEvidenceRef]
    let suggestedSurfacing: String?
    let riskFlags: [String]
    let trace: CognitionTrace
    let createdAt: Date

    init(
        id: UUID = UUID(),
        organ: CognitionOrgan,
        title: String,
        summary: String,
        confidence: Double,
        jurisdiction: CognitionJurisdiction,
        evidenceRefs: [CognitionEvidenceRef],
        suggestedSurfacing: String? = nil,
        riskFlags: [String] = [],
        trace: CognitionTrace? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.organ = organ
        self.title = title
        self.summary = summary
        self.confidence = confidence
        self.jurisdiction = jurisdiction
        self.evidenceRefs = evidenceRefs
        self.suggestedSurfacing = suggestedSurfacing
        self.riskFlags = riskFlags
        self.trace = trace ?? CognitionTrace(producer: organ, createdAt: createdAt)
        self.createdAt = createdAt
    }

    @discardableResult
    func validated() throws -> CognitionArtifact {
        guard (0...1).contains(confidence) else {
            throw CognitionValidationError.confidenceOutOfBounds
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CognitionValidationError.emptySummary
        }
        if jurisdiction.requiresEvidence, evidenceRefs.isEmpty {
            throw CognitionValidationError.missingEvidenceForDurableArtifact
        }
        return self
    }
}

enum CognitionValidationError: Error, Equatable {
    case missingEvidenceForDurableArtifact
    case confidenceOutOfBounds
    case emptySummary
    case invalidBudget
}
