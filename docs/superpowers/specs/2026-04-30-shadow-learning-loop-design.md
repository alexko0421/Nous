# Shadow Learning Loop Design Spec

## Overview

Shadow Learning Loop gives Nous a quiet way to learn how its user thinks without turning that learning into a rigid approval workflow. The first version learns thinking moves and response behavior, not deep personality judgments. It runs in the background, writes evidence-backed patterns into SQLite, lets those patterns gently influence future prompts, and ages them out when the user's behavior changes.

The product feel matters more than the machinery. Alex should not feel like he is managing a rule database. The right feeling is that Nous slowly becomes better at helping him think, because it has noticed which thinking moves repeatedly help him.

## Product Decision

Use Shadow Learning instead of a visible Skill Candidate Inbox for v1.

The earlier candidate-inbox design was safe, but too stiff. It would make Alex approve his own thinking habits like pull requests. Shadow Learning keeps the safety properties underneath while making the surface feel natural:

- The system observes and records patterns silently.
- Only low-risk thinking moves and answer behavior influence prompts.
- Influence starts weak and grows only after reinforcement.
- Corrections and drift reduce weight automatically.
- The user can inspect and edit later, but inspection is not part of the main flow.

## Scope

### In Scope

- Learn thinking moves, such as first-principles reasoning, inversion, pain test, concrete tradeoffs, and direct pushback.
- Learn response behavior, such as "organize my messy thought before judging" or "avoid generic advice."
- Track evidence, confidence, weight, status, and time.
- Decay stale patterns and retire patterns that no longer match.
- Inject at most three relevant shadow patterns into the volatile prompt for a turn.
- Run learning work from a heartbeat cadence: immediate signal capture, daily or message-count learning, weekly consolidation.
- Keep all learning local in SQLite.

### Out of Scope for v1

- Deep personality labels, diagnoses, or claims like "the user always avoids X."
- Automatic edits to `Sources/Nous/Resources/anchor.md`.
- Visible approval inbox.
- Multi-user UI. Data model should use `user_id`, but the app may continue to use the existing default user id in v1.
- Training model weights.

## Core Concepts

### ShadowPattern

A durable pattern that describes a useful thinking move or answer behavior.

Examples:

- `first_principles_decision_frame`
- `inversion_before_recommendation`
- `pain_test_for_product_scope`
- `concrete_over_generic`
- `organize_before_judging`

Each pattern has:

- `kind`: `thinking_move` or `response_behavior`
- `summary`: human-readable explanation
- `prompt_fragment`: short instruction used only when relevant
- `trigger_hint`: text used for lightweight matching
- `confidence`: how well supported it is by evidence
- `weight`: how strongly it may influence prompts
- `status`: `observed`, `soft`, `strong`, `fading`, or `retired`
- evidence message ids
- first seen, last seen, reinforced, corrected, active range timestamps

### LearningEvent

An append-only record of why a pattern changed.

Event types:

- `observed`
- `reinforced`
- `corrected`
- `weakened`
- `promoted`
- `retired`
- `revived`

Events preserve the timeline. Patterns can be retired from prompt use without deleting the history.

### ShadowProfile

The current active set of shadow patterns for a user. This is not stored as one large blob. It is the read-time projection of current `shadow_patterns` rows.

## Lifecycle

Patterns move through this lifecycle:

```text
observed -> soft -> strong -> fading -> retired
```

Meaning:

- `observed`: recorded, but never injected into prompts.
- `soft`: lightly influences prompts when relevant.
- `strong`: stable enough to influence prompts more often.
- `fading`: previously useful, now decaying because it has not been reinforced or was corrected.
- `retired`: no longer affects prompts, but remains in history.

## Cadence

Use layered cadence, not a fixed monthly job.

```text
After each user turn: record cheap signals only.
Daily or every 15-25 new user messages: update ShadowProfile.
Weekly: consolidate, promote, decay, retire, and revive.
Monthly: optional reflection outside v1 core.
```

First implementation defaults:

- Record immediate signals after every persisted user message.
- Run the Learning Steward at most once every 24 hours.
- Require at least 15 new user messages since the last run.
- Schedule the run after an idle delay of 180 seconds.
- Cap each run to three pattern updates.
- Weekly consolidation uses the same steward with a seven-day consolidation path.

## Forgetting and Drift

Nous must learn that the user changes. It should not pin the user to an old profile.

Rules for v1:

- If a pattern has no reinforcement for 30 days, reduce weight and move `strong` to `fading`.
- If a pattern receives two explicit corrections, reduce weight immediately and move it toward `fading`.
- If a pattern stays low-weight and unreinforced for 60 days, set `status = retired`.
- If a retired pattern reappears with fresh evidence, set `status = revived` event and move it back to `observed` or `soft`.
- Retired patterns never enter prompts.

The system should prefer "currently useful" over "historically true."

## Prompt Influence

Shadow patterns are volatile prompt hints, not identity claims.

Good injection:

```text
SHADOW THINKING HINTS:
- For product decisions, start from the pain test: absence must hurt.
- Before recommending, use inversion and name the worst version of the feature.
- Prefer concrete tradeoffs over generic encouragement.
```

Bad injection:

```text
Alex is a first-principles thinker who hates generic advice and always wants pushback.
```

Rules:

- Inject only `soft` and `strong` patterns.
- Inject at most three patterns per turn.
- Each pattern contributes one short sentence.
- Do not inject patterns below confidence `0.65` or weight `0.25`.
- Do not inject a pattern corrected within the last seven days.
- Match patterns to the current quick mode, inferred route, and user message.
- Keep injection in the volatile prompt, not the stable Gemini cache prefix.
- Add `shadow_learning` to `PromptGovernanceTrace.promptLayers` when injected.

## Architecture

```text
User message
  -> ChatTurnRunner persists user message
  -> ShadowLearningSignalRecorder records cheap learning events
  -> HeartbeatCoordinator schedules idle steward run

HeartbeatCoordinator
  -> checks cadence and backgroundAnalysisEnabled
  -> ShadowLearningSteward scans recent messages
  -> ShadowLearningStore upserts patterns and events
  -> ShadowPatternLifecycle applies promotion, decay, retirement

TurnPlanner
  -> ShadowPatternPromptProvider selects 1-3 relevant patterns
  -> PromptContextAssembler adds SHADOW THINKING HINTS to volatile prompt
```

## Data Model

### `shadow_patterns`

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PRIMARY KEY | UUID |
| `user_id` | TEXT NOT NULL | Default remains existing `alex` in v1 |
| `kind` | TEXT NOT NULL | `thinking_move` or `response_behavior` |
| `label` | TEXT NOT NULL | Stable machine label |
| `summary` | TEXT NOT NULL | Human-readable pattern |
| `prompt_fragment` | TEXT NOT NULL | Short instruction for prompt injection |
| `trigger_hint` | TEXT NOT NULL | Lightweight matching text |
| `confidence` | REAL NOT NULL | 0 to 1 |
| `weight` | REAL NOT NULL | 0 to 1 |
| `status` | TEXT NOT NULL | lifecycle state |
| `evidence_message_ids` | TEXT NOT NULL | JSON array of UUID strings |
| `first_seen_at` | REAL NOT NULL | Date |
| `last_seen_at` | REAL NOT NULL | Date |
| `last_reinforced_at` | REAL | Date |
| `last_corrected_at` | REAL | Date |
| `active_from` | REAL | Date |
| `active_until` | REAL | Date |

### `learning_events`

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PRIMARY KEY | UUID |
| `user_id` | TEXT NOT NULL | Same user namespace as patterns |
| `pattern_id` | TEXT | Nullable link to `shadow_patterns` |
| `source_message_id` | TEXT | Nullable link to `messages` |
| `event_type` | TEXT NOT NULL | event enum |
| `note` | TEXT NOT NULL | Short reason |
| `created_at` | REAL NOT NULL | Date |

### `shadow_learning_state`

| Column | Type | Notes |
|---|---|---|
| `user_id` | TEXT PRIMARY KEY | Default `alex` in v1 |
| `last_run_at` | REAL | Last steward run |
| `last_scanned_message_at` | REAL | Last message timestamp included |
| `last_consolidated_at` | REAL | Last weekly consolidation |

## Pattern Extraction v1

Use deterministic extraction first. This avoids asking a cloud model to infer personality from private data.

Initial detectors:

- First principles: "first principle", "first-principles", "底层", "本质", "从根上"
- Inversion: "反过来", "inversion", "worst version", "最坏"
- Pain test: "会痛", "痛不痛", "pain test", "absence"
- Concrete over generic: "generic", "太泛", "具体", "concrete"
- Direct pushback: "push back", "直接说", "不要顺着我"
- Organize before judging: "我说不清", "帮我整理", "organize", "梳理"

Later versions can use an LLM extractor after privacy and cost controls are settled.

## Settings and Visibility

V1 does not need a full UI. It should add a small debug inspector section only:

- Active shadow patterns
- Status, weight, confidence
- Last seen and last corrected
- Recent learning events

The normal product surface stays quiet.

## Success Criteria

- A repeated first-principles or pain-test signal becomes a `soft` pattern after enough evidence.
- A `soft` or `strong` pattern appears in the prompt only for relevant turns.
- Prompt injection never exceeds three short hints.
- Explicit correction reduces weight and prevents immediate reinjection.
- Stale patterns decay and retire without data loss.
- Existing skill behavior continues to pass.
- No changes are made to `anchor.md`.

## Non-Goals

- Do not build a visible approval inbox in v1.
- Do not make Nous explain every learned pattern during chat.
- Do not store deep personality judgments.
- Do not add third-party dependencies.
- Do not introduce SwiftData, Core Data, or an ORM.
