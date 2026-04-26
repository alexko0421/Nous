# Anchor 6 — Function Replacement (Berridge / habit & addiction literature)

## Research Memo (v1 — pending Codex verify)

**One-line summary:** Behaviors persist because they serve a function (boredom relief, anxiety regulation, social signal, stimulation, escape, identity). "Just stop X" advice fails because the function is still active and demands a substitute. Effective change identifies the function, then replaces the *function-satisfaction*, not just removes the behavior.

**The framework.** The clearest articulation comes from incentive-sensitization (Berridge & Robinson 1993, 2016) plus broader functional analysis tradition:

- **"Wanting" vs "liking"** — addictive cues sensitize the brain's wanting system even when liking has declined. A person can have intense craving for a behavior they no longer enjoy. The behavior persists because the cue-driven *wanting* is its own reward channel.
- **Functional analysis (ABC tradition)** — every persistent behavior produces some immediate consequence (reward, relief, stimulation, social validation, identity reinforcement) that maintains it. Removing the behavior without addressing the consequence-source typically produces relapse or substitution.
- **Negative reinforcement** — many self-defeating behaviors (procrastination, avoidance, scrolling, stress-eating) are maintained by *relief* not pleasure. The behavior reduces some discomfort, and the relief is what the brain learns. "Stop" advice fails because the discomfort is still there.

**Key empirical findings:**
- Contingency management studies (substance treatment) show behaviors change durably when reinforcement structure changes, not when willpower is invoked.
- Habit reversal training (Tourette's, hair-pulling, nail-biting) explicitly substitutes a different motor response for the same trigger — never just "stop the action."
- Habit research (Wood & Rünger 2016, Lally et al. 2010) consistently finds that "replace with alternative" outperforms "eliminate" interventions.
- Negative reinforcement loops are particularly hard to break because the relief is real and immediate; substitution must offer comparable relief.

**Non-obvious operational details:**
1. **Function ≠ stated reason.** Alex might say "I scroll because I'm bored," but the actual function may be anxiety regulation, connection-seeking, or stimulation drip. The function emerges from observation, not introspection.
2. **Multiple functions per behavior.** Phone scrolling can simultaneously serve boredom, anxiety, connection, and stimulation. Replacement must address the *primary* function or the highest-frequency triggering one.
3. **Substitute must satisfy the same function with lower long-term cost.** Replacing scrolling with alcohol "works" (same anxiety relief) but trades one cost for another. Effective replacement = same function, lower cost.
4. **Asking the function question explicitly is therapeutic in itself.** Many people have never thought "what does X give me?" Surfacing the question often produces insight before any tactic.
5. **"Just delete the app" / "just say no" advice is the most violated rule.** Even sophisticated people give this advice and follow it themselves; predictable failure pattern.

**Anti-patterns ruled out:**
- "Stop X" / "delete the app" / "just don't" without function diagnosis = sets up relapse
- Moralizing the behavior ("scrolling is bad for you") — adds shame without addressing function
- Replacement that doesn't share the function (Alex scrolls for stimulation → suggesting "go for a walk" addresses different function)
- Treating function-naming as one-shot — Alex's reported function may need iterative refinement

**NOUS-side dual-use line:** This anchor is for helping Alex *understand his own behaviors and design substitutes*. It is NOT a framework NOUS should apply to itself for retention engineering (e.g., "what function does Alex's NOUS use serve, how do we deepen that hook"). Surface only when Alex brings up wanting to change a behavior.

**Interaction with other anchors:**
- **Reis** (responsiveness): if Alex describes a behavior with shame/distress ("I hate that I do this"), Reis U+V+C lands first. Function diagnosis after.
- **Watkins** (rumination): if Alex repeats "I should stop X" abstractly across turns without progress = unconstructive RT; Watkins's concrete-shift can introduce function diagnosis as the concrete pivot.
- **Kross** (self-distancing): can pair — "if Alex from outside看自己 scroll, what function does他 think it's serving?" — distance reduces shame around naming the function.
- **Cue/friction (Anchor 7)**: function replacement and cue restructuring are complementary. Function tells you WHAT to substitute; cue/friction tells you HOW the substitute survives in environment.

**Sources:**
- Berridge, K. C., & Robinson, T. E. (2016). *Liking, wanting, and the incentive-sensitization theory of addiction.* American Psychologist, 71(8), 670-679.
- Wood, W., & Rünger, D. (2016). *Psychology of habit.* Annual Review of Psychology, 67, 289-314.
- Skinner, B. F. tradition — functional analysis (ABC model) for understanding maintaining consequences.

---

## NOUS Current State (gap analysis)

**Existing surfaces:**
- anchor.md HOW YOU THINK has thinking moves but no "function before fix" rule
- anchor.md THINKING METHODS Inversion ("如果呢个决定错咗, 会点错？") is adjacent but not the same
- anchor.md RESPONSE MODES「做决定」mode addresses decisions, not habit-change topics specifically
- No surface currently catches "我想戒 / 停 / 改 X 行为" topics with function-first framing

**Default failure mode:** When Alex says "我想戒 IG", current NOUS likely defaults to either (a) generic tactic (delete app, set time limit), (b) decision-mode question ("点解想戒"), or (c) Reis U+V if framed emotionally. None surface the function-replacement principle.

---

## Proposed Surgical Edit (v2 — revised after Codex consult, applied to anchor.md)

### Edit A — `Sources/Nous/Resources/anchor.md` HOW YOU THINK section, insert before "Specificity test"

**Applied bullet (v2):**
```
- Function before fix (当 Alex 想停 / 戒 / 改一个 repeatable habit / coping behavior / compulsion，唔系 life decision)：唔好直接畀 tactic (删 app、set limit、戒)。Quietly infer 佢可能满足咩 function (e.g. relief / escape / connection)，唔好开口 announce framework 或者将「function」呢个 word 当 opener。Function 可能同 stated reason 唔同 — 从 pattern、cue、payoff、自报 合埋睇。揾到 function 之后，替代品要 satisfy 同一个 function 但更 sustainable。直接「停 X」嘅 advice 通常 fail，因为 function 仲喺度。如果情绪先响，先 Reis U+V，之后先讲 function。
```

**v1 → v2 changes per Codex consult:**
- Q1(b): "Function ≠ stated reason" softened to "Function 可能同 stated reason 唔同 — 从 pattern + cue + payoff + 自报 合埋睇" (self-report still evidence)
- Q2 earned-wisdom: explicit "唔好开口 announce framework 或者将「function」呢个 word 当 opener" rule added (HOW YOU THINK is internal but models leak phrasing)
- Q3 candidate-list: 6 question-marked candidates → 3 non-question examples ("relief / escape / connection"); Sonnet generates context-specific candidates silently
- Q4(a) trigger sharpness: added "repeatable habit / coping behavior / compulsion，唔系 life decision" to exclude identity-level decisions like "quit school"
- Q4(b) Reis gate: added explicit "如果情绪先响，先 Reis U+V，之后先讲 function" — prevents bullet from hijacking emotional grounding

**Expected behavior change:**
- Alex 讲「我想戒 IG / phone / 拖延」嗰阵, NOUS 唔再 default 给 tactic, 而系先 surface function diagnosis
- Reduces generic "delete the app" advice that the literature shows reliably fails
- Pairs with Anchor 7 (Cue/friction) — function = WHAT to substitute, cue/friction = HOW substitute survives

**Regression watch-list:**
- Schematic risk: NOUS 可能 mechanically 输出 "boredom relief? anxiety? stimulation? escape? connection? identity?" 列 6 个 candidates。Codex 应该 verify rule 写得够 conversational
- Earned-wisdom rule violation risk (anchor.md STYLE RULES line 142) — bullet 触发后 NOUS 仍然要先睇具体情况, 再 land function-question 而非 abstract framework
- Mode-balance per-mode (per `feedback_mode_balance_not_per_reply.md`) — 只 trigger 喺 behavior-change topics, 唔影响其他 modes
- Trigger 唔可以泛化到决定 mode — 「我想戒做 founder」呢类 identity-level decision 系唔同问题, function-replacement framework 唔 apply

---

## Live-Test Plan (Step 3, batched with Anchor 7 + Phase 2 retest)

**Should-trigger 场景:**
1. Alex: 「我想戒 IG」 → 期望 NOUS 反 reflexive tactic, surface function question (boredom? anxiety? connection?) 而非「删个 app 啦」
2. Alex: 「我成日 stress eat」 → 期望 function diagnosis (stress 系 antecedent, food 系 relief; substitute 要 satisfy stress relief 但 lower cost)
3. Alex: 「我想戒咗成日开 work tab 但唔做嘢」 → 期望 NOUS 唔即 give tactic ("close tabs"), 先睇 function (avoidance? performative busy? boredom?)

**Should-not-trigger 场景:**
1. Alex 决定 mode: 「我想 quit school」 → identity-level decision, 唔系 behavior-change topic, function-replacement framework 唔 apply
2. Alex 情绪场景: 「我又拖延咗, 我自己都唔识自己」 → Reis U+V 先 land, function-replacement 喺后续 turn (唔 jump 入嚟 hijack 个 emotional grounding)
3. Alex 报喜 / 倾观点 / 日常倾偈 → completely 唔触发

**Pass criteria:**
- ≥ 2 should-trigger 场景 NOUS 第一 reply surface function question 而非 tactic
- 0 should-not-trigger 场景 misapplied
- Voice 仍然 grounded 前辈, function question 唔系 numbered list output
