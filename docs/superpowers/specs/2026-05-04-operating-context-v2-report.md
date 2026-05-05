# Operating Context V2 Future Report

**Date:** 2026-05-04
**Status:** Parked. Do not implement until V1 creates real usage pain.
**Related V1:** Global user-authored Operating Context stored in SQLite and injected before derived memory.

## Purpose

Operating Context V1 gives Nous a manually authored global profile before every chat. V2 should not be a reflexive expansion. It should start only when V1 proves that global-only context is too blunt, or when conflict between manual context and learned memory becomes hard to inspect.

The north star for V2 is:

> Keep Alex in control of the explicit context Nous uses, while making conflicts, scope, and history easier to see.

## Current V1 Baseline

V1 is intentionally small:

- One global `OperatingContext`.
- Stored in SQLite through `NodeStore`, not in markdown and not in `UserModel` projection storage.
- User-edited in Settings/Profile.
- Rendered as `USER-AUTHORED OPERATING CONTEXT`.
- Placed before derived memory/model prompt blocks.
- `boundaries` are hard constraints.
- `identity`, `currentWork`, and `communicationStyle` are strong guidance.
- `PromptGovernanceTrace` records `operating_context` only when at least one field is non-empty.

That baseline is enough until usage shows a clear limitation.

## When To Start V2

Start V2 only if at least two of these signals appear repeatedly:

- Alex edits the global Operating Context often because different projects need different modes.
- Alex wants one project to ignore or override a global goal/style without deleting it.
- Nous surfaces tension between manual context and learned memory, but Alex cannot inspect the source easily.
- Memory/debug review often asks: "Was this answer shaped by Operating Context or learned memory?"
- Boundaries need different enforcement levels, such as "never store", "ask before storing", and "project-only".
- Alex wants to see how his operating mode changed over time.
- V1 Settings fields become too long or too overloaded to stay calm.

Do not start V2 just because the architecture can support it. The pain test is: "Without this, does daily use of Nous feel materially worse?"

## Recommended V2 Shape

### V2A: Tension And Trace Visibility

This is the safest first V2 slice.

Build a calm way to inspect when manual Operating Context and derived memory are both present, especially when they point in different directions. The goal is not automatic resolution. The goal is visibility.

Likely surfaces:

- Memory debug inspector shows whether `operating_context` was included.
- Prompt trace explains that Operating Context outranks derived memory.
- If a response surfaces a tension, the user can see which manual field and which memory layer contributed.

Why this first:

- It deepens trust without expanding the data model much.
- It helps debug V1 in real use.
- It avoids premature per-project complexity.

### V2B: Project Overrides

Add optional project-scoped Operating Context overrides after global V1 has proven too broad.

Recommended rule:

- Global Operating Context always loads first.
- Project override loads after global context and may narrow or override only for that active project.
- Prompt should make the scope explicit: global versus project.

Do not create overrides for every chat mode yet. Project scope is concrete and already exists in Nous.

### V2C: Version History

Store historical versions only if Alex actually wants to review how his operating context changed over time.

Good version history is read-only by default:

- Save a snapshot on explicit save.
- Show timestamped previous versions.
- Allow restore only through an explicit user action.

Avoid building branching, diff-heavy, or timeline-heavy UI until there is real need.

### V2D: Typed Boundaries

Only split `boundaries` into typed rules if free text becomes ambiguous.

Possible types:

- `never_store`
- `ask_before_storing`
- `project_only`
- `style_constraint`
- `safety_constraint`

Typed rules should improve enforcement and traceability. They should not become a policy editor.

## Non-Goals

V2 should still avoid these:

- Do not modify `anchor.md`.
- Do not let learned memory automatically rewrite manual Operating Context.
- Do not store sensitive facts in Operating Context unless the user explicitly writes and saves them.
- Do not create per-message or per-thread overrides unless project overrides prove insufficient.
- Do not add agents that silently manage the profile.
- Do not make Settings feel like a database admin screen.
- Do not merge Operating Context into `UserModel`; keep manual context and derived projection separate.

## Likely Files

V2 work would probably touch:

- `Sources/Nous/Models/UserModel.swift`
- `Sources/Nous/Services/NodeStore.swift`
- `Sources/Nous/ViewModels/SettingsViewModel.swift`
- `Sources/Nous/Views/SettingsView.swift`
- `Sources/Nous/Services/PromptContextAssembler.swift`
- `Sources/Nous/Models/PromptGovernanceTrace.swift`
- `Sources/Nous/Services/TurnMemoryContextBuilder.swift`
- `Sources/Nous/Services/TurnPlanner.swift`
- `Sources/Nous/Services/QuickActionOpeningRunner.swift`
- `Sources/Nous/Views/MemoryDebugInspector.swift`

Tests should extend:

- `Tests/NousTests/NodeStoreTests.swift`
- `Tests/NousTests/SettingsViewModelTests.swift`
- `Tests/NousTests/RAGPipelineTests.swift`
- `Tests/NousTests/PromptGovernanceTraceTests.swift`
- `Tests/NousTests/TurnMemoryContextBuilderTests.swift`
- `Tests/NousTests/TurnPlannerSkillIntegrationTests.swift`

## First V2 Implementation Plan To Write Later

If V2 starts, write the implementation plan around one slice only.

Recommended first plan:

> Operating Context V2A: make inclusion, precedence, and manual-versus-derived tension visible in the debug/trace surface.

Acceptance criteria:

- Trace explicitly shows Operating Context was included.
- Debug view distinguishes manual context from learned memory.
- Empty Operating Context remains omitted.
- No automatic memory deletion or profile rewrite happens.
- Tests prove the displayed trace matches prompt assembly.

## Parking Decision

V1 is complete enough to use. V2 is intentionally parked.

The next correct step is to live with V1 and watch for friction. If V1 stays calm and useful, do nothing. If V1 creates repeated confusion around scope, conflicts, or boundaries, start V2A first.
