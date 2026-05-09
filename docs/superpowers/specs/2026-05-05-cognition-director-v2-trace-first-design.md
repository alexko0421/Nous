# Cognition Director V2 Trace-First Design

**Date:** 2026-05-05
**Status:** Draft for Alex review
**Bead:** `new-york-c2yw`
**Scope:** First slice of the large Nous V2 cognition system. This slice makes per-turn cognition observable before making it more autonomous.

## Thesis

Nous already has many cognition organs: `TurnSteward`, memory context building, Skill Fold, `ProvocationJudge`, slow cognition artifacts, agent loops, shadow learning, weekly reflection, Galaxy relation judgment, and silent review.

The problem is not absence of organs. The problem is that they do not yet share one turn-level frame that answers:

- Which organs participated in this turn?
- Which organs were skipped, and why?
- Which evidence or resource ids shaped the prompt?
- Which artifacts were attached after the turn?
- Did any organ fail closed?
- Did the answer behavior change because of any of this?

The first large V2 move should therefore be trace-first: build a small `CognitionDirector` layer that records one `CognitionFrame` per turn, without changing reply behavior yet.

## Product Standard

This is not a dashboard project. It is a trust project.

Alex should be able to inspect a turn and understand why Nous answered with a certain memory, mode, skill, reflection, or agent path. The trace should stay calm and sparse. If it exposes raw prompt text, private source text, or internal chain-of-thought, it fails.

The product lift is:

- fewer mystery answers
- easier debugging when memory feels wrong
- a shared rail for future Memory Agent, Skill Fold, Weekly Reflection, and Galaxy upgrades
- no new visible burden in the normal chat flow

## Current Baseline

Existing code already gives useful raw materials:

- `TurnPlanner` assembles the per-turn prompt and records `PromptGovernanceTrace`.
- `TurnSteward` decides route, memory policy, challenge stance, and response shape.
- `TurnMemoryContextBuilder` gathers memory layers, citations, citable pool, graph recall, and provenance.
- `QuickActionAddendumResolver` matches and loads skills.
- `ProvocationJudge` can produce a verdict and fallback reason.
- `SlowCognitionArtifactProvider` adapts weekly reflection, shadow patterns, and Galaxy relations into artifacts.
- `CognitionReviewer` silently reviews the final answer for risk flags.
- `TurnCognitionSnapshot` and `TurnCognitionInspectorFeed` already record a small runtime cognition snapshot.
- `GovernanceTelemetryStore` already stores bounded recent snapshots and aggregate counts in `UserDefaults`.

The missing piece is a common frame that treats those parts as one cognition pass instead of unrelated traces.

## Goals

- Add a bounded `CognitionFrame` model for one turn.
- Add per-organ records with `used`, `skipped`, or `failed` status.
- Record reasons and ids, not raw prompt text.
- Extend the existing turn cognition snapshot path instead of adding a parallel persistence system.
- Preserve backward compatibility for old snapshots.
- Keep runtime behavior unchanged in the first implementation.
- Make the next B/C/D upgrades easier to attach:
  - Skill Fold can report matched, loaded, and capped skills.
  - Weekly Reflection and Shadow Learning can report which slow artifacts were eligible.
  - Galaxy and Memory Graph can report relation/evidence participation.
  - Future Director logic can promote from observing to scheduling.

## Non-Goals

- Do not modify `Sources/Nous/Resources/anchor.md`.
- Do not add a new autonomous background loop in this slice.
- Do not let the Director decide or override turn behavior yet.
- Do not expose chain-of-thought or raw prompts.
- Do not create a polished new UI.
- Do not add SwiftData, Core Data, an ORM, or third-party dependencies.
- Do not combine this with Operating Context V2, Skill Fold V2.5, or Galaxy rewrite work.
- Do not store Alex product/personal memory in Beads.

## Recommended Shape

### 1. `CognitionFrame`

A `CognitionFrame` is the turn-level record. It is safe to persist in telemetry because it stores structure and ids, not hidden prompt text.

Suggested fields:

```swift
struct CognitionFrame: Codable, Equatable, Sendable {
    let id: UUID
    let turnId: UUID
    let conversationId: UUID
    let assistantMessageId: UUID?
    let frameVersion: Int
    let records: [CognitionOrganRecord]
    let createdAt: Date
}
```

### 2. `CognitionOrganRecord`

Each record describes one organ's participation.

```swift
enum CognitionOrganStatus: String, Codable, Equatable, Sendable {
    case used
    case skipped
    case failed
}

struct CognitionOrganRecord: Codable, Equatable, Sendable {
    let organ: CognitionOrgan
    let label: String
    let status: CognitionOrganStatus
    let reason: String
    let evidenceRefs: [CognitionEvidenceRef]
    let resourceIds: [String]
    let riskFlags: [String]
}
```

The existing `CognitionOrgan` enum may need a few additional cases, such as `turnSteward`, `memoryRetriever`, `skillFold`, and `provocationJudge`. If that creates too much churn, keep `organ` coarse and use `label` for the precise component name. The implementation plan should choose the smallest change that keeps tests readable.

### 3. `CognitionDirector`

`CognitionDirector` v1 is a collector, not a decider.

It should expose one pure function:

```swift
final class CognitionDirector {
    func frame(
        plan: TurnPlan,
        committed: CommittedAssistantTurn,
        reviewArtifact: CognitionArtifact?
    ) -> CognitionFrame
}
```

The function reads already-computed turn state. It must not call LLMs, search memory, mutate storage, or schedule background work.

### 4. Snapshot Integration

Extend `TurnCognitionSnapshot` with:

```swift
let cognitionFrame: CognitionFrame?
```

The decoder should default missing legacy frames to `nil`. `TurnCognitionSnapshotFactory.make(...)` should ask `CognitionDirector` for a frame after the assistant turn commits.

This keeps storage simple:

- `GovernanceTelemetryStore.recordTurnCognitionSnapshot(...)` continues to be the single write path.
- The bounded recent snapshot window remains the first persistence layer.
- No SQLite schema change is required in the first slice.

SQLite can come later if the trace becomes useful enough to inspect across months.

## First Slice Records

The first implementation should record these organs:

| Organ | Status Rule | Reason Source | Evidence / Resources |
|---|---|---|---|
| Turn Steward | `used` for every successful turn | `TurnStewardDecision.reason` plus route/memory policy | none |
| Memory Retriever | `used` if any memory/citation/resource id reached the prompt, otherwise `skipped` | memory policy and prompt layers | citation ids, memory evidence source ids, provenance keys |
| Skill Fold | `used` if matched or loaded skills exist, otherwise `skipped` | quick action resolution and agent coordination | skill ids |
| Provocation Judge | `used`, `skipped`, or `failed` from judge fallback reason | `JudgeFallbackReason` and verdict availability | entry id if verdict cites one |
| Slow Cognition | `used` if slow artifact attached, otherwise `skipped` | slow cognition trace | artifact id and evidence ref ids |
| Agent Loop | `used` if tool loop executed, otherwise `skipped` | `AgentCoordinationTrace` | indexed and loaded skill ids |
| Reviewer | `used` if silent review artifact exists, otherwise `skipped` | review artifact or absence | artifact id and risk flags |

Do not over-record. A sparse frame that tells the truth is better than a verbose frame that becomes another unreadable log.

## Inspector Behavior

Extend `TurnCognitionInspectorFeed` enough to summarize the frame:

- total organ count
- used/skipped/failed counts
- compact labels like `steward used`, `judge skipped: provider_local`, `reviewer used: 2 risk flags`
- no prompt text
- no source body text

The existing feed rows can gain one field such as:

```swift
let organSummary: String
```

This avoids a new UI surface while still making the first slice visible in `MemoryDebugInspector` or any existing debug feed.

## Privacy Rules

The trace may include:

- UUIDs
- prompt layer names
- memory provenance keys
- skill ids
- artifact ids
- risk flag names
- short machine reasons such as `provider_local`, `judge_unavailable`, or `full_memory_policy`

The trace must not include:

- full user message text
- full assistant answer text
- raw prompt blocks
- source document text
- hidden reasoning traces
- personal memory contents unless already represented as an id

If an evidence quote is needed later, it should be capped and deliberately added through `CognitionEvidenceRef.quote`. The first slice should avoid quotes entirely.

## Error Handling

The Director should fail closed.

- If frame construction throws or hits malformed data, the turn should still complete.
- Snapshot creation should record no frame rather than blocking chat.
- Inspector formatting should tolerate missing frames and legacy snapshots.
- Unknown enum values should not crash old telemetry decoding where possible.

The first implementation can make `CognitionDirector.frame(...)` non-throwing by dropping invalid records internally.

## Testing

Tests should prove behavior, not implementation detail.

Required focused tests:

- `CognitionDirectorTests`
  - builds a frame with steward, memory, judge, slow cognition, agent loop, and reviewer records from a synthetic `TurnPlan`
  - marks skipped organs when optional systems did not participate
  - does not include raw prompt text or assistant text in encoded JSON
- `CognitionContractsTests`
  - validates `CognitionFrame` / `CognitionOrganRecord` encoding and empty-label safeguards if added
  - decodes legacy `TurnCognitionSnapshot` without a frame
- `TurnCognitionInspectorFeedTests`
  - displays organ summary counts and labels
  - tolerates missing `cognitionFrame`
- Existing runner tests
  - confirm successful turns still emit snapshots
  - confirm no answer behavior changes

Verification should include:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/CognitionDirectorTests -only-testing:NousTests/CognitionContractsTests -only-testing:NousTests/TurnCognitionInspectorFeedTests CODE_SIGNING_ALLOWED=NO
```

and a macOS app build after the focused tests pass.

## Phasing

### Phase 1: Observe

Build `CognitionFrame`, `CognitionDirector`, snapshot integration, feed summary, and tests. No behavior change.

### Phase 2: Inspect

If the trace is useful in dogfooding, make the debug inspector easier to read. Still no behavior change.

### Phase 3: Decide

Only after the trace is trusted, let `CognitionDirector` make small routing decisions, such as whether slow cognition should be attached under clear conditions.

### Phase 4: Coordinate

Attach larger V2 systems: Skill Fold upgrades, Weekly Reflection surfacing, Memory Graph relation surfacing, and proactive connection hints.

## Acceptance Criteria For Phase 1

- Every successful normal chat turn can produce a `CognitionFrame`.
- Legacy snapshots still decode.
- The frame records at least steward, memory, judge, slow cognition, agent loop, and reviewer participation.
- The frame does not store raw prompt text, raw user message text, raw assistant answer text, or source body text.
- Existing turn behavior is unchanged.
- Focused tests and app build pass.

## Decision

Alex chose Approach 1: trace-first Cognition Director.

This is the right first large V2 slice because it creates a shared rail for future cognition work without immediately making Nous more autonomous, more intrusive, or harder to debug.
