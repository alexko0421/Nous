# Memory Jurisdiction

This document is the rulebook for where memory belongs in Nous.

It exists because Nous now has several memory substrates:

- `memory_entries`: scoped summary memory for prompt continuity
- `memory_fact_entries`: contradiction-oriented facts for judge recall
- `memory_atoms` / `memory_edges`: graph memory for temporal and relational recall
- `reflection_claim`: weekly inferred conversational patterns
- prompt-only turn context: citations, attachments, quick-action addenda, focus blocks

The same claim may appear in more than one substrate, but only when each copy has
a different product role. Storage duplication is allowed. Prompt confusion is not.

## Core Rule

Every remembered claim must answer three questions:

1. **Jurisdiction:** Which layer owns this claim?
2. **Evidence:** What source proves or supports it?
3. **Prompt role:** Is this current truth, scoped context, historical evidence, a hypothesis, or a turn-only signal?

If those answers are unclear, the claim should not be promoted upward.

## Layers

| Layer | Substrate | Owns | Write Bar | Prompt Role |
|---|---|---|---|---|
| Anchor | `Sources/Nous/Resources/anchor.md` | Nous's identity, judgment style, response modes, emotional handling | Frozen | Highest-priority stable identity |
| Alex Identity | `memory_entries(scope=.global, kind=.identity)`; later selected identity atoms | Durable facts about who Alex is, core values, deep recurring patterns | Explicit confirmation or strong repeated evidence | Current durable identity, stated cautiously |
| User Model | `UserModel` projected by `MemoryProjectionService` | Operational per-turn model: goals, work style, memory boundaries | Derived from active scoped memory | Prompt-facing projection, not canonical truth |
| Project Memory | `memory_entries(scope=.project)` | Project goal context, constraints, recurring project themes, project decisions | Repeated project evidence | Strong only inside that project |
| Conversation Thread | `memory_entries(scope=.conversation)` | Current thread state and local continuity | Conversation refresh | Local context for the current chat |
| Contradiction Facts | `memory_fact_entries(kind=.decision/.boundary/.constraint)` | Explicit decisions, red lines, constraints | Extracted from Alex-only evidence | Judge-facing contradiction substrate |
| Graph Memory | `memory_atoms`, `memory_edges`, `memory_recall_events` | Atom-level state, time, source message, relationships, supersession | Source-message evidence preferred | Temporal / relational recall packet |
| Self-Reflection | `reflection_claim` | Weekly inferred patterns across conversations | Multi-message validator evidence | Hypothesis only; never identity by default |
| Turn Context | `TurnMemoryContext`, `QuickActionMemoryPolicy`, citations, attachments, focus blocks | Current-turn retrieval and mode policy | Per-turn only | Volatile signal; never durable truth |

## Jurisdiction Rules

### Anchor

- `anchor.md` is not memory.
- Do not edit it for taste, mode, format, or temporary behavior changes.
- If living memory conflicts with the anchor, surface the tension instead of silently updating the anchor.

### Alex Identity

Use this layer for facts that remain true across projects and conversations:

- background identity
- core values
- deep recurring patterns
- long-lived constraints on life or work

Do not use this layer for:

- one conversation's emotion
- one project's tactical decision
- a brainstormed possibility
- an inferred diagnosis or personality label

Promotion requires one of:

- Alex explicitly confirms the claim
- the same claim recurs across multiple independent moments
- Alex manually promotes the claim in the memory inspector

### User Model

`UserModel` is a prompt projection, not a storage layer.

It may include:

- active goals
- work-style preferences
- memory boundaries
- selected identity lines when no stronger global block already covers them

It must be removable by `QuickActionMemoryPolicy`. If a mode chooses `.lean`,
`UserModel` should disappear with the other memory layers.

### Project Memory

Project memory should answer:

- what is this project trying to do?
- what decisions or constraints persist across chats?
- what themes keep recurring in this project?

It must not restate identity-level facts about Alex. If a project fact looks
global, it remains project-scoped until promotion rules are satisfied.

### Conversation Thread

Conversation memory is for continuity inside one chat.

It should preserve:

- what the current thread is about
- local decisions made in this thread
- local unresolved context

It should not become durable identity without promotion.

### Contradiction Facts

`memory_fact_entries` is a judge-facing substrate.

It should store only:

- `decision`: explicit choices Alex made
- `boundary`: red lines, do-not-cross rules, operating principles
- `constraint`: real limitations or non-negotiable conditions

These facts may also become graph atoms, but their prompt role differs:

- fact entry: small hard-recall candidate for the judge
- graph atom: time/source/relationship-aware memory for recall paths

### Graph Memory

Graph memory is for questions where summary text is not enough:

- "What did I reject before?"
- "Why did I change my mind?"
- "What did this replace?"
- "Is this still active?"
- "What did I believe at the time?"

Rules:

- `eventTime` means when the thing happened.
- `createdAt` means when Nous stored it.
- `status=.superseded` atoms are not current truth.
- Superseded atoms may be recalled for history, change, or contradiction, not as present-day advice.
- Vector search can find candidates, but graph edges explain relationships.

### Self-Reflection

Self-reflection claims are inferred patterns, not identity.

They should be phrased and used as hypotheses:

- "You may be doing X lately"
- "Across last week, there was a pattern of Y"

They must not silently promote into Alex Identity. A weekly pattern can become
identity only through the normal promotion rules.

### Turn Context

Turn context is volatile.

Examples:

- citations
- attached files
- active quick-action mode
- graph recall output
- judge focus block
- behavior profile
- interactive clarification instruction

It may shape the current reply. It must not be stored as memory unless a later
synthesis step extracts a sourced claim through the normal write path.

## Prompt Rules

Prompt assembly should preserve these meanings:

- `LONG-TERM MEMORY ABOUT ALEX`: durable global memory
- `DERIVED USER MODEL`: operational projection, not canonical truth
- `THIS PROJECT'S CONTEXT`: project-scoped context
- `THIS CHAT'S THREAD SO FAR`: conversation-scoped context
- `SHORT SOURCE EVIDENCE`: evidence for memory summaries
- `GRAPH MEMORY RECALL`: structured atom/chain recall
- `RELEVANT PRIOR MEMORY`: judge-selected focus block
- `RELEVANT KNOWLEDGE FROM ALEX'S NOTES AND CONVERSATIONS`: RAG citations, not durable memory

Do not add new prompt memory blocks without naming their jurisdiction and source
relationship.

## Echo Guard

Before adding a memory block to a prompt, check whether the same source claim is
already present through another path.

Common duplication paths:

- conversation summary plus recent conversation
- summary plus evidence snippet
- graph recall plus judge focus block
- citation plus memory entry sourced from the same node
- reflection claim plus identity line

If two blocks share the same source and claim, prefer the more precise block:

1. judge focus block
2. graph recall with source quote
3. scoped summary memory
4. source evidence snippet, unless it adds source detail not already visible
5. recent conversation summary

## OpenClaw Mapping

OpenClaw's file split maps to Nous like this:

| OpenClaw | Nous Equivalent |
|---|---|
| `SOUL.md` | frozen `anchor.md` |
| `USER.md` | `UserModel` plus carefully promoted Alex Identity |
| `MEMORY.md` / memory files | typed `memory_entries`, `memory_fact_entries`, `memory_atoms`, `reflection_claim` |
| `TOOLS.md` | tool declarations, quick-action agents, skill store, app integrations |

Nous should borrow the separation discipline, not the Markdown storage model.
