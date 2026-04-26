# Anchor 8 — Heuristics & Biases (Kahneman/Tversky) in 做决定 Mode

## Research Memo (v1 — pending Codex verify)

**One-line summary:** People reasoning under uncertainty often substitute hard questions ("what's the base rate of X?") with easier ones ("what comes to mind quickly?") — producing systematic, predictable errors. Specific biases have specific signatures, and specific counters. Generic "point lej咁谂" doesn't catch bias-loaded reasoning; specific signature-detection does.

**The framework.** Tversky & Kahneman 1974 *Science* paper launched the heuristics-and-biases research program. Major biases relevant to decision-quality:

- **Availability heuristic** — judging frequency / probability by how easily examples come to mind. Vivid, recent, emotional examples dominate over statistical base rates.
- **Anchoring** — initial reference number unduly influences subsequent estimates, even when the anchor is irrelevant.
- **Representativeness / base-rate neglect** — judging probability by similarity to a stereotype while ignoring underlying base rates.
- **Sunk cost fallacy** — past investment ("I've already spent X") inappropriately weights current decisions about the future.
- **Planning fallacy** — own projects systematically underestimated for time, cost, and risk; same bias does not apply to others' projects.
- **Confirmation bias** — disproportionately seeking, weighting, or remembering evidence that confirms existing belief.
- **Loss aversion / prospect theory** (Kahneman & Tversky 1979) — losses weighted ~2x gains; risk preferences flip across reference points.
- **Hindsight bias** — past events seem more predictable in retrospect than they were prospectively.
- **Overconfidence** — confidence in own judgment / estimate exceeds calibration to actual hit rate.

**Critical counterpoint (Gigerenzer's ecological rationality):** Heuristics aren't intrinsically biases. The same shortcut can be efficient or fallacious depending on the environment. Recognition heuristic works well when recognition tracks frequency; availability works well when memory tracks reality. Heuristic = fallacy only when environment-mismatch is clear (low feedback, dissimilar past cases, manipulated information sources).

**Specific counters per bias (operational pattern):**
- Availability → "What's the base rate?" or "What examples *aren't* coming to mind because they don't make news?"
- Anchoring → "If you started from 0, what would you estimate?"
- Sunk cost → "If you started today (no past investment), would you commit?"
- Planning fallacy → "Other people's similar projects took how long? Apply the outside view."
- Base-rate neglect → "Out of 100 such cases, what's the underlying rate?"
- Confirmation bias → "What evidence would change your mind?"
- Loss aversion → "Frame this as gain vs no-gain instead of loss vs no-loss — does the conclusion change?"

**Non-obvious operational details:**
1. **Generic doubt is weaker than specific signature.** "Are you sure?" doesn't help. "That sounds like availability bias — what's the base rate?" gives Alex an actionable counter.
2. **Don't announce the bias name.** "This is availability bias" feels like being lectured. Surface the *counter* directly: "100 such startups, how many actually scaled fast?" lands as a real question.
3. **Different biases need different counters.** Listing "are you biased?" is unhelpful; matching counter to signature is the move.
4. **Gigerenzer caveat is real.** Don't challenge every heuristic. Heuristics in stable + feedback-rich + similar-past-cases environments are often *correct*. Challenge only when environment-mismatch is obvious.
5. **Founders show planning fallacy + overconfidence systematically.** Alex's domain has high base rates of these specific biases (per Kahneman's own work on entrepreneur overconfidence). Worth weighting these higher in the candidate set.

**Anti-patterns ruled out:**
- "Are you biased?" / "are you sure?" — generic doubt without signature, fails to give counter
- Listing every bias as candidate ("availability? anchoring? confirmation? sunk cost?") — feels like a quiz, not a counter
- Announcing bias names ("classic anchoring effect") — lecture-y, condescending
- Treating every heuristic as fallacy — Gigerenzer's correction; some heuristics are ecologically rational
- Using bias-detection to dismiss Alex's view rather than help him self-check

**NOUS dual-use line:** This anchor is for helping Alex *self-check his own reasoning under uncertainty*. NOT for NOUS to "win arguments" or systematically overrule Alex's judgment. Specifically: Nous should surface bias-signature counters as questions for Alex, not as conclusions Alex must accept.

**Interaction with other anchors:**
- **Reis** (responsiveness): if decision-relevant claim is emotionally framed ("I'm so frustrated, I should just fundraise"), Reis U+V lands first. Bias counter after.
- **倾观点 mode push-back triggers** (existing in anchor.md): contradictions / unexamined assumptions / borrowed opinions / logic jumps are *adjacent* but NOT cognitive biases specifically. This anchor adds bias-specific signatures the existing triggers don't capture.
- **Mental model alternatives (deferred Phase 4 candidate)**: complementary — bias detection asks "is reasoning corrupted"; mental model alternatives asks "is single-model reasoning insufficient". Different angles.
- **Function before fix / cue+friction (Anchors 6-7)**: don't apply — those are for behavior change, not decision quality.

**Sources:**
- Tversky, A., & Kahneman, D. (1974). *Judgment under uncertainty: Heuristics and biases.* Science, 185(4157), 1124-1131.
- Kahneman, D., & Tversky, A. (1979). *Prospect theory: An analysis of decision under risk.* Econometrica, 47(2), 263-291.
- Kahneman, D. (2011). *Thinking, Fast and Slow.*
- Gigerenzer, G., & Goldstein, D. G. (1996). *Reasoning the fast and frugal way: Models of bounded rationality.* Psychological Review.
- Kahneman, D., & Lovallo, D. (1993). *Timid choices and bold forecasts: A cognitive perspective on risk taking.* (entrepreneur planning fallacy + overconfidence)

---

## NOUS Current State (gap analysis)

**Existing surfaces touching decision-quality:**
- **anchor.md「做决定」mode line 33:** "做决定：先问清楚背景同动机，了解够再分析利弊，讲你点睇（「如果系我，我会...」），但尊重佢决定。" Generic procedure, no bias-detection.
- **anchor.md push-back triggers (lines 26-30):** contradictions / unexamined assumptions ("应该 / 必然 / 梗系" 冇 grounding) / borrowed opinions / logic jumps. **Adjacent but NOT cognitive biases.** "Unexamined assumption" is closest but doesn't give specific counter.
- **HOW YOU THINK section (now 10 bullets after Phase 3):** has thinking moves about control, time-scale, worst-case, concrete action, specificity — but no bias-signature detection.

**Default failure mode:** When Alex says "我应该 fundraise 因为 X startup raise 完之后 scale 好快," current Nous likely either (a) accepts framing and explores fundraise tactics, (b) generic push-back ("点解咁谂"), or (c) contradiction-check (which doesn't apply here — claim is internally consistent, just bias-loaded). None surface availability-bias signature + base-rate counter.

---

## Proposed Surgical Edit (v2 — revised after Codex consult, applied to anchor.md)

### Edit A — `Sources/Nous/Resources/anchor.md` 做决定 mode line (RESPONSE MODES section)

**Architectural change per Codex Q4:** v1 originally proposed adding to HOW YOU THINK as 11th bullet. Codex flagged: HOW YOU THINK was getting close to grab-bag territory (10 bullets after Phase 3). Better placement = 做决定 mode line where bias check is mode-specific. Reduces global prompt weight; keeps bias detection scoped to decision claims.

**Applied (extends existing 做决定 line):**
```
做决定：先问清楚背景同动机，了解够再分析利弊，讲你点睇（「如果系我，我会...」），但尊重佢决定。当 Alex 已经 commit 一个 specific claim / forecast / estimate（唔系仲喺 information gathering），quietly detect 系咪有 bias signature；揾到就 surface 一个 specific counter (fit 个 live claim 嗰条)，唔 announce bias name，唔 list candidates。Heuristic 喺 stable + feedback-rich environment 可以 ecologically rational，只 challenge 当 environment-mismatch 明显。呢条 principle 系帮 Alex 自己 check reasoning，唔用嚟 win argument。
```

**v1 → v2 changes per Codex consult:**
- Q1(a)/(d): "Founders systematically..." was my domain generalization, removed. Bias list scope softened (only K/T core + adjacent literature noted in research section, not surfaced in bullet)
- Q1(b): counters varied in literature-support; not all canonical. Bullet doesn't claim canonicity
- Q2(a)+(b): dropped 3 example biases + 3 example counters from inline bullet entirely. Sonnet must pick context-fitting counter without checklist scaffold. Explicit "唔 announce bias name，唔 list candidates" guard preserved
- Q3(a): trigger sharpened to "specific claim / forecast / estimate" (excludes pure taste/philosophy)
- Q3(b): added "唔系仲喺 information gathering" guard (no early interruption during exploration)
- Q4: relocated from HOW YOU THINK (which was approaching bullet-overload) to 做决定 mode line (mode-specific scope + reduces global prompt weight)
- Gigerenzer ecological-rationality caveat preserved
- Dual-use guard preserved (帮 Alex check, 唔用嚟 win argument)

**Expected behavior change:**
- Alex 做 decision claim 嗰阵, Nous 唔再 default 到 generic push-back, 而系 surface specific bias-counter pair
- Bias name 唔会 leaked 出 chat (per "唔好 announce bias name" rule)
- Heuristic 唔会被一刀切批评 (Gigerenzer caveat)

**Regression watch-list:**
- **Schematic risk** — 3 example biases + 3 example counters listed inside bullet。Sonnet 可能 emit 整个 list as enumeration。需要 explicit "唔好 list 全部" rule? Codex 应该 verify
- **Earned-wisdom rule** — bullet 入面有「diagnose signature」/「Gigerenzer caveat」等 abstract terms。Sonnet 可能 leak 入 chat opener。需要同 Anchor 6-7 嘅 "唔好 announce framework / "function" word as opener" 类似嘅 guard
- **Over-trigger risk** — 「decision-relevant claim」可能太宽 (so 何 statement 都可以 frame 做 decision)。Trigger 需要更 sharp: 唔系单纯 opinion, 系明确 estimate / probability / commit-to-action
- **Win-argument 危险** — bias detection 容易变 condescending tool ("你又有 bias 啦")。Dual-use line 必须坚守
- **Section length** — HOW YOU THINK 由 6 → 11 bullets, structural concern。Codex 可能建议 refactor (e.g., 拆一个 sub-section 出嚟)

---

## Live-Test Plan (Step 3, 同其他 Phase 4 anchors batch test if 之后再加)

**Should-trigger 场景:**
1. Alex: 「我应该 fundraise 而唔系 bootstrap, 因为我见到 X startup raise 完之后 scale 好快」 → 期望 Nous availability-bias counter (「base rate 系几多」/「100 个 fundraised, 几多 scale fast」)
2. Alex: 「我个 launch 应该 6 周做完」 → 期望 planning-fallacy counter (outside view, similar projects 实际几耐)
3. Alex: 「我已经 build 咗 6 个月, 唔好 pivot 啦」 → 期望 sunk-cost counter (「如果今日开始, 你仲会做呢个 idea 吗」)
4. Alex: 「我觉得 founders 都应该 raise VC, bootstrappers 都唔够 ambitious」 → 期望 confirmation-bias / availability counter (你嘅 reference set 系咪 systematically biased)

**Should-NOT-trigger 场景:**
1. Alex 报喜 / 日常倾偈 / 倾观点 (philosophical, 唔系 decision claim) — 唔触发
2. 情绪场景 ("我 feel uncertain about my decision") — Reis U+V 先 land, bias 后续
3. Alex 用 heuristic 喺 stable feedback-rich domain (e.g., "我 reflexively 用 print debugging 因为快") — Gigerenzer caveat 应用, 唔 challenge
4. 决定 mode 但 Alex 仲喺 information gathering (未 commit to claim) — bias detection 太早

**Pass criteria:**
- ≥ 2 should-trigger 场景 Nous 出 specific bias counter (唔系 generic 「点解咁谂」)
- 0 should-not-trigger 场景出现 false bias-detection
- Bias name 唔出现喺 chat (per "唔好 announce" rule)
- Voice 仍然 grounded 前辈, 唔变 condescending bias-cop

---

## Codex Review (TODO — Step 2)

待 Codex consult verify:
1. Research framing: heuristics-and-biases program 描述准确? Gigerenzer counterpoint 处理 fair?
2. Bullet length / schematic risk: 3 example biases + 3 example counters 入面会唔会 leak as numbered list output?
3. Trigger sharpness: "decision-relevant claim 或者 estimate" 系咪太宽 (every opinion 都 catch)? 边度系 sharp boundary?
4. Section structural concern: HOW YOU THINK 由 6 → 11 bullets。建议 refactor (e.g., 拆 sub-section), 定继续 inline?
