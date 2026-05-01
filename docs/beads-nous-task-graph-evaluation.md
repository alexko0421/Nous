# Beads to Nous Task Graph Evaluation

## Decision

Do not make Beads issues first-class `NousNode`, `Project`, Galaxy, or memory
objects in this phase.

Keep Beads as an external engineering-agent task graph. Nous may show a
read-only operational projection of Beads in Settings, but Beads state must not
be written into Nous's SQLite schema, semantic memory, prompt memory, Project
model, or Galaxy edges without a later explicit design.

## Why

Beads and Nous have different jurisdictions.

Beads owns coding-agent work state:

- engineering tasks
- blockers
- handoffs
- discovered follow-up work
- stable repo-specific engineering lessons

Nous owns Alex's thinking system:

- conversations
- notes
- product thinking
- semantic memory
- Project context
- Galaxy relationships

Promoting Beads issues into Nous would mix process telemetry with Alex's memory.
That creates several failure modes:

- **Prompt contamination:** agent implementation notes could enter Alex-facing
  memory or RAG context as if they were product knowledge.
- **False Galaxy edges:** issue titles and close summaries are not the same kind
  of semantic material as notes or conversations, so automatic edges would make
  the graph noisier.
- **Sync conflicts:** Beads is shared across Conductor workspaces; Nous's local
  SQLite store is app/user memory. Mirroring mutable task state creates a second
  source of truth.
- **Lifecycle mismatch:** Beads issues churn quickly. Nous memories should
  survive because they matter to Alex, not because an agent needed coordination.
- **Approval ambiguity:** agents can create Beads follow-ups freely, but they
  should not be able to create Alex-facing memories without a stricter write
  path.

The current Settings-only Agent Work surface gives the useful part: Alex and
agents can see what is happening without making task state part of the product
memory substrate.

## Allowed Now

These are safe in the current architecture:

- Read Beads through the `bd` CLI.
- Display ready, in-progress, and recently closed Beads in Settings.
- Copy commands such as `bd show <id>` for agent handoff.
- Use Beads issue ids in engineering docs, commits, PRs, and final agent
  responses.
- Store stable repo-specific engineering lessons with `bd remember --key`.

These do not require Nous schema changes because the source of truth remains
Beads.

## Not Allowed Yet

Do not add:

- `NodeType.agentTask`
- Beads rows in `nodes`, `projects`, `edges`, `memory_entries`,
  `memory_atoms`, or `memory_edges`
- automatic Beads issue ingestion into Chat, Galaxy, Project, or RAG context
- automatic conversion of closed Beads into Nous notes
- Beads memories about Alex, product strategy, taste, or personal thinking

If a coding session uncovers product insight, the right output is a Beads
follow-up that says the insight should be captured in Nous later. It is not a
`bd remember` entry and not an automatic Nous memory write.

## Future Ladder

If the current read-only Settings panel becomes insufficient, expand in this
order:

1. **L1: Operational view.** Current state. Settings reads Beads directly and
   shows task status.
2. **L2: Command assist.** Add explicit copy/open helpers for `bd show`,
   `bd update`, and `bd close`, still with Beads as the only writer.
3. **L3: Ephemeral projection.** Cache a temporary Beads snapshot for UI
   responsiveness only. The cache must be rebuildable from `bd` and must not
   enter Nous memory or prompts.
4. **L4: Explicit bridge proposal.** Only after real pain appears, design a
   bridge with named jurisdiction, write approval, conflict handling, prompt
   rules, and deletion semantics.

L4 should be rejected unless it passes this test: "冇呢样嘢，会痛唔痛？" If the
answer is no, the read-only Settings surface is enough.

## Approval Model for Any Future Bridge

Any future Beads-to-Nous bridge needs all of these before implementation:

- a written product reason for why read-only Beads is insufficient
- a source-of-truth rule for conflicts between Beads and Nous
- an explicit list of fields allowed to cross the boundary
- a prompt rule proving Beads state cannot leak into Alex-facing memory
- a migration and deletion plan for mirrored data
- tests proving closed or stale Beads do not appear as current Nous memory

Until those exist, Beads remains an external engineering tool exposed in
Settings only.
