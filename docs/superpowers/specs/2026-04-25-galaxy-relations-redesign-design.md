# Galaxy Relations Redesign: Constellation Motifs + Live Drag Physics

**Status:** Draft, awaiting user approval after Codex-review revisions
**Author:** Alex + Claude
**Date:** 2026-04-25 (Codex-review revision)
**Target files (primary):**
`Sources/Nous/Models/NodeEdge.swift`, `Sources/Nous/Services/GraphEngine.swift`, `Sources/Nous/Services/NodeStore.swift`, `Sources/Nous/Services/ReflectionValidator.swift`, `Sources/Nous/Services/TurnExecutor.swift`, `Sources/Nous/ViewModels/GalaxyViewModel.swift`, `Sources/Nous/Views/GalaxyView.swift`, `Sources/Nous/Views/GalaxyScene.swift`, `Sources/Nous/Views/GalaxySceneContainer.swift`, plus a new `Sources/Nous/Services/ConstellationService.swift`.

---

## 1. Context

### 1.1 The design problem

Galaxy today expresses node relations through three edge types:

- `manual` — user-drawn (UI entry point may not exist yet; schema supports)
- `semantic` — embedding cosine similarity ≥ 0.75
- `shared` — auto-generated between every pair of nodes in the same project, fixed strength 0.3

Two distinct gaps:

**Gap A — `shared` encodes folder co-location, not semantic relation.** Project is a storage bucket. Two nodes filed under the same project are not necessarily related; two related nodes may live in different projects. `shared` over-connects (forces clustering on co-location) and under-connects (no signal across projects). This produces a false visual signal.

**Gap B — `semantic` only catches surface similarity.** Embedding cosine catches lexical/topical overlap. Two pieces of writing both touching "father" cluster; two pieces twinned only at a deeper motif level (e.g., one chat about procrastinating a launch + one note about never showing dad his paintings, both circling "fear of being seen as inadequate") will not — surface text distance is too large. The current model has no representation for this kind of deep relation.

**Gap C — Galaxy feels static during interaction.** Layout runs 180 force-directed iterations once at load and freezes. Dragging a node moves only that node; neighbors do not respond. Compared to live-physics graph views (e.g., Obsidian), Galaxy feels architecturally posed rather than alive.

### 1.2 Root causes

- **Gap A:** `GraphEngine.generateSharedEdges` in `Sources/Nous/Services/GraphEngine.swift:113-126` mechanically creates a fully-connected mesh per project. The signal is structural, not semantic.
- **Gap B:** Surface-unrelated/deep-related links require theme distillation, not vector similarity. The reflection layer (`ReflectionClaim` + `ReflectionEvidence`) already produces this distillation as a side-effect of weekly self-reflection — but its output is currently consumed only by the memory retrieval layer, not the Galaxy.
- **Gap C:** `GalaxyScene.mouseDragged` in `Sources/Nous/Views/GalaxyScene.swift:509-525` updates only the dragged node's position and redraws edges; there is no per-frame physics integration. The scene runs at `preferredFramesPerSecond = 120` (`GalaxySceneContainer.swift:19`), so any per-frame work must respect a 120fps budget.

### 1.4 Reflection-layer constraint discovered during review

The current `ReflectionValidator` minimum-evidence rule counts **messages**, not distinct conversations: a claim is "active" if it has ≥2 evidence messages, even if both messages live in the same conversation. Because constellation halos require ≥2 distinct member nodes (a single-node "group" has no visualization value), a meaningful share of currently-active claims would be silently dropped at Galaxy derivation time. This redesign aligns the validator with the constellation requirement (see §4.4).

### 1.3 Scope

**In scope (this design, one bundled change):**

- Delete `EdgeType.shared` and all generation/render call sites; one-shot DB sweep.
- Derive a new `Constellation` concept from existing `ReflectionClaim` + `ReflectionEvidence` and render as visual halos in Galaxy.
- Live force simulation during drag interaction.

**Out of scope:**

- New reflection prompts or schema. Constellation reuses what reflection already produces.
- Manual edge creation UI. Manual edges are unaffected; if entry UI is missing today, that gap is preserved as-is.
- Always-alive layout simulation (Obsidian-style continuous drift). Sim sleeps when idle and freezes layout, preserving the "Galaxy remembers my arrangement" invariant.
- Notes participation in constellation membership. Reflection currently operates on chat messages. Notes can be attached later via a separate evidence pathway.

---

## 2. Design Overview

Three coupled changes. Single spec, one PR target.

1. **Remove `shared`.** Edges express content relations only. Project becomes purely a filter/view dimension.
2. **Add `constellation` (derived).** Active `ReflectionClaim` rows project onto Galaxy as named groupings of member nodes. Members determined by resolving `ReflectionEvidence.messageId` to the conversation node containing the cited message. Multi-membership capped at K=2 per node by claim confidence.
3. **Live drag physics.** Force simulation wakes on `mouseDown`, runs in `update(_:)` while dragging and for ~0.5s after release, persists final positions on sleep.

### 2.1 Why constellation is not a new edge type

Constellation is conceptually a **group** (a motif binds N members), not a 1-to-1 link. Encoding as edge rows would require a fully-connected mesh per group and bend the data shape. Instead constellation is a first-class derived entity at render time (no schema change), and `EdgeType` enum loses one case (`.shared`) without gaining one.

| Today | After |
|---|---|
| `EdgeType` = `.manual`, `.semantic`, `.shared` | `EdgeType` = `.manual`, `.semantic` |
| Constellation: does not exist | Constellation: derived from `ReflectionClaim` at Galaxy load |

---

## 3. Data Model

### 3.1 Removed

- `EdgeType.shared` enum case (in `Sources/Nous/Models/NodeEdge.swift`).
- `GraphEngine.generateSharedEdges(for:)`.
- The `.shared` branch in `regenerateEdges(for:)`.
- All `TurnExecutor` (or other) call sites that invoke shared generation.
- Render branches: `GalaxyScene.sharedStoneBlue` palette, `.shared` cases in `strokeColor`, `lineWidth`, `edgeColor`. `GalaxyView.connectionLabel` `.shared` case ("project"). `GalaxyView.edgeTint` `.shared` case.

### 3.1a Decode-time guard for stale shared rows

`NodeStore.edgeFrom` (line 1370) currently decodes unknown edge type strings as `.semantic`:

```swift
let type = EdgeType(rawValue: stmt.text(at: 4) ?? "") ?? .semantic
```

After removing `.shared` from the enum, any `shared` row not yet swept by migration would be silently re-decoded as `.semantic` — converting structural co-location into false semantic relations. To prevent silent corruption:

1. Change `edgeFrom` to return `nil` for unknown raw values, and have `fetchAllEdges` / `fetchEdges(...)` filter `nil` results out.
2. Migration runs first at startup, but the guard in (1) is the belt-and-braces in case migration order varies or a future code path reads edges before migration completes.

Equivalent SQL-level option (`SELECT ... WHERE type IN ('manual','semantic')`) would also work but the Swift-level filter localizes the change to one place.

### 3.2 New: `Constellation` (in-memory, derived)

```swift
struct Constellation: Identifiable, Equatable {
    let id: UUID                       // = ReflectionClaim.id
    let claimId: UUID
    let label: String                  // = ReflectionClaim.claim (verbatim)
    let derivedShortLabel: String      // computed from `label`, see §5.4
    let confidence: Double
    let memberNodeIds: [UUID]          // post-K=2-cap; distinct, ≥ 2
    let centroidEmbedding: [Float]?    // mean of member embeddings; nil if any member missing embedding
    let isDominant: Bool               // at most one true per Galaxy load
}
```

No persisted table. `Constellation.memberNodeIds` is the merged set: evidence-derived members ∪ current ephemeral members for this constellation, after the K=2 per-node cap. Consumers (render, physics, captions) all read from this single field — no separate "ephemeral vs evidence" axis at the consumer layer.

Ephemeral state is internal to `ConstellationService` (`ephemeralByConstellationId`) and never leaks into `Constellation`. Built fresh on each Galaxy load by `ConstellationService.loadActiveConstellations()`. Cached for the session in `GalaxyViewModel`.

### 3.3 ReflectionClaim → Constellation mapping

After §4.4's validator change lands, all newly-validated active claims will already span ≥2 distinct conversations, but pre-existing active claims may not. The derivation filter is independent of the validator change for safety:

```
For each ReflectionClaim where status == .active:
  evidenceMessageIds = ReflectionEvidence rows for this claim
  memberNodeIds = distinct conversation nodeIds containing those messages
  if memberNodeIds.count < 2: skip (pre-validator-change residue;
     no visualization value — surfaces a single bubble, not a constellation)
  emit Constellation(...)

Dominant selection:
  Among Constellations whose underlying ReflectionRun is the most recent
  (max ranAt across runs of any projectId), pick the highest-confidence
  claim. Mark its Constellation as isDominant. All others isDominant = false.
  If zero qualifying claims: no dominant.

  Freshness guard: if the latest run's `weekEnd` is more than 14 days
  before now, suppress dominant entirely (isDominant = false everywhere).
  Rationale: an old "dominant" lingering for weeks misrepresents the
  current emotional weather. Better silence than stale signal.

Per-node K=2 cap (applied during derivation, not just render):
  For each node, sort its containing Constellations by claim.confidence desc.
  Take top 2. The derivation output stores the capped membership set —
  every consumer (render, physics attraction, bottom-sheet caption,
  toggle-mode floating label) sees the same view. Eliminates "invisible
  constellation pulling layout" inconsistency.

  Implementation note: Constellation.memberNodeIds is the post-cap set.
  A node N appears in at most 2 Constellation.memberNodeIds across the
  whole returned list.
```

### 3.4 Embedding-NN bridging (in-memory ephemeral)

Between reflection cycles, new nodes have no evidence binding. To prevent the "new chat is invisible to constellation system for up to a week" gap, ephemeral attachments live **in `ConstellationService` instance memory only** — no schema, no persistence:

```
ConstellationService maintains:
  ephemeralByConstellationId: [UUID: [UUID]]  // constellationId → [nodeId]

On a node finishing semantic embedding (existing path in TurnExecutor / NodeStore):
  for each Constellation in current snapshot:
    centroid = mean of member node embeddings (cached on Constellation)
    similarity = cosine(newNode.embedding, centroid)
    if similarity ≥ 0.7:
      append newNode.id to ephemeralByConstellationId[constellation.id]
      (cap: at most 2 ephemeral attachments per new node, ranked by similarity)

When loadActiveConstellations() runs (Galaxy load, reflection completion,
or manual refresh):
  build evidence-derived Constellations as in §3.3
  for each, merge ephemeral nodeIds (deduped, K=2 cap reapplied per node
  across both evidence and ephemeral)
  return merged set

App restart:
  ConstellationService is re-instantiated empty.
  ephemeralByConstellationId is empty.
  Next embedding pass repopulates if relevant.

Reflection completion:
  ephemeralByConstellationId cleared explicitly.
  New evidence-derived Constellations form; nodes that were correctly
  ephemeral are now in evidence; orphans fall off cleanly.
```

Threshold rationale: 0.7 is looser than `semantic` edge threshold (0.75) because constellation membership is a softer signal — "plausibly part of this motif" rather than "directly similar." Tunable.

Trade-off accepted: if a user creates a new chat and immediately closes Galaxy + reopens, ephemeral attachments are gone (until next embedding-time recomputation). This is fine because (a) ephemeral state was always best-effort filler, and (b) within a single Galaxy session it works correctly, which is when the user actually sees Galaxy.

---

## 4. Constellation Derivation Pipeline

### 4.1 New service

`Sources/Nous/Services/ConstellationService.swift`

```swift
final class ConstellationService {
    private let nodeStore: NodeStore
    private let reflectionStore: ReflectionStore  // existing or to-add facade over NodeStore reflection methods
    private let vectorStore: VectorStore          // existing

    // In-memory ephemeral state (cleared on app restart and reflection completion)
    private var ephemeralByConstellationId: [UUID: Set<UUID>] = [:]
    private let ephemeralLock = NSLock()

    /// Builds the full active constellation snapshot. Merges evidence-derived
    /// memberships with current ephemeral attachments. Applies K=2 cap per node.
    func loadActiveConstellations() throws -> [Constellation]

    /// Called when a node's embedding is newly available. Computes cosine
    /// similarity vs each Constellation centroid and records ephemeral
    /// attachments in memory. Idempotent.
    func considerNodeForEphemeralBridging(_ node: NousNode) throws

    /// Drops ephemeral attachments referencing the given node ID.
    /// Called when a node is deleted.
    func releaseEphemeral(nodeId: UUID)

    /// Wipes all ephemeral attachments. Called after a successful
    /// ReflectionRun (the derived snapshot now reflects fresh evidence).
    func clearEphemeral()
}
```

`ConstellationService` is owned at the same scope as `NodeStore` (app lifetime, single instance). `GalaxyViewModel` holds a reference and calls `loadActiveConstellations()` on Galaxy load, on reflection completion, and after node insertions trigger `considerNodeForEphemeralBridging`.

### 4.2 messageId → nodeId resolution

`messages.nodeId` already exists (`NodeStore.swift:70`, `nodeId TEXT NOT NULL REFERENCES nodes(id)`), so the resolution is a single SQL JOIN per derivation pass — **not** N+1 per claim.

Add to `NodeStore`:

```swift
/// Bulk resolves message IDs to their owning conversation node IDs.
/// One SQL round-trip; uses `WHERE id IN (?, ?, ...)` parameterized.
func conversationNodeIds(forMessageIds messageIds: [UUID])
    throws -> [UUID: UUID]
```

Implementation: a single `SELECT id, nodeId FROM messages WHERE id IN (...)` with batched parameter binding (SQLite limit 999 vars; chunk if larger). Return as a `[UUID: UUID]` dictionary keyed by messageId.

Inside `loadActiveConstellations()`:

1. Fetch all active claims (one query).
2. Fetch all evidence rows for those claim IDs (one query, `WHERE reflection_id IN (...)`).
3. Bulk resolve all unique messageIds across evidence rows in one round-trip via `conversationNodeIds`.
4. Group evidence rows by claimId, dedupe member nodeIds.
5. Drop claims with <2 distinct nodeIds.
6. Compute centroids from member nodes' embeddings (uses `vectorStore` cache).
7. Pick dominant from latest run (see §6.4 for filter interaction).
8. Apply K=2 per-node cap (§3.3).

### 4.2a Schema index requirement

Add a non-unique index on `reflection_evidence(message_id)` if not already present. Codex flagged this; the existing schema's composite PK on `(reflection_id, message_id)` covers `WHERE reflection_id = ?` but not the inverse direction, which we need when a message delete cascades and `ReflectionValidator` re-checks affected claims (§4.4 evidence-cascade path).

```sql
CREATE INDEX IF NOT EXISTS idx_reflection_evidence_message
  ON reflection_evidence(message_id);
```

Verified during implementation: if the index is already present, this is a no-op.

### 4.3 Wire-up

`GalaxyViewModel.load()`:

```
1. Existing: load nodes, load edges (now without `.shared`), compute layout
   using the persisted UserDefaults position snapshot as seed (§7.4).
2. NEW: constellations = constellationService.loadActiveConstellations()
3. Pass nodes + edges + constellations + positions into GalaxySceneContainer
```

Reflection completion notification: reuse the existing `nousNodesDidChange` notification surface (the rest of the app already routes node-related state changes through it). `WeeklyReflectionService` posts on successful `ReflectionRun`; `GalaxyViewModel` already subscribes for unrelated reasons. Add a small predicate so the existing subscription handler also calls `constellationService.clearEphemeral()` + `loadActiveConstellations()` when the change reason is "reflection success."

If `nousNodesDidChange` does not currently encode a "reason" field: add a minimal `userInfo` payload (`["reason": "reflection_success"]`) only on the reflection completion path. Other senders unchanged.

Polling/timer refresh is explicitly rejected — too coarse and would rebuild constellations unnecessarily.

```
On ReflectionRun.status = .success:
  notify .nousNodesDidChange with userInfo: ["reason": "reflection_success"]
GalaxyViewModel.handler:
  if reason == reflection_success:
    constellationService.clearEphemeral()
  constellations = constellationService.loadActiveConstellations()
```

### 4.4 ReflectionValidator change: ≥2 distinct conversations

`Sources/Nous/Services/ReflectionValidator.swift` currently treats "≥2 evidence messages" as the active-claim minimum. Change to **"≥2 evidence messages whose conversations (nodeIds) are distinct."**

Two touchpoints:

1. **New-claim validation** (when `WeeklyReflectionService` validates a fresh LLM-produced claim): resolve its evidence messageIds to nodeIds via `NodeStore.conversationNodeIds` (§4.2). If `Set(nodeIds).count < 2`, reject the claim with a new `ReflectionRejectionReason.singleConversationEvidence` (extend the enum).

2. **Cascade orphan check** (when a message delete drops evidence count): after the cascade, recompute the remaining evidence's distinct nodeIds. If <2, flip claim status to `.orphaned`. Today the check is `count(evidence) < 2`; new check is `distinct(conversation nodeIds in evidence) < 2`. Same code path, different counting predicate.

Forward-only: existing `.active` claims that pre-date this change are not retroactively re-checked. Galaxy derivation independently filters by ≥2 distinct nodeIds (§3.3), so stale single-conversation active claims simply do not surface in Galaxy. They remain available to the memory retrieval layer (which never required distinct-conversation evidence in the first place).

Tests: `ReflectionValidatorTests` gains cases for (a) 2 messages 1 nodeId rejected with `singleConversationEvidence`, (b) 2 messages 2 nodeIds accepted, (c) cascade-from-3 to 2-same-conversation orphans the claim, (d) cascade-from-3 to 2-different-conversations keeps the claim active.

---

## 5. Visual Design

### 5.1 Halo form

Each constellation rendered as a single `SKEffectNode` containing one `SKSpriteNode` per member, positioned at member scene coordinates. Each sprite uses a **pre-blurred radial gradient texture** (~70px radius) generated once at app launch and cached — not a live `CIGaussianBlur` filter applied per frame.

Rationale: Codex flagged the original approach (`SKEffectNode` + `CIGaussianBlur` + `shouldRasterize = false`) as the worst case for animated blur — Core Image re-runs the GPU filter every frame for every halo. With pre-blurred textures, the cost per halo per frame is just sprite compositing (cheap).

Two-mode rasterization on the `SKEffectNode` itself:

| Phase | `shouldRasterize` |
|---|---|
| Sim active (drag ongoing or settling) | `false` (members move, sprite positions update) |
| Sim asleep (default Galaxy state) | `true` (sprite positions stable, rasterize once and reuse) |

The effect node's filter is set to a no-op compositing filter (or omitted entirely; pre-blurred sprites carry the blur). Blur radius is encoded in the texture, not applied at render time.

Cap: at most **8 visible halos** simultaneously (1 dominant + tap-revealed up to 2 + toggle-revealed remainder). If a user has >8 active constellations and toggles full reveal, lowest-confidence halos beyond 8 do not render. Captured as a knob, not user-facing for v1.

### 5.2 Palette

Single new color: **lavender mist** = `Color(red: 155/255, green: 142/255, blue: 196/255)`. Sourced from existing Morandi palette (already in `GalaxyScene.morandiNodePalette`), so it does not feel imported — but used at much lower alpha than nodes, distinguishing it visually.

Reasoning: Distinct from camel/sage/stoneBlue edge tints. Distinct from terracotta focus highlight. Same family as one node color, which keeps the overall picture coherent.

### 5.3 Alpha tiers

| State | Halo alpha |
|---|---|
| Hidden (default for non-dominant) | 0% |
| Dominant ambient (default) | **8%** |
| Tap-revealed (containing tapped node) | **55%** |
| Toggle-revealed (all halos at once) | **35%** |

Transitions: fade 600ms ease-in-out. Toggle reveal staggers halos by 80ms in order of distance from screen center (closer first).

### 5.4 Caption display

When tap-revealed:
- Bottom sheet gains a new `MOTIFS` section above the existing `CONNECTED` strip.
- Rendered: small label `MOTIFS` (same typography as `CONNECTED`), then **exactly the constellations this node has under the K=2 cap** (0–2 rows; the cap was applied during derivation in §3.3, so consumers see a consistent view).
- Each caption row: a small lavender mist dot + the `claim.label` text, max 3 lines.
- If tapped node has 0 constellations after the cap: the section is omitted entirely (not rendered as empty state).

When toggle-revealed:
- Each halo shows a small floating label at the centroid of its members.
- Label is **a derived short label**, not a truncation of the verbatim claim. Reflection's `claim.claim` text is corpus-scoped and often opens with phrases like "Across four conversations, Alex returns to..." — truncating to 22 characters yields meaningless fragments ("Across four conversa…").
- Derived label algorithm (deterministic, no extra LLM call): scan `claim.claim` for the first quoted phrase in `「」` or `""`, or the first noun phrase after a colon. Fall back to the first 22 characters only if neither pattern matches. Implementation lives in `Constellation.derivedShortLabel` (computed once per constellation).
- Labels deliberately small (10pt) — they are hints, not headings; the bottom sheet remains the place for the full caption.

---

## 6. Interaction Model

### 6.1 Default state

- All `manual` and `semantic` edges render as today.
- Exactly one halo (the dominant constellation) at 8% alpha. If no dominant exists (no active claims), no halo.
- All other halos invisible.

### 6.2 Tap a node

1. Existing select behavior fires.
2. Resolve which constellations (0–2) contain the tapped node. For each: animate halo from 0% (or 8% if dominant) to 55%.
3. Render `MOTIFS` section in bottom sheet with their captions.
4. On deselect: reverse animation.

### 6.3 Toggle button "显示星座"

- Placement: top bar, separated from the `Whole Galaxy / Project` menu by a small visual gap.
- Icon: a custom three-dot constellation glyph (filled when active, outlined when inactive); label "显示星座" / "Hide" depending on state.
- Activate: animate all active constellations' halos from 0% (or 8% for dominant) to 35%, staggered.
- Deactivate: reverse animation; state returns to default.
- Mutually exclusive with tap-reveal: tapping a node while toggle is active still raises that node's halos to 55%, others stay at 35%.

### 6.4 Project filter interaction

Halo membership respects the active project filter, **and dominant selection is recomputed after the filter is applied**:

- Member nodes outside the filtered project are visually filtered out (not rendered).
- A constellation whose visible-member count drops below 2 hides its halo.
- Dominant is selected **from the filtered set**: among constellations with ≥2 visible members under the current filter, pick the highest-confidence claim from the latest run. If none qualifies, no dominant.
- Switching back to "Whole Galaxy" recomputes dominant against the full set.
- Codex flagged the original "latest run across any projectId" rule — under a narrow filter, free-chat (`projectId IS NULL`) claims could dominate the picture and disappear/reappear strangely as filter toggles. Filter-scoped recomputation avoids that.

---

## 7. Live Drag Physics

### 7.1 Ownership handoff

`GalaxySceneContainer.updateNSView` currently does:

```swift
scene.positions = vm.positions
```

…on every SwiftUI rerender. If sim is running and SwiftUI rerenders for an unrelated reason (selection change, sheet open), the scene's live positions get clobbered by the (stale) view-model snapshot. Fix:

- Add `var simulationOwnsPositions: Bool` to `GalaxyScene`.
- In `updateNSView`, copy `vm.positions` into the scene **only if** `simulationOwnsPositions == false`.
- `simulationOwnsPositions` is `true` from `mouseDown` until sim sleep + final position handoff completes.

Conversely, on sim sleep the scene writes its current positions back into `vm.positions` (via `onSimulationSettled` callback) before flipping `simulationOwnsPositions = false`. This ensures SwiftUI sees the settled state and subsequent rerenders are stable.

### 7.2 State machine

```
Galaxy load
  → seedPositions = readPositionSnapshot()  (UserDefaults; see §7.5)
  → run existing 180-iteration layout with seedPositions
  → simulationOwnsPositions = false; isSimActive = false

mouseDown on node N
  → simulationOwnsPositions = true
  → isSimActive = true
  → kinematicNodeId = N
  → simulation runs in update(_:) starting next frame

mouseDragged
  → N.position = mouse position (clamped, as today)
  → other nodes integrate forces normally

mouseUp
  → kinematicNodeId = nil
  → continue simulation; start sleep-watchdog
  → sleep when EITHER:
      (a) 30 consecutive frames with max(|velocity|) < 0.5, OR
      (b) hard timeout: 90 frames since mouseUp regardless of velocity
    On sleep:
      - zero all velocities (defends against float jitter accumulation)
      - call onSimulationSettled([UUID: GraphPosition])
      - writePositionSnapshot(positions) to UserDefaults (off main thread)
      - simulationOwnsPositions = false
      - isSimActive = false
```

Hard timeout (b) defends against the failure mode Codex flagged: floating-point jitter at the velocity floor can keep `max(|velocity|)` perpetually just above 0.5, the soft watchdog never triggers, and positions never persist. With (b), even pathological input settles within 90 frames (~0.75s at 120fps) and the snapshot writes.

### 7.3 Per-frame simulation step

In `GalaxyScene.update(_:)` while `isSimActive`:

```
for each pair (i, j) of nodes:
  apply repulsion = repulsionConstant / distSq, normalized

for each edge:
  apply attraction = attractionConstant × edge.strength × delta
  // edge.strength is unchanged: manual/semantic as before

for each constellation, for each pair (i, j) of its members (post-K=2 cap, §3.3):
  apply weakAttraction = 0.2 × attractionConstant × delta
  // virtual edge for layout; not stored; not rendered as line.
  // Members beyond the K=2 cap are NOT iterated — keeps physics
  // and visual consistent (no invisible pulling).

for each node where node.id != kinematicNodeId:
  velocity *= damping (0.86)
  position += velocity
```

Constants reuse `GraphEngine.computeLayout` defaults: `repulsion = 12000`, `attraction = 0.004`, `damping = 0.86`.

### 7.4 Performance budget

The scene runs at `preferredFramesPerSecond = 120` (`GalaxySceneContainer.swift:19`).

- Repulsion is O(N²). At N=200 that's ~40k pair ops/frame × 120fps = 4.8M/sec, before edge attraction, constellation virtual edges, halo sprite reflow, edge path redraws, and labels.
- Acceptable on M-series silicon for N ≤ ~200, but tight enough to warrant profiling.
- Mitigations available without architecture change: (a) drop scene to 60fps **only while sim active** to halve workload (`scene.view.preferredFramesPerSecond = 60` in `mouseDown`, restore to 120 on sleep); (b) move repulsion inner loop to `vDSP` SIMD operations (Accelerate is already imported by `GraphEngine`).
- For v1: ship at 120fps, profile during QA. If Instruments shows >10ms frame budget overrun in repulsion, apply (a) first (single-line change), (b) only if (a) is insufficient.
- No spatial hashing or Barnes-Hut for now. Defer to >500-node regime.

### 7.5 Position snapshot persistence (UserDefaults)

The `nodes` table has no `x/y` columns. Adding them is out of scope for this redesign. Instead, persist a session-wide layout snapshot in `UserDefaults`:

```
Key: "com.nous.galaxy.positionSnapshot.v1"
Value: JSON-encoded [String: [Float]]  // nodeId.uuidString → [x, y]
```

- `writePositionSnapshot(_ positions: [UUID: GraphPosition])` runs on a background dispatch queue (utility QoS). UserDefaults writes are not free at scale, but for ≤500 entries the write is well under 5ms and tolerates async.
- `readPositionSnapshot() -> [UUID: GraphPosition]` runs on Galaxy load (already on background as part of `GalaxyViewModel.load()`).
- On Galaxy load: snapshot is used as `seedPositions` in `GraphEngine.computeLayout(seedPositions:)`. Nodes present in snapshot start near their last-settled coordinates; nodes added since (no snapshot entry) start at random and converge via the existing 180 iterations.
- Stale entries: if a node has been deleted, its key in the snapshot is harmless — `computeLayout` just doesn't read it. Pruning happens lazily on next write.
- App restart: snapshot persists. Reopening Galaxy gives a near-identical layout to the user's last settled state.
- App reinstall / data reset: snapshot is gone; Galaxy starts from scratch (acceptable).

This satisfies the "Galaxy remembers" invariant without a schema migration. Trade-offs accepted: (a) UserDefaults isn't transactional with `nodes` table — a node can be deleted while its position lingers in the snapshot until next write; (b) for very large galaxies (>1000 nodes) UserDefaults isn't ideal storage, but this is far beyond current scale.

### 7.6 Threading

- All sim math runs on SpriteKit's render thread (the scene's `update(_:)`).
- `onSimulationSettled` callback is dispatched to main thread (Swift Concurrency / `MainActor`) before mutating `vm.positions` (which is `@Bindable`).
- `writePositionSnapshot` is dispatched to a background utility queue. No SQLite involvement, no main-thread write penalty.
- `onSimulationSettled` does **not** touch `NodeStore` — there's nothing to write there for positions in this design.

---

## 8. Migration

### 8.1 Schema/data

App startup migration step (in whatever runs current schema migrations):

```sql
-- Verified table name (NodeStore.swift:85): the table is `edges`, not `node_edges`.
DELETE FROM edges WHERE type = 'shared';

-- See §4.2a: index for inverse-direction evidence lookups.
CREATE INDEX IF NOT EXISTS idx_reflection_evidence_message
  ON reflection_evidence(message_id);
```

Idempotent. Wrap in version guard if migration framework requires.

Belt-and-braces: even if migration order varies or a future code path reads edges before migration completes, §3.1a's `edgeFrom` change ensures stale `shared` rows decode to `nil` (filtered out) rather than silently becoming `.semantic`.

### 8.2 Code

One PR includes:

Removes:
- `EdgeType.shared` case (in `Sources/Nous/Models/NodeEdge.swift`)
- `GraphEngine.generateSharedEdges` and the `.shared` branch in `regenerateEdges`
- Any caller in `TurnExecutor` etc.
- `GalaxyView.connectionLabel` `.shared` case + `edgeTint(.shared)` fallback
- `GalaxyScene.sharedStoneBlue` and `.shared` branches in `strokeColor`, `lineWidth`, `edgeColor`

Modifies:
- `NodeStore.edgeFrom` to return `nil` on unknown raw values; `fetchAllEdges` / `fetchEdges` filter `nil` out (§3.1a)
- `NodeStore` gains `conversationNodeIds(forMessageIds:)` (§4.2)
- `ReflectionValidator` switches min-evidence rule from "≥2 messages" to "≥2 distinct conversations" (§4.4); `ReflectionRejectionReason` gains `.singleConversationEvidence`
- `GalaxySceneContainer.updateNSView` respects `simulationOwnsPositions` (§7.1)
- `GalaxyScene.update(_:)` runs sim while `isSimActive` (§7.3)
- `GalaxyViewModel.load()` reads UserDefaults position snapshot, calls `ConstellationService.loadActiveConstellations()` (§4.3, §7.5)
- `WeeklyReflectionService` posts `nousNodesDidChange` with `userInfo: ["reason": "reflection_success"]` on success (§4.3)

Adds:
- `Sources/Nous/Services/ConstellationService.swift` (§4.1)
- `Constellation` value type (§3.2)

Compiler-driven removal of `.shared` will surface most touch points; the `edgeFrom` filter and `EdgeType` enum change together prevent silent corruption.

### 8.3 Test fixtures

Search for `.shared` usages in `Tests/NousTests/`. Replace with `.semantic` where the test's intent is "an edge exists" (most cases). Delete or rewrite tests whose intent specifically validated shared behavior.

---

## 9. Testing Strategy

### 9.1 Unit / integration tests (Swift Testing)

| Test | What it covers |
|---|---|
| `SharedEdgeRemovalMigrationTests` | Seed `type='shared'` rows in `edges` (note: table name `edges`); run migration; verify 0 remaining; rerun is no-op. |
| `EdgeDecodeStaleRowGuardTests` | Insert a row with `type = 'shared'` directly via SQL (bypassing migration), call `fetchAllEdges`, verify the row is filtered (does NOT appear as `.semantic`). |
| `ConstellationDerivationTests` | Mock `ReflectionRun` + `ReflectionClaim` (active / orphaned / superseded mix) + `ReflectionEvidence` + conversation/message data. Verify: (a) only active claims surface; (b) bulk `conversationNodeIds` resolution correct and de-duped; (c) constellations with <2 distinct member nodes are dropped; (d) dominant selection picks highest-confidence claim from latest run; (e) per-node K=2 cap applied during derivation. |
| `ConstellationDominantUnderFilterTests` | Mock claims spanning multiple projectIds. Verify dominant is recomputed against filter; switching filter changes dominant correctly. |
| `EphemeralBridgingInMemoryTests` | Mock new node + existing constellations with synthetic centroids. Verify: (a) attaches when cosine ≥ 0.7; (b) does not attach below threshold; (c) at most 2 attachments per new node; (d) `clearEphemeral` empties the in-memory map; (e) re-instantiating `ConstellationService` starts empty. |
| `ReflectionValidatorDistinctConversationTests` | (a) 2 messages in 1 nodeId rejected with `.singleConversationEvidence`; (b) 2 messages in 2 nodeIds accepted; (c) cascade-from-3 to 2-same-nodeId orphans; (d) cascade-from-3 to 2-different-nodeIds remains active. |
| `GraphEngineLayoutTests` | Constellation pairwise attraction strength = 0.2 × semantic; uses post-K=2-cap memberships only. Existing shared-edge test cases removed. |
| `GalaxyViewModelTests` | `load()` reads UserDefaults snapshot as seed; populates `constellations`; reflection-success notification triggers `clearEphemeral` + reload. |
| `PositionSnapshotPersistenceTests` | `writePositionSnapshot` followed by `readPositionSnapshot` round-trips fidelity; absent snapshot returns empty; corrupt snapshot returns empty (not crash). |
| `SimulationSleepWatchdogTests` | (a) Soft watchdog: 30 sub-threshold frames triggers sleep + persist; (b) Hard timeout: 90 frames since mouseUp triggers sleep regardless of velocity; (c) Velocity zeroing on sleep. |

### 9.2 Snapshot or pixel-sample tests (light)

| Test | What it covers |
|---|---|
| `GalaxySceneConstellationRenderTests` | After `rebuildScene` with N constellations, the expected number of `SKEffectNode` halos exists, with expected member sprite counts inside; constellations of size <2 are skipped; `shouldRasterize` is `true` when sim is asleep, `false` when active. |
| `OwnershipHandoffTests` | While `simulationOwnsPositions == true`, `updateNSView` does NOT clobber `scene.positions` from `vm.positions`. After sleep, `vm.positions` reflects the settled state. |

### 9.3 Manual / interactive QA

- Drag physics feel: dragging a hub-like node should ripple through 1–2 layers of neighbors, then damp.
- Halo look: dominant ambient at 8% should be barely perceptible; tap reveal at 55% should be clearly present without overwhelming nodes.
- Toggle reveal cascade: stagger should feel like stars appearing, not popping.
- Project filter switching: halos contract/expand correctly as filter changes.

---

## 10. Open Questions / Risks

1. **`ReflectionEvidence` cardinality at scale.** A heavy reflection week could produce N claims × M evidence rows. The bulk-JOIN design (§4.2) is one round-trip, so latency stays bounded. Galaxy load should remain <200ms perceived. Profile if N×M > a few thousand; consider caching `Constellation` snapshot on disk if needed.
2. **Embedding-NN bridging may briefly mis-attach.** A new chat that thematically belongs nowhere may get attached to whichever constellation is closest by sheer cosine luck. Mitigation: 0.7 threshold + cleanup at next reflection completion or app restart. In-memory only, so no persistent corruption possible.
3. **Caption length.** `claim.claim` is free text. Bottom sheet truncates at 3 lines; toggle-mode floating label uses derived short label (§5.4). If reflection produces overlong claims, the bottom sheet may still feel dense. Reflection prompt currently has no length cap on claim text — out of scope to change here, but flag if QA shows readability issues.
4. **Dominant constellation can feel "stale" between reflections.** Already addressed in §3.3 freshness guard (14-day window). Flagged here to surface for QA: if a user pauses chatting for 2+ weeks, Galaxy will go quiet (no ambient halo). Verify this feels intentional, not broken, on return.
5. **Live sim with kinematic dragged node may briefly appear to stretch edges.** When a hub node is yanked fast, edges between dragged node and far neighbors visibly elongate before neighbors catch up. Acceptable behavior — communicates connection.
6. **UserDefaults snapshot vs `nodes` table consistency.** Position snapshot persists in UserDefaults; node identity in SQLite. A node deleted between sessions leaves a stale entry in the snapshot until next write prunes it. No correctness impact (`computeLayout` ignores entries without matching nodes), but worth flagging.
7. **No UI to inspect a constellation independently.** Tap reveals via member; toggle reveals all. There is no list view of constellations. Considered out of scope but worth noting as future work (a sidebar that lists motifs and their member counts).
8. **`ReflectionValidator` change is a behavior change for reflection itself.** Existing single-conversation active claims are not retroactively invalidated (forward-only). They simply never surface in Galaxy (§3.3 filter). They remain valid in memory retrieval. Document in CHANGELOG.

---

## 11. Future Work

- Notes participation in constellation membership (separate evidence pathway).
- Always-alive layout simulation (Obsidian-style continuous drift), gated behind a setting.
- Constellation list sidebar (browse all motifs, see history).
- Manual edge creation UI (pre-existing gap, not regression).
- Re-introducing project-aware visual cluster as a *layout hint* (not edge), if force-only layout makes within-project nodes too scattered for navigation.

---

## 12. Summary of Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Keep or delete `shared` edge? | **Delete (hard).** Project = filter only. |
| 2 | Signal source for deep motif? | **Reuse `ReflectionClaim` + `ReflectionEvidence`.** No new prompts. Hybrid: evidence-driven, with embedding-NN ephemeral bridging between reflection cycles. |
| 3 | Membership rule? | **Multi-membership, K=2 cap** per node by claim confidence — applied at derivation, not just render. |
| 4 | Visual form for deep motif? | **Halo cloud** using **pre-blurred sprite textures** (not live `CIGaussianBlur`); lavender mist; rasterize when sim asleep. Not line, not color cluster. |
| 5 | Default visibility? | **One dominant ambient** (8% alpha) + others on tap/toggle. |
| 6 | Dominant ranking? | **Reflection picks via highest confidence in latest run, recomputed against active filter.** Suppress if latest run >14 days old. |
| 7 | Layout impact of constellations? | **Weak attraction** (0.2 × semantic) between members in force sim, post-K=2-cap memberships only. |
| 8 | Drag physics? | **Live sim during drag**, sleeps after settling. **Position persistence via UserDefaults snapshot** (not a `nodes` schema change). Sleep watchdog has hard timeout fallback. |
| 9 | Packaging? | **Single PR / single spec** covering all three changes. |
| 10 | `ReflectionValidator` minimum-evidence rule? | **Change to "≥2 messages from distinct conversations"** (was "≥2 messages"). Forward-only; existing claims keep status. |
| 11 | Ephemeral bridging persistence? | **In-memory only**, in `ConstellationService` instance state. Cleared on app restart and reflection completion. |
| 12 | Position persistence storage? | **UserDefaults snapshot** keyed by `nodeId.uuidString → [x, y]`. No schema change. |
