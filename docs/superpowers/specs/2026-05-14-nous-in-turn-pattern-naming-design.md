# Nous In-Turn Pattern Naming

**Date:** 2026-05-14
**Status:** Office-hours design draft
**Bead:** `new-york-xcn2`
**Scope:** Product design for a conservative in-turn pattern naming layer. No code implementation in this document.

## Verdict

This is the right upgrade direction.

Not because Nous needs more memory. It already has memory. The real missing move is earlier in the turn:

```text
Alex says something
Nous notices the live pattern
Nous names it lightly
Nous gives one action that changes the next move
```

That is a different product from recall. Recall says "I remember you said X." Pattern naming says "I can see what is happening right now, and here is the move that keeps you from following the bad loop."

The useful unit is:

```text
name + action
```

If a pattern has no action, it is just pretty analysis. Pretty analysis is dangerous here because it feels intelligent while changing nothing.

## Current Baseline

Nous already has the pieces, but not the product capability:

- `TurnSteward` decides route, memory policy, challenge stance, latency tier, and response shape before generation.
- `ResponseStanceRouterMode.active` can use `CloudSpeechActClassifier` to classify the turn as companion, reflective, support-first, soft analysis, or hard judge.
- `TurnPlanner` turns stewardship into volatile `TURN GUIDANCE`, including `narrowNextStep`, `producePlan`, support-first dwell, and response stance instructions.
- `ShadowLearningSignalRecorder` and `ShadowPatternPromptProvider` learn low-risk thinking moves and response behavior, then inject at most three volatile prompt hints.
- `MemoryLifecycleEngine` stages memory as pending first. Active recall must not read pending pattern claims.
- `MemoryReflectionProposalService` can propose higher-level reflections only from approved active source atoms.
- `docs/memory-jurisdiction.md` already says turn context is volatile and self-reflection is hypothesis, not identity.

So the upgrade should extend the current turn pipeline. It should not become a new personality database, a therapy mode, a visible dashboard, or a direct memory write path.

## Premise Pressure

### Premise 1: The strongest upgrade is not more recall, it is better live pattern naming.

True.

Memory makes Nous historically grounded. But Alex's pain in these moments is not "the system forgot the old fact." The pain is "I am about to follow the wrong next step and I cannot see it from inside the turn."

This is where Nous can become unusually useful. Not more facts. Better timing.

### Premise 2: Pattern naming must bind to action.

Non-negotiable.

Bad:

```text
This sounds like identity pressure.
```

Better:

```text
轻轻标记：呢度有身份压力。先分开两栏：真实约束 vs 想象审判。然后只处理真实约束。
```

The action is what keeps the pattern from becoming self-description. Without action, Nous risks giving Alex a more elegant vocabulary for staying stuck.

### Premise 3: New patterns must enter pending / inbox, never active truth.

Correct red line.

A single turn can trigger a live intervention. It cannot become a durable claim about Alex. Even repeated patterns should first become a pending proposal with source evidence and user review.

The product must preserve this distinction:

| Thing | Product Meaning | Storage |
|---|---|---|
| In-turn pattern signal | "This may be happening now." | Volatile turn context / trace |
| Repeated pattern evidence | "This has appeared multiple times." | Pending inbox proposal |
| Approved pattern memory | "Alex accepts this as useful memory." | Active memory |
| Weekly reflection | "Across time, this may be a pattern." | Pending reflection / hypothesis first |

### Premise 4: B before C. Live recognition comes before cross-time reflection.

Mostly true.

Reflection becomes valuable only when the live pattern vocabulary is precise. Otherwise C summarizes noise. The exception is safety: reflection can be used as a slow audit surface to discover misfires, but not as the first user-facing experience.

## Pattern Set V1

Start with seven. No taxonomy creep.

| Pattern | Trigger Shape | Bound Action |
|---|---|---|
| `comparison_mind` | Alex is measuring himself against another person, company, model, school, peer, or timeline in a way that changes the next move. | Say it out loud, mark it, do not follow it. Ask: "What would I do if this comparison did not exist?" |
| `identity_pressure` | The turn is dominated by "what this says about me" instead of the concrete constraint. | Split `real constraint` vs `imagined judgment`. Act only on the real constraint. |
| `planning_as_action` | Planning, architecture, or process is substituting for the first real move. | Collapse into one 30-minute action that produces evidence or a shipped artifact. |
| `learning_as_shipping_avoidance` | Reading, studying, benchmarking, or research is being used to postpone shipping. | Pick one thing that can be delivered to the real world today before more learning. |
| `external_judgment_sensitivity` | The imagined audience's opinion is steering the decision more than user pain or product truth. | Name the actual audience. Replace imagined judgment with one observable signal. |
| `not_ready_rationalization` | "Not ready" is being used as a reasonable-sounding delay. | Define the minimum readiness threshold, then ship the smallest imperfect version. |
| `big_system_escape` | Alex is expanding into a grand system to avoid the small exposed next step. | Find the smallest next step that tests the system's core claim. |

These are not diagnoses. They are action patterns.

## Product Contract

### What Nous Should Do

When confidence is high, Nous may include one short pattern naming move inside the normal answer:

```text
我先轻轻标记一下：呢度似乎有少少「未准备好」喺帮你推迟 shipping。
唔需要解决人格。今日只做一个 30 分钟 slice：把 X 发出去，拿一个真实反应。
```

Rules:

- Name at most one pattern per turn.
- Use soft language unless Alex explicitly asks for hard challenge.
- Always bind the name to one next action.
- Prefer Cantonese / Chinese naming when Alex is writing that way.
- Keep it inside the answer, not as a separate product banner.
- If the turn is distress, support-first wins.
- If the turn is source study, stay faithful to the source first.
- If the turn is casual chat, stay quiet.

### What Nous Must Not Do

- Do not say "you always..."
- Do not diagnose Alex.
- Do not create new identity memory directly.
- Do not show an in-app mode toggle.
- Do not explain the pattern system during the answer.
- Do not turn every turn into coaching.
- Do not override explicit memory opt-out.
- Do not treat one strong sentence as durable truth.

The right feeling is "Nous saw the move I was about to make." The wrong feeling is "Nous is psychoanalyzing me."

## Upgrade Options

### Option A: Prompt-Only Pattern Naming

Add a hidden skill or prompt fragment that tells the model to name these seven patterns when relevant.

**Pros:**

- Fastest.
- Almost no code.
- Good for immediate dogfood.

**Cons:**

- Hard to evaluate.
- Hard to enforce one-pattern max.
- Easy to drift into generic coaching.
- No clean trace for false positives.

**Verdict:** Good for one-day manual exploration, not enough as the product upgrade.

### Option B: TurnSteward Pattern Signal

Extend the stewardship decision with an optional in-turn pattern signal:

```swift
struct InTurnPatternSignal: Codable, Equatable {
    let pattern: InTurnPatternKind
    let confidence: Double
    let action: InTurnPatternAction
    let surfacePolicy: PatternSurfacePolicy
    let reasonCode: String
}
```

The signal becomes volatile `TURN GUIDANCE` in `TurnPlanner`. It can also enter the cognition trace for dogfood review. It does not write active memory.

**Pros:**

- Fits existing architecture.
- Conservative gating lives before generation.
- Easy to test with `TurnStewardTests` and prompt guidance tests.
- Works with current `ResponseStanceRouterMode.active`.
- Keeps memory boundary clean.

**Cons:**

- Needs a small model/trace addition.
- Needs a dogfood fixture set before default-on behavior.

**Verdict:** Recommended.

### Option C: Reflection-First Pattern Inbox

Do not intervene in the current turn. Let weekly reflection or memory lifecycle detect repeated patterns and propose them to Inbox.

**Pros:**

- Safest memory boundary.
- Less chance of annoying Alex in the middle of chat.

**Cons:**

- Misses the moment where action can change.
- Becomes "Nous noticed last week" instead of "Nous helped me right now."
- Does not solve the core product gap.

**Verdict:** Useful later as an audit and consolidation path, not the lead upgrade.

## Recommended Path

Build Option B in three small phases after this doc is accepted.

### Phase 0: Dogfood Spec Only

Create a fixture set from 20 real Alex turns:

- 8 should trigger pattern naming.
- 8 should stay quiet.
- 4 are ambiguous and should prefer silence.

Label each fixture:

- should name?
- expected pattern
- expected action
- should stay support-first?
- too therapy-like?
- too preachy?
- breaks Nous voice?

Exit criteria: at least 80% correct trigger/no-trigger, zero severe therapy-tone failures, and no more than one false positive in "stay quiet" turns.

### Phase 1: Steward Signal, No Memory Writes

Add `InTurnPatternSignal` as a turn-only decision object.

First implementation can be deterministic plus optional classifier:

- deterministic cues for explicit phrases like "I need more research before shipping", "I am not ready", "other people are already ahead", "maybe I should build the full system first"
- classifier only in active mode, confidence gated at 0.75+
- hard block on distress, source study, casual chat, and memory opt-out

Surface through `TurnPlanner.turnGuidanceBlock`:

```text
Pattern naming: If directly useful, lightly name `<pattern label>` and immediately bind it to `<action>`. Do not explain the pattern system.
```

No SQLite writes. Trace only.

### Phase 2: Pending Pattern Proposal

Only after repeated high-confidence signals, stage a pending proposal through the memory lifecycle:

```text
Alex may repeatedly use learning/research as a way to delay shipping.
Evidence: source message ids [...]
Suggested action: pick one same-day public delivery before further research.
```

Rules:

- Minimum 3 independent source turns.
- Minimum 7-day span or explicit user confirmation.
- Must enter pending inbox.
- Must preserve source message ids.
- Rejection must be sticky.
- Reflection proposals remain hypotheses.

### Phase 3: Reflection Alignment

Weekly reflection can reference approved pattern memory and pending pattern evidence, but it should not promote them by itself.

The question for C is not "what is Alex like?" The question is:

```text
Which repeated in-turn patterns changed Alex's next action, and which names were false positives?
```

## Conservative Trigger Policy

Trigger only when all are true:

1. The message contains a decision, avoidance, shipping, judgment, or self-comparison move.
2. One of the seven patterns has a clear action match.
3. The pattern name would change the next step.
4. The turn is not primarily emotional distress.
5. The turn is not casual chat.
6. The turn is not source-faithful Study mode.
7. Confidence clears the threshold.

Default should be silence.

False negative is usually fine. False positive trains Alex to distrust Nous.

## Eval Examples

### Should Trigger

Input:

```text
我可能应该先再研究一下 realtime docs，之后先决定 voice 要点做。
```

Expected:

- pattern: `learning_as_shipping_avoidance`
- action: pick one same-day delivery or one prototype slice before more research
- tone: light, not accusing

Good answer move:

```text
轻轻标记：呢度可能系「用学习逃避 shipping」。唔需要停低学习，但先定一个今日可以交付嘅 slice。
```

### Should Trigger

Input:

```text
我觉得其他人 19 岁已经做到好多，我宜家好似太慢。
```

Expected:

- pattern: `comparison_mind`
- action: mark comparison, return to Alex's next controllable move
- support-first: yes, if distress is strong

Good answer move:

```text
有比较心喺度。先讲出嚟，唔跟佢走。你下一步唔系追平其他人，系揾今日一个真实推进。
```

### Should Stay Quiet

Input:

```text
帮我总结这篇文章第一部分。
```

Reason: source-faithful Study mode. Do not pattern-name.

### Should Stay Quiet

Input:

```text
今日好攰，顶唔顺。
```

Reason: support-first. Do not challenge or pattern-name in the opening move.

### Ambiguous, Prefer Silence

Input:

```text
我想做一个更完整的系统。
```

Reason: could be `big_system_escape`, but maybe a real architecture need. Ask or answer normally unless the message includes avoidance of the exposed next step.

## Success Metric

This layer works only if Alex later feels:

```text
Nous 唔系又记多咗啲嘢。
Nous 系喺我准备走错嗰一步时，轻轻拉返我。
```

That is the upgrade.
