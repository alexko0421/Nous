import Foundation

enum CLIBehaviorExperiment {
    enum Metric: String, CaseIterable, Encodable {
        case trust
        case usefulness
        case voice
    }

    struct Options {
        var experimentId: String?
        var mode = "quick"
        var live = "never"
        var resultsDir = "results/behavior_eval"
        var provider: String?
        var model: String?
        var changeSignature: String?
        var expectedImpacts: [Metric] = [.trust]
    }

    struct TrustedBaseline {
        let id: String
        let trustScore: Int
        let results: [CLIBehaviorEval.Result]
    }

    struct MetricDelta: Encodable {
        let metric: Metric
        let beforeScore: Int
        let afterScore: Int
        let delta: Int

        init(metric: Metric, beforeScore: Int, afterScore: Int) {
            self.metric = metric
            self.beforeScore = beforeScore
            self.afterScore = afterScore
            self.delta = afterScore - beforeScore
        }
    }

    struct Record: Encodable {
        let id: String
        let experimentId: String
        let mode: String
        let liveMode: String
        let status: String
        let startedAt: String
        let endedAt: String
        let baselineRunId: String
        let candidateRunId: String
        let beforeTrustScore: Int
        let afterTrustScore: Int
        let trustScoreDelta: Int
        let regression: Bool
        let expectedImpacts: [Metric]
        let metricDeltas: [MetricDelta]
        let changeSignature: String?
        let detail: String
    }
}

struct ExperimentCommandOutcome {
    let detail: String
    let failed: Bool
    let resultsDir: String
}

func runExperimentCommand(_ arguments: [String]) throws -> ExperimentCommandOutcome {
    let options = try parseExperimentOptions(arguments)
    guard let experimentId = nonEmpty(options.experimentId) else {
        throw CLIError.missingValue("--id")
    }

    let provider = resolvedProviderForLiveMode(
        live: options.live,
        explicitProvider: options.provider
    )
    let model = resolvedModelForLiveMode(
        live: options.live,
        provider: provider,
        explicitModel: options.model
    )
    let baseline = try trustedExperimentBaseline(
        resultsDir: options.resultsDir,
        mode: options.mode,
        live: options.live,
        provider: provider,
        model: model
    )
    var evalOptions = CLIBehaviorEval.Options()
    evalOptions.mode = options.mode
    evalOptions.live = options.live
    evalOptions.resultsDir = options.resultsDir
    evalOptions.provider = provider
    evalOptions.model = model
    evalOptions.changeSignature = options.changeSignature

    let candidateResults = try deterministicResults() + liveResults(options: evalOptions)
    let initialStatus = runStatus(candidateResults)
    let candidateTrustScore = trustScore(candidateResults)
    let trustScoreDelta = candidateTrustScore - baseline.trustScore
    let regression = trustScoreDelta < 0 || initialStatus == "failed"
    let candidateStatus = regression ? "failed" : initialStatus
    let candidateRunId = UUID().uuidString.lowercased()
    let endedAt = Date()
    let formatter = ISO8601DateFormatter()
    let detail = experimentDetail(
        experimentId: experimentId,
        status: regression ? "failed" : "passed",
        beforeTrustScore: baseline.trustScore,
        afterTrustScore: candidateTrustScore,
        trustScoreDelta: trustScoreDelta
    )

    let runRecord = CLIBehaviorEval.RunRecord(
        id: candidateRunId,
        mode: options.mode,
        liveMode: options.live,
        status: candidateStatus,
        trustScore: candidateTrustScore,
        startedAt: formatter.string(from: startedAt),
        endedAt: formatter.string(from: endedAt),
        provider: provider,
        model: model,
        changeSignature: options.changeSignature,
        baselineRunId: baseline.id,
        baselineTrustScore: baseline.trustScore,
        trustScoreDelta: trustScoreDelta,
        regression: regression,
        detail: detail
    )
    try persist(run: runRecord, results: candidateResults, resultsDir: options.resultsDir)

    let experimentRecord = CLIBehaviorExperiment.Record(
        id: UUID().uuidString.lowercased(),
        experimentId: experimentId,
        mode: options.mode,
        liveMode: options.live,
        status: regression ? "failed" : "passed",
        startedAt: formatter.string(from: startedAt),
        endedAt: formatter.string(from: endedAt),
        baselineRunId: baseline.id,
        candidateRunId: candidateRunId,
        beforeTrustScore: baseline.trustScore,
        afterTrustScore: candidateTrustScore,
        trustScoreDelta: trustScoreDelta,
        regression: regression,
        expectedImpacts: options.expectedImpacts,
        metricDeltas: experimentMetricDeltas(
            beforeResults: baseline.results,
            beforeTrustScore: baseline.trustScore,
            afterResults: candidateResults,
            afterTrustScore: candidateTrustScore
        ),
        changeSignature: options.changeSignature,
        detail: detail
    )
    let directoryURL = URL(fileURLWithPath: options.resultsDir, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try appendJSONL(experimentRecord, to: directoryURL.appendingPathComponent("experiments.jsonl"))

    return ExperimentCommandOutcome(
        detail: detail,
        failed: regression,
        resultsDir: options.resultsDir
    )
}

func parseExperimentOptions(_ arguments: [String]) throws -> CLIBehaviorExperiment.Options {
    var options = CLIBehaviorExperiment.Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--id":
            options.experimentId = try value(after: argument, in: arguments, index: &index)
        case "--mode":
            options.mode = try value(after: argument, in: arguments, index: &index)
        case "--live":
            options.live = try value(after: argument, in: arguments, index: &index)
        case "--results-dir":
            options.resultsDir = try value(after: argument, in: arguments, index: &index)
        case "--provider":
            options.provider = try normalizedProviderArgument(
                value(after: argument, in: arguments, index: &index)
            )
        case "--model":
            options.model = try normalizedModelArgument(
                value(after: argument, in: arguments, index: &index)
            )
        case "--change-signature":
            options.changeSignature = try value(after: argument, in: arguments, index: &index)
        case "--expected-impact":
            options.expectedImpacts = try parseExperimentMetrics(
                value(after: argument, in: arguments, index: &index)
            )
        case "--help", "-h":
            print("usage: BehaviorEvalRunner experiment --id name --mode quick|full --live never|auto|required [--expected-impact usefulness,voice,trust]")
            exit(0)
        default:
            throw CLIError.invalidArgument(argument)
        }
        index += 1
    }

    guard ["quick", "full"].contains(options.mode) else {
        throw CLIError.invalidArgument("--mode \(options.mode)")
    }
    guard ["never", "auto", "required"].contains(options.live) else {
        throw CLIError.invalidArgument("--live \(options.live)")
    }
    return options
}

func parseExperimentMetrics(_ rawValue: String) throws -> [CLIBehaviorExperiment.Metric] {
    let metrics = try rawValue
        .split(separator: ",")
        .map { rawMetric -> CLIBehaviorExperiment.Metric in
            let value = rawMetric.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let metric = CLIBehaviorExperiment.Metric(rawValue: value) else {
                throw CLIError.invalidArgument("--expected-impact \(value)")
            }
            return metric
        }
    let orderedMetrics = CLIBehaviorExperiment.Metric.allCases.filter { metrics.contains($0) }
    return orderedMetrics.isEmpty ? [.trust] : orderedMetrics
}

func trustedExperimentBaseline(
    resultsDir: String,
    mode: String,
    live: String,
    provider: String?,
    model: String?
) throws -> CLIBehaviorExperiment.TrustedBaseline {
    let baselineDescription = trustedBaselineDescription(
        mode: mode,
        live: live,
        provider: provider,
        model: model
    )
    let url = URL(fileURLWithPath: resultsDir, isDirectory: true)
        .appendingPathComponent("runs.jsonl")
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
        throw CLIError.missingTrustedBaseline(baselineDescription)
    }

    var baseline: (id: String, trustScore: Int)?
    for line in contents.split(separator: "\n") {
        guard let data = String(line).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["mode"] as? String == mode,
              json["liveMode"] as? String == live,
              json["status"] as? String == "passed",
              json["provider"] as? String == provider,
              json["model"] as? String == model,
              let id = json["id"] as? String,
              let trustScore = json["trustScore"] as? Int else {
            continue
        }
        baseline = (id, trustScore)
    }

    guard let baseline else {
        throw CLIError.missingTrustedBaseline(baselineDescription)
    }

    let baselineResults = try caseResults(
        resultsDir: resultsDir,
        runId: baseline.id
    )
    guard !baselineResults.isEmpty else {
        throw CLIError.invalidResponse("missing behavior eval cases for baseline \(baseline.id)")
    }

    return CLIBehaviorExperiment.TrustedBaseline(
        id: baseline.id,
        trustScore: baseline.trustScore,
        results: baselineResults
    )
}

func trustedBaselineDescription(
    mode: String,
    live: String,
    provider: String?,
    model: String?
) -> String {
    let providerValue = provider ?? "mock"
    let modelValue = model ?? "default"
    return "mode=\(mode) live=\(live) provider=\(providerValue) model=\(modelValue)"
}

func caseResults(resultsDir: String, runId: String) throws -> [CLIBehaviorEval.Result] {
    let url = URL(fileURLWithPath: resultsDir, isDirectory: true)
        .appendingPathComponent("cases.jsonl")
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
        throw CLIError.invalidResponse("missing behavior eval cases file")
    }

    var results: [CLIBehaviorEval.Result] = []
    for (lineIndex, line) in contents.split(separator: "\n").enumerated() {
        guard let data = String(line).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lineRunId = json["runId"] as? String else {
            throw CLIError.invalidResponse("behavior eval cases line \(lineIndex + 1)")
        }
        guard lineRunId == runId else {
            continue
        }
        guard let caseId = json["caseId"] as? String,
              let axis = json["axis"] as? String,
              let verdict = json["verdict"] as? String else {
            throw CLIError.invalidResponse("behavior eval cases line \(lineIndex + 1)")
        }
        let findings = try (json["findings"] as? [[String: Any]] ?? []).map { finding -> CLIBehaviorEval.Finding in
            guard let code = finding["code"] as? String,
                  let severity = finding["severity"] as? String,
                  let message = finding["message"] as? String else {
                throw CLIError.invalidResponse("behavior eval finding in cases line \(lineIndex + 1)")
            }
            return CLIBehaviorEval.Finding(
                code: code,
                severity: severity,
                message: message
            )
        }
        results.append(CLIBehaviorEval.Result(
            id: caseId,
            axis: axis,
            verdict: verdict,
            findings: findings,
            provider: json["provider"] as? String,
            model: json["model"] as? String
        ))
    }
    return results
}

func experimentMetricDeltas(
    beforeResults: [CLIBehaviorEval.Result],
    beforeTrustScore: Int,
    afterResults: [CLIBehaviorEval.Result],
    afterTrustScore: Int
) -> [CLIBehaviorExperiment.MetricDelta] {
    CLIBehaviorExperiment.Metric.allCases.map { metric in
        CLIBehaviorExperiment.MetricDelta(
            metric: metric,
            beforeScore: experimentMetricScore(
                results: beforeResults,
                trustScore: beforeTrustScore,
                metric: metric
            ),
            afterScore: experimentMetricScore(
                results: afterResults,
                trustScore: afterTrustScore,
                metric: metric
            )
        )
    }
}

func experimentMetricScore(
    results: [CLIBehaviorEval.Result],
    trustScore: Int,
    metric: CLIBehaviorExperiment.Metric
) -> Int {
    switch metric {
    case .trust:
        return trustScore
    case .usefulness:
        return experimentAxisScore(
            results: results,
            axes: ["source_grounding", "tool_loop", "current_intent", "current_fact_honesty"]
        )
    case .voice:
        return experimentAxisScore(
            results: results,
            axes: ["sycophancy", "provocation", "current_intent"]
        )
    }
}

func experimentAxisScore(
    results: [CLIBehaviorEval.Result],
    axes: Set<String>
) -> Int {
    let filteredResults = results.filter { axes.contains($0.axis) }
    guard !filteredResults.isEmpty else { return 100 }
    return trustScore(filteredResults)
}

func experimentDetail(
    experimentId: String,
    status: String,
    beforeTrustScore: Int,
    afterTrustScore: Int,
    trustScoreDelta: Int
) -> String {
    if status == "failed" {
        return "behavior experiment \(experimentId) failed: trust score \(beforeTrustScore) -> \(afterTrustScore), delta \(trustScoreDelta). Trust regression blocks merge."
    }
    return "behavior experiment \(experimentId) passed: trust score \(beforeTrustScore) -> \(afterTrustScore), delta \(trustScoreDelta)."
}
