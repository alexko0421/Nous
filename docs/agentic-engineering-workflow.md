# Agentic Engineering Workflow

This is the operating playbook for coding agents working on Nous. It turns
multi-agent research into a small set of repo-specific rules.

The default is simple: keep one lead agent responsible for context, judgment,
implementation, verification, and the final handoff. Add parallel agents only
when they protect context or create real independent progress.

## Default Posture

- Start with one agent. A well-scoped single thread beats a noisy team.
- Use parallel agents for context isolation, not for theater.
- Prefer read-heavy exploration over parallel code edits.
- Keep the main thread focused on requirements, decisions, and final synthesis.
- The lead agent owns integration. Delegation never transfers accountability.
- Do not modify `Sources/Nous/Resources/anchor.md`; it is frozen.

Before adding any extra agent, ask:

1. Does this side task produce noisy output the main context should not absorb?
2. Can it run with a clean boundary and a clear final answer?
3. Will the result materially improve speed, coverage, or verification?
4. Can the lead integrate the result without resolving hidden assumptions?

If any answer is no, stay single-agent.

## Delegation Decision Tree

Use one of these paths.

| Situation | Pattern | Rule |
|---|---|---|
| Small fix, focused doc edit, or one coherent implementation | Single lead agent | Do the work locally. Do not delegate. |
| Need to find where behavior lives, inspect logs, compare docs, or map code paths | Explorer subagent | Read-only. Return concise findings with file references. |
| Need independent review after changes | Reviewer subagent or fresh session | Read-only. Focus on correctness, regressions, security, and tests. |
| Need parallel implementation | Worker subagent | Only when write sets are disjoint and ownership is explicit. |
| Need peer negotiation, shared task list, or long-running cross-agent coordination | Agent team | Defer unless the user explicitly asks and the task is valuable enough for the overhead. |

Worker subagents are allowed only when all of these are true:

- Each worker has a named responsibility and a disjoint write set.
- The worker knows it is not alone in the codebase.
- The worker is told not to revert or overwrite changes made by others.
- The worker must list changed files and verification results.
- The lead reviews and integrates every returned change.

For coding tasks, do not split "implement feature" and "write its tests" into
different agents unless the test task can be specified from a stable public
interface. The implementer usually has the context needed to write the focused
tests.

## Context Hygiene

Treat context as a finite engineering resource.

- Keep raw logs, broad search output, and long file scans out of the main thread
  when a read-only explorer can summarize them.
- Pull only the files needed for the next decision.
- Prefer `rg` and targeted reads over broad scans.
- Compact findings into decisions, risks, and file references.
- Start a fresh thread or subagent for independent review to avoid author bias.
- Clear or restart when a thread has accumulated unrelated failed attempts.

Use Beads for repo engineering state and lessons. Use Nous for Alex's product,
semantic, and personal memory. Do not store Alex's values, product strategy,
or one-off conversation notes in `bd remember`.

## Verification Loop

Every non-trivial task needs a concrete completion check before it is called
done.

Use the narrowest verification that proves the change:

- Swift build: `xcodegen generate` after `project.yml` edits, then
  `xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build`.
- Tests: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'`.
- Fixture scripts: run the specific `scripts/run_*_fixtures.sh` wrapper.
- Docs-only work: run targeted `rg` checks and review the relevant `git diff`.
- UI work: verify in the app or browser with a screenshot/manual acceptance
  note when automated tests cannot cover the behavior.

If verification cannot run, say why and leave a clear residual risk. Do not
replace verification with confidence.

## Beads + Memory Boundary

At session start, run:

```bash
scripts/beads_agent_workflow.sh start
```

For non-trivial code or docs work:

1. Claim or create a bead before editing.
2. Keep the bead scoped to the actual engineering work.
3. Create linked discovered-work beads instead of silently expanding scope.
4. Finish the bead with what changed and how it was verified.

Stable engineering lessons may go in `bd remember`. Product memory, Alex memory,
semantic knowledge, values, and strategy belong in Nous, not Beads.

See `docs/beads-agent-memory.md` and `docs/memory-jurisdiction.md` for the
full boundary.

## Reusable Prompts

Read-only exploration:

```text
Explore this code path without editing files. Find the entry points, data flow,
and likely files involved. Return concise findings with file references and
open questions only.
```

Parallel explorer split:

```text
Spawn one read-only explorer per area: <area A>, <area B>, <area C>. Each
explorer should inspect only its area, avoid proposing fixes unless necessary
to explain a risk, and return a short summary with file references. Wait for
all results before synthesizing.
```

Worker implementation:

```text
You are responsible only for <files/modules>. Other agents may be editing
elsewhere. Do not revert or overwrite changes you did not make. Implement the
requested behavior, run the specified verification, and report changed files,
commands run, and remaining risks.
```

Fresh review:

```text
Review this diff like an owner. Prioritize correctness, behavior regressions,
security/privacy risks, and missing tests. Lead with concrete findings tied to
files and lines. Skip style-only comments unless they hide a real bug.
```

Handoff:

```text
Summarize the current state for the next agent: goal, files changed, important
decisions, commands run, verification results, unresolved risks, and the next
small action.
```
