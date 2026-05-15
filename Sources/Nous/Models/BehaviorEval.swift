import Foundation

enum BehaviorEvalAxis: String, Codable, CaseIterable, Equatable, Sendable {
    case anchorIntegrity = "anchor_integrity"
    case memoryBoundary = "memory_boundary"
    case sourceGrounding = "source_grounding"
    case sycophancy
    case provocation
    case currentFactHonesty = "current_fact_honesty"
    case toolLoop = "tool_loop"
    case currentIntent = "current_intent"
    case liveGeneration = "live_generation"
    case delegationContract = "delegation_contract"
}

enum BehaviorEvalSeverity: String, Codable, Equatable, Sendable {
    case warning
    case failure
}

enum BehaviorEvalVerdict: String, Codable, Equatable, Sendable {
    case pass
    case warning
    case failure
}

enum BehaviorEvalMode: String, Codable, Equatable, Sendable {
    case quick
    case full
}

enum BehaviorEvalLiveMode: String, Codable, Equatable, Sendable {
    case never
    case auto
    case required
}

enum BehaviorEvalRunStatus: String, Codable, Equatable, Sendable {
    case passed
    case warning
    case failed
    case skipped
}

struct BehaviorEvalCase: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let axis: BehaviorEvalAxis
    let name: String
    let input: String
    let expectedBehavior: String
    let source: String
    let tags: [String]
    let isSynthetic: Bool

    init(
        id: String,
        axis: BehaviorEvalAxis,
        name: String,
        input: String,
        expectedBehavior: String,
        source: String = "deterministic_fixture",
        tags: [String] = [],
        isSynthetic: Bool = false
    ) {
        self.id = id
        self.axis = axis
        self.name = name
        self.input = input
        self.expectedBehavior = expectedBehavior
        self.source = source
        self.tags = tags
        self.isSynthetic = isSynthetic
    }
}

struct BehaviorEvalFinding: Codable, Equatable, Sendable {
    let code: String
    let severity: BehaviorEvalSeverity
    let message: String

    init(code: String, severity: BehaviorEvalSeverity, message: String) {
        self.code = code
        self.severity = severity
        self.message = message
    }
}

struct BehaviorEvalResult: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let axis: BehaviorEvalAxis
    let verdict: BehaviorEvalVerdict
    let findings: [BehaviorEvalFinding]
    let provider: LLMProvider?
    let model: String?
    let durationMilliseconds: Int?

    init(
        id: String,
        axis: BehaviorEvalAxis,
        verdict: BehaviorEvalVerdict,
        findings: [BehaviorEvalFinding],
        provider: LLMProvider? = nil,
        model: String? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.id = id
        self.axis = axis
        self.verdict = verdict
        self.findings = findings
        self.provider = provider
        self.model = model
        self.durationMilliseconds = durationMilliseconds
    }

    var passed: Bool {
        verdict != .failure && !findings.contains { $0.severity == .failure }
    }
}

struct BehaviorEvalSummary: Codable, Equatable, Sendable {
    let results: [BehaviorEvalResult]

    init(results: [BehaviorEvalResult]) {
        self.results = results
    }

    var passed: Bool {
        failedCount == 0
    }

    var passedCount: Int {
        results.filter { normalizedVerdict(for: $0) == .pass }.count
    }

    var warningCount: Int {
        results.filter { normalizedVerdict(for: $0) == .warning }.count
    }

    var failedCount: Int {
        results.filter { normalizedVerdict(for: $0) == .failure }.count
    }

    var failureFindingCount: Int {
        results.reduce(0) { total, result in
            let findings = result.findings.filter { $0.severity == .failure }.count
            return total + (findings > 0 ? findings : (result.verdict == .failure ? 1 : 0))
        }
    }

    var warningFindingCount: Int {
        results.reduce(0) { total, result in
            let findings = result.findings.filter { $0.severity == .warning }.count
            return total + (findings > 0 ? findings : (result.verdict == .warning ? 1 : 0))
        }
    }

    var verdict: BehaviorEvalVerdict {
        if failedCount > 0 { return .failure }
        if warningCount > 0 || warningFindingCount > 0 { return .warning }
        return .pass
    }

    var trustScore: Int {
        max(0, 100 - (failureFindingCount * 40) - (warningFindingCount * 10))
    }

    private func normalizedVerdict(for result: BehaviorEvalResult) -> BehaviorEvalVerdict {
        if result.verdict == .failure || result.findings.contains(where: { $0.severity == .failure }) {
            return .failure
        }
        if result.verdict == .warning || result.findings.contains(where: { $0.severity == .warning }) {
            return .warning
        }
        return .pass
    }
}

struct BehaviorEvalRunRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let mode: BehaviorEvalMode
    let liveMode: BehaviorEvalLiveMode
    let status: BehaviorEvalRunStatus
    let trustScore: Int
    let startedAt: Date
    let endedAt: Date
    let provider: LLMProvider?
    let model: String?
    let changeSignature: String?
    let baselineRunId: UUID?
    let baselineTrustScore: Int?
    let trustScoreDelta: Int?
    let regression: Bool
    let detail: String

    init(
        id: UUID = UUID(),
        mode: BehaviorEvalMode,
        liveMode: BehaviorEvalLiveMode,
        status: BehaviorEvalRunStatus,
        trustScore: Int,
        startedAt: Date,
        endedAt: Date,
        provider: LLMProvider? = nil,
        model: String? = nil,
        changeSignature: String? = nil,
        baselineRunId: UUID? = nil,
        baselineTrustScore: Int? = nil,
        trustScoreDelta: Int? = nil,
        regression: Bool = false,
        detail: String
    ) {
        self.id = id
        self.mode = mode
        self.liveMode = liveMode
        self.status = status
        self.trustScore = trustScore
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.provider = provider
        self.model = model
        self.changeSignature = changeSignature
        self.baselineRunId = baselineRunId
        self.baselineTrustScore = baselineTrustScore
        self.trustScoreDelta = trustScoreDelta
        self.regression = regression
        self.detail = detail
    }
}

struct BehaviorEvalBaselineComparison: Codable, Equatable, Sendable {
    let baselineRunId: UUID?
    let baselineTrustScore: Int?
    let currentTrustScore: Int
    let trustScoreDelta: Int?
    let isRegression: Bool
}

enum BehaviorEvalBaselineComparator {
    static func compare(
        current: BehaviorEvalRunRecord,
        baseline: BehaviorEvalRunRecord?
    ) -> BehaviorEvalBaselineComparison {
        guard let baseline, baseline.status == .passed else {
            return BehaviorEvalBaselineComparison(
                baselineRunId: nil,
                baselineTrustScore: nil,
                currentTrustScore: current.trustScore,
                trustScoreDelta: nil,
                isRegression: false
            )
        }

        let delta = current.trustScore - baseline.trustScore
        return BehaviorEvalBaselineComparison(
            baselineRunId: baseline.id,
            baselineTrustScore: baseline.trustScore,
            currentTrustScore: current.trustScore,
            trustScoreDelta: delta,
            isRegression: delta < 0 || current.status == .failed
        )
    }
}

enum BehaviorEvalJSONL {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder.behaviorEval.encode(value)
        guard let line = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Behavior eval JSON was not valid UTF-8."
                )
            )
        }
        return line.replacingOccurrences(of: "\n", with: "")
    }
}

extension JSONEncoder {
    static var behaviorEval: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var behaviorEval: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
