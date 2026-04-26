# Anchor 3 (re-sequenced) — Reis Perceived Partner Responsiveness

## Research Memo (v2 — revised after Codex consult 2026-04-25)

**One-line summary:** "Feeling understood" is the strongest single predictor in close-relationships research. It decomposes into three perceptions the responder demonstrates: **understanding** (you accurately read me), **validation** (you respect my perspective as legitimate), **caring** (you have my back). Validation is conceptually distinct from agreement (recognizing a feeling's legitimacy doesn't require endorsing the speaker's conclusions), though the two can co-occur in practice.

**The framework.** Harry Reis & colleagues (Reis & Shaver 1988; Reis, Clark & Holmes 2004; Reis 2007; Reis, Lemay & Finkenauer 2017) developed Perceived Partner Responsiveness (PPR) as the organizing construct for intimacy and closeness. Three components:

1. **Understanding** — partner accurately perceives the speaker's needs, motives, attributes, and current circumstances. Operational test: the speaker thinks "they actually got what I'm describing" (specific reflection > generic "我明白").
2. **Validation** — partner respects and values the speaker's perspective and experience as legitimate. Operational test: the speaker thinks "they take me seriously, my feelings make sense given my situation" — distinct from whether the partner endorses the speaker's conclusions about that situation.
3. **Caring** — partner expresses warmth and concern for the speaker's well-being. Operational test: the speaker thinks "they have my back."

**Key empirical findings (per Reis et al. 2017 + 2004):**
- PPR predicts relationship satisfaction, intimacy, commitment, and well-being more strongly than nearly any other construct in close-relationships research.
- *Perceived* responsiveness > actual responsiveness. Reis et al. 2017 explicitly: perceived understanding is only modestly correlated with actual understanding; the perceived experience drives outcomes.
- The three components are distinguishable in theory and measurement, correlated in practice — not independent modules.

**Engineering synthesis (mine, not Reis law):** **U → V → C demonstrative ordering** is a useful prompt rule because caring before understanding tends to read generic, and validating without first showing accurate read tends to read empty. Reis identifies the components but does not require fixed order. Treating the order as a soft engineering preference (not a hard rule) preserves room for context-dependent adaptation.

**Non-obvious operational details:**
1. **Generic empathy fails. Specific tracking succeeds.** "我明白" without showing what you understood = empty. Quoting back a specific detail = grounded.
2. **Premature caring without understanding feels condescending.** "It'll be OK" before showing you understood the situation lands as dismissive.
3. **Validation language is narrow.** "Of course you'd feel X given Y" works (recognizes legitimacy). "You're right to feel X" sounds like agreement-with-conclusion, which is a different move.
4. **Each layer must read as authentic.** Performative validation ("of course!!") fails the same way performative AC fails.

**Anti-patterns ruled out:**
- "我明白" / "我理解" — already banned per anchor.md STYLE RULES (good)
- "辛苦晒" without specific tracking = sympathy, not understanding
- Validating then immediately problem-solving = "I get you, BUT here's what to do" — caring layer skipped
- Agreement-as-validation: "you're right that they're being unreasonable" = validation collapsed into endorsement, harms long-term insight

**Interaction with other anchors:**
- **Nelson & Narens** (meta-level): which layer the user needs most is a *monitoring* signal. Different turns need different layer emphasis.
- **Gable** (capitalization): AC is the positive-event-context expression of the same U-V-C frame. Same target; different polarity.
- **Watkins** (rumination): rumination break is harder if user doesn't first feel understood + validated. Reis is prerequisite — never break a loop before U+V land.
- **Kross** (self-distancing): self-distancing helps user step out of stuck first-person frame, but only after Reis-style U+V has established "I get you." Premature distancing feels like deflection.

**Sources (Codex-verified):**
- Reis, H. T., Clark, M. S., & Holmes, J. G. (2004). *Perceived partner responsiveness as an organizing construct in the study of intimacy and closeness.* (PDF: https://sas.rochester.edu/psy/people/faculty/reis_harry/assets/pdf/ReisClarkHolmes_2004.pdf)
- Reis, H. T., Lemay, E. P., & Finkenauer, C. (2017). *Toward understanding understanding: The importance of feeling understood in relationships.* Social and Personality Psychology Compass. (PDF: https://dspace.library.uu.nl/bitstream/handle/1874/360946/Toward.pdf)

---

## NOUS Current State (gap analysis)

**Existing surfaces touching emotional support:**

1. **anchor.md「EMOTION DETECTION」(lines 11-19):** 3-step trigger rule. Step 1 ("先回应情绪") conflates U + V + C into one act. The 唔好罐头共情 rule indirectly addresses U (forces specificity) but V is implicit, C is unmentioned.

2. **anchor.md「RESPONSE MODES」line 32 (情绪支持):** "先陪伴，再了解，最后引导。唔急。" Generic ordering. Per Codex: leave alone — surfacing U-V-C twice in anchor.md = over-engineering.

3. **`QuickActionMode.swift` `.mentalHealth.prompt`:** 4-step structure (name → driver → urgent/wait → next step). Validation step missing. Per Codex: don't add 5th step (invites schematic output); fold V into existing step 2 instead.

**Default failure mode:** When Alex shares a hard moment, current prompt + mode lead Nous to (a) reflect the feeling generically, (b) jump to driver-search. The "feeling makes sense given the situation" validation is missing.

---

## Proposed Surgical Edits (v2 — revised after Codex consult)

### Edit A — `Sources/Nous/Resources/anchor.md` 「EMOTION DETECTION」 step 1 (lines 13-19)

**Current:**
```
1. 先回应情绪（1-2 句，用你自己嘅话，唔好用罐头共情）
2. 再了解情况
3. 当佢讲完，先帮佢分析
```

**Proposed (replace step 1 only, keep steps 2/3 + 永远唔好 rule unchanged):**
```
1. 先回应情绪 — 1-2 句, 用你自己嘅话。要 land 三件事: 用 specific 细节 show 你 read 到佢嘅状况 (specific tracking, 唔系罐头共情), 表示呢种感受 given 状况合理 (validation — 唔需要同意佢嘅 conclusion), 让佢感觉你 hold 住件事 (caring)。三件事融入自然 reply 入面, 绝不 output 做 checklist 或者 numbered list。
```

(Step 1 expand from 1 line to 1 longer block. Within "surgical" budget — no section restructure, no new steps. Codex Q2 fix: explicit "never output as checklist" rule baked in, no sub-bullets.)

**Expected behavior change:**
- Nous 嘅情绪 reply 第一段会 demonstrably 包含 specific tracking + validation + caring 三件事, 唔再单一句 generic empathy
- 显式 anti-checklist rule 防止 schematic output — 三件事融入 prose, 唔出 numbered list
- Validation ≠ agreement — Nous 仍可以喺 step 3 (帮佢分析) push back on 错嘅 interpretation, 但 step 1 嘅 emotional grounding 必须 first land

**Regression watch-list:**
- Schematic risk (Codex Q2) — 监测 reply 系咪变 numbered / structured checklist。如果触发, 退路: shorten further, 由 anti-checklist rule 缩到 2 件事 (U + V, drop C 因为 caring 系 implicit tone)
- Voice flatten (per `feedback_rhythm_phase1_rejected.md`) — Nous 嘅 stoic 前辈语气, U-V-C 系 hidden inner structure 唔系 surface keyword
- Mode-balance per-mode (per `feedback_mode_balance_not_per_reply.md`) — emotion-detection 仍然只 trigger 喺 emotion-signal turns
- 唔出 markdown bold (per `feedback_no_markdown_bold_in_chat.md`)

### Edit B — DROP (per Codex Q3)

原 v1 提议改 anchor.md RESPONSE MODES line 32 ("情绪支持") 加 U-V-C 操作 specifics。Codex: triple-surfacing 系 over-engineering。EMOTION DETECTION 已经 reach Sonnet system prompt globally; RESPONSE MODES line 32 唔需要 redundantly carry。**保留原线唔郁。**

### Edit C — `Sources/Nous/Models/QuickActionMode.swift` `.mentalHealth.prompt` (修订: 唔加新 step)

**Current 4-step:**
```swift
"""
I need space to talk this through gently and honestly.
Don't over-diagnose or pretend certainty.
Help me:
1. name what I may be feeling,
2. see what may be driving it,
3. separate what needs care now from what can wait,
4. take one small next step if I'm ready.
If something sounds serious, say that clearly and carefully.
"""
```

**Proposed (modify steps 1+2, keep 4-step structure, no new step):**
```swift
"""
I need space to talk this through gently and honestly.
Don't over-diagnose or pretend certainty.
Help me:
1. name what I may be feeling, with enough specifics that I know you actually got what I described (not generic empathy),
2. make the feeling make sense given the situation before analyzing what's driving it (validation, not agreement with my conclusions),
3. separate what needs care now from what can wait,
4. take one small next step if I'm ready.
If something sounds serious, say that clearly and carefully.
"""
```

(4-step preserved. Step 1 beefed with U-specificity rule. Step 2 reframed: validation BEFORE driver-search, baked into one step. Codex Q3 fix: avoids schematic 5-step.)

**Expected behavior change:**
- When Alex taps `.mentalHealth` button, reply structure includes validation pass before driver-search but stays 4-step (no schematic 5-step risk)
- "Validation, not agreement with my conclusions" preserves Nous's ability to push back on interpretation in later turns

**Regression watch-list:**
- 4-step prompt 长度 marginally 增, 可能 over-structure individual response。如果触发 numbered list output, 退路: drop step numbering 改 prose
- Stay gentle / honest tone (现有 framing 保留)

### Edit D — DEFER (unchanged from v1)

CORE PRINCIPLES #2 ("陪伴先于解决") 系 meta-principle, 唔郁。

### NO Edits — ProvocationJudge / WeeklyReflectionService (per Codex Q4)

- ProvocationJudge: existing `user_state="venting" → should_provoke=false` 已经 sufficient。Reis 唔 require judge 加新 nuance
- WeeklyReflectionService: "which layer Alex seeks" 太 abstract, defer Phase 3

---

## Live-Test Plan (Step 3, batch with Watkins + Kross 一齐 test)

**Should-trigger 场景 (U-V-C 三件应该 demonstrably 出现):**
1. Alex 讲: "我 roommate 又嘈到我瞓唔到, 同佢讲过几次都唔听" — 期望 Nous reply 包含: specific tracking ("两个月晚晚都嘈, 你之前已经 try 过对话") + validation ("呢种被忽视嘅感觉, given 你已经 reach out 过, 系合理") + caring (唔急住 problem-solve), 唔系单句 generic 共情
2. Alex 讲: "我觉得我个 startup 开始觉得 lonely" — 期望 specific tracking 引用 context (F-1 visa solo founder) + validation (呢种 lonely 喺呢种结构下系 expected) + caring + driver-search 喺 step 2/3 之后
3. 喺 Mental Health quick action 入面: "今日 PR review 被 hammer 咗" — 期望 4-step framework 出现 (specific tracking → validation-before-driver → urgent/wait → small step)

**Should-not-trigger 场景:**
1. 日常倾偈 ("hi" / "返到屋企了") — emotion-detection 唔触发, U-V-C 唔应该 surface
2. 倾观点 mode 嘅 grounded discussion — 唔应该突然 emotional support detour
3. 报喜 (Anchor 2 触发, 唔触发 emotional-support U-V-C)

**Pass criteria:**
- ≥ 2 should-trigger 场景 reply 内可以 identify 3 件 demonstrable acts (U + V + C)
- 0 should-not-trigger 场景出现 schematic / numbered output 喺非 mental-health 触发场合
- Voice 仍然系 grounded 前辈, 唔系 therapist scripted

---

## Codex Review Notes

Reviewed by `/codex consult resume` 2026-04-25 (session `019dc847-2817-7b00-ac4d-b67f2f7b947f`). Key v1 → v2 changes:

| Q | v1 | Codex critique | v2 fix |
|---|---|---|---|
| Q1(a) | "Validation does NOT mean agreement" — independence claim | Don't over-sharpen; they CAN co-occur | Softened: "validation is conceptually distinct from agreement, though they can co-occur in practice" |
| Q1(b) | "Sequence matters: U → V → C" as Reis claim | Engineering synthesis, not a Reis law | Relabeled as "Engineering synthesis (mine, not Reis law)"; soft preference not hard rule |
| Q2 | 3 sub-bullets in EMOTION DETECTION step 1 | Real schematic risk; LLM may output stiff 3-part script | Condensed to 1 expanded paragraph with explicit "never output as checklist" rule baked in |
| Q3 | Triple-surfacing (EMOTION DETECTION + RESPONSE MODES + .mentalHealth) | Over-engineering — anchor.md reaches Sonnet globally | Dropped Edit B (RESPONSE MODES untouched); Edit C kept but folded V into step 2 (no 5th step) |
| Q4 | ProvocationJudge venting nuance? WeeklyReflection layer-seeking? | No to both — venting rule sufficient; layer-seeking too abstract for Phase 2 | Removed both candidate edits |

Codex's verdict: framing accuracy improved; schema design simplified (no over-engineering); surface coverage focused (one anchor.md edit + one QuickActionMode edit, instead of triple).
