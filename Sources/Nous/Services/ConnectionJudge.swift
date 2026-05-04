import Foundation

final class ConnectionJudge {
    func assess(
        source: NousNode,
        target: NousNode,
        similarity: Float,
        verdict: GalaxyRelationVerdict?
    ) -> ConnectionJudgeAssessment {
        guard let verdict else {
            return reject("missing relation verdict")
        }

        guard source.id != target.id else {
            return reject("self connection")
        }

        if verdict.sourceAtomId != nil || verdict.targetAtomId != nil {
            return accept(verdict, reason: "atom-backed relation")
        }

        if verdict.relationKind == .topicSimilarity,
           verdict.explanation.contains("只是语义相似") {
            return ConnectionJudgeAssessment(
                role: .connectionJudge,
                decision: .deferred,
                reason: "generic topic similarity needs stronger evidence",
                verdict: nil
            )
        }

        let hasUsableEvidence = !verdict.sourceEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !verdict.targetEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasUsableEvidence else {
            return reject("missing evidence")
        }

        guard verdict.confidence >= 0.65 || similarity >= 0.86 else {
            return reject("low confidence")
        }

        return accept(verdict, reason: "specific evidence-backed relation")
    }

    private func accept(_ verdict: GalaxyRelationVerdict, reason: String) -> ConnectionJudgeAssessment {
        ConnectionJudgeAssessment(
            role: .connectionJudge,
            decision: .accept,
            reason: reason,
            verdict: verdict
        )
    }

    private func reject(_ reason: String) -> ConnectionJudgeAssessment {
        ConnectionJudgeAssessment(
            role: .connectionJudge,
            decision: .reject,
            reason: reason,
            verdict: nil
        )
    }
}
