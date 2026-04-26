import Foundation

/// Validates raw JSON produced by `GeminiLLMService.generateStructured` for the
/// WeeklyReflectionService prompt. Pure function — no IO, no side effects —
/// so the orchestrator can decide whether to persist active rows or a
/// rejected_all run based solely on the return value.
///
/// Three kinds of rejection feed back into `ReflectionRun.rejectionReason`:
///   - `.generic`: Gemini returned `{"claims": []}`. Working as designed.
///   - `.lowConfidence`: all claims had confidence < 0.5.
///   - `.unsupported`: all claims had fewer than 2 grounded supporting turn IDs
///     (ids that actually appear in the week's message set).
///
/// Schema-shape errors (missing `claims` key, wrong types) are not rejections —
/// those throw `ValidationError.malformed` so the caller can record a
/// `.failed` run instead.
enum ReflectionValidator {

    /// Minimum supporting turns required after grounding. Matches prompt rule
    /// and Codex R3 / design doc §schema.
    static let minGroundedTurns = 2

    /// Confidence below this is treated as the model not endorsing its own
    /// claim. Matches prompt rule (`confidence below 0.5 means you're not
    /// confident`).
    static let minConfidence = 0.5

    enum ValidationError: Error, Equatable {
        case malformed(String)
    }

    struct Output: Equatable {
        let claims: [ReflectionClaim]
        let rejectionReason: ReflectionRejectionReason?
    }

    /// - Parameters:
    ///   - rawJSON: text of Gemini's structured response.
    ///   - validMessageIds: the set of message IDs that were present in the
    ///     fixture passed to Gemini. Supporting turn IDs outside this set are
    ///     filtered out (the model hallucinated them).
    ///   - messageIdToNodeId: maps each message ID to its conversation node UUID.
    ///     Used to enforce the distinct-conversation rule: evidence must span
    ///     ≥2 distinct nodeIds. Pass `[:]` to defer resolution to Task 8.
    ///   - runId: the `ReflectionRun.id` these claims belong to.
    ///   - now: injected for deterministic tests.
    static func validate(
        rawJSON: String,
        validMessageIds: Set<String>,
        messageIdToNodeId: [String: UUID],
        runId: UUID,
        now: Date = Date()
    ) throws -> Output {
        let data = Data(rawJSON.utf8)
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ValidationError.malformed("JSON decode failed: \(error.localizedDescription)")
        }

        // Empty claims array is a valid prompt outcome (`{"claims": []}`).
        if envelope.claims.isEmpty {
            return Output(claims: [], rejectionReason: .generic)
        }

        var passed: [ReflectionClaim] = []
        var droppedForLowConfidence = 0
        var droppedForUngrounded = 0
        var droppedForSingleConversation = 0

        for raw in envelope.claims {
            let trimmed = raw.claim.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if raw.confidence < minConfidence {
                droppedForLowConfidence += 1
                continue
            }

            let grounded = raw.supporting_turn_ids.filter { validMessageIds.contains($0) }
            if grounded.count < minGroundedTurns {
                droppedForUngrounded += 1
                continue
            }

            // Deduplicate while preserving first-occurrence order — the model
            // occasionally cites the same turn twice.
            var seen = Set<String>()
            let deduped = grounded.filter { id in
                if seen.contains(id) { return false }
                seen.insert(id)
                return true
            }
            if deduped.count < minGroundedTurns {
                droppedForUngrounded += 1
                continue
            }

            // Distinct-conversation rule: evidence must span ≥2 distinct
            // conversation nodeIds. A claim grounded only in a single
            // conversation is not a cross-session pattern.
            let distinctNodeIds = Set(deduped.compactMap { messageIdToNodeId[$0] })
            if distinctNodeIds.count < 2 {
                droppedForSingleConversation += 1
                continue
            }

            let clampedConfidence = max(0.0, min(1.0, raw.confidence))

            passed.append(ReflectionClaim(
                runId: runId,
                claim: trimmed,
                confidence: clampedConfidence,
                whyNonObvious: raw.why_non_obvious.trimmingCharacters(in: .whitespacesAndNewlines),
                status: .active,
                createdAt: now
            ))
        }

        if !passed.isEmpty {
            return Output(claims: passed, rejectionReason: nil)
        }

        // All claims dropped — pick the dominant reason.
        // Order: lowConfidence > ungrounded > singleConversationEvidence.
        let reason: ReflectionRejectionReason
        if droppedForLowConfidence >= droppedForUngrounded && droppedForLowConfidence >= droppedForSingleConversation {
            reason = .lowConfidence
        } else if droppedForUngrounded >= droppedForSingleConversation {
            reason = .unsupported
        } else {
            reason = .singleConversationEvidence
        }
        return Output(claims: [], rejectionReason: reason)
    }

    // MARK: - Wire format

    /// Intermediate shape matching the Gemini JSON output exactly. Field names
    /// use snake_case to match the prompt's schema literally; Swift sites map
    /// these onto `ReflectionClaim`'s camelCase properties.
    private struct Envelope: Decodable {
        let claims: [RawClaim]
    }

    private struct RawClaim: Decodable {
        let claim: String
        let confidence: Double
        let supporting_turn_ids: [String]
        let why_non_obvious: String
    }
}
