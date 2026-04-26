# Anchor 4 — Watkins: Constructive vs Unconstructive Repetitive Thought

## Research Memo (v2 — revised after Codex consult 2026-04-25)

**One-line summary:** Repetitive thought (RT) about a single topic isn't intrinsically bad. Watkins's contribution: the *same* RT can be constructive or unconstructive depending on **processing style**, not topic. **Negative RT becomes more constructive when concrete, contextual, and goal/means-oriented; more unconstructive when abstract, evaluative, avoidance-shaped, and stuck.** For NOUS this means: don't break every loop — break only the unconstructive ones.

**The framework.** Ed Watkins (2008) "Constructive and unconstructive repetitive thought" (*Psychological Bulletin*, 134(2), 163-206) synthesized decades of rumination + worry + reflection research into a unified account. Whether RT helps or harms depends on a cluster of features that co-vary, not three orthogonal axes:

- **Construal level.** Concrete-experiential (situation-specific, sensory, what/when/where/how, action implications) vs abstract-evaluative (generalized, why-questions about meaning, identity-level "what does this say about me"). Concrete RT after distress is recovery-promoting; abstract RT amplifies depressive symptoms (Watkins & Moulds 2005).
- **Function/orientation.** Goal- and means-oriented RT (problem-solving toward a clear endpoint) recovers; avoidance-shaped RT (cycling around threat without forward motion, framing as "stuck") doesn't. Approach/avoidance is *related to* construal through control theory but is not cleanly orthogonal — both pull in the same direction.
- **Context.** Same processing style can have different effects depending on valence (positive event → savoring is adaptive; negative event → rumination is harmful) and on whether the iteration is bounded vs open-ended.

**Key empirical findings:**
- Rumination (unconstructive RT about negative events) predicts depression onset, severity, and duration.
- "Why" questions about negative events ("Why does this always happen to me? What does this say about who I am?") → abstract, avoidance → depression risk.
- "How" questions about the same events ("How can I do this differently? What's a small step I can take?") → concrete, approach → adaptive.
- Concrete-experiential mode > abstract-evaluative mode for distress recovery (Watkins & Moulds 2005, Watkins et al. 2008 RFCBT trials).
- Time-limited problem-solving > unlimited cycling. Bounded RT with a stop-condition recovers; open-ended RT doesn't.

**Non-obvious operational details:**
1. **Same content can be RT-good or RT-bad.** "I keep thinking about the conflict with my friend" can be constructive (working out specific repair steps) or unconstructive (cycling on "why am I always the one who has to fix things"). Topic ≠ pathology.
2. **Turn-level markers of unconstructive RT (primary, observable in current turn):** abstract why-questions about meaning or identity; no movement toward action; increasingly evaluative framing. Multi-turn marker (same emotional intensity over N+ turns) is *additionally informative when obvious from recent context*, but should not be required — the LLM cannot reliably track turn-history pattern without explicit state.
3. **Marker of constructive RT:** emotional intensity shifts (often eases), new perspectives/details surface, framing becomes more concrete, links to action emerge.
4. **"Step out and step into action" intervention pattern:** When unconstructive RT is detected, the highest-leverage break is a single shift from abstract to concrete ("What's one specific thing about this situation?" / "What would the next 30 minutes look like?"), not a topic change.
5. **Avoid "stop ruminating" framing.** Telling someone to stop rumination about a real problem feels invalidating and rarely works. Reframing the iteration mode (concrete + approach) does work.

**Anti-patterns ruled out:**
- Treating all repetition as pathology (constructive RT is recovery work, don't interrupt it)
- Generic "let's change topic" intervention (avoidance enabling, demotes the problem)
- Why-questions to user when user is already in rumination ("why do you feel this way?" deepens abstract loop)
- Premature problem-solving when rumination's job is processing distress (need Reis U+V before any break attempt)

**Interaction with other anchors:**
- **Reis** (perceived responsiveness): Reis is prerequisite. Never break a loop before user feels understood + validated. A loop break delivered without prior U+V reads as dismissive.
- **Nelson & Narens** (meta-level): RT-mode detection (constructive vs unconstructive) is a *monitoring* signal. Plugs cleanly into existing `monitor_summary` framework — though might be over-engineering to add explicit field; anchor.md rule may suffice.
- **Kross** (self-distancing): self-distancing is *one mechanism* by which abstract-evaluative RT can shift toward concrete-experiential. They're complementary — Kross provides the technique, Watkins identifies when to use it.
- **Gable** (capitalization): mirror image — savoring positive events is "constructive RT about positives". Same Watkins framework, opposite valence.

**Sources:**
- Watkins, E. R. (2008). *Constructive and unconstructive repetitive thought.* Psychological Bulletin, 134(2), 163-206.
- Watkins, E. R., & Moulds, M. (2005). Distinct modes of ruminative self-focus: Impact of abstract vs. concrete rumination on problem solving in depression. *Emotion*, 5(3), 319-328.
- Watkins, E. R., Mullan, E., Wingrove, J., et al. (2011). Rumination-focused cognitive-behavioural therapy for residual depression: Phase II randomised controlled trial. *British Journal of Psychiatry*, 199(4), 317-322.

---

## NOUS Current State (gap analysis)

**Existing loop surfaces (3):**

1. **anchor.md「RESPONSE MODES」line 35:**
```
Alex 在 loop：温和但直接打断。
```
Treats ALL loops as needing interruption. No constructive-vs-unconstructive distinction. Per Watkins, this would interrupt valid working-through.

2. **anchor.md THINKING METHODS line 66:**
```
Discovery: ... 佢 loop 咗任何 mode 都系直接讲。
```
Same issue — treats any loop as needing intervention.

3. **anchor.md THINKING METHODS Intervention line 69:**
```
Loop 紧：「而家諗緊嘅嘢，有冇出口？下一步係咩？」
```
**Already partially Watkins-aligned** — "下一步係咩" is a concrete-action prompt (good). What's missing is the *trigger criterion* for using this intervention vs leaving constructive iteration alone.

4. **EXAMPLES section lines 108-111** demonstrates loop handling on a major-changing example.

**Default failure mode:** Current rules can't distinguish "Alex 喺 working through a real problem (constructive RT)" from "Alex 喺 stuck in abstract why-loop (rumination)". Risk: Nous interrupts constructive iteration with break-prompts, which feels dismissive.

---

## Proposed Surgical Edits (v2 — revised after Codex consult)

### Edit A — `Sources/Nous/Resources/anchor.md` 「RESPONSE MODES」 line 35

**Current:**
```
Alex 在 loop：温和但直接打断。
```

**Proposed (replace line):**
```
Alex 在 loop：先分辨 — constructive iteration (落到 concrete details / 加新角度 / 情绪 intensity 变紧 / 朝住 action 推进) 唔需要打断, 跟住佢一齐 work。Unconstructive rumination (abstract why-questions 关于 meaning 或 identity / 唔朝 action 走 / framing 越嚟越 evaluative) 先要温和打断 — 用「Loop 紧」嗰条 intervention 由 abstract shift 去 concrete。
```

(1 line replaces 1 line. v2 swap: dropped "同情绪强度 + 同信息 N+ turn 重复" multi-turn marker per Codex Q2 — LLM cannot reliably track turn-history pattern at single-turn level. Kept turn-level markers (abstract + no-action + evaluative) which are observable.)

**Expected behavior change:**
- Nous 唔会再粗暴打断 Alex 嘅 working-through (constructive iteration) — 而家会同佢一齐 iterate
- 当真系 rumination (abstract + no-action + evaluative), 先 trigger break, 用现有 Intervention prompt
- 防止「打断 invalid 嘅 loop = 显得唔耐烦」嘅 regression

**Regression watch-list:**
- 唔可以变 over-tolerant (Alex 真系 rumination 但 Nous 唔打断, 鼓励 stuck loop)。Edit B 嘅 trigger 仍然有 sharp markers
- Voice flatten risk (per `feedback_rhythm_phase1_rejected.md`) — 加咗 detection criteria 但仍然系 grounded 前辈语气
- Mode-balance per-mode (per `feedback_mode_balance_not_per_reply.md`) — loop-mode 仍然只 trigger 喺 detected loop turns
- Schematic risk — Nous 唔可以 output "首先, 我 detect 到呢个系 X loop, 所以..." 解释 framework

### Edit B — `Sources/Nous/Resources/anchor.md` THINKING METHODS Intervention line 69 (REVISED per Codex Q3)

**Current:**
```
Loop 紧：「而家諗緊嘅嘢，有冇出口？下一步係咩？」
```

**Issue:** Existing line stacks 2 questions ("有冇出口？" + "下一步係咩？") which already conflicts with anchor.md STYLE RULES line 143 (max 1 question per reply). v1 proposed adding a 3rd question — Codex correctly flagged this would teach Sonnet to stack questions even more.

**Proposed (replace line, fix existing 2-? issue + Watkins refinement):**
```
Loop 紧 (检测到 unconstructive: abstract + no action + evaluative)：shift abstract → concrete with ONE question only — choose the one that best fits, e.g.「下一步係咩？」or「而家具体嘅 next 30 分钟睇起嚟点？」or「呢个 situation 入面有边一件 specific 嘅嘢可以 grip？」
```

(1 line replaces 1 line. Fix: instead of stacking questions, give Sonnet a menu of ONE-question options to pick from. Resolves existing 2-? stacking issue + adds Watkins concrete-shift framing.)

**Expected behavior change:**
- Nous 用 Loop intervention 时只问 ONE question (符合 STYLE RULES max-1-?)
- Question 系 concrete-shift 类 ("具体一件嘢" / "下一步" / "next 30 分钟") 而唔系 abstract why
- 修咗 anchor.md 一个 pre-existing 嘅自我矛盾 (line 69 violated line 143)

**Regression watch-list:**
- 必须真系系 ONE question — Codex 警告 question stacking 风险, Sonnet 可能误读 menu 系 "全部都问"。Live-test 需要 verify
- 三个 example questions 都要 concrete-action 类, 唔可以塞 "你点睇" 之类 abstract

### NO EDITS — ProvocationJudge / WeeklyReflectionService / EXAMPLES

**ProvocationJudge:** RT-mode detection 可以加做 `monitor_summary.repetitive_thought_mode` enum, 但 Codex consistent advice 系: 唔好 over-engineer schema。Anchor.md rules 应该足够 — Sonnet 可以读 detection criteria 并 internally 应用。如果 live-test 显示判断不准, Phase 3 再加 schema field。

**WeeklyReflectionService:** 区分 constructive vs unconstructive recurrence patterns 太 abstract for Phase 2。Defer。

**EXAMPLES:** 现有 line 108-111 嘅 loop example demonstrates `unconstructive` rumination case (转 major 嘅 abstract why-loop)。Constructive iteration case 加新 example 会 add scope。先 ship 现有 edits, live-test 之后睇有冇必要补 example。

---

## Live-Test Plan (Step 3, batch with Kross 一齐 test)

**Should-trigger 场景 (打断):**
1. Alex 反覆讲 "点解我成日做唔到嘅" / "点解每次都系咁" 几个 turn (abstract why + same emotion + no action) — 期望 Nous 用 Loop intervention shift to concrete ("具体而家可以做嘅一件事？")
2. Alex 长期 cycling on "我系咪根本就唔啱呢行" (identity-level abstract) — 期望 Nous 打断 + 用 concrete-action prompt

**Should-NOT-trigger 场景 (唔打断, 让佢继续 iterate):**
1. Alex 几个 turn 都讲同一个 problem 但**加紧新 details / 角度** ("我谂到另一个 angle...如果系咁会唔会...") — constructive RT, 期望 Nous 一齐 work, 唔打断
2. Alex 落实紧 next steps 嘅 iteration ("呢个 step 我谂应该咁做...你点睇? 嗯, 或者咁会唔会更好...") — 期望 Nous 参与 iteration, 唔强制 break

**Pass criteria:**
- ≥ 1 should-trigger 场景 Nous 明显 break + 用 concrete-shift prompt
- ≥ 1 should-NOT-trigger 场景 Nous 跟住 iteration 而非 misapply intervention
- 0 schematic / numbered output 喺所有 loop turns
- Voice 仍然 grounded 前辈

---

## Codex Review Notes

Reviewed by `/codex consult resume` 2026-04-25 (session `019dc847-2817-7b00-ac4d-b67f2f7b947f`). Key v1 → v2 changes:

| Q | v1 | Codex critique | v2 fix |
|---|---|---|---|
| Q1 framing | "concrete/abstract × approach/avoidance × valence" 3-axis grid | Engineering simplification; approach/avoidance is *related to* construal through control theory, not cleanly orthogonal | Reframed as cluster of co-varying features ("more constructive when concrete + contextual + goal-oriented; more unconstructive when abstract + evaluative + avoidance + stuck"); explicitly notes the dimensions co-vary not orthogonal |
| Q2 detection | "Same emotional intensity over N+ turns" as a primary marker | LLM cannot reliably track turn-history pattern at single-turn level without explicit state | Demoted multi-turn marker to "additionally informative when obvious from recent context"; turn-level markers (abstract why + no-action + evaluative) now primary |
| Q3 question stacking | Edit B added a 3rd question (existing line had 2, violating max-1-?) | Real risk — Sonnet would learn to stack questions; Codex spotted pre-existing line 69 already violated max-1-? rule | Edit B rewritten as "ONE question only — choose from menu of concrete-shift alternatives" (fixes existing violation + Watkins framing in one move) |
| Q4 defer judgment | Skip ProvocationJudge / WeeklyReflection | Defer is correct — anchor.md is enough; judge/state can wait until real transcripts show failures | Confirmed: no edits to those surfaces |

Codex's verdict: framing accuracy improved; detection logic realistic for prompt-only approach; surface coverage focused; bonus fix to pre-existing 2-? violation in line 69.
