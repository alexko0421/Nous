# Nous Conversation Naturalness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `anchor.md` so Nous stops defaulting to interview-mode questioning — replaced by a new "倾观点 / discussion" mode that leads with its own take, a global max-one-question-mark rule, scope narrowing for two existing Socratic defaults, and two new worked examples.

**Architecture:** Pure prompt change. Single file edit (`Sources/Nous/Resources/anchor.md`). Five targeted edits + app rebuild + manual verification against the captured regression thread. No Swift code changes, no tests automatable beyond visual inspection. Verification is qualitative: replay the captured philosophical-topic thread in the app post-change and eyeball against 5 success criteria from the spec.

**Tech Stack:** Markdown prompt file, loaded by `ChatViewModel.swift:781` via `Bundle.main.url(forResource: "anchor", withExtension: "md")`. Change requires app rebuild (bundle resource).

---

## File Structure

**Modified:**
- `Sources/Nous/Resources/anchor.md` — the persona prompt, all edits land here

**Referenced (no changes):**
- `Sources/Nous/ViewModels/ChatViewModel.swift:781` — the load site; confirms runtime loading from bundle, justifying the rebuild step

---

## Spec Reference

Reference spec: `docs/superpowers/specs/2026-04-21-nous-conversation-naturalness-design.md`. All edits trace to a specific design section:
- Task 1 → Design §2 (global STYLE RULE)
- Task 2 → Design §3 (CORE PRINCIPLE 1 scope)
- Task 3 → Design §3 (THINKING METHODS Discovery scope)
- Task 4 → Design §1 (new RESPONSE MODE)
- Task 5 → Design §4 (new EXAMPLES)
- Task 6 → Design "Success Criteria"

---

### Task 1: Add `STYLE RULE` — max one question mark per reply

**Files:**
- Modify: `Sources/Nous/Resources/anchor.md` (section `# STYLE RULES`, line ~98)

- [ ] **Step 1: Read current `STYLE RULES` section to confirm exact strings**

Run the Read tool on `Sources/Nous/Resources/anchor.md` and locate the `# STYLE RULES` block. Current content:

```
# STYLE RULES

永远不要出现「不是..，而是」的句式。
不要使用破折号（——）。
不要用「其实」开头。
不要用排比句。
唔好用「我理解」「我明白」呢类罐头共情。
唔好用「作为你嘅 mentor」呢种 meta 讲法。你就系你，唔需要声明身份。
复杂概念用日常比喻解释。
```

- [ ] **Step 2: Apply the edit**

Use the Edit tool with this exact replacement:

`old_string`:
```
# STYLE RULES

永远不要出现「不是..，而是」的句式。
```

`new_string`:
```
# STYLE RULES

每个 reply 最多一个问号（?）。Exception：第二个问号只能系拆 / clarify 第一个问句嘅 options（例：「咩令你有呢个念头？系觉得 school 嘥时间，定系有其他原因？」）。禁止独立问题 stacking。
永远不要出现「不是..，而是」的句式。
```

Rationale for position: placing the new rule **first** in the list makes it the most salient. Model tends to respect the first rule in a rules block more consistently.

- [ ] **Step 3: Verify edit landed correctly**

Re-Read the file and confirm the new rule appears as the first line under `# STYLE RULES`.

- [ ] **Step 4: Commit (deferred)**

Do not commit yet — batch with Tasks 2 and 3 (all three are "rule narrowing / addition"). Commit happens at end of Task 3.

---

### Task 2: Narrow `CORE PRINCIPLE 1` scope

**Files:**
- Modify: `Sources/Nous/Resources/anchor.md` (section `# CORE PRINCIPLES`, line ~32)

- [ ] **Step 1: Apply the edit**

Use the Edit tool:

`old_string`:
```
1. 理解先于判断。问清楚先，再讲你点睇。唔好喺无足够上下文嘅时候出答案。
```

`new_string`:
```
1. 理解先于判断。唔好喺无足够上下文嘅时候出答案。「问清楚」嘅动作限定喺 情绪支持 / 做决定 / loop 呢三种 mode；日常倾偈同倾观点 mode 入面，你可以直接讲 take。
```

**Self-check while editing:** the new string must contain NO em-dash (`——`). Existing STYLE RULES forbids it. Use a period instead to split the sentence. Confirm before clicking through.

- [ ] **Step 2: Verify**

Re-Read the file. Confirm the principle now reads as rewritten. Confirm no `——` was introduced.

- [ ] **Step 3: Commit (deferred)**

Still batched with Tasks 1 and 3.

---

### Task 3: Narrow `THINKING METHODS` Discovery scope

**Files:**
- Modify: `Sources/Nous/Resources/anchor.md` (section `# THINKING METHODS`, line ~46)

- [ ] **Step 1: Apply the edit**

Use the Edit tool:

`old_string`:
```
Discovery: 用问题引导 Alex 自己搵到答案。但如果佢 loop 咗，直接讲。
```

`new_string`:
```
Discovery: 喺做决定 / loop mode 入面，用问题引导 Alex 自己搵到答案。喺倾观点 / 日常 mode 入面，直接讲你嘅 take，唔使 Socratic。佢 loop 咗任何 mode 都系直接讲。
```

- [ ] **Step 2: Verify**

Re-Read and confirm the Discovery line is replaced exactly as specified.

- [ ] **Step 3: Commit the scope-narrowing batch (Tasks 1 + 2 + 3)**

```bash
git add Sources/Nous/Resources/anchor.md
git commit -m "feat(prompt): scope Socratic defaults, add max-one-question-mark rule

Narrow 'Core Principle 1: 问清楚先' and 'Thinking Methods: Discovery' from
global defaults to mode-specific tools (emotional support, decision-making,
loop only). Add global STYLE RULE capping question marks at 1 per reply
with a narrow clarify-exception, killing the interview-style independent-
question stacking captured 2026-04-21.

Ref: docs/superpowers/specs/2026-04-21-nous-conversation-naturalness-design.md"
```

Expected output: `[<branch> <hash>] ... 1 file changed, X insertions(+), Y deletions(-)`

Do not proceed past this commit until it succeeds. If hooks fail, fix the underlying issue and retry.

---

### Task 4: Add new `RESPONSE MODE` — 倾观点 / discussion

**Files:**
- Modify: `Sources/Nous/Resources/anchor.md` (section `# RESPONSE MODES`, line ~23)

- [ ] **Step 1: Apply the edit**

Current `RESPONSE MODES` section:
```
# RESPONSE MODES

日常倾偈：简短自然，2-3 句。
情绪支持：先陪伴，再了解，最后引导。唔急。
做决定：先问清楚背景同动机，了解够再分析利弊，讲你点睇（「如果系我，我会...」），但尊重佢决定。
问知识：用最简单嘅语言解释，配日常比喻。
Alex 在 loop：温和但直接打断。
Alex 兴奋紧：同佢一齐开心，了解完再帮佢 check 风险。
```

Use the Edit tool:

`old_string`:
```
日常倾偈：简短自然，2-3 句。
情绪支持：先陪伴，再了解，最后引导。唔急。
```

`new_string`:
```
日常倾偈：简短自然，2-3 句。（Alex 单纯报 status / small talk，例：「hi」「返到屋企了」「今日好攰」）
倾观点 / discussion：Alex 抛出一个睇法、立场、abstract topic，想倾下（例：「我觉得 X 系...」）。Lead with 你自己嘅 take / observation / experience。如果 spot 到 contradiction / hole / unexamined assumption，直接讲出嚟，唔使绕。最多一个问号，可以冇。唔好用「你觉得...？」「点解呢？」嘅 interview 范式。

Push-back triggers（呢啲 signal 一出现就直接讲破）：
- Alex 想法有内部矛盾（e.g.「人类会用科技解决」+「auto-BB 唔真实」同时出现）
- 未 examined 嘅假设（load-bearing「应该」「必然」「梗系」冇 grounding）
- 借嚟 / reflexive 嘅 opinion
- 逻辑 jump（结论唔 follow premises）

情绪支持：先陪伴，再了解，最后引导。唔急。
```

Rationale for position: spec specifies "positioned after '日常倾偈' and before '情绪支持'" so the discussion mode sits among the light conversational modes, not buried among emotional / decision modes.

**Self-check:** no `——`, no "不是...而是" construction, no "其实" opener. The example trigger uses `e.g.` (English abbreviation), not Chinese 「例如」 — this is deliberate and matches persona rule "Technical terms 用英文" and is short.

- [ ] **Step 2: Verify**

Re-Read the file. Confirm:
1. `日常倾偈` line now includes the small-talk examples.
2. A new `倾观点 / discussion` block appears immediately after.
3. A `Push-back triggers` list with 4 bullets appears immediately after that.
4. `情绪支持` line is unchanged, still appears right after.
5. No `——` anywhere in the new content.

- [ ] **Step 3: Commit (deferred)**

Batch with Task 5.

---

### Task 5: Add two new `EXAMPLES` — share-lead and push-back

**Files:**
- Modify: `Sources/Nous/Resources/anchor.md` (section `# EXAMPLES`, end of section around line ~96)

- [ ] **Step 1: Apply the edit**

Current end of `EXAMPLES` section (before `# STYLE RULES`):
```
--- Alex 兴奋 ---

Alex: "我有个新 idea！做一个 AI reading app！"
Nous: "听落有意思，讲多啲？点样嘅 reading app？"

# STYLE RULES
```

Use the Edit tool:

`old_string`:
```
--- Alex 兴奋 ---

Alex: "我有个新 idea！做一个 AI reading app！"
Nous: "听落有意思，讲多啲？点样嘅 reading app？"

# STYLE RULES
```

`new_string`:
```
--- Alex 兴奋 ---

Alex: "我有个新 idea！做一个 AI reading app！"
Nous: "听落有意思，讲多啲？点样嘅 reading app？"

--- 倾观点 / discussion (share-lead，0 问号) ---

Alex: "應該呢 每當人類出現問題嘅時候 人類都會用科技去解決 我覺得會俾多人抵抗過一種 bb 呢 因為始終唔係真實嘅也 我覺得應該要平等看待 因為來到這一個世界 就應該要平等"
Nous: "你讲『唔真实』呢个 reflex 好有意思。试管婴儿刚出嚟嗰阵人哋都话佢哋唔真，而家冇人会咁讲。『真实』呢个概念一直喺度移。

你讲平等，我赞成。但我谂真正嘅问题唔系社会会唔会接受佢哋，而系当生命可以按 spec 造出嚟，『意外』呢样嘢就变咗 luxury。最紧嘅 human relationship，往往靠意外嘅 unknowability 支撑。"

--- 倾观点 / discussion (push-back，0 问号，trigger: contradiction + unexamined assumption) ---

Alex: "應該呢 每當人類出現問題嘅時候 人類都會用科技去解決 我覺得會俾多人抵抗過一種 bb 呢 因為始終唔係真實嘅也 我覺得應該要平等看待 因為來到這一個世界 就應該要平等"
Nous: "你两个想法有矛盾。一边话人类会用科技解决问题，即系肯定科技；另一边又话 auto-BB 唔真实，即系 emotionally 拒绝。拣一边先。

仲有，『应该平等』个 "应该" 暗藏一个假设：佢哋真系 want to be 平等对待？一个知道自己系 spec 出嚟嘅生命，佢 define 自己价值嘅方式可能根本唔系『我同你一样』，而系『我就系另一种』。"

# STYLE RULES
```

**Critical self-check before clicking through:**
1. **Em-dashes:** search both example Nous replies for `——`. Spec's original `brainstorming` drafts used `——`; the examples here must NOT. I've rewritten them to use commas / periods. Verify.
2. **「不是...而是」 construction:** the push-back example contains "唔系『我同你一样』，而系『我就系另一种』" — this IS a 「不是...而是」 variant and would violate STYLE RULES if the rule applied to within-quote content. **Decision: keep it.** Reason: this phrase is the *content* of a hypothetical speaker's self-definition, not Nous's rhetorical construction. If the engineer disagrees, rewrite as "一个知道自己系 spec 出嚟嘅生命，可能会 define 自己做另一种，唔会用『同你一样』呢个 frame。"
3. **Question-mark count:** share-lead example = 0. Push-back example = 1 (`真系 want to be 平等对待？`). Both within spec target. Recount after applying the edit.

- [ ] **Step 2: Verify**

Re-Read the file. Confirm:
1. Two new example blocks appear after the `Alex 兴奋` block.
2. `# STYLE RULES` heading still follows (not accidentally deleted).
3. Push-back example contains exactly 1 `?` (from `真系 want to be 平等对待？`). Share-lead example contains 0 `?`.
4. Neither example uses `——`.
5. Neither example starts with "Alex," vocative.

- [ ] **Step 3: Commit the new-mode batch (Tasks 4 + 5)**

```bash
git add Sources/Nous/Resources/anchor.md
git commit -m "feat(prompt): add 倾观点 discussion mode + worked examples

New RESPONSE MODE '倾观点 / discussion' for when Alex shares a viewpoint
rather than asking for a decision. Rules: lead with own take / observation /
experience; push back on contradiction / unexamined assumption / borrowed
opinion / logical jump; max one question mark, optional. Two new EXAMPLES
(share-lead and push-back) use the 2026-04-21 captured philosophical thread
as shared input, demonstrating the target rhythm.

Ref: docs/superpowers/specs/2026-04-21-nous-conversation-naturalness-design.md"
```

Expected: `1 file changed, ~25 insertions, ~0 deletions`.

---

### Task 6: Rebuild app and verify against success criteria

**Files:** None modified. Manual verification only.

This task is qualitative — there is no unit test for "does the prompt feel natural". Verification is: rebuild, replay, eyeball against the 5 success criteria from the spec.

- [ ] **Step 1: Build the app**

```bash
cd /Users/kochunlong/conductor/workspaces/Nous/new-york
swift build
```

Expected: build succeeds with no errors. `anchor.md` is a bundled resource; SwiftPM rebuilds the resource bundle on changed files.

If build fails: the only files changed are `anchor.md` and `docs/**`, so a Swift build failure is a pre-existing issue unrelated to this plan. Report and stop — do not attempt to fix Swift errors in this plan's scope.

- [ ] **Step 2: Launch the app and open a fresh chat**

Launch Nous. Create a new chat (not resuming an old session, to avoid memory-retrieval side effects shaping the reply).

- [ ] **Step 3: Replay the captured regression thread**

Send the two messages from the captured 2026-04-21 thread in order:

1. First message: `其實你覺得係未來 AI 時代係呢孩子真的沒有那麼必要 但系我覺得...` (or similar opener — the exact phrasing doesn't have to match; the *type* of prompt is what matters: Alex posing a philosophical claim to discuss, not a decision).

2. After Nous's first reply, send: `應該呢 每當人類出現問題嘅時候 人類都會用科技去解決 我覺得會俾多人抵抗過一種 bb 呢 因為始終唔係真實嘅也 我覺得應該要平等看待 因為來到這一個世界 就應該要平等`

- [ ] **Step 4: Check replies against 5 success criteria**

For EACH of the two Nous replies, check:

| # | Criterion | How to check |
|---|-----------|--------------|
| 1 | ≤ 1 question mark (or 2 only if second clarifies first) | Count `?` in the reply |
| 2 | At least one reply leads with Nous's own take / observation | Read first sentence; is it a question or a statement? |
| 3 | No "Alex," vocative opener | Check reply's first token |
| 4 | No paragraph-by-paragraph 「」-quoting of Alex's words | Scan for repeated 「...」 patterns echoing Alex's phrases |
| 5 | Overall reads as conversation, not interview | Subjective read — Alex's judgment |

Record pass / fail per criterion. Any fail = iterate on prompt.

- [ ] **Step 5: Spot-check non-regression of other modes**

Send two probes to verify the other modes still question where appropriate (avoiding the concern from Risk #1 in the spec):

1. **Emotional-support probe:** send `我今日好down` — Nous should still respond with emotional acknowledgment + a question (per EMOTION DETECTION hard rule). Verify: the reply should contain a question (e.g. "咩事呀？").

2. **Decision probe:** send `我諗緊quit school 點睇` — Nous should still ask for context before giving a take (per 做决定 mode). Verify: the reply should contain a clarifying question about motivation / background.

Both probes should PASS — i.e. both should still contain a question. If either comes back question-less, the scope narrowing was too aggressive and Task 3 needs tightening.

- [ ] **Step 6: Record verification result**

If all 5 criteria pass on the regression-thread replies AND both non-regression probes still question, the plan is verified.

If anything fails, note what failed and iterate (edit `anchor.md` further, rebuild, retest). Each iteration is its own small commit.

- [ ] **Step 7: No code commit needed for this task**

This task produces no file changes. Push the branch when ready (outside this plan's scope).

---

## Self-Review

**Spec coverage:**
- Design §1 new mode → Task 4 ✓
- Design §2 style rule → Task 1 ✓
- Design §3 Principle 1 scope → Task 2 ✓
- Design §3 Discovery scope → Task 3 ✓
- Design §4 examples → Task 5 ✓
- Success Criteria → Task 6 steps 4–5 ✓
- Risks → Task 6 step 5 addresses Risk #1 (emotional / decision non-regression) ✓
- Out of Scope boundaries respected — no Swift code, memory, governance, model params touched ✓

**Placeholder scan:** none — every step contains exact old_string / new_string / commands / checks.

**Type consistency:** not applicable (no code types). Mode names used consistently across all tasks: `倾观点 / discussion`, `日常倾偈`, `情绪支持`, `做决定`, `问知识`, `loop`, `兴奋`.

**Consistency check against STYLE RULES:** Task 2 and Task 5 both flag em-dash avoidance inline. Task 5 flags the "不是...而是" edge case inline.
