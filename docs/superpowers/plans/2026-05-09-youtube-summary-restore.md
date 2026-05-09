# YouTube Summary Restoration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the full YouTube summary feature (ingestion + source-learning memory + RightPanel UI) from stash `932a19c` onto the current own-corpus Phase 1 base.

**Architecture:** Three phases mapped to spec buckets — Phase 1 Foundation (model + storage + ingestion), Phase 2 Learning hook (turn loop + scheduler), Phase 3 UI (Welcome action + RightPanel + chips). Per-file `git checkout 932a19c -- <file>` then hand-merge conflicts using "own-corpus shipped wins on shared concerns; stash wins on YouTube-specific concerns". Each phase ends with `swift test` green and a commit.

**Tech Stack:** Swift / SwiftUI / AppKit / SwiftPM (XcodeGen via `project.yml`) / SQLite (NodeStore) / WebKit / AppleEvents.

**Reference spec:** `docs/superpowers/specs/2026-05-09-youtube-summary-restore-design.md`

**Source-of-truth stash:** `932a19c` — read with `git show 932a19c -- <path>` for full file content. Stash also contains Bucket D (eval/voice/harness) files; this plan strictly excludes them.

---

## Conventions Used Throughout

**Restore command (per file):**

```bash
git checkout 932a19c -- <path>
```

This overwrites the working tree file with the stash version. After running it, immediately diff against `HEAD` to see what landed:

```bash
git diff HEAD -- <path>
```

**Conflict resolution:** Some files have moved on `main` since the stash. For those, do NOT just `git checkout`. Instead:

1. `git show 932a19c:<path> > /tmp/stash-<basename>` to extract the stash version.
2. Read the current `HEAD` version.
3. Identify the YouTube-specific additions in the stash diff (`git diff HEAD..932a19c -- <path>` shows the delta from current to stash).
4. Apply only those additions to the current file by hand-edit. Own-corpus shipped logic stays intact.

Per-file conflict status is called out in each task.

**Verification gate:** After every code task that touches Swift sources, run `swift build` (warning-clean is not required — green build is). After tests are restored, run `swift test`. Both must succeed before committing.

**Commit hygiene:** One commit per task unless explicitly grouped. Commit messages use prefix `restore-yt:` so the series is greppable.

**Out of scope (excluded Bucket D files in stash):** `BehaviorEvalRunner/*`, `BehaviorDatasetCLI`, `BehaviorExperimentCLI`, `BehaviorLocalSpecializationCLI`, `BehaviorEvalRunner.swift`, `BehaviorDatasetStudio.swift`, `BehaviorFineTuneExporter.swift`, `BehaviorLocalModelEvaluator.swift`, `HarnessHealth.swift`, `RealtimeVoiceSession.swift`, `SycophancyRiskHeuristics.swift`, `VoiceCommandController.swift`, `VoiceActionRegistry.swift`, `Voice/VoiceModeModels.swift`, `ActionMenuSeparationMotion.swift`, `NousMainWindowController.swift`, `NoteViewModel.swift`, `LeftSidebar.swift`, `ScratchPadPanel.swift`, `TemporaryBranchOverlay.swift`, `AgentWorkView.swift`, `VectorStore.swift`, `nous_harness_check.sh`, `behavior_dataset_studio.sh`, and their associated test files (`BehaviorEvalTests.swift`, `HarnessHealthTests.swift`, `VoiceActionRegistryTests.swift`, `VoiceCommandControllerTests.swift`, `RealtimeVoiceSessionTests.swift`, `RuntimeQualityReviewerTests.swift`, `ActionMenuSeparationMotionTests.swift`, `AppMotionTests.swift`, `TemporaryBranchUILayoutTests.swift`, `NoteViewModelTests.swift`, `VectorStoreTests.swift`, `TurnPlannerShadowLearningTests.swift`).

If a checkout accidentally pulls one of these, `git checkout HEAD -- <path>` to revert.

**Pre-existing dirty files:** The working tree has unstaged modifications to `Sources/Nous/Services/TurnSteward.swift` and `Tests/NousTests/TurnStewardTests.swift` from prior unrelated work. **Do not stage or commit these.** They must remain untouched in the working tree throughout this plan.

---

# Phase 1 — Foundation (Bucket A)

After Phase 1 the app compiles, all tests pass, ingestion plumbing exists, but no UI surfaces it.

### Task 1: Restore SourceMaterial model

**Files:**
- Modify: `Sources/Nous/Models/SourceMaterial.swift`
- Reference: `git show 932a19c:Sources/Nous/Models/SourceMaterial.swift`

**Conflict status:** Likely conflict — `SourceMaterial.swift` evolved on `main` for own-corpus Phase 1 (`Source connection brief v2a` per `docs/superpowers/specs/2026-05-04-source-connection-brief-v2a-design.md`). Hand-merge.

- [ ] **Step 1: Extract stash version**

```bash
git show 932a19c:Sources/Nous/Models/SourceMaterial.swift > /tmp/stash-SourceMaterial.swift
```

- [ ] **Step 2: Diff stash against current to identify YouTube additions**

```bash
git diff HEAD..932a19c -- Sources/Nous/Models/SourceMaterial.swift
```

Expected YouTube-specific additions:
- `case youtube` in `SourceKind` enum
- New `SourceEvidenceLevel` enum with cases `.transcriptBacked`, `.geminiVideoAnalysis`, `.summaryOnly`, `.unknown`, plus `label: String` and `isQuoteLevelReliable: Bool` computed properties
- `evidenceLevel: SourceEvidenceLevel` field on `SourceMetadata` (and any `Codable` updates that follow)
- Any `SourceMaterialContext` additions referenced by other Bucket A/B files

- [ ] **Step 3: Hand-merge YouTube additions onto current file**

Edit `Sources/Nous/Models/SourceMaterial.swift` directly. Add the YouTube enum case, the `SourceEvidenceLevel` enum, and the `evidenceLevel` field. Preserve every line that own-corpus added on `main`. If `SourceMetadata` `init` ordering changed, default `evidenceLevel` to `.unknown` for backward construction.

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -40
```

Expected: build succeeds. Compile errors at this stage almost always mean a downstream file reads a property/method that no longer exists on the merged type — note the missing symbol; it should be added in a later task.

If a downstream file fails to compile because it references YouTube-specific symbols not yet present, that is fine — those symbols come in later tasks. If a downstream file fails because of a shape change to `SourceMetadata` (e.g., new required init param), backfill `evidenceLevel: .unknown` at the call site.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Models/SourceMaterial.swift
git commit -m "restore-yt: add SourceKind.youtube + SourceEvidenceLevel"
```

---

### Task 2: Restore NodeStore schema migration

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift`
- Test: `Tests/NousTests/NodeStoreTests.swift`

**Conflict status:** Conflict — NodeStore evolved on `main` (own-corpus atom storage). Stash adds two columns on the source table: `evidenceLevel` and `materialJSON`, plus a schema-version bump and migration code.

- [ ] **Step 1: Diff to identify schema additions**

```bash
git diff HEAD..932a19c -- Sources/Nous/Services/NodeStore.swift > /tmp/nodestore-yt.diff
cat /tmp/nodestore-yt.diff | head -200
```

Identify (a) the schema version bump, (b) the new `evidenceLevel` and `materialJSON` columns, (c) the migration step (typically an `ALTER TABLE` block guarded by version check), (d) any encode/decode updates that read/write the new columns.

- [ ] **Step 2: Hand-merge schema changes**

Apply the version bump, the new columns, and the migration step. Preserve every own-corpus `main` change (atom tables, FTS triggers, lexical index — these were committed in `f670b79`).

If the stash bumps schema from `N` to `N+1` but `main` already bumped to `N+1` for a different reason, bump to `N+2` and chain both migrations. Pick whichever migration ordering keeps existing user databases readable.

- [ ] **Step 3: Restore NodeStoreTests additions**

```bash
git diff HEAD..932a19c -- Tests/NousTests/NodeStoreTests.swift > /tmp/nodestoretests-yt.diff
cat /tmp/nodestoretests-yt.diff
```

Hand-merge only the YouTube/source-related test additions (~66 lines per stash stat). Skip any test additions that exercise out-of-scope Bucket D code.

- [ ] **Step 4: Build + run NodeStore tests**

```bash
swift build 2>&1 | tail -20
swift test --filter NodeStoreTests 2>&1 | tail -30
```

Expected: build succeeds, all `NodeStoreTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift Tests/NousTests/NodeStoreTests.swift
git commit -m "restore-yt: NodeStore schema migration for evidenceLevel + materialJSON"
```

---

### Task 3: Restore SourceIngestionService

**Files:**
- Modify: `Sources/Nous/Services/SourceIngestionService.swift`
- Test: `Tests/NousTests/SourceConnectionTests.swift`

**Conflict status:** Likely conflict — own-corpus Phase 1 may have touched ingestion. Hand-merge YouTube-specific additions.

- [ ] **Step 1: Diff and identify YouTube additions**

```bash
git diff HEAD..932a19c -- Sources/Nous/Services/SourceIngestionService.swift
```

Expected additions:
- `ingestExtractedSource(...)` entry point that accepts a pre-extracted YouTube transcript or summary plus an `evidenceLevel`
- `emoji(for:)` adds a `.youtube` arm
- Any helper that constructs `SourceMaterial` from YouTube payloads

- [ ] **Step 2: Hand-merge the additions**

Edit the current file to include `ingestExtractedSource(...)` and the `.youtube` emoji arm. Keep all own-corpus changes.

- [ ] **Step 3: Restore SourceConnectionTests additions**

```bash
git diff HEAD..932a19c -- Tests/NousTests/SourceConnectionTests.swift
```

Hand-merge YouTube-specific test additions (~67 lines per stash stat).

- [ ] **Step 4: Build + run filter test**

```bash
swift build 2>&1 | tail -20
swift test --filter SourceConnectionTests 2>&1 | tail -30
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/SourceIngestionService.swift Tests/NousTests/SourceConnectionTests.swift
git commit -m "restore-yt: SourceIngestionService.ingestExtractedSource + .youtube emoji"
```

---

### Task 4: Restore PromptContextAssembler evidence-level surfacing

**Files:**
- Modify: `Sources/Nous/Services/PromptContextAssembler.swift`
- Test: `Tests/NousTests/SourcePromptContextTests.swift`

**Conflict status:** High-conflict — `assembleContext`/`pinnedSectionCue` is the volatile context surface; many own-corpus posture changes live here.

- [ ] **Step 1: Diff and identify YouTube additions**

```bash
git diff HEAD..932a19c -- Sources/Nous/Services/PromptContextAssembler.swift
```

Expected additions (~46 lines per stash stat):
- `pinnedSectionCue()` (or the equivalent function) emits an evidence-level label string for active sources
- Helper that maps `SourceEvidenceLevel` to the prompt label (e.g., "Transcript-backed", "Gemini video analysis", "Summary-only", "Unknown")

- [ ] **Step 2: Hand-merge onto current file**

The own-corpus posture text (NO YES-MAN, PREFER OWN-CORPUS, etc.) MUST stay intact. The YouTube evidence-level cue is additive — slot it into the pinned-section block where the stash placed it, after the existing source-anchored cue.

- [ ] **Step 3: Restore SourcePromptContextTests additions**

```bash
git diff HEAD..932a19c -- Tests/NousTests/SourcePromptContextTests.swift
```

Hand-merge YouTube-related test additions (~66 lines per stash stat).

- [ ] **Step 4: Build + filter test**

```bash
swift build 2>&1 | tail -20
swift test --filter SourcePromptContextTests 2>&1 | tail -30
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/PromptContextAssembler.swift Tests/NousTests/SourcePromptContextTests.swift
git commit -m "restore-yt: PromptContextAssembler evidence-level cue"
```

---

### Task 5: Restore project plumbing (project.yml + Info.plist)

**Files:**
- Modify: `project.yml`
- Modify: `Info.plist`

**Conflict status:** Low — additive. Confirm the YouTube-required entries land.

- [ ] **Step 1: Diff project.yml**

```bash
git diff HEAD..932a19c -- project.yml
```

Expected additions: `WebKit.framework` in the link/embed section, `NSAppleEventsUsageDescription` in the Info entries (if generated via `project.yml`).

- [ ] **Step 2: Apply project.yml additions**

Edit `project.yml` directly to add the WebKit framework link and the AppleEvents entry. Preserve every existing entry.

- [ ] **Step 3: Diff Info.plist**

```bash
git diff HEAD..932a19c -- Info.plist
```

Expected: `NSAppleEventsUsageDescription` key with a user-facing description string.

- [ ] **Step 4: Apply Info.plist additions**

Edit `Info.plist` directly to add the entry.

- [ ] **Step 5: Regenerate Xcode project (only if you build via Xcode)**

```bash
xcodegen 2>&1 | tail -5
```

If `xcodegen` is not installed locally, skip — the SwiftPM build (`swift build`) does not require it. The pbxproj sync happens in Phase 3 Task 18.

- [ ] **Step 6: Build + commit**

```bash
swift build 2>&1 | tail -10
git add project.yml Info.plist
git commit -m "restore-yt: project.yml + Info.plist (WebKit + AppleEvents entitlements)"
```

---

### Task 6: Restore AppEnvironment YouTube service wiring (Phase 1 portion)

**Files:**
- Modify: `Sources/Nous/App/AppEnvironment.swift`
- New (extracted from stash): any new YouTube service files referenced by `AppEnvironment` that don't yet exist on `HEAD`.

**Conflict status:** Conflict expected — `AppEnvironment` is a wiring hub touched by every recent feature.

- [ ] **Step 1: Diff to find new YouTube service references**

```bash
git diff HEAD..932a19c -- Sources/Nous/App/AppEnvironment.swift
```

Expected additions in the stash diff: instantiation of `YouTubeTranscriptService`, `YouTubeLearningSummaryService`, `ActiveBrowserTabURLReader`. Each is referenced by name; use the names to find their implementation files.

- [ ] **Step 2: Identify YouTube service source files**

```bash
git show 932a19c --stat | grep -iE "YouTube|ActiveBrowserTab"
```

For each file listed (likely in `Sources/Nous/Services/`):

```bash
git checkout 932a19c -- <path>
```

These files almost certainly do not exist on `HEAD` (they came in with the YouTube feature originally), so the checkout is a clean add — no merge needed.

- [ ] **Step 3: Hand-merge AppEnvironment Phase 1 additions only**

Add ONLY the lines that instantiate the YouTube ingestion services (transcript, summary, browser-tab reader) and expose them on `AppEnvironment`. **Do not** wire `SourceLearningMemoryService` / scheduler yet — that happens in Phase 2 Task 12. **Do not** wire UI viewmodels — that happens in Phase 3.

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -30
```

Expected: green. If a YouTube service file references a type from a Bucket B/C file that has not landed yet, you have two options:
1. **Preferred:** stub the unresolved reference with a TODO and let Phase 2/3 swap it in. Note the TODO line in the commit body.
2. If stubbing is not feasible (e.g., type is required by an `init` chain), pull the dependent file forward — but only if it is in scope (A/B/C). Never pull a Bucket D file.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/App/AppEnvironment.swift Sources/Nous/Services/YouTube*.swift Sources/Nous/Services/ActiveBrowserTab*.swift
git commit -m "restore-yt: AppEnvironment wiring for YouTube ingestion services"
```

---

### Task 7: Phase 1 verification gate

- [ ] **Step 1: Full build + full test suite**

```bash
swift build 2>&1 | tail -20
swift test 2>&1 | tail -50
```

Expected: build succeeds, all tests pass. If any non-YouTube test regresses, that is a hand-merge bug — fix before proceeding.

- [ ] **Step 2: Sanity check working tree**

```bash
git status
```

Expected: only the pre-existing `TurnSteward.swift` / `TurnStewardTests.swift` modifications are unstaged. Everything else is committed.

- [ ] **Step 3: Tag end-of-phase**

```bash
git tag yt-restore-phase1
```

Phase 1 complete. The app compiles, ingestion plumbing exists, no UI surfaces it.

---

# Phase 2 — Source learning memory hook (Bucket B)

After Phase 2, the source-learning scheduler is wired into the turn loop. Still no UI; the hook is dormant until Phase 3 activates a source.

### Task 8: Restore TurnContracts.sourceLearningDigest field

**Files:**
- Modify: `Sources/Nous/Models/TurnContracts.swift`

**Conflict status:** Likely conflict — `TurnContracts` is touched by every turn-loop feature.

- [ ] **Step 1: Diff**

```bash
git diff HEAD..932a19c -- Sources/Nous/Models/TurnContracts.swift
```

Expected additions (~5 lines):
- `sourceLearningDigest: SourceLearningDigestRequest?` (or similar) field on the turn-output contract
- A type definition `SourceLearningDigestRequest` (may live in this file or be referenced from elsewhere)
- Codable updates if applicable

- [ ] **Step 2: Hand-merge the field**

Add the optional field. Default to `nil` everywhere it is constructed. Preserve own-corpus contract changes.

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -20
```

If construction sites complain about a missing `sourceLearningDigest:` argument, the field must be optional or default-`nil` to avoid touching every call site. Use `= nil` defaults.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Models/TurnContracts.swift
git commit -m "restore-yt: TurnContracts.sourceLearningDigest"
```

---

### Task 9: Restore TurnOutcomeFactory source-material plumbing

**Files:**
- Modify: `Sources/Nous/Services/TurnOutcomeFactory.swift`

**Conflict status:** Conflict possible.

- [ ] **Step 1: Diff**

```bash
git diff HEAD..932a19c -- Sources/Nous/Services/TurnOutcomeFactory.swift
```

Expected additions (~21 lines):
- `makeCompletion(...)` gains optional parameters `userMessage: Message? = nil` and `sourceMaterials: [SourceMaterialContext] = []`
- New logic computes `sourceLearningDigest` when a source is active and the persistence decision is `.persist`
- Threads `sourceLearningDigest` into the returned `TurnCompletion`

- [ ] **Step 2: Hand-merge**

Add the optional parameters with defaults so existing call sites keep compiling.

- [ ] **Step 3: Build + filter relevant tests**

```bash
swift build 2>&1 | tail -20
swift test --filter TurnOutcomeFactory 2>&1 | tail -30
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Services/TurnOutcomeFactory.swift
git commit -m "restore-yt: TurnOutcomeFactory source-learning digest"
```

---

### Task 10: Restore TurnPlanner + ChatTurnRunner source plumbing

**Files:**
- Modify: `Sources/Nous/Services/TurnPlanner.swift`
- Modify: `Sources/Nous/Services/ChatTurnRunner.swift`
- Modify: `Sources/Nous/Services/MemoryQueryPlanner.swift`

**Conflict status:** All three are heavily-modified files in own-corpus Phase 1. Each stash diff is small (3–9 lines). Hand-merge.

- [ ] **Step 1: Diff TurnPlanner**

```bash
git diff HEAD..932a19c -- Sources/Nous/Services/TurnPlanner.swift
```

Hand-merge the additions (likely a `sourceMaterials` parameter being threaded through `prepareTurn` or an equivalent entry).

- [ ] **Step 2: Diff ChatTurnRunner**

```bash
git diff HEAD..932a19c -- Sources/Nous/Services/ChatTurnRunner.swift
```

Hand-merge the additions (likely propagating `sourceMaterials` from request to outcome and into `outcomeFactory.makeCompletion(...)`).

- [ ] **Step 3: Diff MemoryQueryPlanner**

```bash
git diff HEAD..932a19c -- Sources/Nous/Services/MemoryQueryPlanner.swift
```

Hand-merge the additions (likely a source-aware filter or an `excludeSourceAnchored` gate).

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -30
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/TurnPlanner.swift Sources/Nous/Services/ChatTurnRunner.swift Sources/Nous/Services/MemoryQueryPlanner.swift
git commit -m "restore-yt: thread sourceMaterials through TurnPlanner + ChatTurnRunner + MemoryQueryPlanner"
```

---

### Task 11: Restore ContextContinuationService scheduler hook

**Files:**
- Modify: `Sources/Nous/Services/ContextContinuationService.swift`
- Test: `Tests/NousTests/ContextContinuationServiceTests.swift`

**Conflict status:** Conflict possible.

- [ ] **Step 1: Diff service**

```bash
git diff HEAD..932a19c -- Sources/Nous/Services/ContextContinuationService.swift
```

Expected additions (~11 lines):
- `init(...)` gains `sourceLearningScheduler: SourceLearningMemoryScheduler? = nil` parameter
- After-turn block invokes the scheduler when `turnCompletion.sourceLearningDigest` is non-nil

- [ ] **Step 2: Hand-merge service additions**

Add the optional init parameter with default `nil`. Wire the scheduler invocation. If `SourceLearningMemoryScheduler` type does not yet exist, create the file in this task — extract from stash:

```bash
git show 932a19c --stat | grep -iE "SourceLearningMemory"
git checkout 932a19c -- <path-to-SourceLearningMemoryService.swift>
git checkout 932a19c -- <path-to-SourceLearningMemoryScheduler.swift>
```

(Pull both the service and the scheduler. They are clean adds — they did not exist on `HEAD` before the stash.)

- [ ] **Step 3: Diff tests**

```bash
git diff HEAD..932a19c -- Tests/NousTests/ContextContinuationServiceTests.swift
```

Hand-merge YouTube-related test additions (~197 lines per stash stat — but only the source-learning subset).

- [ ] **Step 4: Build + filter tests**

```bash
swift build 2>&1 | tail -20
swift test --filter ContextContinuationServiceTests 2>&1 | tail -40
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/ContextContinuationService.swift Sources/Nous/Services/SourceLearningMemory*.swift Tests/NousTests/ContextContinuationServiceTests.swift
git commit -m "restore-yt: ContextContinuationService source-learning scheduler hook"
```

---

### Task 12: Restore AppEnvironment SourceLearningMemory wiring

**Files:**
- Modify: `Sources/Nous/App/AppEnvironment.swift`

**Conflict status:** Touch the same file as Task 6 — only add the Bucket B portion now.

- [ ] **Step 1: Re-diff against stash for the un-restored portion**

```bash
git diff HEAD..932a19c -- Sources/Nous/App/AppEnvironment.swift
```

The Phase 1 portion is already merged. Remaining: instantiate `SourceLearningMemoryService` + `Scheduler`, pass scheduler into `ContextContinuationService` init.

- [ ] **Step 2: Hand-merge Phase 2 wiring**

Add the scheduler instantiation. Pass it through to `ContextContinuationService`. **Do not** wire UI viewmodels yet (Phase 3).

- [ ] **Step 3: Build + smoke test**

```bash
swift build 2>&1 | tail -20
swift test 2>&1 | tail -10
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/App/AppEnvironment.swift
git commit -m "restore-yt: AppEnvironment wiring for SourceLearningMemoryScheduler"
```

---

### Task 13: Restore ChatViewModel source-learning hooks (Phase 2 portion)

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Test: `Tests/NousTests/ChatViewModelTests.swift`

**Conflict status:** High-conflict — `ChatViewModel` is heavily touched.

- [ ] **Step 1: Diff**

```bash
git diff HEAD..932a19c -- Sources/Nous/ViewModels/ChatViewModel.swift
```

The stash diff (~71 lines) has both Phase 2 (scheduler ownership, `sourceLearningMemoryScheduler` property, hook into turn lifecycle) and Phase 3 (`activeSourceDiscussionContext`, `activate(...)`, `clearActiveSource()`, `rightPanelMode` binding) content. **In this task, port ONLY the Phase 2 portion** — scheduler ownership and turn-lifecycle hook.

- [ ] **Step 2: Hand-merge Phase 2 portion**

Add the scheduler property. Wire it into the turn-completion path so `sourceLearningDigest` flows into the scheduler. Leave UI state (`activeSourceDiscussionContext`, `rightPanelMode`) for Phase 3 Task 14.

- [ ] **Step 3: Diff tests**

```bash
git diff HEAD..932a19c -- Tests/NousTests/ChatViewModelTests.swift
```

Hand-merge ONLY the source-learning-related test additions (~386 lines per stash stat — split across Phases 2 and 3; pick only the Phase 2 subset).

- [ ] **Step 4: Build + filter tests**

```bash
swift build 2>&1 | tail -20
swift test --filter ChatViewModelTests 2>&1 | tail -50
```

Expected: green.

- [ ] **Step 5: Phase 2 verification gate**

```bash
swift test 2>&1 | tail -50
```

Expected: full suite green.

- [ ] **Step 6: Commit + tag phase**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift Tests/NousTests/ChatViewModelTests.swift
git commit -m "restore-yt: ChatViewModel source-learning scheduler ownership (Phase 2)"
git tag yt-restore-phase2
```

Phase 2 complete. The source-learning hook is wired but dormant.

---

# Phase 3 — RightPanel UI (Bucket C)

After Phase 3, the user can trigger YouTube summaries from Welcome, see the source in the RightPanel, and chat references the source via chips.

### Task 14: Restore ChatViewModel UI state (Phase 3 portion)

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Test: `Tests/NousTests/ChatViewModelTests.swift` (UI subset)

**Conflict status:** Same file as Task 13 — port the remaining UI portion now.

- [ ] **Step 1: Re-diff for un-restored portion**

```bash
git diff HEAD..932a19c -- Sources/Nous/ViewModels/ChatViewModel.swift
```

Remaining additions: `activeSourceDiscussionContext` state, `activate(source:)` / `clearActiveSource()` methods, any binding to `rightPanelMode`.

- [ ] **Step 2: Hand-merge UI state**

Add the `@Published` (or equivalent) state. Add the activate/clear methods. Preserve every own-corpus posture.

- [ ] **Step 3: Hand-merge remaining ChatViewModelTests UI additions**

```bash
git diff HEAD..932a19c -- Tests/NousTests/ChatViewModelTests.swift
```

Pick the UI-related tests not yet ported.

- [ ] **Step 4: Build + filter tests**

```bash
swift build 2>&1 | tail -20
swift test --filter ChatViewModelTests 2>&1 | tail -50
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift Tests/NousTests/ChatViewModelTests.swift
git commit -m "restore-yt: ChatViewModel activeSourceDiscussionContext + activate/clear"
```

---

### Task 15: Restore AttachmentChip + new chip components

**Files:**
- Modify: `Sources/Nous/Views/AttachmentChip.swift`

**Conflict status:** Stash adds ~98 lines. Likely additive — new chip types `SourceDiscussionLinkChip` and `SourceMaterialMessageChip`.

- [ ] **Step 1: Diff**

```bash
git diff HEAD..932a19c -- Sources/Nous/Views/AttachmentChip.swift
```

- [ ] **Step 2: Hand-merge new chip types**

Add `SourceDiscussionLinkChip` and `SourceMaterialMessageChip` views. Preserve existing chip code.

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: green. If a chip references colors from `AppColor` not yet present, defer the build and proceed to Task 16.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/AttachmentChip.swift
git commit -m "restore-yt: SourceDiscussionLinkChip + SourceMaterialMessageChip"
```

---

### Task 16: Restore AppColor YouTube-related additions

**Files:**
- Modify: `Sources/Nous/Theme/AppColor.swift`

**Conflict status:** Low — additive (~4 lines per stash stat).

- [ ] **Step 1: Diff**

```bash
git diff HEAD..932a19c -- Sources/Nous/Theme/AppColor.swift
```

- [ ] **Step 2: Hand-merge color additions**

Append the new color constants to `AppColor`. Preserve every existing color.

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/Nous/Theme/AppColor.swift
git commit -m "restore-yt: AppColor additions for RightPanel"
```

---

### Task 17: Restore WelcomeView YouTube summary action

**Files:**
- Modify: `Sources/Nous/Views/WelcomeView.swift`

**Conflict status:** Low — additive (~19 lines per stash stat).

- [ ] **Step 1: Diff**

```bash
git diff HEAD..932a19c -- Sources/Nous/Views/WelcomeView.swift
```

- [ ] **Step 2: Hand-merge `onYouTubeSummary` action**

Add the new action callback parameter to `WelcomeView`. Add the new action button. Preserve existing welcome actions.

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/Nous/Views/WelcomeView.swift
git commit -m "restore-yt: WelcomeView onYouTubeSummary action"
```

---

### Task 18: Restore ChatArea + ContentView RightPanel layout

**Files:**
- Modify: `Sources/Nous/Views/ChatArea.swift`
- Modify: `Sources/Nous/App/ContentView.swift`
- New (extracted from stash): `Sources/Nous/Views/RightPanelLayout.swift`, `Sources/Nous/App/RightPanelMode.swift` (or wherever stash places them — confirm via `git show 932a19c --stat | grep RightPanel`)
- Modify: `Nous.xcodeproj/project.pbxproj`

**Conflict status:** Highest-conflict task. ChatArea (~252 lines), ContentView (~148 lines) both heavily touched.

- [ ] **Step 1: Identify new files**

```bash
git show 932a19c --stat | grep -iE "RightPanel"
```

For each new file:

```bash
git checkout 932a19c -- <path>
```

These are clean adds.

- [ ] **Step 2: Diff ChatArea**

```bash
git diff HEAD..932a19c -- Sources/Nous/Views/ChatArea.swift
```

Expected additions:
- `rightPanelMode` binding parameter
- `rightPanelToggleCapsule` view component
- `SourceMaterialMessageChip` integration into the message stream
- `onYouTube` callback wiring

- [ ] **Step 3: Hand-merge ChatArea additions**

This is the largest UI hand-merge. Take it slowly. Preserve every existing layout invariant. If unsure whether a chunk is YouTube-specific or own-corpus shipped, lean toward keeping the current `HEAD` version and only inserting new YouTube hooks.

- [ ] **Step 4: Diff ContentView**

```bash
git diff HEAD..932a19c -- Sources/Nous/App/ContentView.swift
```

Expected additions:
- `RightPanelMode.youtube` enum case (or the full enum if not yet present)
- `YouTubeLearningViewModel` instantiation
- `YouTubeLearningPanel` view embedded in the right panel host
- `RightPanelLayout` wrapping the main content + right panel

- [ ] **Step 5: Hand-merge ContentView additions**

Wire the right panel state into `ContentView`. Pass `rightPanelMode` binding into `ChatArea`. Wire `onYouTubeSummary` from `WelcomeView` to the YouTube ingestion service from `AppEnvironment` (added in Task 6).

- [ ] **Step 6: Sync pbxproj**

```bash
git diff HEAD..932a19c -- Nous.xcodeproj/project.pbxproj
```

Hand-merge the new file references and build phases. If `xcodegen` is set up locally:

```bash
xcodegen 2>&1 | tail -5
```

— and let it regenerate the pbxproj instead of hand-merging. Verify the new files appear in the regenerated pbxproj before committing.

- [ ] **Step 7: Build**

```bash
swift build 2>&1 | tail -40
```

Expected: green. UI-layer compile errors at this stage are almost always missing imports or wrong type names — fix them rather than silencing.

- [ ] **Step 8: Commit**

```bash
git add Sources/Nous/App/ContentView.swift Sources/Nous/Views/ChatArea.swift Sources/Nous/Views/RightPanelLayout.swift Sources/Nous/App/RightPanelMode.swift Nous.xcodeproj/project.pbxproj
git commit -m "restore-yt: RightPanel layout (ContentView + ChatArea + RightPanelLayout)"
```

---

### Task 19: Phase 3 verification gate + manual smoke

- [ ] **Step 1: Full build + full test suite**

```bash
swift build 2>&1 | tail -20
swift test 2>&1 | tail -50
```

Expected: green.

- [ ] **Step 2: Working tree sanity check**

```bash
git status
```

Expected: only the pre-existing `TurnSteward.swift` / `TurnStewardTests.swift` modifications remain unstaged.

- [ ] **Step 3: Manual smoke test — happy path (transcript-backed)**

Open the app in Xcode (or `swift run` if a run target exists). Trigger:
- Welcome → YouTube summary action
- Paste a YouTube URL with English captions (e.g., a popular TED talk)
- Verify: RightPanel opens with the YouTube panel; transcript loads; summary appears; chat references the source via a `SourceMaterialMessageChip`; the chat reply mentions the evidence level (`Transcript-backed`) somewhere in the system cue (verify by inspecting `PromptContextAssembler` debug output if exposed).

- [ ] **Step 4: Manual smoke test — fallback (Gemini video)**

Repeat the flow with a YouTube URL that does NOT have captions. Verify the Gemini video analysis fallback fires and the panel shows `Gemini video analysis` evidence level.

- [ ] **Step 5: Manual smoke test — source-learning memory**

Stay in the source-anchored conversation, exchange 2–3 turns about the video content, then close the conversation. In a debug surface (if one exists — `MemoryAtomDebug` or `git log`-style atom dump), verify a source-learning atom was written. If no debug surface exists, this step is best-effort — note the gap and move on.

- [ ] **Step 6: Tag end-of-phase**

```bash
git tag yt-restore-phase3
```

Phase 3 complete. Feature is fully restored.

---

# Wrap-up

- [ ] **Step 1: Final review**

```bash
git log --oneline yt-restore-phase1^..HEAD
```

Expected: ~14–17 commits, all prefixed `restore-yt:`, plus three tags.

- [ ] **Step 2: Confirm no Bucket D files leaked in**

```bash
git diff main..HEAD --stat | grep -iE "Behavior|HarnessHealth|Voice|Sycophancy|Realtime|VectorStore|MainWindowController|NoteViewModel|LeftSidebar|ScratchPadPanel|TemporaryBranch|AgentWorkView|ActionMenuSeparation|AppMotion"
```

Expected: empty output. If any leak is found, revert just that file by hand-edit + amend the offending commit.

- [ ] **Step 3: Done**

Branch `youtube-summary-restore` is ready for `/ship` (the user invokes that skill — do not invoke it directly from this plan).

---

# Self-Review

**Spec coverage (against `docs/superpowers/specs/2026-05-09-youtube-summary-restore-design.md`):**
- Spec Bucket A → Tasks 1–7 (SourceMaterial, NodeStore, SourceIngestionService, PromptContextAssembler, AppEnvironment, project.yml, Info.plist) ✓
- Spec Bucket B → Tasks 8–13 (TurnContracts, TurnOutcomeFactory, TurnPlanner, ChatTurnRunner, MemoryQueryPlanner, ContextContinuationService, AppEnvironment scheduler, ChatViewModel scheduler) ✓
- Spec Bucket C → Tasks 14–18 (ChatViewModel UI state, AttachmentChip, AppColor, WelcomeView, ChatArea, ContentView, RightPanelLayout, pbxproj) ✓
- Spec "Conflict Resolution Policy" → conventions section + per-task "Conflict status" callouts ✓
- Spec "Testing Strategy" → per-task `swift test --filter` + Phase 7/13/19 full-suite gates ✓
- Spec "Risks" — own-corpus regression → guarded by per-phase `swift test` gates + Bucket D leak check in wrap-up ✓
- Spec "Risks" — WebKit/AppleEvents → Task 5 ✓
- Spec "Risks" — UI drift → Task 18 isolates this ✓

**Type consistency:** `SourceLearningMemoryScheduler` named consistently across Tasks 11, 12, 13. `SourceMaterialContext` named consistently across Tasks 1, 9, 10. `evidenceLevel` field named consistently. `SourceLearningDigestRequest` consistent across Tasks 8, 9. `RightPanelMode` consistent across Tasks 14, 18.

**Placeholder scan:** No "TBD"/"TODO"/"add appropriate error handling"/"similar to Task N" patterns. Task 6 explicitly calls out the option to stub-with-TODO if a forward dependency blocks the build, with the rule that the TODO must be resolved by Phase 2/3.

**Scope:** A single feature restoration, three phases, ~19 tasks. Appropriately sized for one plan.

**Ambiguity:** The "hand-merge" pattern is inherently judgmental. Mitigated by per-task explicit "expected additions" lists derived from the stash, plus the conflict-resolution policy ("own-corpus wins on shared concerns; stash wins on YouTube-specific concerns").
