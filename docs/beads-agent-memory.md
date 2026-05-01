# Beads Agent Memory Protocol

Beads is the shared engineering memory and task graph for coding agents working
on Nous. It is not Nous's user memory.

Use this split strictly:

- **Beads**: repo-specific engineering lessons, task state, blockers,
  handoffs, verification notes, and follow-up work discovered by agents.
- **Nous**: Alex's thinking, product direction, semantic memory, notes,
  conversations, and values.

If a coding session surfaces a product insight, record the need to capture it in
Nous. Do not write it into `bd remember`.

## Setup

Run from the repo root:

```bash
scripts/setup_beads_agent_memory.sh
```

If the `bd` CLI is missing, install it explicitly:

```bash
brew install beads
```

Or allow the setup script to install it:

```bash
scripts/setup_beads_agent_memory.sh --install
```

By default, all Conductor workspaces point to the same local store:

```bash
~/.local/share/nous/beads
```

Override this with `NOUS_BEADS_DIR` when needed:

```bash
NOUS_BEADS_DIR=/path/to/shared/beads scripts/setup_beads_agent_memory.sh
```

The script creates a local `.beads/redirect` file. `.beads/` is ignored by git.

## Session Start

At the start of every coding session:

```bash
scripts/beads_agent_workflow.sh start
```

Read `bd prime` before planning work. It injects the current Beads workflow
rules and persistent engineering memories.

If the workflow helper is unavailable, run the equivalent commands manually:

```bash
scripts/setup_beads_agent_memory.sh
bd prime
bd ready --json
bd list --status=in_progress --json
```

## Starting Work

Use existing ready work when it matches the task:

```bash
bd show <id> --json
scripts/beads_agent_workflow.sh claim <id>
```

For non-trivial work without a matching bead, create one before editing:

```bash
scripts/beads_agent_workflow.sh create \
  "Short task title" \
  "Why this task exists and what needs to be done"
```

Small direct answers and read-only investigation do not need a bead.

## During Work

If you discover follow-up work, create a linked bead instead of expanding scope
silently:

```bash
scripts/beads_agent_workflow.sh discovered \
  <current-id> \
  "Follow-up title" \
  "What was discovered and why it matters"
```

Use `bd remember` only for stable engineering lessons that should guide future
coding agents:

```bash
bd remember "Stable repo-specific lesson" --key stable-key
```

Do not store:

- Alex's personal memory
- product strategy
- design taste
- one-off discussion notes
- temporary implementation details

## Session End

Before saying work is complete:

```bash
scripts/beads_agent_workflow.sh finish \
  <id> \
  "What changed and how it was verified"
```

Only close beads for work that is actually complete. Leave blocked or partial
work open with a clear note:

```bash
bd update <id> --notes "Current state, blocker, and next step"
```

Every final response for non-trivial work must include one of these lines:

```text
Bead: <id> closed
Bead: <id> still open - <blocker or next step>
No bead: <reason this was tiny/read-only>
```

Use `scripts/beads_agent_workflow.sh no-bead "<reason>"` when no bead is
appropriate. Do not use that escape hatch for code or docs changes.

## Boundary Rule

The memory boundary is part of the architecture:

- Beads helps agents remember how to work in this repo.
- Nous helps Alex remember and connect his own thinking.

Do not merge those layers unless a future design explicitly changes this
protocol.

Native Nous integration has been evaluated and rejected for this phase. Beads
may be shown as a read-only Settings surface, but Beads issues must not become
`NousNode`, `Project`, Galaxy, or Nous memory rows. See
`docs/beads-nous-task-graph-evaluation.md`.
