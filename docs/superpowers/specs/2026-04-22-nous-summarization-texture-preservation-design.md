# Nous Summarization: Texture Preservation Design

**Status:** Draft, awaiting user review
**Author:** Alex + Claude
**Date:** 2026-04-22
**Target files (primary):** `Sources/Nous/Resources/anchor.md`, `Sources/Nous/ViewModels/ChatViewModel.swift` (summaryOutputPolicy), `Sources/Nous/Services/UserMemoryService.swift` (refreshConversation), `Sources/Nous/Services/ClarificationCardParser.swift`
**Supersedes (partial):** `2026-04-21-scratchpad-summary-paper-design.md` — specifically, the rigid four-section Problem/Thinking/Conclusion/Next Steps output structure defined there is replaced with a conversation-type adaptive templates system (see §4).

---

## 1. Context

### 1.1 The design problem

Nous has a quality gap between its conversation layer and its summarization layer. In-dialogue, Nous produces sharp, textured responses that honor specific imagery, user-coined phrasing, and non-obvious insights. At summarization time, the same content flattens into abstract structured categories.

Observed example:

- **In-dialogue (vivid):** "品味 = 睇过一千幅画，试过一百种咖啡，失败过十次，你就会开始知道咩系好，咩系唔好，同埋点解"
- **Summary (flattened):** "品味 = 基于大量经验同失败而建立起嚟嘅判断系统"

Correct but drained of texture. The specific imagery (一千幅画 / 一百种咖啡 / 十次) — which was the insight — disappears in favor of an abstract frame (经验 / 失败 / 判断系统).

This is a **design problem**, not a taste problem. The summarization pass actively trades vividness for structure.

### 1.2 Root causes

Three existing instruction-pool pressures actively pull toward flattening:

1. **Structure pressure** — `summaryOutputPolicy` (ChatViewModel:831-851) forces a fixed four-section markdown frame (Problem / Thinking / Conclusion / Next Steps) regardless of conversation type. This frame fits problem-solving but misfits idea-exploration, existential, emotional-processing, planning, teaching, and venting conversations — which are the majority of Nous use. Forcing misfit structure squeezes vivid content into wrong slots, flattening along the way.

2. **Compression pressure** — `refreshConversation` prompt (UserMemoryService.swift:485-507) instructs "SHORT memory note" and "under 6 bullet points." Density targets conflict with texture: preserving "睇过一千幅画，试过一百种咖啡，失败过十次" costs more tokens than "大量经验" — and the existing rule picks density.

3. **Pattern-extraction pressure** — `refreshProject` and `WeeklyReflection` prompts instruct "what recurs" / "durable context" — this is appropriate for those abstraction levels, but if it leaks into `refreshConversation`, specific imagery gets prematurely abstracted into patterns.

No existing summarization prompt contains an imagery-preservation instruction. This is a net-new rule, not a strengthening of an existing one.

### 1.3 Scope

**In scope:**
- `Scratch Summary` (user-triggered, visible in ScratchPadPanel notepad)
- `Conversation Memory Refresh` (background, feeds next-turn context)

**Out of scope (this round):**
- `Project Memory Refresh` — correctly abstract by design; changes risk breaking its cross-conversation pattern function
- `Global/Identity Memory` — highest abstraction layer
- `Weekly Reflection` — batch, pattern-focused, corpus-scoped
- `Conversation Title` — hidden label, not a texture-preservation surface

Rationale: starting with the two surfaces where texture loss is most visible (Scratch) and most compounding (Conversation Memory feeds back into next turn's conversation context). Validate principle at these two surfaces before extending to higher abstraction layers.

---

## 2. Design Overview

Five-part design addressing both the additive instruction (what to preserve) and the subtractive restructure (removing pressures that flatten):

1. **Route 2 Signature-Moments Tagging** — Inline hidden tags emitted by the conversation model to flag preservation-worthy phrases; summarizer reads and quotes verbatim.
2. **Instruction Pool Changes** — Additive (preserve imagery, respect signature moments) and subtractive (loosen compression pressure) prompt rules, with 7–8 positive/negative example pairs.
3. **Scratch Summary Output Policy Overhaul** — Replace rigid four-section structure with six conversation-type adaptive templates plus narrative fallback.
4. **Conversation Memory Refresh Prompt Changes** — Loosened bullet budget, signature-moment escalation, imagery-over-count priority.
5. **Validation Plan** — Golden conversation set + hand-crafted target summaries + manual regression review + observe-in-use, no quantitative metrics.

### 2.1 Two-axis hybrid strategy

Summaries use different preservation strategies depending on both (a) the surface and (b) the content class:

| Content class | Conversation Memory (surface) | Scratch Summary (surface) |
|---|---|---|
| Signature moment (flagged via `<signature_moments>`) | Strategy A (quote verbatim) | Strategy A (quote verbatim) |
| Concrete imagery (specific numbers, objects, examples, metaphors) | Strategy B (imagery-preserved paraphrase) | Strategy A (quote-embedded) |
| Generic content (routine Q&A, acknowledgments) | Normal compression | Normal compression |

Where:
- **Strategy A:** "用户讲：「睇过一千幅画，试过一百种咖啡，失败过十次」" (verbatim)
- **Strategy B:** "品味唔係抽象能力，係「大量样本 + 失败记忆 + 时间」" (keeps concrete texture, no verbatim quote)

Rationale: Scratch Summary is user-visible and token-cost-tolerant, so biases toward quote-embedded. Conversation Memory is model-consumed and token-constrained, so biases toward imagery-preserved paraphrase — but escalates to verbatim when the signature-moment signal is present.

---

## 3. Signature-Moments Tagging (Route 2)

### 3.1 Tag format

Nous emits a hidden block at the end of each assistant reply that contains signature moments. Format:

```
<signature_moments>
- source: user
  text: "睇过一千幅画，试过一百种咖啡，失败过十次"
- source: nous
  text: "硬限制系精神上嘅奢侈品"
</signature_moments>
```

- Block is appended after the visible reply and inside no other wrapper (sibling of `<chat_title>` convention).
- `source` is one of `user` or `nous` — preserves attribution for downstream templates.
- `text` is verbatim from the turn (user's utterance or Nous's own line). No paraphrasing at tag time.
- Block is optional per turn. Zero signature moments is a valid and expected state.

### 3.2 Discipline (budget and anti-patterns)

Emit 0–2 signature moments per turn. Most turns have none; the signal is diluted when over-emitted.

**Flag when:**
- User articulates an original metaphor, vivid imagery, or non-obvious insight
- Nous produces a sharp line (non-routine, would be quotable in retrospect)
- A specific phrase is likely to be referenced back to, either by the user or the summarizer

**Do not flag:**
- Routine confirmation / acknowledgment turns
- Paraphrases of something already flagged earlier
- Every Nous reply (self-inflation anti-pattern)
- Standard Q&A phrasing

### 3.3 Instruction location

A new section is added to `anchor.md` documenting:
- The `<signature_moments>` tag contract
- The flag / don't-flag rules above
- The 0–2 per turn budget with "when in doubt, skip" guidance
- Sample tag emission

### 3.4 UI stripping

`ClarificationCardParser.swift` adds a strip rule for `<signature_moments>` blocks alongside existing rules for `<thinking>`, `<phase>`, `<chat_title>`, `<summary>`. Tag content is never rendered in the chat bubble.

### 3.5 Consumption by summarizers

- **Scratch Summary prompt:** "Read all `<signature_moments>` blocks in the conversation. Those exact phrases must appear verbatim in your summary output."
- **Conversation Memory prompt:** "Read all `<signature_moments>` blocks in the conversation. For flagged phrases, use Strategy A (verbatim quote) in your bullets. For other imagery, use Strategy B (imagery-preserved paraphrase)."

### 3.6 Who decides conversation type (Option A)

Summarizer at summary time, reading the full conversation arc. No inline conversation-type tagging. Rationale: summarizer has post-hoc visibility of the entire arc, which outperforms inline single-turn judgment; and YAGNI — no evidence yet that summarizer judgment is unstable. If instability is observed in validation, strengthen by adding in-prompt type-judgment examples before escalating to inline tagging.

---

## 4. Scratch Summary Output Policy Overhaul

### 4.1 Replace rigid structure with adaptive templates

Current `summaryOutputPolicy` (ChatViewModel:831-851) forces Problem / Thinking / Conclusion / Next Steps. Replace with six templates the summarizer picks from based on conversation type, plus a narrative fallback.

### 4.2 Templates

**Type 1: Problem-solving / debugging**
```
Problem
Thinking
Conclusion
Next Steps
```
(Unchanged — fits this mode correctly.)

**Type 2: Idea-exploration / philosophical / existential**
```
Key Threads
Vivid Moments    ← verbatim-quote signature_moments here
Open Questions
```
No forced Conclusion. Not all existential conversations land.

**Type 3: Emotional-processing / self-reflection**
```
What Came Up
What Shifted
Where You Landed
```
Preserve the user's own landing phrase.

**Type 4: Planning / decision-making**
```
Context
Decisions
Constraints
Actions
```

**Type 5: Teaching / learning**
```
What Was Covered
Aha Moments    ← verbatim-quote signature_moments here
Applications
```

**Type 6: Venting / complaint**
```
What's Weighing
Root Tension
What You Need
```
Preserve the user's actual phrasing of frustration.

**Narrative fallback**
If no template fits, write 2–3 paragraphs of prose. Signature moments embedded verbatim.

### 4.3 New instruction text (summaryOutputPolicy)

```
Before writing the <summary> body, judge the conversation type.
Pick the matching template from Types 1–6. If uncertain, use the
narrative fallback (2–3 paragraphs of prose).

Signature moments — any phrase flagged inside <signature_moments>
earlier in the conversation — MUST appear verbatim in your output.
Quote them in the natural position within your chosen template.

Preserving texture beats hitting template structure perfectly.
If the template doesn't naturally hold a vivid moment, extend
the template rather than drop the moment.
```

### 4.4 Wrapper unchanged

Output is still wrapped in `<summary>…</summary>`. `ClarificationCardParser.extractSummary` and `ScratchPadStore.ingestAssistantMessage` require no changes. Only the internal content shape has adaptive freedom.

---

## 5. Conversation Memory Refresh Changes

### 5.1 Location

`UserMemoryService.swift:485-507` — inline system prompt for `refreshConversation`.

### 5.2 Preserved

- Corpus scope (last 8 user turns, deduped against assistant replies)
- Output destination (`memory_entries` with scope: conversation, stability: temporary)
- Temporal focus (what the user is working on right now)

### 5.3 Changes

1. **Imagery preservation rule** added (see §6.1)
2. **Signature-moments consumption rule** added: flagged phrases use Strategy A (verbatim quote); other imagery uses Strategy B (paraphrase with specifics); generic content compresses normally
3. **Bullet budget loosened**: "under 6 bullet points" → "up to 8 bullet points when preserving imagery requires it"
4. **Priority rule**: "Preserve imagery > hit bullet count" — if hitting a tight count would flatten, prefer a slightly longer list
5. **7–8 positive/negative example pairs** inlined in the prompt (see §6.3)

### 5.4 Out-of-scope sibling prompts (this round)

- `refreshProject` (UserMemoryService.swift:584-604) — unchanged
- `refreshIdentity` (UserMemoryService.swift:674-694) — unchanged
- `WeeklyReflectionService.systemPrompt` — unchanged

These higher-abstraction layers are deliberately more pattern-focused. Texture preservation at those layers is a separate design question for a later round.

---

## 6. Instruction Pool Additions

### 6.1 New additive rules (applied to both Scratch Summary and Conversation Memory prompts)

**Rule 1 — Imagery preservation:**
> When source text contains specific details (concrete numbers, objects, sensory imagery), an original metaphor, or non-obvious phrasing, preserve that specificity in the summary. Do not substitute abstract categories.

**Rule 2 — Signature-moment priority:**
> If the conversation contains `<signature_moments>` blocks, those exact phrases MUST appear verbatim in your output (Scratch Summary) or be escalated to verbatim-quote within bullets (Conversation Memory).

**Rule 3 — Priority ordering:**
> Preserve imagery > hit template structure > hit bullet count.

### 6.2 Subtractive changes (pressures to loosen)

- Scratch Summary: fixed four-section structure → adaptive templates (§4)
- Conversation Memory: bullet cap 6 → 8; add "imagery > count" priority (§5)
- Project Memory: no change (scope boundary)

### 6.3 Positive / negative example pairs (7–8 pairs, inlined in both prompts)

Each pair contrasts a flattened summary against a texture-preserving one, covering all six conversation types plus an abstract-vs-concrete general case.

1. **Idea-exploration (品味):**
   - ❌ 品味 = 基于大量经验同失败而建立起嚟嘅判断系统
   - ✅ 品味 = 「睇过一千幅画，试过一百种咖啡，失败过十次」之后形成嘅judgment

2. **Problem-solving (debugging):**
   - ❌ 修复咗authentication嘅bug
   - ✅ 修咗login bug：session cookie响Safari被当作third-party，改咗SameSite=Lax之后work

3. **Emotional-processing:**
   - ❌ 用户处理紧关于工作嘅挫败感
   - ✅ 用户讲：「我觉得自己系响隧道入面跑，但冇人话我终点响边」——感到direction缺失

4. **Planning:**
   - ❌ 讨论咗下季度嘅优先事项
   - ✅ 决定Q2聚焦retention而非growth，理由：「先把漏斗底补实，再落更多水」

5. **Teaching / learning:**
   - ❌ 学咗点用Swift concurrency
   - ✅ Aha: async let同TaskGroup嘅分别——「async let系兵，TaskGroup系将」

6. **Venting:**
   - ❌ 对meeting overload感到frustration
   - ✅ 用户讲：「我嘅calendar系别人agenda嘅投影」——冇mental space做deep work

7. **Abstract vs concrete (general):**
   - ❌ 用户describe咗一个复杂嘅想法
   - ✅ 用户describe：思考就系「响脑入面开咗十个tab，但闩唔到其中任何一个」

8. **Conversation with no signature moment (routine):**
   - ❌ 用户问问题、得到答案
   - ✅ 用户问点set up Xcode scheme，给咗三步instruction

(Pair #8 teaches the model that not every turn needs vivid preservation — routine is routine, and forcing texture there is also a failure mode.)

---

## 7. Validation Plan

### 7.1 Golden conversation set

Curate 5–8 conversations:
- **Flatten cases (3–5):** Conversations where current summaries demonstrably lose texture.
  - The 品味 conversation (confirmed)
  - User to identify 2–4 additional cases during spec review
- **Anti-regression cases (2–3):** Problem-solving conversations where current Problem/Thinking/Conclusion/Next Steps structure works well. Verify these continue to render as Type 1 after the change.

### 7.2 Hand-crafted target summaries

For each golden conversation, write the expected "good" Scratch Summary and Conversation Memory output by hand, following the new design. These become the reference for manual comparison.

### 7.3 Manual regression review (gate before ship)

After prompt changes are applied:

- Re-run Scratch Summary on each golden conversation, compare to hand-crafted target. Check:
  - Are `<signature_moments>` phrases verbatim-present?
  - Is concrete imagery preserved (not abstracted)?
  - Does the chosen template match the conversation type?
  - Does Type 1 (problem-solving) still look right on anti-regression cases?
- Re-run Conversation Memory on each golden conversation, compare. Check:
  - Flagged phrases quoted verbatim in bullets?
  - Other imagery paraphrased with specifics, not abstracted?
  - Bullet count respects priority rule (imagery > count)?

### 7.4 Ship + observe

Prompt-only changes; no feature flag. Alex uses Nous daily — qualitative observation across 1–2 weeks catches regressions faster than any automated gate. If patterns emerge (e.g., specific conversation types mis-typed, or over-quoting diluting summaries), iterate on prompts.

### 7.5 Explicitly not doing

- LLM-judge self-critique pass — over-engineered for this stage
- Automated metrics — texture-preservation is a subjective quality problem, attempts to quantify will mislead
- Long-form user study — premature, ship first and iterate

---

## 8. Risks and Open Questions

### 8.1 Risks

- **Over-tagging signature moments:** If Nous flags too liberally, the signal dilutes and Scratch Summary becomes a quote collage. Mitigation: discipline language in anchor.md explicitly caps 0–2 per turn with "when in doubt, skip" guidance. Validation review catches this pattern if it emerges.

- **Conversation-type mis-classification:** If summarizer picks wrong template (e.g., uses Type 1 on an emotional-processing conversation), output feels mechanically wrong. Mitigation: narrative fallback catches the "none of these fit" case; validation golden set includes at least one instance of each type to observe judgment quality.

- **Prompt length inflation:** Adding 7–8 example pairs + adaptive template list + new rules grows both summarization prompts. May cause token-budget issues or attention dilution. Mitigation: monitor prompt size; if a surface's prompt exceeds its budget, consider moving the example pairs to a shared include.

- **Type shift within a single conversation:** A conversation that starts problem-solving and ends existential gets one template. Summarizer must pick the dominant or final mode. This is a known limitation accepted in scope. If shift-handling becomes a pattern complaint, revisit with multi-section or arc-aware template in a later round.

### 8.2 Open questions for user review

- Confirm the 3–5 additional golden "flatten cases" beyond the 品味 conversation
- Confirm 2–3 anti-regression problem-solving conversations to validate Type 1 preservation
- Confirm bullet cap of 8 (vs. 7 or 10) for Conversation Memory

### 8.3 Deferred (not for this round)

- Extending texture preservation to Project Memory, Identity Memory, and Weekly Reflection
- Route 2 inline tagging of conversation type (only adopt if Option A judgment proves unstable)
- Retrospective signature-moment detection (flagging moments that only become significant later in the arc)

---

## 9. Success Criteria

After implementation and validation:

- The 品味 conversation's Scratch Summary contains the phrase "睇过一千幅画，试过一百种咖啡，失败过十次" verbatim, and its Conversation Memory bullet for that turn quotes it verbatim (not "大量经验").
- At least one conversation from each of Types 2, 3, 5, 6 produces a template-appropriate summary rather than being force-fit into Problem/Thinking/Conclusion/Next Steps.
- Anti-regression conversations (Type 1 problem-solving) still produce the four-section structure they did before.
- No signature_moments tag visible in rendered chat bubbles.
- Alex's qualitative experience over 1–2 weeks: summaries feel "like the conversation" rather than "like a report of the conversation."
