# Hybrid LLM Routing — Phase 1: Abstraction Lift Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Bead:** `new-york-fxhd` — Hybrid per-mode LLM routing — Phase 1: abstraction lift
**Follow-up bead:** `new-york-gf97` — Phase 1.5 (TurnPlanner + foreground threading; depends on this bead)

**Goal:** Introduce the `LLMRoutingPurpose` enum + a purpose-aware factory on `SettingsViewModel`, and migrate the weekly reflection closure to use them. This is the smallest safe slice that establishes the new abstraction and delivers concrete value (deletes the hardcoded `GeminiLLMService` in `AppEnvironment`'s reflection closure). Zero behavior change.

**Out of scope for this bead — explicitly deferred to Phase 1.5 (`new-york-gf97`):** threading `LLMRoutingPurpose` through `TurnPlanner`, `TurnExecutor`, `TurnSteward`, and `ChatViewModel`. `grep llmServiceProvider Sources` shows 10+ consumer services; touching the foreground path requires updating ChatViewModel/TurnExecutor/TurnSteward init signatures plus their test fixtures, which expands the PR substantially. Phase 1 deliberately stops at the factory + reflection migration.

**Architecture:** A new `LLMRoutingPurpose` enum captures three call-site intents — `.foreground(mode:quickAction:)`, `.judge`, `.reflection`. `SettingsViewModel` gains `makeLLMService(for:openRouterWebSearchEnabled:)` and `provider(for:)` that internally delegate to the existing per-purpose construction (the existing `makeLLMService()` and `makeJudgeLLMService()` become thin pass-through wrappers so SwiftUI display helpers keep compiling). The weekly reflection closure in `AppEnvironment` (lines 295–318) drops its inline `GeminiLLMService(apiKey:)` construction and routes through the new chokepoint with `.reflection`.

**Tech Stack:** Swift, XCTest, existing `LLMService` / `LLMProvider` types in `Sources/Nous/Services/LLMService.swift`, `ModelCatalog` private enum in `SettingsViewModel.swift`. No new dependencies.

**Constraints (do not violate):**
- `Sources/Nous/Resources/anchor.md` is frozen — do not touch.
- `PromptContextAssembler` stays model-agnostic — no per-model prompt forks in Phase 1.
- Per-turn lock — `effectiveMode` is computed once per turn in `TurnPlanner.plan()`; provider selection must use that lock, not switch mid-turn.
- No new model IDs in Phase 1. Adding Opus 4.7 to `ModelCatalog` is Phase 2.
- Reflection continues running on Gemini 2.5 Pro after the migration.

---

## Scope Check

This plan covers one connected subsystem: the LLM service factory chokepoint + reflection migration. It deliberately excludes:
- TurnPlanner / TurnExecutor / TurnSteward / ChatViewModel threading — deferred to Phase 1.5 bead `new-york-gf97`.
- Memory / backfill / housekeeping LLM consumers (`UserMemoryService`, `SourceLearningMemoryService`, `ConversationTitleBackfillService`, `MemoryGraphMessageBackfillService`, `GalaxyRelationJudge`, `TurnHousekeepingService`, `YouTubeLearningSummaryService`) — these have their own implicit purposes; defer until a later phase.
- Phase 2 (actual per-mode Opus 4.7 / Sonnet 4.6 model selection — separate bead).
- Adding Opus 4.7 to `ModelCatalog` (deferred to Phase 2).
- Anchor / prompt edits (anchor is frozen; prompt is model-agnostic).
- `BehaviorEvalRunner` / `ProvocationFixtureRunner` — these CLIs read provider config independently and are not on the foreground / judge / reflection paths. Out of scope.

## File Structure

**Create:**
- `Sources/Nous/Services/LLMRoutingPurpose.swift` — the new enum + `Equatable`/`Sendable` conformance.
- `Tests/NousTests/LLMRoutingPurposeTests.swift` — purpose enum equality + Sendable smoke tests.
- `Tests/NousTests/SettingsViewModelLLMRoutingTests.swift` — assertions that `makeLLMService(for:)` and `provider(for:)` return the same service / provider as the existing `makeLLMService()` / `makeJudgeLLMService()` / hardcoded reflection logic for every `(provider × purpose)` combination.

**Modify:**
- `Sources/Nous/ViewModels/SettingsViewModel.swift` — add `makeLLMService(for:openRouterWebSearchEnabled:)` and `provider(for:)`. Keep the existing `makeLLMService()` and `makeJudgeLLMService()` — they become thin wrappers that call the purpose-aware overload, so SwiftUI display helpers (`foregroundModelName`, `judgeModelName`) keep working unchanged.
- `Sources/Nous/App/AppEnvironment.swift` — replace the `reflectionRollover` closure body (lines 295–318) so that line 301's `let llm = GeminiLLMService(apiKey: key)` becomes `guard let llm = settingsVM.makeLLMService(for: .reflection) else { return }`. Lines 240–242 (foreground / judge / current-provider closures) are **untouched in Phase 1** — they remain on the legacy API and are migrated in Phase 1.5.

**No changes to:** `TurnPlanner.swift`, `ChatViewModel.swift`, `TurnExecutor.swift`, `TurnSteward.swift`, or any test fixture under `Tests/NousTests/TurnPlanner*.swift`. Phase 1.5 (`new-york-gf97`) owns those.

---

## Task 1: Define `LLMRoutingPurpose`

**Files:**
- Create: `Sources/Nous/Services/LLMRoutingPurpose.swift`
- Create: `Tests/NousTests/LLMRoutingPurposeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NousTests/LLMRoutingPurposeTests.swift
import XCTest
@testable import Nous

final class LLMRoutingPurposeTests: XCTestCase {
    func test_foreground_equality_byMode() {
        let a = LLMRoutingPurpose.foreground(mode: .companion, quickAction: nil)
        let b = LLMRoutingPurpose.foreground(mode: .companion, quickAction: nil)
        let c = LLMRoutingPurpose.foreground(mode: .strategist, quickAction: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_judge_and_reflection_are_distinct() {
        XCTAssertNotEqual(LLMRoutingPurpose.judge, LLMRoutingPurpose.reflection)
        XCTAssertNotEqual(
            LLMRoutingPurpose.judge,
            LLMRoutingPurpose.foreground(mode: nil, quickAction: nil)
        )
    }

    func test_isSendable_smoke() {
        // Compiles only if Sendable conformance holds.
        let _: any Sendable = LLMRoutingPurpose.judge
    }
}
```

- [ ] **Step 2: Run test to verify it fails to compile**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/LLMRoutingPurposeTests`
Expected: COMPILE FAIL — "cannot find 'LLMRoutingPurpose' in scope"

- [ ] **Step 3: Add the enum**

```swift
// Sources/Nous/Services/LLMRoutingPurpose.swift
import Foundation

/// Identifies the call-site intent for an LLM service request. Phase 1
/// introduces this enum as a single chokepoint; Phase 2 will branch on
/// `.foreground(mode:quickAction:)` to route 倾观点 / Plan / Brainstorm to
/// Opus 4.7 while 日常倾偈 stays on Sonnet 4.6.
enum LLMRoutingPurpose: Equatable, Sendable {
    case foreground(mode: ChatMode?, quickAction: QuickActionMode?)
    case judge
    case reflection
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/LLMRoutingPurposeTests`
Expected: PASS — 3 tests succeed.

- [ ] **Step 5: Run xcodegen + full build**

Run: `xcodegen generate && xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/LLMRoutingPurpose.swift \
        Tests/NousTests/LLMRoutingPurposeTests.swift \
        Nous.xcodeproj/project.pbxproj
git commit -m "Introduce LLMRoutingPurpose enum (Phase 1)"
```

---

## Task 2: Add purpose-aware factory on `SettingsViewModel`

**Files:**
- Modify: `Sources/Nous/ViewModels/SettingsViewModel.swift:285-330`
- Create: `Tests/NousTests/SettingsViewModelLLMRoutingTests.swift`

- [ ] **Step 1: Write the failing tests (parity assertions)**

```swift
// Tests/NousTests/SettingsViewModelLLMRoutingTests.swift
import XCTest
@testable import Nous

@MainActor
final class SettingsViewModelLLMRoutingTests: XCTestCase {

    func test_foregroundPurpose_matchesLegacyMakeLLMService_openrouter() {
        let vm = SettingsViewModel.testFixture(
            provider: .openrouter,
            openrouterApiKey: "test-or"
        )
        let legacy = vm.makeLLMService(openRouterWebSearchEnabled: false)
        let routed = vm.makeLLMService(
            for: .foreground(mode: .companion, quickAction: nil),
            openRouterWebSearchEnabled: false
        )
        XCTAssertEqual(type(of: legacy!) == type(of: routed!), true)
    }

    func test_judgePurpose_matchesLegacyMakeJudgeLLMService_openrouter() {
        let vm = SettingsViewModel.testFixture(
            provider: .openrouter,
            openrouterApiKey: "test-or"
        )
        let legacy = vm.makeJudgeLLMService()
        let routed = vm.makeLLMService(for: .judge)
        XCTAssertEqual(type(of: legacy!) == type(of: routed!), true)
    }

    func test_reflectionPurpose_returnsGeminiServiceWhenKeyPresent() {
        let vm = SettingsViewModel.testFixture(
            provider: .openrouter, // intentionally NOT gemini
            openrouterApiKey: "test-or",
            geminiApiKey: "test-gemini"
        )
        let routed = vm.makeLLMService(for: .reflection)
        XCTAssertNotNil(routed)
        XCTAssertTrue(routed is GeminiLLMService)
    }

    func test_reflectionPurpose_returnsNilWhenGeminiKeyMissing() {
        let vm = SettingsViewModel.testFixture(
            provider: .openrouter,
            openrouterApiKey: "test-or",
            geminiApiKey: ""
        )
        XCTAssertNil(vm.makeLLMService(for: .reflection))
    }

    func test_provider_for_judge_matchesSelectedProvider() {
        let vm = SettingsViewModel.testFixture(provider: .openrouter, openrouterApiKey: "k")
        XCTAssertEqual(vm.provider(for: .judge), .openrouter)
    }

    func test_provider_for_reflection_isAlwaysGemini() {
        let vm = SettingsViewModel.testFixture(provider: .openrouter, openrouterApiKey: "k", geminiApiKey: "g")
        XCTAssertEqual(vm.provider(for: .reflection), .gemini)
    }
}
```

If `SettingsViewModel.testFixture` does not exist, add it in this task as a `#if DEBUG` extension on `SettingsViewModel` inside the test target's helper file (search `Tests/NousTests/` for existing fixture pattern; mirror it). If creating the helper bloats this task, split fixture creation into a sub-step.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/SettingsViewModelLLMRoutingTests`
Expected: COMPILE FAIL — "value of type 'SettingsViewModel' has no member 'makeLLMService(for:openRouterWebSearchEnabled:)'" and "no member 'provider(for:)'".

- [ ] **Step 3: Add the new methods on `SettingsViewModel`**

In `Sources/Nous/ViewModels/SettingsViewModel.swift`, after line 307 (after the existing `makeLLMService()`), add:

```swift
func makeLLMService(
    for purpose: LLMRoutingPurpose,
    openRouterWebSearchEnabled webSearchOverride: Bool? = nil
) -> (any LLMService)? {
    switch purpose {
    case .foreground:
        return makeForegroundLLMService(openRouterWebSearchEnabled: webSearchOverride)
    case .judge:
        return makeJudgeLLMServiceInternal()
    case .reflection:
        return makeReflectionLLMService()
    }
}

func provider(for purpose: LLMRoutingPurpose) -> LLMProvider {
    switch purpose {
    case .foreground, .judge:
        return selectedProvider
    case .reflection:
        return .gemini
    }
}

private func makeReflectionLLMService() -> (any LLMService)? {
    let key = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    return GeminiLLMService(apiKey: key, model: ModelCatalog.geminiForeground)
}
```

Then **rename** the existing `makeLLMService(openRouterWebSearchEnabled:)` body into `private func makeForegroundLLMService(...)`, and rename `makeJudgeLLMService()` body into `private func makeJudgeLLMServiceInternal()`. Keep the public wrappers as thin pass-throughs:

```swift
func makeLLMService(openRouterWebSearchEnabled webSearchOverride: Bool? = nil) -> (any LLMService)? {
    makeForegroundLLMService(openRouterWebSearchEnabled: webSearchOverride)
}

func makeJudgeLLMService() -> (any LLMService)? {
    makeJudgeLLMServiceInternal()
}
```

This keeps every existing call site (SettingsView display helpers, AppEnvironment line 240/242, anywhere else) compiling unchanged.

- [ ] **Step 4: Run new tests + the entire SettingsViewModel test surface**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/SettingsViewModelLLMRoutingTests -only-testing:NousTests/SettingsViewModelTests`
Expected: PASS for all routing tests; existing `SettingsViewModelTests` (if any) unaffected.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/ViewModels/SettingsViewModel.swift \
        Tests/NousTests/SettingsViewModelLLMRoutingTests.swift \
        Nous.xcodeproj/project.pbxproj
git commit -m "Add purpose-aware LLM service factory on SettingsViewModel (Phase 1)"
```

---

## Task 3: Migrate weekly reflection closure to the new chokepoint

**Files:**
- Modify: `Sources/Nous/App/AppEnvironment.swift:295-318`

This is the smallest behavior-equivalent migration and exercises the `.reflection` purpose end-to-end. Doing it before TurnPlanner gives early integration confidence.

- [ ] **Step 1: Replace hardcoded Gemini construction with the new chokepoint**

Edit `Sources/Nous/App/AppEnvironment.swift`. Replace lines 295–318 (the `reflectionRollover` closure):

```swift
let reflectionRollover: @Sendable () async -> Void = { [settingsVM, nodeStore, backgroundAITelemetry] in
    guard settingsVM.backgroundAnalysisEnabled else { return }
    guard let (weekStart, weekEnd) = WeeklyReflectionService.previousCompletedWeek(now: Date())
    else { return }
    guard let llm = await MainActor.run(body: { settingsVM.makeLLMService(for: .reflection) })
    else { return }
    let service = WeeklyReflectionService(
        nodeStore: nodeStore,
        llm: llm,
        backgroundTelemetry: backgroundAITelemetry
    )
    do {
        _ = try await service.runForWeek(
            projectId: nil,
            weekStart: weekStart,
            weekEnd: weekEnd
        )
    } catch {
        // Failure already persisted as a `.failed` row inside the service.
    }
}
```

(Verify whether `settingsVM` access requires `@MainActor` here — if the existing closure already runs cross-actor, mirror its pattern. If lines 297–298 currently read `settingsVM.geminiApiKey` without `MainActor.run`, drop the `MainActor.run` wrapper and call `settingsVM.makeLLMService(for: .reflection)` directly.)

- [ ] **Step 2: Build and confirm no regressions**

Run: `xcodegen generate && xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the WeeklyReflection test surface (if any)**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/WeeklyReflectionServiceTests`
Expected: PASS, OR "No such test" — if the latter, run a slightly broader filter: `-only-testing:NousTests | grep -i reflection`.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/App/AppEnvironment.swift
git commit -m "Migrate weekly reflection to LLMRoutingPurpose chokepoint (Phase 1)"
```

---

## Task 4: Behavioral parity check (verification before claiming done)

**Files:** none (verification only)

This task does not modify code. It exists to catch behavior drift introduced by Tasks 1–3.

- [ ] **Step 1: Run the full test suite cleanly**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' 2>&1 | tail -100`
Expected: `** TEST SUCCEEDED **`. Save the summary line to attach to the bead's verification notes.

- [ ] **Step 2: Run a manual smoke conversation**

Launch the app (xcodegen + xcodebuild build, then run from Xcode or `open` the built `.app`). Have one short conversation with `selectedProvider = .openrouter`. Confirm the provider footer in Settings still reads "OpenRouter Sonnet 4.6" for both foreground and judge.

- [ ] **Step 3: Confirm reflection still routes to Gemini**

In the running app, set `geminiApiKey` to a valid key and `selectedProvider = .openrouter`. Open `~/Library/Application Support/Nous/.../weekly_reflections` (path varies; check `WeeklyReflectionService` for the actual storage location) or rely on the existing telemetry — confirm a reflection run produces a Gemini-shaped response, not an OpenRouter one. If telemetry doesn't expose model IDs, skip this step and rely on Task 3's unit tests.

- [ ] **Step 4: Codex review**

Run: `/codex review` (the user invokes this skill manually) and resolve any findings. Phase 1 is a refactor; Codex is likely to flag any unintended behavior change as `pass` or `revise`. A `revise` verdict blocks shipping.

- [ ] **Step 5: Run beads finish workflow**

Run: `scripts/agentic_workflow_check.sh --bead new-york-fxhd --path docs/superpowers/plans/2026-05-08-hybrid-llm-routing-phase1.md`
Then: `scripts/beads_agent_workflow.sh finish new-york-fxhd "Phase 1 abstraction lift complete: LLMRoutingPurpose chokepoint introduced, all tests pass, Codex review clean, smoke conversation confirms parity."`
Expected: bead transitions to closed; final answer must include `Bead: new-york-fxhd closed`.

---

## Self-Review Checklist

After all tasks complete, before marking the bead closed, the executor must confirm:

1. **Spec coverage**:
   - [x] `LLMRoutingPurpose` enum exists with all three cases — Task 1.
   - [x] `SettingsViewModel.makeLLMService(for:)` and `provider(for:)` exist and have parity tests — Task 2.
   - [x] Reflection closure no longer hardcodes `GeminiLLMService` — Task 3.
   - [x] All existing tests still pass — Task 4 Step 1.
   - [x] Smoke conversation confirms behavior parity — Task 4 Step 2.

2. **Constraint compliance**:
   - [x] `anchor.md` was not touched.
   - [x] No new model IDs in `ModelCatalog`.
   - [x] No prompt forks introduced.
   - [x] Reflection still ends up on Gemini 2.5 Pro.
   - [x] `TurnPlanner.swift`, `TurnExecutor.swift`, `TurnSteward.swift`, `ChatViewModel.swift` are unchanged in this PR — those are Phase 1.5 (`new-york-gf97`) territory.

3. **Phase 1.5 / Phase 2 readiness**:
   - Phase 1.5 (`new-york-gf97`) is the next bead — thread `LLMRoutingPurpose` through `TurnPlanner` (judge entry) and the foreground LLM call sites (`TurnExecutor`, `TurnSteward`, `ChatViewModel`). Without Phase 1.5, Phase 2's per-mode model selection cannot reach the foreground call.
   - Phase 2 (after 1.5) expected diff: (a) extend `ModelCatalog` with Opus 4.7 IDs, (b) branch on `LLMRoutingPurpose.foreground(mode:quickAction:)` inside `makeForegroundLLMService` to pick Opus vs Sonnet model strings, (c) optionally update display helpers. No new types or closure plumbing.
