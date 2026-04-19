# JudgeVerdict v2 — Unified Schema Delta

Generated: 2026-04-18
Status: DRAFT
Referenced by:
- `2026-04-18-memory-retrieval-vnext.md` (vNext retrieval — `provocation_hint`)
- `kochunlong-alexko0421-chatmode-ui-removal-design-20260418-190807.md` (Companion v2 — `arcStage`)

## Purpose

Two in-flight designs want to extend `JudgeVerdict`. Rather than land them in sequence and migrate twice, this doc locks one additive schema both designs target.

## Current schema

`Sources/Nous/Models/JudgeVerdict.swift` today:

```swift
struct JudgeVerdict: Codable, Equatable {
    let tensionExists: Bool
    let userState: UserState            // deciding | exploring | venting
    let shouldProvoke: Bool
    let entryId: String?
    let reason: String
    let inferredMode: ChatMode          // companion | strategist
}
```

## Additions (v2)

Both fields are **optional** so decoding old judge responses (and fixtures) stays valid. Judge prompt is extended to populate them; missing / unparseable → nil, logged as `bad_json` fallback but not fatal.

```swift
struct JudgeVerdict: Codable, Equatable {
    // ...existing fields unchanged...

    /// Companion v2 — conversation arc position for closure detection.
    /// nil when judge did not emit (old fixtures, fallback path).
    let arcStage: ArcStage?

    /// vNext retrieval — optional hint to the surface-selection layer.
    /// nil when nothing worth surfacing this turn.
    let provocationHint: ProvocationHint?

    enum CodingKeys: String, CodingKey {
        // ...existing...
        case arcStage = "arc_stage"
        case provocationHint = "provocation_hint"
    }
}

enum ArcStage: String, Codable {
    case opening       // user just started a thread
    case exploring     // actively working through an idea
    case insight       // a take has landed, user is processing
    case landing       // conversation winding down, user acknowledging
}

struct ProvocationHint: Codable, Equatable {
    enum HintType: String, Codable {
        case contradiction   // past entry contradicts current user message
        case askBack = "ask_back"   // past entry deserves a follow-up question
        case surface         // past entry worth naming without asking
    }
    let type: HintType
    let targetEntryId: String   // must appear in citable pool

    enum CodingKeys: String, CodingKey {
        case type
        case targetEntryId = "target_entry_id"
    }
}
```

## Fixture impact

- Existing fixtures under `Tests/NousTests/Fixtures/ProvocationScenarios/*.json` stay valid — both new fields are optional.
- New fixtures covering `arcStage` landing + `provocation_hint` emission land with their respective design's implementation phase.

## Telemetry

`judge_events` already logs the full verdict. No schema change to the event store — new fields serialize alongside existing ones. Governance dashboard can add columns lazily.

## Ship order

1. **This schema doc lands first** (docs only, no code).
2. Companion v2 Phase 1 (prompt-only, no judge changes) can ship without touching this.
3. Whichever of Companion v2 Phase 3 / vNext `provocation_hint` implementation lands first extends `JudgeVerdict` with **both** fields at once. Second design consumes the already-added field.

## Non-goals

- Not changing existing field names or types.
- Not introducing a version number on the verdict envelope — additive optionals are forward/backward compatible by construction.
- Not specifying the judge prompt changes here — each design's doc owns its own prompt delta.
