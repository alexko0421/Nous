# Proactive Surfacing + Interjection Design Spec

## Overview

First concrete feature to advance Nous from "chat with memory" to "thinking companion." Adds the ability for Nous to **proactively surface relevant prior memory entries** and — when warranted — **interject in its response** to call out tensions (contradictions or relevant-but-unused ideas) instead of only using memory silently.

Sits on top of the v2.2 block-level `memory_entries` substrate: block-level addressability is what makes per-entry surfacing and citation possible.

## Problem

Today Nous consumes memory passively — retrieved entries are prepended to the system prompt and the assistant "just knows more." This makes it a more informed chat, not a thinking companion. Alex's stated favorite dimension (see `feedback_nous_thinking_companion_design_principles`) is provocation: proactively surfacing old ideas, asking back, pointing out contradictions. This spec delivers two of those three: **surface** and **contradict**. Ask-back is out of scope for v1 (it is a main-model prompting layer, addressable later).

The hard problem is not "retrieve more." It is the **annoyance threshold**: when is provocation useful vs. intrusive.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| UX surfaces | Silent injection (A) + in-line interjection in main reply (C) | B (visible card) and D (out-of-chat nudge) deferred — C is the smallest surface change that changes the product identity |
| Gating mechanism | LLM judge per turn | Rule-based (pattern match) is too narrow; user-mode gating pushes cognitive load back onto user |
| Mode-based toggle | **Removed** | Asking the user "want to be challenged?" defeats the thinking-companion identity — AI must read the room |
| Judge shape | Single small-model call, structured JSON output | Not an agent, not a skill runtime — just a classifier call |
| Judge's entry pool | Reuse entries already retrieved for the main call | Fail-closed on scope boundary; avoids duplicate retrieval cost |
| Trigger taxonomy | Contradiction **and** relevant-but-unused recall | Contradiction alone misses the "surface" half of the feature; stale-claim detection deferred |
| Behavior delivery | Two swappable `BehaviorProfile` enum cases (Swift-native v1) | Matches existing `ChatMode.contextBlock` shape; migrates to markdown-in-bundle cleanly |
| ChatMode role | Explicit input to judge; strategist lowers the provoke threshold, companion raises it | Still a real user-intent signal (not a hard gate, but not merely a "prior" either) — encoded as concrete rules in the judge prompt |
| Orchestration location | `ChatViewModel` (or a new `ResponseOrchestrator` extracted from it), **not** `LLMService` | `LLMService` is a pure provider transport (`generate(messages:system:)`). Memory assembly, chat-mode resolution, judge invocation, and telemetry logging already live at the ViewModel layer. Pushing orchestration down into `LLMService` would make the provider layer know about memory entries, modes, and telemetry — a boundary violation. |
| Citable entry pool | Explicit `{id, text}` pool (vectorStore citations + raw `memory_entries` fetched by id), **separate from** the summary blocks the main call consumes | Main call today consumes `currentGlobal()` / `currentEssentialStory()` / `currentBoundedEvidence()` / etc. — these are summaries without per-entry IDs. Judge's `entry_id` must resolve into a pool that the orchestrator can also look up by ID to inject the raw text into the main prompt. Without this split, the judge quotes one thing and the main model quotes another. |
| Judge provider scope (v1) | Cloud providers only (Claude / Gemini / OpenAI). Local MLX disabled. | `LocalLLMService`'s default is `Llama-3.2-3B-Instruct-4bit`; strict JSON on a 3B 4-bit quant is not reliable. When user's active provider is local, feature degrades to supportive-only (no judge call). |
| Telemetry substrate | New SQLite-backed event log via NodeStore, **not** `UserDefaults` counters | Current `GovernanceTelemetryStore` (55 lines, UserDefaults) stores counters + one last-prompt-trace blob. It cannot support the "last N verdicts, filter by user_state / should_provoke, correlate with thumbs-down" review loop this feature depends on. |
| Failure default | Silent fallback to `.supportive` profile | Never block or degrade the main reply |

## Components

| Component | Status | Responsibility |
|---|---|---|
| `ProvocationJudge` | New | Single async method: `judge(userMessage, citablePool, chatMode, provider) -> JudgeVerdict`. Wraps one small-model LLM call with structured-JSON output. Called from the orchestration layer, not from `LLMService`. |
| `BehaviorProfile` | New enum | `.supportive` / `.provocative` cases, each with a `contextBlock: String` property — same shape as `ChatMode.contextBlock`. |
| `JudgeVerdict` | New struct | `{ tensionExists: Bool, userState: UserState, shouldProvoke: Bool, entryId: String?, reason: String }` |
| `CitableEntry` | New struct | `{ id: String, text: String, scope: MemoryScope }` — the shape passed into the judge and looked up back out by `entry_id`. |
| Response orchestration | Extended in `ChatViewModel.send()` (or extracted into `ResponseOrchestrator`) | Owns the per-turn flow: assemble summary context (today's behavior, unchanged) **and** assemble the citable entry pool, call `ProvocationJudge`, select profile, fetch the referenced entry's raw text for the main prompt, record telemetry, then call `LLMService.generate(...)`. |
| `UserMemoryService` | Extended | New method `citableEntryPool(projectId:conversationId:query:) -> [CitableEntry]` returning `memory_entries` relevant to this turn (v1: top-K from vector search + recent per-scope entries) with IDs preserved. Existing summary methods unchanged. |
| `LLMService` | **Unchanged** | Stays a pure transport — `generate(messages:system:)`. The judge call is a separate invocation from the orchestrator, using the same `LLMService` abstraction. |
| `GovernanceTelemetryStore` | **Materially extended** | New SQLite-backed event log (see Telemetry Substrate below). UserDefaults counters + last-prompt-trace blob remain for existing metrics; the new judge/feedback events go into a proper table. |
| `NodeStore` | Extended | Adds `judge_events` table migration + append/query helpers. |
| `ChatMode` | Unchanged structurally | Passed as an explicit input signal into the judge. `strategist` → lower provoke threshold; `companion` → higher. This is encoded in the judge prompt, not in orchestration control flow. |

## Data Flow (Single Turn)

Driver is `ChatViewModel.send()` (or a `ResponseOrchestrator` extracted from it). `LLMService` is **only** called as a pure transport, twice: once for the judge, once for the main reply.

1. User sends a message.
2. **Summary context assembly** — unchanged from today. `ChatViewModel.assembleContext(...)` composes the summary layers (`currentGlobal`, `currentEssentialStory`, `currentUserModel`, `currentBoundedEvidence`, `currentProject`, `currentConversation`, `recentConversations`, `citations`, `projectGoal`, attachments). These feed the main prompt, not the judge.
3. **Citable entry pool assembly** — new. Orchestrator calls `UserMemoryService.citableEntryPool(...)`, which returns `[CitableEntry]` with IDs. v1 sources: top-K `memory_entries` by vector-search relevance (the same search that populates `citations`) + explicit recent entries at each active scope. This is the **only** pool the judge may cite from.
4. **Provider capability check** — if the active provider is `.local`, skip steps 5–6 entirely, go straight to step 7 with `.supportive`. Log a `judge_skipped_local` event.
5. **Judge call** — `ProvocationJudge.judge(userMessage, citablePool, chatMode, provider)` issues one small-model call (Haiku or equivalent on current provider). Returns `JudgeVerdict`.
6. **Verdict validation + telemetry** — orchestrator verifies `verdict.entryId` (when present) is actually in the pool. If not → treat as Scenario 3 failure. Record the verdict (valid or not) in the SQLite `judge_events` table.
7. **Profile selection + main prompt composition:**
   - `verdict.shouldProvoke == false` (or step 4/6 forced fallback) → `BehaviorProfile.supportive`.
   - `verdict.shouldProvoke == true` → `BehaviorProfile.provocative`. Orchestrator looks up the full raw entry by `verdict.entryId` from `NodeStore` and appends a dedicated block into the system prompt: `"FOCUS ON THIS MEMORY: <text>. Surface it in your reply and name the tension with the user's current claim."`
   - System prompt order: anchor → summary context (unchanged) → `profile.contextBlock` → (optional) focus block.
8. **Main call** — `LLMService.generate(messages:system:)` streams the reply.

### Critical Timing

- Judge is on the critical path of the main call — the main prompt depends on its output.
- Target latency: **p50 ≤ 500ms**, **p95 ≤ 1.5s**.
- Timeout: **1.5s hard deadline**. On timeout → fallback to `.supportive`, log the timeout.

### Why Judge Has Its Own Entry Pool (and Why It's Not the Main Call's Context)

- **Main call's context is summaries**, not addressable entries. `currentGlobal()`, `currentEssentialStory()`, `currentBoundedEvidence()` all return string blocks already compressed — the judge has no stable ID to return that would make sense to the main model.
- **Citable pool is raw `memory_entries` with IDs.** v1 pool is drawn from vector-search hits over the same `memory_entries` table the summary layers were derived from, so by construction the judge cannot cite anything the system didn't already consider relevant for this turn.
- When the judge says "provoke via entry X," the orchestrator explicitly injects X's raw text into the main prompt. This guarantees the main model quotes the same thing the judge reasoned about — there is no gap between judge-pool and main-model-pool.
- v2.2 scope-boundary invariant is preserved: the pool builder respects scope (global / project / conversation) the same way existing retrieval does.

## Judge Prompt Contract

The judge is prompted to produce strict JSON with these fields:

```
{
  "tension_exists": true | false,
  "user_state": "deciding" | "exploring" | "venting",
  "should_provoke": true | false,
  "entry_id": "<id from provided entries>" | null,
  "reason": "<short natural-language reason>"
}
```

**Inputs to the judge prompt:**

- `user_message` — the text of the user's latest turn.
- `citable_pool` — a numbered list of `{id, text}` pairs.
- `chat_mode` — `"companion"` or `"strategist"`.

**Rules encoded in the prompt:**

- `should_provoke == true` REQUIRES `tension_exists == true`, `user_state != "venting"`, and a non-null `entry_id` drawn from `citable_pool`.
- `user_state == "venting"` forces `should_provoke == false` regardless of tension. Venting is a signal to support, not to challenge.
- `entry_id` must match the ID of an entry in `citable_pool`. (Enforced in code post-parse; if the judge returns an unknown ID, we treat it as a Scenario 3 failure — see below.)
- **ChatMode-dependent threshold (explicit, not prior):**
  - `chat_mode == "strategist"`: set `should_provoke = true` whenever `tension_exists == true` AND `user_state` is `deciding` or `exploring`. Be willing to interject even on soft tensions.
  - `chat_mode == "companion"`: set `should_provoke = true` only when tension is strong and clearly decision-relevant. Soft tensions → use silently, don't interject.
  - Rationale goes in the prompt verbatim so the model has the "why," not just the rule.

## BehaviorProfile Contents

Profiles are Swift enum cases with string `contextBlock`. Supportive is roughly the existing `ChatMode.companion.contextBlock` voice (unchanged). Provocative is a new voice giving the main model explicit permission — and expectation — to interject.

```swift
enum BehaviorProfile {
    case supportive
    case provocative
    var contextBlock: String { ... }
}
```

Provocative profile will instruct the main model to: acknowledge the user's current point briefly, then surface the referenced prior entry verbatim, and name the tension in plain language. It must not lecture or moralize. It must remain in the tone set by `ChatMode` (companion = softer provoke, strategist = sharper).

Exact `contextBlock` wording is in scope of the implementation plan, not this spec.

## Error Handling

| Scenario | Handling |
|---|---|
| 1. Judge API call fails or times out | Fallback to `.supportive`. Log `judge_failed` event with error kind. Main reply proceeds normally. |
| 2. Judge returns malformed JSON | Same as 1. Log `warning` level. Signals judge prompt needs iteration. |
| 3. Judge returns `entry_id` not in the provided entry pool | **Do not** pass the ID to the main model. Downgrade to `.supportive`. Log at `error` level — this is a scope-boundary safety issue, not merely a quality issue. |
| 4. User feels a provocation was wrong | Lightweight 👍 / 👎 affordance on any provoked reply. Writes `{ verdict_id, user_feedback }` into the `judge_events` table, correlated to the verdict row. No runtime retraining — the data is for weekly human review. |
| 5. User sends a new message while previous turn's judge is still running | Cancel the in-flight judge call immediately. A stale verdict must never inform a newer turn's reply. |
| 6. Active provider is `.local` | Skip the judge call entirely. Use `.supportive`. Log `judge_skipped_local`. The feature is effectively disabled on local providers in v1 (strict JSON on small quantized models is not reliable). |

### Explicitly Out of v1

- **No automated circuit-breakers** (e.g., "disable judge for 1h after N timeouts"). These hide the real failure mode. v1 calls the judge every turn, honestly fails, honestly logs.
- **No self-evaluation** (LLM-as-judge-of-judge). Too early — not enough data.
- **No A/B framework**. Single-user product, one prompt at a time.
- **No online learning**. Telemetry is reviewed by Alex; judge prompt iteration is manual.

## Testing Strategy

### Layer 1 — Deterministic Tests (`Tests/NousTests/`)

| Test | What it asserts |
|---|---|
| `JudgeVerdictParsing` | Well-formed, malformed, partial JSON are all handled without crashes |
| `ProvocationFallback` | Injected failing judge → profile resolves to `.supportive`, main call proceeds, telemetry records error |
| `ScopeBoundaryGuard` | Judge returns `entry_id` not in pool → ID is discarded, profile is `.supportive`, error log written |
| `JudgeCancellation` | Second turn mid-first-turn judge → first judge is cancelled, its verdict is never applied |
| `ProfileSelection` | Verdict permutations map to the expected profile; `user_state == "venting"` always maps to `.supportive` regardless of tension |
| `LocalProviderGate` | When active provider is `.local`, judge is not invoked; `judge_skipped_local` event is recorded; main reply uses `.supportive` |
| `CitablePoolIntegrity` | Orchestrator's main-prompt focus block, when present, contains the raw text of the entry identified by `verdict.entryId` — verified against `NodeStore.fetchMemoryEntry(id:)` |
| `TelemetryAppendQuery` | `appendJudgeEvent` + `recentJudgeEvents` round-trip, filtered query returns correct subset |

### Layer 2 — Judgment Quality

Cannot be asserted in CI. Captured as:

**(a) Scenario fixture bank** — 20-30 hand-authored `(userMessage, entries, expectedVerdictShape)` cases kept in `Tests/NousTests/Fixtures/ProvocationScenarios/`. Asserts **shape only** on the core fields (`tension_exists`, `should_provoke`, `user_state`, whether `entry_id` points to the expected one). Run before every judge-prompt change; regressions surface as diffs.

**(b) Review panel in `MemoryDebugInspector`** — new tab showing the last N judge verdicts, filterable by profile / user_state / should_provoke. Internal-only. Intended for weekly human review; mis-judged cases become new fixture rows.

**(c) Production telemetry watched metrics:**

| Metric | Purpose | Alert threshold |
|---|---|---|
| `% of turns with should_provoke == true` | Too high = noisy; too low = feature is vestigial | Expected 10-25% |
| Judge call p50 / p95 latency | Too slow = main reply is dragged | p95 > 1.5s triggers prompt simplification |
| `thumbs_down / total_provocations` | False-positive feedback signal | North star for judge-prompt iteration |

## Telemetry Substrate

The existing `GovernanceTelemetryStore` (UserDefaults-based counters + a single last-prompt-trace blob) is inadequate for this feature. v1 adds a real event log:

- **Storage:** new SQLite table `judge_events`, created via a NodeStore migration. Columns (initial draft, to be finalized in the implementation plan):
  - `id` (PK, text)
  - `ts` (real, unix epoch seconds)
  - `node_id` (text, FK → conversation node)
  - `message_id` (text, FK → assistant message this verdict led to — nullable if judge failed before a reply was produced)
  - `chat_mode` (text)
  - `provider` (text)
  - `verdict_json` (text, the full `JudgeVerdict` blob)
  - `fallback_reason` (text, nullable — one of `ok`, `timeout`, `api_error`, `bad_json`, `unknown_entry_id`, `provider_local`)
  - `user_feedback` (text, nullable — one of `up`, `down`)
  - `feedback_ts` (real, nullable)
- **Access API (on `GovernanceTelemetryStore`, backed by NodeStore):**
  - `appendJudgeEvent(...)`
  - `recordFeedback(eventId:feedback:)`
  - `recentJudgeEvents(limit:filter:)` where filter supports user_state / should_provoke / fallback_reason / date range
- **Existing UserDefaults counters and `lastPromptTrace` stay as-is.** This change is additive; nothing in the current telemetry is removed.

The `MemoryDebugInspector` gains a new tab backed by `recentJudgeEvents(...)`, rendering a filterable list. Internal surface only — not shipped to normal users.

## Dependencies / Preconditions

- **v2.2 block-level `memory_entries`** already merged (PRs #4–#7). Without entry-level addressability, `entry_id` citation is not possible.
- **NodeStore migration** adding the `judge_events` table (see Telemetry Substrate above).
- **`UserMemoryService` extension** with `citableEntryPool(...)` method returning raw `[CitableEntry]` from `memory_entries` (IDs preserved). v1 implementation: reuse the vector-search path already used for `citations`, plus top-N recent per-scope entries.
- `GovernanceTelemetryStore` gains SQLite-backed event methods; existing UserDefaults counters unchanged.
- `ChatMode` enum unchanged structurally — passed as explicit input to judge.
- Existing `MemoryDebugInspector` view gains a new tab; no new view hierarchy needed.

## Success Criteria

This feature is working if, after two weeks of dogfooding:

1. Alex's subjective read: **at least some interjections feel like genuine sparks**, not noise.
2. `thumbs_down / total_provocations` < **30%** and trending down week-over-week.
3. Judge p95 latency < **1.5s**.
4. No `error`-level scope-boundary log events in production.
5. Alex has iterated the judge prompt **at least once** based on telemetry — demonstrating the review loop actually closes.

If any of 1, 2, or 5 fails, the feature design is re-examined before further UI investment (e.g., before considering adding UX surface B — the visible recall card — in a v2).

## Out of Scope for This Spec

- Ask-back (Socratic reflection) as its own provocation type — future feature, layers on top of this one.
- Stale-claim detection — a third judge trigger type, deferred until B's telemetry shows the feature is warranted.
- Out-of-chat nudges (welcome screen, notifications) — a different surface entirely.
- Markdown-in-bundle profile loading — v2 migration, after profiles stabilize.
- User-editable profiles — far future.
- Judge support on `.local` provider — revisit once small-model structured-output reliability improves or once a rule-based local fallback is warranted.
- Full extraction of `ResponseOrchestrator` as its own type — v1 may keep orchestration inside `ChatViewModel.send()` to minimize churn; extraction is an implementation-plan decision, not a spec decision.
