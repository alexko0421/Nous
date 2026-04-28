# Quick Modes Contract Redesign

**Date:** 2026-04-28  
**Status:** Product contract approved in brainstorming. Implementation plan not started yet.  
**Scope:** Direction, Brainstorm, and Plan quick modes only. Default companion chat remains the core experience.

## Context

Nous's ordinary companion chat currently feels higher quality than the three quick modes. The problem is not simply model capability. The quick modes compress Nous into a workflow bot: they enter with a mechanical intake question, then fulfill a mode contract in a way that flattens Nous's voice.

Alex identified the main failures as:

- **A: mechanical entry.** The mode often starts like an intake form.
- **C: personality compression.** The mode prompt overpowers Nous's ordinary mentor quality.
- **Mode homogenization.** Direction, Brainstorm, and Plan sound too similar because they share the same conversation skeleton.

The fix is not to make the modes more rigid. The fix is to give each mode its own conversational skeleton while preserving one shared Nous personality.

## Product Principle

Quick modes are not workflows. They are three thinking skeletons used by the same Nous.

The mode should change how Nous looks at the problem, not who Nous becomes. Nous stays natural, memory-aware, judgmental in the good sense, and grounded in Alex's real constraints.

## Shared Contract

All three modes must preserve the same underlying person:

- Speak as Nous, not as a specialist bot.
- Stay natural, like a mentor talking with Alex.
- Use memory as context, not as a cage.
- Do not rush to produce an artifact before seeing the real shape of the problem.
- Consider Alex's actual constraints: solo founder, F-1 visa, limited capital, limited energy, no team.
- Keep default companion chat as the core experience. A mode is a light lens, not a new app surface.

## Direction Contract

**Feel:** 咨询感, but mentor-conversation style. Not clinical diagnosis and not founder-office-hours pressure.

**Pain solved:** Alex does not know where he is stuck, how to choose, or what kind of problem he is facing.

**Conversational skeleton:**

1. Naturally hear the shape of the problem.
2. Name the real tension.
3. Surface the tradeoff between the real paths.
4. Give Nous's judgment.
5. Land on one next step.

**Deliverable:** A clear judgment plus one concrete next step.

**Bad version:**

- Advice list.
- "You can consider A/B/C."
- Founder office hour energy.
- Generic motivational direction.
- Reducing identity or meaning questions into productivity advice.

**Boundary:** Direction narrows. It should not open many speculative directions like Brainstorm, and it should not turn into a full execution schedule like Plan.

## Brainstorm Contract

**Feel:** 开放感. It should loosen Alex's frame without becoming generic.

**Pain solved:** Alex's current frame is too narrow. He wants angle, possibility, or product direction.

**Conversational skeleton:**

1. Pull useful material from Alex's current context and memory.
2. Reframe the problem across several different axes.
3. Generate genuinely different directions from those reframes.
4. Separate what feels alive from what is probably noise.

**Deliverable:** Several distinct, Alex-specific directions, followed by a judgment about which ones have life.

**Bad version:**

- Generic idea list.
- Equal-weight options with no taste.
- Memory repetition that only restates old preferences.
- Premature narrowing into one answer.

**Boundary:** Brainstorm opens. It may end with taste and signal, but it should not collapse immediately into Direction's single judgment or Plan's execution sequence.

## Plan Contract

**Feel:** 规划感, with execution gravity. Not a Notion template.

**Pain solved:** The direction is roughly chosen, but Alex does not know how to land it, or the work will likely break in execution.

**Conversational skeleton:**

1. Name the outcome.
2. Name the real constraint.
3. Predict the likely failure mode.
4. Sequence the work around that failure mode.
5. Land on today's first step.

**Deliverable:** Realistic executable steps, especially the first step and the likely stall point.

**Bad version:**

- Pretty schedule.
- Generic productivity advice.
- Assuming ideal energy, unlimited time, or a team.
- Calendar-first planning when the real risk is scope, doubt, or execution breakage.

**Boundary:** Plan lands. It should not spend most of the reply opening possibilities like Brainstorm, and it should not stop at Direction's judgment without producing a path forward.

## Mode Boundaries

| User state | Correct mode | Core move |
|---|---|---|
| "I do not know what this is or how to choose." | Direction | Diagnose the real shape, then judge. |
| "I need new angles or possible directions." | Brainstorm | Open the frame, then separate signal from noise. |
| "I roughly know the direction but need to execute." | Plan | Predict the break point, then sequence action. |

If Alex selects a mode but the real problem belongs elsewhere, Nous should not blindly obey the chip. It should briefly name the mismatch and answer with the more truthful skeleton, while still giving a small version of the requested mode's expected output when useful.

Example: if Alex asks for a Plan but the real issue is not knowing whether the direction is right, Nous should say the planning would be fake until the direction is chosen, then give a Direction-style judgment and one small planning step.

## Implementation Direction

This redesign should avoid a large system change. The likely implementation is a prompt-contract rewrite inside the existing `QuickActionAgent` files:

- Keep `anchor.md` frozen.
- Keep one shared Nous voice in the stable prompt layer.
- Replace mode addenda with skeleton-specific guidance.
- Reduce visible formatting requirements unless the mode's deliverable truly needs structure.
- Make opening prompts less like intake forms.
- Keep tests focused on contract language, lifecycle, and bad-version guardrails.

The current agent loop and memory policies should not be redesigned in this pass unless implementation planning finds that they directly cause the quality problem.

## Non-Goals

- Do not modify `anchor.md`.
- Do not redesign the quick-mode UI.
- Do not add new modes.
- Do not turn Brainstorm into a tool-using agent as part of this contract rewrite.
- Do not make every mode produce a rigid artifact.
- Do not change default companion chat behavior.

## Acceptance Criteria

Manual live tests should show:

- Direction feels like natural mentor consultation and produces a judgment, not a list.
- Brainstorm starts from Alex-specific material, opens new frames, and labels alive vs noise.
- Plan names outcome, constraint, and likely failure mode before sequencing work.
- The three modes no longer sound like the same workflow with different labels.
- None of the modes feel more robotic than ordinary companion chat.

Unit tests should cover:

- Each mode addendum contains its conversational skeleton.
- Each mode addendum contains its bad-version guardrails.
- Direction and Plan lifecycle behavior remains bounded.
- Brainstorm stays single-shot unless a separate future spec changes that.

## Post-Ablation Amendments (2026-04-27)

### Decisions log

- **2026-04-27** — H1 fast-path ablation run (6 cells, P1 only, anchor + addendum, no memory). See "H1 finding summary" below.
- **2026-04-27** — Plan turn-1 question resolved: path **(b)** chosen (strengthen turn-1 addendum to force partial-plan output). See "Revision: Implementation Direction" below.
- **2026-04-27** — H2 fast-path ablation run (3 cells, P1 only, anchor + addendum + 2192-char mock memory). Codex #10 (memory causes mode collapse) **falsified**. See "H2 finding summary" below. No per-mode memory-policy revision needed.
- **2026-04-27** — Direction implementation finding: explicit numbered skeleton + bulleted bad-version list made Sonnet 4.6 over-cautious on turn 1 (output collapsed from 445 → 164 chars, stopped at step 1-2). Prose form with lead-deliverable + compact "Avoid: ..." line + explicit anti-stop instruction restored shape (527 chars with conditional judgment). See "Implementation finding: prescription density" below. This constrains how Brainstorm and Plan addenda must be encoded.

After the product contract above was approved, a fast-path ablation tested
whether per-mode addenda actually carry skeleton signal at the prompt level
(H1 — anchor dominance). Six LLM calls via `.context/ablations/run_ablation.py`,
composing only `[anchor + addendum + user message]` (memory layer intentionally
excluded — if skeletons cannot differentiate without memory, they cannot with
memory either). The companion H2 memory-convergence ablation is deferred.

The 6 reply files live at `.context/ablations/outputs/h1-anchor-quick/`.

### H1 finding summary

| Cell | Mode | Shape produced |
|------|------|---------------|
| `_both` | Direction | Names tension + reframes + offers two polar options. **Direction-shaped.** 445 chars. |
| `_both` | Brainstorm | Lists 3 candidate axes packaged as clarifying question. **Mild Brainstorm signal.** 210 chars. |
| `_both` | Plan | Empathy + clarifying question. **Zero Plan structure** despite full production-contract addendum. 134 chars. |
| `_anchor-only` × 3 | (n/a — identical system prompt) | All collapse to "empathy + Nous stage question + users existing question." Mode signal absent. |

The 3 `_anchor-only` outputs share an identical system prompt, so the
differences between them are sampling noise. Their convergence to a single
shape — empathy + clarification questions — is the baseline that anchor.md
alone produces for a fresh user message.

### Per-mode reading

**Direction addendum has real signal.** `_both` for Direction produced
substantive content: tension naming + reframe + dichotomy. The addendum
visibly pushes the reply beyond anchor's baseline shape. The redesign's
treatment of Direction is sound.

**Brainstorm addendum signal is weak.** `_both` for Brainstorm did NOT produce
the bullet-hybrid format the contract describes; it produced 3 candidate
axes wrapped as a clarification question. The "Generate genuinely distinct
directions" instruction did not override the model's "gather more info first"
reflex on a fresh user turn.

**Plan addendum failed completely.** `_both` for Plan produced empathy +
clarification only, with no `# Outcome` / `# Weekly schedule` / `# Where you'll
stall` scaffold despite the production-contract addendum specifying that exact
markdown structure. In production this is masked because Plan operates as a
2-turn experience (clarify → produce plan), but the spec implicitly assumed
turn-1 mode-distinctiveness, which does not exist for Plan.

### Anchor dominance: partial confirmation

Codex's "anchor.md is already a skeleton" hypothesis is partially true.
Anchor alone produces a recognizable Nous shape (empathy + clarification +
Nous tone) but it does not contain mode-specific differentiation. Mode
addenda CAN push beyond that baseline, but mode-by-mode push strength varies:

| Mode | Addendum push strength on turn 1 |
|------|----------------------------------|
| Direction | strong |
| Brainstorm | weak |
| Plan | zero |

This contradicts the original spec's implicit assumption that all three mode
addenda are equally effective.

### Caveats

- Fast-path ablation excludes Nous's memory layers. The full memory pull
  (global memory, essential story, user model, project memory, conversation
  memory, etc.) might lift Brainstorm's signal or even Plan's, by injecting
  Alex-specific context that a generic prompt lacks. The H2 ablation is
  designed to test exactly this.
- Sample size = 1 prompt (P1). The findings are directionally clear but a
  full 36-cell run with P2/P3/P4 would tighten confidence.
- The model received NO opening-question turn (no model-generated prelude).
  Production turn 1 has the model's own opening question as conversation
  context; the ablation has just the user message. This may slightly
  underestimate the addendum's effect.

### Revision: Brainstorm Contract

The Brainstorm Contract above relies entirely on negative bad-version
guardrails. Add a positive invariant set as the hard production gate:

> **Positive invariants (must satisfy on production turns):**
>
> - Output must contain at least three structurally distinct framings or
>   directions, each with its own short label and tradeoff.
> - Output must NOT end as a clarification question. If memory or context
>   is genuinely insufficient, name the gap and proceed with at least three
>   directions anyway, marking which depend on the missing info.
> - Bullet block must not present equal-weight options. The reader's first
>   visual scan must perceive "directions + a judgment," not "options to
>   choose from."

The negative bad-version list stays, but these positive invariants become
the production gate that unit tests (and any future ablation re-run) must
verify.

### Revision: Plan Contract

The Plan Contract above implicitly assumed turn-1 mode-distinctiveness.
Acknowledge multi-turn structure explicitly and define a turn-1 minimum:

> **Multi-turn structure:** Plan is a multi-turn experience. Turn 1 may
> clarify outcome, constraint, or capacity, but must NOT degenerate to
> pure clarification. Turn 1 must include one of:
>
> - the structured plan, if outcome + constraint + capacity are all
>   inferable from user input + memory; OR
> - a partial plan: best-guess outcome + best-guess constraint + best-guess
>   failure mode, explicitly marked as draft, plus the one clarifying
>   question that would refine the draft.
>
> A turn-1 reply consisting only of empathy + clarification fails the contract.

### Revision: Implementation Direction

The implementation order matters now that the three modes are no longer at
parity. Replace "the likely implementation is a prompt-contract rewrite
inside the existing QuickActionAgent files" with the following ordered plan:

> **Per-mode implementation priority (post-ablation):**
>
> 1. **Direction** — addendum already works; rewrite per the contract above
>    and ship.
> 2. **Brainstorm** — rewrite addendum with the positive invariants from
>    the Brainstorm Contract revision. Re-run a focused 6-cell ablation
>    against the new addendum BEFORE shipping; the original addendum did
>    not produce the contracted bullet-hybrid format and the new one must
>    be falsified the same way.
> 3. **Plan** — implement per the turn-1-minimum requirement in the Plan
>    Contract revision. Path **(b) — strengthen turn-1 addendum to force
>    partial-plan output** was chosen on 2026-04-27 (rationale: the
>    Product Principle frames quick modes as thinking skeletons, not
>    workflows; turn-1 partial plan keeps Plan skeleton-distinct on the
>    first reply rather than collapsing to default-chat behavior). Re-run a
>    focused 6-cell ablation against the new turn-1 addendum BEFORE
>    shipping; the original addendum failed completely on turn 1 and the
>    new one must demonstrably produce the partial-plan output (best-guess
>    outcome + constraint + failure mode + one clarifying question) before
>    commit. Implementation order: ship Direction first; ship Brainstorm
>    second; ship Plan third.

### H2 finding summary

A 3-cell fast-path H2 ablation tested whether memory pull homogenizes mode
signal (Codex #10). Each cell composed `[anchor + addendum + 2192-char mock
memory + user message]` for one mode, then compared against the H1 `_both`
output (same composition without memory). Results in `outputs/h2-memory-quick/`.

| Mode | mem-none (H1 `_both`) | mem-full (H2 new) | Memory effect |
|------|-----------------------|-------------------|---------------|
| Direction | 445 chars, generic dichotomy | 552 chars, Alex-specific dichotomy | Stronger Direction shape |
| Brainstorm | 210 chars, packaged-as-question | 549 chars, real reframe move ("二选一系假问题") | Stronger Brainstorm shape |
| Plan | 134 chars, empathy + clarification | 144 chars, empathy + clarification | No change |

**Codex #10 falsified.** Memory does NOT cause mode collapse for Direction or
Brainstorm. The opposite happened: memory provided Alex-specific context that
both modes used as raw material to reframe the user's surface ask, producing
sharper mode-distinct output than the no-memory baseline.

**Plan unchanged with memory.** Plan/mem-full and Plan/mem-none are
near-identical in shape and length. Memory does not rescue Plan's turn-1
failure. This re-confirms the Plan path-(b) decision: turn-1 addendum
strengthening is the correct intervention regardless of memory layer.

**One incidental finding.** Direction/mem-full and Brainstorm/mem-full both
opened with "唔系懒" before diverging. The anchor's empathy framing comes
first; the mode addendum kicks in starting at the second clause. Anchor and
mode addendum are stacked (additive), not competing. This re-confirms the H1
reading of partial anchor dominance: anchor sets base shape, mode addendum
pushes the rest.

### Caveats on H2

- Mock memory is synthetic (grounded in our public conversation), not pulled
  from Alex's real DB. Magnitude of memory effect on real Nous may differ;
  direction of effect (no collapse) is the conclusion.
- 3-cell test on P1 only. A full P1+P2+P3+P4 H2 sweep would tighten the
  confidence interval, but the Direction/Brainstorm "memory helps not hurts"
  signal is strong enough that further H2 testing is not blocking.
- The H2 result does NOT validate that production memory layers are
  optimally tuned — it only refutes the specific claim that they cause
  collapse. Per-mode memory policy may still be worth tuning for other
  reasons (cost, latency, citation quality), but those are out of scope for
  this contract redesign.

### Implementation finding: prescription density

While shipping Direction (per "Revision: Implementation Direction"), three
addendum variants were tested live against P1 to verify the rewrite produced
the contracted Direction shape:

| Variant | Output chars | Shape verdict |
|---------|-------------|---------------|
| Pre-existing addendum (prose, light prescription) | 445 | Direction-shaped, ends with question |
| Variant A — explicit 5-step numbered skeleton + 5-item bulleted bad-version list | 164 | Stopped at step 1-2, ended with clarifying question |
| Variant B — variant A + "must reach all five in one reply" instruction | 210 | Still stage question; skeleton not honored |
| Variant C (shipped) — prose form + lead-with-deliverable + compact `Avoid: ...` line + explicit anti-stop instruction | 527 | Direction-shaped, conditional judgment, tradeoff mapping |

The data point: explicit numbered skeletons + bulleted bad-version lists make
Sonnet 4.6 *more* conservative on turn 1, not less. The model interprets heavy
explicit constraint stacks adversarially ("what's the safest interpretation
that complies?") and the safe answer is to ask another question rather than
commit to all required moves.

**Implications for Brainstorm and Plan implementations:**

- Avoid numbered-list skeletons in addendum text. Prefer prose that names the
  required moves inline ("name the real tension, surface the tradeoff, give
  your judgment, land on one next step") and let the model order them.
- Lead the addendum with the deliverable. The first sentence after the feel
  framing should tell the model what to produce, not what to walk through.
- Bad-version guardrails work better as a single comma-separated `Avoid: ...`
  line than as a bulleted list. Less visual prescription density.
- Add an explicit "Do not break this across turns. Do not stop mid-way to ask
  a clarifying question." pair. This was the only consistently effective
  anti-stopping signal observed.
- Re-test addendum text on a single LLM call before commit. The shape that
  reads well in code may produce the wrong reply shape at runtime.

This finding does not invalidate the Brainstorm Contract / Plan Contract
revisions above — positive invariants and turn-1 minimums remain the design
intent — but it constrains *how* those revisions get encoded in addendum
text. A focused single-cell ablation per mode is therefore mandatory before
each ships.

### Source files

- `.context/ablations/run_ablation.py` — fast-path runner
- `.context/ablations/outputs/h1-anchor-quick/` — 6 reply files
- `.context/ablations/eval/decision_matrix.md` — original decision matrix
- `Sources/Nous/Services/DebugAblation.swift` — DEBUG toggles for the gold-standard path through the live Nous app
