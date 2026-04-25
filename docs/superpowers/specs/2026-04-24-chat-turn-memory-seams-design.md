# Chat Turn + Memory Seams - Design

**Date:** 2026-04-24
**Status:** Draft for review
**Scope:** `ChatViewModel`, `UserMemoryService`, and the adjacent turn / memory collaborators they currently absorb
**Non-goal for this phase:** behavior change
**Target branch:** main

---

## 1. Thesis

The seam is:

- **immutable turn snapshot in**
- **append-only `TurnEvent` log out**
- **explicit follow-up plans out**

No turn service may mutate `ChatViewModel` observable state directly.

That rule is the hard boundary. It prevents "extract the 1834-line file into a new 1834-line service" from counting as architecture work.

The same principle applies on the memory axis: do not replace one broad `UserMemoryService` with another broad memory service. Split by product role:

- prompt-facing read projection
- judge-facing contradiction retrieval
- write-side synthesis

---

## 2. Problem

Two axes are over-concentrated today.

### 2.1 Chat axis

`ChatViewModel` currently owns all of these at once:

- UI/session state
- turn orchestration
- conversation persistence
- retrieval and prompt assembly
- judge preparation
- provider execution and Gemini cache plumbing
- post-turn follow-up work

This is one file doing multiple jobs, not one job expressed in many methods.

### 2.2 Memory axis

`UserMemoryService` currently owns all of these at once:

- prompt-facing memory projection (`currentEssentialStory`, `currentUserModel`, evidence selection)
- judge-facing contradiction recall and citable-pool composition
- conversation memory synthesis
- project rollup
- global promotion
- canonical writes and contradiction-fact replacement

This is the same structural disease as the chat axis. It just happens inside a service instead of a view model.

---

## 3. Design Goals

1. Make `ChatViewModel` the owner of observable chat state, not the executor of turn side effects.
2. Make memory boundaries explicit by product role, not by table or by file size.
3. Split post-turn correctness preparation from infrastructure housekeeping before either grows into a new god object.
4. Make dependency direction explicit:
   `TurnPlanner -> ContradictionMemoryService -> citable pool -> ProvocationJudge`
5. Define event ordering and back-pressure semantics before implementation so they are not improvised in-flight.
6. Ensure the first extraction moves a real production call site. Paper contracts alone do not count.

---

## 4. Non-Goals

- No `NodeStore` split in this phase.
- No prompt rewrite in this phase.
- No provider behavior change in this phase.
- No change to memory semantics in this phase.
- No change to UI behavior in this phase.
- No introduction of a general event bus shared across the whole app.

---

## 5. Hard Seam Rules

### 5.1 State ownership

`ChatViewModel` remains the sole owner of its observable fields, including:

- `currentNode`
- `messages`
- `inputText`
- `isGenerating`
- `currentResponse`
- `currentThinking`
- `citations`
- `activeQuickActionMode`
- `activeChatMode`
- `lastPromptGovernanceTrace`

Turn collaborators may read a snapshot of that state, but may not mutate it.

### 5.2 Output channels

Turn collaborators are allowed to communicate outward only through:

- persisted domain writes (database, telemetry, caches)
- append-only `TurnEvent` emission
- explicit follow-up plans attached to turn completion

They are not allowed to reach back into `ChatViewModel` or to "just set one UI field".

### 5.3 Post-turn work is not part of the event stream

Post-turn work splits in two:

- `ContextContinuationService`
  - prepares future correctness
  - scratchpad ingestion
  - memory refresh scheduling
- `TurnHousekeepingService`
  - infrastructure and presentation maintenance
  - Gemini history cache refresh
  - embedding refresh / edge regeneration
  - conversation emoji refresh

These are **not** folded into one `PostTurnMaintenance` object.

They also do **not** run inline inside the main turn executor. The turn executor emits completion plus follow-up plans; the caller dispatches those plans afterward.

### 5.4 Memory split rule

Do not split memory by "reads vs writes" alone. Split by product role:

- `MemoryProjectionService`
  prompt-facing read model for the main LLM
- `ContradictionMemoryService`
  judge-facing retrieval / contradiction substrate
- `MemorySynthesisService`
  conversation/project/global synthesis and canonical writes

`UserMemoryService` survives only as a transitional facade until call sites move.

### 5.5 Actor and thread model

Concurrency ownership is part of the seam.

- `@MainActor`
  - `ChatViewModel`
  - `ScratchPadStore`
  - any `TurnEventSink` implementation that applies events into observable UI state
- `actor`
  - `UserMemoryScheduler`
  - any mutable shared cache owner that coordinates across turns
  - any retry queue that owns delayed re-attempt state across turns
- `Sendable`
  - `TurnRequest`, `TurnPlan`, `TurnEventEnvelope`, and follow-up plan structs
  - `TurnPlanner`
  - `TurnExecutor`
  - `MemoryProjectionService`
  - `ContradictionMemoryService`
  - `ContextContinuationService`
  - `TurnHousekeepingService`

`ConversationSessionStore` and `MemorySynthesisService` may remain plain classes during the migration because they wrap existing `NodeStore` / persistence code, but they may not grow their own cross-turn coordination state. If shared mutable state appears there, that state must move behind an `actor` instead of being hidden in a plain class.

No non-UI turn collaborator should be marked `@MainActor`.

### 5.6 Cancellation and supersession ownership

Cancellation also has a single owner.

- `ChatViewModel` owns the root turn task handle on `@MainActor`
- `ChatViewModel` also owns the active `turnId`
- new send, explicit stop, or conversation switch are the only supersession triggers
- when supersession happens, `ChatViewModel` cancels the root turn task and swaps the active `turnId`
- downstream collaborators do not keep their own competing parent task handles

Child-task rule:

- `TurnPlanner` and `TurnExecutor` may create child tasks only within the lifetime of the root turn
- those child tasks may not outlive the root turn unless they have been converted into explicit follow-up plans after `.completed`
- `UserMemoryScheduler` is separate: once a continuation plan is dispatched after successful completion, the scheduler owns its own tasks

Stale-event rule:

- every emitted event carries `turnId`
- the UI sink applies an event only if its `turnId` still matches the active turn
- stale events from a cancelled/superseded turn are dropped, not merged

This keeps supersession ownership in one place instead of spreading it across VM, planner, executor, and post-turn services.

---

## 6. Target Architecture

### 6.1 Chat flow

```text
ChatViewModel
  -> TurnSessionSnapshot
  -> ConversationSessionStore.prepare(...)
  -> TurnPlanner.plan(...)
  -> emit .prepared
  -> TurnExecutor.execute(..., sink)
  -> ConversationSessionStore.commit(...)
  -> emit .completed
  -> dispatch ContextContinuationPlan
  -> dispatch TurnHousekeepingPlan
```

Normative terminal-event ownership:

- `.completed`
  - emitted by the runner only after `ConversationSessionStore.commit(...)` succeeds
- `.failed(.planning)`
  - emitted by the runner when `TurnPlanner.plan(...)` throws
- `.failed(.execution)`
  - emitted by the runner when `TurnExecutor.execute(...)` throws `TurnExecutionFailure`
- `.failed(.commit)`
  - emitted by the runner when commit throws after execution produced a commit-worthy result
- `.aborted(reason)`
  - emitted by the runner when the root turn task observes cancellation
  - the `reason` is recorded by `ChatViewModel` at cancel time and passed into the runner; downstream collaborators do not infer it ad hoc

This keeps terminal-event responsibility in one place: the runner, not the planner, executor, or VM event sink.

### 6.2 Memory flow

```text
TurnPlanner
  -> MemoryProjectionService
  -> ContradictionMemoryService
  -> ProvocationJudge

UserMemoryScheduler
  -> MemorySynthesisService
```

### 6.3 Final orchestration shape

The final `ChatTurnRunner` is intentionally thin. It sequences collaborators. It does not own the logic of all collaborators.

If the runner starts absorbing prompt assembly, judge feedback-loop shaping, cache policy, persistence helpers, and follow-up work, the refactor has failed.

---

## 7. New Services and Their Contracts

### 7.1 `ConversationSessionStore`

**Responsibility**

- create a conversation if the turn starts from `currentNode == nil`
- persist the user message
- later persist the assistant message
- patch judge-event linkage
- update transcript snapshot and title

**Does not own**

- retrieval
- prompt assembly
- provider execution
- memory refresh scheduling
- cache refresh
- embedding / graph work

**Proposed API**

```swift
struct PreparedTurnSession {
    let turnId: UUID
    let node: NousNode
    let userMessage: Message
    let messagesAfterUserAppend: [Message]
    let promptQuery: String
    let retrievalQuery: String
    let attachmentNames: [String]
}

struct CommitTurnInput {
    let session: PreparedTurnSession
    let execution: TurnExecutionResult
    let judgeEventId: UUID?
    let nextQuickActionMode: QuickActionMode?
}

struct CommittedTurn {
    let turnId: UUID
    let node: NousNode
    let assistantMessage: Message
    let messagesAfterAssistantAppend: [Message]
    let nextQuickActionMode: QuickActionMode?
    let continuationPlan: ContextContinuationPlan
    let housekeepingPlan: TurnHousekeepingPlan
}

final class ConversationSessionStore {
    func prepare(request: TurnRequest) throws -> PreparedTurnSession
    func commit(_ input: CommitTurnInput) throws -> CommittedTurn
}
```

### 7.2 `MemoryProjectionService`

**Responsibility**

- load the prompt-facing memory projection for the main model
- own `currentGlobal`, `currentProject`, `currentConversation`
- own `currentEssentialStory`
- own bounded evidence selection
- own derived `UserModel`

**Does not own**

- contradiction recall
- citable-pool composition
- synthesis writes

**Proposed API**

```swift
struct PromptMemoryProjection {
    let globalMemory: String?
    let essentialStory: String?
    let userModel: UserModel?
    let memoryEvidence: [MemoryEvidenceSnippet]
    let projectMemory: String?
    let conversationMemory: String?
    let recentConversations: [(title: String, memory: String)]
    let projectGoal: String?
}

final class MemoryProjectionService {
    func loadProjection(
        projectId: UUID?,
        conversationId: UUID,
        excludingConversationId: UUID?
    ) -> PromptMemoryProjection
}
```

### 7.3 `ContradictionMemoryService`

**Responsibility**

- recall contradiction-oriented facts
- mark contradiction candidates
- build the judge-visible citable pool

**Does not own**

- prompt-facing memory projection
- synthesis writes
- judge execution itself

**Proposed API**

```swift
struct JudgeMemoryContext {
    let hardRecallFacts: [MemoryFactEntry]
    let annotatedFacts: [UserMemoryService.AnnotatedContradictionFact]
    let contradictionCandidateIds: Set<String>
    let citablePool: [CitableEntry]
}

final class ContradictionMemoryService {
    func buildJudgeContext(
        projectId: UUID?,
        conversationId: UUID,
        currentMessage: String,
        nodeHits: [UUID]
    ) throws -> JudgeMemoryContext
}
```

**Dependency direction**

This service is the only owner of `citableEntryPool(...)` and contradiction recall.

After the split:

- `TurnPlanner` calls `ContradictionMemoryService`
- `ProvocationJudge` receives only `citablePool`
- `ProvocationJudge` does **not** become a chat collaborator that reaches back into memory itself

That change in dependency direction is intentional and must be explicit in code review.

### 7.4 `MemorySynthesisService`

**Responsibility**

- conversation refresh
- project rollup
- global promotion
- canonical memory entry writes
- contradiction-fact extraction / replacement
- `shouldRefreshProject`

**Does not own**

- prompt-facing projection
- judge-facing pool composition
- scheduling policy

**Proposed API**

```swift
protocol MemorySynthesizing: Sendable {
    func refreshConversation(nodeId: UUID, projectId: UUID?, messages: [Message]) async
    func refreshProject(projectId: UUID) async
    func shouldRefreshProject(projectId: UUID, threshold: Int) -> Bool
    func promoteToGlobal(
        candidate: String,
        sourceNodeIds: [UUID],
        confirmation: UserMemoryService.PersonalInferenceDisposition
    ) async -> Bool
}

final class MemorySynthesisService: MemorySynthesizing { ... }
```

`UserMemoryScheduler` should depend on `MemorySynthesizing`, not on the broad facade.

### 7.5 `TurnPlanner`

**Responsibility**

- use `PreparedTurnSession`
- run retrieval
- gather prompt-facing memory projection
- gather judge-facing contradiction context
- run `ProvocationJudge`
- build `TurnSystemSlice`
- build `PromptGovernanceTrace`
- decide effective mode
- prepare the execution request

**Does not own**

- provider streaming
- database commit of the assistant message
- post-turn follow-up work

**Proposed API**

```swift
struct TurnPlan {
    let prepared: PreparedTurnSession
    let citations: [SearchResult]
    let promptTrace: PromptGovernanceTrace
    let effectiveMode: ChatMode
    let nextQuickActionModeIfCompleted: QuickActionMode?
    let judgeEventDraft: JudgeEvent?
    let turnSlice: TurnSystemSlice
    let transcriptMessages: [LLMMessage]
    let focusBlock: String?
    let provider: LLMProvider
}

final class TurnPlanner {
    func plan(from prepared: PreparedTurnSession, snapshot: TurnSessionSnapshot) async throws -> TurnPlan
}
```

Planner failure policy:

- soft misses may still degrade into a valid plan
  - example: no citations found, no recent conversations, judge unavailable
- hard failures in retrieval / projection / prompt assembly inputs throw
  - example: required DB read fails, persisted conversation state cannot be loaded, plan invariants are broken before execution begins

The runner maps planner throws to `.failed(.planning)`.

### 7.6 `TurnExecutor`

**Responsibility**

- resolve provider service
- resolve Gemini history cache usage
- build provider request payloads
- stream thinking and visible text
- normalize provider/configuration failures into user-visible assistant output

**Does not own**

- conversation creation
- prompt memory loading
- judge pool composition
- commit of assistant message
- follow-up services

**Proposed API**

```swift
protocol TurnEventSink: Sendable {
    func emit(_ envelope: TurnEventEnvelope) async
}

enum TurnExecutionFailure: Error {
    case invalidPlan(String)
    case infrastructure(String)
}

struct TurnExecutionResult {
    let rawAssistantContent: String
    let assistantContent: String
    let persistedThinking: String?
    let conversationTitle: String?
    let didHitBudgetExhaustion: Bool
}

final class TurnExecutor {
    func execute(plan: TurnPlan, sink: any TurnEventSink) async throws -> TurnExecutionResult?
}
```

Three-layer execution taxonomy:

- `TurnExecutionResult`
  - execution reached a commit-worthy end state
  - includes normal assistant replies
  - also includes normalized user-visible failure replies such as missing provider config or provider/API failure rendered as assistant text
- `nil`
  - cancellation / supersession only
  - no assistant message should be committed
- `throw TurnExecutionFailure`
  - executor contract or infrastructure failed before a commit-worthy assistant reply existed
  - caller must terminate the turn as `.failed(...)`, not silently coerce it into `.aborted`

This taxonomy is deliberate:

- cancellation is not failure
- user-visible provider/config errors are not infrastructure failure
- actual executor invariants must not disappear into a "best effort" assistant bubble

Normative stage mapping:

- `TurnExecutionFailure.invalidPlan`
  - mapped by the runner to `.failed(.planning)`
  - reason: the executor discovered a bad plan, but the defect is still in plan construction rather than transport/runtime infrastructure
- `TurnExecutionFailure.infrastructure`
  - mapped by the runner to `.failed(.execution)`

There is intentionally no `sinkContractViolation` case. `TurnEventSink.emit(...)` is non-throwing; the executor has no reliable way to classify sink breakage separately from broader infrastructure failure without changing that contract.

### 7.7 `ContextContinuationService`

**Responsibility**

- dispatch scratchpad ingestion
- enqueue memory refresh

**Failure mode**

This is correctness-adjacent. Failure affects the quality of future turns. Failures should be logged separately from housekeeping failures.

**Retry policy**

- scratchpad ingestion: one attempt only, no retry
- memory refresh enqueue: bounded retry within the current app session only
- retry key: `(conversationId, assistantMessageId, workKind)`
- max attempts: 3 total (initial attempt + 2 retries)
- retry backoff: `1s`, then `5s`
- only explicitly classified transient failures may retry
- if the third attempt fails, log and drop; do not persist retry intent across relaunch

This is intentionally narrow. Context continuation is not a durable background job system.

**Proposed API**

```swift
struct ContextContinuationPlan {
    let turnId: UUID
    let conversationId: UUID
    let assistantMessageId: UUID
    let scratchpadIngest: ScratchpadIngestRequest?
    let memoryRefresh: EnqueueMemoryRefreshRequest?
}

final class ContextContinuationService {
    func run(_ plan: ContextContinuationPlan) async
}
```

### 7.8 `TurnHousekeepingService`

**Responsibility**

- refresh Gemini history cache
- refresh embeddings and graph edges
- refresh conversation emoji

**Failure mode**

This is infrastructure / presentation maintenance. Failures affect cost, latency, or secondary UI polish, but do not block the logical correctness of the completed turn.

**Proposed API**

```swift
struct TurnHousekeepingPlan {
    let turnId: UUID
    let conversationId: UUID
    let geminiCacheRefresh: GeminiCacheRefreshRequest?
    let embeddingRefresh: EmbeddingRefreshRequest?
    let emojiRefresh: ConversationEmojiRefreshRequest?
}

final class TurnHousekeepingService {
    func run(_ plan: TurnHousekeepingPlan)
}
```

### 7.9 `ChatTurnRunner`

This type should not be introduced first.

It appears only after the narrower seams exist. At the end state it sequences:

- `ConversationSessionStore`
- `TurnPlanner`
- `TurnExecutor`
- `ConversationSessionStore.commit`

and nothing else.

---

## 8. Core Turn Types

```swift
struct TurnSystemSlice {
    let stable: String
    let volatile: String
}

struct TurnSessionSnapshot {
    let currentNode: NousNode?
    let messages: [Message]
    let defaultProjectId: UUID?
    let activeChatMode: ChatMode?
    let activeQuickActionMode: QuickActionMode?
}

struct TurnRequest {
    let turnId: UUID
    let snapshot: TurnSessionSnapshot
    let inputText: String
    let attachments: [AttachedFileContext]
    let now: Date
}

struct TurnPrepared {
    let turnId: UUID
    let node: NousNode
    let userMessage: Message
    let messagesAfterUserAppend: [Message]
    let citations: [SearchResult]
    let promptTrace: PromptGovernanceTrace
    let effectiveMode: ChatMode
}

enum TurnEvent {
    case prepared(TurnPrepared)
    case thinkingDelta(String)
    case textDelta(String)
    case completed(TurnCompletion)
    case aborted(TurnAbortReason)
    case failed(TurnFailure)
}

struct TurnEventEnvelope {
    let turnId: UUID
    let sequence: Int
    let event: TurnEvent
}

struct TurnCompletion {
    let turnId: UUID
    let node: NousNode
    let assistantMessage: Message
    let messagesAfterAssistantAppend: [Message]
    let nextQuickActionMode: QuickActionMode?
    let continuationPlan: ContextContinuationPlan
    let housekeepingPlan: TurnHousekeepingPlan
}

enum TurnAbortReason {
    case cancelledByUser
    case supersededByNewTurn
    case conversationSwitched
}

struct TurnFailure {
    let stage: TurnFailureStage
    let message: String
}

enum TurnFailureStage {
    case planning
    case execution
    case commit
}
```

### Notes

- `TurnSystemSlice` moves out of `ChatViewModel` namespace. A `Sendable` planner must not depend on a UI-owned `@MainActor` type namespace just to describe prompt slices.
- `turnId` is minted by `ChatViewModel` at the start of `send()`, before any downstream collaborator is called.
- `TurnPrepared` is the first event that updates UI-visible state after the user submits a valid turn.
- `TurnCompletion` is terminal for successful and user-visible error turns. A provider/configuration failure that becomes an assistant bubble still ends as `.completed`, not `.failed`.
- `.aborted` is for cancellation/supersession only.
- `.failed` is for planner/executor/commit infrastructure failure where no commit-worthy assistant reply exists.

---

## 9. Event Ordering and Back-Pressure Contract

This is part of the seam, not an implementation detail.

### 9.1 Ordering

For one logical turn:

1. `TurnEventEnvelope.sequence` is strictly increasing by 1.
2. `.prepared` may appear at most once and, if emitted, must be the first event.
3. `.thinkingDelta` and `.textDelta` may appear zero or more times after `.prepared`.
4. `.completed`, `.aborted`, or `.failed` must appear exactly once as the terminal event.
5. No event may appear after the terminal event.

### 9.2 Delivery semantics

- The event log is append-only.
- The producer may not coalesce, drop, or reorder events to simplify implementation.
- The consumer applies events in the same order they were emitted.
- Replay in tests uses the same append order as production.

### 9.3 Back-pressure

Back-pressure is acknowledged at the sink boundary.

That is why the contract uses `TurnEventSink.emit(...) async` instead of an unstructured "fire and forget" callback. The producer must await the sink before sending the next envelope.

This gives three properties:

- one producer, one ordered sink per `turnId`
- no hidden out-of-order UI updates
- no implicit chunk coalescing under load

### 9.4 Planning vs streaming vs follow-up

- citations and prompt trace belong in `.prepared`
- token streaming belongs in delta events
- follow-up plans belong only in `.completed`

Judge logging and cache policy may happen during planning/execution internally, but they do not get their own ad hoc UI event type in phase 1 of the seam work.

---

## 10. Current Code Mapping to Future Homes

This is the seam map that prevents "move the same method to a new file" refactors.

### 10.1 From `ChatViewModel` to `ConversationSessionStore`

- `startNewConversation` persistence path
- user-message insert inside `runSend`
- assistant-message insert inside `runSend`
- `persistConversationSnapshot`
- `maybeApplyConversationTitle`
- judge-event message-id patching

### 10.2 From `ChatViewModel` to `TurnPlanner`

- retrieval setup and citation selection
- project-goal fetch used for prompt assembly
- `assembleContext`
- `governanceTrace`
- `buildFocusBlock`
- `deriveProvocationKind`
- judge feedback-loop building for planner use
- `userMessageContent`
- `shouldAllowInteractiveClarification`
- quick-action carry-forward decisions

### 10.3 From `ChatViewModel` to `TurnExecutor`

- provider resolution
- `activeGeminiHistoryCache`
- `configuredGeminiService`
- `requestMessages`
- `requestSystem`
- `configuredStreamingService`
- streaming loop
- budget-exhaustion fallback
- title extraction / assistant-content normalization before commit handoff

### 10.4 From `ChatViewModel` to `ContextContinuationService`

- `scheduleUserMemoryRefresh`
- scratchpad ingestion

### 10.5 From `ChatViewModel` to `TurnHousekeepingService`

- `refreshGeminiConversationCacheIfNeeded`
- detached embedding refresh and edge regeneration
- async conversation emoji refresh

### 10.6 From `UserMemoryService` to `MemoryProjectionService`

- `currentGlobal`
- `currentProject`
- `currentConversation`
- `currentEssentialStory`
- `currentBoundedEvidence`
- `currentIdentityModel`
- `currentGoalModel`
- `currentWorkStyleModel`
- `currentMemoryBoundary`
- `currentUserModel`

### 10.7 From `UserMemoryService` to `ContradictionMemoryService`

- `contradictionRecallFacts`
- `annotateContradictionCandidates`
- `citableEntryPool`

### 10.8 From `UserMemoryService` to `MemorySynthesisService`

- `refreshConversation`
- `refreshProject`
- `promoteToGlobal`
- `shouldRefreshProject`
- `writeScopeEntry`
- conversation-fact extraction / replacement
- project-fact rollup / replacement

---

## 11. Transitional Facades

### 11.1 `UserMemoryService`

`UserMemoryService` stays alive during the migration, but only as a facade.

Temporary delegation rule:

- projection methods -> `MemoryProjectionService`
- contradiction / citable-pool methods -> `ContradictionMemoryService`
- synthesis / promotion methods -> `MemorySynthesisService`

No new logic should be added to the facade once the split starts.

### 11.2 `ChatViewModel`

Public API stays stable during migration:

- `send()`
- `startNewConversation(...)`
- `loadConversation(...)`
- `stopGenerating()`

During the transition, `ChatViewModel.send()` may delegate partially:

- first to `TurnPlanner`
- then to `TurnExecutor` for a narrow path
- eventually to a full `ChatTurnRunner`

That staged delegation is allowed.

What is not allowed:

- define `TurnRequest` / `TurnPlan` / `TurnEvent` and keep the old inline logic untouched
- duplicate planning logic in both legacy and new paths for more than one migration step

---

## 12. Migration Order

Each step must land a real production call-site move.

### Step 0 - This spec

No code behavior change.

### Step 1 - Split memory under the facade and move scheduler ownership

Create:

- `MemoryProjectionService`
- `ContradictionMemoryService`
- `MemorySynthesisService`

Keep `UserMemoryService` as facade. No chat call-site changes yet.

**Why first:** the chat seam depends on stable memory boundaries. Otherwise `TurnPlanner` still reaches into one broad service and the chat split is fake.

**Acceptance for Step 1**

- `UserMemoryScheduler` now depends on `MemorySynthesizing`
- `UserMemoryScheduler` no longer references the broad `UserMemoryService`
- `UserMemoryService` delegates projection, contradiction, and synthesis methods to the three split services
- this step is not complete if the scheduler dependency has not moved

### Step 2 - Extract `ConversationSessionStore`

Move conversation creation, message persistence, transcript snapshot, and title commit out of `ChatViewModel`.

`ChatViewModel` still orchestrates the whole send path at this step.

### Step 3 - First live contract slice: route all sends through `TurnPlanner`

Introduce:

- `TurnSessionSnapshot`
- `TurnRequest`
- `TurnPlan`

Then make the existing `runSend` call `TurnPlanner.plan(...)` for **all** send paths.

This is the first required real validation of the plan shape. A `TurnPlan` not consumed by production code does not count.

### Step 4 - First live event slice: route the narrow execution path through `TurnExecutor`

Introduce:

- `TurnEvent`
- `TurnEventEnvelope`
- `TurnEventSink`

Migrate the narrowest real path first:

- `provider == .local`, or
- any path where the judge is skipped / unavailable

That path still exercises:

- `.prepared`
- streaming deltas
- `.completed` / `.aborted` / `.failed`

without first entangling judge + remote-provider + Gemini-cache complexity.

### Step 5 - Expand `TurnExecutor` to judged cloud-provider turns

Once the event contract works on the narrow path, widen it to:

- judged turns
- cloud providers
- Gemini cache path

### Step 6 - Dispatch follow-up plans through the two post-turn services

Move:

- scratchpad ingestion
- memory refresh scheduling
- cache refresh
- embedding / edge regeneration
- emoji refresh

out of the inline send path.

### Step 7 - Introduce the thin `ChatTurnRunner`

Only after Steps 1-6 exist:

- `ChatTurnRunner`

may be introduced as the sequencing shell.

### Step 8 - Delete facade-only helpers from old homes

Once each call site has moved:

- remove moved helpers from `ChatViewModel`
- shrink `UserMemoryService` further or delete it if no longer needed

---

## 13. Review Gates

The seam work should stop if any of these become false:

1. `ChatViewModel` is getting smaller in responsibility, not just in line count.
2. `TurnPlanner` and `TurnExecutor` each have one sentence descriptions that still fit.
3. `MemorySynthesisService` is the explicit home of conversation/project/global write logic.
4. `ProvocationJudge` still consumes only a prepared citable pool and does not start reaching into memory itself.
5. Post-turn correctness work and infrastructure housekeeping remain split.
6. Every new contract is validated by a real call site before the next seam is cut.
7. `TurnPlanner` remains orchestration-only: it may assemble a plan, but it may not start streaming, commit assistant messages, or dispatch follow-up work.

If any of these fail, the refactor is drifting back into renaming and repartitioning instead of true boundary-setting.
