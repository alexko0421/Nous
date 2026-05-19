# Agentic Architecture Roadmap

This roadmap maps the multi-agent collaboration research PDF to the current
Nous V1 implementation. The goal is not more agents by default. The goal is a
clear delegation system where context, permissions, state, and final merge
responsibility are explicit.

## Current V1 Baseline

Automatic Memory V1 gives Nous a trust-aware memory write path:

- Low-risk conversation, task, preference, and project memories can become
  active automatically.
- Identity, rule, boundary, reflection, low-confidence, or unclear-source
  memories stay pending for review.
- Source learning records Alex's explicit judgments, decisions, and
  preferences, not raw source facts as personal memory.
- Memory activity keeps provenance, reason, confidence, and review state visible
  enough to explain what happened after a turn.

Agent Work V1 gives Nous a read-only engineering state surface:

- Beads remains engineering agent memory, not Nous product or personal memory.
- The app separates Beads connection problems from harness blocks and runtime
  risk.
- Harness diagnostics show concrete causes such as protected prompt, memory,
  config, source-set, or `anchor.md` changes.
- The app does not run mutating `bd` commands.

## PDF Mapping

The PDF's practical chain is:

```text
Input Event -> Router/Dispatcher -> Context Builder -> Worker Profile
-> Sandbox -> State Store -> Merge/Reduce -> Final Output
```

Nous already has pieces of this chain, but they are mostly policy and workflow
rather than productized interfaces:

- Router/Dispatcher: the lead agent decides locally when to delegate.
- Context Builder: `docs/agentic-engineering-workflow.md` defines the Context
  Boundary Card, but it is still manual text.
- Worker Profile: explorer, worker, reviewer, verifier, and memory steward roles
  exist as workflow guidance, not structured state.
- Sandbox: permissions are mostly enforced by agent instructions and scoped
  ownership, not a first-class permission model.
- State Store: Beads stores engineering tasks, blockers, handoffs, and
  follow-ups; Nous keeps product, semantic, and personal memory separate.
- Merge/Reduce: the lead owns integration, but the acceptance evidence is not
  yet a structured gate.

## Roadmap

### Phase 1: Delegation Contract

Turn the Context Boundary Card into a structured contract that every delegated
task can carry:

- Objective, context in, context out, ownership paths, forbidden actions,
  output schema, stop condition, failure behavior, acceptance rubric, and
  verification evidence.
- Default to one lead agent. A missing or ambiguous contract means no
  delegation.
- Keep the contract engineering-only; do not convert it into Nous memory.

Acceptance:

- A focused workflow check can flag a delegated task without ownership,
  forbidden actions, output schema, or verification evidence.
- Docs include copyable contract examples for explorer, worker, verifier, and
  memory steward roles.

### Phase 2: Worker Profiles and Sandbox Policy

Define narrow worker profiles with explicit permissions:

- Explorer: read-only file and log inspection; no writes.
- Worker: writes only inside named ownership paths; must list changed files.
- Reviewer: read-only findings with severity, file references, and test gaps.
- Verifier: read-only evidence check for false-green risk.
- Memory Steward: read-only boundary judgment for Beads, Nous memory, prompt
  context, RAG, and `anchor.md`.

Acceptance:

- The workflow check can detect missing ownership for worker profiles.
- Worker prompts state that the worker is not alone in the codebase and must not
  revert unrelated changes.
- Verifier is recommended only for dirty worktree, prompt/memory/config changes,
  scripts, release handoff, or Bead ambiguity.

### Phase 3: Durable Board Integration

Use Beads as the durable engineering board for long-running agent work:

- Represent task state, dependency, blocker, handoff, retry, acceptance criteria,
  and verification summary in Beads.
- Keep Settings > Agent Work read-only and status-oriented.
- Do not make Beads issues into `NousNode`, Galaxy, Project, or product memory.

Acceptance:

- Agent Work can show ready, in-progress, blocked, and recently closed work
  without hiding harness state when Beads connection fails.
- Follow-up work is created as linked Beads tasks instead of expanding the
  current scope silently.

### Phase 4: Merge/Reduce Gate

Make final integration explicit:

- The lead agent owns the final patch, conflict resolution, and user handoff.
- Path ownership, changed-file summary, verification commands, skipped checks,
  and residual risks are recorded before close.
- Harness findings distinguish connection failure, protected file changes,
  runtime risk, and missing verification.

Acceptance:

- A closing workflow check fails when scoped changed files exist but no Bead,
  verification summary, or path-limited scope is present.
- `anchor.md` stays frozen unless an approved anchor migration exists.

### Phase 5: Dogfood and Team-Mode Decision

Measure whether delegation helps before adding heavier agent teams:

- Track unnecessary delegation, duplicate investigation, write-set conflicts,
  false-green catches, time saved, and rework avoided across 5-10 real tasks.
- Keep autonomous agent teams off by default.
- Consider team mode only for multi-hypothesis work where peer communication is
  worth the coordination cost.

Acceptance:

- The next roadmap revision is based on real dogfood cases, not architecture
  taste.
- If team mode is proposed, it includes ownership boundaries, merge/reduce
  policy, and a kill switch.

## Guardrails

- Do not modify `Sources/Nous/Resources/anchor.md`.
- Do not store Alex's values, product strategy, design taste, or one-off
  conversation notes in Beads.
- Do not add a third-party dependency for delegation infrastructure until the
  pain is proven.
- Do not split planner, implementer, and tester roles when they need the same
  context.
- Do not treat a busy task board as proof of better agent quality.
