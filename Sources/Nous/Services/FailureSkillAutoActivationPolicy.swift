import Foundation

struct FailureSkillAutoActivationPolicy {
    let isEnabled: Bool
    var evaluator = SkillifyChecklistEvaluator()

    func canAutoActivate(
        candidate: FailureSkillCandidate,
        latestRun: FailureSkillRepairRun?
    ) -> Bool {
        guard isEnabled,
              candidate.status == .approved,
              candidate.sourceKind == .judgeFeedback,
              candidate.repairKind == .promptSkill,
              candidate.activatedSkillId == nil,
              latestRun?.status.isActive != true,
              candidate.signature.isLowRiskJudgeFeedbackPostureSkill,
              evaluator.evaluate(candidate).canActivate else {
            return false
        }

        return true
    }
}

extension FailureSignature {
    var isLowRiskJudgeFeedbackPostureSkill: Bool {
        switch self {
        case .judgeFeedbackWrongTiming,
             .judgeFeedbackTooForceful,
             .judgeFeedbackTooRepetitive,
             .judgeFeedbackNotUseful:
            return true
        case .judgeFeedbackWrongMemory,
             .ownCorpusIgnored,
             .borrowedAuthorityLeakage,
             .sourceMaterialIgnored:
            return false
        }
    }
}
