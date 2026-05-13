# Memory Engine v1 Star Plan

**Verdict:** 5/5 fit for Nous. The autonomous-agent memory guide maps directly onto the product's core loop: write memory deliberately, manage it over time, retrieve it with provenance, and let higher-level reflections emerge from trusted evidence.

**Pain test:** The absence hurts. Nous already has graph memory, local vector storage, and AI chat, but without an explicit lifecycle it can still remember silently, retrieve opaquely, and let low-quality memories leak into future answers.

**Non-goals:**

- Do not modify `Sources/Nous/Resources/anchor.md`.
- Do not add SwiftData, Core Data, an ORM, or third-party dependencies.
- Do not replace the existing memory stack in one sweep.
- Do not let pending or inferred memory affect normal recall before approval.

## Article Takeaways

The useful shape is not "chat history plus vector search." The useful shape is a memory lifecycle:

1. Write: decide whether an observation deserves storage.
2. Manage: classify, consolidate, approve, decay, correct, or forget it.
3. Read: retrieve by semantic fit, graph context, time, importance, and use history.
4. Reflect: periodically turn many lower-level memories into higher-level insights.
5. Govern: preserve user agency, evidence, source, and deletion paths.

For Nous, this means Galaxy should be both a visual graph and a retrieval substrate. Every strong memory edge needs evidence; every recalled memory needs a reason.

## Star-Rated Roadmap

### 5 stars: Memory Inbox

**Why first:** Remembering wrong without visibility is worse than forgetting. Long-term memory should enter as pending, not active.

**V1 scope:**

- Stage durable user statements as pending `MemoryAtom`s.
- Suppress hard opt-out or sensitive writes.
- Keep pending memory out of active recall.
- Let Alex save, reject, or forget pending atoms from the memory inspector surface.

### 5 stars: Memory Lifecycle Engine

**Why first:** The repo already has memory atoms, curator logic, graph storage, and recall services. The missing piece is a small coordinator that makes write/manage/read explicit.

**V1 scope:**

- `stageFromUserText` for capture.
- `inbox` for pending review.
- `approve`, `reject`, and `forget` for user control.
- temporal scope classification: episodic, semantic, procedural, reflective.

### 4 stars: Hybrid Recall With Reasons

**Why next:** Vector search alone is too narrow. Nous has graph evidence, so recall should explain why it selected a memory.

**V1 scope:**

- Score active memories by semantic fit, graph proximity, recency, importance, and interaction.
- Use a transparent weighted formula:
  - 0.40 semantic
  - 0.20 graph
  - 0.15 recency
  - 0.15 importance
  - 0.10 interaction
- Return a reason string with component scores and source identifiers.

### 4 stars: Reflection Nodes

**Why not v1:** Valuable, but risky before the write gate exists. Reflection can amplify bad memory if raw memory is messy.

**V2 scope:**

- Generate reflection atoms from approved source atoms only.
- Store source atom IDs.
- Mark confidence and evidence.
- Surface reflection nodes in Galaxy as derived, not user-confirmed.

### 3 stars: Decay, Merge, and Correction Review

**Why later:** Important for quality, but not the first pain. The first pain is silent memory writes and opaque recall.

**V2/V3 scope:**

- Merge duplicate atoms.
- Decay low-importance stale memory.
- Flag contradictions.
- Promote only repeated or user-confirmed preferences.

## V1 Execution Plan

- [x] Add a pending memory status.
- [x] Add `MemoryLifecycleEngine` as the narrow lifecycle coordinator.
- [x] Add deterministic tests for pending capture, hard opt-out, approval, active recall, and graph-neighbor ranking.
- [x] Add Memory Graph Inspector support for Inbox, Save, Reject, and Forget.
- [x] Wire main chat semantic atom capture through the pending inbox lifecycle.
- [x] Deduplicate repeated pending proposals and refresh existing active atoms without downgrading them.
- [x] Keep correction supersede behavior out of the pending path until explicit approval support exists.
- [x] Regenerate the Xcode project with `xcodegen generate`.
- [x] Verify with focused `xcodebuild test`.

## Next Step After V1

Add the v2 approval path for corrections: when Alex approves a pending correction, Nous can supersede the targeted active belief/preference/goal/plan/rule and write the evidence edge at approval time. Keep legacy memory summaries as orientation; they are not part of the Inbox gate.
