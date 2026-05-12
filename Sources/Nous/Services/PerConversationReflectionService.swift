import Foundation

/// Manual-trigger per-conversation reflection. Runs `PerConversationReflectionPrompt`
/// against a single conversation's transcript on Gemini 2.5 Pro, validates the
/// result via `ReflectionValidator`, and persists the run + claim + evidence
/// scoped to the source conversation via `ReflectionRun.nodeId`.
///
/// The conversation-scoping is the load-bearing invariant: claims phrased as
/// "in this conversation, you ..." MUST NOT leak into retrieval for other
/// conversations. `NodeStore.fetchActiveReflectionClaims(currentNodeId:)`
/// enforces this by filtering on `r.node_id IS NULL OR r.node_id = ?`, so
/// per-conv claims surface only when the user is back in the source chat.
///
/// This service mirrors `WeeklyReflectionService` deliberately so that future
/// wiring (auto-trigger after N turns, per-project rollup, etc.) can lift the
/// fixture/encoder/validator pipeline wholesale.
final class PerConversationReflectionService {

    enum ServiceError: Error, LocalizedError {
        case notEnoughMessages(count: Int, minimum: Int)
        case llmFailure(Error)
        case validatorMalformed(String)

        var errorDescription: String? {
            switch self {
            case .notEnoughMessages(let count, let minimum):
                return "Not enough turns in this conversation (\(count) < \(minimum))."
            case .llmFailure(let inner):
                return "Gemini call failed: \(inner.localizedDescription)."
            case .validatorMalformed(let detail):
                return "Validator could not decode Gemini output: \(detail)"
            }
        }
    }

    struct Output {
        let claim: ReflectionClaim?
        let rejectionReason: ReflectionRejectionReason?
        let costCents: Int
    }

    /// Manual-trigger floor. Below this we don't burn a Gemini call — a 1-turn
    /// "hi" chat has nothing to pattern-match. Lower than
    /// `PerConversationReflectionPrompt.defaultMinimumTurnCount` (16, designed
    /// for auto-fire) because manual = user explicitly asked, so we trust
    /// their judgment but still reject genuinely empty conversations.
    static let manualTriggerMinimumTurns = 4

    private let nodeStore: NodeStore
    private let llm: StructuredLLMClient
    private let now: () -> Date

    init(
        nodeStore: NodeStore,
        llm: StructuredLLMClient,
        now: @escaping () -> Date = Date.init
    ) {
        self.nodeStore = nodeStore
        self.llm = llm
        self.now = now
    }

    convenience init(
        nodeStore: NodeStore,
        llm: GeminiLLMService,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            nodeStore: nodeStore,
            llm: GeminiStructuredLLMAdapter(service: llm),
            now: now
        )
    }

    /// Run reflection on one conversation's messages and persist the result.
    /// LLM/validator failures still persist a `.failed` run row so debug
    /// inspectors can see the attempt happened. The Output `claim` is non-nil
    /// only when validation produced an active claim.
    func run(
        conversationId: UUID,
        conversationTitle: String,
        projectId: UUID?,
        messages: [Message]
    ) async throws -> Output {
        guard messages.count >= Self.manualTriggerMinimumTurns else {
            throw ServiceError.notEnoughMessages(
                count: messages.count,
                minimum: Self.manualTriggerMinimumTurns
            )
        }

        let runId = UUID()
        let startedAt = now()
        let validMessageIds = Set(messages.map { $0.id.uuidString })
        let fixtureJSON = try encodeFixture(
            conversationId: conversationId,
            conversationTitle: conversationTitle,
            messages: messages
        )

        let rawText: String
        let usage: GeminiUsageMetadata?
        do {
            let userMessage = LLMMessage(
                role: "user",
                content: "Conversation:\n\n\(fixtureJSON)"
            )
            (rawText, usage) = try await llm.generateStructured(
                messages: [userMessage],
                system: PerConversationReflectionPrompt.systemPrompt,
                responseSchema: PerConversationReflectionPrompt.responseSchema,
                temperature: 0.7
            )
        } catch {
            try? persistFailedRun(
                runId: runId,
                conversationId: conversationId,
                projectId: projectId,
                startedAt: startedAt,
                costCents: 0,
                reason: .apiError
            )
            throw ServiceError.llmFailure(error)
        }

        let cost = WeeklyReflectionService.estimatedCostCents(usage: usage)

        let validation: ReflectionValidator.Output
        do {
            validation = try ReflectionValidator.validate(
                rawJSON: rawText,
                validMessageIds: validMessageIds,
                runId: runId,
                now: now()
            )
        } catch let err as ReflectionValidator.ValidationError {
            try? persistFailedRun(
                runId: runId,
                conversationId: conversationId,
                projectId: projectId,
                startedAt: startedAt,
                costCents: cost,
                reason: .apiError
            )
            if case let .malformed(detail) = err {
                throw ServiceError.validatorMalformed(detail)
            }
            throw ServiceError.validatorMalformed("unknown validator error")
        }

        // Empty / rejected validator output: persist a `.rejectedAll` row so
        // the debug inspector can see the attempt and reason. Return Output
        // with claim=nil so the UI can render a sensible notice.
        guard let firstClaim = validation.claims.first else {
            let run = ReflectionRun(
                id: runId,
                projectId: projectId,
                nodeId: conversationId,
                weekStart: startedAt,
                weekEnd: startedAt,
                ranAt: startedAt,
                status: .rejectedAll,
                rejectionReason: validation.rejectionReason ?? .generic,
                costCents: cost
            )
            try nodeStore.persistReflectionRun(run, claims: [], evidence: [])
            return Output(
                claim: nil,
                rejectionReason: validation.rejectionReason,
                costCents: cost
            )
        }

        // Happy path: build evidence rows from the raw JSON (re-parsed because
        // the validator doesn't return grounded IDs), persist run + claim +
        // evidence in one transaction.
        let evidence = try buildEvidence(
            rawJSON: rawText,
            claims: validation.claims,
            validMessageIds: validMessageIds
        )
        let run = ReflectionRun(
            id: runId,
            projectId: projectId,
            nodeId: conversationId,
            weekStart: startedAt,
            weekEnd: startedAt,
            ranAt: startedAt,
            status: .success,
            rejectionReason: nil,
            costCents: cost
        )
        try nodeStore.persistReflectionRun(run, claims: validation.claims, evidence: evidence)
        return Output(
            claim: firstClaim,
            rejectionReason: nil,
            costCents: cost
        )
    }

    private func persistFailedRun(
        runId: UUID,
        conversationId: UUID,
        projectId: UUID?,
        startedAt: Date,
        costCents: Int,
        reason: ReflectionRejectionReason
    ) throws {
        let run = ReflectionRun(
            id: runId,
            projectId: projectId,
            nodeId: conversationId,
            weekStart: startedAt,
            weekEnd: startedAt,
            ranAt: startedAt,
            status: .failed,
            rejectionReason: reason,
            costCents: costCents
        )
        try nodeStore.persistReflectionRun(run, claims: [], evidence: [])
    }

    private func buildEvidence(
        rawJSON: String,
        claims: [ReflectionClaim],
        validMessageIds: Set<String>
    ) throws -> [ReflectionEvidence] {
        struct Envelope: Decodable { let claims: [RawClaim] }
        struct RawClaim: Decodable {
            let claim: String
            let confidence: Double
            let supporting_turn_ids: [String]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: Data(rawJSON.utf8))

        var map: [String: [[UUID]]] = [:]
        for raw in env.claims {
            let trimmed = raw.claim.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.confidence >= ReflectionValidator.minConfidence else { continue }
            let grounded = raw.supporting_turn_ids.filter { validMessageIds.contains($0) }
            var seen = Set<String>()
            let deduped = grounded.filter { id in
                if seen.contains(id) { return false }
                seen.insert(id)
                return true
            }
            guard deduped.count >= ReflectionValidator.minGroundedTurns else { continue }
            let uuids = deduped.compactMap(UUID.init(uuidString:))
            map[trimmed, default: []].append(uuids)
        }

        var evidence: [ReflectionEvidence] = []
        for claim in claims {
            guard var queue = map[claim.claim], !queue.isEmpty else { continue }
            let ids = queue.removeFirst()
            map[claim.claim] = queue
            var seenIds = Set<UUID>()
            for messageId in ids where !seenIds.contains(messageId) {
                seenIds.insert(messageId)
                evidence.append(ReflectionEvidence(reflectionId: claim.id, messageId: messageId))
            }
        }
        return evidence
    }

    private func encodeFixture(
        conversationId: UUID,
        conversationTitle: String,
        messages: [Message]
    ) throws -> String {
        struct ExportMessage: Encodable {
            let id: String
            let role: String
            let content: String
            let timestamp: String
        }
        struct ExportFixture: Encodable {
            let node_id: String
            let node_title: String
            let message_count: Int
            let messages: [ExportMessage]
        }

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let exported = messages.map { m in
            ExportMessage(
                id: m.id.uuidString,
                role: m.role.rawValue,
                content: m.content,
                timestamp: isoFull.string(from: m.timestamp)
            )
        }

        let fixture = ExportFixture(
            node_id: conversationId.uuidString,
            node_title: conversationTitle,
            message_count: exported.count,
            messages: exported
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(fixture)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
