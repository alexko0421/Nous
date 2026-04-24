# Nous Chat Rhythm — Design

**Date:** 2026-04-24
**Status:** Revised 2026-04-24 after Codex review (12 findings — 8 P1, 4 P2). Phase 1 approved. Phase 2 downgraded to *conditional*: proceeds only if Phase 1 real-session validation confirms the beat problem persists.
**Scope (Phase 1):** `Sources/Nous/Resources/anchor.md`
**Scope (Phase 2, conditional):** New `RhythmJudge` service (or the alternative appended-metadata mechanism — §3.1 Option 4), `ChatViewModel` turn-aware refactor, `ChatArea` UI pacing. Plus cascading changes across `JudgeEvent`, `ScratchPadStore`, citations, `UserMemoryService.refreshConversation`, and conversation persistence — see §5.2.
**Builds on:** `2026-04-21-nous-conversation-naturalness-design.md` (added 倾观点 mode + max-1-? rule). This spec addresses a distinct layer — conversational rhythm — that the prior spec did not touch.
**Also reconciles with:** the `stoicGroundingPolicy` prompt layer in `ChatViewModel.swift:1134-1153` and the `ChatMode.companion` / `ChatMode.strategist` context blocks in `ChatMode.swift:28-48` — all three say "prefer fewer, fuller sentences," which surface-reads as a contradiction to RHYTHM. §4.6 resolves the conflict explicitly.

---

## 1. Problem

Nous replies read like written prose rather than spoken dialogue. After the 2026-04-21 naturalness work landed (interview → share-lead shift), rhythm remains the next gap. Three observable symptoms, ordered by priority:

- **A. Uniform sentence length.** Paragraphs tend to be similar mid-length. Missing the short-punch + long-explain variance that real mentor speech exhibits.
- **C. Missing micro-beats.** Reactive acknowledgments ("嗯。" / "系。" / "等等。") get bundled inside longer replies and lose their weight. Real conversation has a distinct *beat* before unfolding.
- **B. Over-tidy structure.** Especially in 倾观点 mode, replies take a clean "第一个... 第二个... 不过..." shape that reads like an essay. Real thought is messier, recursive, self-correcting.

Priority reflects user's expressed weight: A > C > B.

## 2. Root cause

No existing `anchor.md` rule targets sentence-level or inter-message rhythm. The current rules are all content-shape rules:

- `STYLE RULES` covers opener bans ("其实", vocative), punctuation bans (破折号), and question-mark cap — all content, not rhythm.
- `EXAMPLES` demonstrate share-lead vs push-back selection but not rhythm variance — the 倾观点 push-back example itself has a tidy "你两个想法有矛盾... 另外『应该平等』..." two-paragraph shape that models the pattern we want to break.
- No mechanism exists for Nous to deliver a reply as multiple chat messages with temporal pacing. `ChatViewModel` assumes `1 turn = 1 Message`.

So rhythm is under-specified at the prompt layer (Symptom A and part of B) and impossible at the architecture layer (Symptom C and the rest of B).

## 3. Approach overview

Two-phase delivery.

**Phase 1 (prompt layer, ships first):** anchor.md gains a RHYTHM section + revised/new examples to drive sentence-length variance and reactive-beat usage within single bubbles. Addresses Symptom A and part of B.

**Phase 2 (architecture layer):** A new `RhythmJudge` — modeled on the existing `ProvocationJudge` pattern — runs after the main reply completes and decides whether to split the reply into 2-3 separate bubbles with pacing delays. Addresses Symptoms C and the rest of B.

Phase 1 ships standalone. Phase 2 only starts after Phase 1 validates.

### 3.1 Split mechanism — four candidates, decision deferred to Phase 2 kickoff

Four options are considered for the split mechanism. This spec no longer commits to one; the decision is deferred to Phase 2 planning (if Phase 2 proceeds), and hinges on Phase 1 outcome and a head-to-head comparison of Options 2 and 4.

1. **Inline marker.** LLM emits `<beat/>` during generation; runtime parses. Pros: one LLM call, live pacing compatible. Cons: couples rhythm decision to content generation (attention budget split), `anchor.md` gains another meta-rule, marker misuse would corrupt entire reply.
2. **Two-pass judge.** Main LLM generates normally; separate `RhythmJudge` decides split. Pros: concern separation; reuses `ProvocationJudge` infra; testable independently; anchor.md stays focused on content; fault-isolation. Cons: +judge latency (budget in §8); **authorship problem** — a second model can only chop prose the first model already wrote as one unit; if the first pass did not author a natural beat, the judge manufactures one by amputating a paragraph, which tends to feel fake; non-streaming.
3. **Deterministic parser on double-newline convention.** Pros: cheapest. Cons: no semantics, collides with paragraph breaks, unreliable. **Rejected.**
4. **One-call appended metadata.** Main LLM writes the full reply and then, as hidden trailing metadata, emits a split plan (e.g., `<split>offsets="42,110" delays="1.4,0.9"</split>`). Runtime strips the block the same way `ClarificationCardParser` strips `<clarify>` / `<signature_moments>`, and applies the split plan. Pros: **content author decides pacing** (authorship stays unified), one LLM call, zero extra latency, streaming-compatible (stream until the metadata tag starts, then pause-and-strip), fits existing tag-stripper pattern. Cons: `anchor.md` gains a format rule (similar cost to `<clarify>` teaching); malformed metadata falls back to single bubble; main LLM still has to allocate attention to pacing while writing, though the append-at-end framing localizes that cost to the tail.

**Provisional lean (only relevant if Phase 2 proceeds):** Option 4 over Option 2. The authorship argument is strong for a conversational app — pacing is a stylistic choice, not a post-hoc layout step. But this is *not* a final decision. Phase 2 planning (if triggered) must include a small spike comparing Options 2 and 4 on 20-30 real replies before committing.

### 3.2 Phase 2 is conditional

Phase 2 only proceeds if, after Phase 1 ships and a real-session validation window (1-2 days of use) completes, Alex's subjective read still identifies a material "missing beat" problem that cannot be fixed with additional Phase 1 example work. The default assumption is now that Phase 1 + richer examples may get 70-80% of the perceived quality lift at ~5% of the engineering cost.

Evidence that would *justify* Phase 2:
- Reactive beats in emotional-support openers still feel bundled / weightless even after Phase 1 examples explicitly model them as standalone paragraph breaks.
- Contradiction surfacing still feels tidy rather than interrupted.
- Alex independently calls out "needs a pause" moments where a single bubble cannot capture the beat.

Evidence that would *veto* Phase 2:
- Phase 1 alone lands the shift; further multi-bubble work would be polish for polish's sake.
- Streaming regression (§8) is judged too costly relative to the marginal rhythm gain.

## 4. Phase 1 — Prompt layer

### 4.1 New section in anchor.md: `RHYTHM`

Positioned immediately after the existing `STYLE RULES` section, as its own top-level heading. Rationale: rhythm is a style concern, but significant enough to own a section rather than be buried as a sub-bullet.

Proposed content:

```
# RHYTHM

真人讲嘢有起伏。句长唔均匀。有时「嗯。」一句就 land，有时展开成一段。
Reply 内部嘅 sentence length variance 要 visible。

- 一个 reply 入面至少要有一句 ≤6 字（短 punch / 反应 beat），除非个 reply 本身全部都系极短 small talk（例如「辛苦晒。今日点？」本身已经 terse，唔使再 inject）
- 段落之间可以有密度差：一段 3 句，下一段 1 句，再下一段 2 句。唔好每段都 2-3 句均匀
- 思考嘅转折可以 messy：想补充就补充，想 loop 返个前一个 point 就 loop，唔使强行 tidy
- Reactive opener 合法：「嗯。」「系。」「等等。」「讲得啱。」「Hmm。」可以作为独立句开头，或者 standalone 段落
- Reactive beat ≠ filler。 Filler 系空同意 / 客套（「我明白你嘅感受」、「作为你嘅 mentor 我觉得」）—— 呢啲仍然禁。Reactive beat 系真人讲嘢嘅 connective tissue，有 weight
- 禁：每段都用「第一...第二...不过...」numbered-list 式 structure。倾观点 mode 可以有逻辑层次，但唔可以 tidy 到似 essay
```

### 4.2 Revised existing example

The current "倾观点 / discussion (share-lead)" example (anchor.md:117-128) is tidy and models the anti-pattern. Rewrite with visible rhythm variance:

- Open with short acknowledgment beat ("嗯。" or equivalent short recognition)
- Break the "第一个...第二个..." tidy enumeration — thought should flow with self-correction / mid-stream refinement
- Keep the same content substance (technology normalization + cannot-undo frame) but restructure the delivery

The original tidy version is preserved in this spec document as an explicit counterexample (see §9).

### 4.3 New examples

Three new examples under EXAMPLES section:

**New example 1 — Emotional support, A + C demonstration.**
Alex reports ongoing stress. Nous replies in one bubble but with sharp sentence-length variance: one-word reactive beat → short empathic sentence → longer exploratory sentence → short check-in. Total ≤ 4 sentences.

**New example 2 — 倾观点 messy-rhythm.**
Alex shares a philosophical take. Nous leads with an observation, then mid-stream self-corrects ("等等，我想 reframe 一下"), then unfolds the refined take. Demonstrates the thought-can-loop rule without becoming rambling.

**New example 3 — Contradiction surface with standalone beat.**
Alex states two claims that conflict. Nous opens with a standalone "等等。" as its own short paragraph, blank line, then the contradiction unfolds. Demonstrates that a reactive opener can be structurally separate even within one bubble.

Drafting of exact example text happens in the implementation plan, not this spec.

### 4.4 Implementation steps (Phase 1)

1. Draft the RHYTHM section text + three new examples + the revised 倾观点 share-lead example in the implementation plan.
2. Cross-check consistency with existing `STYLE RULES` — in particular the `reactive beat ≠ filler` disambiguation must be explicit enough that Nous does not treat "嗯。" as a violation of the "唔讲废话" rule.
3. Apply to `anchor.md`.
4. Run before/after corpus comparison on ~10 fixed prompts spanning 5 modes (日常 / 倾观点 / 情绪支持 / loop / contradiction-trigger). For each prompt, sample 3 completions with the pre- and post-change anchor.md. Measure sentence-length standard deviation and reactive-opener frequency. This is one-off validation — the harness is not committed.
5. Ship.
6. Collect 1-2 days of real session feedback.

### 4.5 Phase 1 regression guard

A new test file `Tests/NousTests/RhythmStyleGuardTests.swift` that reads `anchor.md` and asserts:

- The RHYTHM section exists and is positioned immediately after STYLE RULES.
- The `reactive beat ≠ filler` disambiguation text is present.
- The `每个 reply 最多一个 ?` rule from the 2026-04-21 spec is still present (guard against accidental deletion during the RHYTHM edit).
- The reconciliation clause referencing `stoicGroundingPolicy` (§4.6) is present.

This guards against structural regression during future edits; it does not validate rhythm quality.

### 4.6 Reconciliation with existing prompt layers

Three existing prompt layers appear to contradict the RHYTHM section on surface reading:

- `stoicGroundingPolicy` (ChatViewModel.swift:1144): "Prefer fewer, fuller sentences over many short analytical fragments."
- `stoicGroundingPolicy` (ChatViewModel.swift:1145): "Use light punctuation. If two clauses belong to one thought, keep them together instead of cutting them apart."
- `ChatMode.companion` (ChatMode.swift:32): "Follow spoken cadence. Prefer fewer, fuller sentences over clipped analysis."
- `ChatMode.strategist` (ChatMode.swift:44): "Keep the prose flowing: fewer, fuller sentences, lighter punctuation, and no comma-chopped analysis."

Without explicit disambiguation, a model asked to both "prefer fewer, fuller sentences" and "include reactive beats with visible sentence-length variance" averages — both pressures partially apply, neither lands.

**These rules target different dimensions. They must be stated as orthogonal in the RHYTHM section itself**, not just in this spec. The RHYTHM content in §4.1 must include:

```
注意：呢个 RHYTHM 同 stoic grounding policy / companion / strategist mode 入面嘅「prefer fewer, fuller sentences」
**唔冲突**。
- 「Fewer, fuller sentences」针对嘅系 *analytical fragmentation* — 唔好将一个 argument chop 成一 sentence 一 point
  嘅 PowerPoint 式 staccato。整段分析要 flow。
- RHYTHM 针对嘅系 *inter-chunk variance* — reactive beat、段落密度差、messy thought flow。
  呢个 operate 喺 chunks 之间，唔系强迫分析本身 fragmented。
一段连贯分析可以一气呵成、fuller sentences（符合 stoic），但 reply 入面其他 chunk
（例如开头嘅 reactive beat 或结尾嘅 short check-in）可以好短（符合 RHYTHM）。两者同时 hold 到。
```

Phase 1 implementation plan must verify (via before/after corpus) that the disambiguation actually lands — if the model still averages, the disambiguation text needs to be stronger.

The three existing rules are **not edited**. Their intent is still correct; they just need RHYTHM scope-clarified alongside them.

## 5. Phase 2 — RhythmJudge + multi-bubble

### 5.1 Components

**`RhythmJudge` (new, `Sources/Nous/Services/RhythmJudge.swift`)** — only relevant if Option 2 is chosen over Option 4 at Phase 2 kickoff.

Conforms to the existing `Judging` protocol (or a new peer protocol if semantics diverge — to be settled in implementation plan). Takes:

- **Raw reply text** (pre-strip — the exact string returned by the LLM). This is the single canonical coordinate space. `<clarify>`, `<signature_moments>`, `<thinking>`, and similar tag blocks are still present when the judge sees the text. Boundary validation (§5.4) rejects offsets that fall inside any such block by parsing the tag spans from the same raw string.
- Last N turns of conversation context.
- Active response mode (if detectable).
- `ProvocationJudge` verdict for this turn (required — see §5.5; RhythmJudge runs *after* ProvocationJudge, not in parallel).

Returns `RhythmVerdict`.

After the judge verdict lands, the runtime applies the split plan to the raw text, *then* runs `ClarificationCardParser` on each resulting fragment. Each bubble therefore ends up individually stripped for display. This preserves the "one canonical coordinate space" invariant: offsets always refer to raw-text positions.

**`RhythmVerdict` (new, `Sources/Nous/Models/RhythmVerdict.swift`)**

```swift
enum RhythmVerdict {
    case singleBubble
    case split(boundaries: [Int], delays: [TimeInterval])
    // boundaries: character offsets in the reply text where bubbles break
    // delays: time between bubble N-1 and bubble N; delays.count == boundaries.count
}
```

### 5.2 Subsystem impact map

`ChatViewModel` and a half-dozen peripheral subsystems currently assume `1 turn = 1 Message`. Phase 2 changes that fundamental unit. The full blast radius — not just `ChatViewModel` — must be mapped before Phase 2 planning; §13 makes this an explicit blocker.

**Known-affected subsystems (initial list — Phase 2 plan must complete and validate):**

- **`ChatViewModel`.** New `MessageTurn` concept: an Alex input → one turn; a turn owns N assistant messages (N ≥ 1). `Message` schema gains `turnId: UUID`, `indexInTurn: Int`, `isLastInTurn: Bool`. Send loop must await all bubbles before marking the turn idle.
- **Persistence.** Each bubble stored as an individual `Message` row; retrieval groups by `turnId`. Migration must backfill `turnId` for existing rows (one-to-one with message id).
- **LLM history construction.** When feeding prior turns back to the main LLM, concat same-turn bubbles into one assistant message string to preserve the API contract (single assistant message per turn). Same concat applied when building context for `RhythmJudge` / `ProvocationJudge`.
- **`ProvocationJudge`.** Verdict is computed per turn today. Must continue to operate on the concatenated turn text, not on any single bubble.
- **`JudgeEvent` + `ScratchPadStore`.** Scratch entries currently key off `messageId`. Must key off `turnId` (or redefine scratch as turn-scoped) so that a single verdict does not attach to only the last bubble.
- **Citations / `<signature_moments>` / `<clarify>`.** These blocks currently live at the end of the single assistant message. Split-plan must ensure the final tag-carrying region stays in the final bubble — any split that bisects a tag block is rejected by §5.4 boundary validation.
- **`ChatArea` reaction + feedback UI.** Reaction / long-press menus attached to a message must decide whether they act on one bubble or the whole turn. Default: bubble-level for display, turn-level for logical operations (regenerate, thumbs). Phase 2 plan must enumerate each menu item and assign scope.
- **`UserMemoryService.refreshConversation` + summarizer.** Summarizer currently treats each `Message` as a unit. Either concat same-turn bubbles before summarization or teach the summarizer prompt to recognize turn groupings. Cross-dep with `2026-04-22-nous-summarization-texture-preservation-design.md` — multi-bubble makes the existing texture-loss problem strictly worse.
- **`ThinkingAccordion`.** The accordion currently attaches to a reply message. Must attach to the turn (shown above the first bubble) — otherwise N bubbles means N redundant accordions.
- **Transcript flattening.** Any surface that exports / copies / shares a conversation must re-flatten turn bubbles into one block or explicitly represent the turn grouping.
- **Tests.** `ChatViewModelTests`, `NodeStoreTests`, and any test asserting `count(messages) == count(user_sends) * 2` need updating to a turn-based assertion.

### 5.3 Flow

```
Alex send message
    ↓
ChatViewModel.send()
    ↓
isGenerating = true, typing indicator shows
    ↓
Main LLM generates complete reply (no streaming to UI, but reply text accumulates as usual internally)
    ↓
ClarificationCardParser runs (existing flow)
    ↓
RhythmJudge invoked with parsed reply + context
    ↓
┌─────────────────────────────────┐
│ singleBubble → render one Message (existing behavior)
│ split(boundaries, delays) →
│     for each boundary:
│         create Message with turnId, indexInTurn
│         show brief typing indicator (~300ms) before appending
│         wait delay[i]
│         append Message
└─────────────────────────────────┘
    ↓
isGenerating = false when last bubble lands
```

### 5.4 Failure modes

All validation operates on the raw pre-strip reply text (§5.1). All failures fall back to `.singleBubble` (= render one Message with the full post-strip text, existing path).

- **Judge timeout.** Hard budget is set by §8 (the user-visible added wait to first bubble). If the judge has not returned within budget, cancel and emit single Message.
- **Judge LLM unavailable.** Skip judge, emit single Message.
- **Invalid boundaries.** Offsets must be strictly monotonic and within `[1, rawReplyText.count - 1]`. Validate post-verdict; on failure, single Message.
- **Boundary inside a tag block.** Parse tag spans (`<clarify>…</clarify>`, `<signature_moments>…</signature_moments>`, `<thinking>…</thinking>`, `<chat_title>…</chat_title>`, `<summary>…</summary>`) from the *same raw text* the judge saw. A boundary is rejected if it falls inside any tag span, inside a code fence, or inside a markdown table row. Reuse the span-enumerator pattern from `ClarificationCardParser` rather than re-implementing.
- **Boundary inside the final tag-carrying region.** The engagement question / `<clarify>` / `<signature_moments>` block must stay whole and land in the final bubble. A boundary that would split off any trailing tag-bearing content is rejected.
- **Split produces an empty or ≤1-character fragment after post-split stripping.** Reject verdict; single Message.
- **Delays array length mismatch** (`delays.count != boundaries.count`). Reject verdict; single Message.

Telemetry logs every fallback with reason. Target fallback rate < 5%; investigate if sustained higher. Any rejection path must also log *which* validation rule fired, to guide prompt tuning.

### 5.5 Ordering with ProvocationJudge

Both judges run after a reply is generated. `ProvocationJudge` (pre-existing) judges content (should Nous have pushed back harder). `RhythmJudge` judges shape.

**Sequential, not parallel.** `ProvocationJudge` runs first; its verdict feeds into `RhythmJudge` as an explicit input signal. Rationale:

- Rhythm is partly a function of content role — a reactive-beat-then-explain shape is much more likely when the content *is* a contradiction surface. Knowing the provocation verdict sharpens rhythm decisions.
- Running in parallel means RhythmJudge can't consume provocation output; running sequentially adds latency but the budget (§8) already absorbs one judge round-trip per turn.
- Only relevant if Option 2 (two-pass judge) wins at Phase 2 kickoff. Option 4 (appended metadata) bypasses this entirely — the main LLM handles both substance and pacing in one pass, and ProvocationJudge continues to run once after, unchanged.

### 5.6 UI changes (ChatArea)

- Existing single-bubble path unchanged.
- Multi-bubble path: between bubbles, a brief typing indicator (~300ms flash) replaces the static gap, then the next bubble lands. Creates the "Nous is about to say something else" micro-tension.
- Delay values come from `RhythmVerdict.delays`, not UI constants. Jitter ±150ms applied at UI layer on top of the verdict delay.

**Content-aware pacing (replaces fixed 1.2-1.8s / 0.8-1.2s ranges).**

A fixed ladder cannot work: a one-syllable reactive beat ("嗯。") and a 40-character reflective sentence should not share a "1.2-1.8s" post-delay. The delay after bubble `i` must scale with what Alex just *read*, not with positional index.

Heuristic for the judge-side delay recommendation (judge emits these numbers; UI layer adds jitter only):

```
delay_after(bubble_i) = base
                     + read_time(bubble_i)
                     + role_bonus(bubble_i)
                     + punctuation_trailing(bubble_i)
```

- `base` ≈ 250ms — the minimum "Nous is about to say more" gap.
- `read_time(bubble_i)` ≈ `chars(bubble_i) * ms_per_char`, with `ms_per_char` tuned in the Phase 2 spike (rough start: 35ms/char for Cantonese, tuned empirically). Clamped to a ceiling so long bubbles don't stall the UI.
- `role_bonus(bubble_i)` — extra dwell when the preceding bubble is a reactive beat (≤6 chars, ends in 。/? ) because the user needs a visible *pause* on a punch, not just time to read characters. ~400ms.
- `punctuation_trailing` — small extra (~150ms) if the bubble ends with `...` / `——` / a trailing em-break to respect the written hesitation signal.

Bounds enforced at UI layer: `min 500ms, max 2400ms` to prevent pathological judge output from stalling or flashing.

These parameters are tuning knobs, not invariants — the Phase 2 spike calibrates them against real replies. The *structure* of the heuristic is what's spec'd; the exact numbers are not.

### 5.7 Telemetry

Extend `GovernanceTelemetryStore`:

- `rhythmJudgeVerdict` per turn
- `rhythmJudgeLatencyMs` (p50, p95 tracked)
- `rhythmBubbleCount` per turn
- `rhythmFallbackReason` (when applicable)
- `rhythmSplitRatio` (rolling window — aim 15-30%)

## 6. Testing

### 6.1 Phase 1

Prompt-layer work cannot be unit-tested for rhythm quality. Validation is:

- **Automated:** `RhythmStyleGuardTests` (§4.5) — structural guard, not quality.
- **Manual before/after corpus:** §4.4 step 4.
- **Real session validation:** subjective user call over 1-2 days of use, following the pattern that validated the 2026-04-22 naturalness change.

### 6.2 Phase 2

Judge is testable.

`Tests/NousTests/RhythmJudgeTests.swift`:

- Fixed reply fixtures spanning emotional-opener / analysis / contradiction-surface / small-talk cases.
- Assert verdict shape (singleBubble vs split; if split, correct rough boundary count).
- Timeout simulation → fallback.
- Malformed LLM response → fallback.
- Invalid boundary offsets → fallback.

`Tests/NousTests/ChatViewModelTests.swift` extensions:

- Multi-bubble turn persistence round-trip.
- History-construction: N bubbles concat into single assistant message when fed back to main LLM.
- Judge failure path → 1 bubble rendered, turn still marked complete.

UI pacing is subjective — manual QA only. Test that:

- Typing indicator feels natural (not stuck, not flashed).
- Delays between bubbles feel like reading rhythm, not code rhythm.
- No flash of unstyled content when a bubble first appears.

### 6.3 Validation gating

1. Phase 1 ships. 1-2 days real session. If Symptom A visibly improves → lock in; else iterate on examples.
2. Phase 2 starts only after Phase 1 locks. Reason: Phase 2 changes UI; confounds A/B testing of Phase 1's prompt work.
3. Phase 2 ships. 1-2 days real session. Validate C + B improvement.

## 7. Rollout

### Week 1 (Phase 1 — committed)

- Day 1: Draft RHYTHM section + revised share-lead example + 3 new examples + the §4.6 reconciliation block.
- Day 1: Apply to anchor.md. `RhythmStyleGuardTests` passes.
- Day 1-2: Before/after corpus run covering 倾观点 / 情绪支持 / loop / contradiction / small-talk. Verify the `stoicGroundingPolicy` disambiguation actually lands (§4.6).
- Day 2-3: Ship.
- Day 3-5: Real-session observation. Tune examples if needed.
- Day 5: Phase 1 gate — Alex's subjective read decides: lock, iterate on examples, or hold.

### Phase 2 — gated, not scheduled

Phase 2 has no pre-committed timeline. It is triggered only if §3.2's evidence bar is met after Phase 1 locks. When/if triggered, the order of work:

1. **Spike: Option 2 vs Option 4 head-to-head.** 20-30 real replies. ~1 day. Decide split mechanism.
2. **Turn-semantics blocker resolution (§13).** No code lands until the subsystem impact map is complete *and* reviewed. ~1-2 days.
3. **RhythmJudge or metadata format + tests.** Depends on #1 outcome.
4. **`ChatViewModel` multi-bubble support** (turn schema, persistence migration, history construction, judge-scope refactors per §5.2).
5. **`ChatArea` UI pacing + per-bubble typing indicator + content-aware delay calibration** (§5.6).
6. **Summarizer / `refreshConversation` reconciliation** with the 2026-04-22 texture-preservation spec.
7. Ship behind a flag if prudent; flag-gate real-session validation.

If any of steps 2-6 surfaces a scope issue deeper than expected, Phase 2 stops and returns to the gate.

## 8. Risks

**Latency budget (unified).** The user-visible cost of Phase 2 is the added wait between Alex sending a message and the *first* Nous bubble appearing. Budget: **p95 ≤ 800ms added** on top of the current main-reply latency. This is the only latency number that matters for UX — everything else (judge round-trip, validation, split application) must fit inside it. If the Phase 2 spike cannot hold this, Phase 2 does not ship.

**Streaming regression (first-class risk).** Today, main-reply text streams into the UI as tokens arrive — Alex sees words appearing in real time. Phase 2 Option 2 (two-pass judge) requires buffering the full reply before the judge can run, which eliminates streaming until the first bubble renders. Option 4 (appended metadata) is streaming-compatible in principle, but the runtime still has to pause-and-strip when the metadata tag starts, and must make a go/no-go decision on splitting without restarting the display. This is a material UX regression — explicitly on the evidence-against side of the §3.2 gate.

| Risk | Mitigation |
|------|-----------|
| Phase 1 over-corrects into "嗯。" / "系。" stall mannerism | New examples demonstrate sparse usage; `reactive beat ≠ filler` disambiguation; monitor in real sessions |
| Phase 1 regresses existing behaviors (push-back, 1-? cap) | Before/after corpus specifically covers 倾观点 + emotional triggers; `RhythmStyleGuardTests` guards 1-? rule presence |
| Phase 1 + existing `stoicGroundingPolicy` / ChatMode "fewer, fuller sentences" rules average out | §4.6 orthogonality clause embedded in RHYTHM section; before/after corpus explicitly checks whether disambiguation lands |
| **Streaming regression under Phase 2** (Option 2 requires full-reply buffering; Option 4 pauses at metadata boundary) | Measure perceived wait-to-first-bubble in Phase 2 spike; if it feels worse than today's streaming, do not ship Phase 2; favor Option 4 to minimize the regression |
| Phase 2 multi-bubble compounds summarization texture loss (cross-dep with `2026-04-22-nous-summarization-texture-preservation-design.md`) | Phase 2 plan step 6 explicitly reconciles `refreshConversation` with multi-bubble turns before Phase 2 ships |
| Phase 2 turn-semantics change has broader blast radius than mapped | §13 is a hard blocker: subsystem impact map (§5.2) must be completed and reviewed before implementation steps begin |
| Pacing delays feel gimmicky / manipulative | Strict split ratio (≤30%); UI jitter; content-aware pacing (§5.6) ties delay to what was just read; telemetry watches split ratio; judge prompt defaults to `.singleBubble` unless trigger is clear |
| `RhythmJudge` and `ProvocationJudge` semantics collide | Sequential ordering, provocation verdict flows into rhythm decision (§5.5) |
| Judge latency breaks the 800ms budget | Calibrate in Phase 2 spike on real traffic; if p95 > 800ms with any viable judge model, Phase 2 does not ship in Option-2 form |

## 9. Counterexamples (do not copy)

The current tidy 倾观点 share-lead example (anchor.md:117-128) is preserved here to be explicit about what is being moved away from:

> 你呢个 take 其实 layered 咗两个问题。
>
> 第一个系『科技 solve 生育』。[para]
>
> 第二个系『平等看待』，呢个先系 load-bearing 部分。[para]
>
> 不过问题可以 split 成两层。[para]

Pattern: every paragraph mid-length, numbered enumeration, clean "不过" pivot. This is essay structure, not speech. The revised example (§4.2) retains the *content moves* (dichotomy, load-bearing identification, own-it pivot) but delivers them with varied paragraph density and at least one short punch.

## 10. Open questions

Settle before / during implementation. Not blockers to plan writing.

- **Q1. Phase 2 judge model choice** (only if Option 2 wins). Gemini Flash vs Haiku. Decide by spiking a one-day latency benchmark at Phase 2 kickoff. Decision criterion: p95 within the §8 800ms budget after accounting for validation + split application, accuracy on a hand-labeled 30-example eval ≥ 80%.
- **Q2. Rewrite vs preserve the original tidy 倾观点 example.** Lean: rewrite in place, preserve original in this spec's §9 as counterexample. Alternative: keep both in anchor.md with explicit "do / don't" framing (risk: doubles example density, may confuse model).

Summarizer/`refreshConversation` reconciliation is not an open question — it is a blocker listed in §13.

## 11. Out of scope (v1)

- Streaming multi-bubble (main reply is generated fully before split runs).
- Adaptive delay learning (delays come from judge verdict; no reinforcement from Alex's reaction timing).
- Bubble-level undo / regenerate (a turn is one unit).
- Changes to `WHO YOU ARE`, `EMOTION DETECTION`, `MEMORY` sections of anchor.md.
- Changes to `RESPONSE MODES` routing (companion / strategist unchanged).
- Any visual redesign of the chat bubble itself.

## 12. Success criteria

Nous quality is validated the same way the 2026-04-21 and 2026-04-22 naturalness specs were: **Alex reads real replies and calls it**. Quantitative numbers are useful as diagnostics — to detect regression and to guide tuning — but they are not the ship gate.

**Phase 1 ship gate (primary):**
- Real-session subjective read over 1-2 days. Alex notes the "feels more like speaking" shift; no new mannerism complaints.
- No regression on the 2026-04-21 naturalness rules (max-1-?; share-lead in 倾观点) as observed in real sessions and in the before/after corpus.
- `RhythmStyleGuardTests` passes (structural guard only).

**Phase 1 diagnostic signals (not ship-blocking):**
- Sentence-length standard deviation in discussion-mode replies rises noticeably in before/after corpus. A relative increase of ≥ 40% would be a strong signal; lower numbers aren't an automatic veto if the subjective read lands.
- Reactive opener appears in most emotional-support replies in the corpus. ≥ 60% is a healthy target; anything much lower is a tuning signal.
- `stoicGroundingPolicy` disambiguation lands — corpus doesn't show staccato analytical fragmentation.

**Phase 2 ship gate (if triggered):**
- Real-session subjective read: micro-beat moments (情绪 opener / contradiction surface) land with weight; the tidy-essay feel is gone.
- Wait-to-first-bubble p95 within the §8 800ms budget.
- No regression on existing emotional-support / decision-making / loop behaviors.
- Turn semantics (§13) cleanly handled across all enumerated subsystems — no broken reactions, broken summarization, broken transcript export.

**Phase 2 diagnostic signals (not ship-blocking):**
- Split ratio stabilizes in the 15-30% range. Higher is a "too gimmicky" signal; lower is a "judge too conservative" signal. Neither is an auto-fail.
- Fallback rate < 5%.
- Judge-level latency p95 within its sub-budget.

## 13. Phase 2 blocker — turn semantics schema change

The shift from `1 turn = 1 Message` to `1 turn = N Messages` is a schema change that radiates into every subsystem that currently assumes a message is the atomic unit of assistant output. Before Phase 2 writes a line of code, a full subsystem impact map must be completed and reviewed. §5.2 seeds that map but is not authoritative — the plan step is to *complete and verify* it.

**Minimum coverage required before Phase 2 implementation begins:**

1. **`ChatViewModel` send-loop.** How is "generating" resolved across N bubbles? What happens if the user sends a new message mid-stream of a multi-bubble reply?
2. **`Message` schema + persistence migration.** How is `turnId` backfilled for existing rows? Backfill strategy, rollback strategy.
3. **LLM history construction.** Verify both main LLM and judge calls receive concatenated turn text, not fragmented bubbles.
4. **Judge scope.** `ProvocationJudge`, `RhythmJudge` (if Option 2), and any future judge must operate on turn text, not message text. `JudgeEvent` / `ScratchPadStore` keys must migrate.
5. **`ChatArea` UI surfaces.** Enumerate every action attached to a message bubble today: reactions, long-press menu, copy, regenerate, quote-reply. Assign each to either bubble-scope or turn-scope with rationale.
6. **`ThinkingAccordion`.** Must attach to turn, not first bubble. UI layout must handle a single accordion above a group of bubbles.
7. **`UserMemoryService.refreshConversation` + summarizer prompt.** Same-turn bubbles must feed the summarizer as one unit; otherwise summarization texture loss (ref: `2026-04-22-nous-summarization-texture-preservation-design.md`) gets worse, not better.
8. **Citations, `<signature_moments>`, `<clarify>`.** These tag blocks must live in the final bubble of a turn. Split validation enforces this (§5.4).
9. **Transcript export / share / copy.** Re-flattens turn bubbles into a single block, or preserves turn grouping with explicit markers.
10. **Test suites.** Any assertion that counts messages must shift to counting turns, or explicitly count messages-per-turn.

Phase 2 planning (writing-plans) must reproduce this list, mark each item with current state + intended state + migration approach, and flag anything discovered during that pass. Only then does implementation start.
