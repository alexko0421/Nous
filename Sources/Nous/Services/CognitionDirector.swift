import Foundation

final class CognitionDirector {
    func frame(
        plan: TurnPlan,
        committed: CommittedAssistantTurn,
        reviewArtifact: CognitionArtifact?,
        reviewerFailed: Bool = false
    ) -> CognitionFrame {
        let records = [
            stewardRecord(plan),
            memoryRecord(plan),
            skillRecord(plan),
            judgeRecord(plan),
            patternNamingRecord(plan),
            reflectiveMeaningRecord(plan),
            slowCognitionRecord(plan),
            agentLoopRecord(plan),
            reviewerRecord(reviewArtifact, reviewerFailed: reviewerFailed)
        ]

        let frame = CognitionFrame(
            turnId: plan.turnId,
            conversationId: committed.node.id,
            assistantMessageId: committed.assistantMessage.id,
            records: records.compactMap { try? $0.validated() }
        )
        return (try? frame.validated()) ?? CognitionFrame(
            turnId: plan.turnId,
            conversationId: committed.node.id,
            assistantMessageId: committed.assistantMessage.id,
            records: []
        )
    }

    private func stewardRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        let reason = plan.promptTrace.turnSteward.map { trace in
            var parts = [
                "turn_steward_trace_available",
                "route:\(trace.route.rawValue)",
                "memory:\(trace.memoryPolicy.rawValue)",
                "source:\(trace.source.rawValue)"
            ]
            if let routerSource = trace.routerSource {
                parts.append("router:\(routerSource.rawValue)")
            }
            if trace.fallbackUsed == true {
                parts.append("fallback_used")
            }
            return parts.joined(separator: " ")
        } ?? "turn_steward_trace_missing"

        return CognitionOrganRecord(
            organ: .coordinator,
            label: "turn_steward",
            status: .used,
            reason: reason
        )
    }

    private func memoryRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        let resourceIds =
            plan.memoryEvidenceSourceIds.map { "memory_evidence:\($0.uuidString)" } +
            plan.loadedCitationIds.map { "citation:\($0.uuidString)" } +
            plan.memoryProvenance.keys.sorted().map { "memory_provenance:\($0)" }
        let used = plan.promptTrace.hasMemorySignal || !resourceIds.isEmpty

        return CognitionOrganRecord(
            organ: .coordinator,
            label: "memory_retriever",
            status: used ? .used : .skipped,
            reason: used ? "memory_signal_present" : "no_memory_signal",
            resourceIds: resourceIds
        )
    }

    private func skillRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        let resourceIds =
            plan.indexedSkillIds.map { "skill:\($0.uuidString)" } +
            plan.loadedSkillIds.map { "loaded_skill:\($0.uuidString)" }

        return CognitionOrganRecord(
            organ: .singleTurnToolLoop,
            label: "skill_fold",
            status: resourceIds.isEmpty ? .skipped : .used,
            reason: resourceIds.isEmpty ? "no_skills_matched_or_loaded" : "skills_available",
            resourceIds: resourceIds
        )
    }

    private func judgeRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        let fallback = plan.judgeEventDraft?.fallbackReason
        let status: CognitionOrganStatus = switch fallback {
        case .ok:
            .used
        case .timeout, .apiError, .badJSON, .unknownEntryId:
            .failed
        case .providerLocal, .judgeUnavailable, nil:
            .skipped
        }

        return CognitionOrganRecord(
            organ: .reviewer,
            label: "provocation_judge",
            status: status,
            reason: fallback?.rawValue ?? "judge_event_missing"
        )
    }

    private func slowCognitionRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        guard let trace = plan.promptTrace.slowCognitionTrace else {
            return CognitionOrganRecord(
                organ: .patternAnalyst,
                label: "slow_cognition",
                status: .skipped,
                reason: "no_slow_cognition_trace"
            )
        }

        return CognitionOrganRecord(
            organ: trace.organ,
            label: "slow_cognition",
            status: .used,
            reason: "slow_cognition_attached",
            resourceIds: ["artifact:\(trace.artifactId.uuidString)"] +
                trace.evidenceRefIds.map { "evidence:\($0)" }
        )
    }

    private func patternNamingRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        guard let signal = plan.promptTrace.turnSteward?.inTurnPatternSignal else {
            return CognitionOrganRecord(
                organ: .patternAnalyst,
                label: "in_turn_pattern_naming",
                status: .skipped,
                reason: "no_pattern_signal"
            )
        }

        let patternId = "pattern:\(signal.kind.rawValue)"
        let reasonCode = sanitizedMachineReasonCode(signal.reasonCode)
        return CognitionOrganRecord(
            organ: .patternAnalyst,
            label: "in_turn_pattern_naming",
            status: .used,
            reason: "\(patternId) reason:\(reasonCode)",
            resourceIds: [patternId]
        )
    }

    private func reflectiveMeaningRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        guard let signal = plan.promptTrace.turnSteward?.reflectiveMeaningSignal else {
            return CognitionOrganRecord(
                organ: .meaningAnalyst,
                label: "reflective_meaning_signal",
                status: .skipped,
                reason: "no_reflective_meaning_signal"
            )
        }

        let reasonCode = sanitizedMachineReasonCode(signal.reasonCode)
        return CognitionOrganRecord(
            organ: .meaningAnalyst,
            label: "reflective_meaning_signal",
            status: .used,
            reason: "surface:\(signal.surfacePolicy.rawValue) reason:\(reasonCode)"
        )
    }

    private func sanitizedMachineReasonCode(_ reasonCode: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let isMachineCode = !reasonCode.isEmpty
            && reasonCode.count <= 80
            && reasonCode.unicodeScalars.allSatisfy { allowed.contains($0) }
        return isMachineCode ? reasonCode : "invalid_reason_code"
    }

    private func agentLoopRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        let coordination = plan.promptTrace.agentCoordination
        let used = coordination?.executionMode == .toolLoop

        return CognitionOrganRecord(
            organ: .singleTurnToolLoop,
            label: "agent_loop",
            status: used ? .used : .skipped,
            reason: coordination?.reason.rawValue ?? "agent_coordination_missing",
            resourceIds: plan.indexedSkillIds.map { "skill:\($0.uuidString)" }
        )
    }

    private func reviewerRecord(_ artifact: CognitionArtifact?, reviewerFailed: Bool) -> CognitionOrganRecord {
        guard let artifact else {
            if reviewerFailed {
                return CognitionOrganRecord(
                    organ: .reviewer,
                    label: "reviewer",
                    status: .failed,
                    reason: "silent_review_failed"
                )
            }
            return CognitionOrganRecord(
                organ: .reviewer,
                label: "reviewer",
                status: .skipped,
                reason: "no_review_artifact"
            )
        }

        return CognitionOrganRecord(
            organ: .reviewer,
            label: "reviewer",
            status: .used,
            reason: "silent_review_artifact",
            resourceIds: ["artifact:\(artifact.id.uuidString)"],
            riskFlags: artifact.riskFlags
        )
    }
}
