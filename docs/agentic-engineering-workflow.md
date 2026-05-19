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
- **Worker profile:** one of explorer, worker, reviewer, verifier, or memory
  steward.
- **Context needed:** the files, docs, logs, or concepts it should inspect.
- **Context excluded:** what it should ignore so it does not duplicate the lead.
- **Ownership paths:** the exact files, directories, or read-only areas it owns.
- **Forbidden actions:** edits, commands, memory writes, or scope expansions it
  must not perform.
- **Sandbox policy:** read-only, write-scoped to ownership paths, or explicit
  command-only permissions.
- **Output schema:** the exact structure the lead expects back: bullets, JSON,
  table, patch summary, changed files, or pass/fail findings.
- **Stop condition:** when it should stop exploring or editing.
- **Failure behavior:** what the subagent should do when blocked, uncertain,
  or unable to verify. It should report the gap and stop rather than inventing.
- **Acceptance rubric:** the concrete criteria the lead will use to decide
  whether the returned work is usable.
- **Verification evidence:** commands, file references, or checks required before
  claiming the subtask is ready.

If the card cannot be filled clearly, keep the work in the lead thread.

## Worker Profiles And Sandbox Policy

Worker profiles are permission bundles, not job titles. Pick the narrowest
profile that can finish the delegated slice.

| Profile | Default sandbox | Allowed work | Forbidden by default |
|---|---|---|---|
| Explorer | Read-only | Inspect files, logs, docs, and command output; map code paths. | File edits, Bead mutation, PR mutation, broad refactors. |
| Worker | Write-scoped | Edit only named ownership paths; run focused verification. | Reverting unrelated changes, expanding write set silently, editing `anchor.md`. |
| Reviewer | Read-only | Report bugs, regressions, missing tests, and residual risk. | Fixing the patch, staging files, rewriting the plan. |
| Verifier | Read-only | Check whether evidence supports the finish claim. | Re-implementation, cosmetic review, default ceremony. |
| Memory Steward | Read-only | Classify whether a lesson belongs in Beads, Nous memory, docs, or nowhere. | Writing durable memory, editing `anchor.md`, inferring Alex values. |

Sandbox policy must be explicit even when it feels obvious. "Read-only" means no
file writes and no mutating Beads/PR/git operations. "Write-scoped" means the
worker may edit only the ownership paths in the card and must list changed
files. Any broader write requires returning to the lead for a new boundary.

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

## Dream Review

Dream Review is for speculative product and workflow imagination before a task
turns into implementation. It is not Beads state, not a verifier, and not an
execution plan by itself.

Use it only to explore possibilities, pressure-test taste, and name what would
hurt if missing. Keep every output labeled as a hypothesis until the lead agent
translates it into a normal Context Boundary Card, bead, or implementation plan.

Dream Review must not:

- Modify `anchor.md` or reinterpret it as living memory.
- Write `bd remember`, create Beads issues, or change task state directly.
- Override the latest user instruction, current Bead scope, or verification
  requirements.
- Become product/semantic/personal memory unless Alex explicitly asks to capture
  it in Nous.

Before building from a Dream Review, reduce it to the same engineering contract
as any other task: objective, context in/out, output schema, failure behavior,
acceptance rubric, and verification evidence.

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
- Worker profile: explorer.
- Context needed: Inspect only <files/modules/logs>.
- Context excluded: Do not inspect or propose changes outside <excluded area>.
- Ownership paths: Read-only ownership of <files/modules/logs>.
- Forbidden actions: Do not edit files, create Beads, run mutating commands, or broaden scope.
- Sandbox policy: read-only.
- Output schema: Return bullets under Findings, Evidence, Open Questions, and Remaining Risk.
- Stop condition: Stop after mapping entry points, data flow, and likely files.
- Failure behavior: If blocked, return the blocker, evidence inspected, and the next smallest unblock.
- Acceptance rubric: The result is usable only if every claim has a file, command, or source reference.
- Verification evidence: Cite the exact files/lines or commands inspected.

Do not edit files.
```

Parallel explorer split:

```text
Spawn one read-only explorer per area: <area A>, <area B>, <area C>. Each
explorer must include a Context Boundary Card, inspect only its assigned area,
avoid proposing fixes unless necessary to explain a risk, and return bullets
under Findings, Evidence, Open Questions, and Remaining Risk. If blocked, it
must report the blocker and stop. Wait for all results before synthesizing.
Each card must name Worker profile: explorer and Sandbox policy: read-only.
```

Worker implementation:

```text
Context Boundary Card:
- Task objective: Implement <specific behavior>.
- Worker profile: worker.
- Context needed: Inspect <files/modules/tests> needed for this change.
- Context excluded: Ignore unrelated product/UI/worktree changes.
- Ownership paths: Write only inside <files/modules/tests>.
- Forbidden actions: Do not revert or overwrite changes you did not make; do not edit `Sources/Nous/Resources/anchor.md`; do not run destructive git commands.
- Sandbox policy: write-scoped to ownership paths only.
- Output schema: Return Changed Files, Verification, Residual Risk, and Notes.
- Stop condition: Stop when the owned patch and focused tests are complete.
- Failure behavior: If blocked, stop and return the blocker, files inspected, and the next smallest unblock.
- Acceptance rubric: The work is acceptable only when owned files changed, focused verification ran, and every residual risk is named.
- Verification evidence: List exact commands run and whether they passed.

You are not alone in the codebase. Other agents may be editing elsewhere; adjust
to their work without reverting unrelated changes.
```

Fresh review:

```text
Context Boundary Card:
- Task objective: Review <diff/branch/PR> like an owner.
- Worker profile: reviewer.
- Context needed: Inspect <diff/files/tests> needed to judge correctness.
- Context excluded: Do not redesign the feature or broaden into unrelated cleanup.
- Ownership paths: Read-only ownership of review findings.
- Forbidden actions: Do not edit files, stage files, close Beads, or mutate PR state.
- Sandbox policy: read-only.
- Output schema: Findings first by severity, then Open Questions, then Test Gaps.
- Stop condition: Stop after checking correctness, behavior regressions, security/privacy risk, and missing tests.
- Failure behavior: If the diff or evidence is unavailable, report the missing input and stop.
- Acceptance rubric: The review is usable only if every finding is tied to a file/line or concrete behavior.
- Verification evidence: Cite diff hunks, files, tests, or command output inspected.

Skip style-only comments unless they hide a real bug.
```

Verifier / Gatekeeper:

```text
Context Boundary Card:
- Task objective: Verify whether <task/bead/PR> is ready to finish.
- Worker profile: verifier.
- Context needed: Inspect <diff/status/test output/bead/docs>.
- Context excluded: Do not re-implement or broaden product scope.
- Ownership paths: Read-only ownership of verification evidence.
- Forbidden actions: Do not edit files, stage files, close Beads, or mutate PR state.
- Sandbox policy: read-only.
- Output schema: Return Findings, Evidence, Required Fixes, and Remaining Risk, or "ready to finish" with the evidence relied on.
- Stop condition: Stop after checking scope, changed files, Bead state, verification commands, skipped checks, and residual risks.
- Failure behavior: If evidence is missing, say what is missing and stop.
- Acceptance rubric: The verification is usable only if every ready/not-ready claim names concrete commands, files, diffs, or outputs inspected.
- Verification evidence: Cite exact commands, file paths, PR state, or Bead state.
```

Memory Steward:

```text
Context Boundary Card:
- Task objective: Decide the durable-memory boundary for <lesson/finding>.
- Worker profile: memory steward.
- Context needed: Inspect <conversation/task/docs/code> needed to classify it.
- Context excluded: Do not infer Alex values or product strategy beyond evidence.
- Ownership paths: Read-only ownership of memory-boundary judgment.
- Forbidden actions: Do not edit files, write `bd remember`, create Nous memory, or modify `Sources/Nous/Resources/anchor.md`.
- Sandbox policy: read-only.
- Output schema: Return Recommendation, Boundary Risks, Store wording, and Do Not Store wording.
- Stop condition: Stop once the narrowest durable-memory action is identified.
- Failure behavior: If the boundary cannot be decided, say what evidence is missing and do not recommend durable storage.
- Acceptance rubric: The recommendation is usable only if it keeps Beads, Nous memory, docs, and ephemeral notes separate.
- Verification evidence: Cite the source text, file, or Bead state inspected.
```

Handoff:

```text
Summarize the current state for the next agent: goal, files changed, important
decisions, commands run, verification results, unresolved risks, and the next
small action. The handoff is acceptable only if the next agent can continue
without re-reading unrelated logs or guessing what remains.
```
