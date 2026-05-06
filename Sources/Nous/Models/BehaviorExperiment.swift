import Foundation

enum BehaviorExperimentMetric: String, Codable, CaseIterable, Equatable, Sendable {
    case trust
    case usefulness
    case voice
}

enum BehaviorExperimentStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
}

struct BehaviorExperimentMetricDelta: Codable, Equatable, Sendable {
    let metric: BehaviorExperimentMetric
    let beforeScore: Int
    let afterScore: Int
    let delta: Int

    init(metric: BehaviorExperimentMetric, beforeScore: Int, afterScore: Int) {
        self.metric = metric
        self.beforeScore = beforeScore
        self.afterScore = afterScore
        self.delta = afterScore - beforeScore
    }
}

struct BehaviorExperimentRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let experimentId: String
    let mode: BehaviorEvalMode
    let liveMode: BehaviorEvalLiveMode
    let status: BehaviorExperimentStatus
    let startedAt: Date
    let endedAt: Date
    let baselineRunId: UUID?
    let candidateRunId: UUID?
    let beforeTrustScore: Int
    let afterTrustScore: Int
    let trustScoreDelta: Int
    let regression: Bool
    let expectedImpacts: [BehaviorExperimentMetric]
    let metricDeltas: [BehaviorExperimentMetricDelta]
    let detail: String

    init(
        id: UUID = UUID(),
        experimentId: String,
        mode: BehaviorEvalMode,
        liveMode: BehaviorEvalLiveMode,
        status: BehaviorExperimentStatus,
        startedAt: Date,
        endedAt: Date,
        baselineRunId: UUID? = nil,
        candidateRunId: UUID? = nil,
        beforeTrustScore: Int,
        afterTrustScore: Int,
        trustScoreDelta: Int,
        regression: Bool,
        expectedImpacts: [BehaviorExperimentMetric],
        metricDeltas: [BehaviorExperimentMetricDelta],
        detail: String
    ) {
        self.id = id
        self.experimentId = experimentId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = mode
        self.liveMode = liveMode
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.baselineRunId = baselineRunId
        self.candidateRunId = candidateRunId
        self.beforeTrustScore = beforeTrustScore
        self.afterTrustScore = afterTrustScore
        self.trustScoreDelta = trustScoreDelta
        self.regression = regression
        self.expectedImpacts = expectedImpacts
        self.metricDeltas = metricDeltas
        self.detail = detail
    }

    @discardableResult
    func validated() throws -> BehaviorExperimentRecord {
        guard !experimentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BehaviorExperimentError.blankExperimentId
        }
        guard (0...100).contains(beforeTrustScore),
              (0...100).contains(afterTrustScore) else {
            throw BehaviorExperimentError.invalidTrustScore
        }
        guard endedAt >= startedAt else {
            throw BehaviorExperimentError.invalidDateRange
        }
        guard !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BehaviorExperimentError.blankDetail
        }
        guard trustScoreDelta == afterTrustScore - beforeTrustScore else {
            throw BehaviorExperimentError.invalidTrustScoreDelta
        }
        guard (regression && status == .failed) || (!regression && status == .passed) else {
            throw BehaviorExperimentError.inconsistentRegressionStatus
        }
        guard !expectedImpacts.isEmpty else {
            throw BehaviorExperimentError.emptyExpectedImpacts
        }
        var seenExpectedImpacts: [BehaviorExperimentMetric] = []
        for metric in expectedImpacts {
            guard !seenExpectedImpacts.contains(metric) else {
                throw BehaviorExperimentError.duplicateExpectedImpact(metric)
            }
            seenExpectedImpacts.append(metric)
        }

        var seenMetricDeltas: [BehaviorExperimentMetric] = []
        for metricDelta in metricDeltas {
            guard !seenMetricDeltas.contains(metricDelta.metric) else {
                throw BehaviorExperimentError.duplicateMetricDelta(metricDelta.metric)
            }
            guard (0...100).contains(metricDelta.beforeScore),
                  (0...100).contains(metricDelta.afterScore) else {
                throw BehaviorExperimentError.invalidMetricScore(metricDelta.metric)
            }
            guard metricDelta.delta == metricDelta.afterScore - metricDelta.beforeScore else {
                throw BehaviorExperimentError.invalidMetricDelta(metricDelta.metric)
            }
            seenMetricDeltas.append(metricDelta.metric)
        }
        for metric in BehaviorExperimentMetric.allCases {
            guard seenMetricDeltas.contains(metric) else {
                throw BehaviorExperimentError.missingMetricDelta(metric)
            }
        }
        return self
    }
}

enum BehaviorExperimentError: Error, Equatable {
    case blankExperimentId
    case invalidTrustScore
    case invalidDateRange
    case blankDetail
    case invalidTrustScoreDelta
    case inconsistentRegressionStatus
    case emptyExpectedImpacts
    case duplicateExpectedImpact(BehaviorExperimentMetric)
    case missingMetricDelta(BehaviorExperimentMetric)
    case duplicateMetricDelta(BehaviorExperimentMetric)
    case invalidMetricScore(BehaviorExperimentMetric)
    case invalidMetricDelta(BehaviorExperimentMetric)
}
