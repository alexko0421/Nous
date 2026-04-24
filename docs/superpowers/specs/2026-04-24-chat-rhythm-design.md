# Nous Chat Rhythm — Design

**Date:** 2026-04-24
**Status:** Design approved, ready for implementation plan.
**Scope (Phase 1):** `Sources/Nous/Resources/anchor.md`
**Scope (Phase 2):** New `RhythmJudge` service, `ChatViewModel` multi-bubble support, `ChatArea` UI pacing.
**Builds on:** `2026-04-21-nous-conversation-naturalness-design.md` (added 倾观点 mode + max-1-? rule). This spec addresses a distinct layer — conversational rhythm — that the prior spec did not touch.

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

### 3.1 Why two-pass judge (not inline marker, not deterministic parser)

Three options were considered for the split mechanism:

1. **Inline marker.** LLM emits `<beat/>` during generation; runtime parses. Pros: one LLM call, live pacing. Cons: couples rhythm decision to content generation (attention budget split), `anchor.md` gains another meta-rule, marker misuse would corrupt entire reply.
2. **Two-pass judge (chosen).** Main LLM generates normally; separate `RhythmJudge` decides split. Pros: concern separation; reuses `ProvocationJudge` infra; testable independently; anchor.md stays focused on content; fault-isolation (judge failure → 1 bubble fallback; main reply unaffected). Cons: +300-700ms latency; non-streaming.
3. **Deterministic parser on double-newline convention.** Pros: cheapest. Cons: no semantics, collides with paragraph breaks, unreliable.

**Chosen: Option 2.** Architectural stability and separation of concerns outweigh the latency cost. The typing-indicator window that the judge adds is plausibly *more* natural than instant streaming — it mimics "I'm thinking about how to answer you."

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

This guards against structural regression during future edits; it does not validate rhythm quality.

## 5. Phase 2 — RhythmJudge + multi-bubble

### 5.1 Components

**`RhythmJudge` (new, `Sources/Nous/Services/RhythmJudge.swift`)**

Conforms to the existing `Judging` protocol (or a new peer protocol if semantics diverge — to be settled in implementation plan). Takes:

- Full reply text (post-`ClarificationCardParser` strip — so `<clarify>` / `<signature_moments>` do not reach the judge)
- Last N turns of conversation context
- Active response mode (if detectable)
- Optional: `ProvocationJudge` verdict for this turn (see §5.5)

Returns `RhythmVerdict`.

**`RhythmVerdict` (new, `Sources/Nous/Models/RhythmVerdict.swift`)**

```swift
enum RhythmVerdict {
    case singleBubble
    case split(boundaries: [Int], delays: [TimeInterval])
    // boundaries: character offsets in the reply text where bubbles break
    // delays: time between bubble N-1 and bubble N; delays.count == boundaries.count
}
```

### 5.2 ChatViewModel changes

`ChatViewModel` currently assumes `1 turn = 1 Message`. Phase 2 relaxes this.

- New `MessageTurn` concept: an Alex input corresponds to one turn; a turn owns N assistant messages (N ≥ 1).
- `Message` schema gains: `turnId: UUID`, `indexInTurn: Int`, `isLastInTurn: Bool`.
- Persistence: each bubble stored as an individual `Message` row. Retrieval groups by `turnId`.
- LLM history construction: when feeding prior turns back to the main LLM, concatenate all bubbles of a single turn into one assistant message string. The LLM API contract (single assistant message per turn) is preserved.
- Same concatenation applied when passing context to the next `RhythmJudge` call.

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

All failures fall back to `.singleBubble`:

- **Judge timeout** (>2s hard timeout). Main reply has already rendered internally; emit as single Message.
- **Judge LLM unavailable.** Skip judge, emit single Message.
- **Invalid boundaries** (out of range; negative; non-monotonic). Validate post-verdict; on failure, emit single Message.
- **Boundary inside a tag block** (`<clarify>`, `<signature_moments>`, code fence, markdown table). Post-verdict validation rejects; fall back to single Message.
- **Split produces an empty or 1-character fragment.** Reject verdict; single Message.

Telemetry logs every fallback with reason. Target fallback rate < 5%; investigate if sustained higher.

### 5.5 Interaction with ProvocationJudge

Both judges run after a reply is generated. `ProvocationJudge` is pre-existing and judges content (should Nous have pushed back harder, etc.). `RhythmJudge` judges shape.

Run in parallel (`async let` fan-out). `RhythmJudge` may optionally consume `ProvocationJudge`'s verdict as input signal — e.g., if provocation verdict identifies a contradiction surface, `RhythmJudge` is more likely to split the reactive opener from the unfolded explanation.

### 5.6 UI changes (ChatArea)

- Existing single-bubble path unchanged.
- Multi-bubble path: between bubbles, a brief typing indicator (~300ms flash) replaces the static gap, then the next bubble lands. Creates the "Nous is about to say something else" micro-tension.
- Delay values come from `RhythmVerdict.delays`, not UI constants. Typical ranges (judge-side guidance):
  - Bubble 1 → 2: 1.2-1.8s (reactive → thought)
  - Bubble 2 → 3: 0.8-1.2s
  - Jitter ±200ms applied at UI layer, not at judge layer.

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

### Week 1 (Phase 1)

- Day 1: Draft RHYTHM section + revised share-lead example + 3 new examples.
- Day 1: Apply to anchor.md. `RhythmStyleGuardTests` passes.
- Day 1-2: Before/after corpus run. Subjective pass.
- Day 2-3: Ship.
- Day 3-5: Real-session observation. Tune examples if needed.
- Day 5: Lock or iterate.

### Week 2-3 (Phase 2)

- Week 2 early: `RhythmJudge` + `RhythmVerdict` + `RhythmJudgeTests`.
- Week 2 late: `ChatViewModel` multi-bubble support (turn schema, persistence, history construction).
- Week 3: `ChatArea` UI pacing + per-bubble typing indicator.
- Week 3 late: Ship + real-session validation.

## 8. Risks

| Risk | Mitigation |
|------|-----------|
| Phase 1 over-corrects into "嗯。" / "系。" stall mannerism | New examples demonstrate sparse usage; `reactive beat ≠ filler` disambiguation; monitor in real sessions |
| Phase 1 regresses existing behaviors (push-back, 1-? cap) | Before/after corpus specifically covers 倾观点 + emotional triggers; `RhythmStyleGuardTests` guards 1-? rule presence |
| Phase 2 multi-bubble compounds summarization texture loss (cross-dep with `2026-04-22-nous-summarization-texture-preservation-design.md`) | Phase 2 scope includes reviewing `refreshConversation` prompt to explicitly handle multi-bubble turns as one continuous reply. Listed in §10 Open Questions. |
| Pacing delays feel gimmicky / manipulative | Strict split ratio (≤30%); UI jitter; telemetry watches split ratio; judge trained (via prompt) to be conservative — default singleBubble unless trigger is clear |
| `RhythmJudge` and `ProvocationJudge` semantics collide | Run parallel; RhythmJudge can consume Provocation verdict as input signal (§5.5) |
| Latency (judge adds 300-700ms) feels slow | Accept as design cost; the typing-indicator window is itself part of the natural pacing; measure p95, reject model choices with p95 > 1s |

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

- **Q1. Phase 2 judge model choice.** Gemini Flash vs Haiku. Decide by spiking a one-day latency benchmark at Phase 2 kickoff. Decision criterion: p95 < 700ms, accuracy on a hand-labeled 30-example eval ≥ 80%.
- **Q2. Final bubble + `<clarify>` block.** The engagement question (if any) must land in the final bubble. Enforce via post-verdict validation that no boundary falls inside a `<clarify>` block.
- **Q3. Rewrite vs preserve the original tidy 倾观点 example.** Lean: rewrite in place, preserve original in this spec's §9 as counterexample. Alternative: keep both in anchor.md with explicit "do / don't" framing (risk: doubles example density, may confuse model).
- **Q4. Multi-bubble interaction with memory summarization.** `UserMemoryService.refreshConversation` currently treats each `Message` as a unit. Phase 2 needs to either concat same-turn bubbles before feeding to summarizer, or update the summarizer prompt to recognize turn groupings. Cross-ref: `2026-04-22-nous-summarization-texture-preservation-design.md`.

## 11. Out of scope (v1)

- Streaming multi-bubble (main reply is generated fully before split runs).
- Adaptive delay learning (delays come from judge verdict; no reinforcement from Alex's reaction timing).
- Bubble-level undo / regenerate (a turn is one unit).
- Changes to `WHO YOU ARE`, `EMOTION DETECTION`, `MEMORY` sections of anchor.md.
- Changes to `RESPONSE MODES` routing (companion / strategist unchanged).
- Any visual redesign of the chat bubble itself.

## 12. Success criteria

**Phase 1 exit:**
- Before/after corpus shows a material rise in sentence-length standard deviation for discussion-mode replies (target: ≥ 40% relative increase).
- Reactive-opener appearance in emotional-support replies ≥ 60%.
- `RhythmStyleGuardTests` passes.
- Real-session subjective read: Alex notes the "feels more like speaking" shift.

**Phase 2 exit:**
- Split ratio in production telemetry: 15-30% (rolling 7-day).
- Judge latency p95 < 700ms.
- Fallback rate < 5%.
- Real-session subjective read: micro-beat moments (情绪 opener / contradiction surface) land with weight; the tidy-essay feel is gone.

**Combined:**
- No regression on the 2026-04-21 naturalness rules (max-1-?; share-lead in 倾观点).
- No regression on the existing emotional-support / decision-making / loop behaviors.
