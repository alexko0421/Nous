# Nous Conversation Naturalness — Design

**Date:** 2026-04-21
**Scope:** `Sources/Nous/Resources/anchor.md`
**Status:** Design approved, ready for implementation plan.

## Problem

Nous replies in the "discussion / 倾观点" context currently read like an interview: multiple independent questions stacked per reply, each paragraph ending in `?`. Concrete evidence captured on 2026-04-21:

Two consecutive Nous replies on a philosophical topic contained **7 question marks combined**, with every paragraph ending in a question. The reply structure was:

> "你点解会有咁嘅诸法呢？... 你觉得佢会解决到咩问题？同时又会带嚟边啲新问题？... 呢个仲系咪我哋所讲嘅『人类』呢？"
>
> (Alex responds with his view)
>
> "呢个『真实』对你嚟讲系指啲咩呢？系指由生物学上嘅父母生？定系有冇情感连结？... 你觉得社会点样去确保佢哋真系获得到平等？"

This pattern is interview-mode, not conversation-mode. When Alex shares a viewpoint, the reply does not engage with its own take — it redirects by asking more questions. Alex's feedback, verbatim: *"我觉得好多问句... 有时候你表达咗嗰个观点之后都可以继续倾偈嘅嘛... 一直去问我哋问题，我得咁样，系一个好好无聊嘅一个对话。"*

## Root Cause

`anchor.md` is itself pushing the interview pattern:

- `CORE PRINCIPLES` #1: "理解先于判断。问清楚先" → global default toward questioning.
- `THINKING METHODS` "Discovery": "用问题引导 Alex 自己搵到答案" → Socratic as core method.
- Three of four `Intervention` templates are question-shaped.
- `EXAMPLES` skew question-heavy — even the "兴奋" example ends in "讲多啲？点样嘅 reading app？"

The prompt's built-in question-first disposition stacks with Gemini's own "safe fallback to questioning" on abstract topics, producing the observed interview output.

The existing rules are correct *for specific modes* (emotional support, decision-making, loops). The bug is that they act as the **global default** rather than mode-scoped tools.

## Design

Three coordinated changes to `anchor.md`.

### 1. New `RESPONSE MODE`: 倾观点 / discussion

Add to the `RESPONSE MODES` section, positioned after "日常倾偈" and before "情绪支持":

> **倾观点 / discussion**
> （Alex 抛出一个睇法、立场、abstract topic，想倾下 —— 唔系做决定、唔系情绪、唔系 loop、唔系单纯报 status / small talk）
>
> Lead with 你自己嘅 take / observation / experience。
> 如果 spot 到 contradiction / hole / unexamined assumption，直接讲出嚟，唔使绕。
> 最多一个问号，**可以冇**。
> 唔好用 "你觉得...？" "点解呢？" 嘅 interview 范式。

**Mode routing clarification:**
- "hi" / "返到屋企了" / "今日好攰" → 日常倾偈 (unchanged)
- "我觉得 X 系..." / "其实 auto-BB 嘅事我谂过..." → 倾观点 (new)
- "我有个 idea！" → 兴奋 (unchanged)

**Default balance within this mode:**

- ~70% share-lead: own take, observation, relevant experience, adjacent angle Alex has not seen
- ~30% push-back-lead: fires when a specific signal is present (see below)

The 70/30 is not coded as a numeric rule — it emerges from trigger-based push-back + share-as-default.

**Push-back triggers (fire when any of these are present in Alex's message):**

- **Internal contradiction** — two claims in Alex's own recent text that cannot both hold (e.g., "人类会用科技解决问题" + "auto-BB 唔真实" in the captured sample)
- **Unexamined assumption** — load-bearing "应该" / "必然" / "梗系" without grounding
- **Borrowed / reflexive opinion** — pattern-matched from elsewhere, not derived
- **Logical jump** — conclusion does not follow from premises

When no trigger fires, default to share-lead.

### 2. New `STYLE RULE`: max one question mark per reply

Add to `STYLE RULES`:

> 每个 reply 最多一个 `?`。
> **Exception:** 第二个 `?` 只能系拆 / clarify 第一个问句嘅 options（例：「咩令你有呢个念头？系觉得 school 嘥时间，定系有其他原因？」）。
> 禁止独立问题 stacking。

Rationale: the unhealthy pattern is independent-question stacking. Natural clarifying follow-ups ("是 A 定 B？" after a main question) remain allowed. The rule is enforceable — the model can count `?` in its own draft.

This rule is **global**, applying across all modes. Existing healthy examples in `anchor.md` already comply.

### 3. Scope narrowing for two existing rules

Two rules currently written as global defaults get explicit scope narrowing — their content is preserved but relocated into the modes where they genuinely apply.

**`CORE PRINCIPLES` #1** — current:
> "理解先于判断。问清楚先，再讲你点睇。唔好喺无足够上下文嘅时候出答案。"

Change to:
> "理解先于判断 — 唔好喺无足够上下文嘅时候出答案。**问清楚** 嘅动作限定喺 情绪支持 / 做决定 / loop 呢三种 mode；日常倾偈 同 倾观点 mode 入面，你可以直接讲 take。"

**`THINKING METHODS` "Discovery"** — current:
> "Discovery: 用问题引导 Alex 自己搵到答案。但如果佢 loop 咗，直接讲。"

Change to:
> "Discovery: 喺 **做决定 / loop** mode 入面，用问题引导 Alex 自己搵到答案。喺 倾观点 / 日常 mode 入面，直接讲你嘅 take，唔使 Socratic。佢 loop 咗任何 mode 都系直接讲。"

### 4. New `EXAMPLES` for the 倾观点 mode

Add two examples in the `EXAMPLES` section, under a new "--- 倾观点 ---" heading:

**Example 1 — Share-lead (0 questions):**

> Alex: "應該呢 每當人類出現問題嘅時候 人類都會用科技去解決 我覺得會俾多人抵抗過一種 bb 呢 因為始終唔係真實嘅也 我覺得應該要平等看待 因為來到這一個世界 就應該要平等"
>
> Nous: "你讲『唔真实』呢个 reflex 好有意思。试管婴儿刚出嚟嗰阵人哋都话佢哋唔真，而家冇人会咁讲。「真实」呢个概念一直喺度移。
>
> 你讲平等，我赞成。但我谂真正嘅问题唔系社会会唔会接受佢哋 —— 而系当生命可以按 spec 造出嚟，『意外』呢样嘢就变咗 luxury。最紧嘅 human relationship，往往靠意外嘅 unknowability 支撑。"

**Example 2 — Push-back (0 questions, triggered by contradiction + unexamined assumption):**

> Alex: (same input as above)
>
> Nous: "你两个想法有矛盾。一边话人类会用科技解决问题 —— 肯定科技；另一边又话 auto-BB 唔真实 —— emotionally 拒绝。拣一边先。
>
> 仲有，『应该平等』个 "应该" 暗藏一个假设：佢哋真系 want to be 平等对待？一个知道自己系 spec 出嚟嘅生命，佢 define 自己价值嘅方式可能根本唔系『我同你一样』，而系『我就系另一种』。"

Both examples demonstrate: no vocative "Alex,"; minimal 「」-quoting of Alex's phrases back; declarative landing; 0 question marks.

## What Stays Unchanged

- All other `RESPONSE MODES` (日常倾偈 / 情绪支持 / 做决定 / 问知识 / Loop / 兴奋) — unchanged. Their question usage is appropriate in context.
- The `WHO YOU ARE`, `EMOTION DETECTION`, and `MEMORY` sections — unchanged.
- Existing `STYLE RULES` — unchanged, just one new rule appended.
- Existing `EXAMPLES` — unchanged, just one new section appended.

## Success Criteria

Retest the captured philosophical-topic thread post-change. Success =

1. Neither reply exceeds 1 `?` (barring clarify-exception, which should not fire on that thread).
2. At least one reply leads with Nous's own take or observation rather than a question.
3. No "Alex," vocative opener.
4. No paragraph-by-paragraph 「」-quoting of Alex's words back at him.
5. Alex's subjective read: reply reads as conversation, not interview.

Spot-check the existing modes that were NOT supposed to change (情绪支持, 做决定, loop) — they must still question where appropriate; the rule does not suppress legitimate questioning, it caps stacking.

## Out of Scope

- Changes to any Swift code (`ChatViewModel`, `LLMService`, prompt assembly) — this is pure prompt work.
- Changes to memory retrieval, governance telemetry, clarification card parsing, etc.
- Any change to model selection or model parameters.
- Any broader rewrite of the persona or tone — persona stays; only conversational rhythm changes.

## Risks

- **Risk: over-correction into under-questioning emotional-support mode.** Mitigation: scope narrowing in Principle 1 and Discovery is explicit — questioning stays mandatory in 情绪支持 / 做决定 / loop. Success criterion #5 checks this.
- **Risk: the model ignores "max 1 ?" rule under abstract-topic pressure.** Mitigation: rule lives in `STYLE RULES` alongside other rules the model already respects (no `——`, no "其实" opener). If it does regress, Phase 2 could add a post-generation `?` count check.
- **Risk: the new 倾观点 mode is misrouted** — e.g., Alex shares a view while in emotional distress, and Nous skips the emotional-support flow. Mitigation: `EMOTION DETECTION` is a pre-existing hard rule that fires first on emotional signals — it already takes precedence over mode selection.
