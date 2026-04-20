# ChatMode UI Removal — Design Spec

**Date:** 2026-04-17
**Branch target:** TBD (new branch, forks off `alexko0421/proactive-surfacing` or `main` post-merge)
**Status:** APPROVED

## Problem

Nous's Welcome view currently exposes a `ChatModePicker` chip row (`Companion` / `Strategist`). This contradicts the product's stated principle:

> AI judges per-turn (not user mode toggles); behaviors as swappable named profiles, not mega-conditional prompts.

The proactive-surfacing feature we just shipped introduced a per-turn `ProvocationJudge` that already classifies `shouldProvoke` + `userState` + `entryId` + `BehaviorProfile` before each main LLM call. The same judge should pick the turn's framing mode, replacing the user-facing toggle.

## Goal

Remove the `ChatModePicker` UI. Let the `ProvocationJudge` infer `ChatMode` per turn with a soft continuity bias, so tone stays stable within a conversation but adapts when the user's register clearly shifts.

## Non-goals

- Renaming `ChatMode` enum cases (`companion` / `strategist` stay as-is).
- Local-provider heuristic inferrer (deferred; `.local` falls back to `Companion`).
- Migrating or rethinking the `Direction` / `Brainstorm` / `Mental Health` quick-action chips on Welcome view — those are prompt shortcuts, not mode toggles. They stay.
- Schema migration of existing conversations. `ChatMode` is runtime state only (already verified: stored only on `judge_events`, not on `conversations` / `nodes`).

## Design decisions

### D1. Judge owns mode selection

`ProvocationJudge` gains one output field (`inferredMode`) and one input param (`previousMode`). The existing `chatMode` param is removed because, after the UI is gone, it would be the same value as `previousMode` — duplicate state that makes call sites ambiguous.

```swift
// Sources/Nous/Models/JudgeVerdict.swift
struct JudgeVerdict {
    // existing fields: shouldProvoke, userState, entryId, reason, behaviorProfile...
    let inferredMode: ChatMode   // NEW

    enum CodingKeys: String, CodingKey {
        // existing keys (snake_case convention): should_provoke, user_state,
        // entry_id, behavior_profile, ...
        case inferredMode = "inferred_mode"   // NEW
    }
}

// Sources/Nous/Services/ProvocationJudge.swift
protocol Judging {
    func judge(
        userMessage: String,
        citablePool: [CitableEntry],
        previousMode: ChatMode?,   // nil on first turn
        provider: LLMProvider
    ) async throws -> JudgeVerdict
}
```

**JSON key convention.** All `JudgeVerdict` JSON fields use snake_case (`should_provoke`, `user_state`, `entry_id`, `behavior_profile`). The new field follows the same convention: `"inferred_mode": "companion" | "strategist"`. Fixture JSON and test strings MUST use snake_case; `CodingKeys` maps the Swift camelCase property to the JSON key.

### D2. Soft continuity bias in the judge prompt

Judge prompt gains a paragraph:

> Previous turn mode: `{previousMode.rawValue}` (or `"none (first turn)"`).
> Prefer continuity — only switch if the user's register clearly shifted (e.g. casual-emotional → structured-analytical, or vice versa).
> Output field: `inferred_mode ∈ {"companion", "strategist"}` (snake_case, matches D1 JSON contract).

Behavior from earlier brainstorming (option Y):
- Turn 1 casual → Companion
- Turn 2 more casual → Companion (delta small, stays)
- Turn 3 "help me brainstorm for a presentation" → Strategist (strong signal, switches)
- Turn 4 "ok let me start the outline" → Companion (register snap-back, switches)

No hard-coded hysteresis in Swift; the bias lives in the prompt. This keeps behavior tunable by editing the judge prompt and observing the `judge_events` review tab.

### D3. Reordered `send()` flow

The old flow assembled context with `activeChatMode` *before* the judge ran, which would now use a stale (previous-turn) mode as the current-turn framing. The judge must run first; its output drives this turn's context.

`activeChatMode` becomes `ChatMode?` (was `ChatMode = .companion`). `nil` means "this conversation has no prior judged mode" — either a brand-new chat, or a reopened chat whose node has no `judge_events` rows. This lets the judge receive a true `nil` on first turn rather than a defaulted `.companion`.

Ordered steps inside `ChatViewModel.send()`:

1. Retrieve citable pool (unchanged).
2. Run judge with `previousMode: activeChatMode`. Returns `verdict?` (nil on `.local`, timeout, error).
3. Compute `effectiveMode: ChatMode`:
   - Judge ran successfully → `verdict.inferredMode`
   - Any fallback path → `activeChatMode ?? .companion`
4. `assembleContext(..., chatMode: effectiveMode)` — system prompt and context blocks use the freshly-decided mode.
5. **Append `judge_events` now** (before main call) with `chatMode: effectiveMode`, `messageId: nil`. Rationale: `judge_events` is the hydration source for mode continuity (see D5), so it cannot be gated on main-call success.
6. **`activeChatMode = effectiveMode`** (persist runtime state NOW, before the main call can fail). Rationale: if the main call throws and the user retries without reloading, the next `send()` must see the freshly-judged mode as `previousMode`, not a stale one. Pairing this with step 5 keeps runtime state and the persisted `judge_events` row in sync on every path.
7. Main LLM call.
8. Save assistant message to `NodeStore`; patch `judge_events.messageId` with the saved message id.

Failure modes:
- If step 7 throws: steps 1–6 are durable. `activeChatMode` already reflects `effectiveMode`, and the `judge_events` row exists (with `messageId: nil`). A subsequent send in the same session has correct `previousMode`; a later `loadConversation` also hydrates correctly from `judge_events`. Continuity survives with or without a reload.
- If step 2 (judge) throws or is skipped (`.local` or timeout): `effectiveMode` falls back to `activeChatMode ?? .companion`; steps 5–6 still run so the row and runtime state stay consistent.

### D4. UI removal

Files touched:
- **Delete** `Sources/Nous/Views/ChatModePicker.swift` entirely.
- `Sources/Nous/Views/WelcomeView.swift`: remove `selectedChatMode`, `onChatModeSelected`, and the `ChatModePicker` call at line ~70. Keep Welcome layout and the quick-action chips ("Direction" / "Brainstorm" / "Mental Health").
- `Sources/Nous/Views/ChatArea.swift`: remove any `ChatModePicker` usage (line ~128).
- `Sources/Nous/App/ContentView.swift`: remove `selectedChatMode` state + the binding passed to `WelcomeView`/`ChatArea`. Remove any call to `chatVM.setChatMode(_:)`.
- `Sources/Nous/ViewModels/ChatViewModel.swift`: remove `setChatMode(_:)` public method. `activeChatMode` stays as internal state.

### D5. Conversation-switch hydration

Because `ChatMode` is runtime-only, switching between chats without a rehydrate would let the previous conversation's `activeChatMode` bleed into the new one.

Source of truth: the newest row in `judge_events` for that conversation's node.

New `NodeStore` method:
```swift
func latestChatMode(forNode nodeId: UUID) throws -> ChatMode?
// SELECT chatMode FROM judge_events
//   WHERE nodeId = ? ORDER BY ts DESC LIMIT 1;
```

Call sites in `ChatViewModel`:
- `loadConversation(_:)`: set `activeChatMode = try? nodeStore.latestChatMode(forNode: node.id)` — keep `nil` if the node has no `judge_events` rows (chat was created but never sent; next send should get `previousMode: nil`).
- `startNewConversation(...)`: set `activeChatMode = nil` — brand-new chat has no prior judgment.

Both methods are already `@MainActor` after the proactive-surfacing work, so no new isolation concerns.

### D6. Fallbacks

| Path | `effectiveMode` source |
|---|---|
| First turn of new chat, judge runs OK | `verdict.inferredMode` |
| First turn of new chat, judge fallback | `activeChatMode ?? .companion` = `.companion` |
| Continuing turn, judge runs OK | `verdict.inferredMode` |
| Continuing turn, `.local` / timeout / error | `activeChatMode ?? .companion` = prior judged mode |
| `loadConversation` into node with no `judge_events` | `activeChatMode = nil`; next turn behaves as "first turn of new chat" above |

The `ProvocationJudge`'s existing `fallbackReason` telemetry already captures why a fallback occurred; no new reason codes needed.

### D7. Quick-action opener path

The Welcome quick-action chips (`Direction` / `Brainstorm` / `Mental Health`) call `ChatViewModel.beginQuickActionConversation(_:)`, which is a canned one-shot LLM call: it creates a new conversation, assembles context with a pre-written opening prompt, calls the main LLM once, and saves the assistant message. There is no user message to judge on this turn.

Rule: **the quick-action opener uses `.companion` as a hardcoded framing and does not run `ProvocationJudge`.**

Concretely in `beginQuickActionConversation(_:)`:
- `assembleContext(..., chatMode: .companion)` — the opener is a warm, neutral "AI's opening move," not something the user asked for in a specific register yet.
- No `judge_events` row is appended. The opener is not a judged turn.
- `activeChatMode` stays `nil` after the opener completes. This matters: the user's first real reply afterward is still treated as a first judged turn (`previousMode: nil` in the judge call), so the judge can freely pick either mode based on the user's register rather than being anchored to `.companion`.

This keeps the quick-action path simple (no new judge call on a prompt the user didn't write) and preserves the "first real turn" property of the subsequent user message.

## Tests

### Unit tests (`Tests/NousTests/ProvocationOrchestrationTests.swift`)

- `testJudgeVerdictParsesInferredMode` — verdict JSON with `"inferred_mode": "strategist"` (snake_case per D1) round-trips into `JudgeVerdict.inferredMode == .strategist`.
- `testFirstTurnPassesNilPreviousMode` — `CannedJudge` records the `previousMode` arg it received; assert nil.
- `testSecondTurnPassesPriorInferredMode` — after T1 returns `.strategist`, T2's `previousMode` arg equals `.strategist`.
- `testSystemPromptUsesEffectiveModeNotActiveModePre` — assemble happens with inferred mode, not stale prior.
- `testLocalProviderFallbackKeepsActiveMode` — `.local` path: `effectiveMode == activeChatMode`.
- `testJudgeTimeoutFallbackKeepsActiveMode` — timeout path: `effectiveMode == activeChatMode`.
- `testJudgeEventAppendedBeforeMainCall` — use a failing main-call stub; assert `judge_events` row exists after throw.
- `testActiveChatModeUpdatedBeforeMainCall` — use a failing main-call stub; after the throw, assert `activeChatMode == verdict.inferredMode` (not the pre-turn value). Guards continuity on retry-without-reload.
- `testLoadConversationHydratesFromLatestEvent` — seed `judge_events` with `.strategist` latest, load node, assert `activeChatMode == .strategist`.
- `testLoadConversationKeepsNilWhenNoEvents` — empty `judge_events`, assert `activeChatMode == nil` (so the next send treats it as a first judged turn with `previousMode: nil`).
- `testStartNewConversationResetsToNil` — regardless of prior state, new chat starts `activeChatMode == nil`.
- `testQuickActionOpenerUsesCompanionAndDoesNotRunJudge` — invoke `beginQuickActionConversation(_:)`, assert (a) the assembled context used `.companion`, (b) no `judge_events` row was written, (c) `activeChatMode` is still `nil` after the opener.

### Fixture bank (`Tests/NousTests/Fixtures/ProvocationScenarios/`)

- Each of the 5 existing fixtures gains `expected.inferred_mode`.
- `ProvocationFixtureRunner` diff-reports `inferred_mode` alongside `should_provoke` / `user_state` / `entry_id`.
- Add 1 new fixture: `06-register-shift-snaps-back.json` — two-turn scenario where T1 strategist analysis → T2 "ok I'll start" expects `inferredMode: companion` with `previousMode: strategist` in the request.

## Rollout

Single PR, forks off whatever base is current (likely `main` after `alexko0421/proactive-surfacing` merges, otherwise off that branch).

Estimated diff: ~50 lines production + ~80 lines tests + 6 fixture JSON updates.

No feature flag. No migration. Failure modes (if judge prompt is miscalibrated and flips too often) are observable in the existing `MemoryDebugInspector` judge-events review tab — tune the prompt and iterate.

## Open questions

None at time of approval.

## Deferred (explicit YAGNI)

- **`.local` heuristic inferrer.** Brainstormed as Approach B. Rejected because Cantonese / English / mixed prompts make regex / keyword matching brittle. If dogfood shows `.local` users are permanently stuck in Companion and it degrades the experience, pull the heuristic into its own small PR.
- **Rethinking Companion/Strategist.** Out of scope; this spec is about who picks the mode, not what the modes are.
