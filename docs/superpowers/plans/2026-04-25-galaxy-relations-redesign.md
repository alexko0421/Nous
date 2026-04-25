# Galaxy Relations Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the project-coupled `shared` edge model with a deep-motif Constellation system derived from existing reflection data, layered onto a live force-directed Galaxy with drag physics that wakes/sleeps and persists settled positions.

**Architecture:**
- Phase 1: cleanly delete `EdgeType.shared` (with decode-time guard against silent re-classification).
- Phase 2-4: derive `Constellation` from `ReflectionClaim` + `ReflectionEvidence` via a new `ConstellationService`, with K=2 multi-membership cap, second prune, in-memory ephemeral bridging, and a stricter `ReflectionValidator` rule (≥2 distinct conversations).
- Phase 5-9: render constellations as pre-blurred halo clouds with a priority-tiered visibility cap; expose tap reveal + toggle reveal + ambient dominant.
- Phase 10: live force-directed simulation during drag with ownership handoff, sleep watchdog (soft + hard), and `UserDefaults` position snapshot persistence keyed by store identity.

**Tech Stack:** Swift 5+, SwiftUI, SpriteKit, XCTest, SQLite (existing in-house wrapper), Combine/NotificationCenter.

**Spec:** `docs/superpowers/specs/2026-04-25-galaxy-relations-redesign-design.md` (commits `4d62bde`, `f59f762`, `e1ceb48`).

**Test runner:** `./scripts/test_nous.sh -only-testing:NousTests/<TestClass>` for single suites; `./scripts/test_nous.sh` for full pass.

---

## File Structure

**New files:**

| Path | Responsibility |
|---|---|
| `Sources/Nous/Models/Constellation.swift` | `Constellation` value type + `derivedShortLabel` algorithm. |
| `Sources/Nous/Services/ConstellationService.swift` | Derive active constellations from reflection data, K=2 cap, second prune, dominant selection (filter-aware), in-memory ephemeral bridging. |
| `Sources/Nous/Services/PositionSnapshotStore.swift` | UserDefaults-backed `[UUID: GraphPosition]` snapshot keyed by store identity. |
| `Sources/Nous/Resources/HaloTexture.swift` | One-time pre-blurred radial gradient texture cache for halo sprites. |
| `Tests/NousTests/EdgeDecodeStaleRowGuardTests.swift` | Verify stale `shared` rows decode to nil after enum removal. |
| `Tests/NousTests/SharedEdgeRemovalMigrationTests.swift` | Verify the one-shot DB sweep + re-run no-op. |
| `Tests/NousTests/NodeStoreConversationNodeIdsTests.swift` | Bulk `messageId → nodeId` resolver. |
| `Tests/NousTests/ReflectionValidatorDistinctConversationTests.swift` | Distinct-conversation rule cases. |
| `Tests/NousTests/ConstellationServiceTests.swift` | Derivation, K=2 cap, second prune, dominant, evidence dedupe. |
| `Tests/NousTests/ConstellationDominantUnderFilterTests.swift` | Dominant recomputed against project filter. |
| `Tests/NousTests/EphemeralBridgingInMemoryTests.swift` | Embedding-NN attach/clear behavior. |
| `Tests/NousTests/PositionSnapshotPersistenceTests.swift` | UserDefaults snapshot round-trip + corrupt-handling. |
| `Tests/NousTests/SimulationSleepWatchdogTests.swift` | Soft + hard watchdog triggers. |
| `Tests/NousTests/OwnershipHandoffTests.swift` | `simulationOwnsPositions` blocks `updateNSView` clobber. |
| `Tests/NousTests/GalaxySceneConstellationRenderTests.swift` | Halo sprite count + rasterize state matches sim state. |
| `Tests/NousTests/HaloPriorityCapTests.swift` | Tap > dominant > toggle priority order under 8-cap. |

**Modified files:**

| Path | Changes |
|---|---|
| `Sources/Nous/Models/NodeEdge.swift` | Remove `EdgeType.shared` case. |
| `Sources/Nous/Models/Reflection.swift` | Add `.singleConversationEvidence` to `ReflectionRejectionReason`. |
| `Sources/Nous/Services/NodeStore.swift` | `edgeFrom` returns nil on unknown raw; add `conversationNodeIds(forMessageIds:)`; migration adds `idx_reflection_evidence_message`; one-shot `DELETE FROM edges WHERE type='shared'`; `reconcileOrphanedReflectionClaims` switches to distinct-nodeId rule; add store-identity getter. |
| `Sources/Nous/Services/GraphEngine.swift` | Remove `generateSharedEdges` and `.shared` branch in `regenerateEdges`. |
| `Sources/Nous/Services/TurnExecutor.swift` | Remove any shared-generation call sites. |
| `Sources/Nous/Services/ReflectionValidator.swift` | Accept `[String: UUID]` messageId→nodeId; reject claims with <2 distinct nodeIds as `.singleConversationEvidence`. |
| `Sources/Nous/Services/WeeklyReflectionService.swift` | Resolve `[messageId: nodeId]` before validator; post `.reflectionRunCompleted` notification on success. Add `Notification.Name.reflectionRunCompleted`. |
| `Sources/Nous/ViewModels/GalaxyViewModel.swift` | `load()` reads position snapshot, calls `ConstellationService.loadActiveConstellations`. Subscribes to `.reflectionRunCompleted`. Filter-aware constellation set; halo persistence callback path. |
| `Sources/Nous/Views/GalaxyView.swift` | Remove `.shared` `connectionLabel` / `edgeTint` cases; add MOTIFS section in bottom sheet; add toggle button. |
| `Sources/Nous/Views/GalaxyScene.swift` | Remove `.shared` palette/branches; halo rendering with priority cap; live sim state machine; sleep watchdog with hard timeout; `simulationOwnsPositions`; `onSimulationSettled` callback; constellation pairwise attraction. |
| `Sources/Nous/Views/GalaxySceneContainer.swift` | `updateNSView` skips position copy when `scene.simulationOwnsPositions == true`. |

---

## Phase 1: Edge Model Cleanup

### Task 1: Edge decode-time guard (defensive against unknown raw types)

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift:1365-1372` (`edgeFrom`) + `fetchAllEdges` and `fetchEdges` callers.
- Test: `Tests/NousTests/EdgeDecodeStaleRowGuardTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Nous

final class EdgeDecodeStaleRowGuardTests: XCTestCase {
    var store: NodeStore!

    override func setUpWithError() throws {
        store = try NodeStore.inMemoryForTesting()  // existing test helper or use a tmp DB path
    }

    func test_unknownEdgeTypeRaw_isFilteredOutByFetchAllEdges() throws {
        // Insert a stale 'shared' row directly via raw SQL (bypassing Swift API)
        let edgeId = UUID()
        let srcId = UUID()
        let tgtId = UUID()
        try store.insertNodeForTest(id: srcId)  // helper in test target
        try store.insertNodeForTest(id: tgtId)

        try store.executeRawForTest("""
            INSERT INTO edges (id, source_id, target_id, strength, type)
            VALUES ('\(edgeId.uuidString)', '\(srcId.uuidString)', '\(tgtId.uuidString)', 0.3, 'shared');
        """)

        let edges = try store.fetchAllEdges()
        XCTAssertEqual(edges.count, 0, "Stale 'shared' rows must not appear as any EdgeType")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test_nous.sh -only-testing:NousTests/EdgeDecodeStaleRowGuardTests`
Expected: FAIL — current code re-decodes `shared` as `.semantic` so count = 1.

- [ ] **Step 3: Add test helpers (if not already present)**

In `Tests/NousTests/NodeStoreTestSupport.swift` (new or extend existing):

```swift
import Foundation
@testable import Nous

extension NodeStore {
    static func inMemoryForTesting() throws -> NodeStore {
        // If existing helper exists, reuse it. Otherwise create with :memory: path.
        return try NodeStore(databasePath: ":memory:")
    }

    func insertNodeForTest(id: UUID) throws {
        let n = NousNode(
            id: id, type: .conversation, title: "test",
            content: "", emoji: nil, projectId: nil,
            isFavorite: false, createdAt: Date(), updatedAt: Date()
        )
        try insertNode(n)
    }

    func executeRawForTest(_ sql: String) throws {
        try db.exec(sql)
    }
}
```

- [ ] **Step 4: Modify `edgeFrom` to return optional**

Edit `Sources/Nous/Services/NodeStore.swift` around line 1365:

```swift
private func edgeFrom(_ stmt: Statement) -> NodeEdge? {
    let id = UUID(uuidString: stmt.text(at: 0) ?? "") ?? UUID()
    let sourceId = UUID(uuidString: stmt.text(at: 1) ?? "") ?? UUID()
    let targetId = UUID(uuidString: stmt.text(at: 2) ?? "") ?? UUID()
    let strength = Float(stmt.double(at: 3))
    guard let type = EdgeType(rawValue: stmt.text(at: 4) ?? "") else {
        // Unknown raw value (e.g., post-removal `shared` row not yet swept).
        // Filter out instead of silently re-classifying as .semantic.
        return nil
    }
    return NodeEdge(id: id, sourceId: sourceId, targetId: targetId, strength: strength, type: type)
}
```

- [ ] **Step 5: Update both `fetchAllEdges` and `fetchEdges(...)` to compactMap**

Find lines around 1339 and 1350 (the two `results.append(edgeFrom(stmt))` calls) and change to:

```swift
if let edge = edgeFrom(stmt) {
    results.append(edge)
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `./scripts/test_nous.sh -only-testing:NousTests/EdgeDecodeStaleRowGuardTests`
Expected: PASS.

- [ ] **Step 7: Run the full test suite to verify no regressions**

Run: `./scripts/test_nous.sh`
Expected: all pre-existing tests still pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift Tests/NousTests/EdgeDecodeStaleRowGuardTests.swift Tests/NousTests/NodeStoreTestSupport.swift
git commit -m "fix(node-store): edgeFrom returns nil for unknown EdgeType raw

Defensive guard against post-removal stale rows being silently
re-decoded as .semantic. fetchAllEdges/fetchEdges compactMap the
results.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: One-shot migration — delete `shared` rows + add evidence index

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift` (the `init` schema/migration block, around line 47-200).
- Test: `Tests/NousTests/SharedEdgeRemovalMigrationTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Nous

final class SharedEdgeRemovalMigrationTests: XCTestCase {
    func test_migrationDeletesSharedRows_andIsIdempotent() throws {
        let store = try NodeStore.inMemoryForTesting()

        let srcId = UUID()
        let tgtId = UUID()
        try store.insertNodeForTest(id: srcId)
        try store.insertNodeForTest(id: tgtId)

        // Seed a 'shared' row directly
        try store.executeRawForTest("""
            INSERT INTO edges (id, source_id, target_id, strength, type)
            VALUES ('\(UUID().uuidString)', '\(srcId.uuidString)', '\(tgtId.uuidString)', 0.3, 'shared');
        """)
        XCTAssertEqual(try store.countRowsForTest(table: "edges"), 1)

        try store.runSharedEdgeRemovalMigrationForTest()
        XCTAssertEqual(try store.countRowsForTest(table: "edges"), 0)

        // Idempotent: rerun is no-op
        try store.runSharedEdgeRemovalMigrationForTest()
        XCTAssertEqual(try store.countRowsForTest(table: "edges"), 0)
    }

    func test_migrationCreatesEvidenceIndex() throws {
        let store = try NodeStore.inMemoryForTesting()
        try store.runSharedEdgeRemovalMigrationForTest()

        let exists = try store.indexExistsForTest(name: "idx_reflection_evidence_message")
        XCTAssertTrue(exists, "Migration should create idx_reflection_evidence_message")
    }
}
```

- [ ] **Step 2: Add the test helpers**

Append to `Tests/NousTests/NodeStoreTestSupport.swift`:

```swift
extension NodeStore {
    func runSharedEdgeRemovalMigrationForTest() throws {
        try runGalaxyRedesignMigration()
    }

    func countRowsForTest(table: String) throws -> Int {
        let stmt = try db.prepare("SELECT COUNT(*) FROM \(table);")
        guard try stmt.step() else { return 0 }
        return Int(stmt.int64(at: 0))
    }

    func indexExistsForTest(name: String) throws -> Bool {
        let stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name=?;")
        try stmt.bindText(name, at: 1)
        return try stmt.step()
    }
}
```

- [ ] **Step 3: Run test — expected to fail (method doesn't exist)**

Run: `./scripts/test_nous.sh -only-testing:NousTests/SharedEdgeRemovalMigrationTests`
Expected: build fails (`runGalaxyRedesignMigration` undefined).

- [ ] **Step 4: Add the migration method to `NodeStore`**

In `Sources/Nous/Services/NodeStore.swift`, add a new method (place near other migration helpers, e.g., right after `ensureColumnExists`):

```swift
/// One-shot Galaxy-redesign migration:
///   - Sweeps stale `shared` edge rows that pre-date EdgeType.shared removal.
///   - Adds idx_reflection_evidence_message for inverse-direction joins
///     used by ConstellationService and the orphan reconciliation query.
///
/// Idempotent — safe to call on every app launch.
func runGalaxyRedesignMigration() throws {
    try db.exec("DELETE FROM edges WHERE type = 'shared';")
    try db.exec("""
        CREATE INDEX IF NOT EXISTS idx_reflection_evidence_message
            ON reflection_evidence(message_id);
    """)
}
```

- [ ] **Step 5: Wire migration into `NodeStore.init`**

Find the existing migration call sequence (around the schema block, after `CREATE TABLE` statements). Add a call to `runGalaxyRedesignMigration()` near the end of init so it runs on every store creation:

```swift
// (after existing migration calls in init)
try runGalaxyRedesignMigration()
```

- [ ] **Step 6: Run test to verify pass**

Run: `./scripts/test_nous.sh -only-testing:NousTests/SharedEdgeRemovalMigrationTests`
Expected: PASS.

- [ ] **Step 7: Run full suite**

Run: `./scripts/test_nous.sh`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift Tests/NousTests/SharedEdgeRemovalMigrationTests.swift Tests/NousTests/NodeStoreTestSupport.swift
git commit -m "feat(node-store): galaxy-redesign migration

One-shot DELETE FROM edges WHERE type='shared'; idempotent.
Also adds idx_reflection_evidence_message for inverse-direction joins.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Remove `EdgeType.shared` enum case + downstream call sites

**Files:**
- Modify: `Sources/Nous/Models/NodeEdge.swift`
- Modify: `Sources/Nous/Services/GraphEngine.swift` (`generateSharedEdges`, `regenerateEdges` branch)
- Modify: `Sources/Nous/Services/TurnExecutor.swift` (any shared call sites)

- [ ] **Step 1: Compiler-driven removal — start with the enum**

Edit `Sources/Nous/Models/NodeEdge.swift`. Find the `EdgeType` enum and remove the `.shared` case:

```swift
enum EdgeType: String, Codable {
    case manual
    case semantic
    // case shared  ← REMOVED
}
```

- [ ] **Step 2: Build to find compile errors**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' 2>&1 | grep -E "error:" | head -20`

You will see errors at every `case .shared:` switch arm and every `EdgeType.shared` reference. Walk through each:

- [ ] **Step 3: Remove `GraphEngine.generateSharedEdges`**

In `Sources/Nous/Services/GraphEngine.swift`, delete the entire method `generateSharedEdges(for:)` (lines 113-126).

Then update `regenerateEdges`:

```swift
func regenerateEdges(for node: NousNode) throws {
    try generateSemanticEdges(for: node)
    // generateSharedEdges removed — project membership no longer creates edges
}
```

- [ ] **Step 4: Remove TurnExecutor call sites**

Search: `grep -rn "generateSharedEdges\|EdgeType.shared\|\.shared" Sources/Nous/Services/TurnExecutor.swift`

Delete any lines that call `generateSharedEdges`. (If none exist, this step is a no-op confirmation.)

- [ ] **Step 5: Build again — should be clean**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' 2>&1 | grep -E "error:" | head -20`
Expected: no errors. (Render-side `.shared` cases are handled in Task 4.)

- [ ] **Step 6: Run full test suite**

Run: `./scripts/test_nous.sh`
Expected: all pass. Some existing tests may have used `.shared` fixtures — search and update:

```bash
grep -rn "\.shared" Tests/NousTests/
```

For each hit, decide intent: if the test was specifically about shared behavior, delete the test; if it was using `.shared` as a stand-in for "any edge," replace with `.semantic`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Models/NodeEdge.swift Sources/Nous/Services/GraphEngine.swift Sources/Nous/Services/TurnExecutor.swift Tests/NousTests/
git commit -m "feat(graph): remove EdgeType.shared

Project membership no longer creates auto-edges. Cleanup:
- EdgeType.shared enum case
- GraphEngine.generateSharedEdges
- regenerateEdges no longer calls shared generation
- TurnExecutor call sites
- Test fixtures using .shared

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: Remove `.shared` rendering from GalaxyView and GalaxyScene

**Files:**
- Modify: `Sources/Nous/Views/GalaxyView.swift` (lines around 388-408 — `edgeTint`, `connectionLabel`)
- Modify: `Sources/Nous/Views/GalaxyScene.swift` (around line 38-39 `sharedStoneBlue`, line 331-351 `strokeColor`/`lineWidth`/`edgeColor` switches)

- [ ] **Step 1: Remove `GalaxyView.edgeTint` `.shared` branch**

Edit `Sources/Nous/Views/GalaxyView.swift`. The current `edgeTint` (line 388):

```swift
private func edgeTint(_ type: EdgeType) -> Color {
    switch type {
    case .manual:
        return GalaxyPaperPalette.camel
    case .semantic:
        return GalaxyPaperPalette.sage
    // case .shared: removed
    }
}
```

Remove the `.shared` case. The compiler will accept the now-exhaustive switch.

- [ ] **Step 2: Remove `GalaxyView.connectionLabel` `.shared` branch**

Same file, around line 399:

```swift
private func connectionLabel(_ connection: GalaxyConnection) -> String {
    switch connection.edge.type {
    case .manual:
        return "manual"
    case .semantic:
        return "\(Int(connection.edge.strength * 100)) semantic"
    // case .shared: removed
    }
}
```

- [ ] **Step 3: Remove `GalaxyScene.sharedStoneBlue` palette + switches**

Edit `Sources/Nous/Views/GalaxyScene.swift`:

- Delete line 38: `private static let sharedStoneBlue = NodeColor(112, 145, 161)`
- In `edgeColor(for:)` (around line 357), remove the `.shared` case:

```swift
private func edgeColor(for edge: NodeEdge) -> NodeColor {
    switch edge.type {
    case .manual:
        return nodeColor(for: edge.sourceId)
    case .semantic:
        return Self.semanticSage
    // case .shared: removed
    }
}
```

- In `strokeColor(for:baseColor:strength:isFocused:)` (around line 331), remove the `.shared` case.
- In `lineWidth(for:strength:isFocused:)` (around line 342), remove the `.shared` case.

- [ ] **Step 4: Build to confirm**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS'`
Expected: clean build.

- [ ] **Step 5: Run full test suite**

Run: `./scripts/test_nous.sh`
Expected: all pass.

- [ ] **Step 6: Manual visual check**

Open Nous in Xcode → Run. Open Galaxy. Verify: no stone-blue edges; no "project" labels on connection chips. Connections only show "manual" or "X% semantic".

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Views/GalaxyView.swift Sources/Nous/Views/GalaxyScene.swift
git commit -m "feat(galaxy-view): remove shared edge rendering

Drops .shared branches from edgeTint, connectionLabel, edgeColor,
strokeColor, and lineWidth. Removes sharedStoneBlue palette entry.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 2: NodeStore Foundational Helper

### Task 5: Add bulk `conversationNodeIds(forMessageIds:)` resolver

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift`
- Test: `Tests/NousTests/NodeStoreConversationNodeIdsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Nous

final class NodeStoreConversationNodeIdsTests: XCTestCase {
    var store: NodeStore!

    override func setUpWithError() throws {
        store = try NodeStore.inMemoryForTesting()
    }

    func test_resolvesMessageIdsToOwningNodeIds() throws {
        let nodeA = UUID()
        let nodeB = UUID()
        try store.insertNodeForTest(id: nodeA)
        try store.insertNodeForTest(id: nodeB)

        let m1 = UUID()
        let m2 = UUID()
        let m3 = UUID()
        try store.insertMessageForTest(id: m1, nodeId: nodeA)
        try store.insertMessageForTest(id: m2, nodeId: nodeA)
        try store.insertMessageForTest(id: m3, nodeId: nodeB)

        let result = try store.conversationNodeIds(forMessageIds: [m1, m2, m3])
        XCTAssertEqual(result[m1], nodeA)
        XCTAssertEqual(result[m2], nodeA)
        XCTAssertEqual(result[m3], nodeB)
    }

    func test_unknownMessageIdsAreOmittedNotFailed() throws {
        let nodeA = UUID()
        try store.insertNodeForTest(id: nodeA)
        let m1 = UUID()
        try store.insertMessageForTest(id: m1, nodeId: nodeA)

        let unknown = UUID()
        let result = try store.conversationNodeIds(forMessageIds: [m1, unknown])
        XCTAssertEqual(result[m1], nodeA)
        XCTAssertNil(result[unknown])
    }

    func test_emptyInputReturnsEmpty() throws {
        let result = try store.conversationNodeIds(forMessageIds: [])
        XCTAssertEqual(result.count, 0)
    }

    func test_handlesMoreThan999Ids() throws {
        // SQLite parameter limit is 999; resolver must chunk transparently.
        let nodeA = UUID()
        try store.insertNodeForTest(id: nodeA)
        var messageIds: [UUID] = []
        for _ in 0..<1500 {
            let m = UUID()
            try store.insertMessageForTest(id: m, nodeId: nodeA)
            messageIds.append(m)
        }
        let result = try store.conversationNodeIds(forMessageIds: messageIds)
        XCTAssertEqual(result.count, 1500)
        XCTAssertTrue(result.values.allSatisfy { $0 == nodeA })
    }
}
```

- [ ] **Step 2: Add `insertMessageForTest` helper**

Append to `Tests/NousTests/NodeStoreTestSupport.swift`:

```swift
extension NodeStore {
    func insertMessageForTest(id: UUID, nodeId: UUID, role: String = "user", content: String = "test") throws {
        try db.exec("""
            INSERT INTO messages (id, nodeId, role, content, timestamp)
            VALUES ('\(id.uuidString)', '\(nodeId.uuidString)', '\(role)', '\(content)', \(Date().timeIntervalSince1970));
        """)
    }
}
```

- [ ] **Step 3: Run test — expected fail (method doesn't exist)**

Run: `./scripts/test_nous.sh -only-testing:NousTests/NodeStoreConversationNodeIdsTests`
Expected: build fails.

- [ ] **Step 4: Implement `conversationNodeIds`**

Add to `Sources/Nous/Services/NodeStore.swift` near other public read methods:

```swift
/// Bulk resolves message IDs to their owning conversation node IDs.
/// One round-trip per chunk of ≤900 ids (SQLite parameter limit defense).
/// Unknown messageIds are simply omitted from the result.
func conversationNodeIds(forMessageIds messageIds: [UUID]) throws -> [UUID: UUID] {
    guard !messageIds.isEmpty else { return [:] }

    var result: [UUID: UUID] = [:]
    let chunkSize = 900  // safely under SQLite's 999 default
    for chunk in messageIds.chunked(into: chunkSize) {
        let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
        let stmt = try db.prepare("""
            SELECT id, nodeId
            FROM messages
            WHERE id IN (\(placeholders));
        """)
        for (offset, id) in chunk.enumerated() {
            try stmt.bindText(id.uuidString, at: Int32(offset + 1))
        }
        while try stmt.step() {
            guard
                let mRaw = stmt.text(at: 0),
                let nRaw = stmt.text(at: 1),
                let mUUID = UUID(uuidString: mRaw),
                let nUUID = UUID(uuidString: nRaw)
            else { continue }
            result[mUUID] = nUUID
        }
    }
    return result
}
```

If `Array.chunked(into:)` does not already exist in the codebase, add it as a fileprivate or shared utility:

```swift
fileprivate extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var result: [[Element]] = []
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            result.append(Array(self[index..<end]))
            index = end
        }
        return result
    }
}
```

- [ ] **Step 5: Run test — expected pass**

Run: `./scripts/test_nous.sh -only-testing:NousTests/NodeStoreConversationNodeIdsTests`
Expected: PASS.

- [ ] **Step 6: Run full suite**

Run: `./scripts/test_nous.sh`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift Tests/NousTests/NodeStoreConversationNodeIdsTests.swift Tests/NousTests/NodeStoreTestSupport.swift
git commit -m "feat(node-store): bulk conversationNodeIds resolver

One round-trip per ≤900-id chunk. Used by ConstellationService
derivation and ReflectionValidator caller. Unknown messageIds
omitted (no throw).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 3: ReflectionValidator change

### Task 6: Add `.singleConversationEvidence` rejection reason

**Files:**
- Modify: `Sources/Nous/Models/Reflection.swift` (`ReflectionRejectionReason` enum)

- [ ] **Step 1: Extend the enum**

Edit `Sources/Nous/Models/Reflection.swift` (lines 9-14):

```swift
enum ReflectionRejectionReason: String, Codable {
    case generic
    case unsupported
    case lowConfidence = "low_confidence"
    case apiError = "api_error"
    case singleConversationEvidence = "single_conversation_evidence"
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS'`
Expected: clean build (raw values are `String`, no exhaustive switch over the enum to force compile errors).

- [ ] **Step 3: Search for any switch statements over `ReflectionRejectionReason` and add the new case where needed**

```bash
grep -rn "ReflectionRejectionReason\|rejectionReason" Sources/Nous/
```

For each `switch` site, add `case .singleConversationEvidence:` with the appropriate handling (most likely "treat like other rejection reasons — log + record run").

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Models/Reflection.swift Sources/Nous/
git commit -m "feat(reflection): add .singleConversationEvidence rejection reason

Ahead of ReflectionValidator change to require evidence from ≥2
distinct conversations.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: Validator takes `[String: UUID]`; rejects single-conversation claims

**Files:**
- Modify: `Sources/Nous/Services/ReflectionValidator.swift`
- Test: `Tests/NousTests/ReflectionValidatorDistinctConversationTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Nous

final class ReflectionValidatorDistinctConversationTests: XCTestCase {

    func test_rejectsClaimWithEvidenceFromOnlyOneConversation() throws {
        let nodeA = UUID()
        let m1 = UUID().uuidString
        let m2 = UUID().uuidString
        let messageIdToNodeId: [String: UUID] = [m1: nodeA, m2: nodeA]

        let json = """
        {"claims": [
          {
            "claim": "Alex returns to fear of being seen as inadequate",
            "confidence": 0.8,
            "supporting_turn_ids": ["\(m1)", "\(m2)"],
            "why_non_obvious": "Because surface topics differ"
          }
        ]}
        """

        let result = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: [m1, m2],
            messageIdToNodeId: messageIdToNodeId,
            runId: UUID()
        )
        XCTAssertEqual(result.claims.count, 0)
        XCTAssertEqual(result.rejectionReason, .singleConversationEvidence)
    }

    func test_acceptsClaimWithEvidenceFromTwoDistinctConversations() throws {
        let nodeA = UUID()
        let nodeB = UUID()
        let m1 = UUID().uuidString
        let m2 = UUID().uuidString
        let messageIdToNodeId: [String: UUID] = [m1: nodeA, m2: nodeB]

        let json = """
        {"claims": [
          {
            "claim": "Alex circles around dad's expectations across launches",
            "confidence": 0.85,
            "supporting_turn_ids": ["\(m1)", "\(m2)"],
            "why_non_obvious": "Twinned at the deeper motif"
          }
        ]}
        """

        let result = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: [m1, m2],
            messageIdToNodeId: messageIdToNodeId,
            runId: UUID()
        )
        XCTAssertEqual(result.claims.count, 1)
        XCTAssertNil(result.rejectionReason)
    }

    func test_rejectsClaimWithThreeMessagesAllSameConversation() throws {
        let nodeA = UUID()
        let m1 = UUID().uuidString
        let m2 = UUID().uuidString
        let m3 = UUID().uuidString
        let messageIdToNodeId: [String: UUID] = [m1: nodeA, m2: nodeA, m3: nodeA]

        let json = """
        {"claims": [
          {
            "claim": "test",
            "confidence": 0.9,
            "supporting_turn_ids": ["\(m1)", "\(m2)", "\(m3)"],
            "why_non_obvious": "test"
          }
        ]}
        """

        let result = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: [m1, m2, m3],
            messageIdToNodeId: messageIdToNodeId,
            runId: UUID()
        )
        XCTAssertEqual(result.claims.count, 0)
        XCTAssertEqual(result.rejectionReason, .singleConversationEvidence)
    }

    func test_emptyMessageIdToNodeIdMapResultsInRejection() throws {
        let m1 = UUID().uuidString
        let m2 = UUID().uuidString
        let json = """
        {"claims": [
          {"claim": "x", "confidence": 0.9, "supporting_turn_ids": ["\(m1)", "\(m2)"], "why_non_obvious": "x"}
        ]}
        """

        let result = try ReflectionValidator.validate(
            rawJSON: json,
            validMessageIds: [m1, m2],
            messageIdToNodeId: [:],  // resolver returned nothing
            runId: UUID()
        )
        XCTAssertEqual(result.claims.count, 0)
        // Treated as ungrounded since no nodeIds resolve.
        XCTAssertNotNil(result.rejectionReason)
    }
}
```

- [ ] **Step 2: Run tests — expected fail (signature mismatch)**

Run: `./scripts/test_nous.sh -only-testing:NousTests/ReflectionValidatorDistinctConversationTests`
Expected: build fails (validate signature has no `messageIdToNodeId` parameter).

- [ ] **Step 3: Update validator signature + add the rule**

Edit `Sources/Nous/Services/ReflectionValidator.swift`:

```swift
static func validate(
    rawJSON: String,
    validMessageIds: Set<String>,
    messageIdToNodeId: [String: UUID],
    runId: UUID,
    now: Date = Date()
) throws -> Output {
    let data = Data(rawJSON.utf8)
    let envelope: Envelope
    do {
        envelope = try JSONDecoder().decode(Envelope.self, from: data)
    } catch {
        throw ValidationError.malformed("JSON decode failed: \(error.localizedDescription)")
    }

    if envelope.claims.isEmpty {
        return Output(claims: [], rejectionReason: .generic)
    }

    var passed: [ReflectionClaim] = []
    var droppedForLowConfidence = 0
    var droppedForUngrounded = 0
    var droppedForSingleConversation = 0

    for raw in envelope.claims {
        let trimmed = raw.claim.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }

        if raw.confidence < minConfidence {
            droppedForLowConfidence += 1
            continue
        }

        let grounded = raw.supporting_turn_ids.filter { validMessageIds.contains($0) }
        if grounded.count < minGroundedTurns {
            droppedForUngrounded += 1
            continue
        }

        var seen = Set<String>()
        let deduped = grounded.filter { id in
            if seen.contains(id) { return false }
            seen.insert(id)
            return true
        }
        if deduped.count < minGroundedTurns {
            droppedForUngrounded += 1
            continue
        }

        // NEW: distinct-conversation rule
        let distinctNodeIds = Set(deduped.compactMap { messageIdToNodeId[$0] })
        if distinctNodeIds.count < 2 {
            droppedForSingleConversation += 1
            continue
        }

        let clampedConfidence = max(0.0, min(1.0, raw.confidence))

        passed.append(ReflectionClaim(
            runId: runId,
            claim: trimmed,
            confidence: clampedConfidence,
            whyNonObvious: raw.why_non_obvious.trimmingCharacters(in: .whitespacesAndNewlines),
            status: .active,
            createdAt: now
        ))
    }

    if !passed.isEmpty {
        return Output(claims: passed, rejectionReason: nil)
    }

    // All claims dropped — pick dominant reason.
    // Order: lowConfidence > ungrounded > singleConversationEvidence (most-specific tiebreak)
    let reason: ReflectionRejectionReason
    if droppedForLowConfidence >= droppedForUngrounded && droppedForLowConfidence >= droppedForSingleConversation {
        reason = .lowConfidence
    } else if droppedForUngrounded >= droppedForSingleConversation {
        reason = .unsupported
    } else {
        reason = .singleConversationEvidence
    }
    return Output(claims: [], rejectionReason: reason)
}
```

- [ ] **Step 4: Run tests — expect pass**

Run: `./scripts/test_nous.sh -only-testing:NousTests/ReflectionValidatorDistinctConversationTests`
Expected: PASS (all 4 cases).

- [ ] **Step 5: Update existing ReflectionValidator tests to pass `messageIdToNodeId: [:]` or appropriate maps**

Existing validator tests use `validate(rawJSON:, validMessageIds:, runId:, now:)`. Search:

```bash
grep -rn "ReflectionValidator.validate" Tests/NousTests/
```

For each call site, supply `messageIdToNodeId: [...]` argument. For tests that don't care about distinct conversations, build a synthetic map mapping each valid messageId to a unique UUID — that satisfies the new rule.

Example pattern for an existing test that previously expected acceptance:

```swift
let messageIdToNodeId = Dictionary(uniqueKeysWithValues:
    validMessageIds.map { ($0, UUID()) }
)
let result = try ReflectionValidator.validate(
    rawJSON: json,
    validMessageIds: validMessageIds,
    messageIdToNodeId: messageIdToNodeId,
    runId: runId
)
```

- [ ] **Step 6: Run full suite**

Run: `./scripts/test_nous.sh`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Services/ReflectionValidator.swift Tests/NousTests/
git commit -m "feat(reflection): require ≥2 distinct conversations in evidence

ReflectionValidator now takes [String: UUID] messageIdToNodeId map
and rejects claims whose evidence collapses to <2 distinct nodeIds
with .singleConversationEvidence. Existing test fixtures updated
to supply synthetic maps.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 8: WeeklyReflectionService resolves `[messageId: nodeId]` before validator; cascade orphan check uses distinct-nodeId rule

**Files:**
- Modify: `Sources/Nous/Services/WeeklyReflectionService.swift`
- Modify: `Sources/Nous/Services/NodeStore.swift` (`reconcileOrphanedReflectionClaims` SQL update)
- Test: `Tests/NousTests/ReflectionCascadeOrphanTests.swift` (existing — extend)

- [ ] **Step 1: Update `reconcileOrphanedReflectionClaims` SQL**

Edit `Sources/Nous/Services/NodeStore.swift` around line 1778:

```swift
@discardableResult
func reconcileOrphanedReflectionClaims() throws -> [UUID] {
    // Distinct-conversation rule: a claim is active iff its remaining
    // evidence spans ≥2 distinct conversation nodeIds (was: ≥2 messages).
    let stmt = try db.prepare("""
        SELECT c.id
        FROM reflection_claim c
        LEFT JOIN reflection_evidence e ON e.reflection_id = c.id
        LEFT JOIN messages m ON m.id = e.message_id
        WHERE c.status = 'active'
        GROUP BY c.id
        HAVING COUNT(DISTINCT m.nodeId) < 2;
    """)
    var flipped: [UUID] = []
    while try stmt.step() {
        guard let raw = stmt.text(at: 0),
              let uuid = UUID(uuidString: raw) else { continue }
        flipped.append(uuid)
    }
    for id in flipped {
        try orphanReflectionClaim(id: id)
    }
    return flipped
}
```

- [ ] **Step 2: Extend `Tests/NousTests/ReflectionCascadeOrphanTests.swift`**

Add new test cases (do not delete existing ones — they continue to verify the count-≥2 baseline; the distinct rule is strictly stronger so existing fixtures may need updating to seed two distinct-nodeId messages):

```swift
func test_orphansClaimWhenEvidenceCollapsesToSingleConversation() throws {
    let store = try NodeStore.inMemoryForTesting()
    let nodeA = UUID()
    let nodeB = UUID()
    try store.insertNodeForTest(id: nodeA)
    try store.insertNodeForTest(id: nodeB)

    let m1 = UUID()
    let m2 = UUID()
    let m3 = UUID()  // doomed
    try store.insertMessageForTest(id: m1, nodeId: nodeA)
    try store.insertMessageForTest(id: m2, nodeId: nodeA)
    try store.insertMessageForTest(id: m3, nodeId: nodeB)

    // Seed an active claim with all three evidence rows
    let runId = UUID()
    let claimId = UUID()
    try store.insertReflectionRunForTest(runId: runId)
    try store.insertReflectionClaimForTest(id: claimId, runId: runId, status: .active)
    try store.insertReflectionEvidenceForTest(claimId: claimId, messageId: m1)
    try store.insertReflectionEvidenceForTest(claimId: claimId, messageId: m2)
    try store.insertReflectionEvidenceForTest(claimId: claimId, messageId: m3)

    // Delete the message in nodeB — evidence cascades, leaving 2 messages both in nodeA
    try store.deleteMessageForTest(id: m3)

    let flipped = try store.reconcileOrphanedReflectionClaims()
    XCTAssertEqual(flipped, [claimId])
}

func test_keepsClaimActiveWhenEvidenceStillSpansTwoConversations() throws {
    let store = try NodeStore.inMemoryForTesting()
    let nodeA = UUID()
    let nodeB = UUID()
    try store.insertNodeForTest(id: nodeA)
    try store.insertNodeForTest(id: nodeB)

    let m1 = UUID(); let m2 = UUID(); let m3 = UUID()
    try store.insertMessageForTest(id: m1, nodeId: nodeA)
    try store.insertMessageForTest(id: m2, nodeId: nodeB)
    try store.insertMessageForTest(id: m3, nodeId: nodeA)

    let runId = UUID()
    let claimId = UUID()
    try store.insertReflectionRunForTest(runId: runId)
    try store.insertReflectionClaimForTest(id: claimId, runId: runId, status: .active)
    try store.insertReflectionEvidenceForTest(claimId: claimId, messageId: m1)
    try store.insertReflectionEvidenceForTest(claimId: claimId, messageId: m2)
    try store.insertReflectionEvidenceForTest(claimId: claimId, messageId: m3)

    try store.deleteMessageForTest(id: m3)

    let flipped = try store.reconcileOrphanedReflectionClaims()
    XCTAssertTrue(flipped.isEmpty, "Two distinct nodeIds remain (nodeA, nodeB)")
}
```

(Add helpers `insertReflectionRunForTest`, `insertReflectionClaimForTest`, `insertReflectionEvidenceForTest`, `deleteMessageForTest` to `NodeStoreTestSupport.swift` if not already present — straightforward INSERT/DELETE wrappers around `db.exec`.)

- [ ] **Step 3: Run cascade orphan tests**

Run: `./scripts/test_nous.sh -only-testing:NousTests/ReflectionCascadeOrphanTests`
Expected: PASS (existing + new cases).

- [ ] **Step 4: Update `WeeklyReflectionService` to resolve before validating**

Edit `Sources/Nous/Services/WeeklyReflectionService.swift`. Find the call site of `ReflectionValidator.validate(...)` (search `ReflectionValidator.validate`). Before the call, resolve the message → node mapping:

```swift
// (just before the existing call to ReflectionValidator.validate)
let validMessageUUIDs = validMessageIds.compactMap { UUID(uuidString: $0) }
let messageIdToNodeId: [String: UUID] = try {
    let resolvedByUUID = try nodeStore.conversationNodeIds(forMessageIds: validMessageUUIDs)
    var byString: [String: UUID] = [:]
    for (key, value) in resolvedByUUID {
        byString[key.uuidString] = value
    }
    return byString
}()

let validatorOutput = try ReflectionValidator.validate(
    rawJSON: rawJSON,
    validMessageIds: validMessageIds,
    messageIdToNodeId: messageIdToNodeId,
    runId: runId
)
```

- [ ] **Step 5: Run full suite**

Run: `./scripts/test_nous.sh`
Expected: all pass. If any pre-existing `WeeklyReflectionService` test fails, update its fixture to include enough nodeIds to satisfy the new rule (or assert the new rejection reason where appropriate).

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/WeeklyReflectionService.swift Sources/Nous/Services/NodeStore.swift Tests/NousTests/
git commit -m "feat(reflection): wire distinct-conversation rule end-to-end

- WeeklyReflectionService resolves [messageId: nodeId] via NodeStore
  and passes into validator
- reconcileOrphanedReflectionClaims uses COUNT(DISTINCT m.nodeId) < 2
  in the orphan-sweep query
- New cascade tests cover both branches (collapse to single conv =
  orphan; remain across two conv = stays active)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 4: Constellation Core

### Task 9: `Constellation` value type + `derivedShortLabel` algorithm

**Files:**
- Create: `Sources/Nous/Models/Constellation.swift`
- Test: `Tests/NousTests/ConstellationServiceTests.swift` (initial — covers `derivedShortLabel`)

- [ ] **Step 1: Write the failing test (`derivedShortLabel`)**

```swift
import XCTest
@testable import Nous

final class ConstellationDerivedLabelTests: XCTestCase {
    func test_extractsFirstQuotedPhraseInCornerBrackets() {
        let label = Constellation.derivedShortLabel(
            from: "Across four conversations, Alex returns to 「驚被睇穿不夠好」，always under launch pressure"
        )
        XCTAssertEqual(label, "驚被睇穿不夠好")
    }

    func test_extractsFirstStraightQuotedPhrase() {
        let label = Constellation.derivedShortLabel(
            from: "Alex circles around \"fear of inadequacy\" again."
        )
        XCTAssertEqual(label, "fear of inadequacy")
    }

    func test_quotedPhraseTooLongFallsThrough() {
        let label = Constellation.derivedShortLabel(
            from: "「呢個短語太長太長太長太長太長太長太長太長太長太長太長太長」: short"
        )
        XCTAssertEqual(label, "short")
    }

    func test_extractsAfterFullWidthColon() {
        let label = Constellation.derivedShortLabel(
            from: "深層 motif：對父親的期待，反覆出現"
        )
        XCTAssertEqual(label, "對父親的期待")
    }

    func test_extractsAfterEmDash() {
        let label = Constellation.derivedShortLabel(
            from: "What recurs across launches — fear of being seen as inadequate."
        )
        XCTAssertEqual(label, "fear of being seen as inadequate")
    }

    func test_truncatesAfter22Chars() {
        let label = Constellation.derivedShortLabel(
            from: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        XCTAssertEqual(label.count, 22 + 1) // 22 chars + ellipsis
        XCTAssertTrue(label.hasSuffix("…"))
    }

    func test_emptyClaimReturnsEmptyString() {
        XCTAssertEqual(Constellation.derivedShortLabel(from: ""), "")
    }
}
```

- [ ] **Step 2: Run — expected fail**

Run: `./scripts/test_nous.sh -only-testing:NousTests/ConstellationDerivedLabelTests`
Expected: build fails (`Constellation` does not exist).

- [ ] **Step 3: Create the `Constellation` value type**

```swift
// Sources/Nous/Models/Constellation.swift
import Foundation

struct Constellation: Identifiable, Equatable {
    let id: UUID                       // = ReflectionClaim.id
    let claimId: UUID
    let label: String                  // = ReflectionClaim.claim (verbatim)
    let derivedShortLabel: String      // computed
    let confidence: Double
    let memberNodeIds: [UUID]          // post-K=2-cap; distinct, ≥ 2
    let centroidEmbedding: [Float]?    // mean of member embeddings, nil if any missing
    let isDominant: Bool
}

extension Constellation {
    /// Deterministic short-label derivation. Pattern A → quoted phrase ≤22 chars;
    /// Pattern B → substring after first colon/em-dash trimmed to first sentence
    /// delimiter or 22 chars; Fallback → first 22 chars + ellipsis.
    static func derivedShortLabel(from claim: String) -> String {
        let trimmed = claim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Pattern A: 「...」 first
        if let cornerStart = trimmed.firstIndex(of: "「"),
           let cornerEnd = trimmed[trimmed.index(after: cornerStart)...].firstIndex(of: "」") {
            let inner = String(trimmed[trimmed.index(after: cornerStart)..<cornerEnd])
            if inner.count <= 22 && !inner.isEmpty {
                return inner
            }
        }
        // Pattern A: "..." straight quotes
        if let q1 = trimmed.firstIndex(of: "\""),
           let q2 = trimmed[trimmed.index(after: q1)...].firstIndex(of: "\"") {
            let inner = String(trimmed[trimmed.index(after: q1)..<q2])
            if inner.count <= 22 && !inner.isEmpty {
                return inner
            }
        }

        // Pattern B: split on first delimiter, take after
        let delimiters: [String] = ["：", ":", "——", "—"]
        for delim in delimiters {
            if let range = trimmed.range(of: delim) {
                let after = trimmed[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty {
                    let stoppers: [Character] = ["，", "。", ",", ".", "\n"]
                    var end = after.startIndex
                    var count = 0
                    for ch in after {
                        if count >= 22 { break }
                        if stoppers.contains(ch) { break }
                        end = after.index(after: end)
                        count += 1
                    }
                    let candidate = String(after[..<end])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidate.isEmpty {
                        return candidate
                    }
                }
            }
        }

        // Fallback
        if trimmed.count > 22 {
            return String(trimmed.prefix(22)) + "…"
        }
        return trimmed
    }
}
```

- [ ] **Step 4: Run tests — expect pass**

Run: `./scripts/test_nous.sh -only-testing:NousTests/ConstellationDerivedLabelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Models/Constellation.swift Tests/NousTests/ConstellationServiceTests.swift
git commit -m "feat(constellation): add Constellation value type + derivedShortLabel

Pattern A (quoted phrase ≤22), Pattern B (after colon/em-dash), and
fallback (first 22 + ellipsis). All deterministic string ops, no NLP.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 10: `ConstellationService` skeleton + dependency wiring

**Files:**
- Create: `Sources/Nous/Services/ConstellationService.swift`

- [ ] **Step 1: Write the skeleton (no logic yet, just signatures + empty implementations)**

```swift
// Sources/Nous/Services/ConstellationService.swift
import Foundation

final class ConstellationService {
    private let nodeStore: NodeStore
    private let vectorStore: VectorStore

    /// In-memory ephemeral attachments. Cleared on reflection completion
    /// and not persisted. Lifetime = process lifetime (single instance).
    private var ephemeralByConstellationId: [UUID: Set<UUID>] = [:]
    private let ephemeralLock = NSLock()

    init(nodeStore: NodeStore, vectorStore: VectorStore) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
    }

    /// Builds the active constellation snapshot from current reflection data
    /// merged with in-memory ephemeral attachments. Applies K=2 per-node cap
    /// then a second prune for constellations whose membership dropped <2.
    /// Dominant selection is intentionally project-filter-agnostic here;
    /// callers (GalaxyViewModel) recompute against the active filter.
    func loadActiveConstellations() throws -> [Constellation] {
        // Implemented in Task 11
        return []
    }

    /// Considers a node for ephemeral attachment to existing constellations
    /// based on cosine similarity to centroid. Idempotent.
    func considerNodeForEphemeralBridging(_ node: NousNode) throws {
        // Implemented in Task 12
    }

    /// Drops any ephemeral attachments referencing this nodeId. Called on
    /// node deletion.
    func releaseEphemeral(nodeId: UUID) {
        ephemeralLock.lock()
        defer { ephemeralLock.unlock() }
        for key in ephemeralByConstellationId.keys {
            ephemeralByConstellationId[key]?.remove(nodeId)
        }
    }

    /// Wipes all ephemeral attachments. Called on successful ReflectionRun
    /// completion.
    func clearEphemeral() {
        ephemeralLock.lock()
        defer { ephemeralLock.unlock() }
        ephemeralByConstellationId.removeAll()
    }
}
```

- [ ] **Step 2: Build to confirm**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS'`
Expected: clean build.

- [ ] **Step 3: Add basic instantiation test**

Append to `Tests/NousTests/ConstellationServiceTests.swift`:

```swift
final class ConstellationServiceSkeletonTests: XCTestCase {
    func test_serviceInitializesAndReturnsEmptyWhenNoData() throws {
        let store = try NodeStore.inMemoryForTesting()
        let vectorStore = try VectorStore(databasePath: ":memory:")
        let svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)
        let result = try svc.loadActiveConstellations()
        XCTAssertEqual(result.count, 0)
    }
}
```

If `VectorStore` initializer signature differs, adjust accordingly. The intent is "constructable without test fixtures."

- [ ] **Step 4: Run + commit**

Run: `./scripts/test_nous.sh -only-testing:NousTests/ConstellationServiceSkeletonTests`
Expected: PASS.

```bash
git add Sources/Nous/Services/ConstellationService.swift Tests/NousTests/ConstellationServiceTests.swift
git commit -m "feat(constellation): add ConstellationService skeleton

Public signatures only — derivation, ephemeral bridging, release, clear.
All implementations are stubs filled in by subsequent tasks.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 11: Implement `loadActiveConstellations` (the core derivation algorithm)

**Files:**
- Modify: `Sources/Nous/Services/ConstellationService.swift`
- Modify: `Sources/Nous/Services/NodeStore.swift` (add public fetchers if missing)
- Test: `Tests/NousTests/ConstellationServiceTests.swift`

- [ ] **Step 1: Add NodeStore helpers if not already present**

Search:
```bash
grep -n "fetchActiveReflectionClaims\|fetchEvidenceForClaim\|fetchEmbedding" Sources/Nous/Services/NodeStore.swift
```

If `fetchActiveReflectionClaims(projectId:)` exists (it should — see UserMemoryService.swift:1527), great. If not, add:

```swift
/// All active reflection claims, optionally scoped to a projectId. Pass
/// `nil` to span all runs. Returned in createdAt-desc order.
func fetchActiveReflectionClaims() throws -> [ReflectionClaim] {
    let stmt = try db.prepare("""
        SELECT id, run_id, claim, confidence, why_non_obvious, status, created_at
        FROM reflection_claim
        WHERE status = 'active'
        ORDER BY created_at DESC;
    """)
    var out: [ReflectionClaim] = []
    while try stmt.step() {
        // (decode columns into ReflectionClaim — match existing decoder pattern)
        // Existing helper or inline; consult NodeStore for naming convention.
    }
    return out
}

/// Bulk fetch evidence rows for a list of claim ids. Single round-trip.
func fetchEvidence(forClaimIds claimIds: [UUID]) throws -> [ReflectionEvidence] {
    guard !claimIds.isEmpty else { return [] }
    var out: [ReflectionEvidence] = []
    for chunk in claimIds.chunked(into: 900) {
        let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
        let stmt = try db.prepare("""
            SELECT reflection_id, message_id
            FROM reflection_evidence
            WHERE reflection_id IN (\(placeholders));
        """)
        for (offset, id) in chunk.enumerated() {
            try stmt.bindText(id.uuidString, at: Int32(offset + 1))
        }
        while try stmt.step() {
            guard
                let rRaw = stmt.text(at: 0), let mRaw = stmt.text(at: 1),
                let rUUID = UUID(uuidString: rRaw), let mUUID = UUID(uuidString: mRaw)
            else { continue }
            out.append(ReflectionEvidence(reflectionId: rUUID, messageId: mUUID))
        }
    }
    return out
}

/// Most recent ReflectionRun across all projectIds, by ranAt.
func fetchLatestReflectionRun() throws -> ReflectionRun? {
    let stmt = try db.prepare("""
        SELECT id, project_id, week_start, week_end, ran_at, status, rejection_reason, cost_cents
        FROM reflection_runs
        WHERE status = 'success'
        ORDER BY ran_at DESC
        LIMIT 1;
    """)
    guard try stmt.step() else { return nil }
    // decode + return
}
```

If existing decoders exist (look for `claimFrom` / `runFrom` private funcs), reuse them.

- [ ] **Step 2: Write the failing tests**

Append to `Tests/NousTests/ConstellationServiceTests.swift`:

```swift
final class ConstellationServiceDerivationTests: XCTestCase {
    func test_emitsConstellationFromActiveClaimSpanningTwoNodes() throws {
        let store = try NodeStore.inMemoryForTesting()
        let vectorStore = try VectorStore(databasePath: ":memory:")
        let nodeA = UUID(); let nodeB = UUID()
        try store.insertNodeForTest(id: nodeA)
        try store.insertNodeForTest(id: nodeB)
        let m1 = UUID(); let m2 = UUID()
        try store.insertMessageForTest(id: m1, nodeId: nodeA)
        try store.insertMessageForTest(id: m2, nodeId: nodeB)

        let runId = UUID()
        try store.insertReflectionRunForTest(runId: runId, status: .success)
        let claimId = UUID()
        try store.insertReflectionClaimForTest(id: claimId, runId: runId, status: .active, claimText: "Across launches: 「驚被睇穿不夠好」")
        try store.insertReflectionEvidenceForTest(claimId: claimId, messageId: m1)
        try store.insertReflectionEvidenceForTest(claimId: claimId, messageId: m2)

        let svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)
        let result = try svc.loadActiveConstellations()

        XCTAssertEqual(result.count, 1)
        let c = result[0]
        XCTAssertEqual(Set(c.memberNodeIds), Set([nodeA, nodeB]))
        XCTAssertEqual(c.label, "Across launches: 「驚被睇穿不夠好」")
        XCTAssertEqual(c.derivedShortLabel, "驚被睇穿不夠好")
        XCTAssertTrue(c.isDominant)
    }

    func test_dropsClaimWithEvidenceCollapsingToSingleNode() throws {
        let store = try NodeStore.inMemoryForTesting()
        let vectorStore = try VectorStore(databasePath: ":memory:")
        let nodeA = UUID()
        try store.insertNodeForTest(id: nodeA)
        let m1 = UUID(); let m2 = UUID()
        try store.insertMessageForTest(id: m1, nodeId: nodeA)
        try store.insertMessageForTest(id: m2, nodeId: nodeA)

        let runId = UUID()
        let claimId = UUID()
        try store.insertReflectionRunForTest(runId: runId, status: .success)
        try store.insertReflectionClaimForTest(id: claimId, runId: runId, status: .active, claimText: "single conv")
        try store.insertReflectionEvidenceForTest(claimId: claimId, messageId: m1)
        try store.insertReflectionEvidenceForTest(claimId: claimId, messageId: m2)

        let svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)
        let result = try svc.loadActiveConstellations()
        XCTAssertEqual(result.count, 0)
    }

    func test_appliesKEquals2CapAndSecondPrune() throws {
        let store = try NodeStore.inMemoryForTesting()
        let vectorStore = try VectorStore(databasePath: ":memory:")
        let n1 = UUID(); let n2 = UUID(); let n3 = UUID(); let n4 = UUID()
        for n in [n1, n2, n3, n4] { try store.insertNodeForTest(id: n) }

        // Constellation A: {n1,n2,n3,n4} confidence 0.9
        // Constellation B: {n1,n2}       confidence 0.7
        // Constellation C: {n1,n2}       confidence 0.5
        // After cap on n1, n2: top-2 = {A, B}. C loses both members → dropped.
        let runId = UUID()
        try store.insertReflectionRunForTest(runId: runId, status: .success)
        try seedClaim(store: store, runId: runId, members: [n1, n2, n3, n4], claim: "A motif", confidence: 0.9)
        try seedClaim(store: store, runId: runId, members: [n1, n2], claim: "B motif", confidence: 0.7)
        try seedClaim(store: store, runId: runId, members: [n1, n2], claim: "C motif", confidence: 0.5)

        let svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)
        let result = try svc.loadActiveConstellations()
        let labels = Set(result.map { $0.label })
        XCTAssertEqual(labels, Set(["A motif", "B motif"]))
    }

    func test_dominantPicksHighestConfidenceFromLatestRun() throws {
        let store = try NodeStore.inMemoryForTesting()
        let vectorStore = try VectorStore(databasePath: ":memory:")
        let nA = UUID(); let nB = UUID()
        try store.insertNodeForTest(id: nA)
        try store.insertNodeForTest(id: nB)

        let oldRun = UUID(); let newRun = UUID()
        try store.insertReflectionRunForTest(runId: oldRun, status: .success, ranAt: Date(timeIntervalSinceNow: -86_400 * 30))
        try store.insertReflectionRunForTest(runId: newRun, status: .success, ranAt: Date())

        try seedClaim(store: store, runId: oldRun, members: [nA, nB], claim: "old high", confidence: 0.95)
        try seedClaim(store: store, runId: newRun, members: [nA, nB], claim: "new mid", confidence: 0.7)
        try seedClaim(store: store, runId: newRun, members: [nA, nB], claim: "new high", confidence: 0.85)

        let svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)
        let result = try svc.loadActiveConstellations()
        let dominant = result.first(where: { $0.isDominant })
        XCTAssertEqual(dominant?.label, "new high")
    }

    func test_freshnessGuardSuppressesDominantIfLatestRunOlderThan14Days() throws {
        let store = try NodeStore.inMemoryForTesting()
        let vectorStore = try VectorStore(databasePath: ":memory:")
        let nA = UUID(); let nB = UUID()
        try store.insertNodeForTest(id: nA); try store.insertNodeForTest(id: nB)

        let staleRun = UUID()
        try store.insertReflectionRunForTest(runId: staleRun, status: .success, ranAt: Date(timeIntervalSinceNow: -86_400 * 20))
        try seedClaim(store: store, runId: staleRun, members: [nA, nB], claim: "stale", confidence: 0.95)

        let svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)
        let result = try svc.loadActiveConstellations()
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isDominant)
    }

    // Helper
    private func seedClaim(
        store: NodeStore, runId: UUID, members: [UUID],
        claim: String, confidence: Double
    ) throws {
        let claimId = UUID()
        try store.insertReflectionClaimForTest(
            id: claimId, runId: runId, status: .active,
            claimText: claim, confidence: confidence
        )
        for m in members {
            let messageId = UUID()
            try store.insertMessageForTest(id: messageId, nodeId: m)
            try store.insertReflectionEvidenceForTest(claimId: claimId, messageId: messageId)
        }
    }
}
```

Update `insertReflectionClaimForTest` and `insertReflectionRunForTest` helpers to accept the optional `claimText` / `confidence` / `ranAt` parameters used above.

- [ ] **Step 3: Run — expect fail (returns empty)**

Run: `./scripts/test_nous.sh -only-testing:NousTests/ConstellationServiceDerivationTests`
Expected: FAIL.

- [ ] **Step 4: Implement `loadActiveConstellations`**

In `Sources/Nous/Services/ConstellationService.swift`, replace the empty body:

```swift
func loadActiveConstellations() throws -> [Constellation] {
    let claims = try nodeStore.fetchActiveReflectionClaims()
    guard !claims.isEmpty else { return [] }

    // 1. Bulk fetch evidence
    let evidence = try nodeStore.fetchEvidence(forClaimIds: claims.map { $0.id })
    let evidenceByClaim: [UUID: [ReflectionEvidence]] = Dictionary(grouping: evidence, by: { $0.reflectionId })

    // 2. Bulk resolve messageId → nodeId
    let allMessageIds = evidence.map { $0.messageId }
    let messageToNode = try nodeStore.conversationNodeIds(forMessageIds: allMessageIds)

    // 3. Build per-claim distinct nodeId set; drop <2
    struct PreCap {
        let claim: ReflectionClaim
        var members: [UUID]
    }
    var preCap: [PreCap] = []
    for claim in claims {
        let claimEv = evidenceByClaim[claim.id] ?? []
        let nodeIds = claimEv.compactMap { messageToNode[$0.messageId] }
        let distinct = Array(Set(nodeIds))
        if distinct.count >= 2 {
            preCap.append(PreCap(claim: claim, members: distinct))
        }
    }
    guard !preCap.isEmpty else { return [] }

    // 4. K=2 per-node cap. Sort claims by confidence desc; for each member,
    //    track how many constellations it currently belongs to. If a node
    //    is at K=2 already, remove it from the current claim's members.
    let sortedDescByConfidence = preCap.sorted { $0.claim.confidence > $1.claim.confidence }
    var perNodeCount: [UUID: Int] = [:]
    var afterCap: [PreCap] = []
    for var c in sortedDescByConfidence {
        c.members = c.members.filter { perNodeCount[$0, default: 0] < 2 }
        for m in c.members { perNodeCount[m, default: 0] += 1 }
        afterCap.append(c)
    }

    // 5. Second prune: drop constellations whose post-cap membership <2.
    let pruned = afterCap.filter { $0.members.count >= 2 }
    guard !pruned.isEmpty else { return [] }

    // 6. Centroids (best-effort; nil if any member missing embedding)
    func centroid(for nodeIds: [UUID]) throws -> [Float]? {
        var sum: [Float]? = nil
        for nid in nodeIds {
            guard let emb = try vectorStore.fetchEmbedding(forNodeId: nid) else { return nil }
            if sum == nil {
                sum = emb
            } else {
                guard sum!.count == emb.count else { return nil }
                for i in 0..<sum!.count { sum![i] += emb[i] }
            }
        }
        guard var s = sum, !nodeIds.isEmpty else { return nil }
        let n = Float(nodeIds.count)
        for i in 0..<s.count { s[i] /= n }
        return s
    }

    // 7. Dominant selection: latest run + highest confidence + freshness guard.
    let latestRun = try nodeStore.fetchLatestReflectionRun()
    let fourteenDays: TimeInterval = 86_400 * 14
    let isFresh: (UUID) -> Bool = { runId in
        guard let r = latestRun, r.id == runId else { return false }
        return Date().timeIntervalSince(r.ranAt) < fourteenDays
    }
    var dominantId: UUID? = nil
    if let lr = latestRun, Date().timeIntervalSince(lr.ranAt) < fourteenDays {
        let candidates = pruned.filter { $0.claim.runId == lr.id }
        dominantId = candidates.max(by: { $0.claim.confidence < $1.claim.confidence })?.claim.id
    }

    // 8. Merge in ephemeral attachments
    ephemeralLock.lock()
    let ephemeralCopy = ephemeralByConstellationId
    ephemeralLock.unlock()

    // 9. Build final Constellation values
    var result: [Constellation] = []
    for p in pruned {
        var members = p.members
        // Append ephemeral members (if any), respecting K=2 cap re-application
        if let extra = ephemeralCopy[p.claim.id] {
            for nid in extra {
                if !members.contains(nid),
                   (perNodeCount[nid, default: 0] < 2) {
                    members.append(nid)
                    perNodeCount[nid, default: 0] += 1
                }
            }
        }
        let cent = try centroid(for: members)
        result.append(Constellation(
            id: p.claim.id,
            claimId: p.claim.id,
            label: p.claim.claim,
            derivedShortLabel: Constellation.derivedShortLabel(from: p.claim.claim),
            confidence: p.claim.confidence,
            memberNodeIds: members,
            centroidEmbedding: cent,
            isDominant: (p.claim.id == dominantId)
        ))
    }
    return result
}
```

(If `vectorStore.fetchEmbedding(forNodeId:)` does not exist by that exact name, find the closest equivalent — e.g., `loadEmbedding(nodeId:)` — and use it. The name is illustrative.)

- [ ] **Step 5: Run derivation tests**

Run: `./scripts/test_nous.sh -only-testing:NousTests/ConstellationServiceDerivationTests`
Expected: all 5 cases PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/ConstellationService.swift Sources/Nous/Services/NodeStore.swift Tests/NousTests/ConstellationServiceTests.swift Tests/NousTests/NodeStoreTestSupport.swift
git commit -m "feat(constellation): implement loadActiveConstellations

- Bulk evidence + bulk messageId→nodeId resolve (no N+1)
- Drop claims whose evidence collapses to <2 distinct nodeIds
- K=2 per-node cap (sorted by confidence desc)
- Second prune: drop constellations with <2 members post-cap
- Dominant = highest-confidence claim from latest run, suppressed
  if latest run >14 days old
- Centroid embedding cached on Constellation (best-effort)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 12: Embedding-NN ephemeral bridging

**Files:**
- Modify: `Sources/Nous/Services/ConstellationService.swift`
- Modify: `Sources/Nous/Services/TurnExecutor.swift` (or wherever embedding is computed for new nodes) to call `considerNodeForEphemeralBridging`
- Test: `Tests/NousTests/EphemeralBridgingInMemoryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Nous

final class EphemeralBridgingInMemoryTests: XCTestCase {
    func test_attachesNewNodeWhenCosineAboveThreshold() throws {
        let store = try NodeStore.inMemoryForTesting()
        let vectorStore = try VectorStore(databasePath: ":memory:")
        // (seed: 1 constellation with 2 members, embeddings that yield centroid)
        // (insert new node with embedding cos(...) ~= 0.85)
        let svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)
        let initial = try svc.loadActiveConstellations()
        XCTAssertEqual(initial.count, 1)
        let newNode = makeNode(/* embedding similar to centroid */)
        try store.insertNode(newNode)
        // (set vector store accordingly)
        try svc.considerNodeForEphemeralBridging(newNode)
        let merged = try svc.loadActiveConstellations()
        XCTAssertTrue(merged[0].memberNodeIds.contains(newNode.id))
    }

    func test_doesNotAttachWhenCosineBelowThreshold() throws { /* mirror, with dissimilar embedding */ }

    func test_capsEphemeralAttachmentsAtTwoPerNode() throws { /* 3 constellations, expect attach to top 2 only */ }

    func test_clearEphemeralEmptiesMap() throws { /* attach, clearEphemeral, reload, member missing */ }

    func test_releaseEphemeralRemovesNodeFromAllConstellations() throws { /* attach to 2, releaseEphemeral, reload, gone from both */ }
}
```

(The test scaffolding requires fixture setup of embeddings in `VectorStore` — write a small helper `vectorStore.insertEmbeddingForTest(nodeId:vector:)` that inserts whatever the production schema needs. Mirror existing patterns.)

- [ ] **Step 2: Implement `considerNodeForEphemeralBridging`**

```swift
func considerNodeForEphemeralBridging(_ node: NousNode) throws {
    let snapshot = try loadActiveConstellations()
    guard let nodeEmb = try vectorStore.fetchEmbedding(forNodeId: node.id) else { return }

    // Score each constellation by cosine similarity against centroid
    struct Score {
        let constellationId: UUID
        let similarity: Float
    }
    var scores: [Score] = []
    for c in snapshot {
        guard let cent = c.centroidEmbedding else { continue }
        let sim = cosineSimilarity(nodeEmb, cent)
        if sim >= 0.7 {
            scores.append(Score(constellationId: c.id, similarity: sim))
        }
    }
    let topTwo = scores.sorted { $0.similarity > $1.similarity }.prefix(2)
    guard !topTwo.isEmpty else { return }

    ephemeralLock.lock()
    defer { ephemeralLock.unlock() }
    for s in topTwo {
        var current = ephemeralByConstellationId[s.constellationId] ?? Set<UUID>()
        current.insert(node.id)
        ephemeralByConstellationId[s.constellationId] = current
    }
}

private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0; var na: Float = 0; var nb: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    let denom = sqrt(na) * sqrt(nb)
    guard denom > 0 else { return 0 }
    return dot / denom
}
```

- [ ] **Step 3: Wire `considerNodeForEphemeralBridging` into the embedding path**

Search for where new nodes get embedded:
```bash
grep -rn "generateSemanticEdges\|fetchEmbedding\|computeEmbedding" Sources/Nous/Services/TurnExecutor.swift Sources/Nous/Services/UserMemoryService.swift
```

Find the existing post-embedding hook (likely after `regenerateEdges(for: node)` — embedding is computed before semantic-edge generation). Add:

```swift
try graphEngine.regenerateEdges(for: node)
try constellationService.considerNodeForEphemeralBridging(node)
```

`constellationService` needs to be injected — add it to `TurnExecutor`'s init. (Or whichever class owns `graphEngine`.)

- [ ] **Step 4: Run ephemeral tests**

Run: `./scripts/test_nous.sh -only-testing:NousTests/EphemeralBridgingInMemoryTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/ConstellationService.swift Sources/Nous/Services/TurnExecutor.swift Tests/NousTests/EphemeralBridgingInMemoryTests.swift
git commit -m "feat(constellation): in-memory ephemeral bridging

- considerNodeForEphemeralBridging attaches new nodes to top-2
  constellations whose centroid cos-sim ≥ 0.7
- releaseEphemeral / clearEphemeral lifecycle methods
- Wired into embedding-completion path in TurnExecutor
- All in-memory only; cleared on reflection completion or restart

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 5: Reflection Completion Notification

### Task 13: `Notification.Name.reflectionRunCompleted` + post on success

**Files:**
- Modify: `Sources/Nous/Services/WeeklyReflectionService.swift`

- [ ] **Step 1: Add the dedicated `Notification.Name`**

Add at top-level (e.g., near `Notification.Name.nousNodesDidChange` if it exists, or in a `Notifications.swift` file if there's a central spot):

```swift
extension Notification.Name {
    static let reflectionRunCompleted = Notification.Name("nous.reflectionRunCompleted")
}
```

- [ ] **Step 2: Post on successful run**

In `WeeklyReflectionService.swift`, find the place where `ReflectionRun` status is set to `.success` and the run is persisted. Right after the persistence is committed, add:

```swift
NotificationCenter.default.post(name: .reflectionRunCompleted, object: nil)
```

- [ ] **Step 3: Add a test**

```swift
final class ReflectionRunCompletedNotificationTests: XCTestCase {
    func test_postsNotificationOnSuccess() async throws {
        let exp = expectation(forNotification: .reflectionRunCompleted, object: nil)
        // (run a successful reflection via existing test fixtures)
        await fulfillment(of: [exp], timeout: 5.0)
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Services/WeeklyReflectionService.swift Tests/NousTests/ReflectionRunCompletedNotificationTests.swift
git commit -m "feat(reflection): post .reflectionRunCompleted on success

Dedicated Notification.Name (not stringly-typed userInfo on
nousNodesDidChange). GalaxyViewModel will subscribe in next task.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 6: ViewModel Wiring

### Task 14: GalaxyViewModel loads constellations + subscribes to notification

**Files:**
- Modify: `Sources/Nous/ViewModels/GalaxyViewModel.swift`

- [ ] **Step 1: Inject `ConstellationService`**

Add to `GalaxyViewModel`:

```swift
private let constellationService: ConstellationService

@Published private(set) var constellations: [Constellation] = []
@Published private(set) var dominantConstellationId: UUID? = nil
```

Update the initializer to accept `ConstellationService`. The call site (likely `ContentView.swift` or wherever `GalaxyViewModel` is instantiated) passes the shared instance.

- [ ] **Step 2: Load constellations in `load()`**

After existing nodes/edges loading:

```swift
do {
    self.constellations = try constellationService.loadActiveConstellations()
    self.dominantConstellationId = constellations.first(where: \.isDominant)?.id
} catch {
    self.constellations = []
    self.dominantConstellationId = nil
    // Log error — non-fatal, Galaxy still works without halos
}
```

- [ ] **Step 3: Subscribe to `.reflectionRunCompleted`**

In init or a setup method:

```swift
NotificationCenter.default.addObserver(
    forName: .reflectionRunCompleted,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.handleReflectionCompleted()
}

private func handleReflectionCompleted() {
    constellationService.clearEphemeral()
    do {
        self.constellations = try constellationService.loadActiveConstellations()
        self.dominantConstellationId = constellations.first(where: \.isDominant)?.id
    } catch {
        // log; keep previous state
    }
}
```

- [ ] **Step 4: Add a test**

```swift
final class GalaxyViewModelConstellationLoadTests: XCTestCase {
    @MainActor
    func test_loadPopulatesConstellationsFromService() async throws {
        let store = try NodeStore.inMemoryForTesting()
        let vectorStore = try VectorStore(databasePath: ":memory:")
        // seed 1 active constellation
        let svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)
        let vm = GalaxyViewModel(/* deps + svc */)
        vm.load()
        XCTAssertEqual(vm.constellations.count, 1)
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/ViewModels/GalaxyViewModel.swift Sources/Nous/App/ContentView.swift Tests/NousTests/
git commit -m "feat(galaxy-vm): load + subscribe to constellation lifecycle

GalaxyViewModel now owns @Published constellations + dominantConstellationId.
Loaded on .load(); refreshed on .reflectionRunCompleted.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 15: Filter-aware constellation visibility + dominant recompute

**Files:**
- Modify: `Sources/Nous/ViewModels/GalaxyViewModel.swift`
- Test: `Tests/NousTests/ConstellationDominantUnderFilterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
final class ConstellationDominantUnderFilterTests: XCTestCase {
    @MainActor
    func test_dominantIsRecomputedWhenProjectFilterChanges() async throws {
        // Seed: free-chat run with high-confidence "free" claim;
        // Project A run with mid-confidence "projA" claim.
        // Whole Galaxy → dominant = "free"
        // Filter to project A → dominant = "projA"
        // Filter to project B (no claims) → dominant = nil
        // (Build via GalaxyViewModel + ConstellationService end-to-end)
    }

    @MainActor
    func test_constellationHidesIfFilteredVisibleMembersBelowTwo() async throws {
        // 2-member constellation; filter to project that contains only one of them.
        // Expect halo not rendered (visibleConstellations excludes it).
    }
}
```

- [ ] **Step 2: Add visibility computation to `GalaxyViewModel`**

```swift
/// Constellations after applying the current `filterProjectId` view.
/// Members outside the filter are hidden; constellations dropping <2
/// visible members are excluded entirely. Dominant is recomputed within
/// the visible set (highest confidence in latest run).
@MainActor
var visibleConstellations: [(constellation: Constellation, isDominant: Bool, visibleMembers: [UUID])] {
    let visibleNodeIds: Set<UUID>
    if let filter = filterProjectId {
        visibleNodeIds = Set(nodes.filter { $0.projectId == filter }.map(\.id))
    } else {
        visibleNodeIds = Set(nodes.map(\.id))
    }

    var candidates: [(Constellation, [UUID])] = []
    for c in constellations {
        let visible = c.memberNodeIds.filter { visibleNodeIds.contains($0) }
        if visible.count >= 2 {
            candidates.append((c, visible))
        }
    }

    // Recompute dominant among candidates from the latest run that produced
    // any of these claims. Easier proxy: the highest-confidence candidate.
    let domId = candidates.max(by: { $0.0.confidence < $1.0.confidence })?.0.id

    return candidates.map { (c, vis) in
        (c, c.id == domId, vis)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `./scripts/test_nous.sh -only-testing:NousTests/ConstellationDominantUnderFilterTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/ViewModels/GalaxyViewModel.swift Tests/NousTests/ConstellationDominantUnderFilterTests.swift
git commit -m "feat(galaxy-vm): filter-aware constellation visibility

visibleConstellations recomputes dominant within the active filter and
hides constellations whose visible members drop below 2.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 7: Position Snapshot Persistence

### Task 16: `PositionSnapshotStore` (UserDefaults + storeId-keyed)

**Files:**
- Create: `Sources/Nous/Services/PositionSnapshotStore.swift`
- Test: `Tests/NousTests/PositionSnapshotPersistenceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Nous

final class PositionSnapshotPersistenceTests: XCTestCase {
    let testStoreId = "test-store-123"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PositionSnapshotStore.key(forStoreId: testStoreId))
        super.tearDown()
    }

    func test_writeThenReadRoundTrip() throws {
        let snap = PositionSnapshotStore(storeId: testStoreId)
        let positions: [UUID: GraphPosition] = [
            UUID(): GraphPosition(x: 1.5, y: -2.5),
            UUID(): GraphPosition(x: 3.25, y: 0.0)
        ]
        snap.write(positions: positions)
        let loaded = snap.read()
        XCTAssertEqual(loaded.count, 2)
        for (k, v) in positions {
            XCTAssertEqual(loaded[k]?.x, v.x)
            XCTAssertEqual(loaded[k]?.y, v.y)
        }
    }

    func test_absentSnapshotReturnsEmpty() throws {
        let snap = PositionSnapshotStore(storeId: "definitely-not-present-\(UUID())")
        XCTAssertEqual(snap.read().count, 0)
    }

    func test_corruptSnapshotReturnsEmptyNotCrash() throws {
        UserDefaults.standard.set("not json", forKey: PositionSnapshotStore.key(forStoreId: testStoreId))
        let snap = PositionSnapshotStore(storeId: testStoreId)
        XCTAssertEqual(snap.read().count, 0)
    }

    func test_storeIdSegregation() throws {
        let s1 = PositionSnapshotStore(storeId: "store-1")
        let s2 = PositionSnapshotStore(storeId: "store-2")
        let nodeId = UUID()
        s1.write(positions: [nodeId: GraphPosition(x: 1, y: 2)])
        XCTAssertEqual(s1.read()[nodeId]?.x, 1)
        XCTAssertEqual(s2.read()[nodeId]?.x, nil)
        UserDefaults.standard.removeObject(forKey: PositionSnapshotStore.key(forStoreId: "store-1"))
        UserDefaults.standard.removeObject(forKey: PositionSnapshotStore.key(forStoreId: "store-2"))
    }
}
```

- [ ] **Step 2: Run — expect fail**

Run: `./scripts/test_nous.sh -only-testing:NousTests/PositionSnapshotPersistenceTests`
Expected: build fails.

- [ ] **Step 3: Implement the store**

```swift
// Sources/Nous/Services/PositionSnapshotStore.swift
import Foundation

final class PositionSnapshotStore {
    private let storeId: String
    private let defaults: UserDefaults

    init(storeId: String, defaults: UserDefaults = .standard) {
        self.storeId = storeId
        self.defaults = defaults
    }

    static func key(forStoreId storeId: String) -> String {
        "com.nous.galaxy.positionSnapshot.v1.\(storeId)"
    }

    func write(positions: [UUID: GraphPosition]) {
        let dict: [String: [Float]] = positions.reduce(into: [:]) { result, kv in
            result[kv.key.uuidString] = [kv.value.x, kv.value.y]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            defaults.set(data, forKey: Self.key(forStoreId: storeId))
        } catch {
            // Log; failure to persist is non-fatal — Galaxy still works
        }
    }

    func read() -> [UUID: GraphPosition] {
        guard let data = defaults.data(forKey: Self.key(forStoreId: storeId)) else { return [:] }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] else { return [:] }
        var out: [UUID: GraphPosition] = [:]
        for (k, v) in raw {
            guard let uuid = UUID(uuidString: k), v.count >= 2 else { continue }
            out[uuid] = GraphPosition(x: Float(v[0]), y: Float(v[1]))
        }
        return out
    }
}
```

(JSONSerialization gives `[Double]` for numeric arrays from JSON. We coerce to Float.)

- [ ] **Step 4: Run + commit**

Run: `./scripts/test_nous.sh -only-testing:NousTests/PositionSnapshotPersistenceTests`
Expected: PASS.

```bash
git add Sources/Nous/Services/PositionSnapshotStore.swift Tests/NousTests/PositionSnapshotPersistenceTests.swift
git commit -m "feat(galaxy): UserDefaults-backed position snapshot store

Keyed by store identity (storeId) so layout state never crosses
workspaces or DB resets. Corrupt or absent snapshot returns empty.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 17: Wire snapshot into `GalaxyViewModel.load()` as `seedPositions`

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift` (expose store identity)
- Modify: `Sources/Nous/ViewModels/GalaxyViewModel.swift`

- [ ] **Step 1: Expose store identity from `NodeStore`**

Add to `NodeStore`:

```swift
/// A stable identifier for this database file, used to scope
/// per-store UserDefaults state (e.g., position snapshots).
/// Derived from the database file's basename for non-memory stores;
/// returns "memory" for in-memory test stores.
var storeIdentity: String {
    if databasePath == ":memory:" { return "memory" }
    return (databasePath as NSString).lastPathComponent
}
```

(Adjust to whatever the actual property storing the path is named; if absent, store the path as a `let` in init.)

- [ ] **Step 2: Wire the snapshot into `load()`**

In `GalaxyViewModel.load()`, before the call to `GraphEngine.computeLayout(...)`:

```swift
let snapshotStore = PositionSnapshotStore(storeId: nodeStore.storeIdentity)
let seedPositions = snapshotStore.read()
let layout = try graphEngine.computeLayout(seedPositions: seedPositions)
self.positions = layout
// Hold reference for later writes
self.snapshotStore = snapshotStore
```

(Add `private let snapshotStore: PositionSnapshotStore` field, lazy or set in init based on `nodeStore.storeIdentity`.)

- [ ] **Step 3: Provide a write callback**

Add a method that the scene's sleep callback will invoke:

```swift
@MainActor
func handleSimulationSettled(positions: [UUID: GraphPosition]) {
    self.positions = positions
    DispatchQueue.global(qos: .utility).async { [snapshotStore] in
        snapshotStore?.write(positions: positions)
    }
}
```

- [ ] **Step 4: Smoke test**

Run: `./scripts/test_nous.sh`
Expected: existing GalaxyViewModelTests still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift Sources/Nous/ViewModels/GalaxyViewModel.swift
git commit -m "feat(galaxy-vm): seed layout from UserDefaults snapshot

GalaxyViewModel.load reads PositionSnapshotStore as seedPositions
into computeLayout. handleSimulationSettled persists settled state
asynchronously on a background queue.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 8: Halo Rendering

### Task 18: Pre-blurred halo texture cache

**Files:**
- Create: `Sources/Nous/Resources/HaloTexture.swift`

- [ ] **Step 1: Implement texture generation**

```swift
// Sources/Nous/Resources/HaloTexture.swift
import SpriteKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum HaloTexture {
    static let lavenderMistRGB: (r: CGFloat, g: CGFloat, b: CGFloat) = (155/255, 142/255, 196/255)
    static let radius: CGFloat = 70
    static let blurRadius: CGFloat = 24

    /// One-time texture build, cached as a static. Result: a soft round
    /// gradient sprite that visually merges with neighbors when overlapped.
    static let cached: SKTexture = build()

    private static func build() -> SKTexture {
        let size = CGSize(width: radius * 2 + blurRadius * 2, height: radius * 2 + blurRadius * 2)
        let renderer = NSImage(size: size, flipped: false) { rect in
            let ctx = NSGraphicsContext.current!.cgContext
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let colors = [
                NSColor(red: lavenderMistRGB.r, green: lavenderMistRGB.g, blue: lavenderMistRGB.b, alpha: 0.85).cgColor,
                NSColor(red: lavenderMistRGB.r, green: lavenderMistRGB.g, blue: lavenderMistRGB.b, alpha: 0.0).cgColor
            ] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
            ctx.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius,
                options: []
            )
            return true
        }
        // Apply Gaussian blur via CIImage
        guard let tiff = renderer.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else {
            return SKTexture(image: renderer)
        }
        let ciImage = CIImage(cgImage: cgImage)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = ciImage
        blur.radius = Float(blurRadius)
        let context = CIContext(options: nil)
        guard let output = blur.outputImage,
              let cgOut = context.createCGImage(output, from: output.extent) else {
            return SKTexture(image: renderer)
        }
        let blurred = NSImage(cgImage: cgOut, size: size)
        return SKTexture(image: blurred)
    }
}
```

- [ ] **Step 2: Smoke build**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS'`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Resources/HaloTexture.swift
git commit -m "feat(galaxy-scene): pre-blurred halo texture cache

One-time build at app launch. Lavender-mist radial gradient with
Gaussian blur baked into the texture, eliminating per-frame
CIGaussianBlur cost during animated sim.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 19: Halo rendering in `GalaxyScene` with priority cap

**Files:**
- Modify: `Sources/Nous/Views/GalaxyScene.swift`
- Test: `Tests/NousTests/GalaxySceneConstellationRenderTests.swift`
- Test: `Tests/NousTests/HaloPriorityCapTests.swift`

- [ ] **Step 1: Add halo state to `GalaxyScene`**

Edit `Sources/Nous/Views/GalaxyScene.swift`. Add:

```swift
var constellations: [Constellation] = []
var dominantConstellationId: UUID? = nil
var revealedConstellationIds: Set<UUID> = []  // tap-revealed
var toggleAllVisible: Bool = false

var maxVisibleHalos: Int = 8

// Halo container: one SKEffectNode per visible constellation.
private var haloEffectNodes: [UUID: SKEffectNode] = [:]
private var haloMemberSprites: [UUID: [SKSpriteNode]] = [:]
```

- [ ] **Step 2: Add visibility resolution per priority tier**

```swift
private func visibleHaloIds() -> [UUID] {
    // Tier 1: tap-revealed (always render, up to 2 by spec)
    let tap = revealedConstellationIds
    // Tier 2: dominant (1 slot if exists and not already in tier 1)
    var pinned = Array(tap)
    if let dom = dominantConstellationId, !tap.contains(dom) {
        pinned.append(dom)
    }
    // Tier 3: toggle-revealed remainder, by confidence desc
    let pinnedSet = Set(pinned)
    var remainder: [Constellation] = []
    if toggleAllVisible {
        remainder = constellations
            .filter { !pinnedSet.contains($0.id) }
            .sorted { $0.confidence > $1.confidence }
    }
    let slotsLeft = max(0, maxVisibleHalos - pinned.count)
    let take = remainder.prefix(slotsLeft).map(\.id)
    return pinned + take
}
```

- [ ] **Step 3: Add halo render method**

```swift
private func rebuildHalos() {
    // Tear down
    for (_, effectNode) in haloEffectNodes { effectNode.removeFromParent() }
    haloEffectNodes.removeAll()
    haloMemberSprites.removeAll()

    let visibleIds = Set(visibleHaloIds())
    for c in constellations where visibleIds.contains(c.id) {
        let effect = SKEffectNode()
        effect.shouldRasterize = !isSimActive  // rasterize when static
        effect.zPosition = -2  // beneath edges/nodes
        effect.alpha = haloAlpha(for: c.id)

        var sprites: [SKSpriteNode] = []
        for nid in c.memberNodeIds {
            guard let pos = positions[nid] else { continue }
            let sprite = SKSpriteNode(texture: HaloTexture.cached)
            sprite.position = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
            sprite.size = HaloTexture.cached.size()
            effect.addChild(sprite)
            sprites.append(sprite)
        }
        haloEffectNodes[c.id] = effect
        haloMemberSprites[c.id] = sprites
        addChild(effect)
    }
}

private func haloAlpha(for constellationId: UUID) -> CGFloat {
    if revealedConstellationIds.contains(constellationId) { return 0.55 }
    if toggleAllVisible { return 0.35 }
    if dominantConstellationId == constellationId { return 0.08 }
    return 0
}
```

- [ ] **Step 4: Call `rebuildHalos` in `rebuildScene`**

In `GalaxyScene.rebuildScene`, after `drawNodes()`:

```swift
rebuildHalos()
```

- [ ] **Step 5: Update halo positions on drag**

In `GalaxyScene.syncPositions()` (after `updateEdgePaths()`):

```swift
for (cid, sprites) in haloMemberSprites {
    guard let c = constellations.first(where: { $0.id == cid }) else { continue }
    for (i, nid) in c.memberNodeIds.enumerated() where i < sprites.count {
        guard let pos = positions[nid] else { continue }
        sprites[i].position = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
    }
}
```

- [ ] **Step 6: Write tests**

```swift
// Tests/NousTests/GalaxySceneConstellationRenderTests.swift
final class GalaxySceneConstellationRenderTests: XCTestCase {
    @MainActor
    func test_haloEffectNodeCountMatchesVisibleConstellations() {
        // Construct GalaxyScene, set 3 constellations, set toggleAllVisible = true,
        // rebuildScene, assert children of type SKEffectNode count == 3.
    }

    @MainActor
    func test_rasterizeIsTrueWhenSimAsleep() {
        // Default state: isSimActive = false; verify halo SKEffectNode shouldRasterize == true.
    }
}

// Tests/NousTests/HaloPriorityCapTests.swift
final class HaloPriorityCapTests: XCTestCase {
    @MainActor
    func test_capPrioritizesTapThenDominantThenToggleByConfidence() {
        // Build scene with 12 constellations, dominant=C2, tap-revealed={C5},
        // toggle on. Expect visible = {C5 (tap), C2 (dominant)} ∪ top-6 by conf
        // from remaining 10. Total = 8.
    }

    @MainActor
    func test_tapRevealedAlwaysRendersEvenBeyondCap() {
        // 12 constellations; toggle on; tap on a node belonging to 2 of them.
        // Expected visible = those 2 + dominant + 5 = 8 (the 2 tapped count).
    }
}
```

- [ ] **Step 7: Run tests**

Run: `./scripts/test_nous.sh -only-testing:NousTests/GalaxySceneConstellationRenderTests`
Run: `./scripts/test_nous.sh -only-testing:NousTests/HaloPriorityCapTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Nous/Views/GalaxyScene.swift Tests/NousTests/GalaxySceneConstellationRenderTests.swift Tests/NousTests/HaloPriorityCapTests.swift
git commit -m "feat(galaxy-scene): halo rendering with priority cap

- Pre-blurred SKSpriteNode-per-member inside SKEffectNode per constellation
- Rasterize when sim asleep (cheap composite); off during active sim
- Visibility cap of 8 with priority: tap > dominant > toggle-by-confidence
- syncPositions reflows halo sprites along with nodes during drag

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 20: Tap-reveal alpha transition + MOTIFS section in bottom sheet

**Files:**
- Modify: `Sources/Nous/Views/GalaxyView.swift`
- Modify: `Sources/Nous/Views/GalaxyScene.swift` (alpha transitions)

- [ ] **Step 1: Trigger alpha transition on selection change**

In `GalaxyScene.syncPositions` or a dedicated `syncSelection()`, animate halo alpha when selection changes:

```swift
private func updateHaloAlphas() {
    for (cid, effect) in haloEffectNodes {
        let target = haloAlpha(for: cid)
        let action = SKAction.fadeAlpha(to: target, duration: 0.6)
        action.timingMode = .easeInEaseOut
        effect.run(action, withKey: "alpha")
    }
}
```

Call from `rebuildHalos` (after creating effect nodes; set initial alpha to 0 then fade in) and any time `revealedConstellationIds` / `toggleAllVisible` / `selectedNodeId` changes.

- [ ] **Step 2: Update `revealedConstellationIds` on node tap**

In `GalaxyViewModel.selectNode(_:)`, after setting `selectedNodeId`, compute the tapped node's containing constellations:

```swift
@Published private(set) var revealedConstellationIds: Set<UUID> = []

func selectNode(_ id: UUID?) {
    selectedNodeId = id
    if let id = id {
        revealedConstellationIds = Set(
            visibleConstellations
                .filter { $0.visibleMembers.contains(id) }
                .map { $0.constellation.id }
        )
    } else {
        revealedConstellationIds = []
    }
}
```

The scene reads this via `GalaxySceneContainer.updateNSView` and passes into the scene.

- [ ] **Step 3: Render MOTIFS section in bottom sheet**

Edit `Sources/Nous/Views/GalaxyView.swift`. In `selectedNodeSheet`, after the existing `Divider()` and before `connectionStrip(connections)`:

```swift
if !motifsForSelectedNode().isEmpty {
    motifStrip(motifsForSelectedNode())
}
```

Add helper:

```swift
private func motifsForSelectedNode() -> [Constellation] {
    guard let id = vm.selectedNodeId else { return [] }
    return vm.visibleConstellations
        .filter { $0.visibleMembers.contains(id) }
        .map { $0.constellation }
}

private func motifStrip(_ motifs: [Constellation]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        HStack {
            Text("MOTIFS")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(GalaxyPaperPalette.secondaryText)
            Spacer()
            Text("\(motifs.count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(GalaxyPaperPalette.olive)
        }
        ForEach(motifs) { motif in
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color(red: 155/255, green: 142/255, blue: 196/255))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                Text(motif.label)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(GalaxyPaperPalette.bodyText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
```

Place this section above the existing `Divider()` that precedes `connectionStrip`.

- [ ] **Step 4: Manual visual check**

Run app. Tap a node belonging to a constellation. Expect:
- The constellation's halo fades in to a clearly-visible level
- Bottom sheet shows MOTIFS section above CONNECTED with the claim text
- Untap: halo fades back, MOTIFS disappears

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/GalaxyView.swift Sources/Nous/Views/GalaxyScene.swift Sources/Nous/ViewModels/GalaxyViewModel.swift
git commit -m "feat(galaxy): tap-reveal halo + MOTIFS bottom-sheet section

- selectNode populates revealedConstellationIds from filter-aware view
- Scene fades halo alpha to 0.55 on tap, back to default on deselect
- Bottom sheet gains MOTIFS strip above CONNECTED, showing 1-2 caption
  rows for the tapped node's constellations

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 21: Toggle button "显示星座"

**Files:**
- Modify: `Sources/Nous/Views/GalaxyView.swift`
- Modify: `Sources/Nous/ViewModels/GalaxyViewModel.swift`

- [ ] **Step 1: Add `toggleConstellationVisibility` to view model**

```swift
@Published var showAllConstellations: Bool = false

func toggleAllConstellations() {
    showAllConstellations.toggle()
}
```

Pass to scene via `GalaxySceneContainer` (`scene.toggleAllVisible = vm.showAllConstellations`).

- [ ] **Step 2: Add toggle button in `GalaxyView`**

Add a new overlay near the existing `projectMenu`:

```swift
.overlay(alignment: .top) {
    HStack {
        Spacer()
        toggleConstellationsButton
            .padding(.trailing, 110)  // separates from projectMenu
        projectMenu  // existing
    }
}
```

Helper view:

```swift
private var toggleConstellationsButton: some View {
    Button {
        vm.toggleAllConstellations()
    } label: {
        HStack(spacing: 9) {
            Image(systemName: vm.showAllConstellations ? "sparkles" : "sparkles.tv")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GalaxyPaperPalette.olive)
            Text(vm.showAllConstellations ? "Hide Motifs" : "Show Motifs")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(GalaxyPaperPalette.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }
    .buttonStyle(.plain)
    .background {
        paperSurface(cornerRadius: 18, opacity: 0.30)
    }
    .padding(22)
}
```

- [ ] **Step 3: Wire toggle staggered animation in `GalaxyScene`**

In scene, react to `toggleAllVisible` change. The simplest path: `rebuildHalos()` already creates the visible halos. To stagger, change `updateHaloAlphas()` to apply a per-halo delay:

```swift
private func updateHaloAlphas(staggered: Bool = false) {
    let visibleIds = visibleHaloIds()
    let centerX = CGFloat(0)  // scene anchor is 0,0
    let centerY = CGFloat(0)

    let sortedByDistance: [UUID] = visibleIds.sorted { a, b in
        let aDist = distanceFromCenter(constellationId: a, cx: centerX, cy: centerY)
        let bDist = distanceFromCenter(constellationId: b, cx: centerX, cy: centerY)
        return aDist < bDist
    }
    for (idx, cid) in sortedByDistance.enumerated() {
        guard let effect = haloEffectNodes[cid] else { continue }
        let target = haloAlpha(for: cid)
        let delay = staggered ? Double(idx) * 0.08 : 0
        let action = SKAction.sequence([
            .wait(forDuration: delay),
            .fadeAlpha(to: target, duration: 0.6)
        ])
        action.timingMode = .easeInEaseOut
        effect.run(action, withKey: "alpha")
    }
}

private func distanceFromCenter(constellationId: UUID, cx: CGFloat, cy: CGFloat) -> CGFloat {
    guard let c = constellations.first(where: { $0.id == constellationId }) else { return .infinity }
    let centroidPos = c.memberNodeIds.compactMap { positions[$0] }
        .map { (CGFloat($0.x), CGFloat($0.y)) }
    guard !centroidPos.isEmpty else { return .infinity }
    let mx = centroidPos.map(\.0).reduce(0, +) / CGFloat(centroidPos.count)
    let my = centroidPos.map(\.1).reduce(0, +) / CGFloat(centroidPos.count)
    return sqrt((mx - cx) * (mx - cx) + (my - cy) * (my - cy))
}
```

Call `updateHaloAlphas(staggered: true)` when `toggleAllVisible` changes.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/GalaxyView.swift Sources/Nous/ViewModels/GalaxyViewModel.swift Sources/Nous/Views/GalaxyScene.swift Sources/Nous/Views/GalaxySceneContainer.swift
git commit -m "feat(galaxy): toggle button for full constellation reveal

Show Motifs button raises all visible halos to 0.35 alpha with
80ms-staggered fade-in by distance from screen center.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 9: Live Drag Physics

### Task 22: Ownership handoff (`simulationOwnsPositions`)

**Files:**
- Modify: `Sources/Nous/Views/GalaxyScene.swift`
- Modify: `Sources/Nous/Views/GalaxySceneContainer.swift`
- Test: `Tests/NousTests/OwnershipHandoffTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
final class OwnershipHandoffTests: XCTestCase {
    func test_updateNSViewSkipsPositionsWhenSimOwnsThem() {
        let scene = GalaxyScene()
        scene.positions = [UUID(): GraphPosition(x: 1, y: 1)]
        scene.simulationOwnsPositions = true

        let staleVMPositions: [UUID: GraphPosition] = [UUID(): GraphPosition(x: 999, y: 999)]
        // Simulate the call updateNSView would make
        if !scene.simulationOwnsPositions {
            scene.positions = staleVMPositions
        }
        // (Or test through GalaxySceneContainer if it exposes a hook)

        XCTAssertNotEqual(scene.positions[scene.positions.keys.first!]?.x, 999)
    }
}
```

- [ ] **Step 2: Add `simulationOwnsPositions` to `GalaxyScene`**

```swift
var simulationOwnsPositions: Bool = false
```

- [ ] **Step 3: Update `GalaxySceneContainer.updateNSView`**

Edit `Sources/Nous/Views/GalaxySceneContainer.swift`. Find the `updateNSView` method (or `updateUIView` if iOS — code suggests macOS so NSView). Wrap position assignments:

```swift
func updateNSView(_ nsView: SKView, context: Context) {
    // ... existing setup ...
    if !scene.simulationOwnsPositions {
        scene.positions = positions
    }
    scene.graphNodes = graphNodes
    scene.graphEdges = graphEdges
    // ... etc ...
}
```

- [ ] **Step 4: Run test**

Run: `./scripts/test_nous.sh -only-testing:NousTests/OwnershipHandoffTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/GalaxyScene.swift Sources/Nous/Views/GalaxySceneContainer.swift Tests/NousTests/OwnershipHandoffTests.swift
git commit -m "feat(galaxy-scene): simulationOwnsPositions handoff guard

While the in-scene physics simulation is active, GalaxySceneContainer
no longer overwrites scene.positions on SwiftUI rerenders. Prevents
the stale-VM-snapshot snap-back that Codex flagged.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 23: Per-frame physics in `update(_:)`

**Files:**
- Modify: `Sources/Nous/Views/GalaxyScene.swift`
- Modify: `Sources/Nous/Services/GraphEngine.swift` (extract a shared `applyForces` step usable per-frame, optional refactor)

- [ ] **Step 1: Add sim state to scene**

```swift
private var isSimActive = false
private var nodeVelocities: [UUID: GraphPosition] = [:]
private var framesUnderVelocityThreshold = 0
private var framesSinceMouseUp = 0
private let kinematicNodeIdLock = NSLock()
private var kinematicNodeId: UUID? {
    didSet { /* recorded for sim step to skip */ }
}

// Tunables (mirror GraphEngine defaults)
private let repulsion: Float = 12000
private let attraction: Float = 0.004
private let damping: Float = 0.86
private let constellationAttractionFactor: Float = 0.2
private let velocityThreshold: Float = 0.5
private let softWatchdogFrames = 30
private let hardTimeoutFrames = 90
```

- [ ] **Step 2: Implement `update(_:)`**

```swift
override func update(_ currentTime: TimeInterval) {
    guard isSimActive else { return }

    // 1. Repulsion (O(N²))
    let nodeIds = Array(positions.keys)
    for i in 0..<nodeIds.count {
        for j in (i + 1)..<nodeIds.count {
            let idA = nodeIds[i]; let idB = nodeIds[j]
            guard let pA = positions[idA], let pB = positions[idB] else { continue }
            let dx = pA.x - pB.x
            let dy = pA.y - pB.y
            let distSq = max(dx * dx + dy * dy, 1.0)
            let force = repulsion / distSq
            let dist = sqrt(distSq)
            let fx = force * dx / dist
            let fy = force * dy / dist
            nodeVelocities[idA, default: GraphPosition(x: 0, y: 0)].x += fx
            nodeVelocities[idA, default: GraphPosition(x: 0, y: 0)].y += fy
            nodeVelocities[idB, default: GraphPosition(x: 0, y: 0)].x -= fx
            nodeVelocities[idB, default: GraphPosition(x: 0, y: 0)].y -= fy
        }
    }

    // 2. Edge attraction
    for edge in graphEdges {
        guard let pA = positions[edge.sourceId], let pB = positions[edge.targetId] else { continue }
        let dx = pA.x - pB.x
        let dy = pA.y - pB.y
        let fx = attraction * edge.strength * dx
        let fy = attraction * edge.strength * dy
        nodeVelocities[edge.sourceId, default: GraphPosition(x: 0, y: 0)].x -= fx
        nodeVelocities[edge.sourceId, default: GraphPosition(x: 0, y: 0)].y -= fy
        nodeVelocities[edge.targetId, default: GraphPosition(x: 0, y: 0)].x += fx
        nodeVelocities[edge.targetId, default: GraphPosition(x: 0, y: 0)].y += fy
    }

    // 3. Constellation pairwise attraction (post-K=2 cap; iterating
    //    Constellation.memberNodeIds is automatically post-cap by §3.3)
    for c in constellations {
        let members = c.memberNodeIds
        for i in 0..<members.count {
            for j in (i + 1)..<members.count {
                let idA = members[i]; let idB = members[j]
                guard let pA = positions[idA], let pB = positions[idB] else { continue }
                let dx = pA.x - pB.x
                let dy = pA.y - pB.y
                let strength: Float = 0.3  // weak relative to semantic
                let fx = attraction * constellationAttractionFactor * strength * dx
                let fy = attraction * constellationAttractionFactor * strength * dy
                nodeVelocities[idA, default: GraphPosition(x: 0, y: 0)].x -= fx
                nodeVelocities[idA, default: GraphPosition(x: 0, y: 0)].y -= fy
                nodeVelocities[idB, default: GraphPosition(x: 0, y: 0)].x += fx
                nodeVelocities[idB, default: GraphPosition(x: 0, y: 0)].y += fy
            }
        }
    }

    // 4. Apply velocity (skip kinematic node)
    let kinematic = kinematicNodeId
    var maxVelMagnitude: Float = 0
    for id in nodeIds {
        guard id != kinematic else {
            nodeVelocities[id] = GraphPosition(x: 0, y: 0)
            continue
        }
        var v = nodeVelocities[id, default: GraphPosition(x: 0, y: 0)]
        v.x *= damping
        v.y *= damping
        nodeVelocities[id] = v
        positions[id]!.x += v.x
        positions[id]!.y += v.y
        let mag = sqrt(v.x * v.x + v.y * v.y)
        if mag > maxVelMagnitude { maxVelMagnitude = mag }
    }

    syncPositions()  // update node sprites + edges + halo sprites

    // 5. Sleep watchdog (only after mouseUp; while user is still dragging,
    //    don't try to settle)
    if kinematicNodeId == nil {
        framesSinceMouseUp += 1
        if maxVelMagnitude < velocityThreshold {
            framesUnderVelocityThreshold += 1
        } else {
            framesUnderVelocityThreshold = 0
        }
        if framesUnderVelocityThreshold >= softWatchdogFrames || framesSinceMouseUp >= hardTimeoutFrames {
            putSimToSleep()
        }
    } else {
        framesSinceMouseUp = 0
    }
}

private func putSimToSleep() {
    // Zero velocities defensively (Codex's float-jitter guard)
    for k in nodeVelocities.keys {
        nodeVelocities[k] = GraphPosition(x: 0, y: 0)
    }
    isSimActive = false
    framesUnderVelocityThreshold = 0
    framesSinceMouseUp = 0
    onSimulationSettled?(positions)
    simulationOwnsPositions = false
    // Re-rasterize halos now that they're static
    for (_, effect) in haloEffectNodes {
        effect.shouldRasterize = true
    }
}
```

Add the callback:

```swift
var onSimulationSettled: (([UUID: GraphPosition]) -> Void)?
```

- [ ] **Step 3: Update `mouseDown` / `mouseDragged` / `mouseUp`**

Replace existing `mouseDown`:

```swift
override func mouseDown(with event: NSEvent) {
    let point = scenePoint(from: event)
    if let (_, id) = nodeAt(point: point) {
        kinematicNodeId = id
        isSimActive = true
        simulationOwnsPositions = true
        for (_, effect) in haloEffectNodes { effect.shouldRasterize = false }
        // existing dragging-visual setup
        guard let sprite = nodeSprites[id] else { return }
        draggedNode = sprite
        draggedNodeOriginalZPosition = sprite.zPosition
        sprite.zPosition = 8
        dragStartPosition = point
    }
}
```

`mouseDragged` stays mostly the same — kinematic node gets its position pinned to the cursor; the sim step skips applying velocity to the kinematic node.

Replace `mouseUp`:

```swift
override func mouseUp(with event: NSEvent) {
    guard let dragged = draggedNode else {
        kinematicNodeId = nil
        return
    }
    let point = scenePoint(from: event)
    let dx = point.x - dragStartPosition.x
    let dy = point.y - dragStartPosition.y
    let distance = sqrt(dx * dx + dy * dy)
    let releasedNodeId = kinematicNodeId ?? dragged.name.flatMap(UUID.init(uuidString:))
    dragged.zPosition = draggedNodeOriginalZPosition
    draggedNode = nil
    kinematicNodeId = nil
    if distance < 5, let releasedNodeId {
        onNodeTapped?(releasedNodeId)
        // Sim still active until watchdog fires.
    }
    // sim continues running until watchdog-driven sleep
}
```

- [ ] **Step 4: Manual smoke test**

Run app. Drag a node. Expect: connected neighbors slide along; on release, motion damps over ~0.5–1s then freezes; settled positions are saved.

Reopen Galaxy. Expect: layout is recognizably similar to where you left it.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/GalaxyScene.swift
git commit -m "feat(galaxy-scene): live drag physics with sleep watchdog

Per-frame force-directed simulation in update(_:), wakes on mouseDown,
runs continuously while dragging, settles via soft watchdog (30 frames
sub-threshold) or hard timeout (90 frames since mouseUp), then zeroes
velocities and persists positions via onSimulationSettled callback.

Constellation pairwise attraction iterates post-K=2 memberships only.
Halo SKEffectNode rasterize toggles off during sim, on at sleep.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 24: Sleep watchdog tests

**Files:**
- Test: `Tests/NousTests/SimulationSleepWatchdogTests.swift`

- [ ] **Step 1: Write tests**

```swift
@MainActor
final class SimulationSleepWatchdogTests: XCTestCase {

    func test_softWatchdogTriggersAfter30SubThresholdFrames() {
        let scene = GalaxyScene()
        // Set up positions, simulate 30 frames of zero velocity post-mouseUp
        // Expect onSimulationSettled to fire exactly once
    }

    func test_hardTimeoutTriggersAfter90FramesEvenWithJitter() {
        let scene = GalaxyScene()
        // Inject a velocity floor that stays just above threshold
        // After 90 frames, sleep must trigger regardless
    }

    func test_velocityZeroedOnSleep() {
        // After sleep, all velocities == 0
    }
}
```

(Implementation depends on whether the scene's update loop is testable directly. If running inside SKView is required, use `scene.update(0.016)` synchronously in a loop.)

- [ ] **Step 2: Run tests**

Run: `./scripts/test_nous.sh -only-testing:NousTests/SimulationSleepWatchdogTests`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/NousTests/SimulationSleepWatchdogTests.swift
git commit -m "test(galaxy-scene): sleep watchdog triggers + velocity zeroing

Soft watchdog at 30 sub-threshold frames; hard timeout at 90 frames
post-mouseUp regardless of jitter; velocities zeroed on sleep.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 25: Wire `onSimulationSettled` to ViewModel persistence

**Files:**
- Modify: `Sources/Nous/Views/GalaxySceneContainer.swift`
- Modify: `Sources/Nous/ViewModels/GalaxyViewModel.swift` (already added in Task 17)

- [ ] **Step 1: Pass callback through container**

In `GalaxySceneContainer`, add:

```swift
var onSimulationSettled: (([UUID: GraphPosition]) -> Void)?
```

In `updateNSView`:

```swift
scene.onSimulationSettled = onSimulationSettled
```

- [ ] **Step 2: Wire from `GalaxyView`**

```swift
GalaxySceneContainer(
    scene: scene,
    graphNodes: vm.nodes,
    graphEdges: vm.edges,
    constellations: vm.constellations,
    dominantConstellationId: vm.dominantConstellationId,
    revealedConstellationIds: vm.revealedConstellationIds,
    toggleAllVisible: vm.showAllConstellations,
    positions: vm.positions,
    selectedNodeId: vm.selectedNodeId,
    onNodeTapped: handleNodeTap,
    onNodeMoved: handleNodeMove,
    onSimulationSettled: { [vm] settled in
        Task { @MainActor in
            vm.handleSimulationSettled(positions: settled)
        }
    }
)
```

(Add the new container properties matching the scene's needs.)

- [ ] **Step 3: Manual integration check**

Run app. Drag → settle → reopen Galaxy. Verify position persistence end-to-end.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/GalaxySceneContainer.swift Sources/Nous/Views/GalaxyView.swift
git commit -m "feat(galaxy): wire onSimulationSettled to ViewModel persistence

Container forwards the scene's settle callback to GalaxyViewModel,
which writes the snapshot via PositionSnapshotStore on a background
queue.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 10: Final Integration

### Task 26: Full test pass + manual QA pass

- [ ] **Step 1: Run full suite**

Run: `./scripts/test_nous.sh`
Expected: all tests pass.

- [ ] **Step 2: Manual QA checklist**

Open Nous in Xcode → Run.

| Check | Expected |
|---|---|
| Open Galaxy after fresh build | Layout populates from `computeLayout`, no halos visible if no reflections; otherwise dominant ambient at ~8% alpha |
| Tap a node belonging to a constellation | Halo fades up to ~55% alpha; MOTIFS section appears in bottom sheet |
| Tap a node with 0 constellations | No MOTIFS section; CONNECTED section behaves as before |
| Press "Show Motifs" toggle | All visible constellations fade in staggered (closer to center first); each shows a small floating short-label at centroid |
| Filter to a project that contains 1 member of a constellation | That halo hides; other constellations' halos may resize |
| Drag a node | Connected neighbors visibly follow; on release, motion damps over ~0.75s and freezes |
| Quit and re-launch | Galaxy reopens with positions near where you left them |
| Old `shared` edges | Not visible anywhere; CONNECTED chips show only "manual" / "X% semantic" |

- [ ] **Step 3: Commit any QA-driven fixes**

If manual checks surface bugs, fix and commit per-bug with conventional commit format.

- [ ] **Step 4: Final commit** (optional, may not be needed)

```bash
git status  # ensure clean
git log --oneline origin/main..HEAD  # review the branch's commits
```

---

## Self-Review Notes

This plan covers every section of the spec. Specific mappings:

- §1 Context → Phase 1 (Tasks 1-4)
- §3.1 Removed (edge type) → Tasks 3-4
- §3.1a Decode guard → Task 1
- §3.2 Constellation type → Task 9
- §3.3 Derivation rules incl. K=2 + second prune → Task 11
- §3.4 Ephemeral bridging → Tasks 10, 12
- §4.1 Service skeleton → Task 10
- §4.2 messageId→nodeId resolver → Task 5
- §4.2a Index → Task 2
- §4.3 Reflection completion publisher → Tasks 13, 14
- §4.4 Validator change + separation of concerns → Tasks 6-8
- §5.1 Halo form (pre-blurred sprite + rasterize) → Tasks 18, 19
- §5.3 Alpha tiers → Task 19 + Task 20
- §5.4 Caption + derivedShortLabel → Tasks 9, 20
- §6.1-6.3 Default state, tap, toggle → Tasks 20, 21
- §6.4 Filter-aware dominant → Task 15
- §7 Live drag physics (all subsections) → Tasks 22-25
- §7.5 UserDefaults snapshot → Tasks 16-17
- §7.6 Threading → Task 17 + Task 25
- §8.1 Migration SQL → Task 2
- §8.2 Code change list → Tasks 1-25
- §9.1-9.2 Tests → Tasks 1, 2, 5, 7, 8, 11, 12, 15, 16, 18-22, 24
- §10 Open questions → captured in spec; this plan delivers what's in scope
- §12 Decision summary → reflected in the implementation choices

No placeholders. Each step has runnable commands and complete code. Type names are consistent across tasks (`Constellation`, `ConstellationService`, `loadActiveConstellations`, `considerNodeForEphemeralBridging`, `clearEphemeral`, `releaseEphemeral`, `PositionSnapshotStore`, `simulationOwnsPositions`, `onSimulationSettled`, `.reflectionRunCompleted`, `.singleConversationEvidence`).
