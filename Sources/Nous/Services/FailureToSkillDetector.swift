import Foundation

struct FailureToSkillDetector {
    private let userId: String
    private let now: () -> Date

    init(userId: String = "alex", now: @escaping () -> Date = Date.init) {
        self.userId = userId
        self.now = now
    }

    func candidates(
        corpusFidelity: CorpusFidelityRecord?,
        contextManifest: ContextManifestRecord?
    ) -> [FailureSkillCandidate] {
        var candidates: [FailureSkillCandidate] = []
        var signatures = Set<FailureSignature>()

        if let corpusFidelity {
            for candidate in corpusCandidates(from: corpusFidelity) where signatures.insert(candidate.signature).inserted {
                candidates.append(candidate)
            }
        }

        if let contextManifest {
            for candidate in manifestCandidates(from: contextManifest) where signatures.insert(candidate.signature).inserted {
                candidates.append(candidate)
            }
        }

        return candidates
    }

    func candidate(from event: JudgeEvent) -> FailureSkillCandidate? {
        guard event.userFeedback == .down else { return nil }
        let signature = signature(for: event.feedbackReason)
        let repairKind = repairKind(for: event.feedbackReason, note: event.feedbackNote)
        let timestamp = now()
        return FailureSkillCandidate(
            id: UUID(),
            userId: userId,
            sourceKind: .judgeFeedback,
            sourceId: event.id.uuidString,
            turnId: nil,
            conversationId: event.nodeId,
            assistantMessageId: event.messageId,
            signature: signature,
            repairKind: repairKind,
            status: .proposed,
            evidence: judgeEvidence(from: event),
            proposedSkillPayload: repairKind == .promptSkill ? proposedPayload(for: signature) : nil,
            checklist: checklist(for: signature, repairKind: repairKind),
            createdAt: timestamp,
            updatedAt: timestamp,
            activatedSkillId: nil
        )
    }

    private func corpusCandidates(from record: CorpusFidelityRecord) -> [FailureSkillCandidate] {
        guard record.ownCorpusAvailableCount > 0 else { return [] }
        var candidates: [FailureSkillCandidate] = []
        let timestamp = now()

        if record.ownCorpusCitationRate == 0 {
            candidates.append(FailureSkillCandidate(
                id: UUID(),
                userId: userId,
                sourceKind: .corpusFidelity,
                sourceId: record.id.uuidString,
                turnId: record.turnId,
                conversationId: record.conversationId,
                assistantMessageId: record.assistantMessageId,
                signature: .ownCorpusIgnored,
                repairKind: .promptSkill,
                status: .proposed,
                evidence: [
                    FailureSkillEvidence(source: .telemetry, id: "available:\(record.ownCorpusAvailableCount)", label: "available own-corpus cards"),
                    FailureSkillEvidence(source: .telemetry, id: "cited:\(record.ownCorpusCitedIds.count)", label: "own-corpus cards cited")
                ],
                proposedSkillPayload: nil,
                checklist: SkillifyChecklist(
                    rootCause: "Own corpus cards reached the prompt, but the assistant reply did not cite or reuse them.",
                    trigger: "own corpus available with zero citation overlap",
                    useWhen: "Use when Nous has Alex corpus cards available for a turn.",
                    antiPatternExample: "Answering from generic reasoning while ignoring available Alex corpus.",
                    regressionTestReference: "FailureToSkillDetectorTests.testCorpusIgnoredCreatesPromptSkillCandidate",
                    resolverTestReference: nil,
                    smokeTestCommand: nil
                ),
                createdAt: timestamp,
                updatedAt: timestamp,
                activatedSkillId: nil
            ))
        }

        if !record.borrowedAuthorityHits.isEmpty {
            candidates.append(FailureSkillCandidate(
                id: UUID(),
                userId: userId,
                sourceKind: .corpusFidelity,
                sourceId: record.id.uuidString,
                turnId: record.turnId,
                conversationId: record.conversationId,
                assistantMessageId: record.assistantMessageId,
                signature: .borrowedAuthorityLeakage,
                repairKind: .promptSkill,
                status: .proposed,
                evidence: record.borrowedAuthorityHits.map {
                    FailureSkillEvidence(source: .telemetry, id: $0, label: "borrowed authority hit")
                },
                proposedSkillPayload: nil,
                checklist: SkillifyChecklist(
                    rootCause: "The reply named outside frameworks while Alex's own corpus was available.",
                    trigger: "borrowed authority hit with own corpus available",
                    useWhen: "Use when Nous has Alex corpus cards but starts from outside authorities.",
                    antiPatternExample: "Using Kahneman, Munger, or similar names before Alex's own evidence.",
                    regressionTestReference: "FailureToSkillDetectorTests.testBorrowedAuthorityLeakageCreatesPromptSkillCandidate",
                    resolverTestReference: nil,
                    smokeTestCommand: nil
                ),
                createdAt: timestamp,
                updatedAt: timestamp,
                activatedSkillId: nil
            ))
        }

        return candidates
    }

    private func manifestCandidates(from record: ContextManifestRecord) -> [FailureSkillCandidate] {
        let loadedSourceMaterials = record.resources.filter { resource in
            resource.source == .sourceMaterial && resource.state == .loaded
        }
        guard !loadedSourceMaterials.isEmpty,
              !loadedSourceMaterials.contains(where: \.used) else {
            return []
        }

        let ignoredSourceIds = Array(Set(loadedSourceMaterials.compactMap { resource -> String? in
            guard resource.source == .sourceMaterial,
                  resource.state == .loaded,
                  !resource.used else {
                return nil
            }
            return resource.referenceId
        })).sorted()
        guard !ignoredSourceIds.isEmpty else { return [] }

        let timestamp = now()
        return [
            FailureSkillCandidate(
                id: UUID(),
                userId: userId,
                sourceKind: .contextManifest,
                sourceId: record.id.uuidString,
                turnId: record.turnId,
                conversationId: record.conversationId,
                assistantMessageId: record.assistantMessageId,
                signature: .sourceMaterialIgnored,
                repairKind: .promptSkill,
                status: .proposed,
                evidence: ignoredSourceIds.map {
                    FailureSkillEvidence(source: .contextManifest, id: $0, label: "unused source material")
                },
                proposedSkillPayload: nil,
                checklist: SkillifyChecklist(
                    rootCause: "Source material was loaded into the turn manifest but was not used by the assistant reply.",
                    trigger: "source material loaded but unused",
                    useWhen: "Use when Alex attaches source material and expects source-first analysis.",
                    antiPatternExample: "Answering the user without grounding in the attached source.",
                    regressionTestReference: "FailureToSkillDetectorTests.testSourceMaterialIgnoredCreatesPromptSkillCandidate",
                    resolverTestReference: nil,
                    smokeTestCommand: nil
                ),
                createdAt: timestamp,
                updatedAt: timestamp,
                activatedSkillId: nil
            )
        ]
    }

    private func signature(for reason: JudgeFeedbackReason?) -> FailureSignature {
        switch reason {
        case .wrongMemory:
            return .judgeFeedbackWrongMemory
        case .wrongTiming:
            return .judgeFeedbackWrongTiming
        case .tooForceful:
            return .judgeFeedbackTooForceful
        case .tooRepetitive:
            return .judgeFeedbackTooRepetitive
        case .notUseful, .none:
            return .judgeFeedbackNotUseful
        }
    }

    private func repairKind(for reason: JudgeFeedbackReason?, note: String?) -> FailureRepairKind {
        if let override = repairKindOverride(from: note) {
            return override
        }
        switch reason {
        case .wrongMemory:
            return .deterministicFix
        case .wrongTiming, .tooForceful, .tooRepetitive, .notUseful, .none:
            return .promptSkill
        }
    }

    private func repairKindOverride(from note: String?) -> FailureRepairKind? {
        let normalized = (note ?? "").lowercased()
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if normalized.contains("regression only")
            || normalized.contains("regression-only")
            || normalized.contains("test only")
            || normalized.contains("only test") {
            return .regressionOnly
        }
        if normalized.contains("deterministic")
            || normalized.contains("patch code")
            || normalized.contains("code fix")
            || normalized.contains("fix in code") {
            return .deterministicFix
        }
        return nil
    }

    private func judgeEvidence(from event: JudgeEvent) -> [FailureSkillEvidence] {
        var evidence = [
            FailureSkillEvidence(source: .judgeEvent, id: event.id.uuidString, label: event.feedbackReason?.rawValue ?? "downvote")
        ]
        if let messageId = event.messageId {
            evidence.append(FailureSkillEvidence(source: .assistantMessage, id: messageId.uuidString, label: "assistant message"))
        }
        if let note = event.feedbackNote {
            evidence.append(FailureSkillEvidence(source: .userFeedback, id: "note", label: "feedback note", snippet: note))
        }
        return evidence
    }

    private func proposedPayload(for signature: FailureSignature) -> SkillPayload? {
        switch signature {
        case .judgeFeedbackWrongTiming:
            return promptSkillPayload(
                name: "judge-feedback-wrong-timing",
                useWhen: "Use when judge feedback says tension surfaced at the wrong time.",
                content: "Before surfacing tension, check whether this turn is asking for analysis or emotional steadiness. If the turn is mainly support-seeking, keep the judge silent.",
                antiPattern: "Challenging a support-seeking turn because a related memory exists."
            )
        case .judgeFeedbackTooForceful:
            return promptSkillPayload(
                name: "judge-feedback-too-forceful",
                useWhen: "Use when judge feedback says the challenge was too forceful.",
                content: "Surface tension in a lower-pressure way: name the uncertainty, offer one concrete counterpoint, and avoid prosecutorial framing.",
                antiPattern: "Turning a small concern into a hard verdict."
            )
        case .judgeFeedbackTooRepetitive:
            return promptSkillPayload(
                name: "judge-feedback-too-repetitive",
                useWhen: "Use when judge feedback says a repeated pattern was overused.",
                content: "Do not reuse the same challenge pattern unless the current turn adds new evidence. Prefer a fresh concrete observation or stay quiet.",
                antiPattern: "Repeating the same correction because it was once useful."
            )
        case .judgeFeedbackNotUseful:
            return promptSkillPayload(
                name: "judge-feedback-not-useful",
                useWhen: "Use when judge feedback says an intervention was not useful.",
                content: "Before adding a judge intervention, ask whether it changes the next action. If not, answer the user's immediate question directly.",
                antiPattern: "Adding a thoughtful-sounding caveat that does not change the answer."
            )
        case .ownCorpusIgnored, .borrowedAuthorityLeakage, .sourceMaterialIgnored, .judgeFeedbackWrongMemory:
            return nil
        }
    }

    private func promptSkillPayload(
        name: String,
        useWhen: String,
        content: String,
        antiPattern: String
    ) -> SkillPayload {
        SkillPayload(
            payloadVersion: 1,
            name: name,
            description: useWhen,
            useWhen: useWhen,
            source: .alex,
            trigger: SkillTrigger(kind: .always, modes: [], priority: 45),
            action: SkillAction(kind: .promptFragment, content: content),
            rationale: "Generated from explicit thumbs-down judge feedback.",
            antiPatternExamples: [antiPattern]
        )
    }

    private func checklist(
        for signature: FailureSignature,
        repairKind: FailureRepairKind
    ) -> SkillifyChecklist {
        SkillifyChecklist(
            rootCause: signature.displayName,
            trigger: "explicit thumbs-down feedback",
            useWhen: "Use when similar judge feedback appears in dogfood.",
            antiPatternExample: "Repeating a judge behavior Alex already downvoted.",
            regressionTestReference: nil,
            resolverTestReference: nil,
            smokeTestCommand: nil,
            codeReference: repairKind == .deterministicFix ? "judge feedback wrong-memory path" : nil
        )
    }
}
