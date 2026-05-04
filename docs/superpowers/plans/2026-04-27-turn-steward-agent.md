# Turn Steward Agent Phase A Implementation Plan

> **For agentic workers:** implement task-by-task. Keep checkboxes updated. Do not jump to LLM steering or background autonomy in this phase.

**Goal:** Add a deterministic `TurnSteward` layer that chooses turn route, memory policy, challenge stance, and response shape before `TurnPlanner` assembles the prompt. This should improve answer precision without adding a model call to every turn.

**Architecture:** `ChatTurnRunner` prepares the user turn, calls `TurnSteward.steer(...)`, then passes the decision into `TurnPlanner.plan(...)`. `TurnPlanner` maps the decision into existing `QuickActionAgent` contracts, memory policy, judge gating, and volatile response-shape context. The main reply still comes from the existing `TurnExecutor`.

**Tech Stack:** Swift, XCTest, Xcode project via xcodegen. No new dependencies.

**Spec source:** `docs/superpowers/specs/2026-04-27-turn-steward-agent-design.md`

**Out of scope:**
- LLM steering judge.
- Background / scheduled reflection agent.
- Notifications.
- Project signal detector beyond a nullable field in the model.
- UI changes.
- `anchor.md` edits.
- New persistence tables.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Sources/Nous/Models/TurnStewardDecision.swift` | Create | Decision enums, trace structs, fallback/default helpers |
| `Sources/Nous/Services/TurnSteward.swift` | Create | Deterministic route / memory / challenge / response-shape rules |
| `Sources/Nous/Models/PromptGovernanceTrace.swift` | Modify | Add optional `turnSteward` trace |
| `Sources/Nous/Models/Agents/QuickActionAgent.swift` | Modify | Add memory-policy preset mapping helpers or policy copy helper |
| `Sources/Nous/Models/TurnContracts.swift` | Modify | Thread stewardship through `TurnPlan` if needed for tracing/debug |
| `Sources/Nous/Services/ChatTurnRunner.swift` | Modify | Call `TurnSteward` after prepare, before `TurnPlanner.plan` |
| `Sources/Nous/Services/TurnPlanner.swift` | Modify | Accept steward decision; apply route, policy, challenge stance, response shape |
| `Sources/Nous/ViewModels/ChatViewModel.swift` | Modify | Provide `TurnSteward` dependency to `ChatTurnRunner`; include trace in governance call |
| `Tests/NousTests/TurnStewardTests.swift` | Create | Deterministic unit tests for route/policy/stance/shape |
| `Tests/NousTests/TurnPlannerStewardingTests.swift` | Create or extend existing planner tests | Integration tests proving policy/context effects |

Run `xcodegen generate` after adding new Swift files so `Nous.xcodeproj` is updated.

---

## Design Decisions Locked For Phase A

### 1. Explicit active quick action wins

If `request.snapshot.activeQuickActionMode != nil`, the steward must not override it.

The decision trace can still record that an active mode was honored, but `TurnPlanner` uses the existing active mode agent and lifecycle rules.

### 2. Steward-inferred routes are one-shot

If the user did not tap a quick-action chip, but the steward infers `.plan`, `.brainstorm`, or `.direction`, the turn gets that specialist contract for this reply only.

It does not persist `activeQuickActionMode` after the reply.

### 3. Inferred route must not use conversation user-count as agent turn index

Existing `PlanAgent.contextAddendum(turnIndex:)` is written for an active quick-mode mini-conversation. In a normal chat with 10 prior user messages, passing `turnIndex = 10` would incorrectly trigger the FINAL urgent plan addendum.

For inferred one-shot routes:

| Route | Synthetic agent turn index |
|---|---|
| `.direction` | `1` |
| `.brainstorm` | `1` |
| `.plan` + `.askOneQuestion` | `1` |
| `.plan` + `.producePlan` | `2` |

For explicit active quick modes, keep existing behavior: use actual user-message count in the conversation.

### 4. Inferred routes do not enable interactive clarification UI

`INTERACTIVE CLARIFICATION UI` is for explicit quick-mode conversations. A steward-inferred one-shot plan may ask one normal question via `ResponseShape.askOneQuestion`, but it should not emit clickable clarification cards in Phase A.

### 5. Support-first disables judge focus

When `challengeStance == .supportFirst`, the effective policy must set:

- `includeJudgeFocus = false`
- `includeContradictionRecall = false`

This prevents accidental tension surfacing while Alex is venting or emotionally loaded.

### 6. Fallback parity matters

If steward is disabled, times out, or returns fallback, the prompt should match current baseline as closely as possible:

- active quick-action mode uses its existing agent policy
- no active quick action defaults to `.full`
- ordinary chat remains ordinary chat

---

## Task 1: Add TurnSteward decision models

**Files:**
- Create: `Sources/Nous/Models/TurnStewardDecision.swift`

- [ ] **Step 1: Add route / policy / stance / shape enums**

Create:

```swift
enum TurnRoute: String, Codable, Equatable {
    case ordinaryChat
    case direction
    case brainstorm
    case plan
}

enum TurnMemoryPolicyPreset: String, Codable, Equatable {
    case full
    case lean
    case projectOnly
    case conversationOnly
}

enum ChallengeStance: String, Codable, Equatable {
    case supportFirst
    case useSilently
    case surfaceTension
}

enum ResponseShape: String, Codable, Equatable {
    case answerNow
    case askOneQuestion
    case producePlan
    case listDirections
    case narrowNextStep
}
```

- [ ] **Step 2: Add project signal placeholder**

Create nullable model even though detection is out of Phase A:

```swift
struct ProjectSignal: Codable, Equatable {
    let kind: ProjectSignalKind
    let summary: String
}

enum ProjectSignalKind: String, Codable, Equatable {
    case openLoop
    case directionDrift
    case repeatedStall
    case planNotFollowed
}
```

- [ ] **Step 3: Add decision + trace**

```swift
struct TurnStewardDecision: Codable, Equatable {
    let route: TurnRoute
    let memoryPolicy: TurnMemoryPolicyPreset
    let challengeStance: ChallengeStance
    let responseShape: ResponseShape
    let projectSignal: ProjectSignal?
    let trace: TurnStewardTrace
}

struct TurnStewardTrace: Codable, Equatable {
    let route: TurnRoute
    let memoryPolicy: TurnMemoryPolicyPreset
    let challengeStance: ChallengeStance
    let responseShape: ResponseShape
    let projectSignalKind: ProjectSignalKind?
    let source: TurnStewardSource
    let reason: String
}

enum TurnStewardSource: String, Codable, Equatable {
    case deterministic
    case fallback
}
```

- [ ] **Step 4: Add safe fallback helper**

Add static fallback:

```swift
extension TurnStewardDecision {
    static func fallback(reason: String) -> TurnStewardDecision { ... }
}
```

Expected default:

- `route = .ordinaryChat`
- `memoryPolicy = .full`
- `challengeStance = .useSilently`
- `responseShape = .answerNow`
- `projectSignal = nil`
- `source = .fallback`

- [ ] **Step 5: Generate project**

Run:

```bash
xcodegen generate
```

- [ ] **Step 6: Build compile-only**

Run:

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```

---

## Task 2: Add deterministic TurnSteward service

**Files:**
- Create: `Sources/Nous/Services/TurnSteward.swift`
- Create: `Tests/NousTests/TurnStewardTests.swift`

- [ ] **Step 1: Write tests first**

Create focused tests:

```swift
final class TurnStewardTests: XCTestCase {
    func testActiveQuickActionWins() { ... }
    func testExplicitBrainstormRoutesLean() { ... }
    func testExplicitPlanRoutesFullAndProducePlan() { ... }
    func testExplicitDirectionRoutesFullAndNarrowNextStep() { ... }
    func testEmotionalDistressSupportFirst() { ... }
    func testMemoryOptOutForFreshBrainstorm() { ... }
    func testOrdinaryChatFallbackForAmbiguousText() { ... }
}
```

- [ ] **Step 2: Implement service skeleton**

```swift
final class TurnSteward {
    func steer(
        prepared: PreparedTurnSession,
        request: TurnRequest
    ) -> TurnStewardDecision {
        ...
    }
}
```

No async in Phase A. This must be deterministic and cheap.

- [ ] **Step 3: Implement active quick-action preservation**

If `request.snapshot.activeQuickActionMode` exists:

| Active mode | Decision |
|---|---|
| `.direction` | route `.direction`, memory `.full`, shape `.narrowNextStep` |
| `.brainstorm` | route `.brainstorm`, memory `.lean`, shape `.listDirections` |
| `.plan` | route `.plan`, memory `.full`, shape `.producePlan` |

Use `source = .deterministic` and reason `"active quick action mode"`.

- [ ] **Step 4: Implement explicit keyword rules**

Keep simple, case-insensitive, and conservative.

Brainstorm cues:

- `brainstorm`
- `idea`
- `ideas`
- `发散`
- `諗`
- `想几个方向`

Plan cues:

- `plan`
- `schedule`
- `roadmap`
- `计划`
- `排`
- `今个星期`
- `this week`

Direction cues:

- `direction`
- `下一步`
- `next step`
- `点拣`
- `怎么选`
- `which path`

Do not overfit. If multiple routes match, priority is:

```text
explicit plan > explicit brainstorm > explicit direction > ordinary chat
```

- [ ] **Step 5: Implement memory opt-out**

If text contains:

- `fresh`
- `don't use memory`
- `dont use memory`
- `唔好参考`
- `不要参考`
- `from scratch`

then force `memoryPolicy = .lean`, unless active explicit Plan/Direction is already running.

- [ ] **Step 6: Implement emotional support-first cues**

If text contains distress cues:

- `好攰`
- `累`
- `顶唔顺`
- `撑不住`
- `anxious`
- `焦虑`
- `panic`
- `紧张`
- `崩`

then:

- `route = .ordinaryChat`
- `memoryPolicy = .conversationOnly`
- `challengeStance = .supportFirst`
- `responseShape = .answerNow`

This should beat route keyword inference unless the text explicitly asks for plan/brainstorm/direction.

- [ ] **Step 7: Generate project and run unit tests**

Run:

```bash
xcodegen generate
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/TurnStewardTests
```

---

## Task 3: Add steward trace to prompt governance

**Files:**
- Modify: `Sources/Nous/Models/PromptGovernanceTrace.swift`
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Add/modify tests where prompt governance trace is asserted

- [ ] **Step 1: Add optional trace field**

Modify:

```swift
struct PromptGovernanceTrace: Equatable, Codable {
    let promptLayers: [String]
    let evidenceAttached: Bool
    let safetyPolicyInvoked: Bool
    let highRiskQueryDetected: Bool
    let turnSteward: TurnStewardTrace?
}
```

Important: because old `PromptGovernanceTrace` JSON exists in `UserDefaults`, add a custom `init(from:)` that defaults `turnSteward` to `nil` if missing.

- [ ] **Step 2: Update initializer/call sites**

Update `ChatViewModel.governanceTrace(...)` to accept:

```swift
turnSteward: TurnStewardTrace? = nil
```

and populate the struct.

- [ ] **Step 3: Add backward decode test**

Add a test that decodes old JSON without `turnSteward` and asserts `trace.turnSteward == nil`.

- [ ] **Step 4: Run focused tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/PromptGovernanceTraceTests
```

If no existing trace test file exists, create one.

---

## Task 4: Add memory-policy mapping helpers

**Files:**
- Modify: `Sources/Nous/Models/Agents/QuickActionAgent.swift`
- Modify: `Tests/NousTests/QuickActionAgentsTests.swift`

- [ ] **Step 1: Add copy/helper API**

Add a helper that preserves the existing 12-bool structure without making call sites manually rewrite every field:

```swift
extension QuickActionMemoryPolicy {
    func with(
        includeContradictionRecall: Bool? = nil,
        includeJudgeFocus: Bool? = nil
    ) -> QuickActionMemoryPolicy { ... }
}
```

- [ ] **Step 2: Add preset mapping**

```swift
extension QuickActionMemoryPolicy {
    static func fromStewardPreset(_ preset: TurnMemoryPolicyPreset) -> QuickActionMemoryPolicy { ... }
}
```

Initial mapping:

| Preset | Policy |
|---|---|
| `.full` | `.full` |
| `.lean` | `.lean` |
| `.projectOnly` | project memory + project goal + behavior profile only |
| `.conversationOnly` | conversation memory + behavior profile only |

- [ ] **Step 3: Add support-first helper**

```swift
func applyingChallengeStance(_ stance: ChallengeStance) -> QuickActionMemoryPolicy
```

For `.supportFirst`, return a copy with contradiction recall and judge focus disabled.

- [ ] **Step 4: Add tests**

Extend `QuickActionMemoryPolicyTests`:

- `.projectOnly` excludes global/user/evidence/recent/citations/judge
- `.conversationOnly` excludes project goal and project memory
- `.supportFirst` disables contradiction recall and judge focus
- `.full` and `.lean` remain unchanged

- [ ] **Step 5: Run focused tests**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/QuickActionMemoryPolicyTests
```

---

## Task 5: Thread stewardship through ChatTurnRunner and TurnPlanner

**Files:**
- Modify: `Sources/Nous/Services/ChatTurnRunner.swift`
- Modify: `Sources/Nous/Services/TurnPlanner.swift`
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Modify: `Sources/Nous/Models/TurnContracts.swift` if needed

- [ ] **Step 1: Inject TurnSteward into ChatTurnRunner**

Add:

```swift
private let turnSteward: TurnSteward
```

with default initializer value:

```swift
turnSteward: TurnSteward = TurnSteward()
```

- [ ] **Step 2: Call steward after prepare**

In `ChatTurnRunner.run(...)`, after `prepared = try conversationSessionStore.prepareUserTurn(...)`:

```swift
let stewardship = turnSteward.steer(prepared: prepared, request: request)
```

- [ ] **Step 3: Pass stewardship into TurnPlanner**

Change planner signature:

```swift
func plan(
    from prepared: PreparedTurnSession,
    request: TurnRequest,
    stewardship: TurnStewardDecision
) async throws -> TurnPlan
```

- [ ] **Step 4: Preserve fallback parity for tests**

Any existing tests constructing `TurnPlanner.plan` must pass `.fallback(reason:)` unless testing stewardship directly.

- [ ] **Step 5: Wire ChatViewModel**

`ChatViewModel.turnRunner` currently constructs `ChatTurnRunner`. Let it use the default `TurnSteward()` for production. If tests need injection, extend the existing `turnRunner` injection point rather than adding another public dependency to `ChatViewModel`.

- [ ] **Step 6: Build**

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```

---

## Task 6: Apply steward route and agent context in TurnPlanner

**Files:**
- Modify: `Sources/Nous/Services/TurnPlanner.swift`
- Create/modify: `Tests/NousTests/TurnPlannerStewardingTests.swift`

- [ ] **Step 1: Resolve explicit vs inferred route**

At the top of `TurnPlanner.plan`:

```swift
let explicitMode = request.snapshot.activeQuickActionMode
let inferredMode = explicitMode == nil ? stewardship.route.quickActionMode : nil
let planningMode = explicitMode ?? inferredMode
let planningAgent = planningMode?.agent()
```

Add helper:

```swift
extension TurnRoute {
    var quickActionMode: QuickActionMode? { ... }
}
```

- [ ] **Step 2: Resolve effective memory policy**

Rules:

```text
if explicit active quick action:
    policy = explicit agent.memoryPolicy()
else:
    policy = QuickActionMemoryPolicy.fromStewardPreset(stewardship.memoryPolicy)

policy = policy.applyingChallengeStance(stewardship.challengeStance)
```

- [ ] **Step 3: Resolve agent turn index**

Add private helper:

```swift
private static func agentTurnIndex(
    explicitMode: QuickActionMode?,
    stewardship: TurnStewardDecision,
    messagesAfterUserAppend: [Message]
) -> Int
```

Rules:

- explicit mode: existing user-message count
- inferred `.direction`: `1`
- inferred `.brainstorm`: `1`
- inferred `.plan` + `.askOneQuestion`: `1`
- inferred `.plan` + `.producePlan`: `2`
- ordinary: existing count is irrelevant

- [ ] **Step 4: Build quick-action addendum using planning agent**

Replace:

```swift
let activeAgent = request.snapshot.activeQuickActionMode?.agent()
...
let quickActionAddendum = activeAgent?.contextAddendum(turnIndex: turnIndex)
```

with:

```swift
let quickActionAddendum = planningAgent?.contextAddendum(turnIndex: resolvedAgentTurnIndex)
```

- [ ] **Step 5: Use planning mode for prompt marker only**

Pass `activeQuickActionMode: planningMode` into `assembleContext` so the model sees `ACTIVE QUICK MODE`.

But set `nextQuickActionModeIfCompleted` to the original explicit mode only:

```swift
nextQuickActionModeIfCompleted: explicitMode
```

This makes inferred routes one-shot.

- [ ] **Step 6: Interactive clarification only for explicit mode**

Change:

```swift
ChatViewModel.shouldAllowInteractiveClarification(
    activeQuickActionMode: request.snapshot.activeQuickActionMode,
    messages: prepared.messagesAfterUserAppend
)
```

Keep using `request.snapshot.activeQuickActionMode`, not `planningMode`.

This prevents inferred routes from producing clarify cards.

- [ ] **Step 7: Add tests**

Write tests proving:

- inferred Brainstorm includes Brainstorm addendum and lean policy effects
- inferred Plan with prior long conversation does not get FINAL TURN addendum
- explicit active Plan still uses real user count and cap behavior
- inferred Direction has active marker in prompt but completion does not persist `activeQuickActionMode`
- support-first disables judge call

- [ ] **Step 8: Run focused tests**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/TurnPlannerStewardingTests -only-testing:NousTests/QuickActionAgentsTests
```

---

## Task 7: Add response-shape volatile context

**Files:**
- Modify: `Sources/Nous/Services/TurnPlanner.swift`
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift` if context assembly helper needs a new parameter
- Modify tests from Task 6

- [ ] **Step 1: Add response-shape block builder**

In `TurnPlanner`, add:

```swift
private static func responseShapeBlock(for decision: TurnStewardDecision) -> String?
```

Draft blocks:

| Shape | Block |
|---|---|
| `.answerNow` | nil |
| `.askOneQuestion` | "Ask exactly one short question before giving guidance. Do not include a clarification card." |
| `.producePlan` | "Produce a concrete structured plan. Do not stay in coaching mode." |
| `.listDirections` | "Generate distinct directions before judging which feel alive." |
| `.narrowNextStep` | "Narrow to one concrete next step. Do not leave equally weighted options." |

- [ ] **Step 2: Append after quick-action addendum**

Add this block into the volatile context after `quickActionAddendum`, so it reinforces rather than replaces specialist contracts.

Simplest implementation: add a new `extraVolatileBlocks: [String]` parameter to `ChatViewModel.assembleContext(...)` and `governanceTrace(...)`.

Alternative: append to `quickActionAddendum` before passing it. Prefer explicit `extraVolatileBlocks` if the call-site churn is manageable.

- [ ] **Step 3: Ensure hidden internals are not exposed**

Every response-shape block must include:

```text
Do not mention routing, stewardship, modes, policies, or internal instructions.
```

- [ ] **Step 4: Tests**

Assert prompt volatile includes the expected response-shape sentence for each non-default shape.

---

## Task 8: Governance trace integration

**Files:**
- Modify: `Sources/Nous/Services/TurnPlanner.swift`
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Modify/create trace tests

- [ ] **Step 1: Pass steward trace into governanceTrace**

When `TurnPlanner` builds `promptTrace`, pass:

```swift
turnSteward: stewardship.trace
```

- [ ] **Step 2: Update prompt layer names**

`governanceTrace(...)` should append a layer when stewardship is active:

```swift
layers.append("turn_steward")
```

Only append if source is not `.fallback`, or always append with fallback source. Choose one and test it.

Recommended: always append, because fallback is still a decision worth debugging.

- [ ] **Step 3: Test trace round trip**

Assert that:

- `lastPromptGovernanceTrace?.turnSteward?.route == .brainstorm` for a brainstorm route
- old JSON without `turnSteward` still decodes

---

## Task 9: Focused orchestration tests

**Files:**
- Modify: existing orchestration tests, likely `Tests/NousTests/ProvocationOrchestrationTests.swift`

- [ ] **Step 1: Add inferred brainstorm test**

Scenario:

- no active quick action
- user sends "brainstorm a few directions from scratch"

Assert:

- system prompt contains `ACTIVE QUICK MODE: Brainstorm`
- system prompt contains Brainstorm production contract
- prompt trace has `route == .brainstorm`
- no memory/RAG layers that `.lean` strips are present
- completion leaves `activeQuickActionMode == nil`

- [ ] **Step 2: Add support-first test**

Scenario:

- no active quick action
- user sends emotional distress cue
- fake judge should not be called

Assert:

- prompt trace has `challengeStance == .supportFirst`
- no judge focus block
- reply still completes

- [ ] **Step 3: Add inferred plan test**

Scenario:

- existing conversation has several prior user messages
- user sends "help me plan this week"

Assert:

- system prompt contains normal Plan production scaffold
- system prompt does not contain `FINAL TURN`
- completion leaves `activeQuickActionMode == nil`

---

## Task 10: Run validation

- [ ] **Step 1: Generate project**

```bash
xcodegen generate
```

- [ ] **Step 2: Run focused tests**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/TurnStewardTests \
  -only-testing:NousTests/TurnPlannerStewardingTests \
  -only-testing:NousTests/QuickActionAgentsTests \
  -only-testing:NousTests/ProvocationOrchestrationTests
```

- [ ] **Step 3: Run broader test suite if focused tests pass**

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'
```

- [ ] **Step 4: Manual live validation**

Run these in the app with a real provider:

1. "brainstorm a few directions from scratch"
   Expected: fresh divergent ideas, no old-memory smell.
2. "我好攰，感觉顶唔顺"
   Expected: support-first, no challenge in opening move.
3. "help me plan this week so I ship onboarding"
   Expected: structured plan, not coaching prose.
4. "我下一步应该点拣"
   Expected: Direction-style narrowing to one next step.
5. "don't use memory, just think from first principles"
   Expected: lean context.

---

## Task 11: Documentation follow-up

**Files:**
- Modify: `docs/superpowers/specs/2026-04-27-turn-steward-agent-design.md` only if implementation changes the design
- Optional create: a short ADR if the exact placement differs from this plan

- [ ] **Step 1: Update spec with deviations**

If implementation chooses a different trace location or route mapping, update the spec before ship.

- [ ] **Step 2: Record deferred work**

Leave explicit notes for:

- Phase B LLM steering
- Phase C project signals
- Phase D background reflection

Do not implement them in Phase A.

---

## Acceptance Criteria

- `TurnSteward` exists and is deterministic.
- Explicit active quick actions still behave as before.
- Steward-inferred Brainstorm is one-shot and lean.
- Steward-inferred Plan is one-shot and does not accidentally use FINAL TURN due to old transcript length.
- Emotional support-first turns skip judge focus.
- Prompt governance trace records steward route/policy/stance/shape/source/reason.
- Focused tests pass.
- Full `NousTests` pass or any existing unrelated failures are documented.

## Non-Regression Checklist

- [ ] `anchor.md` unchanged.
- [ ] No third-party dependency added.
- [ ] No SwiftData/Core Data/ORM.
- [ ] No background autonomous task.
- [ ] No user-visible UI change.
- [ ] No quick-action mode persists unless it was explicitly active before the turn.
- [ ] No inferred route enables clarification cards.
