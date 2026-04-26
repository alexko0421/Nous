import Foundation

extension Notification.Name {
    static let reflectionRunCompleted = Notification.Name("nous.reflectionRunCompleted")
}

/// Sunday-night batch reflection. Given a (projectId, week) scope, reads the
/// week's messages, asks Gemini for up-to-2 non-obvious patterns, validates
/// the output, and persists either active claims or a rejected/failed row.
///
/// Idempotent by design: if a run already exists for the (scope, week), this
/// is a no-op. That lets the foreground rollover trigger fire on every app
/// launch without worrying about duplicate work.
///
/// Callers are expected to detach this off the main actor — we do NOT block
/// UI on the HTTP call.
final class WeeklyReflectionService {

    /// Below this, we don't waste a Gemini call — there is not enough signal
    /// in the week to find cross-conversation patterns.
    static let minMessagesForRun = 10

    /// W1 D1 spike prompt (Alex-graded 2026-04-22), revised 2026-04-22 to add
    /// the CORPUS SCOPE rule after Alex flagged that a trait-style claim about
    /// his "anchoring in abstract feelings" generalized beyond the observable
    /// corpus — he has plenty of granular analysis, it just doesn't happen
    /// inside Nous chats. The fix: every claim must stay scoped to the
    /// week's conversations, never make claims about Alex as a whole person.
    static let systemPrompt = """
    You are reading one week of conversations between Alex and Nous.

    Your job is to produce at most 2 "reflection claims" — patterns you notice across multiple conversations that week, NOT summaries of what was discussed.

    CORPUS SCOPE (this is the most important rule — read it twice):

    You only see what Alex shared with Nous this week. You do NOT see:
    - His private notes or journals
    - His conversations with other AIs or people
    - His in-person discussions
    - His unspoken thoughts

    A pattern that is true inside our chats this week may be FALSE about Alex
    as a person. He may do the opposite thing everywhere else. Therefore:

    Every claim MUST be scoped to the conversations. Use phrasing like:
    - "In your conversations with me this week, you tend to..."
    - "Across N conversations this week, you..."
    - "When you talk to me, you..."

    REJECTED (trait claims about Alex as a person — DO NOT PRODUCE THESE):
    - "You anchor your understanding of the world in abstract feelings."
    - "You prefer lifestyle over technical details."
    - "You are skeptical of AI hype."

    ACCEPTED (corpus claims about these specific conversations):
    - "Across four conversations this week, you framed decisions through
      environment and lifestyle ('Austin', 'outdoors for design inspiration')
      before discussing tactical skill-building. This may reflect how you
      use our chats to think about direction, not necessarily your whole
      planning style."
    - "In three conversations you rejected technical framings (golden ratio,
      specific metrics) in favor of feelings and vibes. This may be how
      you prefer to explore ideas with me, not a general preference for
      abstraction — you may analyze granularly in contexts I can't see."
    - "Across two ship moments this week, you reported feeling relieved that
      nothing broke rather than proud that you finished. This may reflect how
      you process wins inside our chats — you may experience pride elsewhere
      I can't see." (Patterns about how you respond to positive events / 报喜
      moments are valid claims, not only struggle/decision patterns.)

    If a claim cannot be stated as a corpus claim without becoming a trivial
    summary, return fewer claims rather than force it.

    HARD BAR — still rejected even when corpus-scoped:
    - "This week you discussed Swift and design." (summary, not pattern)
    - "You worked on Nous a lot." (generic, not non-obvious)
    - "You asked questions about engineering." (tautological)

    A claim must be specific, backed by at least two turns, and tell Alex
    something he would NOT have said about himself before reading it —
    AND must stay inside the corpus.

    Rules:
    - claims array has length 0, 1, or 2. Never more.
    - Length 0 is a VALID answer. If nothing clears the "non-obvious" AND "corpus-scoped" bars, return {"claims": []}. Do not invent patterns.
    - supporting_turn_ids MUST be real `id` values copied verbatim from the fixture messages. Minimum 2 ids per claim.
    - confidence below 0.5 means you're not confident. Use it honestly.
    - why_non_obvious explains why this pattern in OUR CHATS is something Alex wouldn't self-report, not a description of the claim.

    Alex's fixture (one week of his free-chat conversations) follows as the user message.
    """

    /// Schema matches `ReflectionValidator.Envelope`. `snake_case` literals so
    /// Gemini emits exactly what the validator decodes.
    static let responseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "claims": [
                "type": "array",
                "maxItems": 2,
                "items": [
                    "type": "object",
                    "properties": [
                        "claim": ["type": "string"],
                        "confidence": ["type": "number"],
                        "supporting_turn_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "minItems": 2
                        ],
                        "why_non_obvious": ["type": "string"]
                    ],
                    "required": ["claim", "confidence", "supporting_turn_ids", "why_non_obvious"]
                ]
            ]
        ],
        "required": ["claims"]
    ]

    /// Gemini 2.5 Pro pricing per million tokens, in US cents. Used to
    /// estimate `ReflectionRun.costCents`. Input: $1.25/M; thinking+output:
    /// $10/M. Values in cents so the integer column stores the rounded
    /// result without float drift.
    private static let promptCentsPerMillion: Double = 125.0
    private static let outputCentsPerMillion: Double = 1000.0

    enum ServiceError: Error, LocalizedError {
        case notEnoughMessages(count: Int)
        case llmFailure(Error)
        case validatorMalformed(String)

        var errorDescription: String? {
            switch self {
            case .notEnoughMessages(let count):
                return "Not enough messages this week (\(count) < \(WeeklyReflectionService.minMessagesForRun))."
            case .llmFailure(let inner):
                return "Gemini call failed: \(inner.localizedDescription)."
            case .validatorMalformed(let detail):
                return "Validator could not decode Gemini output: \(detail)"
            }
        }
    }

    struct RunResult {
        let run: ReflectionRun
        let claims: [ReflectionClaim]
        let evidence: [ReflectionEvidence]
    }

    private let nodeStore: NodeStore
    private let llm: StructuredLLMClient
    private let now: () -> Date

    init(nodeStore: NodeStore, llm: StructuredLLMClient, now: @escaping () -> Date = Date.init) {
        self.nodeStore = nodeStore
        self.llm = llm
        self.now = now
    }

    /// Convenience init matching the production call site: a concrete
    /// `GeminiLLMService`. Test code uses the protocol-based init with a fake.
    convenience init(nodeStore: NodeStore, llm: GeminiLLMService, now: @escaping () -> Date = Date.init) {
        self.init(nodeStore: nodeStore, llm: GeminiStructuredLLMAdapter(service: llm), now: now)
    }

    /// Idempotent entrypoint. Returns `nil` if a run already exists for this
    /// (scope, week); otherwise kicks off the full pipeline and returns the
    /// resulting row set (whether success, rejected, or failed).
    @discardableResult
    func runForWeek(
        projectId: UUID?,
        weekStart: Date,
        weekEnd: Date
    ) async throws -> RunResult? {
        if try nodeStore.existsReflectionRun(projectId: projectId, weekStart: weekStart, weekEnd: weekEnd) {
            return nil
        }

        let runId = UUID()
        let fixture = try nodeStore.fetchReflectionFixture(
            projectId: projectId,
            weekStart: weekStart,
            weekEnd: weekEnd
        )
        let messageCount = fixture.reduce(0) { $0 + $1.messages.count }

        // Guard #1: not enough content. Write a rejected_all/generic row so
        // the foreground trigger sees "already ran this week" on next launch.
        if messageCount < Self.minMessagesForRun {
            let rejected = ReflectionRun(
                id: runId,
                projectId: projectId,
                weekStart: weekStart,
                weekEnd: weekEnd,
                ranAt: now(),
                status: .rejectedAll,
                rejectionReason: .generic,
                costCents: 0
            )
            try nodeStore.persistReflectionRun(rejected, claims: [], evidence: [])
            return RunResult(run: rejected, claims: [], evidence: [])
        }

        let fixtureJSON = try encodeFixture(
            projectId: projectId,
            weekStart: weekStart,
            weekEnd: weekEnd,
            rows: fixture,
            messageCount: messageCount
        )

        let validMessageIds: Set<String> = Set(
            fixture.flatMap { $0.messages.map { $0.id.uuidString } }
        )

        // Guard #2: LLM call. HTTP or parse failures land as a `.failed` row
        // with cost 0 (we don't trust a half-parsed usage block).
        let rawText: String
        let usage: GeminiUsageMetadata?
        do {
            let userMessage = LLMMessage(role: "user", content: "Fixture:\n\n\(fixtureJSON)")
            (rawText, usage) = try await llm.generateStructured(
                messages: [userMessage],
                system: Self.systemPrompt,
                responseSchema: Self.responseSchema,
                temperature: 0.7
            )
        } catch {
            let failedRun = ReflectionRun(
                id: runId,
                projectId: projectId,
                weekStart: weekStart,
                weekEnd: weekEnd,
                ranAt: now(),
                status: .failed,
                rejectionReason: .apiError,
                costCents: 0
            )
            try nodeStore.persistReflectionRun(failedRun, claims: [], evidence: [])
            throw ServiceError.llmFailure(error)
        }

        let cost = Self.estimatedCostCents(usage: usage)

        // Guard #3: validator. Malformed JSON → `.failed`/`.apiError` row.
        let messageIdToNodeId: [String: UUID] = Dictionary(
            fixture.flatMap { row in row.messages.map { ($0.id.uuidString, row.nodeId) } },
            uniquingKeysWith: { first, _ in first }
        )
        let validation: ReflectionValidator.Output
        do {
            validation = try ReflectionValidator.validate(
                rawJSON: rawText,
                validMessageIds: validMessageIds,
                messageIdToNodeId: messageIdToNodeId,
                runId: runId,
                now: now()
            )
        } catch let err as ReflectionValidator.ValidationError {
            let failedRun = ReflectionRun(
                id: runId,
                projectId: projectId,
                weekStart: weekStart,
                weekEnd: weekEnd,
                ranAt: now(),
                status: .failed,
                rejectionReason: .apiError,
                costCents: cost
            )
            try nodeStore.persistReflectionRun(failedRun, claims: [], evidence: [])
            if case let .malformed(detail) = err {
                throw ServiceError.validatorMalformed(detail)
            }
            throw ServiceError.validatorMalformed("unknown validator error")
        }

        // Happy paths: success with claims, or rejected_all with a reason.
        if validation.claims.isEmpty {
            let rejected = ReflectionRun(
                id: runId,
                projectId: projectId,
                weekStart: weekStart,
                weekEnd: weekEnd,
                ranAt: now(),
                status: .rejectedAll,
                rejectionReason: validation.rejectionReason ?? .generic,
                costCents: cost
            )
            try nodeStore.persistReflectionRun(rejected, claims: [], evidence: [])
            return RunResult(run: rejected, claims: [], evidence: [])
        }

        // Rebuild evidence rows by re-parsing the model output for turn IDs,
        // but restrict to those the validator already grounded. We don't get
        // the grounded IDs back from validate(), so re-derive here.
        let evidence = try buildEvidence(
            rawJSON: rawText,
            claims: validation.claims,
            validMessageIds: validMessageIds
        )

        let run = ReflectionRun(
            id: runId,
            projectId: projectId,
            weekStart: weekStart,
            weekEnd: weekEnd,
            ranAt: now(),
            status: .success,
            rejectionReason: nil,
            costCents: cost
        )
        try nodeStore.persistReflectionRun(run, claims: validation.claims, evidence: evidence)
        NotificationCenter.default.post(name: .reflectionRunCompleted, object: nil)
        return RunResult(run: run, claims: validation.claims, evidence: evidence)
    }

    /// The most recently completed ISO-8601 week at `now`. That is: the week
    /// whose Monday 00:00 local time is `>= 7 days ago` and `< 1 second ago`.
    /// Returns `nil` only if ISO-8601 calendar arithmetic fails (shouldn't
    /// happen on real clocks).
    ///
    /// Rollover trigger on app launch uses this to decide "what week should
    /// I reflect on." By running once per launch with idempotent
    /// `existsReflectionRun` guarding, we get "Sunday night batch" behavior
    /// without a timer or background task (Codex R1).
    static func previousCompletedWeek(now: Date, calendar: Calendar? = nil) -> (start: Date, end: Date)? {
        var cal = calendar ?? Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        // Start of current ISO week (Monday 00:00 local).
        guard let thisWeekStart = cal.date(
            from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        ) else { return nil }
        guard let previousWeekStart = cal.date(byAdding: .day, value: -7, to: thisWeekStart) else {
            return nil
        }
        return (previousWeekStart, thisWeekStart)
    }

    // MARK: - Helpers

    /// Wire format — shape matches what ReflectionFixtureRunner emits so prompts
    /// grade against the same JSON whether the fixture came from a CLI export
    /// or live from the running app.
    private func encodeFixture(
        projectId: UUID?,
        weekStart: Date,
        weekEnd: Date,
        rows: [NodeStore.ReflectionFixtureRow],
        messageCount: Int
    ) throws -> String {
        struct ExportMessage: Encodable {
            let id: String
            let role: String
            let content: String
            let timestamp: String
        }
        struct ExportConversation: Encodable {
            let node_id: String
            let node_title: String
            let messages: [ExportMessage]
        }
        struct ExportFixture: Encodable {
            let project_id: String?
            let week_start: String
            let week_end: String
            let message_count: Int
            let conversation_count: Int
            let conversations: [ExportConversation]
        }

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoDate = ISO8601DateFormatter()
        isoDate.formatOptions = [.withFullDate]

        let conversations = rows.map { row in
            ExportConversation(
                node_id: row.nodeId.uuidString,
                node_title: row.nodeTitle,
                messages: row.messages.map { m in
                    ExportMessage(
                        id: m.id.uuidString,
                        role: m.role.rawValue,
                        content: m.content,
                        timestamp: isoFull.string(from: m.timestamp)
                    )
                }
            )
        }

        let fixture = ExportFixture(
            project_id: projectId?.uuidString,
            week_start: isoDate.string(from: weekStart),
            week_end: isoDate.string(from: weekEnd),
            message_count: messageCount,
            conversation_count: conversations.count,
            conversations: conversations
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(fixture)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func buildEvidence(
        rawJSON: String,
        claims: [ReflectionClaim],
        validMessageIds: Set<String>
    ) throws -> [ReflectionEvidence] {
        // Re-parse the raw model output for supporting IDs. We can't trust an
        // in-memory mapping between validator inputs and outputs by order
        // alone — the validator may have dropped claims in the middle.
        struct Envelope: Decodable { let claims: [RawClaim] }
        struct RawClaim: Decodable {
            let claim: String
            let supporting_turn_ids: [String]
        }
        let env = try JSONDecoder().decode(Envelope.self, from: Data(rawJSON.utf8))

        // Build a claim-text → [messageId] map using grounded ids only.
        var map: [String: [UUID]] = [:]
        for raw in env.claims {
            let trimmed = raw.claim.trimmingCharacters(in: .whitespacesAndNewlines)
            let grounded = raw.supporting_turn_ids
                .filter { validMessageIds.contains($0) }
                .compactMap(UUID.init(uuidString:))
            map[trimmed] = grounded
        }

        var evidence: [ReflectionEvidence] = []
        for claim in claims {
            guard let ids = map[claim.claim] else { continue }
            var seen = Set<UUID>()
            for messageId in ids where !seen.contains(messageId) {
                seen.insert(messageId)
                evidence.append(ReflectionEvidence(reflectionId: claim.id, messageId: messageId))
            }
        }
        return evidence
    }

    /// Round-trip cost estimate for the run. Input tokens priced at prompt
    /// rate; thinking + candidates at output rate. Returns 0 on missing
    /// usage metadata.
    static func estimatedCostCents(usage: GeminiUsageMetadata?) -> Int {
        guard let usage else { return 0 }
        let inCents = Double(usage.promptTokenCount) * promptCentsPerMillion / 1_000_000.0
        let outTokens = (usage.candidatesTokenCount ?? 0) + (usage.thoughtsTokenCount ?? 0)
        let outCents = Double(outTokens) * outputCentsPerMillion / 1_000_000.0
        return Int((inCents + outCents).rounded())
    }
}
