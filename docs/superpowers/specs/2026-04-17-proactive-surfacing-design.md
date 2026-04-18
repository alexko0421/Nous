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
| ChatMode role | Demoted to "prior signal" for judge | Keeps user-visible tone preference without letting it gate behavior |
| Failure default | Silent fallback to `.supportive` profile | Never block or degrade the main reply |

## Components

| Component | Status | Responsibility |
|---|---|---|
| `ProvocationJudge` | New | Single async method: takes `(userMessage, memoryEntries, chatMode)` → `JudgeVerdict`. Wraps one small-model LLM call with structured output. |
| `BehaviorProfile` | New enum | `.supportive` / `.provocative` cases, each with a `contextBlock: String` property — same shape as `ChatMode.contextBlock`. |
| `JudgeVerdict` | New struct | `{ tensionExists: Bool, userState: UserState, shouldProvoke: Bool, entryId: String?, reason: String }` |
| `UserMemoryService` | Unchanged | Continues to assemble the memory block for each turn. |
| `LLMService` | Extended | Before the main call, invokes `ProvocationJudge`, selects profile, composes system prompt. |
| `GovernanceTelemetryStore` | Extended | New event type for judge verdicts + user feedback events. |
| `ChatMode` | Unchanged structurally, semantically demoted | No longer gates behavior; passed as input to judge. |

## Data Flow (Single Turn)

1. User sends a message.
2. `UserMemoryService.assembleMemoryBlock(...)` returns the entries for this turn (unchanged from today).
3. `ProvocationJudge.judge(userMessage, memoryEntries, chatMode)` runs. One small-model LLM call. Returns `JudgeVerdict`.
4. `GovernanceTelemetryStore.recordJudgment(verdict)` — synchronous, non-blocking on failure.
5. Profile selection:
   - `verdict.shouldProvoke == false` → `BehaviorProfile.supportive`
   - `verdict.shouldProvoke == true` → `BehaviorProfile.provocative` + inject a line into the main prompt pointing at `verdict.entryId`.
6. `LLMService.stream(...)` runs the main call with the composed system prompt.

### Critical Timing

- Judge is on the critical path of the main call — the main prompt depends on its output.
- Target latency: **p50 ≤ 500ms**, **p95 ≤ 1.5s**.
- Timeout: **1.5s hard deadline**. On timeout → fallback to `.supportive`, log the timeout.

### Why Judge Reuses Retrieved Entries

- One retrieval pass is cheaper.
- Guarantees the judge cannot reference entries outside the current scope (v2.2 scope-boundary invariant is preserved by construction).
- If the main retrieval missed an entry, the judge will not hallucinate one in.

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

**Rules encoded in the prompt:**

- `should_provoke == true` REQUIRES `tension_exists == true`, `user_state != "venting"`, and a non-null `entry_id` drawn from the supplied entries.
- `user_state == "venting"` forces `should_provoke == false` regardless of tension. Venting is a signal to support, not to challenge.
- `entry_id` must match the ID of an entry in the provided pool. (Enforced in code post-parse; if the judge returns an unknown ID, we treat it as a Scenario 3 failure — see below.)

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
| 1. Judge API call fails or times out | Fallback to `.supportive`. Log timeout/error. Main reply proceeds normally. |
| 2. Judge returns malformed JSON | Same as 1. Log `warning` level. Signals judge prompt needs iteration. |
| 3. Judge returns `entry_id` not in the provided entry pool | **Do not** pass the ID to the main model. Downgrade to `.supportive`. Log at `error` level — this is a scope-boundary safety issue, not merely a quality issue. |
| 4. User feels a provocation was wrong | Lightweight 👍 / 👎 affordance on any provoked reply. Writes `{ verdict, user_feedback }` to `GovernanceTelemetryStore`. No runtime retraining — the data is for weekly human review. |
| 5. User sends a new message while previous turn's judge is still running | Cancel the in-flight judge call immediately. A stale verdict must never inform a newer turn's reply. |

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
| `ProfileSelection` | Verdict permutations map to the expected profile |

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

## Dependencies / Preconditions

- **v2.2 block-level `memory_entries`** already merged (PRs #4–#7). Without entry-level addressability, `entry_id` citation is not possible.
- `GovernanceTelemetryStore` already exists in the branch — schema will be extended for verdict + feedback events.
- `ChatMode` enum already exists; no schema change, only semantic demotion.
- Existing `MemoryDebugInspector` view will gain a new tab; no new view hierarchy needed.

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
