# Source Connection Brief V2A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make source-analysis turns produce grounded connection briefs that link external source claims to existing Nous citations without promoting source material into personal memory.

**Architecture:** Reuse the V1 source ingestion and turn route. Add a prompt contract, context manifest source-material telemetry, and a light runtime reviewer warning. No new UI, no new persistence tables, and no source library.

**Tech Stack:** Swift, XCTest, raw SQLite-backed existing stores, existing `PromptContextAssembler`, `ContextManifestFactory`, and runtime reviewer artifacts.

---

## Task 1: Prompt Contract

**Files:**
- Modify: `Sources/Nous/Services/PromptContextAssembler.swift`
- Modify: `Tests/NousTests/SourcePromptContextTests.swift`

- [ ] Add a failing XCTest that `SOURCE MATERIAL` prompt context contains `SOURCE CONNECTION BRIEF` and the phrases `What the source says`, `How it connects to Alex`, and `If there is no strong existing Nous connection`.

- [ ] Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/SourcePromptContextTests/testSourceMaterialsRenderAsGroundedSourceBlock
```

Expected: FAIL because the contract text is not present yet.

- [ ] Add the brief contract to the existing source material block:

```swift
SOURCE CONNECTION BRIEF:
When answering from source material, use a compact connection brief when it helps:
- What the source says: cite the source title, URL, filename, or chunk marker.
- How it connects to Alex: connect only to provided notes, conversations, projects, decisions, or citations.
- Why it matters: state the practical implication for Alex's current thinking or project.
- Grounding: name the source and any existing Nous citation used for the connection.
If there is no strong existing Nous connection, say that plainly instead of inventing one.
```

- [ ] Re-run the focused test and confirm PASS.

## Task 2: Source Material Context Manifest

**Files:**
- Modify: `Sources/Nous/Services/GovernanceTelemetryStore.swift`
- Modify: `Tests/NousTests/AgentToolTests.swift`

- [ ] Add a failing XCTest in `ContextManifestFactoryTests` that builds a `TurnPlan` with `sourceMaterials`, `promptLayers: ["source_material"]`, and assistant content mentioning the source title. Assert a `ContextManifestResource(source: .sourceMaterial, label: "source_material", referenceId: sourceNodeId.uuidString, state: .loaded, used: true)` exists.

- [ ] Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ContextManifestFactoryTests
```

Expected: FAIL because `.sourceMaterial` does not exist or resources are not emitted.

- [ ] Add `case sourceMaterial` to `ContextManifestResourceSource`.

- [ ] Add telemetry summary counts for loaded and used source material resources so `summaryText` can include `source material <count>`.

- [ ] In `ContextManifestFactory.make`, when `promptLayers` contains `source_material`, append one loaded resource per `plan.sourceMaterials`. Mark it used when assistant content contains the source title, original URL, original filename, or URL host.

- [ ] Re-run `ContextManifestFactoryTests` and confirm PASS.

## Task 3: Source Connection Grounding Reviewer

**Files:**
- Modify: `Sources/Nous/Services/CognitionArtifactAdapters.swift`
- Modify: `Tests/NousTests/RuntimeQualityReviewerTests.swift`

- [ ] Add a failing XCTest that creates a source-analysis review with one source and one citation, then an assistant answer that mentions the source title but no existing citation title and does not say no connection exists. Assert the review artifact contains `source_connection_grounding_missing`.

- [ ] Add a second XCTest proving no warning when the assistant references the citation title.

- [ ] Add a third XCTest proving no warning when the assistant says there is no strong existing Nous connection.

- [ ] Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/RuntimeQualityReviewerTests
```

Expected before implementation: at least the new first test FAILS.

- [ ] In `CognitionArtifactAdapters`, add a helper that checks source-analysis turns with non-empty citations. It should return true only when no citation title appears and no "no strong connection" style phrase appears.

- [ ] Add risk flag `source_connection_grounding_missing` when the helper returns true.

- [ ] Re-run `RuntimeQualityReviewerTests` and confirm PASS.

## Task 4: Verification

**Files:**
- Check: `Sources/Nous/Services/PromptContextAssembler.swift`
- Check: `Sources/Nous/Services/GovernanceTelemetryStore.swift`
- Check: `Sources/Nous/Services/CognitionArtifactAdapters.swift`
- Check: `Tests/NousTests/SourcePromptContextTests.swift`
- Check: `Tests/NousTests/AgentToolTests.swift`
- Check: `Tests/NousTests/RuntimeQualityReviewerTests.swift`

- [ ] Run focused V2A tests:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/SourcePromptContextTests \
  -only-testing:NousTests/ContextManifestFactoryTests \
  -only-testing:NousTests/RuntimeQualityReviewerTests
```

Expected: PASS.

- [ ] Run build:

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```

Expected: PASS.

- [ ] Run full tests with an isolated DerivedData path if the default DerivedData cache hits Xcode signing noise:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -derivedDataPath /tmp/NousV2ASourceConnectionBriefDerivedData
```

Expected: PASS.

- [ ] Run workflow guardrails:

```bash
scripts/agentic_workflow_check.sh --bead new-york-5g3b \
  --path Sources/Nous/Services/PromptContextAssembler.swift \
  --path Sources/Nous/Services/GovernanceTelemetryStore.swift \
  --path Sources/Nous/Services/CognitionArtifactAdapters.swift \
  --path Tests/NousTests/SourcePromptContextTests.swift \
  --path Tests/NousTests/AgentToolTests.swift \
  --path Tests/NousTests/RuntimeQualityReviewerTests.swift \
  --path docs/superpowers/specs/2026-05-04-source-connection-brief-v2a-design.md \
  --path docs/superpowers/plans/2026-05-04-source-connection-brief-v2a.md
```

Expected: PASS.
