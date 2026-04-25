# Galaxy Relations Redesign: Constellation Motifs + Live Drag Physics

**Status:** Draft, awaiting Codex review and user approval
**Author:** Alex + Claude
**Date:** 2026-04-25
**Target files (primary):**
`Sources/Nous/Models/NodeEdge.swift` (or wherever `EdgeType` lives), `Sources/Nous/Services/GraphEngine.swift`, `Sources/Nous/Services/NodeStore.swift`, `Sources/Nous/Services/TurnExecutor.swift`, `Sources/Nous/ViewModels/GalaxyViewModel.swift`, `Sources/Nous/Views/GalaxyView.swift`, `Sources/Nous/Views/GalaxyScene.swift`, plus a new `Sources/Nous/Services/ConstellationService.swift`.

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
- **Gap C:** `GalaxyScene.mouseDragged` in `Sources/Nous/Views/GalaxyScene.swift:509-525` updates only the dragged node's position and redraws edges; there is no per-frame physics integration.

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

- `EdgeType.shared` enum case (wherever it lives — likely `Sources/Nous/Models/NodeEdge.swift`).
- `GraphEngine.generateSharedEdges(for:)`.
- The `.shared` branch in `regenerateEdges(for:)`.
- All `TurnExecutor` (or other) call sites that invoke shared generation.
- Render branches: `GalaxyScene.sharedStoneBlue` palette, `.shared` cases in `strokeColor`, `lineWidth`, `edgeColor`. `GalaxyView.connectionLabel` `.shared` case ("project"). `GalaxyView.edgeTint` `.shared` case.

### 3.2 New: `Constellation` (in-memory, derived)

```swift
struct Constellation: Identifiable, Equatable {
    let id: UUID                  // = ReflectionClaim.id
    let claimId: UUID
    let label: String             // = ReflectionClaim.claim (verbatim)
    let confidence: Double
    let memberNodeIds: [UUID]     // distinct, ≥ 2
    let isDominant: Bool          // exactly one true per Galaxy load (if any)
    let isEphemeral: Bool         // false for evidence-derived; true for embedding-NN bridged
}
```

No persisted table. Built fresh on each Galaxy load by `ConstellationService.loadActiveConstellations()`. Cached for the session in `GalaxyViewModel`.

### 3.3 ReflectionClaim → Constellation mapping

```
For each ReflectionClaim where status == .active:
  evidenceMessageIds = ReflectionEvidence rows for this claim
  memberNodeIds = distinct conversation nodeIds containing those messages
  if memberNodeIds.count < 2: skip (corner case — claim survived validator
     but messages collapsed to single conversation; no visualization value)
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

Per-node K=2 cap (applied at render time, not derivation):
  For each node, sort its containing Constellations by claim.confidence desc.
  Take top 2. Constellations may still exist beyond the cap — they just
  aren't rendered as halos for nodes already at cap.
```

### 3.4 Embedding-NN bridging (ephemeral membership)

Between reflection cycles, new nodes have no evidence binding. To prevent the "new chat is invisible to constellation system for up to a week" gap:

```
On NodeStore.insertNode (after embedding is computed, async):
  for each existing Constellation:
    centroid = mean of member node embeddings (cached on Constellation)
    similarity = cosine(newNode.embedding, centroid)
    if similarity ≥ 0.7:
      attach newNode.id as ephemeral member of that Constellation
      (cap: at most K=2 ephemeral attachments per new node, ranked by similarity)

On next ReflectionRun completion:
  ConstellationService rebuilds from scratch. All ephemeral attachments
  cleared. New nodes that were correctly ephemeral-attached will now
  have evidence binding (reflection picked them up); others fall off
  cleanly.
```

Threshold rationale: 0.7 is looser than `semantic` edge threshold (0.75) because constellation membership is a softer signal — "plausibly part of this motif" rather than "directly similar." Tunable.

---

## 4. Constellation Derivation Pipeline

### 4.1 New service

`Sources/Nous/Services/ConstellationService.swift`

```swift
final class ConstellationService {
    private let nodeStore: NodeStore
    private let reflectionStore: ReflectionStore  // existing
    private let messageStore: MessageStore        // existing
    private let vectorStore: VectorStore          // existing

    func loadActiveConstellations() throws -> [Constellation]
    func attachEphemeral(node: NousNode) throws -> [UUID]  // returns Constellation ids attached
    func detachEphemeral(nodeId: UUID)
}
```

### 4.2 Resolution helper

Need `messageId → nodeId` resolution. Options:

- **A.** Add `func conversationNodeId(forMessageId: UUID) throws -> UUID?` to `MessageStore` (or `NodeStore`).
- **B.** Bulk fetch: `func conversationNodeIds(forMessageIds: [UUID]) throws -> [UUID: UUID]` for efficiency on large evidence sets.

Implement B; A is a special case of B with one element.

### 4.3 Wire-up

`GalaxyViewModel.load()`:

```
1. Existing: load nodes, load edges, compute layout
2. NEW: constellations = constellationService.loadActiveConstellations()
3. Pass nodes + edges + constellations + positions into GalaxySceneContainer
```

Reflection completion: `WeeklyReflectionService` already writes a successful
`ReflectionRun` to the store on completion. Add a lightweight
`ReflectionCompletionPublisher` (or reuse an existing observable surface
if one exists — verify before adding) that posts on success. `GalaxyViewModel`
subscribes; on signal it re-runs `loadActiveConstellations()`, which
clears all ephemeral attachments and rebuilds from the now-updated
evidence. Polling/timer-based refresh is explicitly rejected — too coarse
and would re-build constellations unnecessarily.

```
On ReflectionRun.status = .success:
  publisher.send()
GalaxyViewModel.subscription:
  constellations = constellationService.loadActiveConstellations()
```

---

## 5. Visual Design

### 5.1 Halo form

Each constellation rendered as a single `SKEffectNode` with `shouldRasterize = false` and a `CIGaussianBlur` filter. Inside the effect node, one `SKShapeNode` (radial gradient sprite, ~70px radius) per member node, positioned at the member's current scene coordinates. Blur radius ~24pt. Result: an organic cloud that hugs the members and reflows when members move.

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
- Rendered: small label `MOTIFS` (same typography as `CONNECTED`), then 1–2 caption rows (one per constellation containing the tapped node).
- Each caption row: a small lavender mist dot + the `claim.label` text, max 3 lines.
- If tapped node belongs to 0 constellations: the section is omitted entirely (not rendered as empty state).

When toggle-revealed:
- Each halo shows a floating label at the centroid of its members. Label = first 22 characters of `claim.label` + ellipsis.
- Labels deliberately small (10pt) — they are hints, not headings; the bottom sheet remains the place for full caption.

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

Halo membership respects the active project filter:
- Member nodes outside the filtered project are visually filtered out (not rendered).
- A constellation whose visible-member count drops below 2 hides its halo.
- Switching back to "Whole Galaxy" restores full halos.
- The dominant constellation may become invisible while a narrow project filter is active. This is acceptable — it preserves filter consistency.

---

## 7. Live Drag Physics

### 7.1 State machine

```
Galaxy load
  → run existing 180-iteration layout (one-shot, as today)
  → freeze; isSimActive = false

mouseDown on node N
  → isSimActive = true
  → mark N as kinematic (simulation does not apply velocity to N)
  → simulation runs in update(_:) starting next frame

mouseDragged
  → N.position = mouse position (clamped, as today)
  → other nodes integrate forces normally

mouseUp
  → unmark N kinematic
  → continue simulation; start sleep-watchdog
  → 30 consecutive frames with max(|velocity|) < 0.5 → isSimActive = false
  → batch-persist all changed positions to NodeStore
```

### 7.2 Per-frame simulation step

In `GalaxyScene.update(_:)` while `isSimActive`:

```
for each pair (i, j) of nodes:
  apply repulsion = repulsionConstant / distSq, normalized

for each edge:
  apply attraction = attractionConstant × edge.strength × delta
  // edge.strength is unchanged: manual/semantic as before

for each constellation, for each pair (i, j) of its members:
  apply weakAttraction = 0.2 × attractionConstant × delta
  // virtual edge for layout; not stored; not rendered as line

for each non-kinematic node:
  velocity *= damping (0.86)
  position += velocity
```

Constants reuse `GraphEngine.computeLayout` defaults: `repulsion = 12000`, `attraction = 0.004`, `damping = 0.86`. Confirmed appropriate at the load-time iteration scale; live-frame scale should match well at 60fps but may need calibration if motion feels too jittery or too sluggish.

### 7.3 Performance

- Repulsion is O(N²); at N ≈ 200 this is 40k pair-ops/frame. Acceptable at 60fps on Apple Silicon.
- Constellation pairwise attraction: O(Σ Cᵢ²) where Cᵢ is member count of constellation i. Real-world Cᵢ ≈ 3–8, so this term is small.
- If profile shows hot path, reuse `vDSP` (Accelerate) — already imported by `GraphEngine`.
- No spatial hashing or Barnes-Hut for now. Defer to >500-node regime.

### 7.4 Persistence

Existing `onNodeMoved((UUID, GraphPosition))` callback fires per-drag-end today. With live sim, *all* nodes move during drag, so:

- During sim, do **not** fire `onNodeMoved` per-frame (too chatty).
- On `isSimActive = false` (sleep), iterate all nodes whose position changed since drag start and emit a single batch update through a new `onSimulationSettled([UUID: GraphPosition])` callback.
- `GalaxyViewModel` writes batch to `NodeStore`.

---

## 8. Migration

### 8.1 Schema/data

App startup migration step (in whatever runs current schema migrations):

```sql
DELETE FROM node_edges WHERE type = 'shared';
```

Idempotent. Wrap in version guard if migration framework requires.

### 8.2 Code

One PR removes:
- `EdgeType.shared` case
- `GraphEngine.generateSharedEdges` and the `.shared` branch in `regenerateEdges`
- Any caller in `TurnExecutor` etc.
- `GalaxyView.connectionLabel` `.shared` case + `edgeTint(.shared)` fallback
- `GalaxyScene.sharedStoneBlue` and `.shared` branches in `strokeColor`, `lineWidth`, `edgeColor`

Compiler-driven: removing the enum case will surface every site that needs touching.

### 8.3 Test fixtures

Search for `.shared` usages in `Tests/NousTests/`. Replace with `.semantic` where the test's intent is "an edge exists" (most cases). Delete or rewrite tests whose intent specifically validated shared behavior.

---

## 9. Testing Strategy

### 9.1 Unit / integration tests (Swift Testing)

| Test | What it covers |
|---|---|
| `SharedEdgeRemovalMigrationTests` | Seed `type='shared'` rows; run migration; verify 0 remaining; rerun is no-op. |
| `ConstellationDerivationTests` | Mock `ReflectionRun` + `ReflectionClaim` (active / orphaned / superseded mix) + `ReflectionEvidence` + conversation/message data. Verify: (a) only active claims surface; (b) member resolution is correct and de-duped; (c) constellations with <2 distinct member nodes are dropped; (d) dominant selection picks highest-confidence claim from latest run; (e) per-node K=2 cap is applied. |
| `EmbeddingNNBridgingTests` | Mock new node + existing constellations with synthetic centroids. Verify: (a) attaches when cosine ≥ 0.7; (b) does not attach below threshold; (c) at most 2 attachments per new node; (d) reflection re-run clears ephemerals. |
| `GraphEngineLayoutTests` | Constellation pairwise attraction strength = 0.2 × semantic. Existing shared-edge test cases removed. |
| `GalaxyViewModelTests` | `load()` populates `constellations`; reflection refresh callback rebuilds. |

### 9.2 Snapshot or pixel-sample tests (light)

| Test | What it covers |
|---|---|
| `GalaxySceneConstellationRenderTests` | After `rebuildScene` with N constellations, the expected number of `SKEffectNode` halos exists, with expected member sprite counts inside; constellations of size <2 are skipped. |

### 9.3 Manual / interactive QA

- Drag physics feel: dragging a hub-like node should ripple through 1–2 layers of neighbors, then damp.
- Halo look: dominant ambient at 8% should be barely perceptible; tap reveal at 55% should be clearly present without overwhelming nodes.
- Toggle reveal cascade: stagger should feel like stars appearing, not popping.
- Project filter switching: halos contract/expand correctly as filter changes.

---

## 10. Open Questions / Risks

1. **Where does `EdgeType` live exactly.** Spec assumes `Sources/Nous/Models/NodeEdge.swift`; verify before implementing. (Easy.)
2. **`ReflectionEvidence` cardinality at scale.** A heavy reflection week could produce N claims × M evidence rows. Galaxy load must remain <200ms perceived. Profile if N×M > a few hundred; consider caching `Constellation` snapshot on disk if needed.
3. **Embedding-NN bridging may briefly mis-attach.** A new chat that thematically belongs nowhere may get attached to whichever constellation is closest by sheer cosine luck. Mitigation: 0.7 threshold + cleanup at next reflection. Risk is one-week-max staleness.
4. **Caption length.** `claim.claim` is free text. Bottom sheet truncates at 3 lines; toggle-mode floating label truncates at 22 characters. If reflection produces overlong claims, both look truncated. Reflection prompt currently has no length cap on claim text — out of scope to change here, but flag if QA shows readability issues.
5. **Dominant constellation can feel "stale" between reflections.** Already addressed in §3.3 freshness guard (14-day window). Flagged here to surface for QA: if a user pauses chatting for 2+ weeks, Galaxy will go quiet (no ambient halo). Verify this feels intentional, not broken, on return.
6. **Live sim with kinematic dragged node may briefly appear to stretch edges.** When a hub node is yanked fast, edges between dragged node and far neighbors visibly elongate before neighbors catch up. Acceptable behavior — communicates connection.
7. **Persisted positions vs sim drift.** Drag → sim runs → settles → positions written. Reopening Galaxy uses persisted positions as seeds, then re-runs the 180-iteration layout. The seeded layout will be near-identical to where the user left off (force balance was already at rest), so the user perceives "Galaxy remembered." Edge case: if many nodes were added between sessions, seeded layout drifts more — acceptable.
8. **No UI to inspect a constellation independently.** Tap reveals via member; toggle reveals all. There is no list view of constellations. Considered out of scope but worth noting as future work (a sidebar that lists motifs and their member counts).

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
| 3 | Membership rule? | **Multi-membership, K=2 cap** per node by claim confidence. |
| 4 | Visual form for deep motif? | **Halo cloud** (blurred radial gradients), lavender mist. Not line, not color cluster. |
| 5 | Default visibility? | **One dominant ambient** (8% alpha) + others on tap/toggle. |
| 6 | Dominant ranking? | **Reflection picks via highest confidence in latest run.** Suppress if latest run >14 days old. |
| 7 | Layout impact of constellations? | **Weak attraction** (0.2 × semantic) between members in force sim. |
| 8 | Drag physics? | **Live sim during drag**, sleeps after settling, persists final positions. |
| 9 | Packaging? | **Single PR / single spec** covering all three changes. |
