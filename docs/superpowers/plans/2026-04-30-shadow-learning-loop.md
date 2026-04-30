# Shadow Learning Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a heartbeat-driven Shadow Learning Loop that learns low-risk thinking moves and response behavior, gently injects relevant hints into future prompts, and decays stale patterns without modifying `anchor.md`.

**Architecture:** Add a local SQLite-backed `ShadowLearningStore`, deterministic signal extraction, lifecycle/decay logic, a heartbeat coordinator, and a prompt provider wired into `TurnPlanner` and `PromptContextAssembler`. Keep learning in volatile prompt context only, capped to three hints per turn.

**Tech Stack:** Swift, SwiftUI, XCTest, raw SQLite through the existing `Database`/`NodeStore` pattern, `@Observable` view models where UI changes are needed.

---

## Scope Check

This plan covers one connected subsystem: Shadow Learning. It touches persistence, background scheduling, prompt assembly, and debug visibility because those are required for one end-to-end learning loop. It deliberately excludes a visible approval inbox, deep personality inference, model fine-tuning, and any edit to `Sources/Nous/Resources/anchor.md`.

## File Structure

- Create `Sources/Nous/Models/ShadowLearningPattern.swift` for pattern/event enums and value types.
- Create `Sources/Nous/Services/ShadowPatternLifecycle.swift` for deterministic promotion, decay, correction, retirement, and revival.
- Create `Sources/Nous/Services/ShadowLearningStore.swift` for SQLite reads/writes over `shadow_patterns`, `learning_events`, and `shadow_learning_state`.
- Create `Sources/Nous/Services/ShadowLearningSignalRecorder.swift` for cheap per-message signal capture.
- Create `Sources/Nous/Services/ShadowLearningSteward.swift` for daily and weekly learning work.
- Create `Sources/Nous/Services/HeartbeatCoordinator.swift` for idle-delayed background scheduling.
- Create `Sources/Nous/Services/ShadowPatternPromptProvider.swift` for selecting at most three relevant prompt hints.
- Modify `Sources/Nous/Services/NodeStore.swift` to create the three new tables and indexes.
- Modify `Sources/Nous/Services/PromptContextAssembler.swift` to accept and render shadow hints in volatile context.
- Modify `Sources/Nous/Services/TurnPlanner.swift` to request shadow hints after route/mode inference.
- Modify `Sources/Nous/Services/ChatTurnRunner.swift` to record immediate user-message signals after a user message is persisted.
- Modify `Sources/Nous/App/AppEnvironment.swift` to construct and pass the new services.
- Modify `Sources/Nous/App/ContentView.swift` to schedule heartbeat maintenance when background analysis is enabled.
- Modify `Sources/Nous/Views/MemoryDebugInspector.swift` to show shadow patterns and learning events in the existing debug surface.
- Add focused XCTest files under `Tests/NousTests/`.

---

### Task 1: Add Shadow Learning Models and Lifecycle

**Files:**
- Create: `Sources/Nous/Models/ShadowLearningPattern.swift`
- Create: `Sources/Nous/Services/ShadowPatternLifecycle.swift`
- Test: `Tests/NousTests/ShadowPatternLifecycleTests.swift`

- [ ] **Step 1: Write failing lifecycle tests**

Create `Tests/NousTests/ShadowPatternLifecycleTests.swift`:

```swift
import XCTest
@testable import Nous

final class ShadowPatternLifecycleTests: XCTestCase {
    func testObservedPatternPromotesToSoftAfterEnoughEvidence() {
        let now = Date(timeIntervalSince1970: 10_000)
        let pattern = ShadowLearningPattern(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001001")!,
            userId: "alex",
            kind: .thinkingMove,
            label: "first_principles_decision_frame",
            summary: "Use first principles for product and architecture judgment.",
            promptFragment: "For product or architecture judgment, start from the base constraint before comparing existing patterns.",
            triggerHint: "product architecture decision first principles",
            confidence: 0.62,
            weight: 0.22,
            status: .observed,
            evidenceMessageIds: [
                UUID(uuidString: "00000000-0000-0000-0000-000000001101")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000001102")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000001103")!
            ],
            firstSeenAt: now.addingTimeInterval(-3600),
            lastSeenAt: now,
            lastReinforcedAt: now,
            lastCorrectedAt: nil,
            activeFrom: nil,
            activeUntil: nil
        )

        let updated = ShadowPatternLifecycle.afterReinforcement(pattern, at: now)

        XCTAssertEqual(updated.status, .soft)
        XCTAssertGreaterThanOrEqual(updated.confidence, 0.70)
        XCTAssertGreaterThanOrEqual(updated.weight, 0.30)
        XCTAssertEqual(updated.activeFrom, now)
    }

    func testCorrectionWeakensPatternAndSuppressesRecentInjection() {
        let now = Date(timeIntervalSince1970: 20_000)
        let pattern = strongPattern(lastCorrectedAt: nil)

        let corrected = ShadowPatternLifecycle.afterCorrection(pattern, at: now)

        XCTAssertEqual(corrected.status, .fading)
        XCTAssertLessThan(corrected.weight, pattern.weight)
        XCTAssertEqual(corrected.lastCorrectedAt, now)
        XCTAssertFalse(ShadowPatternLifecycle.isPromptEligible(corrected, now: now))
    }

    func testStaleStrongPatternFadesAfterThirtyDays() {
        let now = Date(timeIntervalSince1970: 90 * 86_400)
        let pattern = strongPattern(lastCorrectedAt: nil).copy(
            lastReinforcedAt: now.addingTimeInterval(-31 * 86_400),
            lastSeenAt: now.addingTimeInterval(-31 * 86_400)
        )

        let decayed = ShadowPatternLifecycle.afterDecay(pattern, at: now)

        XCTAssertEqual(decayed.status, .fading)
        XCTAssertLessThan(decayed.weight, pattern.weight)
    }

    func testLowWeightStalePatternRetiresAfterSixtyDays() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let pattern = strongPattern(lastCorrectedAt: nil).copy(
            weight: 0.12,
            status: .fading,
            lastReinforcedAt: now.addingTimeInterval(-61 * 86_400),
            lastSeenAt: now.addingTimeInterval(-61 * 86_400)
        )

        let decayed = ShadowPatternLifecycle.afterDecay(pattern, at: now)

        XCTAssertEqual(decayed.status, .retired)
        XCTAssertEqual(decayed.activeUntil, now)
    }

    func testEligiblePatternRequiresSoftOrStrongAndRecentCorrectionGap() {
        let now = Date(timeIntervalSince1970: 30_000)
        let eligible = strongPattern(lastCorrectedAt: now.addingTimeInterval(-8 * 86_400))
        let recentlyCorrected = strongPattern(lastCorrectedAt: now.addingTimeInterval(-2 * 86_400))
        let observed = strongPattern(lastCorrectedAt: nil).copy(status: .observed)

        XCTAssertTrue(ShadowPatternLifecycle.isPromptEligible(eligible, now: now))
        XCTAssertFalse(ShadowPatternLifecycle.isPromptEligible(recentlyCorrected, now: now))
        XCTAssertFalse(ShadowPatternLifecycle.isPromptEligible(observed, now: now))
    }

    private func strongPattern(lastCorrectedAt: Date?) -> ShadowLearningPattern {
        let now = Date(timeIntervalSince1970: 20_000)
        return ShadowLearningPattern(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001002")!,
            userId: "alex",
            kind: .thinkingMove,
            label: "pain_test_for_product_scope",
            summary: "Use the pain test before adding scope.",
            promptFragment: "For product scope, ask whether absence would genuinely hurt before expanding the feature.",
            triggerHint: "product scope feature pain test",
            confidence: 0.88,
            weight: 0.72,
            status: .strong,
            evidenceMessageIds: [
                UUID(uuidString: "00000000-0000-0000-0000-000000001201")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000001202")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000001203")!
            ],
            firstSeenAt: now.addingTimeInterval(-10 * 86_400),
            lastSeenAt: now,
            lastReinforcedAt: now,
            lastCorrectedAt: lastCorrectedAt,
            activeFrom: now.addingTimeInterval(-5 * 86_400),
            activeUntil: nil
        )
    }
}

private extension ShadowLearningPattern {
    func copy(
        confidence: Double? = nil,
        weight: Double? = nil,
        status: ShadowPatternStatus? = nil,
        lastSeenAt: Date? = nil,
        lastReinforcedAt: Date? = nil,
        lastCorrectedAt: Date?? = nil,
        activeFrom: Date?? = nil,
        activeUntil: Date?? = nil
    ) -> ShadowLearningPattern {
        ShadowLearningPattern(
            id: id,
            userId: userId,
            kind: kind,
            label: label,
            summary: summary,
            promptFragment: promptFragment,
            triggerHint: triggerHint,
            confidence: confidence ?? self.confidence,
            weight: weight ?? self.weight,
            status: status ?? self.status,
            evidenceMessageIds: evidenceMessageIds,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt ?? self.lastSeenAt,
            lastReinforcedAt: lastReinforcedAt ?? self.lastReinforcedAt,
            lastCorrectedAt: lastCorrectedAt ?? self.lastCorrectedAt,
            activeFrom: activeFrom ?? self.activeFrom,
            activeUntil: activeUntil ?? self.activeUntil
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowPatternLifecycleTests
```

Expected: FAIL with errors for missing `ShadowLearningPattern`, `ShadowPatternStatus`, and `ShadowPatternLifecycle`.

- [ ] **Step 3: Add model types**

Create `Sources/Nous/Models/ShadowLearningPattern.swift`:

```swift
import Foundation

enum ShadowPatternKind: String, Codable, CaseIterable {
    case thinkingMove = "thinking_move"
    case responseBehavior = "response_behavior"
}

enum ShadowPatternStatus: String, Codable, CaseIterable {
    case observed
    case soft
    case strong
    case fading
    case retired
}

enum LearningEventType: String, Codable, CaseIterable {
    case observed
    case reinforced
    case corrected
    case weakened
    case promoted
    case retired
    case revived
}

struct ShadowLearningPattern: Identifiable, Equatable, Codable {
    let id: UUID
    let userId: String
    let kind: ShadowPatternKind
    let label: String
    let summary: String
    let promptFragment: String
    let triggerHint: String
    let confidence: Double
    let weight: Double
    let status: ShadowPatternStatus
    let evidenceMessageIds: [UUID]
    let firstSeenAt: Date
    let lastSeenAt: Date
    let lastReinforcedAt: Date?
    let lastCorrectedAt: Date?
    let activeFrom: Date?
    let activeUntil: Date?
}

struct LearningEvent: Identifiable, Equatable, Codable {
    let id: UUID
    let userId: String
    let patternId: UUID?
    let sourceMessageId: UUID?
    let eventType: LearningEventType
    let note: String
    let createdAt: Date
}

struct ShadowLearningState: Equatable {
    let userId: String
    let lastRunAt: Date?
    let lastScannedMessageAt: Date?
    let lastConsolidatedAt: Date?
}
```

- [ ] **Step 4: Add lifecycle rules**

Create `Sources/Nous/Services/ShadowPatternLifecycle.swift`:

```swift
import Foundation

enum ShadowPatternLifecycle {
    static let correctionSuppressionWindow: TimeInterval = 7 * 86_400
    static let fadeAfter: TimeInterval = 30 * 86_400
    static let retireAfter: TimeInterval = 60 * 86_400

    static func afterObservation(
        _ pattern: ShadowLearningPattern,
        evidenceMessageId: UUID,
        at now: Date
    ) -> ShadowLearningPattern {
        var evidence = pattern.evidenceMessageIds
        if !evidence.contains(evidenceMessageId) {
            evidence.append(evidenceMessageId)
        }

        let confidence = clamped(pattern.confidence + 0.06)
        let weight = clamped(pattern.weight + 0.05)

        return ShadowLearningPattern(
            id: pattern.id,
            userId: pattern.userId,
            kind: pattern.kind,
            label: pattern.label,
            summary: pattern.summary,
            promptFragment: pattern.promptFragment,
            triggerHint: pattern.triggerHint,
            confidence: confidence,
            weight: weight,
            status: promotedStatus(
                current: pattern.status,
                confidence: confidence,
                weight: weight,
                evidenceCount: evidence.count
            ),
            evidenceMessageIds: evidence,
            firstSeenAt: pattern.firstSeenAt,
            lastSeenAt: now,
            lastReinforcedAt: now,
            lastCorrectedAt: pattern.lastCorrectedAt,
            activeFrom: pattern.activeFrom ?? (weight >= 0.30 ? now : nil),
            activeUntil: nil
        )
    }

    static func afterReinforcement(
        _ pattern: ShadowLearningPattern,
        at now: Date
    ) -> ShadowLearningPattern {
        let confidence = clamped(max(pattern.confidence + 0.08, pattern.evidenceMessageIds.count >= 3 ? 0.70 : pattern.confidence))
        let weight = clamped(max(pattern.weight + 0.08, pattern.evidenceMessageIds.count >= 3 ? 0.30 : pattern.weight))
        let status = promotedStatus(
            current: pattern.status,
            confidence: confidence,
            weight: weight,
            evidenceCount: pattern.evidenceMessageIds.count
        )

        return ShadowLearningPattern(
            id: pattern.id,
            userId: pattern.userId,
            kind: pattern.kind,
            label: pattern.label,
            summary: pattern.summary,
            promptFragment: pattern.promptFragment,
            triggerHint: pattern.triggerHint,
            confidence: confidence,
            weight: weight,
            status: status,
            evidenceMessageIds: pattern.evidenceMessageIds,
            firstSeenAt: pattern.firstSeenAt,
            lastSeenAt: now,
            lastReinforcedAt: now,
            lastCorrectedAt: pattern.lastCorrectedAt,
            activeFrom: pattern.activeFrom ?? (status == .soft || status == .strong ? now : nil),
            activeUntil: nil
        )
    }

    static func afterCorrection(
        _ pattern: ShadowLearningPattern,
        at now: Date
    ) -> ShadowLearningPattern {
        ShadowLearningPattern(
            id: pattern.id,
            userId: pattern.userId,
            kind: pattern.kind,
            label: pattern.label,
            summary: pattern.summary,
            promptFragment: pattern.promptFragment,
            triggerHint: pattern.triggerHint,
            confidence: clamped(pattern.confidence - 0.18),
            weight: clamped(pattern.weight - 0.30),
            status: pattern.status == .retired ? .retired : .fading,
            evidenceMessageIds: pattern.evidenceMessageIds,
            firstSeenAt: pattern.firstSeenAt,
            lastSeenAt: pattern.lastSeenAt,
            lastReinforcedAt: pattern.lastReinforcedAt,
            lastCorrectedAt: now,
            activeFrom: pattern.activeFrom,
            activeUntil: pattern.activeUntil
        )
    }

    static func afterDecay(
        _ pattern: ShadowLearningPattern,
        at now: Date
    ) -> ShadowLearningPattern {
        guard pattern.status != .retired else { return pattern }
        let lastUseful = pattern.lastReinforcedAt ?? pattern.lastSeenAt
        let age = now.timeIntervalSince(lastUseful)

        if age >= retireAfter && pattern.weight < 0.20 {
            return ShadowLearningPattern(
                id: pattern.id,
                userId: pattern.userId,
                kind: pattern.kind,
                label: pattern.label,
                summary: pattern.summary,
                promptFragment: pattern.promptFragment,
                triggerHint: pattern.triggerHint,
                confidence: pattern.confidence,
                weight: pattern.weight,
                status: .retired,
                evidenceMessageIds: pattern.evidenceMessageIds,
                firstSeenAt: pattern.firstSeenAt,
                lastSeenAt: pattern.lastSeenAt,
                lastReinforcedAt: pattern.lastReinforcedAt,
                lastCorrectedAt: pattern.lastCorrectedAt,
                activeFrom: pattern.activeFrom,
                activeUntil: now
            )
        }

        guard age >= fadeAfter else { return pattern }
        return ShadowLearningPattern(
            id: pattern.id,
            userId: pattern.userId,
            kind: pattern.kind,
            label: pattern.label,
            summary: pattern.summary,
            promptFragment: pattern.promptFragment,
            triggerHint: pattern.triggerHint,
            confidence: clamped(pattern.confidence - 0.08),
            weight: clamped(pattern.weight - 0.12),
            status: .fading,
            evidenceMessageIds: pattern.evidenceMessageIds,
            firstSeenAt: pattern.firstSeenAt,
            lastSeenAt: pattern.lastSeenAt,
            lastReinforcedAt: pattern.lastReinforcedAt,
            lastCorrectedAt: pattern.lastCorrectedAt,
            activeFrom: pattern.activeFrom,
            activeUntil: pattern.activeUntil
        )
    }

    static func isPromptEligible(_ pattern: ShadowLearningPattern, now: Date) -> Bool {
        guard pattern.status == .soft || pattern.status == .strong else { return false }
        guard pattern.confidence >= 0.65 else { return false }
        guard pattern.weight >= 0.25 else { return false }
        if let lastCorrectedAt = pattern.lastCorrectedAt,
           now.timeIntervalSince(lastCorrectedAt) < correctionSuppressionWindow {
            return false
        }
        return true
    }

    private static func promotedStatus(
        current: ShadowPatternStatus,
        confidence: Double,
        weight: Double,
        evidenceCount: Int
    ) -> ShadowPatternStatus {
        if current == .retired { return .soft }
        if evidenceCount >= 5 && confidence >= 0.82 && weight >= 0.55 { return .strong }
        if evidenceCount >= 3 && confidence >= 0.65 && weight >= 0.30 { return .soft }
        return current == .fading ? .soft : current
    }

    private static func clamped(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}
```

- [ ] **Step 5: Run lifecycle tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowPatternLifecycleTests
```

Expected: PASS.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/Nous/Models/ShadowLearningPattern.swift Sources/Nous/Services/ShadowPatternLifecycle.swift Tests/NousTests/ShadowPatternLifecycleTests.swift
git commit -m "feat: add shadow learning lifecycle"
```

---

### Task 2: Add SQLite Tables and ShadowLearningStore

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift`
- Create: `Sources/Nous/Services/ShadowLearningStore.swift`
- Test: `Tests/NousTests/ShadowLearningStoreTests.swift`

- [ ] **Step 1: Write failing store tests**

Create `Tests/NousTests/ShadowLearningStoreTests.swift`:

```swift
import XCTest
@testable import Nous

final class ShadowLearningStoreTests: XCTestCase {
    func testInsertFetchAndUpdatePattern() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let now = Date(timeIntervalSince1970: 1_000)
        let pattern = makePattern(now: now)

        try store.upsertPattern(pattern)
        var fetched = try store.fetchPatterns(userId: "alex")

        XCTAssertEqual(fetched, [pattern])

        let updated = ShadowPatternLifecycle.afterCorrection(pattern, at: now.addingTimeInterval(60))
        try store.upsertPattern(updated)
        fetched = try store.fetchPatterns(userId: "alex")

        XCTAssertEqual(fetched, [updated])
    }

    func testAppendAndFetchLearningEvents() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let event = LearningEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000002001")!,
            userId: "alex",
            patternId: UUID(uuidString: "00000000-0000-0000-0000-000000002101")!,
            sourceMessageId: UUID(uuidString: "00000000-0000-0000-0000-000000002201")!,
            eventType: .observed,
            note: "Detected first-principles wording.",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        try store.appendEvent(event)
        let events = try store.fetchRecentEvents(userId: "alex", limit: 10)

        XCTAssertEqual(events, [event])
    }

    func testLearningStateRoundTrip() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let state = ShadowLearningState(
            userId: "alex",
            lastRunAt: Date(timeIntervalSince1970: 3_000),
            lastScannedMessageAt: Date(timeIntervalSince1970: 3_100),
            lastConsolidatedAt: Date(timeIntervalSince1970: 3_200)
        )

        try store.saveState(state)
        let fetched = try store.fetchState(userId: "alex")

        XCTAssertEqual(fetched, state)
    }

    func testFetchPromptEligiblePatternsFiltersRetiredAndRecentCorrections() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let now = Date(timeIntervalSince1970: 10_000)
        let eligible = makePattern(now: now).copy(status: .soft, confidence: 0.76, weight: 0.44)
        let retired = makePattern(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000002102")!,
            label: "retired_pattern",
            now: now
        ).copy(status: .retired, confidence: 0.90, weight: 0.90)
        let corrected = makePattern(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000002103")!,
            label: "recently_corrected",
            now: now
        ).copy(status: .strong, confidence: 0.90, weight: 0.90, lastCorrectedAt: now)

        try store.upsertPattern(eligible)
        try store.upsertPattern(retired)
        try store.upsertPattern(corrected)

        let fetched = try store.fetchPromptEligiblePatterns(userId: "alex", now: now, limit: 5)

        XCTAssertEqual(fetched.map(\.id), [eligible.id])
    }

    private func makePattern(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000002101")!,
        label: String = "first_principles_decision_frame",
        now: Date
    ) -> ShadowLearningPattern {
        ShadowLearningPattern(
            id: id,
            userId: "alex",
            kind: .thinkingMove,
            label: label,
            summary: "Use first principles for decisions.",
            promptFragment: "Start from the base constraint before comparing patterns.",
            triggerHint: "product architecture decision first principles",
            confidence: 0.70,
            weight: 0.35,
            status: .soft,
            evidenceMessageIds: [
                UUID(uuidString: "00000000-0000-0000-0000-000000002301")!
            ],
            firstSeenAt: now,
            lastSeenAt: now,
            lastReinforcedAt: now,
            lastCorrectedAt: nil,
            activeFrom: now,
            activeUntil: nil
        )
    }
}

private extension ShadowLearningPattern {
    func copy(
        status: ShadowPatternStatus? = nil,
        confidence: Double? = nil,
        weight: Double? = nil,
        lastCorrectedAt: Date?? = nil
    ) -> ShadowLearningPattern {
        ShadowLearningPattern(
            id: id,
            userId: userId,
            kind: kind,
            label: label,
            summary: summary,
            promptFragment: promptFragment,
            triggerHint: triggerHint,
            confidence: confidence ?? self.confidence,
            weight: weight ?? self.weight,
            status: status ?? self.status,
            evidenceMessageIds: evidenceMessageIds,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            lastReinforcedAt: lastReinforcedAt,
            lastCorrectedAt: lastCorrectedAt ?? self.lastCorrectedAt,
            activeFrom: activeFrom,
            activeUntil: activeUntil
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowLearningStoreTests
```

Expected: FAIL with missing `ShadowLearningStore` and missing database tables.

- [ ] **Step 3: Add schema to NodeStore**

In `Sources/Nous/Services/NodeStore.swift`, inside `createTables()` after the `skills` table block, add:

```swift
        try db.exec("""
            CREATE TABLE IF NOT EXISTS shadow_patterns (
                id                   TEXT PRIMARY KEY,
                user_id              TEXT NOT NULL DEFAULT 'alex',
                kind                 TEXT NOT NULL,
                label                TEXT NOT NULL,
                summary              TEXT NOT NULL,
                prompt_fragment      TEXT NOT NULL,
                trigger_hint         TEXT NOT NULL,
                confidence           REAL NOT NULL DEFAULT 0,
                weight               REAL NOT NULL DEFAULT 0,
                status               TEXT NOT NULL,
                evidence_message_ids TEXT NOT NULL DEFAULT '[]',
                first_seen_at        REAL NOT NULL,
                last_seen_at         REAL NOT NULL,
                last_reinforced_at   REAL,
                last_corrected_at    REAL,
                active_from          REAL,
                active_until         REAL
            );
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS learning_events (
                id                TEXT PRIMARY KEY,
                user_id           TEXT NOT NULL DEFAULT 'alex',
                pattern_id        TEXT REFERENCES shadow_patterns(id) ON DELETE SET NULL,
                source_message_id TEXT REFERENCES messages(id) ON DELETE SET NULL,
                event_type        TEXT NOT NULL,
                note              TEXT NOT NULL DEFAULT '',
                created_at        REAL NOT NULL
            );
        """)

        try db.exec("""
            CREATE TABLE IF NOT EXISTS shadow_learning_state (
                user_id                 TEXT PRIMARY KEY,
                last_run_at             REAL,
                last_scanned_message_at REAL,
                last_consolidated_at    REAL
            );
        """)
```

In the indexes block, add:

```swift
        try db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_shadow_patterns_user_kind_label ON shadow_patterns(user_id, kind, label);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_shadow_patterns_user_status ON shadow_patterns(user_id, status);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_learning_events_user_created ON learning_events(user_id, created_at);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_learning_events_pattern ON learning_events(pattern_id);")
```

- [ ] **Step 4: Add ShadowLearningStore**

Create `Sources/Nous/Services/ShadowLearningStore.swift`:

```swift
import Foundation

protocol ShadowLearningStoring {
    func fetchPatterns(userId: String) throws -> [ShadowLearningPattern]
    func fetchPattern(userId: String, kind: ShadowPatternKind, label: String) throws -> ShadowLearningPattern?
    func fetchPromptEligiblePatterns(userId: String, now: Date, limit: Int) throws -> [ShadowLearningPattern]
    func upsertPattern(_ pattern: ShadowLearningPattern) throws
    func appendEvent(_ event: LearningEvent) throws
    func fetchRecentEvents(userId: String, limit: Int) throws -> [LearningEvent]
    func fetchState(userId: String) throws -> ShadowLearningState
    func saveState(_ state: ShadowLearningState) throws
}

final class ShadowLearningStore: ShadowLearningStoring {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func fetchPatterns(userId: String) throws -> [ShadowLearningPattern] {
        let stmt = try database.prepare("""
            SELECT id, user_id, kind, label, summary, prompt_fragment, trigger_hint,
                   confidence, weight, status, evidence_message_ids,
                   first_seen_at, last_seen_at, last_reinforced_at, last_corrected_at,
                   active_from, active_until
            FROM shadow_patterns
            WHERE user_id = ?
            ORDER BY weight DESC, confidence DESC, last_seen_at DESC;
        """)
        try stmt.bind(userId, at: 1)
        var patterns: [ShadowLearningPattern] = []
        while try stmt.step() {
            if let pattern = pattern(from: stmt) {
                patterns.append(pattern)
            }
        }
        return patterns
    }

    func fetchPattern(userId: String, kind: ShadowPatternKind, label: String) throws -> ShadowLearningPattern? {
        let stmt = try database.prepare("""
            SELECT id, user_id, kind, label, summary, prompt_fragment, trigger_hint,
                   confidence, weight, status, evidence_message_ids,
                   first_seen_at, last_seen_at, last_reinforced_at, last_corrected_at,
                   active_from, active_until
            FROM shadow_patterns
            WHERE user_id = ? AND kind = ? AND label = ?
            LIMIT 1;
        """)
        try stmt.bind(userId, at: 1)
        try stmt.bind(kind.rawValue, at: 2)
        try stmt.bind(label, at: 3)
        guard try stmt.step() else { return nil }
        return pattern(from: stmt)
    }

    func fetchPromptEligiblePatterns(userId: String, now: Date, limit: Int) throws -> [ShadowLearningPattern] {
        let stmt = try database.prepare("""
            SELECT id, user_id, kind, label, summary, prompt_fragment, trigger_hint,
                   confidence, weight, status, evidence_message_ids,
                   first_seen_at, last_seen_at, last_reinforced_at, last_corrected_at,
                   active_from, active_until
            FROM shadow_patterns
            WHERE user_id = ?
              AND status IN ('soft', 'strong')
              AND confidence >= 0.65
              AND weight >= 0.25
            ORDER BY weight DESC, confidence DESC, last_seen_at DESC
            LIMIT ?;
        """)
        try stmt.bind(userId, at: 1)
        try stmt.bind(limit * 3, at: 2)

        var patterns: [ShadowLearningPattern] = []
        while try stmt.step() {
            if let pattern = pattern(from: stmt),
               ShadowPatternLifecycle.isPromptEligible(pattern, now: now) {
                patterns.append(pattern)
                if patterns.count == limit {
                    break
                }
            }
        }
        return patterns
    }

    func upsertPattern(_ pattern: ShadowLearningPattern) throws {
        let evidenceJSON = encodeUUIDs(pattern.evidenceMessageIds)
        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                INSERT INTO shadow_patterns (
                    id, user_id, kind, label, summary, prompt_fragment, trigger_hint,
                    confidence, weight, status, evidence_message_ids,
                    first_seen_at, last_seen_at, last_reinforced_at, last_corrected_at,
                    active_from, active_until
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, kind, label) DO UPDATE SET
                    summary = excluded.summary,
                    prompt_fragment = excluded.prompt_fragment,
                    trigger_hint = excluded.trigger_hint,
                    confidence = excluded.confidence,
                    weight = excluded.weight,
                    status = excluded.status,
                    evidence_message_ids = excluded.evidence_message_ids,
                    last_seen_at = excluded.last_seen_at,
                    last_reinforced_at = excluded.last_reinforced_at,
                    last_corrected_at = excluded.last_corrected_at,
                    active_from = excluded.active_from,
                    active_until = excluded.active_until;
            """)
            try bind(pattern, evidenceJSON: evidenceJSON, to: stmt)
            try stmt.step()
        }
    }

    func appendEvent(_ event: LearningEvent) throws {
        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                INSERT INTO learning_events (
                    id, user_id, pattern_id, source_message_id, event_type, note, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
            try stmt.bind(event.id.uuidString, at: 1)
            try stmt.bind(event.userId, at: 2)
            try stmt.bind(event.patternId?.uuidString, at: 3)
            try stmt.bind(event.sourceMessageId?.uuidString, at: 4)
            try stmt.bind(event.eventType.rawValue, at: 5)
            try stmt.bind(event.note, at: 6)
            try stmt.bind(event.createdAt.timeIntervalSince1970, at: 7)
            try stmt.step()
        }
    }

    func fetchRecentEvents(userId: String, limit: Int) throws -> [LearningEvent] {
        let stmt = try database.prepare("""
            SELECT id, user_id, pattern_id, source_message_id, event_type, note, created_at
            FROM learning_events
            WHERE user_id = ?
            ORDER BY created_at DESC
            LIMIT ?;
        """)
        try stmt.bind(userId, at: 1)
        try stmt.bind(limit, at: 2)
        var events: [LearningEvent] = []
        while try stmt.step() {
            if let event = event(from: stmt) {
                events.append(event)
            }
        }
        return events
    }

    func fetchState(userId: String) throws -> ShadowLearningState {
        let stmt = try database.prepare("""
            SELECT user_id, last_run_at, last_scanned_message_at, last_consolidated_at
            FROM shadow_learning_state
            WHERE user_id = ?
            LIMIT 1;
        """)
        try stmt.bind(userId, at: 1)
        guard try stmt.step() else {
            return ShadowLearningState(
                userId: userId,
                lastRunAt: nil,
                lastScannedMessageAt: nil,
                lastConsolidatedAt: nil
            )
        }
        return ShadowLearningState(
            userId: stmt.text(at: 0) ?? userId,
            lastRunAt: dateOrNil(stmt, at: 1),
            lastScannedMessageAt: dateOrNil(stmt, at: 2),
            lastConsolidatedAt: dateOrNil(stmt, at: 3)
        )
    }

    func saveState(_ state: ShadowLearningState) throws {
        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                INSERT INTO shadow_learning_state (
                    user_id, last_run_at, last_scanned_message_at, last_consolidated_at
                )
                VALUES (?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    last_run_at = excluded.last_run_at,
                    last_scanned_message_at = excluded.last_scanned_message_at,
                    last_consolidated_at = excluded.last_consolidated_at;
            """)
            try stmt.bind(state.userId, at: 1)
            try stmt.bind(state.lastRunAt?.timeIntervalSince1970, at: 2)
            try stmt.bind(state.lastScannedMessageAt?.timeIntervalSince1970, at: 3)
            try stmt.bind(state.lastConsolidatedAt?.timeIntervalSince1970, at: 4)
            try stmt.step()
        }
    }

    private var database: Database {
        nodeStore.rawDatabase
    }

    private func bind(_ pattern: ShadowLearningPattern, evidenceJSON: String, to stmt: Statement) throws {
        try stmt.bind(pattern.id.uuidString, at: 1)
        try stmt.bind(pattern.userId, at: 2)
        try stmt.bind(pattern.kind.rawValue, at: 3)
        try stmt.bind(pattern.label, at: 4)
        try stmt.bind(pattern.summary, at: 5)
        try stmt.bind(pattern.promptFragment, at: 6)
        try stmt.bind(pattern.triggerHint, at: 7)
        try stmt.bind(pattern.confidence, at: 8)
        try stmt.bind(pattern.weight, at: 9)
        try stmt.bind(pattern.status.rawValue, at: 10)
        try stmt.bind(evidenceJSON, at: 11)
        try stmt.bind(pattern.firstSeenAt.timeIntervalSince1970, at: 12)
        try stmt.bind(pattern.lastSeenAt.timeIntervalSince1970, at: 13)
        try stmt.bind(pattern.lastReinforcedAt?.timeIntervalSince1970, at: 14)
        try stmt.bind(pattern.lastCorrectedAt?.timeIntervalSince1970, at: 15)
        try stmt.bind(pattern.activeFrom?.timeIntervalSince1970, at: 16)
        try stmt.bind(pattern.activeUntil?.timeIntervalSince1970, at: 17)
    }

    private func pattern(from stmt: Statement) -> ShadowLearningPattern? {
        guard let idText = stmt.text(at: 0), let id = UUID(uuidString: idText) else { return nil }
        guard let kindText = stmt.text(at: 2), let kind = ShadowPatternKind(rawValue: kindText) else { return nil }
        guard let statusText = stmt.text(at: 9), let status = ShadowPatternStatus(rawValue: statusText) else { return nil }
        return ShadowLearningPattern(
            id: id,
            userId: stmt.text(at: 1) ?? "alex",
            kind: kind,
            label: stmt.text(at: 3) ?? "",
            summary: stmt.text(at: 4) ?? "",
            promptFragment: stmt.text(at: 5) ?? "",
            triggerHint: stmt.text(at: 6) ?? "",
            confidence: stmt.double(at: 7),
            weight: stmt.double(at: 8),
            status: status,
            evidenceMessageIds: decodeUUIDs(stmt.text(at: 10) ?? "[]"),
            firstSeenAt: Date(timeIntervalSince1970: stmt.double(at: 11)),
            lastSeenAt: Date(timeIntervalSince1970: stmt.double(at: 12)),
            lastReinforcedAt: dateOrNil(stmt, at: 13),
            lastCorrectedAt: dateOrNil(stmt, at: 14),
            activeFrom: dateOrNil(stmt, at: 15),
            activeUntil: dateOrNil(stmt, at: 16)
        )
    }

    private func event(from stmt: Statement) -> LearningEvent? {
        guard let idText = stmt.text(at: 0), let id = UUID(uuidString: idText) else { return nil }
        guard let typeText = stmt.text(at: 4), let type = LearningEventType(rawValue: typeText) else { return nil }
        return LearningEvent(
            id: id,
            userId: stmt.text(at: 1) ?? "alex",
            patternId: stmt.text(at: 2).flatMap(UUID.init(uuidString:)),
            sourceMessageId: stmt.text(at: 3).flatMap(UUID.init(uuidString:)),
            eventType: type,
            note: stmt.text(at: 5) ?? "",
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 6))
        )
    }

    private func dateOrNil(_ stmt: Statement, at index: Int32) -> Date? {
        stmt.isNull(at: index) ? nil : Date(timeIntervalSince1970: stmt.double(at: index))
    }

    private func encodeUUIDs(_ ids: [UUID]) -> String {
        let strings = ids.map(\.uuidString)
        guard let data = try? JSONSerialization.data(withJSONObject: strings),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private func decodeUUIDs(_ json: String) -> [UUID] {
        guard let data = json.data(using: .utf8),
              let strings = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return strings.compactMap(UUID.init(uuidString:))
    }
}
```

- [ ] **Step 5: Run store tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowLearningStoreTests
```

Expected: PASS.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/Nous/Services/NodeStore.swift Sources/Nous/Services/ShadowLearningStore.swift Tests/NousTests/ShadowLearningStoreTests.swift
git commit -m "feat: persist shadow learning patterns"
```

---

### Task 3: Add Immediate Signal Recorder

**Files:**
- Create: `Sources/Nous/Services/ShadowLearningSignalRecorder.swift`
- Modify: `Sources/Nous/Services/ChatTurnRunner.swift`
- Test: `Tests/NousTests/ShadowLearningSignalRecorderTests.swift`
- Test: `Tests/NousTests/ChatTurnRunnerShadowLearningTests.swift`

- [ ] **Step 1: Write failing recorder tests**

Create `Tests/NousTests/ShadowLearningSignalRecorderTests.swift`:

```swift
import XCTest
@testable import Nous

final class ShadowLearningSignalRecorderTests: XCTestCase {
    func testRecordsFirstPrinciplesObservation() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let recorder = ShadowLearningSignalRecorder(store: store)
        let message = Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000003001")!,
            nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000003101")!,
            role: .user,
            content: "先用 first principles 拆一下这个产品判断",
            timestamp: Date(timeIntervalSince1970: 1_000)
        )

        try recorder.recordSignals(from: message, userId: "alex")

        let patterns = try store.fetchPatterns(userId: "alex")
        XCTAssertEqual(patterns.count, 1)
        XCTAssertEqual(patterns[0].label, "first_principles_decision_frame")
        XCTAssertEqual(patterns[0].status, .observed)
        XCTAssertEqual(patterns[0].evidenceMessageIds, [message.id])

        let events = try store.fetchRecentEvents(userId: "alex", limit: 10)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, .observed)
        XCTAssertEqual(events[0].sourceMessageId, message.id)
    }

    func testCorrectionWeakensMatchingPattern() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let recorder = ShadowLearningSignalRecorder(store: store)
        let now = Date(timeIntervalSince1970: 2_000)
        try store.upsertPattern(
            ShadowLearningPattern(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000003201")!,
                userId: "alex",
                kind: .thinkingMove,
                label: "first_principles_decision_frame",
                summary: "Use first principles for product and architecture judgment.",
                promptFragment: "For product or architecture judgment, start from the base constraint before comparing existing patterns.",
                triggerHint: "product architecture decision first principles",
                confidence: 0.86,
                weight: 0.65,
                status: .strong,
                evidenceMessageIds: [],
                firstSeenAt: now.addingTimeInterval(-1_000),
                lastSeenAt: now.addingTimeInterval(-100),
                lastReinforcedAt: now.addingTimeInterval(-100),
                lastCorrectedAt: nil,
                activeFrom: now.addingTimeInterval(-500),
                activeUntil: nil
            )
        )
        let correction = Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000003002")!,
            nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000003102")!,
            role: .user,
            content: "这次别用第一性原理，先给我直觉判断",
            timestamp: now
        )

        try recorder.recordSignals(from: correction, userId: "alex")

        let pattern = try XCTUnwrap(store.fetchPattern(
            userId: "alex",
            kind: .thinkingMove,
            label: "first_principles_decision_frame"
        ))
        XCTAssertEqual(pattern.status, .fading)
        XCTAssertEqual(pattern.lastCorrectedAt, now)
        XCTAssertLessThan(pattern.weight, 0.65)

        let events = try store.fetchRecentEvents(userId: "alex", limit: 10)
        XCTAssertEqual(events.first?.eventType, .corrected)
    }
}
```

- [ ] **Step 2: Run recorder tests to verify they fail**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowLearningSignalRecorderTests
```

Expected: FAIL with missing `ShadowLearningSignalRecorder`.

- [ ] **Step 3: Implement deterministic signal recorder**

Create `Sources/Nous/Services/ShadowLearningSignalRecorder.swift`:

```swift
import Foundation

final class ShadowLearningSignalRecorder {
    private let store: any ShadowLearningStoring

    init(store: any ShadowLearningStoring) {
        self.store = store
    }

    func recordSignals(from message: Message, userId: String = "alex") throws {
        guard message.role == .user else { return }
        let text = message.content.lowercased()
        let now = message.timestamp

        if isCorrection(text, for: "first_principles_decision_frame"),
           let existing = try store.fetchPattern(userId: userId, kind: .thinkingMove, label: "first_principles_decision_frame") {
            let updated = ShadowPatternLifecycle.afterCorrection(existing, at: now)
            try store.upsertPattern(updated)
            try store.appendEvent(LearningEvent(
                id: UUID(),
                userId: userId,
                patternId: updated.id,
                sourceMessageId: message.id,
                eventType: .corrected,
                note: "User asked not to use first-principles framing in this context.",
                createdAt: now
            ))
            return
        }

        for definition in Self.definitions where definition.matches(text) {
            try recordObservation(definition, message: message, userId: userId, now: now)
        }
    }

    private func recordObservation(
        _ definition: ShadowPatternDefinition,
        message: Message,
        userId: String,
        now: Date
    ) throws {
        let existing = try store.fetchPattern(userId: userId, kind: definition.kind, label: definition.label)
        let base = existing ?? ShadowLearningPattern(
            id: UUID(),
            userId: userId,
            kind: definition.kind,
            label: definition.label,
            summary: definition.summary,
            promptFragment: definition.promptFragment,
            triggerHint: definition.triggerHint,
            confidence: 0.45,
            weight: 0.12,
            status: .observed,
            evidenceMessageIds: [],
            firstSeenAt: now,
            lastSeenAt: now,
            lastReinforcedAt: nil,
            lastCorrectedAt: nil,
            activeFrom: nil,
            activeUntil: nil
        )
        let updated = ShadowPatternLifecycle.afterObservation(base, evidenceMessageId: message.id, at: now)
        try store.upsertPattern(updated)
        try store.appendEvent(LearningEvent(
            id: UUID(),
            userId: userId,
            patternId: updated.id,
            sourceMessageId: message.id,
            eventType: existing == nil ? .observed : .reinforced,
            note: definition.eventNote,
            createdAt: now
        ))
    }

    private func isCorrection(_ text: String, for label: String) -> Bool {
        switch label {
        case "first_principles_decision_frame":
            return (text.contains("别用") || text.contains("不要") || text.contains("not use") || text.contains("don't use")) &&
                (text.contains("第一性原理") || text.contains("first principle"))
        default:
            return false
        }
    }

    private static let definitions: [ShadowPatternDefinition] = [
        ShadowPatternDefinition(
            kind: .thinkingMove,
            label: "first_principles_decision_frame",
            summary: "Use first principles for product and architecture judgment.",
            promptFragment: "For product or architecture judgment, start from the base constraint before comparing existing patterns.",
            triggerHint: "product architecture decision first principles",
            keywords: ["first principles", "first-principles", "第一性原理", "底层", "本质"],
            eventNote: "Detected first-principles wording."
        ),
        ShadowPatternDefinition(
            kind: .thinkingMove,
            label: "inversion_before_recommendation",
            summary: "Use inversion before recommending a path.",
            promptFragment: "Before recommending, name the worst version of the decision and avoid it.",
            triggerHint: "decision recommendation inversion worst version",
            keywords: ["inversion", "反过来", "最坏", "worst version"],
            eventNote: "Detected inversion wording."
        ),
        ShadowPatternDefinition(
            kind: .thinkingMove,
            label: "pain_test_for_product_scope",
            summary: "Use the pain test before adding product scope.",
            promptFragment: "For product scope, ask whether absence would genuinely hurt before expanding the feature.",
            triggerHint: "product scope feature pain test",
            keywords: ["pain test", "会痛", "痛不痛", "absence would hurt"],
            eventNote: "Detected pain-test wording."
        ),
        ShadowPatternDefinition(
            kind: .responseBehavior,
            label: "concrete_over_generic",
            summary: "Prefer concrete references over generic guidance.",
            promptFragment: "Prefer concrete tradeoffs, files, decisions, and examples over generic encouragement.",
            triggerHint: "concrete specific generic advice",
            keywords: ["generic", "太泛", "具体", "concrete"],
            eventNote: "Detected concrete-over-generic feedback."
        ),
        ShadowPatternDefinition(
            kind: .responseBehavior,
            label: "direct_pushback_when_wrong",
            summary: "Push back plainly when the user's framing is wrong.",
            promptFragment: "If the framing is wrong, say so plainly and name the missing distinction.",
            triggerHint: "push back disagree direct wrong framing",
            keywords: ["push back", "直接说", "不要顺着我", "disagree"],
            eventNote: "Detected direct-pushback preference."
        ),
        ShadowPatternDefinition(
            kind: .responseBehavior,
            label: "organize_before_judging",
            summary: "Organize messy thinking before giving judgment.",
            promptFragment: "When the user's thought is tangled, first organize the pieces, then give judgment.",
            triggerHint: "organize messy thought clarify before judgment",
            keywords: ["我说不清", "帮我整理", "梳理", "organize"],
            eventNote: "Detected organize-before-judging preference."
        )
    ]
}

private struct ShadowPatternDefinition {
    let kind: ShadowPatternKind
    let label: String
    let summary: String
    let promptFragment: String
    let triggerHint: String
    let keywords: [String]
    let eventNote: String

    func matches(_ lowercasedText: String) -> Bool {
        keywords.contains { lowercasedText.contains($0.lowercased()) }
    }
}
```

- [ ] **Step 4: Run recorder tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowLearningSignalRecorderTests
```

Expected: PASS.

- [ ] **Step 5: Inject recorder into ChatTurnRunner**

Modify `Sources/Nous/Services/ChatTurnRunner.swift`.

Add a property:

```swift
    private let shadowLearningSignalRecorder: ShadowLearningSignalRecorder?
```

Add an initializer parameter:

```swift
        shadowLearningSignalRecorder: ShadowLearningSignalRecorder? = nil,
```

Assign it in `init`:

```swift
        self.shadowLearningSignalRecorder = shadowLearningSignalRecorder
```

In `runPreparedTurn`, immediately after `let stewardship = turnSteward.steer(prepared: prepared, request: request)`, add:

```swift
        if let shadowLearningSignalRecorder {
            do {
                try shadowLearningSignalRecorder.recordSignals(from: prepared.userMessage)
            } catch {
                print("[ShadowLearning] failed to record user signal: \(error)")
            }
        }
```

- [ ] **Step 6: Add runner integration test**

Create `Tests/NousTests/ChatTurnRunnerShadowLearningTests.swift`:

```swift
import XCTest
@testable import Nous

final class ChatTurnRunnerShadowLearningTests: XCTestCase {
    func testRunnerRecordsShadowSignalAfterPreparingUserTurn() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let shadowStore = ShadowLearningStore(nodeStore: nodeStore)
        let recorder = ShadowLearningSignalRecorder(store: shadowStore)
        let conversationStore = ConversationSessionStore(nodeStore: nodeStore)
        let planner = makePlanner(nodeStore: nodeStore)
        let executor = TurnExecutor(
            llmServiceProvider: { FixedLLMService(output: "Done\n<chat_title>Shadow test</chat_title>") },
            geminiPromptCache: GeminiPromptCacheService(),
            shouldUseGeminiHistoryCache: { false },
            shouldPersistAssistantThinking: { false }
        )
        let runner = ChatTurnRunner(
            conversationSessionStore: conversationStore,
            turnPlanner: planner,
            turnExecutor: executor,
            outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false }),
            shadowLearningSignalRecorder: recorder
        )
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: nil,
                messages: [],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: nil
            ),
            inputText: "先用 first principles 拆一下",
            attachments: [],
            now: Date(timeIntervalSince1970: 5_000)
        )
        let sink = TurnSequencedEventSink(turnId: request.turnId, sink: NoOpTurnEventSink())

        _ = await runner.run(request: request, sink: sink, abortReason: { .unexpectedCancellation })

        let patterns = try shadowStore.fetchPatterns(userId: "alex")
        XCTAssertEqual(patterns.map(\.label), ["first_principles_decision_frame"])
    }

    private func makePlanner(nodeStore: NodeStore) -> TurnPlanner {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        return TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: nodeStore),
            contradictionMemoryService: ContradictionMemoryService(core: core),
            currentProviderProvider: { .gemini },
            judgeLLMServiceFactory: { nil }
        )
    }
}

private struct NoOpTurnEventSink: TurnEventSink {
    func emit(_ envelope: TurnEventEnvelope) async {}
}
```

If `FixedLLMService` already exists in test helpers, reuse it. If it does not, add this private type at the bottom of the test file:

```swift
private final class FixedLLMService: LLMService {
    let output: String

    init(output: String) {
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}
```

- [ ] **Step 7: Run runner integration test**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ChatTurnRunnerShadowLearningTests
```

Expected: PASS.

- [ ] **Step 8: Commit Task 3**

```bash
git add Sources/Nous/Services/ShadowLearningSignalRecorder.swift Sources/Nous/Services/ChatTurnRunner.swift Tests/NousTests/ShadowLearningSignalRecorderTests.swift Tests/NousTests/ChatTurnRunnerShadowLearningTests.swift
git commit -m "feat: record shadow learning signals"
```

---

### Task 4: Add Learning Steward and Heartbeat Cadence

**Files:**
- Create: `Sources/Nous/Services/ShadowLearningSteward.swift`
- Create: `Sources/Nous/Services/HeartbeatCoordinator.swift`
- Modify: `Sources/Nous/Services/ShadowLearningStore.swift`
- Test: `Tests/NousTests/ShadowLearningStewardTests.swift`
- Test: `Tests/NousTests/HeartbeatCoordinatorTests.swift`

- [ ] **Step 1: Extend store with recent user message fetch**

Add this protocol method in `ShadowLearningStoring`:

```swift
    func fetchRecentUserMessages(since: Date?, limit: Int) throws -> [Message]
```

Add this implementation to `ShadowLearningStore`:

```swift
    func fetchRecentUserMessages(since: Date?, limit: Int) throws -> [Message] {
        let sql: String
        let stmt: Statement
        if let since {
            sql = """
                SELECT id, nodeId, role, content, timestamp, thinking_content, agent_trace_json, source
                FROM messages
                WHERE role = 'user' AND timestamp > ?
                ORDER BY timestamp ASC
                LIMIT ?;
            """
            stmt = try database.prepare(sql)
            try stmt.bind(since.timeIntervalSince1970, at: 1)
            try stmt.bind(limit, at: 2)
        } else {
            sql = """
                SELECT id, nodeId, role, content, timestamp, thinking_content, agent_trace_json, source
                FROM messages
                WHERE role = 'user'
                ORDER BY timestamp ASC
                LIMIT ?;
            """
            stmt = try database.prepare(sql)
            try stmt.bind(limit, at: 1)
        }

        var messages: [Message] = []
        while try stmt.step() {
            guard let idText = stmt.text(at: 0),
                  let id = UUID(uuidString: idText),
                  let nodeIdText = stmt.text(at: 1),
                  let nodeId = UUID(uuidString: nodeIdText),
                  let roleText = stmt.text(at: 2),
                  let role = MessageRole(rawValue: roleText) else {
                continue
            }
            messages.append(Message(
                id: id,
                nodeId: nodeId,
                role: role,
                content: stmt.text(at: 3) ?? "",
                timestamp: Date(timeIntervalSince1970: stmt.double(at: 4)),
                thinkingContent: stmt.text(at: 5),
                agentTraceJson: stmt.text(at: 6),
                source: MessageSource(rawValue: stmt.text(at: 7) ?? "") ?? .typed
            ))
        }
        return messages
    }
```

- [ ] **Step 2: Write failing steward tests**

Create `Tests/NousTests/ShadowLearningStewardTests.swift`:

```swift
import XCTest
@testable import Nous

final class ShadowLearningStewardTests: XCTestCase {
    func testDailyRunSkipsWhenBelowMessageThreshold() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let steward = ShadowLearningSteward(store: store, minNewMessages: 15)

        let result = await steward.runIfDue(userId: "alex", now: Date(timeIntervalSince1970: 10_000), force: false)

        XCTAssertEqual(result, .skippedInsufficientMessages(0))
    }

    func testDailyRunUpdatesStateAndCapsPatternUpdates() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let steward = ShadowLearningSteward(store: store, minNewMessages: 3, maxPatternUpdates: 2)
        let node = NousNode(type: .conversation, title: "Learning")
        try nodeStore.insertNode(node)
        try insertUserMessage(nodeStore, nodeId: node.id, text: "先用 first principles", offset: 1)
        try insertUserMessage(nodeStore, nodeId: node.id, text: "这个太 generic 了", offset: 2)
        try insertUserMessage(nodeStore, nodeId: node.id, text: "用 pain test 看一下", offset: 3)

        let result = await steward.runIfDue(userId: "alex", now: Date(timeIntervalSince1970: 10_000), force: false)

        XCTAssertEqual(result, .updated(patternCount: 2))
        let patterns = try store.fetchPatterns(userId: "alex")
        XCTAssertEqual(patterns.count, 2)
        let state = try store.fetchState(userId: "alex")
        XCTAssertEqual(state.lastRunAt, Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(state.lastScannedMessageAt, Date(timeIntervalSince1970: 1_003))
    }

    func testWeeklyConsolidationDecaysStalePatterns() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        try store.upsertPattern(ShadowLearningPattern(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000004001")!,
            userId: "alex",
            kind: .thinkingMove,
            label: "pain_test_for_product_scope",
            summary: "Use pain test before adding scope.",
            promptFragment: "Ask whether absence would hurt before expanding scope.",
            triggerHint: "product scope pain test",
            confidence: 0.86,
            weight: 0.66,
            status: .strong,
            evidenceMessageIds: [],
            firstSeenAt: now.addingTimeInterval(-80 * 86_400),
            lastSeenAt: now.addingTimeInterval(-40 * 86_400),
            lastReinforcedAt: now.addingTimeInterval(-40 * 86_400),
            lastCorrectedAt: nil,
            activeFrom: now.addingTimeInterval(-70 * 86_400),
            activeUntil: nil
        ))

        let steward = ShadowLearningSteward(store: store, minNewMessages: 15)
        let result = await steward.consolidateIfDue(userId: "alex", now: now, force: true)

        XCTAssertEqual(result, .consolidated(patternCount: 1))
        let pattern = try XCTUnwrap(store.fetchPattern(userId: "alex", kind: .thinkingMove, label: "pain_test_for_product_scope"))
        XCTAssertEqual(pattern.status, .fading)
    }

    private func insertUserMessage(_ nodeStore: NodeStore, nodeId: UUID, text: String, offset: TimeInterval) throws {
        try nodeStore.insertMessage(Message(
            nodeId: nodeId,
            role: .user,
            content: text,
            timestamp: Date(timeIntervalSince1970: 1_000 + offset)
        ))
    }
}
```

- [ ] **Step 3: Implement ShadowLearningSteward**

Create `Sources/Nous/Services/ShadowLearningSteward.swift`:

```swift
import Foundation

enum ShadowLearningRunResult: Equatable {
    case skippedRecentlyRan
    case skippedInsufficientMessages(Int)
    case updated(patternCount: Int)
    case consolidated(patternCount: Int)
}

final class ShadowLearningSteward {
    private let store: any ShadowLearningStoring
    private let recorder: ShadowLearningSignalRecorder
    private let minNewMessages: Int
    private let maxPatternUpdates: Int
    private let dailyInterval: TimeInterval
    private let weeklyInterval: TimeInterval

    init(
        store: any ShadowLearningStoring,
        minNewMessages: Int = 15,
        maxPatternUpdates: Int = 3,
        dailyInterval: TimeInterval = 24 * 3600,
        weeklyInterval: TimeInterval = 7 * 24 * 3600
    ) {
        self.store = store
        self.recorder = ShadowLearningSignalRecorder(store: store)
        self.minNewMessages = minNewMessages
        self.maxPatternUpdates = maxPatternUpdates
        self.dailyInterval = dailyInterval
        self.weeklyInterval = weeklyInterval
    }

    func runIfDue(userId: String = "alex", now: Date = Date(), force: Bool = false) async -> ShadowLearningRunResult {
        do {
            let state = try store.fetchState(userId: userId)
            if !force,
               let lastRunAt = state.lastRunAt,
               now.timeIntervalSince(lastRunAt) < dailyInterval {
                return .skippedRecentlyRan
            }

            let messages = try store.fetchRecentUserMessages(since: state.lastScannedMessageAt, limit: 200)
            guard messages.count >= minNewMessages else {
                return .skippedInsufficientMessages(messages.count)
            }

            var updatedLabels: Set<String> = []
            for message in messages {
                let before = try store.fetchPatterns(userId: userId)
                try recorder.recordSignals(from: message, userId: userId)
                let after = try store.fetchPatterns(userId: userId)
                let changed = Set(after.map(\.label)).subtracting(before.map(\.label))
                    .union(after.filter { pattern in
                        before.first(where: { $0.id == pattern.id }) != pattern
                    }.map(\.label))
                updatedLabels.formUnion(changed)
                if updatedLabels.count >= maxPatternUpdates {
                    break
                }
            }

            try store.saveState(ShadowLearningState(
                userId: userId,
                lastRunAt: now,
                lastScannedMessageAt: messages.last?.timestamp ?? state.lastScannedMessageAt,
                lastConsolidatedAt: state.lastConsolidatedAt
            ))
            return .updated(patternCount: min(updatedLabels.count, maxPatternUpdates))
        } catch {
            print("[ShadowLearning] steward run failed: \(error)")
            return .skippedInsufficientMessages(0)
        }
    }

    func consolidateIfDue(userId: String = "alex", now: Date = Date(), force: Bool = false) async -> ShadowLearningRunResult {
        do {
            let state = try store.fetchState(userId: userId)
            if !force,
               let lastConsolidatedAt = state.lastConsolidatedAt,
               now.timeIntervalSince(lastConsolidatedAt) < weeklyInterval {
                return .skippedRecentlyRan
            }

            let patterns = try store.fetchPatterns(userId: userId)
            var changedCount = 0
            for pattern in patterns {
                let decayed = ShadowPatternLifecycle.afterDecay(pattern, at: now)
                guard decayed != pattern else { continue }
                try store.upsertPattern(decayed)
                try store.appendEvent(LearningEvent(
                    id: UUID(),
                    userId: userId,
                    patternId: decayed.id,
                    sourceMessageId: nil,
                    eventType: decayed.status == .retired ? .retired : .weakened,
                    note: decayed.status == .retired ? "Pattern retired after stale low-weight period." : "Pattern weakened after stale reinforcement period.",
                    createdAt: now
                ))
                changedCount += 1
            }

            try store.saveState(ShadowLearningState(
                userId: userId,
                lastRunAt: state.lastRunAt,
                lastScannedMessageAt: state.lastScannedMessageAt,
                lastConsolidatedAt: now
            ))
            return .consolidated(patternCount: changedCount)
        } catch {
            print("[ShadowLearning] consolidation failed: \(error)")
            return .consolidated(patternCount: 0)
        }
    }
}
```

- [ ] **Step 4: Run steward tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowLearningStewardTests
```

Expected: PASS.

- [ ] **Step 5: Write failing heartbeat tests**

Create `Tests/NousTests/HeartbeatCoordinatorTests.swift`:

```swift
import XCTest
@testable import Nous

final class HeartbeatCoordinatorTests: XCTestCase {
    func testScheduleCancelsPriorPendingRun() async {
        let steward = CountingShadowLearningSteward()
        let coordinator = HeartbeatCoordinator(
            shadowLearningSteward: steward,
            isEnabled: { true },
            idleDelaySeconds: 0.05
        )

        coordinator.scheduleShadowLearningAfterIdle()
        coordinator.scheduleShadowLearningAfterIdle()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(await steward.runCount, 1)
    }

    func testDisabledCoordinatorDoesNotRun() async {
        let steward = CountingShadowLearningSteward()
        let coordinator = HeartbeatCoordinator(
            shadowLearningSteward: steward,
            isEnabled: { false },
            idleDelaySeconds: 0.01
        )

        coordinator.scheduleShadowLearningAfterIdle()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(await steward.runCount, 0)
    }
}

private actor CountingShadowLearningSteward: ShadowLearningStewardRunning {
    private(set) var runCount = 0

    func runShadowLearning(userId: String, now: Date) async {
        runCount += 1
    }
}
```

- [ ] **Step 6: Implement HeartbeatCoordinator**

Create `Sources/Nous/Services/HeartbeatCoordinator.swift`:

```swift
import Foundation

protocol ShadowLearningStewardRunning: AnyObject {
    func runShadowLearning(userId: String, now: Date) async
}

extension ShadowLearningSteward: ShadowLearningStewardRunning {
    func runShadowLearning(userId: String, now: Date) async {
        _ = await runIfDue(userId: userId, now: now)
        _ = await consolidateIfDue(userId: userId, now: now)
    }
}

@MainActor
final class HeartbeatCoordinator {
    private let shadowLearningSteward: any ShadowLearningStewardRunning
    private let isEnabled: () -> Bool
    private let idleDelaySeconds: TimeInterval
    private var pendingShadowLearningTask: Task<Void, Never>?

    init(
        shadowLearningSteward: any ShadowLearningStewardRunning,
        isEnabled: @escaping () -> Bool,
        idleDelaySeconds: TimeInterval = 180
    ) {
        self.shadowLearningSteward = shadowLearningSteward
        self.isEnabled = isEnabled
        self.idleDelaySeconds = idleDelaySeconds
    }

    func scheduleShadowLearningAfterIdle(userId: String = "alex") {
        pendingShadowLearningTask?.cancel()
        pendingShadowLearningTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.idleDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self.isEnabled() else { return }
            await self.shadowLearningSteward.runShadowLearning(userId: userId, now: Date())
        }
    }
}
```

If the actor test does not satisfy `AnyObject`, change `ShadowLearningStewardRunning` to remove `AnyObject` and keep the rest of the implementation unchanged.

- [ ] **Step 7: Run heartbeat tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/HeartbeatCoordinatorTests
```

Expected: PASS.

- [ ] **Step 8: Commit Task 4**

```bash
git add Sources/Nous/Services/ShadowLearningStore.swift Sources/Nous/Services/ShadowLearningSteward.swift Sources/Nous/Services/HeartbeatCoordinator.swift Tests/NousTests/ShadowLearningStewardTests.swift Tests/NousTests/HeartbeatCoordinatorTests.swift
git commit -m "feat: schedule shadow learning heartbeat"
```

---

### Task 5: Inject Shadow Patterns Into Prompt Volatile Context

**Files:**
- Create: `Sources/Nous/Services/ShadowPatternPromptProvider.swift`
- Modify: `Sources/Nous/Services/PromptContextAssembler.swift`
- Modify: `Sources/Nous/Services/TurnPlanner.swift`
- Modify: `Sources/Nous/Models/PromptGovernanceTrace.swift`
- Test: `Tests/NousTests/ShadowPatternPromptProviderTests.swift`
- Test: `Tests/NousTests/PromptContextAssemblerShadowLearningTests.swift`
- Test: `Tests/NousTests/TurnPlannerShadowLearningTests.swift`

- [ ] **Step 1: Write failing prompt provider tests**

Create `Tests/NousTests/ShadowPatternPromptProviderTests.swift`:

```swift
import XCTest
@testable import Nous

final class ShadowPatternPromptProviderTests: XCTestCase {
    func testProviderReturnsTopThreeRelevantPromptFragments() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let now = Date(timeIntervalSince1970: 10_000)
        try store.upsertPattern(pattern(label: "first_principles_decision_frame", trigger: "product architecture decision", weight: 0.80, now: now))
        try store.upsertPattern(pattern(label: "pain_test_for_product_scope", trigger: "product scope feature", weight: 0.70, now: now))
        try store.upsertPattern(pattern(label: "concrete_over_generic", trigger: "concrete generic answer", weight: 0.60, now: now))
        try store.upsertPattern(pattern(label: "irrelevant_voice", trigger: "voice transcript microphone", weight: 0.90, now: now))

        let provider = ShadowPatternPromptProvider(store: store)
        let hints = try provider.promptHints(
            userId: "alex",
            currentInput: "Should we build this product feature?",
            activeQuickActionMode: .plan,
            now: now
        )

        XCTAssertEqual(hints.count, 3)
        XCTAssertTrue(hints[0].contains("product architecture decision"))
        XCTAssertFalse(hints.joined(separator: "\n").contains("microphone"))
    }

    func testProviderReturnsNilWhenNoRelevantHints() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let provider = ShadowPatternPromptProvider(store: ShadowLearningStore(nodeStore: nodeStore))

        let hints = try provider.promptHints(
            userId: "alex",
            currentInput: "hello",
            activeQuickActionMode: nil,
            now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertTrue(hints.isEmpty)
    }

    private func pattern(label: String, trigger: String, weight: Double, now: Date) -> ShadowLearningPattern {
        ShadowLearningPattern(
            id: UUID(),
            userId: "alex",
            kind: .thinkingMove,
            label: label,
            summary: label,
            promptFragment: "Use \(trigger).",
            triggerHint: trigger,
            confidence: 0.86,
            weight: weight,
            status: .strong,
            evidenceMessageIds: [],
            firstSeenAt: now,
            lastSeenAt: now,
            lastReinforcedAt: now,
            lastCorrectedAt: nil,
            activeFrom: now,
            activeUntil: nil
        )
    }
}
```

- [ ] **Step 2: Implement prompt provider**

Create `Sources/Nous/Services/ShadowPatternPromptProvider.swift`:

```swift
import Foundation

protocol ShadowPatternPromptProviding {
    func promptHints(
        userId: String,
        currentInput: String,
        activeQuickActionMode: QuickActionMode?,
        now: Date
    ) throws -> [String]
}

final class ShadowPatternPromptProvider: ShadowPatternPromptProviding {
    private let store: any ShadowLearningStoring

    init(store: any ShadowLearningStoring) {
        self.store = store
    }

    func promptHints(
        userId: String = "alex",
        currentInput: String,
        activeQuickActionMode: QuickActionMode?,
        now: Date
    ) throws -> [String] {
        let patterns = try store.fetchPromptEligiblePatterns(userId: userId, now: now, limit: 12)
        let inputTerms = terms(from: currentInput)
        let modeBonus = activeQuickActionMode == nil ? 0.0 : 0.08

        return patterns
            .map { pattern in
                (pattern: pattern, score: score(pattern, inputTerms: inputTerms, modeBonus: modeBonus))
            }
            .filter { $0.score > 0.20 }
            .sorted {
                if $0.score == $1.score {
                    return $0.pattern.label < $1.pattern.label
                }
                return $0.score > $1.score
            }
            .prefix(3)
            .map { $0.pattern.promptFragment }
    }

    private func score(
        _ pattern: ShadowLearningPattern,
        inputTerms: Set<String>,
        modeBonus: Double
    ) -> Double {
        let triggerTerms = terms(from: pattern.triggerHint)
        let overlap = triggerTerms.intersection(inputTerms).count
        let overlapScore = min(0.30, Double(overlap) * 0.10)
        let alwaysUsefulBehavior = pattern.kind == .responseBehavior ? 0.12 : 0.0
        return pattern.weight * 0.45 + pattern.confidence * 0.25 + overlapScore + modeBonus + alwaysUsefulBehavior
    }

    private func terms(from text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 3 }
        )
    }
}
```

- [ ] **Step 3: Run provider tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowPatternPromptProviderTests
```

Expected: PASS.

- [ ] **Step 4: Write failing prompt assembler test**

Create `Tests/NousTests/PromptContextAssemblerShadowLearningTests.swift`:

```swift
import XCTest
@testable import Nous

final class PromptContextAssemblerShadowLearningTests: XCTestCase {
    func testShadowHintsRenderInVolatilePromptOnly() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "Should we build this?",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            shadowLearningHints: [
                "For product scope, ask whether absence would genuinely hurt.",
                "Before recommending, name the worst version of the decision."
            ]
        )

        XCTAssertFalse(slice.stable.contains("SHADOW THINKING HINTS"))
        XCTAssertTrue(slice.volatile.contains("SHADOW THINKING HINTS"))
        XCTAssertTrue(slice.volatile.contains("For product scope"))
    }

    func testGovernanceTraceIncludesShadowLearningLayerWhenHintsExist() {
        let trace = PromptContextAssembler.governanceTrace(
            chatMode: .companion,
            currentUserInput: "Should we build this?",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            shadowLearningHints: ["Use pain test."]
        )

        XCTAssertTrue(trace.promptLayers.contains("shadow_learning"))
    }
}
```

- [ ] **Step 5: Modify PromptContextAssembler**

In both `assembleContext` and `governanceTrace`, add a parameter before `now`:

```swift
        shadowLearningHints: [String] = [],
```

In `assembleContext`, after the citation and long-gap sections but before quick mode blocks, add:

```swift
        if !shadowLearningHints.isEmpty {
            volatilePieces.append("---\n\nSHADOW THINKING HINTS:")
            for hint in shadowLearningHints.prefix(3) {
                volatilePieces.append("- \(hint)")
            }
            volatilePieces.append("Use these as quiet thinking guidance for this turn. Do not mention the shadow profile, learning system, or that these hints were injected.")
        }
```

In `governanceTrace`, add:

```swift
        if !shadowLearningHints.isEmpty { layers.append("shadow_learning") }
```

- [ ] **Step 6: Run assembler tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/PromptContextAssemblerShadowLearningTests
```

Expected: PASS.

- [ ] **Step 7: Wire prompt provider into TurnPlanner**

Modify `Sources/Nous/Services/TurnPlanner.swift`.

Add property:

```swift
    private let shadowPatternPromptProvider: (any ShadowPatternPromptProviding)?
```

Add initializer parameter:

```swift
        shadowPatternPromptProvider: (any ShadowPatternPromptProviding)? = nil,
```

Assign it:

```swift
        self.shadowPatternPromptProvider = shadowPatternPromptProvider
```

In `plan`, after `let planningQuickActionMode = explicitQuickActionMode ?? inferredQuickActionMode`, add:

```swift
        let shadowLearningHints = (try? shadowPatternPromptProvider?.promptHints(
            userId: "alex",
            currentInput: promptQuery,
            activeQuickActionMode: planningQuickActionMode,
            now: request.now
        )) ?? []
```

Pass `shadowLearningHints` into both `PromptContextAssembler.assembleContext` and `PromptContextAssembler.governanceTrace`.

- [ ] **Step 8: Add TurnPlanner shadow learning test**

Create `Tests/NousTests/TurnPlannerShadowLearningTests.swift`:

```swift
import XCTest
@testable import Nous

final class TurnPlannerShadowLearningTests: XCTestCase {
    func testPlannerAddsShadowHintsToPromptTraceAndVolatilePrompt() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let planner = makePlanner(nodeStore: nodeStore)
        let node = NousNode(type: .conversation, title: "Shadow prompt")
        let message = Message(nodeId: node.id, role: .user, content: "Should we build this product feature?")
        let prepared = PreparedConversationTurn(node: node, userMessage: message, messagesAfterUserAppend: [message])
        let request = TurnRequest(
            turnId: UUID(),
            snapshot: TurnSessionSnapshot(
                currentNode: node,
                messages: [message],
                defaultProjectId: nil,
                activeChatMode: nil,
                activeQuickActionMode: .plan
            ),
            inputText: message.content,
            attachments: [],
            now: Date(timeIntervalSince1970: 4_000)
        )
        let stewardship = TurnStewardDecision(
            route: .plan,
            memoryPolicy: .lean,
            challengeStance: .surfaceTension,
            responseShape: .producePlan,
            source: .deterministic,
            reason: "test"
        )

        let plan = try await planner.plan(from: prepared, request: request, stewardship: stewardship)

        XCTAssertTrue(plan.turnSlice.volatile.contains("SHADOW THINKING HINTS"))
        XCTAssertTrue(plan.turnSlice.volatile.contains("Use pain test."))
        XCTAssertTrue(plan.promptTrace.promptLayers.contains("shadow_learning"))
    }

    private func makePlanner(nodeStore: NodeStore) -> TurnPlanner {
        let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
        return TurnPlanner(
            nodeStore: nodeStore,
            vectorStore: VectorStore(nodeStore: nodeStore),
            embeddingService: EmbeddingService(),
            memoryProjectionService: MemoryProjectionService(nodeStore: nodeStore),
            contradictionMemoryService: ContradictionMemoryService(core: core),
            currentProviderProvider: { .gemini },
            judgeLLMServiceFactory: { nil },
            shadowPatternPromptProvider: FixedShadowPromptProvider()
        )
    }
}

private struct FixedShadowPromptProvider: ShadowPatternPromptProviding {
    func promptHints(
        userId: String,
        currentInput: String,
        activeQuickActionMode: QuickActionMode?,
        now: Date
    ) throws -> [String] {
        ["Use pain test."]
    }
}
```

- [ ] **Step 9: Run planner shadow tests and existing skill tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/TurnPlannerShadowLearningTests -only-testing:NousTests/SkillIntegrationTests -only-testing:NousTests/TurnPlannerSkillIntegrationTests
```

Expected: PASS.

- [ ] **Step 10: Commit Task 5**

```bash
git add Sources/Nous/Services/ShadowPatternPromptProvider.swift Sources/Nous/Services/PromptContextAssembler.swift Sources/Nous/Services/TurnPlanner.swift Sources/Nous/Models/PromptGovernanceTrace.swift Tests/NousTests/ShadowPatternPromptProviderTests.swift Tests/NousTests/PromptContextAssemblerShadowLearningTests.swift Tests/NousTests/TurnPlannerShadowLearningTests.swift
git commit -m "feat: inject shadow learning prompt hints"
```

---

### Task 6: Wire App Dependencies and Background Maintenance

**Files:**
- Modify: `Sources/Nous/App/AppEnvironment.swift`
- Modify: `Sources/Nous/App/ContentView.swift`
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Test: `Tests/NousTests/AppEnvironmentShadowLearningTests.swift`

- [ ] **Step 1: Add dependencies to AppDependencies**

In `Sources/Nous/App/AppEnvironment.swift`, add fields to `AppDependencies`:

```swift
    let shadowLearningStore: ShadowLearningStore
    let shadowLearningSignalRecorder: ShadowLearningSignalRecorder
    let shadowPatternPromptProvider: ShadowPatternPromptProvider
    let shadowLearningSteward: ShadowLearningSteward
    let heartbeatCoordinator: HeartbeatCoordinator
```

- [ ] **Step 2: Construct services in makeDependencies**

In `makeDependencies()`, after `let skillStore = SkillStore(nodeStore: nodeStore)`, add:

```swift
        let shadowLearningStore = ShadowLearningStore(nodeStore: nodeStore)
        let shadowLearningSignalRecorder = ShadowLearningSignalRecorder(store: shadowLearningStore)
        let shadowPatternPromptProvider = ShadowPatternPromptProvider(store: shadowLearningStore)
        let shadowLearningSteward = ShadowLearningSteward(store: shadowLearningStore)
```

After `settingsVM` exists, create:

```swift
        let heartbeatCoordinator = HeartbeatCoordinator(
            shadowLearningSteward: shadowLearningSteward,
            isEnabled: { settingsVM.backgroundAnalysisEnabled }
        )
```

Pass `shadowPatternPromptProvider` into `ChatViewModel` and then into its `TurnPlanner`.

- [ ] **Step 3: Modify ChatViewModel initializer and cached TurnPlanner**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, add properties:

```swift
    private let shadowLearningSignalRecorder: ShadowLearningSignalRecorder?
    private let shadowPatternPromptProvider: (any ShadowPatternPromptProviding)?
    private let heartbeatCoordinator: HeartbeatCoordinator?
```

Add initializer parameters:

```swift
        shadowLearningSignalRecorder: ShadowLearningSignalRecorder? = nil,
        shadowPatternPromptProvider: (any ShadowPatternPromptProviding)? = nil,
        heartbeatCoordinator: HeartbeatCoordinator? = nil,
```

Assign them:

```swift
        self.shadowLearningSignalRecorder = shadowLearningSignalRecorder
        self.shadowPatternPromptProvider = shadowPatternPromptProvider
        self.heartbeatCoordinator = heartbeatCoordinator
```

When creating `ChatTurnRunner`, pass:

```swift
            shadowLearningSignalRecorder: self.shadowLearningSignalRecorder,
```

When creating `TurnPlanner`, pass:

```swift
            shadowPatternPromptProvider: shadowPatternPromptProvider,
```

In the `.completed` handling path inside `handleTurnEvent` or the existing completion handler, after existing continuation/housekeeping scheduling, add:

```swift
            heartbeatCoordinator?.scheduleShadowLearningAfterIdle()
```

- [ ] **Step 4: Complete AppDependencies return**

In the `AppDependencies` initializer expression at the end of `makeDependencies()`, include:

```swift
            shadowLearningStore: shadowLearningStore,
            shadowLearningSignalRecorder: shadowLearningSignalRecorder,
            shadowPatternPromptProvider: shadowPatternPromptProvider,
            shadowLearningSteward: shadowLearningSteward,
            heartbeatCoordinator: heartbeatCoordinator,
```

If `AppDependencies` is synthesized through a memberwise initializer, place the new arguments in the same order as the struct fields.

- [ ] **Step 5: Schedule on launch maintenance**

In `Sources/Nous/App/ContentView.swift`, inside `runBackgroundMaintenanceIfEnabled(dependencies:)`, add:

```swift
        dependencies.heartbeatCoordinator.scheduleShadowLearningAfterIdle()
```

Place it after the weekly reflection scheduling block so the task remains low priority and delayed.

- [ ] **Step 6: Add app wiring test**

Create `Tests/NousTests/AppEnvironmentShadowLearningTests.swift`:

```swift
import XCTest
@testable import Nous

@MainActor
final class AppEnvironmentShadowLearningTests: XCTestCase {
    func testBootstrapConstructsShadowLearningDependencies() throws {
        let state = AppEnvironment.bootstrap()

        guard case .ready(let dependencies) = state else {
            XCTFail("Expected ready app dependencies")
            return
        }

        XCTAssertNotNil(dependencies.shadowLearningStore)
        XCTAssertNotNil(dependencies.shadowLearningSignalRecorder)
        XCTAssertNotNil(dependencies.shadowPatternPromptProvider)
        XCTAssertNotNil(dependencies.shadowLearningSteward)
        XCTAssertNotNil(dependencies.heartbeatCoordinator)
    }
}
```

If production bootstrap is too heavy for unit tests because it opens the real application database, replace this with a narrower construction test around the dependency factory only if such a test hook already exists. If no hook exists, do not add a new global test hook in this task; rely on compiler coverage and the integration tests from Tasks 3-5.

- [ ] **Step 7: Run build and targeted tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ChatTurnRunnerShadowLearningTests -only-testing:NousTests/TurnPlannerShadowLearningTests
```

Expected: PASS.

Run:

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit Task 6**

```bash
git add Sources/Nous/App/AppEnvironment.swift Sources/Nous/App/ContentView.swift Sources/Nous/ViewModels/ChatViewModel.swift Tests/NousTests/AppEnvironmentShadowLearningTests.swift
git commit -m "feat: wire shadow learning services"
```

---

### Task 7: Add Debug Visibility

**Files:**
- Modify: `Sources/Nous/Views/MemoryDebugInspector.swift`
- Test: `Tests/NousTests/MemoryDebugInspectorShadowLearningTests.swift`

- [ ] **Step 1: Add debug inspector test for formatting helper**

Before touching the view body, add a pure formatting helper so the debug UI can be tested without rendering SwiftUI.

Create `Tests/NousTests/MemoryDebugInspectorShadowLearningTests.swift`:

```swift
import XCTest
@testable import Nous

final class MemoryDebugInspectorShadowLearningTests: XCTestCase {
    func testShadowPatternRowsSortByStatusAndWeight() {
        let now = Date(timeIntervalSince1970: 1_000)
        let rows = ShadowPatternDebugFormatting.rows(from: [
            pattern(label: "soft_low", status: .soft, weight: 0.30, now: now),
            pattern(label: "strong_high", status: .strong, weight: 0.90, now: now),
            pattern(label: "retired", status: .retired, weight: 1.00, now: now)
        ])

        XCTAssertEqual(rows.map(\.label), ["strong_high", "soft_low", "retired"])
        XCTAssertEqual(rows[0].status, "strong")
        XCTAssertEqual(rows[0].weight, "0.90")
    }

    private func pattern(label: String, status: ShadowPatternStatus, weight: Double, now: Date) -> ShadowLearningPattern {
        ShadowLearningPattern(
            id: UUID(),
            userId: "alex",
            kind: .thinkingMove,
            label: label,
            summary: label,
            promptFragment: label,
            triggerHint: label,
            confidence: 0.80,
            weight: weight,
            status: status,
            evidenceMessageIds: [],
            firstSeenAt: now,
            lastSeenAt: now,
            lastReinforcedAt: now,
            lastCorrectedAt: nil,
            activeFrom: now,
            activeUntil: nil
        )
    }
}
```

- [ ] **Step 2: Add debug formatting helper**

In `Sources/Nous/Views/MemoryDebugInspector.swift`, add this helper near other debug formatting helpers:

```swift
struct ShadowPatternDebugRow: Equatable {
    let label: String
    let kind: String
    let status: String
    let weight: String
    let confidence: String
    let evidenceCount: String
    let summary: String
}

enum ShadowPatternDebugFormatting {
    static func rows(from patterns: [ShadowLearningPattern]) -> [ShadowPatternDebugRow] {
        patterns
            .sorted(by: ordering)
            .map { pattern in
                ShadowPatternDebugRow(
                    label: pattern.label,
                    kind: pattern.kind.rawValue,
                    status: pattern.status.rawValue,
                    weight: String(format: "%.2f", pattern.weight),
                    confidence: String(format: "%.2f", pattern.confidence),
                    evidenceCount: "\(pattern.evidenceMessageIds.count)",
                    summary: pattern.summary
                )
            }
    }

    private static func ordering(_ lhs: ShadowLearningPattern, _ rhs: ShadowLearningPattern) -> Bool {
        let lhsRank = rank(lhs.status)
        let rhsRank = rank(rhs.status)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        if lhs.weight != rhs.weight {
            return lhs.weight > rhs.weight
        }
        return lhs.label < rhs.label
    }

    private static func rank(_ status: ShadowPatternStatus) -> Int {
        switch status {
        case .strong: return 0
        case .soft: return 1
        case .observed: return 2
        case .fading: return 3
        case .retired: return 4
        }
    }
}
```

- [ ] **Step 3: Run formatting test**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/MemoryDebugInspectorShadowLearningTests
```

Expected: PASS.

- [ ] **Step 4: Add view data loading**

In `MemoryDebugInspector`, add a stored dependency if the view is already dependency-injected:

```swift
    let shadowLearningStore: ShadowLearningStore?
```

If the view currently receives dependencies through `AppDependencies`, pass `dependencies.shadowLearningStore` from the call site.

Add state:

```swift
    @State private var shadowPatterns: [ShadowLearningPattern] = []
    @State private var learningEvents: [LearningEvent] = []
```

In the existing reload method, add:

```swift
            if let shadowLearningStore {
                shadowPatterns = try shadowLearningStore.fetchPatterns(userId: "alex")
                learningEvents = try shadowLearningStore.fetchRecentEvents(userId: "alex", limit: 12)
            }
```

Add a compact card to the debug layout:

```swift
    private var shadowLearningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shadow Learning")
                .font(.system(size: 15, weight: .semibold))
            if shadowPatterns.isEmpty {
                Text("No shadow patterns yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ShadowPatternDebugFormatting.rows(from: shadowPatterns), id: \.label) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.label)
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(row.status) / w \(row.weight)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Text(row.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
```

Place `shadowLearningCard` alongside the existing memory/skill debug cards.

- [ ] **Step 5: Build UI**

Run:

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit Task 7**

```bash
git add Sources/Nous/Views/MemoryDebugInspector.swift Tests/NousTests/MemoryDebugInspectorShadowLearningTests.swift
git commit -m "feat: show shadow learning debug state"
```

---

### Task 8: Verification and Regression Pass

**Files:**
- Modify only files needed to fix failures found by this task.

- [ ] **Step 1: Run full unit test suite**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'
```

Expected: TEST SUCCEEDED.

- [ ] **Step 2: Run app build**

Run:

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify anchor is untouched**

Run:

```bash
git diff -- Sources/Nous/Resources/anchor.md
```

Expected: no output.

- [ ] **Step 4: Verify no root Swift orphans were created**

Run:

```bash
find Sources/Nous -maxdepth 1 -name "*.swift"
```

Expected: no output.

- [ ] **Step 5: Inspect prompt layer behavior**

Run the targeted planner test:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/TurnPlannerShadowLearningTests
```

Expected: PASS and the test confirms `shadow_learning` appears only when hints exist.

- [ ] **Step 6: Inspect git diff**

Run:

```bash
git diff --stat
git diff -- Sources/Nous/Resources/anchor.md
```

Expected: new shadow learning files, focused modifications to wiring/prompt/debug files, and no anchor diff.

- [ ] **Step 7: Final commit**

```bash
git status --short
git add Sources/Nous/Models/ShadowLearningPattern.swift Sources/Nous/Services/ShadowPatternLifecycle.swift Sources/Nous/Services/ShadowLearningStore.swift Sources/Nous/Services/ShadowLearningSignalRecorder.swift Sources/Nous/Services/ShadowLearningSteward.swift Sources/Nous/Services/HeartbeatCoordinator.swift Sources/Nous/Services/ShadowPatternPromptProvider.swift Sources/Nous/Services/NodeStore.swift Sources/Nous/Services/PromptContextAssembler.swift Sources/Nous/Services/TurnPlanner.swift Sources/Nous/Services/ChatTurnRunner.swift Sources/Nous/App/AppEnvironment.swift Sources/Nous/App/ContentView.swift Sources/Nous/ViewModels/ChatViewModel.swift Sources/Nous/Views/MemoryDebugInspector.swift Tests/NousTests/ShadowPatternLifecycleTests.swift Tests/NousTests/ShadowLearningStoreTests.swift Tests/NousTests/ShadowLearningSignalRecorderTests.swift Tests/NousTests/ChatTurnRunnerShadowLearningTests.swift Tests/NousTests/ShadowLearningStewardTests.swift Tests/NousTests/HeartbeatCoordinatorTests.swift Tests/NousTests/ShadowPatternPromptProviderTests.swift Tests/NousTests/PromptContextAssemblerShadowLearningTests.swift Tests/NousTests/TurnPlannerShadowLearningTests.swift Tests/NousTests/MemoryDebugInspectorShadowLearningTests.swift
git commit -m "feat: add shadow learning loop"
```

Expected: commit succeeds with only Shadow Learning changes staged.
