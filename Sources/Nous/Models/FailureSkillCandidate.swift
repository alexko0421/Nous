import Foundation

enum FailureSignature: String, Codable, CaseIterable {
    case ownCorpusIgnored
    case borrowedAuthorityLeakage
    case sourceMaterialIgnored
    case judgeFeedbackWrongMemory
    case judgeFeedbackWrongTiming
    case judgeFeedbackTooForceful
    case judgeFeedbackTooRepetitive
    case judgeFeedbackNotUseful

    var displayName: String {
        switch self {
        case .ownCorpusIgnored:
            return "Own corpus ignored"
        case .borrowedAuthorityLeakage:
            return "Borrowed authority leakage"
        case .sourceMaterialIgnored:
            return "Source material ignored"
        case .judgeFeedbackWrongMemory:
            return "Judge feedback: wrong memory"
        case .judgeFeedbackWrongTiming:
            return "Judge feedback: wrong timing"
        case .judgeFeedbackTooForceful:
            return "Judge feedback: too forceful"
        case .judgeFeedbackTooRepetitive:
            return "Judge feedback: too repetitive"
        case .judgeFeedbackNotUseful:
            return "Judge feedback: not useful"
        }
    }
}

enum FailureRepairKind: String, Codable, CaseIterable {
    case promptSkill
    case deterministicFix
    case regressionOnly
    case observeOnly

    var displayName: String {
        switch self {
        case .promptSkill:
            return "Prompt skill"
        case .deterministicFix:
            return "Deterministic fix"
        case .regressionOnly:
            return "Regression only"
        case .observeOnly:
            return "Observe only"
        }
    }
}

enum FailureSkillStatus: String, Codable, CaseIterable {
    case proposed
    case approved
    case activated
    case dismissed

    var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

enum FailureSkillSourceKind: String, Codable, CaseIterable {
    case corpusFidelity
    case contextManifest
    case judgeFeedback
    case recurringPattern
}

enum FailureSkillEvidenceSource: String, Codable, CaseIterable {
    case telemetry
    case contextManifest
    case judgeEvent
    case assistantMessage
    case userFeedback
    case failureSkillCandidate
}

struct FailureSkillEvidence: Codable, Equatable, Hashable {
    let source: FailureSkillEvidenceSource
    let id: String
    let label: String?
    let snippet: String?

    init(
        source: FailureSkillEvidenceSource,
        id: String,
        label: String? = nil,
        snippet: String? = nil
    ) {
        self.source = source
        self.id = id
        self.label = label?.boundedFailureSkillSnippet()
        self.snippet = snippet?.boundedFailureSkillSnippet()
    }
}

struct SkillifyChecklist: Codable, Equatable {
    let rootCause: String?
    let trigger: String?
    let useWhen: String?
    let antiPatternExample: String?
    let regressionTestReference: String?
    let resolverTestReference: String?
    let smokeTestCommand: String?
    let codeReference: String?

    init(
        rootCause: String? = nil,
        trigger: String? = nil,
        useWhen: String? = nil,
        antiPatternExample: String? = nil,
        regressionTestReference: String? = nil,
        resolverTestReference: String? = nil,
        smokeTestCommand: String? = nil,
        codeReference: String? = nil
    ) {
        self.rootCause = rootCause?.boundedFailureSkillSnippet()
        self.trigger = trigger?.boundedFailureSkillSnippet()
        self.useWhen = useWhen?.boundedFailureSkillSnippet()
        self.antiPatternExample = antiPatternExample?.boundedFailureSkillSnippet()
        self.regressionTestReference = regressionTestReference?.boundedFailureSkillSnippet()
        self.resolverTestReference = resolverTestReference?.boundedFailureSkillSnippet()
        self.smokeTestCommand = smokeTestCommand?.boundedFailureSkillSnippet(limit: 500)
        self.codeReference = codeReference?.boundedFailureSkillSnippet()
    }
}

struct FailureSkillCandidate: Identifiable, Equatable {
    let id: UUID
    let userId: String
    let sourceKind: FailureSkillSourceKind
    let sourceId: String
    let turnId: UUID?
    let conversationId: UUID?
    let assistantMessageId: UUID?
    let signature: FailureSignature
    var repairKind: FailureRepairKind
    var status: FailureSkillStatus
    var evidence: [FailureSkillEvidence]
    var proposedSkillPayload: SkillPayload?
    var checklist: SkillifyChecklist
    let createdAt: Date
    var updatedAt: Date
    var activatedSkillId: UUID?
}

private extension String {
    func boundedFailureSkillSnippet(limit: Int = 240) -> String? {
        let compacted = components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compacted.isEmpty else { return nil }
        if compacted.count <= limit { return compacted }
        return String(compacted.prefix(limit))
    }
}
