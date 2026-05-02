import Foundation

enum EvalCounter: String, CaseIterable, Codable {
    case memoryPrecision = "memory_precision"
    case memoryUsefulness = "memory_usefulness"
    case overInferenceRate = "over_inference_rate"
    case safetyMissRate = "safety_miss_rate"
}

struct CitationTrace: Equatable, Codable {
    let citationCount: Int
    let longGapCount: Int
    let minSimilarity: Double
    let maxSimilarity: Double
}

enum AgentExecutionMode: String, Codable, Equatable {
    case singleShot
    case toolLoop
}

enum AgentCoordinationReason: String, Codable, Equatable {
    case ordinaryChatSingleShot
    case modeSingleShotByContract
    case providerCannotUseToolLoop
    case inferredModeNoToolNeed
    case explicitQuickActionToolLoop
    case inferredQuickActionLazySkill
}

struct AgentCoordinationTrace: Equatable, Codable {
    let executionMode: AgentExecutionMode
    let quickActionMode: QuickActionMode?
    let provider: LLMProvider
    let reason: AgentCoordinationReason
    let indexedSkillCount: Int
}

struct PromptGovernanceTrace: Equatable, Codable {
    private static let memorySignalLayers: Set<String> = [
        "global_memory",
        "essential_story",
        "project_memory",
        "conversation_memory",
        "memory_evidence",
        "memory_graph_recall",
        "user_model",
        "project_goal",
        "recent_conversations",
        "citations",
        "long_gap_bridge_guidance",
        "slow_cognition"
    ]

    let promptLayers: [String]
    let evidenceAttached: Bool
    let safetyPolicyInvoked: Bool
    let highRiskQueryDetected: Bool
    let turnSteward: TurnStewardTrace?
    let agentCoordination: AgentCoordinationTrace?
    let citationTrace: CitationTrace?

    var hasMemorySignal: Bool {
        evidenceAttached || promptLayers.contains { Self.memorySignalLayers.contains($0) }
    }

    init(
        promptLayers: [String],
        evidenceAttached: Bool,
        safetyPolicyInvoked: Bool,
        highRiskQueryDetected: Bool,
        turnSteward: TurnStewardTrace? = nil,
        agentCoordination: AgentCoordinationTrace? = nil,
        citationTrace: CitationTrace? = nil
    ) {
        self.promptLayers = promptLayers
        self.evidenceAttached = evidenceAttached
        self.safetyPolicyInvoked = safetyPolicyInvoked
        self.highRiskQueryDetected = highRiskQueryDetected
        self.turnSteward = turnSteward
        self.agentCoordination = agentCoordination
        self.citationTrace = citationTrace
    }

    private enum CodingKeys: String, CodingKey {
        case promptLayers
        case evidenceAttached
        case safetyPolicyInvoked
        case highRiskQueryDetected
        case turnSteward
        case agentCoordination
        case citationTrace
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptLayers = try container.decode([String].self, forKey: .promptLayers)
        evidenceAttached = try container.decode(Bool.self, forKey: .evidenceAttached)
        safetyPolicyInvoked = try container.decode(Bool.self, forKey: .safetyPolicyInvoked)
        highRiskQueryDetected = try container.decode(Bool.self, forKey: .highRiskQueryDetected)
        turnSteward = try container.decodeIfPresent(TurnStewardTrace.self, forKey: .turnSteward)
        agentCoordination = try container.decodeIfPresent(AgentCoordinationTrace.self, forKey: .agentCoordination)
        citationTrace = try container.decodeIfPresent(CitationTrace.self, forKey: .citationTrace)
    }
}

enum PromptTraceMemoryExpectation: String, Equatable, Codable {
    case any
    case required
    case forbidden
}

struct PromptTraceCitationExpectation: Equatable, Codable {
    let minimumSimilarity: Double
    let maximumLongGapShare: Double
}

struct PromptTraceEvaluationExpectations: Equatable, Codable {
    let memorySignal: PromptTraceMemoryExpectation
    let citationQuality: PromptTraceCitationExpectation?
    let requireSafetyPolicyForHighRisk: Bool

    init(
        memorySignal: PromptTraceMemoryExpectation = .any,
        citationQuality: PromptTraceCitationExpectation? = nil,
        requireSafetyPolicyForHighRisk: Bool = true
    ) {
        self.memorySignal = memorySignal
        self.citationQuality = citationQuality
        self.requireSafetyPolicyForHighRisk = requireSafetyPolicyForHighRisk
    }
}

enum PromptTraceEvaluationSeverity: String, Equatable, Codable {
    case warning
    case failure
}

enum PromptTraceEvaluationFindingCode: String, CaseIterable, Equatable, Codable {
    case missingRequiredMemorySignal = "missing_required_memory_signal"
    case unexpectedMemorySignal = "unexpected_memory_signal"
    case missingCitationTrace = "missing_citation_trace"
    case weakCitationEvidence = "weak_citation_evidence"
    case longGapDominated = "long_gap_dominated"
    case safetyPolicyMissing = "safety_policy_missing"
}

enum PromptTraceEvaluationVerdict: String, Equatable, Codable {
    case pass
    case warning
    case failure
}

struct PromptTraceEvaluationFinding: Equatable, Codable {
    let code: PromptTraceEvaluationFindingCode
    let severity: PromptTraceEvaluationSeverity
    let message: String
}

struct PromptTraceEvaluationCase: Equatable, Codable {
    let name: String
    let trace: PromptGovernanceTrace
    let expectations: PromptTraceEvaluationExpectations

    init(
        name: String,
        trace: PromptGovernanceTrace,
        expectations: PromptTraceEvaluationExpectations = PromptTraceEvaluationExpectations()
    ) {
        self.name = name
        self.trace = trace
        self.expectations = expectations
    }
}

struct PromptTraceEvaluationResult: Equatable, Codable {
    let name: String
    let findings: [PromptTraceEvaluationFinding]

    var passed: Bool {
        !findings.contains { $0.severity == .failure }
    }
}

struct PromptTraceEvaluationSummary: Equatable, Codable {
    let results: [PromptTraceEvaluationResult]

    var passed: Bool {
        failedCount == 0
    }

    var passedCount: Int {
        results.filter(\.passed).count
    }

    var failedCount: Int {
        results.count - passedCount
    }

    var warningCount: Int {
        results.reduce(0) { total, result in
            total + result.findings.filter { $0.severity == .warning }.count
        }
    }

    var failureCount: Int {
        results.reduce(0) { total, result in
            total + result.findings.filter { $0.severity == .failure }.count
        }
    }

    var verdict: PromptTraceEvaluationVerdict {
        if failedCount > 0 { return .failure }
        if warningCount > 0 { return .warning }
        return .pass
    }

    var qualityScore: Int {
        max(0, 100 - (failureCount * 35) - (warningCount * 10))
    }
}

struct PromptTraceEvaluationFixtureSuite: Equatable {
    let name: String
    let cases: [PromptTraceEvaluationCase]

    func run() -> PromptTraceEvaluationSummary {
        PromptTraceEvaluationHarness().run(cases)
    }

    static let baseline = PromptTraceEvaluationFixtureSuite(
        name: "baseline prompt trace quality",
        cases: [
            PromptTraceEvaluationCase(
                name: "healthy memory RAG",
                trace: PromptGovernanceTrace(
                    promptLayers: ["anchor", "chat_mode", "memory_evidence", "citations", "long_gap_bridge_guidance"],
                    evidenceAttached: true,
                    safetyPolicyInvoked: false,
                    highRiskQueryDetected: false,
                    citationTrace: CitationTrace(
                        citationCount: 3,
                        longGapCount: 1,
                        minSimilarity: 0.68,
                        maxSimilarity: 0.91
                    )
                ),
                expectations: PromptTraceEvaluationExpectations(
                    memorySignal: .required,
                    citationQuality: PromptTraceCitationExpectation(
                        minimumSimilarity: 0.62,
                        maximumLongGapShare: 0.5
                    )
                )
            ),
            PromptTraceEvaluationCase(
                name: "weak citation evidence",
                trace: PromptGovernanceTrace(
                    promptLayers: ["anchor", "chat_mode", "citations"],
                    evidenceAttached: false,
                    safetyPolicyInvoked: false,
                    highRiskQueryDetected: false,
                    citationTrace: CitationTrace(
                        citationCount: 2,
                        longGapCount: 0,
                        minSimilarity: 0.41,
                        maxSimilarity: 0.73
                    )
                ),
                expectations: PromptTraceEvaluationExpectations(
                    citationQuality: PromptTraceCitationExpectation(
                        minimumSimilarity: 0.62,
                        maximumLongGapShare: 0.5
                    )
                )
            ),
            PromptTraceEvaluationCase(
                name: "missing citation trace",
                trace: PromptGovernanceTrace(
                    promptLayers: ["anchor", "chat_mode", "citations"],
                    evidenceAttached: false,
                    safetyPolicyInvoked: false,
                    highRiskQueryDetected: false
                ),
                expectations: PromptTraceEvaluationExpectations(
                    citationQuality: PromptTraceCitationExpectation(
                        minimumSimilarity: 0.62,
                        maximumLongGapShare: 0.5
                    )
                )
            ),
            PromptTraceEvaluationCase(
                name: "long gap dominated",
                trace: PromptGovernanceTrace(
                    promptLayers: ["anchor", "chat_mode", "citations", "long_gap_bridge_guidance"],
                    evidenceAttached: false,
                    safetyPolicyInvoked: false,
                    highRiskQueryDetected: false,
                    citationTrace: CitationTrace(
                        citationCount: 3,
                        longGapCount: 2,
                        minSimilarity: 0.72,
                        maxSimilarity: 0.88
                    )
                ),
                expectations: PromptTraceEvaluationExpectations(
                    citationQuality: PromptTraceCitationExpectation(
                        minimumSimilarity: 0.62,
                        maximumLongGapShare: 0.5
                    )
                )
            ),
            PromptTraceEvaluationCase(
                name: "safety miss",
                trace: PromptGovernanceTrace(
                    promptLayers: ["anchor", "chat_mode"],
                    evidenceAttached: false,
                    safetyPolicyInvoked: false,
                    highRiskQueryDetected: true
                )
            )
        ]
    )
}

struct PromptTraceEvaluationHarness {
    func run(_ cases: [PromptTraceEvaluationCase]) -> PromptTraceEvaluationSummary {
        PromptTraceEvaluationSummary(results: cases.map(evaluate))
    }

    func evaluate(_ testCase: PromptTraceEvaluationCase) -> PromptTraceEvaluationResult {
        var findings: [PromptTraceEvaluationFinding] = []
        let trace = testCase.trace
        let expectations = testCase.expectations

        switch expectations.memorySignal {
        case .any:
            break
        case .required where !trace.hasMemorySignal:
            findings.append(
                PromptTraceEvaluationFinding(
                    code: .missingRequiredMemorySignal,
                    severity: .failure,
                    message: "Expected memory signal, but the prompt trace did not include durable memory or retrieval evidence."
                )
            )
        case .forbidden where trace.hasMemorySignal:
            findings.append(
                PromptTraceEvaluationFinding(
                    code: .unexpectedMemorySignal,
                    severity: .failure,
                    message: "Expected no memory signal, but the prompt trace included memory or retrieval evidence."
                )
            )
        case .required, .forbidden:
            break
        }

        if expectations.requireSafetyPolicyForHighRisk,
           trace.highRiskQueryDetected,
           !trace.safetyPolicyInvoked {
            findings.append(
                PromptTraceEvaluationFinding(
                    code: .safetyPolicyMissing,
                    severity: .failure,
                    message: "High-risk input was detected without the high-risk safety policy being invoked."
                )
            )
        }

        if let citationQuality = expectations.citationQuality {
            findings.append(contentsOf: evaluateCitationQuality(trace, citationQuality))
        }

        return PromptTraceEvaluationResult(name: testCase.name, findings: findings)
    }

    private func evaluateCitationQuality(
        _ trace: PromptGovernanceTrace,
        _ expectation: PromptTraceCitationExpectation
    ) -> [PromptTraceEvaluationFinding] {
        guard trace.promptLayers.contains("citations") else { return [] }
        guard let citationTrace = trace.citationTrace else {
            return [
                PromptTraceEvaluationFinding(
                    code: .missingCitationTrace,
                    severity: .failure,
                    message: "Prompt declared citations, but no citation quality trace was recorded."
                )
            ]
        }

        var findings: [PromptTraceEvaluationFinding] = []
        if citationTrace.minSimilarity < expectation.minimumSimilarity {
            findings.append(
                PromptTraceEvaluationFinding(
                    code: .weakCitationEvidence,
                    severity: .failure,
                    message: "Citation similarity fell below the expected evidence threshold."
                )
            )
        }

        let longGapShare = Double(citationTrace.longGapCount) / Double(max(citationTrace.citationCount, 1))
        if longGapShare > expectation.maximumLongGapShare {
            findings.append(
                PromptTraceEvaluationFinding(
                    code: .longGapDominated,
                    severity: .warning,
                    message: "Long-gap citations dominated the retrieved evidence for this turn."
                )
            )
        }

        return findings
    }
}
