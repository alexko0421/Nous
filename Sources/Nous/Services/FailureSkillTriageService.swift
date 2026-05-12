import Foundation

struct FailureSkillTriagePattern: Identifiable, Equatable {
    let signature: FailureSignature
    let repairKind: FailureRepairKind
    let candidateCount: Int
    let readyCount: Int
    let latestAt: Date

    var id: String {
        "\(signature.rawValue):\(repairKind.rawValue)"
    }

    var isRecurring: Bool {
        candidateCount >= 2
    }
}

struct FailureSkillTriageService {
    func triage(_ candidate: FailureSkillCandidate) -> FailureSkillCandidate {
        guard candidate.status != .dismissed,
              candidate.status != .activated else {
            return candidate
        }

        var triaged = candidate
        let draft = draft(for: candidate.signature, repairKind: candidate.repairKind)
        if triaged.proposedSkillPayload == nil {
            triaged.proposedSkillPayload = draft.payload
        }
        triaged.checklist = merge(candidate.checklist, with: draft.checklist)
        return triaged
    }

    func patterns(from candidates: [FailureSkillCandidate]) -> [FailureSkillTriagePattern] {
        let visible = candidates.filter { candidate in
            candidate.status != .dismissed && candidate.sourceKind != .recurringPattern
        }
        let grouped = Dictionary(grouping: visible) { candidate in
            PatternKey(signature: candidate.signature, repairKind: candidate.repairKind)
        }
        return grouped.map { key, rows in
            FailureSkillTriagePattern(
                signature: key.signature,
                repairKind: key.repairKind,
                candidateCount: rows.count,
                readyCount: rows.filter { SkillifyChecklistEvaluator().evaluate($0).canActivate }.count,
                latestAt: rows.map(\.updatedAt).max() ?? .distantPast
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRecurring != rhs.isRecurring {
                return lhs.isRecurring && !rhs.isRecurring
            }
            if lhs.candidateCount != rhs.candidateCount {
                return lhs.candidateCount > rhs.candidateCount
            }
            return lhs.latestAt > rhs.latestAt
        }
    }

    private struct PatternKey: Hashable {
        let signature: FailureSignature
        let repairKind: FailureRepairKind
    }

    private struct Draft {
        let payload: SkillPayload?
        let checklist: SkillifyChecklist
    }

    private func draft(for signature: FailureSignature, repairKind: FailureRepairKind) -> Draft {
        let checklist = checklistDraft(for: signature, repairKind: repairKind)
        guard repairKind == .promptSkill,
              canDraftPromptPayload(for: signature) else {
            return Draft(payload: nil, checklist: checklist)
        }
        return Draft(payload: payloadDraft(for: signature), checklist: checklist)
    }

    private func merge(_ existing: SkillifyChecklist, with draft: SkillifyChecklist) -> SkillifyChecklist {
        SkillifyChecklist(
            rootCause: existing.rootCause ?? draft.rootCause,
            trigger: existing.trigger ?? draft.trigger,
            useWhen: existing.useWhen ?? draft.useWhen,
            antiPatternExample: existing.antiPatternExample ?? draft.antiPatternExample,
            regressionTestReference: existing.regressionTestReference ?? draft.regressionTestReference,
            resolverTestReference: existing.resolverTestReference ?? draft.resolverTestReference,
            smokeTestCommand: existing.smokeTestCommand ?? draft.smokeTestCommand,
            codeReference: existing.codeReference ?? draft.codeReference
        )
    }

    private func checklistDraft(
        for signature: FailureSignature,
        repairKind: FailureRepairKind
    ) -> SkillifyChecklist {
        let template = template(for: signature)
        return SkillifyChecklist(
            rootCause: template.rootCause,
            trigger: template.trigger,
            useWhen: template.useWhen,
            antiPatternExample: template.antiPattern,
            regressionTestReference: template.regressionTestReference,
            resolverTestReference: "SkillMatcherTests.testModeMatchFires",
            smokeTestCommand: smokeCommand(for: template),
            codeReference: repairKind == .deterministicFix ? template.codeReference : nil
        )
    }

    private func canDraftPromptPayload(for signature: FailureSignature) -> Bool {
        switch signature {
        case .judgeFeedbackWrongTiming, .judgeFeedbackTooForceful, .judgeFeedbackTooRepetitive, .judgeFeedbackNotUseful:
            return true
        case .ownCorpusIgnored, .borrowedAuthorityLeakage, .sourceMaterialIgnored, .judgeFeedbackWrongMemory:
            return false
        }
    }

    private func payloadDraft(for signature: FailureSignature) -> SkillPayload? {
        let template = template(for: signature)
        guard let payloadName = template.payloadName,
              let content = template.promptContent else {
            return nil
        }
        return SkillPayload(
            payloadVersion: 1,
            name: payloadName,
            description: template.useWhen,
            useWhen: template.useWhen,
            source: .alex,
            trigger: SkillTrigger(kind: .always, modes: [], priority: template.priority),
            action: SkillAction(kind: .promptFragment, content: content),
            rationale: template.rootCause,
            antiPatternExamples: [template.antiPattern]
        )
    }

    private func smokeCommand(for template: Template) -> String {
        let regressionTarget = onlyTestingTarget(for: template.regressionTestReference)
        let resolverTarget = onlyTestingTarget(for: "SkillMatcherTests.testModeMatchFires")
        return """
        xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:\(regressionTarget) -only-testing:\(resolverTarget) -only-testing:NousTests/SkillifyChecklistEvaluatorTests
        """
    }

    private func onlyTestingTarget(for reference: String) -> String {
        let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "NousTests/\(reference)"
        }
        return "NousTests/\(parts[0])/\(parts[1])"
    }

    private struct Template {
        let payloadName: String?
        let rootCause: String
        let trigger: String
        let useWhen: String
        let antiPattern: String
        let promptContent: String?
        let regressionTestReference: String
        let codeReference: String?
        let priority: Int
    }

    private func template(for signature: FailureSignature) -> Template {
        switch signature {
        case .ownCorpusIgnored:
            return Template(
                payloadName: "own-corpus-before-borrowed-authority",
                rootCause: "Own corpus cards reached the prompt, but the assistant reply did not cite or reuse them.",
                trigger: "own corpus available with zero citation overlap",
                useWhen: "Use when Nous has Alex corpus cards available for a turn.",
                antiPattern: "Answering from generic reasoning while ignoring available Alex corpus.",
                promptContent: "When Alex's own corpus is available, answer from those records before reaching for outside frameworks. If the corpus is weak, say that plainly instead of replacing it with borrowed authority.",
                regressionTestReference: "FailureToSkillDetectorTests.testCorpusIgnoredCreatesPromptSkillCandidate",
                codeReference: nil,
                priority: 50
            )
        case .borrowedAuthorityLeakage:
            return Template(
                payloadName: "borrowed-authority-after-own-corpus",
                rootCause: "The reply named outside frameworks while Alex's own corpus was available.",
                trigger: "borrowed authority hit with own corpus available",
                useWhen: "Use when Nous has Alex corpus cards but starts from outside authorities.",
                antiPattern: "Using Kahneman, Munger, Bezos, or similar names before Alex's own evidence.",
                promptContent: "If Alex's own corpus is available, ground the first pass in that corpus. External authorities may appear only after they clarify, not replace, Alex's evidence.",
                regressionTestReference: "FailureToSkillDetectorTests.testBorrowedAuthorityLeakageCreatesPromptSkillCandidate",
                codeReference: nil,
                priority: 50
            )
        case .sourceMaterialIgnored:
            return Template(
                payloadName: "source-analysis-use-attached-material",
                rootCause: "Source material was loaded into the turn manifest but was not used by the assistant reply.",
                trigger: "source material loaded but unused",
                useWhen: "Use when Alex attaches source material and expects source-first analysis.",
                antiPattern: "Answering the user without grounding in the attached source.",
                promptContent: "When source material is attached, inspect and use it before general reasoning. Mention the source basis explicitly, and avoid generic advice until the attached material has been addressed.",
                regressionTestReference: "FailureToSkillDetectorTests.testSourceMaterialIgnoredCreatesPromptSkillCandidate",
                codeReference: nil,
                priority: 55
            )
        case .judgeFeedbackWrongMemory:
            return Template(
                payloadName: nil,
                rootCause: "Alex marked the judge intervention as using the wrong memory.",
                trigger: "thumbs-down judge feedback with wrong_memory reason",
                useWhen: "Use when a judge event was downvoted because the memory was wrong or irrelevant.",
                antiPattern: "Turning an irrelevant memory into a challenge.",
                promptContent: nil,
                regressionTestReference: "ProvocationOrchestrationTests.testChangingFeedbackReasonClearsPreviousResponseBehaviorLearningPattern",
                codeReference: "Judge feedback wrong-memory path requires a deterministic fix or regression-only patch.",
                priority: 45
            )
        case .judgeFeedbackWrongTiming:
            return Template(
                payloadName: "judge-feedback-wrong-timing",
                rootCause: "Alex marked the judge intervention as arriving at the wrong moment.",
                trigger: "thumbs-down judge feedback with wrong_timing reason",
                useWhen: "Use when judge feedback says tension surfaced at the wrong time.",
                antiPattern: "Challenging a support-seeking turn because a related memory exists.",
                promptContent: "Before surfacing tension, check whether this turn is asking for analysis or emotional steadiness. If the turn is mainly support-seeking, keep the judge silent.",
                regressionTestReference: "ProvocationOrchestrationTests.testDownvoteFeedbackDetailCreatesFailureSkillCandidate",
                codeReference: nil,
                priority: 45
            )
        case .judgeFeedbackTooForceful:
            return Template(
                payloadName: "judge-feedback-too-forceful",
                rootCause: "Alex marked the judge intervention as too forceful.",
                trigger: "thumbs-down judge feedback with too_forceful reason",
                useWhen: "Use when judge feedback says the challenge was too forceful.",
                antiPattern: "Turning a small concern into a hard verdict.",
                promptContent: "Surface tension in a lower-pressure way: name the uncertainty, offer one concrete counterpoint, and avoid prosecutorial framing.",
                regressionTestReference: "ProvocationOrchestrationTests.testDownvoteFeedbackDetailCreatesFailureSkillCandidate",
                codeReference: nil,
                priority: 45
            )
        case .judgeFeedbackTooRepetitive:
            return Template(
                payloadName: "judge-feedback-too-repetitive",
                rootCause: "Alex marked the judge intervention as repetitive.",
                trigger: "thumbs-down judge feedback with too_repetitive reason",
                useWhen: "Use when judge feedback says a repeated pattern was overused.",
                antiPattern: "Repeating the same correction because it was once useful.",
                promptContent: "Do not reuse the same challenge pattern unless the current turn adds new evidence. Prefer a fresh concrete observation or stay quiet.",
                regressionTestReference: "ProvocationOrchestrationTests.testDownvoteFeedbackDetailCreatesFailureSkillCandidate",
                codeReference: nil,
                priority: 45
            )
        case .judgeFeedbackNotUseful:
            return Template(
                payloadName: "judge-feedback-not-useful",
                rootCause: "Alex marked the judge intervention as not useful.",
                trigger: "thumbs-down judge feedback with not_useful reason",
                useWhen: "Use when judge feedback says an intervention was not useful.",
                antiPattern: "Adding a thoughtful-sounding caveat that does not change the answer.",
                promptContent: "Before adding a judge intervention, ask whether it changes the next action. If not, answer the user's immediate question directly.",
                regressionTestReference: "ProvocationOrchestrationTests.testDownvoteFeedbackDetailCreatesFailureSkillCandidate",
                codeReference: nil,
                priority: 45
            )
        }
    }
}
