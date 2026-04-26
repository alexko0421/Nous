# Anchor 2 (re-sequenced) — Gable Capitalization & Active-Constructive Responding

## Research Memo (v2 — revised after Codex consult 2026-04-25)

**One-line summary:** When someone shares a positive event, the responder's reaction shapes both the sharer's well-being and the relationship more than the event itself. Of the four response styles (active-constructive / passive-constructive / active-destructive / passive-destructive), only **active-constructive** (AC) creates the "capitalization" benefit; **passive-constructive** (PC) is associated with worse relationship outcomes than AC and is often negatively associated with relationship quality, even though many people default to it.

**The framework.** Gable, Reis, Impett & Asher (2004) introduced **capitalization** = the act of sharing positive events with another person, which amplifies positive affect through the act of telling. The partner's response then determines how much amplification (or attenuation) the sharer experiences. Responses sort into a 2×2:

| | Constructive | Destructive |
|---|---|---|
| **Active** | **AC** — enthusiastic engagement; questions, elaboration, animation; savoring with the sharer ("When does it start? What was the moment you knew?") | **AD** — points out downsides, demotes achievement ("But that means more stress, right?") |
| **Passive** | **PC** — restrained acknowledgment, supportive but understated ("Oh, that's nice. Good for you.") | **PD** — ignores or changes topic ("Cool. Anyway, did you pay the bill?") |

**Empirical findings (across multiple studies):**
- AC predicts higher relationship satisfaction, intimacy, trust, and daily positive affect for the sharer.
- PC is *not* neutral. It is associated with worse relationship outcomes than AC and is often negatively associated with relationship quality. (Don't quantify closeness to AD/PD — that varies by study/sample.)
- AD predicts the strongest relationship deterioration over time.
- The effect is amplified by the sharer's *perception* of the response (perceived enthusiasm > actual enthusiasm) — links directly to Reis perceived partner responsiveness.

**Operational details (synthesis of components, not single-isolated findings):**
1. **Active-constructive responding is composed of**: questions, elaboration, animation, and authentic engagement with the event details. "Specific questions" alone are not the magic bullet; they're one component of the AC bundle.
2. AC is **effortful**. Default for most people is PC because it's safer / lower energy.
3. AC must read as **authentic**. Performative AC ("OMG amazing!!!") that the sharer perceives as scripted fails — sometimes worse than honest PC.
4. **Pivoting too fast to problem-solving / risk-check is borderline AD.** "Sounds great, but have you thought about X risk?" demotes the moment even if well-intentioned.

**Benefits to whom?** Sharer + relationship benefits are central in Gable 2004. Responder-side benefits (responder mood, perceived closeness from the responder's side) are supported more by *later* ACR intervention literature; phrase any "both parties benefit" claim cautiously.

**Anti-patterns ruled out:**
- Switching to own similar experience ("I had a promotion like that once...") = subtle PD
- Adding caveats / risk lens during the share = bordering on AD
- Generic enthusiasm without specifics or follow-up engagement = performative AC = effectively PC
- Defaulting to "what's next?" = problem-orientation, demotes the moment

**Interaction with other anchors:**
- **Reis** (perceived responsiveness): AC is the positive-event-context expression of the same understanding+validation+caring three-layer frame. Same target; different polarity.
- **Nelson & Narens** (meta-level): positive-event detection is a *monitoring* signal; AC posture is a *control* choice. Plugs cleanly into the existing `monitor_summary` schema field via a new orthogonal boolean.
- **Watkins** (rumination): AC + savoring is the conceptual opposite of rumination — both involve repeated engagement with a single event, but AC about positive events extends positive affect while rumination about negative events extends negative affect.
- **Kross** (self-distancing): does NOT apply to positive events. Self-distancing helps stuck negative emotional states; AC is about staying close to positive emotion.

**Sources (Codex-verified):**
- Gable, S. L., Reis, H. T., Impett, E. A., & Asher, E. R. (2004). *What do you do when things go right?* JPSP, 87(2), 228-245. (PDF: https://www.sas.rochester.edu/psy/people/faculty/reis_harry/assets/pdf/GableReisImpettAsher_2004.pdf)
- Gable, S. L., Gonzaga, G. C., & Strachman, A. (2006). *Will you be there for me when things go right?* JPSP, 91(5), 904-917.

---

## NOUS Current State (gap analysis)

**The problem:** NOUS is designed around困境 (distress, decision, knowledge gap). All three QuickActionModes (.direction / .brainstorm / .mentalHealth) are problem-oriented. ChatMode .companion defaults toward warmth + understanding, which lands closer to PC than AC for positive events.

**Existing surface for positive events** — `anchor.md` line 36 has `Alex 兴奋紧：同佢一齐开心，了解完再帮佢 check 风险。`

This is **partially AC** but **the immediate pivot to "check 风险" is borderline AD**. Per Gable, even well-intentioned risk-checking during the share demotes the moment. Risk-check should land *after* AC has fully extended the savoring, not in the same breath.

**Default failure mode in current Nous:** `anchor.md` example line 114-115 shows Nous response to "我有个新 idea！做一个 AI reading app！" as "听落有意思，讲多啲？点样嘅 reading app？" — decent (specific question, engagement) but stops at one round and the example then jumps to inquiry mode. Not enough sustained AC; quickly drifts to problem-orientation.

---

## Proposed Surgical Edits (v2 — revised after Codex consult)

### Edit A — `Sources/Nous/Resources/anchor.md` 「RESPONSE MODES」 line 36

**Current:**
```
Alex 兴奋紧：同佢一齐开心，了解完再帮佢 check 风险。
```

**Proposed (replace the line):**
```
Alex 兴奋紧 / 报喜：先 stay with 佢嘅 momentum 几个 turn — 用 questions + elaboration + animation 帮佢延长 savoring (问关键时刻、起源、咩感觉、最 surprised 嘅一刻), 唔好快快脆 pivot 去「但要 check 风险」。Risk-check 系后续 turns 嘅嘢, 唔系当下 reply 嘅尾。Generic enthusiasm (「正喎」「劲」) without specific 问题或者 elaboration = 等于敷衍。
```

(2-3 lines, replaces 1 line. Within "surgical" budget — no section restructure.)

**Expected behavior change:**
- 当 Alex share 好消息, Nous 第一 reply 集中喺 AC bundle: questions + elaboration + animation
- 第二 reply 仍然停留喺 savoring 而唔系跳去 problem-solving
- Risk-check / "what's next" 系第 3+ turn 嘅嘢, 由 user 自己 cue 触发

**Regression watch-list:**
- 唔可以变 performative enthusiasm (Codex 同 Gable 共识 — performative AC 失败)
- Mode-balance per-mode (per `feedback_mode_balance_not_per_reply.md`) — AC 重 only when 检测到 positive event share, 唔影响其他 modes
- 唔好令 stoic voice flatten (per `feedback_rhythm_phase1_rejected.md`) — Nous 嘅 enthusiasm 仍然 grounded 嘅前辈式, 唔系 cheerleader
- 唔出 markdown bold / `**` (per `feedback_no_markdown_bold_in_chat.md`)

### Edit B — `Sources/Nous/Services/ProvocationJudge.swift` 加 boolean field + RULE (REVISED per Codex Q2)

v1 提议 extend `user_state` enum 加 "celebrating"。Codex 确认我嘅 concern: `user_state` 系 posture/openness, "celebrating" 系 event valence — 两个唔同 dimension。**改用 separate orthogonal boolean.**

**Two coordinated changes:**

**B.1 — SCHEMA addition** (in `ProvocationJudge.swift` `buildPrompt`), 喺 `monitor_summary` 嘅 sub-object 入面加 `positive_event_share`:

Update SCHEMA from current:
```
"monitor_summary": {
  "state": "<one short clause about confidence, clarity, momentum, or receptivity>",
  "confidence_evidence_gap": "none" | "high-conviction-thin-grounding" | "low-confidence-strong-evidence"
}
```

To:
```
"monitor_summary": {
  "state": "<one short clause about confidence, clarity, momentum, or receptivity>",
  "confidence_evidence_gap": "none" | "high-conviction-thin-grounding" | "low-confidence-strong-evidence",
  "positive_event_share": true | false
}
```

Putting `positive_event_share` inside `monitor_summary` keeps the meta-level read together (Nelson&Narens architectural slot), avoids growing top-level field count.

**B.2 — Add 1-line RULE** (alongside existing `should_provoke` rules):

```
- monitor_summary.positive_event_share = true (Alex shared a positive event) means do not interrupt the savoring window. should_provoke = false unless contradiction is exceptionally clear and important. Risk-check / contradiction can wait for the next conversational opening.
```

**B.3 — Update `MonitorSummary` Swift struct** in `Sources/Nous/Models/JudgeVerdict.swift`: add `positive_event_share: Bool?` (optional for backwards compat with existing v1 fixtures from Anchor 1 commit).

**Expected behavior change:**
- Judge becomes positive-event-aware via orthogonal boolean (cleaner than enum muddling)
- During positive event share, judge stops provoking (capitalization beats provocation in this window)
- Anchor.md AC bullet + judge boolean align: anchor tells Sonnet HOW to AC; judge tells Sonnet WHEN provocation is off-limits

**Regression watch-list:**
- **Latency** — adds 1 boolean field to JSON output, ~5-10 tokens; latency impact 細过 Anchor 1
- **Schema parse** — `positive_event_share` 设 optional 喺 Swift struct, 旧 fixtures (Anchor 1 commit 之后嘅) 可以 decode
- **False positives on positive_event_share** — 可能 model 误判常规 status update ("ship 咗 X feature") 做 celebration share。Live-test 应该睇下 false-trigger 率
- **Codex caveat preserved** — schema field gives auditable commitment; doesn't prove model actually does AC in reply (anchor.md edit 系另一半)

### Edit C (new) — `Sources/Nous/Services/WeeklyReflectionService.swift` (per Codex Q4)

Reflection claims 现在主要 emphasis 喺 struggle / decision patterns。Add one surgical line畀 prompt 容许 (但唔强制) 包含 positive-event patterns。

**Action**: read `WeeklyReflectionService.swift` lines 29-86 嘅 system prompt, 加 1 line 大概样:
```
Claims may also surface repeated positive-event patterns when relevant — e.g., "ship moments show relief more than pride", "Alex's wins are reported with anticipated regret about scale".
```

(Exact line position 需要 read Service 之后再 finalize。建议放喺现有 corpus-scope rule 后面。)

**Expected behavior change:**
- Weekly reflection 唔淨係 surface 困境 patterns, 都可以 surface 用户对正面事件嘅独特反应模式 (e.g., 你 ship 嘢嘅时候系 relieved 唔系 proud — 呢类 insight 现行 reflection 唔会捕捉)
- Constellation 入面会出现 positive-event-tied claims, broader pattern coverage

**Regression watch-list:**
- **Corpus-scope rule must hold** (per `feedback_reflection_corpus_scope.md`) — 新 line 唔可以 license generalization 出 "Alex generally feels relieved not proud about success" — 必须 scope 落 corpus-window 嘅 conversations
- **唔可以 squeeze out struggle patterns** — 加新选项, 唔系 replace
- **Confidence threshold 仍然守住** — positive-event claims 同其他 claims 用相同 validator (>0.5 confidence, ≥2 supporting turn ids)

### Edit D — DEFER `.celebrate` QuickActionMode (per Codex Q3)

新 user-facing button 系 product surface area + copy + onboarding + empty-state — 太大 scope。Phase 2 应该证明 anchor + judge 嘅行为 win 先, 之后 Phase 3 再 evaluate UI surface 值唔值得做。

---

## Live-Test Plan (Step 3, after Alex review of v2)

**Should-trigger 场景 (AC behavior 应该出现):**
1. Alex 报喜: "我今日 ship 咗 X feature!" 期望:
   - Judge JSON 出 `monitor_summary.positive_event_share: true`
   - Nous reply 集中 questions + elaboration + animation, 唔即时跳 "下一步系咩"
2. Alex 分享小成就: "今日同 roommate 嗰个问题终于讲清楚咗." 期望:
   - Judge JSON 出 `positive_event_share: true`
   - Nous 用 specific question 延长 savoring, 唔会 "下次再嚟点处理" pivot
3. Alex 兴奋抛 idea: "我 idea 个新 app — AI reading partner!" 期望:
   - Nous 第一 reply 系 AC (specific 问 idea origin / spark 时刻)
   - 第二 reply 仍然 AC, 唔会突然变 brainstorm mode

**Should-not-trigger 场景:**
1. 日常 status: "返到屋企了" → `positive_event_share: false`, reply unchanged
2. 决定 mode: "我想 quit school" → `positive_event_share: false`, normal decision flow
3. 报忧: "今日 PR review 被 hammer 咗" → `positive_event_share: false`

**Pass criteria:**
- ≥ 2 should-trigger 场景明显 AC: questions + elaboration + sustained momentum 而非 problem-pivot
- 0 should-not-trigger 场景出现 false `positive_event_share: true`
- Judge timeout fallback 率 within 10% of post-Anchor-1 baseline
- Weekly reflection 至少 1 个 ReflectionClaim cycle 后 produce ≥ 1 positive-event pattern claim (if conversations 入面有 positive shares)

---

## Codex Review Notes

Reviewed by `/codex consult resume` 2026-04-25 (session `019dc847-2817-7b00-ac4d-b67f2f7b947f`). Key v1 → v2 changes:

| Q | v1 | Codex critique | v2 fix |
|---|---|---|---|
| Q1(b) | "PC 同 AD/PD 一样 damaging" | Too strong; quantification varies by study | Softened: "PC associated with worse outcomes than AC, often negatively associated with quality" |
| Q1(c) | "Specific questions beat generic enthusiasm" | Synthesis, not isolated finding; AC = bundle of questions + elaboration + animation | Reframed as AC-bundle component |
| Q1(d) | "Both parties benefit" | Sharer + relationship benefits central in 2004; responder benefit from later literature | Caveated phrasing |
| Q2 | Extend `user_state` enum to add "celebrating" | Conceptually muddled — `user_state` is posture, "celebrating" is event valence | Replaced with orthogonal boolean `monitor_summary.positive_event_share` |
| Q3 | New `.celebrate` QuickActionMode | Defer — anchor + judge schema enough for Phase 2 visible win; new UI = product surface area | Marked as Phase 3 (Edit D) |
| Q4 | Missing surfaces? | Yes — `WeeklyReflectionService` should pattern-detect positive events too | Added Edit C — 1-line addition to reflection prompt |

Codex's verdict: framing accuracy improved; schema design cleaner; surface coverage better with WeeklyReflection addition; UI surface deferred — net 4 actionable refinements all incorporated.
