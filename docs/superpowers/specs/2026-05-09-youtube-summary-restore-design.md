# YouTube Summary Feature Restoration — Design

**Date:** 2026-05-09
**Branch:** `youtube-summary-restore` (off `codex/context-manifest-telemetry`)
**Source-of-truth stash:** `932a19c` (3-way merge stash, 63 files, ~3840 insertions)
**Scope decision:** full feature restoration (Buckets A + B + C). Bucket D (voice/eval/harness) excluded.

## Background

The YouTube summary feature was preserved as a WIP stash (`932a19c`, 2026-05-08) to keep it out of the own-corpus Phase 1 PR sequence. Since then, own-corpus blocks 1–7 + 8-lite + Block 6 atom hybrid shipped on `main` and on the current branch (`f670b79`). The user wants the complete feature back in, not a sliver.

Several files in the stash have moved on `main` since the stash was taken: `PromptContextAssembler`, `NodeStore`, `SourceMaterial`, `ChatViewModel`, `ChatTurnRunner`, `CitableContextBuilder`. Direct `git stash pop` will conflict.

## Goals

1. Restore the end-to-end YouTube summary flow:
   - User triggers YouTube summary from Welcome action or active browser tab.
   - Transcript ingestion (preferred) or Gemini video analysis fallback.
   - Source persists with `SourceEvidenceLevel` so prompt assembler labels reliability.
   - Right-side panel surfaces the source; chat references it via citable chips.
   - Source-learning memory captures takeaways into the recall loop.
2. Keep own-corpus Phase 1 behavior intact — no regressions on CitableContextBuilder, lexical atom retrieval, or fidelity checker.
3. Each phase compiles + `swift test` green before the next phase starts.

## Non-Goals

- Voice/eval/harness changes (Bucket D).
- Any redesign of the YouTube ingestion pipeline beyond what the stash already implemented.
- Any cleanup of stash-era code that is no longer idiomatic; treat the stash as the spec for behavior and adapt only at conflict points.

## Architecture Overview

Three buckets, mapped to three implementation phases:

### Bucket A — Foundation (model + storage + ingestion)

- **`Sources/Nous/Models/SourceMaterial.swift`** — adds `SourceKind.youtube`, `SourceEvidenceLevel` enum (`transcriptBacked` / `geminiVideoAnalysis` / `summaryOnly` / `unknown`), embeds `evidenceLevel` in `SourceMetadata`.
- **`Sources/Nous/Services/NodeStore.swift`** — schema migration: `evidenceLevel` + `materialJSON` columns on the source table.
- **`Sources/Nous/Services/SourceIngestionService.swift`** — `ingestExtractedSource()`, emoji + label helpers for `.youtube`.
- **`Sources/Nous/Services/PromptContextAssembler.swift`** — `pinnedSectionCue()` adds evidence-level label so the LLM sees reliability tier.
- **`Sources/Nous/App/AppEnvironment.swift`** — wires `YouTubeTranscriptService`, `YouTubeLearningSummaryService`, `ActiveBrowserTabURLReader`.
- **Project plumbing:** `project.yml` adds WebKit.framework + `NSAppleEventsUsageDescription`; `Info.plist` mirrors.

### Bucket B — Source learning memory hook

- **`Sources/Nous/Services/SourceLearningMemoryService.swift`** + **`Scheduler`** (new) — captures takeaways from a source-anchored conversation into the memory loop.
- **`Sources/Nous/Services/ContextContinuationService.swift`** — accepts `sourceLearningScheduler` parameter; runs scheduler at turn boundaries when an active source is present.
- **`Sources/Nous/ViewModels/ChatViewModel.swift`** — `activeSourceDiscussionContext` state, `activate(...)` / `clearActiveSource()` methods, scheduler ownership.
- **`Sources/Nous/Services/TurnContracts.swift`** — `sourceLearningDigest` field on the turn output contract.
- **`Sources/Nous/App/AppEnvironment.swift`** — wires `SourceLearningMemoryService` + `Scheduler`.

### Bucket C — RightPanel UI

- **`Sources/Nous/App/ContentView.swift`** — `RightPanelMode` enum (with `.youtube`), `YouTubeLearningViewModel`, `YouTubeLearningPanel` view, `RightPanelLayout` host.
- **`Sources/Nous/Views/ChatArea.swift`** — `rightPanelMode` binding, `rightPanelToggleCapsule`, `SourceMaterialMessageChip` integration, `onYouTube` callback wiring.
- **`Sources/Nous/Views/AttachmentChip.swift`** — `SourceDiscussionLinkChip`, `SourceMaterialMessageChip`.
- **`Sources/Nous/Views/WelcomeView.swift`** — `onYouTubeSummary` action.
- New files (added to project): `RightPanelLayout.swift`, `RightPanelMode.swift`.

## Data Flow

```
WelcomeView.onYouTubeSummary
       │
       ▼
ActiveBrowserTabURLReader ──► YouTubeTranscriptService
       │ (URL)                       │
       │                  fallback ──┴─► YouTubeLearningSummaryService (Gemini video)
       ▼
SourceIngestionService.ingestExtractedSource
       │
       ▼
NodeStore (sources table: evidenceLevel + materialJSON)
       │
       ▼
ChatViewModel.activeSourceDiscussionContext
       │                       │
       ▼                       ▼
RightPanel (YouTubeLearningPanel)   ChatArea (SourceMaterialMessageChip)
       │
       ▼
PromptContextAssembler.pinnedSectionCue (evidence-level label)
       │
       ▼
ChatTurnRunner ──► TurnContracts (sourceLearningDigest)
       │
       ▼
ContextContinuationService ──► SourceLearningMemoryScheduler ──► memory atoms
```

## Conflict Resolution Policy

For every Bucket A/B/C file that has changed on `main` since the stash:

- **Base = the version currently on `youtube-summary-restore` (own-corpus shipped).**
- **Diff source = `git show 932a19c -- <file>` for the YouTube-specific additions.**
- Port the YouTube hooks (new types, parameters, call sites, UI bindings) onto the own-corpus base. Do not regress own-corpus changes (`CitableContextBuilder` lexical lane, planner integration, fidelity checker hooks, anchor postures).
- When ambiguous, the own-corpus version wins on shared concerns; the stash wins on YouTube-specific concerns.

Known conflict-prone files: `PromptContextAssembler.swift`, `NodeStore.swift`, `SourceMaterial.swift`, `ChatViewModel.swift`, `ChatTurnRunner.swift` (callers of these), `AppEnvironment.swift`.

## Implementation Phases

Each phase is one or more commits. `swift test` must be green before moving on.

### Phase 1 — Foundation (Bucket A)

Restore model + storage + ingestion. No UI yet, no learning hook. After this phase, the app compiles, all tests pass, and ingestion plumbing exists but is unreachable from the UI.

1. `git checkout 932a19c -- <Bucket A files>` (excluding ones with conflicts).
2. For conflict files, apply the policy above by hand.
3. `swift build` + `swift test` green.
4. Commit: `Restore YouTube source foundation (Bucket A)`.

### Phase 2 — Learning hook (Bucket B)

Wire source learning memory into the turn loop. Still no UI surface; the hook is dormant until UI activates a source.

1. Same checkout-and-port pattern for Bucket B files.
2. `swift test` green (tests covering `ContextContinuationService` and `TurnContracts`).
3. Commit: `Wire SourceLearningMemoryScheduler into turn loop (Bucket B)`.

### Phase 3 — RightPanel UI (Bucket C)

Surface the feature: Welcome action, RightPanel toggle, source chips, YouTube panel.

1. Add new files to `project.yml` / Xcode project.
2. Checkout-and-port Bucket C files.
3. Confirm WebKit.framework + `NSAppleEventsUsageDescription` are in `project.yml` and `Info.plist`.
4. `swift test` + manual smoke (open app, trigger Welcome → YouTube, paste a URL with transcript, verify panel + chip + chat reply).
5. Commit: `Restore YouTube RightPanel UI (Bucket C)`.

## Testing Strategy

- **Unit:** existing tests for `SourceIngestionService`, `PromptContextAssembler`, `ContextContinuationService`, `ChatViewModel` should restore alongside stash files. Add no new tests in this restoration; behavior matches the stash.
- **Integration:** `swift test` green per phase commit.
- **Manual smoke (Phase 3 only):** YouTube link with English captions → transcript ingest path; YouTube link without captions → Gemini fallback; chat references the source via chip; right panel shows summary; source-learning memory captures a takeaway atom (verify via `MemoryAtomDebug` or whichever surface exists).

## Risks

- **Conflict density underestimated.** Mitigation: phase-by-phase commits keep each conflict surface small; stash diff is the authoritative spec for behavior.
- **Own-corpus regression.** Mitigation: base-on-shipped-own-corpus policy + `swift test` gate per phase.
- **WebKit/AppleEvents permission entitlements.** Mitigation: confirmed both `project.yml` and `Info.plist` carry them before Phase 3 manual smoke.
- **UI files (`ChatArea`, `ContentView`) drifted.** Mitigation: Phase 3 isolates UI conflicts; failure does not block Phase 1/2 value.

## Estimate

~45 files touched, ~2000 LOC restored, 3 commits.

## Open Questions

None blocking. Phase 3 manual smoke will surface anything the stash assumed about RightPanel state that no longer matches the current `ContentView`.
