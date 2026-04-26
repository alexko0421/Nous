# Anchor 1 — Nelson & Narens Meta-Level Monitoring/Control

## Research Memo (revised v2 after Codex consult 2026-04-25)

**One-line summary:** Cognition operates on two levels — an *object level* (the task) and a *meta level* (which monitors and controls the object level). They form a **feedback loop**: monitoring updates the meta-level model; control uses that model to alter the object-level process; consequences are then re-monitored. For one-shot prompts that cannot loop, the practical translation is **field separation** — commit the monitoring read in the emitted object before deriving the control decision.

**The framework.** Nelson & Narens (1990) defined two directional relations:
- **Object level** = the ongoing task: remembering, judging, problem-solving, deciding, conversing.
- **Meta level** = a model of the object level. Receives **monitoring** signals (object → meta: "I'm uncertain", "this feels familiar", "I'm stuck") and emits **control** signals (meta → object: "reread", "switch strategy", "stop", "ask for help").

The framework is **explicitly cyclic, not a one-pass sequence**. The canonical learning model: judge mastery → allocate study time / pick strategy → implement → cycle recurs. Nelson & Narens also stress that monitoring is imperfect and distorted, never a clean readout of state. Canonical examples in metamemory: monitoring includes Ease-of-Learning judgments, Feeling-of-Knowing, Judgments-of-Learning, Retrospective Confidence; control includes study-time allocation, strategy selection, termination of study.

**Adaptation note for ProvocationJudge.** Judge runs once per turn (1.5s timeout, JSON output). Cannot run a full implement→observe→update cycle. Best-fit surgical adaptation: **field separation**. Force the model to emit a monitoring read in the JSON object before the control fields, so monitoring is auditable and control must be derivable from it. Not what the framework canonically prescribes — just the engineering best-fit for a one-shot context, guaranteeing the meta-level commitment is captured.

**Measurement note (Fleming & Lau 2014).** Their paper distinguishes metacognitive **sensitivity** (discrimination), **bias** (overall over/under-confidence), and **efficiency** (sensitivity adjusted for object-level skill) as separable measurement constructs, and warns these get conflated. They do *not* prove broad independence in the strong engineering sense.

**Engineering extrapolation (mine, not from the literature).** Adding monitoring signals to a judge prompt without explicit control-derivation rules can produce confident-sounding intervention decisions that aren't grounded in the monitoring read. The fix is field separation + a rule that control must be entailed by the monitoring read + pool.

**Anti-patterns the framework rules out.**
1. **Control without monitoring** — jumping to intervention without reading the cognitive state.
2. **Monitoring without control** — observation paralysis (annotating user state but not acting).
3. **Conflating confidence with accuracy** — endorsing high-conviction user claims without checking grounding.
4. **Faking certainty** — when the meta level is genuinely uncertain, suppressing that uncertainty hides useful information.

**Interaction with other anchors.** Nelson & Narens is the architectural lens that the next 4 anchors plug into:
- **Reis** (responsiveness) = a control choice grounded in monitoring of emotional need.
- **Kross** (self-distancing) = a specific control move available after monitoring a stuck emotional state.
- **Watkins** (rumination) = unconstructive object-level repetition the meta level should detect (monitor) and break (control).
- **Gable** (capitalization) = monitor for positive-event signals before defaulting to problem-solving control.

**Sources.**
- Nelson, T. O., & Narens, L. (1990). *Metamemory: A theoretical framework and new findings.* Psychology of Learning and Motivation, 26, 125–173. (PDF: https://pdf.retrievalpractice.org/metacognition/4_Nelson_Narens_1990.pdf — see Fig. 1 + "Then the cycle recurs" passage)
- Fleming, S. M., & Lau, H. C. (2014). *How to measure metacognition.* Frontiers in Human Neuroscience, 8:443.

---

## Proposed Surgical Edits (revised v2)

### Edit A — `Sources/Nous/Resources/anchor.md` 「HOW YOU THINK」 (lines 47-56)

**Unchanged from v1.** anchor.md feeds Sonnet's internal thinking through long-conversation context, not schema-bound output, so a thinking-move bullet is the right surface. The cyclic framing (vs linear) doesn't change this surgical edit since the bullet only asks Nous to register state *before* moving — it doesn't claim a linear architecture.

**Insert as a new bullet at the top of the existing 6-move list** (before "分 control / not control"):

```
- Monitor before control：先 read 一下 Alex 而家嘅 cognitive state — confident 定 uncertain，clear 定 muddled，stuck 定 moving？confidence 同 grounding 之间嘅 gap 本身就系信号。读咗状态先决定下一步落咩 move。
```

**Expected behavior change:** Nous explicitly registers the user's cognitive state before launching into control moves. Reduces premature intervention.

**Regression watch-list:**
- Interview-pattern guard (per `feedback_naturalness_discussion_mode.md`) — monitoring is internal thinking, must not turn into追问
- Stoic voice not flatten (per `feedback_rhythm_phase1_rejected.md`)
- Mode-balance per-mode (per `feedback_mode_balance_not_per_reply.md`) — 倾观点 mode keeps monitoring lightweight; 日常倾偈 mode keeps it nearly invisible

### Edit B — `Sources/Nous/Services/ProvocationJudge.swift` schema + struct (REVISED per Codex Q2)

v1 proposed a free-text SEQUENCING block in the system prompt. Codex correctly flagged this as prompt theater — text-only sequencing instructions don't enforce reasoning order; the model can produce a fluent `reason` rationalizing a decision it effectively chose first. **Replaced with a schema-level field separation.**

**Two coordinated changes:**

**B.1 — Add `monitor_summary` required field to the JSON SCHEMA** (in `ProvocationJudge.swift` `buildPrompt` lines 133-141), positioned BEFORE `should_provoke`:

```
SCHEMA
{
  "tension_exists": true | false,
  "user_state": "deciding" | "exploring" | "venting",
  "monitor_summary": {
    "state": "<one short clause about confidence, clarity, momentum, or receptivity>",
    "confidence_evidence_gap": "none | high-conviction-thin-grounding | low-confidence-strong-evidence"
  },
  "should_provoke": true | false,
  "entry_id": "<id from citable entries>" | null,
  "reason": "<short natural-language reason>",
  "inferred_mode": "companion" | "strategist"
}
```

**B.2 — Add 1-line RULE** (after existing RULES list, around line 167):

```
- should_provoke = true must be justified by monitor_summary + citable pool. If the provocation is not entailed by the monitoring read (e.g., monitor_summary says "muddled" but should_provoke ignores it), set should_provoke = false.
```

**B.3 — Update Swift struct (`JudgeVerdict`)** to add a new optional `monitor_summary: MonitorSummary?` field with `state: String, confidence_evidence_gap: String`. Optional because old persisted records won't have it; new ones will. (Not in this file — needs to find JudgeVerdict struct definition during Step 3.)

**Expected behavior change:**
- Judge cannot emit `should_provoke = true` without first emitting a `monitor_summary` that auditably grounds the decision
- Schema commitment is stronger than text-only sequencing instruction (per Codex critique: "required fields change task shape; freeform sequencing instructions mostly change style")
- Side benefit: `monitor_summary` is now logged/inspectable, enabling later analysis of judge calibration

**Regression watch-list:**
- **Latency** — additional required field adds ~30-50 output tokens per judge call. 1.5s timeout fallback rate must be measured; if it rises noticeably, shrink the `monitor_summary` schema (e.g., drop `confidence_evidence_gap` and keep only `state`)
- **Schema parse robustness** — old records without `monitor_summary` must still decode (struct field stays optional)
- **Codex caveat preserved** — schema field separation gives auditable commitment but does NOT prove internal reasoning order. Live-test must verify behavior changes, not just JSON shape changes
- **No markdown bold leakage** in Swift comments/strings around the new struct (per `feedback_no_markdown_bold_in_chat.md`)

---

## Live-Test Plan (Step 3, after Alex review of v2)

**Should-trigger 场景:**
1. Alex 抛一个高 confidence 但 thin-grounding 嘅 claim ("我觉得 X 一定系 Y"). Expected: `monitor_summary.confidence_evidence_gap = "high-conviction-thin-grounding"`, `should_provoke` likely true if relevant entry in pool, `reason` cites the gap.
2. Alex 问技术决定但表达 muddled. Expected: `monitor_summary.state = "muddled"`, Nous reply先 acknowledges muddled state then frames clear before take.

**Should-not-trigger 场景:**
1. 日常倾偈 ("hi", "返到屋企了"). Expected: `monitor_summary.state = "opening"`, `should_provoke = false`, judge runtime stays well under 1.5s.
2. 倾观点 mode share-lead reply on a clearly-grounded user opinion. Expected: `monitor_summary.confidence_evidence_gap = "none"`, Nous still leads with own take.

**Pass criteria:**
- ≥ 1 should-trigger scenario shows `monitor_summary` actually informing `should_provoke` / `reason` (not just decorative)
- 0 should-not-trigger scenarios show regression (interview pattern, voice flatten, etc.)
- Judge timeout fallback rate stays within 10% of pre-change baseline (manual sample, ~10 turns each)

---

## Codex Review Notes

Reviewed by `/codex consult` 2026-04-25 (session `019dc847-2817-7b00-ac4d-b67f2f7b947f`). Key changes from v1:

| Q | v1 | Codex critique | v2 fix |
|---|---|---|---|
| Q1 framing | "Information flows up then down... sequenced pair, not jumbled" | Academically overstated. N&N is **cyclic feedback loop**, not linear. | Reframed as feedback loop; added explicit "Adaptation note for one-shot ProvocationJudge: field separation" |
| Q1 Fleming&Lau | "showed... independent dimensions" | Too strong. Their paper is mainly about measurement; sensitivity/bias/efficiency are *separable measurement constructs*, not proven independent. | Softened to "separable measurement constructs"; relabeled my "better monitoring + bad control" claim as "engineering extrapolation, not from literature" |
| Q2 sequencing | Free-text SEQUENCING block in prompt | Prompt theater — model can rationalize control with `reason` field after deciding it first. | Replaced with schema-level field separation: required `monitor_summary` field BEFORE `should_provoke`, plus 1-line rule that control must be entailed by monitoring read |

Codex's caveat preserved: schema field separation gives auditable commitment but does NOT prove internal reasoning order. Live-test must measure behavior, not just JSON shape.

**Second-pass verify (2026-04-25, same session).** Two small further tweaks accepted from Codex:

1. "Correct surgical adaptation" → "Best-fit surgical adaptation" + explicit "not what the framework canonically prescribes — just engineering best-fit for one-shot context". Avoids implying the framework entails this JSON shape.
2. `monitor_summary.state` changed from closed enum (`confident|uncertain|muddled|stuck|opening|closing`) to short clause. Reason: the original enum mixed 4 different dimensions (confidence / clarity / momentum / receptivity), forcing arbitrary collapses. `confidence_evidence_gap` keeps its 3-value enum since values are clean and directly tied to the control rule.

Codex verdict on v2: "good enough conceptually" — proceed to Step 3 (apply edits + live-test).
