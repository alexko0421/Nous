# Turn Steward Agent — Design

**Date:** 2026-04-27
**Status:** Draft for review
**Scope:** Per-turn management agent for chat orchestration, memory selection, quick-action routing, and interruption judgment
**Target branch:** `alexko0421/quick-action-agents`
**Builds on:** `QuickActionAgent` contracts, `TurnPlanner`, `ProvocationJudge`, `QuickActionMemoryPolicy`, and the chat-turn seam work from `2026-04-24-chat-turn-memory-seams-design.md`

## 1. Thesis

Nous does not need a single "ultimate autonomous agent."

Nous needs a thin **Turn Steward Agent** that sits before the main reply and decides how the turn should be handled:

```text
User turn
  -> Turn Steward Agent
  -> TurnPlanner builds the exact context
  -> Main LLM replies
```

The steward is not the thinker. The main model still thinks and speaks.

The steward is the manager of timing, context, and boundaries:

- Should this be ordinary chat, Direction, Brainstorm, Plan, or a quiet follow-up to an existing plan?
- Should this turn use full memory, lean memory, or only project context?
- Is this a moment to challenge Alex, or a moment to first understand him?
- Is there a project drift / open loop worth surfacing?
- Should the reply answer now, ask one question, or produce a structured artifact?

The product lift comes from making these decisions explicit before generation instead of forcing the main model to infer them while also writing the answer.

## 2. Why This Exists

Current turn flow already has strong pieces:

- `QuickActionAgent` gives Direction / Brainstorm / Plan separate contracts.
- `QuickActionMemoryPolicy` can include or strip memory layers per mode.
- `ProvocationJudge` can decide whether to surface a remembered tension.
- `TurnPlanner` assembles stable + volatile prompt context.

The gap is that these decisions are still scattered:

- Quick actions are explicit only when Alex taps a chip.
- Memory policy is owned by the active quick-action mode, or defaults to `.full`.
- Provocation happens as a judge inside `TurnPlanner`, but it is not the same thing as turn routing.
- Project drift / open loops are not first-class steering signals.

The steward centralizes the "what kind of turn is this?" decision while keeping execution in existing services.

## 3. Product Standard

The steward is useful only if Alex feels Nous becomes calmer and more accurate.

It fails if Nous becomes:

- more verbose
- more intrusive
- more likely to ask meta-questions
- more likely to force every conversation into a mode
- another inbox that manufactures work

Pain test:

> 冇呢样嘢，会痛唔痛？

Yes, because without a steward, Nous will keep mixing incompatible behaviors in the same reply: retrieve too much memory while brainstorming, challenge when Alex is venting, give soft chat when Alex needed a plan, or miss project drift until Alex notices manually.

But the answer is a small steward, not a god agent.

## 4. Goals

- Improve answer precision by deciding turn shape before the main LLM call.
- Reduce context noise by selecting an explicit memory policy per turn.
- Reuse existing specialist agents instead of replacing them.
- Make implicit route decisions inspectable through governance traces.
- Add a path for project-drift / open-loop surfacing without turning Nous into a notification app.
- Keep failure mode silent and safe: if stewardship fails, fall back to today's normal chat behavior.

## 5. Non-Goals

- No long-running autonomous background loop in v1.
- No automatic edits to notes, plans, projects, memories, or `anchor.md`.
- No new ORM, SwiftData, Core Data, or third-party dependency.
- No replacement of `ProvocationJudge`; the steward may call or consume it, but it does not subsume contradiction judgment.
- No multi-agent tool runtime.
- No user-visible "agent dashboard" in v1.
- No hidden chain-of-thought persistence.
- No proactive notifications outside the current chat window in v1.

## 6. Naming

Recommended code name: `TurnSteward`.

Rejected names:

| Name | Why rejected |
|---|---|
| `UltimateAgent` | Encourages overreach and vague ownership. |
| `ManagerAgent` | Accurate but too broad; sounds like it owns everything. |
| `OrchestratorAgent` | Close, but this codebase already uses orchestration for turn execution. |
| `BackgroundAgent` | Implies long-running autonomy, which is out of v1. |

`TurnSteward` is boring in the right way: it stewards one turn.

## 7. Steward Output Contract

The steward returns a small structured decision, not prose.

```swift
struct TurnStewardDecision: Equatable, Codable {
    let route: TurnRoute
    let memoryPolicy: TurnMemoryPolicyPreset
    let challengeStance: ChallengeStance
    let responseShape: ResponseShape
    let projectSignal: ProjectSignal?
    let reason: String
}

enum TurnRoute: String, Codable {
    case ordinaryChat
    case direction
    case brainstorm
    case plan
}

enum TurnMemoryPolicyPreset: String, Codable {
    case full
    case lean
    case projectOnly
    case conversationOnly
}

enum ChallengeStance: String, Codable {
    case supportFirst
    case useSilently
    case surfaceTension
}

enum ResponseShape: String, Codable {
    case answerNow
    case askOneQuestion
    case producePlan
    case listDirections
    case narrowNextStep
}

struct ProjectSignal: Equatable, Codable {
    let kind: ProjectSignalKind
    let summary: String
}

enum ProjectSignalKind: String, Codable {
    case openLoop
    case directionDrift
    case repeatedStall
    case planNotFollowed
}
```

The exact enum names can shift during implementation, but the principle should not: the steward emits a bounded decision object.

## 8. Decision Meaning

### 8.1 `route`

`route` decides the turn posture.

| Route | Meaning |
|---|---|
| `ordinaryChat` | Default. No specialist mode. |
| `direction` | Convergent. Surface real paths, then narrow to one concrete next step. |
| `brainstorm` | Divergent. Generate distinct directions without overfitting to memory. |
| `plan` | Structured artifact. Outcome, schedule, stall points, today's first step. |

In v1, `route` should mostly respect explicit user intent. It should not aggressively infer modes from vague text.

Examples:

- "帮我 brainstorm 一下" -> `brainstorm`
- "我下一步应该点做" -> `direction`
- "帮我排一个 plan" -> `plan`
- "我好攰" -> `ordinaryChat`, `supportFirst`

### 8.2 `memoryPolicy`

This extends `QuickActionMemoryPolicy` from mode-specific to turn-specific.

| Preset | Use when |
|---|---|
| `full` | Direction, Plan, project decisions, contradiction-aware replies. |
| `lean` | Brainstorming, fresh naming, creative generation, "don't bias me" turns. |
| `projectOnly` | Active project matters, but global/user memory would over-bias. |
| `conversationOnly` | User is resolving the current thread; old memory would distract. |

Implementation can initially map these presets onto `QuickActionMemoryPolicy` plus a small new factory.

### 8.3 `challengeStance`

This does not replace `ProvocationJudge`; it gates how much space challenge is allowed to take.

| Stance | Meaning |
|---|---|
| `supportFirst` | No hard challenge in the opening move. Understand or steady Alex first. |
| `useSilently` | Memory can inform the answer, but do not explicitly call out tension. |
| `surfaceTension` | If the judge finds a strong citable tension, the main reply may name it. |

`ProvocationJudge` remains the source of citable contradiction facts. Steward decides whether this is a turn where provocation is welcome enough to run or apply strongly.

### 8.4 `responseShape`

This is a lightweight instruction to the main model.

It prevents the model from defaulting to generic chat when the product expectation is clear.

Examples:

- `producePlan` adds the Plan scaffold.
- `listDirections` allows Brainstorm-style bullets.
- `narrowNextStep` reinforces Direction's convergent contract.
- `askOneQuestion` forces a single question when the steward detects a missing blocker.

### 8.5 `projectSignal`

This is the first bridge toward a future background reflection agent.

In v1, `projectSignal` only appears inside the current reply context. It does not trigger notifications or background messages.

Example prompt block:

```text
PROJECT SIGNAL:
Possible direction drift: Alex's last three turns moved from "ship the onboarding flow" to "rewrite the whole memory system."
Surface only if directly helpful. Do not moralize. Do not turn it into a task list.
```

## 9. Placement In The Architecture

Recommended placement:

```text
ChatViewModel
  -> ChatTurnRunner
  -> ConversationSessionStore.prepare(...)
  -> TurnSteward.steer(...)
  -> TurnPlanner.plan(..., stewardshipDecision)
  -> TurnExecutor.execute(...)
```

`TurnSteward` should run after the user message is persisted into the prepared turn, because it needs the current message plus recent transcript.

It should run before `TurnPlanner` assembles memory layers, because its most important output is memory policy.

### 9.1 Why not inside `LLMService`

`LLMService` is provider transport. It should not know about memory, projects, modes, or telemetry.

### 9.2 Why not inside `QuickActionAgent`

Quick-action agents are specialists. They should not decide whether they should be invoked.

### 9.3 Why not inside `ProvocationJudge`

Provocation is one dimension. Turn route is broader: plan vs brainstorm vs ordinary support vs project drift.

## 10. v1 Flow

```text
1. User sends message.
2. ConversationSessionStore persists user message and returns PreparedTurnSession.
3. TurnSteward receives:
   - current user message
   - last N transcript messages
   - active project goal
   - active quick-action mode, if any
   - lightweight project/open-loop hints
   - current provider capability
4. TurnSteward returns TurnStewardDecision.
5. TurnPlanner maps the decision to:
   - effective quick-action agent / addendum
   - memory policy
   - whether to run judge focus
   - response-shape volatile context
   - optional project-signal block
6. Main LLM answers through existing TurnExecutor.
7. Prompt governance trace stores the steward decision.
```

If the steward fails, times out, or returns invalid JSON:

```text
route = activeQuickActionMode if present, otherwise ordinaryChat
memoryPolicy = active quick-action agent policy if present, otherwise full
challengeStance = useSilently
responseShape = answerNow
projectSignal = nil
```

## 11. Steward Implementation Strategy

Do not start with a large model call on every turn.

Use a three-layer decision stack:

### Layer 1 — deterministic rules

Rules handle obvious cases without latency:

- Explicit active quick-action mode wins.
- Explicit keywords can set route:
  - "brainstorm", "諗 idea", "发散" -> `brainstorm`
  - "plan", "schedule", "排" -> `plan`
  - "下一步", "direction", "点拣" -> `direction`
- Emotional distress words bias `challengeStance = supportFirst`.
- "don't use memory", "fresh", "唔好参考以前" -> `memoryPolicy = lean`.

If confidence is high, skip LLM steering.

### Layer 2 — small steering judge

Only run an LLM steering call when rules are not enough.

The steering judge returns strict JSON matching `TurnStewardDecision`.

Hard timeout: 700ms. If it misses, fall back.

The prompt must say:

- choose the least powerful route that can help
- do not force a mode unless the user intent is clear
- prefer silence over unnecessary project signals
- never recommend background notifications
- reason must be one short sentence for audit only

### Layer 3 — main LLM

The main LLM receives the steward's decision as context. It does not see the full steering deliberation.

## 12. Interaction With Existing QuickActionAgent

Existing `DirectionAgent`, `BrainstormAgent`, and `PlanAgent` stay.

The steward can set `route`, but the route should map to the same specialist contracts:

```swift
switch decision.route {
case .direction:
    agent = DirectionAgent()
case .brainstorm:
    agent = BrainstormAgent()
case .plan:
    agent = PlanAgent()
case .ordinaryChat:
    agent = nil
}
```

Key design choice:

- Explicit chip mode remains stronger than steward inference.
- Steward-inferred route should be one-turn unless the specialist agent explicitly keeps it active.

This prevents the app from trapping Alex in an inferred mode he did not ask for.

## 13. Interaction With ProvocationJudge

Current `ProvocationJudge` runs when the memory policy includes judge focus.

With stewardship:

```text
decision.challengeStance == supportFirst
  -> skip judge focus

decision.challengeStance == useSilently
  -> judge may run for telemetry / profile, but focus block should not force explicit challenge

decision.challengeStance == surfaceTension
  -> judge runs if provider allows; valid tension may become focus block
```

For v1, keep it simpler:

- `supportFirst` disables judge focus.
- `useSilently` and `surfaceTension` both allow current judge path.
- `surfaceTension` adds one extra volatile sentence telling the main model it may name a strong tension.

Do not redesign `JudgeVerdict` in v1.

## 14. Interaction With Memory Policy

Current `QuickActionMemoryPolicy` has `.full` and `.lean`.

Add a small factory:

```swift
extension QuickActionMemoryPolicy {
    static func fromStewardPreset(_ preset: TurnMemoryPolicyPreset) -> QuickActionMemoryPolicy {
        switch preset {
        case .full:
            return .full
        case .lean:
            return .lean
        case .projectOnly:
            return QuickActionMemoryPolicy(
                includeGlobalMemory: false,
                includeEssentialStory: false,
                includeUserModel: false,
                includeMemoryEvidence: false,
                includeProjectMemory: true,
                includeConversationMemory: false,
                includeRecentConversations: false,
                includeProjectGoal: true,
                includeCitations: false,
                includeContradictionRecall: false,
                includeJudgeFocus: false,
                includeBehaviorProfile: true
            )
        case .conversationOnly:
            return QuickActionMemoryPolicy(
                includeGlobalMemory: false,
                includeEssentialStory: false,
                includeUserModel: false,
                includeMemoryEvidence: false,
                includeProjectMemory: false,
                includeConversationMemory: true,
                includeRecentConversations: false,
                includeProjectGoal: false,
                includeCitations: false,
                includeContradictionRecall: false,
                includeJudgeFocus: false,
                includeBehaviorProfile: true
            )
        }
    }
}
```

This may be refined during implementation, but v1 should keep the preset count small.

## 15. Governance Trace

Add stewardship fields to `PromptGovernanceTrace` or a sibling trace:

```swift
struct TurnStewardTrace: Codable, Equatable {
    let route: TurnRoute
    let memoryPolicy: TurnMemoryPolicyPreset
    let challengeStance: ChallengeStance
    let responseShape: ResponseShape
    let projectSignalKind: ProjectSignalKind?
    let source: TurnStewardSource
    let reason: String
}

enum TurnStewardSource: String, Codable {
    case deterministic
    case llm
    case fallback
}
```

This is not user-facing in v1. It is for debugging and tuning.

The trace matters because "manager agent got it wrong" must be inspectable. Without this, failures look like vague model weirdness.

## 16. Testing Strategy

### Deterministic unit tests

| Test | Assert |
|---|---|
| Explicit Brainstorm route | "brainstorm" style input returns `.brainstorm`, `.lean`, `.listDirections`. |
| Explicit Plan route | "make me a schedule / plan" returns `.plan`, `.full`, `.producePlan`. |
| Emotional support | distress input returns `.ordinaryChat`, `.supportFirst`, no project signal. |
| Memory opt-out | "fresh / don't use memory" returns `.lean`. |
| Active quick action wins | existing `.plan` active mode cannot be overridden to `.brainstorm` by ambiguous wording. |
| LLM timeout fallback | steward timeout returns safe default and main turn still proceeds. |
| Invalid JSON fallback | malformed steering output never blocks the reply. |
| Trace persistence | trace records route, policy, stance, source, and reason. |

### Integration tests

| Test | Assert |
|---|---|
| Brainstorm policy applied | steward-inferred brainstorm strips memory layers in `TurnPlanner`. |
| Plan scaffold applied | steward-inferred plan injects PlanAgent production addendum. |
| Support-first skips judge | emotional support turn does not call provocation judge. |
| Project signal block | synthetic open-loop signal appears in volatile context only when decision includes it. |
| Fallback parity | disabled steward produces same prompt layers as current baseline. |

### Manual live tests

1. "我想 brainstorm 一个新方向，唔好参考之前我讲过嘅嘢" -> fresh divergent answer, no old-memory smell.
2. "我而家好攰，感觉顶唔顺" -> no challenge in opening move.
3. "帮我 plan 下今个星期点 ship onboarding" -> structured plan, not coaching prose.
4. "我下一步应该点拣" -> Direction-style narrowing.
5. After several project-drift turns, ask a related question -> one quiet drift signal at most.

## 17. Migration Plan

### Phase A — Pure deterministic steward

- Add `TurnStewardDecision` models.
- Add `TurnSteward` service with deterministic rules only.
- Add trace output.
- Wire `TurnPlanner` to accept an optional stewardship decision.
- No LLM steering call yet.

This phase should be behaviorally conservative but proves the seam.

### Phase B — LLM steering for ambiguous turns

- Add `TurnSteeringJudge` or `LLMTurnSteward`.
- Strict JSON parser + timeout.
- Use only when deterministic rules return low confidence.
- Add fallback telemetry.

### Phase C — Project signals

- Add a lightweight `ProjectSignalDetector`.
- Start with deterministic signals:
  - unresolved plan first step
  - repeated same user phrasing across recent turns
  - active project goal mismatch
- Surface only inside current reply context.

### Phase D — Future background reflection

Only after v1 proves useful.

This is where a true long-running or scheduled reflection agent may exist, but it should emit candidate `ProjectSignal`s into a queue for review, not speak directly.

## 18. Failure Modes

| Failure | Bad outcome | Guardrail |
|---|---|---|
| Over-routing | Ordinary chats become forced modes. | Deterministic confidence threshold; ordinary chat default. |
| Over-memory | Brainstorm becomes biased by old preferences. | `.lean` route test and prompt governance trace. |
| Under-memory | Direction / Plan lose Alex context. | Explicit full policy for those routes. |
| Over-challenge | Nous challenges while Alex is venting. | `supportFirst` disables judge focus. |
| Meta chatter | Model explains mode / route to Alex. | Steward decision hidden; main prompt forbids mentioning internal route. |
| Latency | Extra call slows every reply. | Rules first; LLM steering only on ambiguity; 700ms timeout. |
| Project-signal noise | Nous nags about open loops. | Project signal optional, current-turn only, no notifications. |

## 19. Open Questions

1. Should steward-inferred `plan` persist active quick-action mode across turns, or be one-shot unless Alex tapped Plan?
2. Should `projectOnly` include `userModel`, or does that leak too much global bias?
3. Should `useSilently` still run `ProvocationJudge` for telemetry, or skip it to save latency?
4. Where should stewardship trace live: inside `PromptGovernanceTrace`, or a separate `TurnStewardTrace` field on `TurnPlan`?
5. What is the minimum project-signal detector that creates real pain relief without becoming noisy?

## 20. Recommendation

Build Phase A first.

Do not start with autonomous background loops or an LLM steering call.

The first useful slice is:

- deterministic `TurnSteward`
- explicit `TurnStewardDecision`
- memory-policy mapping
- route mapping into existing `QuickActionAgent`
- trace logging
- focused tests proving Brainstorm runs lean, Plan gets structure, support turns skip challenge

If that slice improves answer precision without making Nous louder, then add LLM steering for ambiguous turns.

The deeper background agent should wait until the foreground steward has proven its judgment.
