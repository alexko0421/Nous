import Foundation

enum BackgroundAIJobID: String, Codable, CaseIterable {
    case conversationTitleBackfill = "conversation_title_backfill"
    case memoryGraphMessageBackfill = "memory_graph_message_backfill"
    case weeklyReflection = "weekly_reflection"
    case galaxyRelationRefinement = "galaxy_relation_refinement"
}

enum BackgroundAIJobStatus: String, Codable {
    case completed
    case skipped
    case failed
}

struct BackgroundAIJobRecipe: Codable, Equatable {
    let id: BackgroundAIJobID
    let purpose: String
    let trigger: String
    let inputScope: String
    let outputContract: String
    let privacyBoundary: String
    let validator: String
    let idempotencyKey: String

    var isComplete: Bool {
        [
            purpose,
            trigger,
            inputScope,
            outputContract,
            privacyBoundary,
            validator,
            idempotencyKey
        ].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct BackgroundAIJobRunRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let jobId: BackgroundAIJobID
    let status: BackgroundAIJobStatus
    let startedAt: Date
    let endedAt: Date
    let inputCount: Int
    let outputCount: Int
    let detail: String?
    let costCents: Int?
}

enum BackgroundAIJobCatalog {
    static let all: [BackgroundAIJobRecipe] = [
        BackgroundAIJobRecipe(
            id: .conversationTitleBackfill,
            purpose: "Replace legacy placeholder conversation titles with compact titles.",
            trigger: "App launch maintenance while the schema_meta version is unset.",
            inputScope: "Conversation nodes with legacy or quick-action placeholder titles, thread memory, and recent transcript slice.",
            outputContract: "Updates only the conversation title when the candidate passes title sanitization.",
            privacyBoundary: "Uses local conversation context only; no assistant thinking or unrelated memory is included.",
            validator: "Title sanitizer rejects tags, generic labels, punctuation-only output, and unchanged placeholders.",
            idempotencyKey: "conversation_title_backfill_version"
        ),
        BackgroundAIJobRecipe(
            id: .memoryGraphMessageBackfill,
            purpose: "Backfill durable rejection and decision chains from old user messages.",
            trigger: "Bounded app launch maintenance when background analysis has an LLM provider.",
            inputScope: "Alex-authored user turns from unprocessed conversation fingerprints.",
            outputContract: "Writes memory atoms and edges only when evidence quotes match listed user messages.",
            privacyBoundary: "Assistant replies are omitted from the model prompt and cannot become evidence.",
            validator: "MemoryGraphEvidenceMatcher must verify evidence_message_id and evidence_quote before graph writes.",
            idempotencyKey: "raw_message_graph_backfill fingerprint marker"
        ),
        BackgroundAIJobRecipe(
            id: .weeklyReflection,
            purpose: "Find at most two non-obvious weekly conversation patterns.",
            trigger: "Previous completed ISO week rollover when background analysis and Gemini are configured.",
            inputScope: "One week of conversation messages in the requested project or free-chat scope.",
            outputContract: "Persists reflection runs, validated claims, and evidence rows; rejected or failed runs are explicit.",
            privacyBoundary: "Claims must stay scoped to conversations Nous saw that week, not Alex as a whole person.",
            validator: "ReflectionValidator enforces JSON shape, confidence, corpus scope, and supporting message IDs.",
            idempotencyKey: "reflection_runs unique project/week row"
        ),
        BackgroundAIJobRecipe(
            id: .galaxyRelationRefinement,
            purpose: "Use an LLM to refine high-similarity Galaxy relation candidates.",
            trigger: "Relation refinement queue after local graph relation screening.",
            inputScope: "Two nodes, vector similarity, active memory atoms, and short content excerpts.",
            outputContract: "Returns a relation verdict only when confidence and evidence fields pass decoding.",
            privacyBoundary: "Prompt is limited to the two candidate nodes and their active atoms.",
            validator: "Strict JSON decoding, confidence thresholding, non-empty evidence, and atom-id allowlisting.",
            idempotencyKey: "Relation queue dedupes by node id and hourly budget."
        )
    ]

    static func recipe(for id: BackgroundAIJobID) -> BackgroundAIJobRecipe {
        all.first { $0.id == id }!
    }
}
