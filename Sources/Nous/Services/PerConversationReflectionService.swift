import Foundation

/// Manual-trigger per-conversation reflection. Runs `PerConversationReflectionPrompt`
/// against a single conversation's transcript on Gemini 2.5 Pro, validates the
/// result via `ReflectionValidator`, and returns claims as values.
///
/// Block 8 lite v1 (2026-05-10) deliberately does NOT persist to
/// `reflection_claim`. The weekly tier already populates that table for
/// CitableContextBuilder retrieval; per-conversation claims are scoped to
/// "in this conversation, you tend to..." phrasing and would be misleading
/// if they leaked into other conversations' prompts via the global
/// `fetchActiveReflectionClaims` lane. Once Alex has run this manually a few
/// times and the claim quality is graded, persistence can be added with a
/// proper conversation-scoped storage path.
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

    private let llm: StructuredLLMClient
    private let now: () -> Date

    init(llm: StructuredLLMClient, now: @escaping () -> Date = Date.init) {
        self.llm = llm
        self.now = now
    }

    convenience init(llm: GeminiLLMService, now: @escaping () -> Date = Date.init) {
        self.init(llm: GeminiStructuredLLMAdapter(service: llm), now: now)
    }

    /// Run reflection on one conversation's messages. Caller passes the live
    /// `messages` array from `ChatViewModel`; this service doesn't touch the
    /// node store or write anything.
    func run(
        conversationId: UUID,
        conversationTitle: String,
        messages: [Message]
    ) async throws -> Output {
        guard messages.count >= Self.manualTriggerMinimumTurns else {
            throw ServiceError.notEnoughMessages(
                count: messages.count,
                minimum: Self.manualTriggerMinimumTurns
            )
        }

        let runId = UUID()
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
            if case let .malformed(detail) = err {
                throw ServiceError.validatorMalformed(detail)
            }
            throw ServiceError.validatorMalformed("unknown validator error")
        }

        return Output(
            claim: validation.claims.first,
            rejectionReason: validation.rejectionReason,
            costCents: cost
        )
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
