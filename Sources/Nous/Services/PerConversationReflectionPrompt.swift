import Foundation

/// Block 8 lite (2026-05-08): design-locked prompt + schema + threshold for
/// per-conversation reflection. The actual service that runs the Gemini call
/// and persists to `reflection_claim` is intentionally NOT shipped in this
/// commit — that wiring is deferred until Block 7 telemetry
/// (`recentCorpusFidelityRecords`) reveals which conversation-level patterns
/// the model is leaking on, so the trigger threshold + atom-type targeting
/// can be informed by data instead of guessed.
///
/// Why a separate prompt from `WeeklyReflectionService`:
/// - Scope is one conversation, not a week of conversations.
/// - Lower bar for non-obviousness: a single deep conversation can surface
///   a pattern; a week's surface chatter often cannot.
/// - Output is at most 1 claim (vs weekly's 2) — the goal is precision
///   per-conversation, not breadth.
///
/// Reuses the weekly response schema (claim / confidence / supporting_turn_ids /
/// why_non_obvious) so downstream `ReflectionValidator` and the
/// `CitableEntry` admission path light up without a separate retrieval lane.
enum PerConversationReflectionPrompt {

    /// UserDefaults key for the minimum turn count before a per-conversation
    /// reflection fires. Default 16 (≈ 8 user + 8 assistant exchanges) is a
    /// guess to be tuned against Block 7 telemetry — short conversations
    /// usually don't have a non-obvious pattern, very long ones risk
    /// stale claims that summarize earlier sub-threads.
    static let minimumTurnCountUserDefaultKey = "nous.reflection.perConversation.minTurnCount"
    static let defaultMinimumTurnCount = 16

    /// System prompt. Mirrors `WeeklyReflectionService.systemPrompt`'s strict
    /// CORPUS SCOPE rule but narrows to a single conversation. The "across
    /// N conversations" phrasing is replaced with "within this conversation"
    /// because the reflection sees one conversation's transcript, not a week.
    static let systemPrompt = """
    You are reading one conversation between Alex and Nous.

    Your job is to produce at most 1 "reflection claim" — a non-obvious pattern within THIS conversation, NOT a summary of what was discussed.

    CORPUS SCOPE (this is the most important rule — read it twice):

    You only see what happened inside this single conversation. You do NOT see:
    - Alex's other conversations with Nous
    - His private notes or journals
    - His conversations with other AIs or people
    - His in-person discussions
    - His unspoken thoughts

    A pattern that is true inside THIS conversation may be FALSE about Alex
    as a person — or even false about how he talks to me on other days.
    Therefore:

    Every claim MUST be scoped to THIS conversation. Use phrasing like:
    - "In this conversation, you tend to..."
    - "Across the turns of this chat, you..."
    - "When you brought up X here, you..."

    REJECTED (trait claims about Alex as a person — DO NOT PRODUCE THESE):
    - "You anchor your understanding of the world in abstract feelings."
    - "You prefer lifestyle over technical details."

    REJECTED (cross-conversation claims — out of scope for this prompt):
    - "Across multiple conversations, you tend to..."
    - "You always do X when discussing Y." (you only see this one)

    ACCEPTED (within-conversation pattern claims):
    - "In this conversation you reframed the question three times before
      committing to an answer — first as a logistics problem (storage),
      then as an emotional one (roommate noise), then as a meaning one
      (project obsession). The reframing itself was the deliberation."
    - "You opened with a knowledge question (movie recommendations) but
      every turn after pulled toward the underlying decision (whether to
      move). The knowledge frame was a warm-up, not the destination."

    HARD BAR — still rejected even when conversation-scoped:
    - "You discussed renting in this chat." (summary, not pattern)
    - "You asked five questions." (mechanical, not non-obvious)
    - "You used Cantonese in this chat." (tautological)

    A claim must be specific, backed by at least 2 turns within the same
    conversation, and tell Alex something he would NOT have said about
    this chat before reading it — AND must stay inside this conversation.

    Rules:
    - claims array has length 0 or 1. Never more.
    - Length 0 is a VALID answer. If nothing clears the "non-obvious" AND "in-conversation-scoped" bars, return {"claims": []}. Do not invent patterns.
    - supporting_turn_ids MUST be real `id` values copied verbatim from the conversation messages. Minimum 2 ids.
    - confidence below 0.5 means you're not confident. Use it honestly.
    - why_non_obvious explains why this pattern in THIS conversation is something Alex wouldn't self-report, not a description of the claim.

    The conversation transcript follows as the user message.
    """

    /// Reuses `WeeklyReflectionService.responseSchema` shape; only the array
    /// max length differs (1 vs 2). Keeping the field set identical means
    /// existing `ReflectionValidator` + `CitableEntry` admission code paths
    /// work without modification when this service eventually ships.
    static let responseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "claims": [
                "type": "array",
                "maxItems": 1,
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

    /// Read the configured minimum turn count, falling back to the default
    /// if unset. Callers gate the reflection trigger on this value once the
    /// service is wired into the conversation lifecycle.
    static func minimumTurnCount(defaults: UserDefaults = .standard) -> Int {
        let raw = defaults.integer(forKey: minimumTurnCountUserDefaultKey)
        return raw > 0 ? raw : defaultMinimumTurnCount
    }
}

/// Block 8 lite: design-locked prompt + schema for monthly decision-pattern
/// reflection. Fires once per calendar month over decisions that landed
/// in `memory_atoms` with type `.decision` (and adjacent types — rejection,
/// proposal, reason). Goal: surface a pattern *across* the month's decisions
/// that a single weekly run can't see.
///
/// Like the per-conversation tier, the actual scheduler + LLM call + DB
/// persistence is intentionally NOT shipped in this commit. The constants
/// here lock in the prompt design so future wiring is mechanical.
enum DecisionPatternReflectionPrompt {

    /// UserDefaults key for whether the monthly run is enabled at all.
    /// Default off until Block 7 telemetry confirms decision-type leakage
    /// is the bottleneck (vs preference / rule / pattern leakage which the
    /// existing weekly tier should catch first).
    static let enabledUserDefaultKey = "nous.reflection.decisionPattern.enabled"

    /// System prompt. Operates over a fixture of decision atoms (not raw
    /// messages) — the assumption is that atoms have already been distilled
    /// from messages by `MemoryGraphWriter`, so the reflector reads claims
    /// the system already considers structured.
    static let systemPrompt = """
    You are reading the past month's decision atoms — claims of the form "Alex decided X" or "Alex rejected X" — that the memory graph extracted from his conversations with Nous.

    Your job is to produce at most 1 "decision-pattern claim" — a non-obvious pattern across MULTIPLE decisions this month. Not a summary of what he decided.

    CORPUS SCOPE (this is the most important rule):

    You only see decision atoms extracted from Nous chats this month. You do NOT see:
    - Decisions Alex made outside Nous chats
    - The reasoning he kept private
    - Decisions he changed his mind on without telling Nous

    A pattern across these atoms may be FALSE about how he actually decides
    in his life. He may decide differently in contexts I cannot see.
    Therefore every claim MUST be scoped to the corpus. Use phrasing like:
    - "Across the decisions you brought into Nous this month, you tend to..."
    - "In the N decisions surfaced here, you..."
    - "When you decided things with me this month, you..."

    REJECTED (trait claims — DO NOT PRODUCE THESE):
    - "You are a quick decision-maker."
    - "You prefer reversible decisions."

    REJECTED (single-atom claims — out of scope for this tier):
    - Any pattern resting on only one decision atom. The whole point of
      this tier is cross-decision patterns; if you only see one decision
      that fits, return {"claims": []}.

    ACCEPTED (cross-decision in-corpus patterns):
    - "Across the 6 decisions you logged in March, the four you committed
      to fastest were all reversible (rent, project scope, Slack channel)
      and the two you stalled on were both irreversible (visa filing,
      cofounder talk). The reversibility threshold seems to be your
      decision pacer in this corpus."

    HARD BAR — still rejected even when corpus-scoped:
    - "You decided 6 things this month." (summary)
    - "You rejected one proposal." (mechanical count)
    - "Your decisions were varied." (vacuous)

    Rules:
    - claims array has length 0 or 1. Never more.
    - Length 0 is a VALID answer. If no cross-decision pattern is non-obvious AND in-corpus-scoped, return {"claims": []}.
    - supporting_turn_ids MUST be real atom IDs (UUIDs) copied verbatim from the atoms fixture. Minimum 2 ids.
    - confidence below 0.5 means you're not confident. Use it honestly.
    - why_non_obvious explains why this cross-decision pattern is something Alex wouldn't self-report.

    The decision atoms fixture follows as the user message.
    """

    /// Same schema as `PerConversationReflectionPrompt`. supporting_turn_ids
    /// here carries atom UUIDs instead of message UUIDs — the validator does
    /// not care about the semantic distinction; downstream evidence binding
    /// can.
    static let responseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "claims": [
                "type": "array",
                "maxItems": 1,
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

    /// Whether the monthly decision-pattern tier is enabled. Default false:
    /// shipping the design but keeping the trigger off until telemetry
    /// confirms decision-type leakage is worth a separate cadence.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledUserDefaultKey)
    }
}
