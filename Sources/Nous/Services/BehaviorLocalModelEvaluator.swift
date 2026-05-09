import Foundation

enum BehaviorLocalModelEvaluator {
    static func annotate(
        results: [BehaviorEvalResult],
        model: String
    ) -> [BehaviorEvalResult] {
        results.map { result in
            BehaviorEvalResult(
                id: result.id,
                axis: result.axis,
                verdict: result.verdict,
                findings: result.findings,
                provider: .local,
                model: model,
                durationMilliseconds: result.durationMilliseconds
            )
        }
    }

    static func makeRunRecord(
        mode: BehaviorEvalMode,
        liveMode: BehaviorEvalLiveMode,
        results: [BehaviorEvalResult],
        model: String,
        startedAt: Date,
        endedAt: Date,
        changeSignature: String? = nil
    ) -> BehaviorEvalRunRecord {
        let summary = BehaviorEvalSummary(
            results: resultsWithLocalGenerationCoverage(
                results,
                liveMode: liveMode,
                model: model
            )
        )
        return BehaviorEvalRunRecord(
            mode: mode,
            liveMode: liveMode,
            status: status(for: summary),
            trustScore: summary.trustScore,
            startedAt: startedAt,
            endedAt: endedAt,
            provider: .local,
            model: model,
            changeSignature: changeSignature,
            detail: "Local model behavior eval \(status(for: summary).rawValue) with trust score \(summary.trustScore)."
        )
    }

    private static func resultsWithLocalGenerationCoverage(
        _ results: [BehaviorEvalResult],
        liveMode: BehaviorEvalLiveMode,
        model: String
    ) -> [BehaviorEvalResult] {
        if results.contains(where: { $0.axis == .liveGeneration }) {
            return results
        }

        var results = results
        results.append(
            BehaviorEvalResult(
                id: "local_generation_not_exercised",
                axis: .liveGeneration,
                verdict: liveMode == .required ? .failure : .warning,
                findings: [
                    BehaviorEvalFinding(
                        code: "local_generation_not_exercised",
                        severity: liveMode == .required ? .failure : .warning,
                        message: "This local-model run only covered deterministic harness signals; no local generation result was recorded, so the model is not proven trusted."
                    )
                ],
                provider: .local,
                model: model
            )
        )
        return results
    }

    private static func status(for summary: BehaviorEvalSummary) -> BehaviorEvalRunStatus {
        switch summary.verdict {
        case .pass:
            return .passed
        case .warning:
            return .warning
        case .failure:
            return .failed
        }
    }
}
