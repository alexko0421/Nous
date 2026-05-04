# Agentic Engineering Workflow

This is the operating playbook for coding agents working on Nous. It turns
multi-agent research into a small set of repo-specific rules.

The default is simple: keep one lead agent responsible for context, judgment,
implementation, verification, and the final handoff. Add parallel agents only
when they protect context or create real independent progress.

## Anti-Agent-Sickness Rule

Multi-agent work is a coordination cost, not a maturity signal. Start from one
lead agent and add agents only when the task earns one of three reasons:
context protection, true parallelization, or specialization.

Never split work by role labels like planner / implementer / tester when those
roles need the same deep context. That creates a telephone game. Design around
context boundaries, not org charts.

A separate Verifier / Gatekeeper is not the default second agent. Non-trivial
work needs evidence; it does not automatically need another agent. Add an
independent verifier only when false-green risk is high enough to justify the
extra context boundary.

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

## Context Boundary Card

Before spawning any subagent, write the boundary in the prompt:

- **Task objective:** the exact question or change the subagent owns.
- **Context needed:** the files, docs, logs, or concepts it should inspect.
- **Context excluded:** what it should ignore so it does not duplicate the lead.
- **Expected output:** the format the lead needs for synthesis or integration.
- **Stop condition:** when it should stop exploring or editing.
- **Verification evidence:** commands, file references, or checks required before
  claiming the subtask is ready.

If the card cannot be filled clearly, keep the work in the lead thread.

## Delegation Decision Tree

Use one of these paths.

| Situation | Pattern | Rule |
|---|---|---|
| Small fix, focused doc edit, or one coherent implementation | Single lead agent | Do the work locally. Do not delegate. |
| Need to find where behavior lives, inspect logs, compare docs, or map code paths | Explorer subagent | Read-only. Return concise findings with file references. |
| Need independent review after changes | Reviewer subagent or fresh session | Read-only. Focus on correctness, regressions, security, and tests. |
| Need final evidence check before finish, especially with dirty worktree, scripts, tests, or Beads scope risk | Verifier / Gatekeeper | Conditional and read-only by default. Confirm scope, Bead, commands, acceptance evidence, and residual risk. |
| Need to decide whether something belongs in Beads, Nous memory, prompt context, or nowhere | Memory Steward | Read-only by default. Protect Beads/Nous/anchor boundaries and recommend the narrowest durable memory action. |
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

Verifier / Gatekeeper is a role, not a second implementer and not a ritual.
For ordinary work, the lead runs verification locally. Invoke a separate
verifier only when a false green would be expensive: release handoff,
non-trivial scripts, dirty worktree, flaky verification, Bead ambiguity, or any
claim that depends on a specific command having run. It should not rewrite the
work. It should say what evidence is sufficient, what is missing, and whether
the task is ready to finish.

Memory Steward is also read-only by default. Invoke it when work touches memory
boundaries: `bd remember`, Beads issues, prompt assembly, RAG context, product
strategy, Alex's personal/semantic memory, or `anchor.md`. It should keep stable
engineering lessons in Beads, product/semantic/personal memory in Nous, and
one-off notes out of durable memory. It must never edit `anchor.md`.

These roles do not mean "always spawn more agents." The lead agent may perform
the role locally for small tasks. Use a fresh thread/subagent only when
independent attention materially reduces risk.

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
done. That means evidence, not necessarily a second agent.

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

Use a separate Verifier / Gatekeeper before finishing only when any of these
are true:

- The task changed scripts, build/test gates, project config, or prompt/memory
  assembly.
- The worktree is dirty and task scope depends on path-limited checks.
- The final claim depends on a specific command, manual acceptance check, or
  Bead state.
- A previous review found a false OK, false PASS, or misleading handoff.

For lower-risk tasks, the lead should perform the same checks locally and
report the evidence directly.

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

Use Memory Steward before writing durable memory when any of these are true:

- The lesson might be about Alex, product strategy, tone, values, or design
  taste rather than repo engineering.
- The task touches prompt context, RAG, Galaxy semantics, memory extraction, or
  Beads integration.
- You are unsure whether to create a Bead, use `bd remember`, update docs, or
  leave the information ephemeral.

## Automation

The lightweight automation layer is intentionally advisory first:

- `scripts/beads_agent_workflow.sh start` and `status` print the short
  delegation reminder and point back to this playbook.
- `scripts/agentic_workflow_check.sh` checks for frozen-anchor edits, `.codex`
  agent/config changes, verification hints for Swift/project/script changes,
  direct `Nous.xcodeproj` drift, staged-file risk, and explicit Bead state.
  Use repeated `--path <file-or-dir>` arguments to limit changed-file, staging,
  and verification hints to the current task while keeping frozen-anchor safety
  global. A scoped check fails when the supplied paths match no changed files;
  use `--path .` only when the task intentionally covers the full dirty worktree.
- Hooks or CI gates are deferred until the workflow proves useful without
  blocking legitimate local work.

## Agent Harness Upgrade Roadmap

Use the harness as a measurable system, not a vibe check.

- V1 tool reliability telemetry: persist structured tool outcome, provider,
  quick-action mode, duration, iteration, and error category in agent traces.
- V2 behavior eval: add lightweight satisfaction proxies such as immediate
  correction, repeated question, deletion, or continued forward motion.
- V3 dynamic context manifest: record which memories, skills, and citations were
  loaded for a turn and whether they were actually used.
- V4 model harness profiles: tune tool schema, cache, thinking capture, step
  budget, and fallback policy per provider/model.
- V5 delegation metrics: measure whether explorers/verifiers reduce rework or
  merely add coordination cost.

## Measuring Whether This Helps

Static checks prove documentation completeness and workflow visibility only.
They do not prove agent behavior has improved.

When using this playbook on the next 5-10 non-trivial tasks, track:

- Whether delegation happened only after a Context Boundary Card.
- Unnecessary delegation count.
- Scope leaks, write-set conflicts, or duplicate investigations.
- False-green or rework incidents after the first handoff.
- Whether a verifier found concrete missing evidence when one was justified.

Until those case studies exist, describe results as documentation completeness
or workflow visibility, not as measured agent-quality improvement.

Run the check after task verification and before closing the Bead:

```bash
scripts/agentic_workflow_check.sh --bead <id> \
  --path docs/agentic-engineering-workflow.md \
  --path scripts/beads_agent_workflow.sh \
  --path scripts/agentic_workflow_check.sh
scripts/beads_agent_workflow.sh finish <id> "<verification summary>"
```

## Reusable Prompts

Read-only exploration:

```text
Context Boundary Card:
- Task objective: Explore <area/question>.
- Context needed: Inspect only <files/modules/logs>.
- Context excluded: Do not inspect or propose changes outside <excluded area>.
- Expected output: Concise findings with file references and open questions.
- Stop condition: Stop after mapping entry points, data flow, and likely files.
- Verification evidence: Cite the exact files/lines or commands inspected.

Do not edit files.
```

Parallel explorer split:

```text
Spawn one read-only explorer per area: <area A>, <area B>, <area C>. Each
explorer must include a Context Boundary Card, inspect only its assigned area,
avoid proposing fixes unless necessary to explain a risk, and return a short
summary with file references. Wait for all results before synthesizing.
```

Worker implementation:

```text
You are responsible only for <files/modules>. Other agents may be editing
elsewhere. Do not revert or overwrite changes you did not make. Implement the
requested behavior, write or update the focused tests for your change, run the
specified verification, and report changed files, commands run, evidence seen,
and remaining risks.
```

Fresh review:

```text
Review this diff like an owner. Prioritize correctness, behavior regressions,
security/privacy risks, and missing tests. Lead with concrete findings tied to
files and lines. Skip style-only comments unless they hide a real bug.
```

Verifier / Gatekeeper:

```text
Act as Verifier / Gatekeeper for this task. Do not edit files. Check whether
the claimed scope, Bead, changed files, verification commands, and acceptance
evidence prove the task is ready to finish. Look for false OK/PASS paths,
dirty-worktree leakage, missing commands, and residual risks. Name the concrete
commands, files, diffs, or outputs you inspected. Return only findings, required
fixes, or "ready to finish" with the evidence you relied on.
```

Memory Steward:

```text
Act as Memory Steward for this task. Do not edit files. Decide what belongs in
Beads, what belongs in Nous product/semantic/personal memory, what belongs in
docs, and what should remain ephemeral. Protect `anchor.md`: it is frozen.
Return the recommended memory action, boundary risks, and any wording that
should or should not be stored.
```

Handoff:

```text
Summarize the current state for the next agent: goal, files changed, important
decisions, commands run, verification results, unresolved risks, and the next
small action.
```
