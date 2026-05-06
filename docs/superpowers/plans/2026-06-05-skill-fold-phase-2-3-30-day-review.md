# Skill Fold Phase 2.3 30-Day Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Review the first 30 days of Skill Fold dogfood evidence and decide whether Phase 2.4 should keep, update, retire, or extend observation for the current seed skills.

**Architecture:** Treat the local dogfood JSONL as private telemetry, not as training data and not as user memory. The review reads sanitized skill metadata only, gates on privacy and sample size first, then uses behavior evals to prevent trust regressions before any seed-skill update.

**Tech Stack:** Swift/XcodeGen macOS project, local JSONL at `~/Library/Application Support/Nous/skill-fold-dogfood.jsonl`, `BehaviorEvalRunner dogfood-summary`, Beads for engineering task tracking.

---

## Context

Day-0 was verified on 2026-05-06. The real app flow wrote sanitized events for:

- `plan` -> `pain-test-before-building`
- `direction` -> `inversion-before-commitment`

The 30-day review date is 2026-06-05. Do not modify `Sources/Nous/Resources/anchor.md`.

During the observation window, avoid changing `Sources/Nous/Resources/seed-skills.json` unless there is a confirmed privacy leak or correctness bug. Changing the seed set mid-window invalidates the 30-day comparison.

## Files

- Read: `~/Library/Application Support/Nous/skill-fold-dogfood.jsonl`
- Read: `Sources/Nous/Resources/seed-skills.json`
- Read: `Tests/NousTests/SeedSkillsResourceTests.swift`
- Read: `Tests/NousTests/QuickActionAddendumResolverTests.swift`
- Read: `Sources/Nous/Services/QuickActionAddendumResolver.swift`
- Read: `Sources/Nous/Services/SkillDogfoodLogStore.swift`
- Read: `Sources/BehaviorEvalRunner/SkillDogfoodSummaryCLI.swift`
- Maybe modify: `Sources/Nous/Resources/seed-skills.json`
- Maybe modify: `Tests/NousTests/SeedSkillsResourceTests.swift`
- Maybe modify: `Tests/NousTests/QuickActionAddendumResolverTests.swift`
- Maybe modify: `Sources/BehaviorEvalRunner/SkillDogfoodSummaryCLI.swift`
- Maybe modify: `scripts/skill_dogfood_summary.sh`

## Decision Rules

Keep the current 10-skill seed set unchanged when:

- The log has fewer than 20 turns in the 30-day window.
- The log has fewer than 7 active days.
- The top skills are plausible and there is no trust regression.
- Evidence is inconclusive rather than harmful.

Extend observation by another 30 days when:

- Sample size is too small but the privacy and behavior gates pass.
- Usage is clustered into one or two days, making skill ranking unreliable.
- Phase 2.4 would require rewriting more than two seed skills.

Update at most two seed skills when:

- There are at least 20 turns and 7 active days.
- A skill fires often but its intent is clearly too broad or too weak.
- Behavior evals pass before and after the proposed change.
- The change preserves the existing first 10 IDs unless retiring is explicitly chosen.

Retire or demote a skill only when:

- It repeatedly fires in the wrong mode, or
- It creates visible prompt noise, or
- It correlates with a concrete trust/usefulness problem, or
- It has zero signal across a sufficiently active window and is not strategically important.

Stop immediately and fix privacy if:

- Any JSONL field contains user prompt text, assistant text, anchor content, source content, message content, or free-form model reasoning.
- The logger blocks chat or crashes the app.

## Task 1: Start The Review Bead

**Files:**
- Read: `docs/superpowers/plans/2026-06-05-skill-fold-phase-2-3-30-day-review.md`

- [ ] **Step 1: Start Beads context**

Run:

```bash
scripts/beads_agent_workflow.sh start
```

Expected: `ready work` and `in progress` are printed.

- [ ] **Step 2: Claim the deferred review bead**

Run:

```bash
bd ready
```

Expected: a review bead for the Skill Fold 30-day review is visible on or after 2026-06-05.

Run:

```bash
bd update <review-bead-id> --claim
```

Expected: the bead status becomes `in_progress`.

## Task 2: Collect The 30-Day Evidence

**Files:**
- Read: `~/Library/Application Support/Nous/skill-fold-dogfood.jsonl`
- Read: `scripts/skill_dogfood_summary.sh`
- Read: `Sources/BehaviorEvalRunner/SkillDogfoodSummaryCLI.swift`

- [ ] **Step 1: Run the 30-day summary**

Run:

```bash
scripts/skill_dogfood_summary.sh --days 30
```

Expected: output includes `turns`, `active days`, `zero-signal days`, and `top skills`.

- [ ] **Step 2: Capture raw metadata counts without opening prompt content**

Run:

```bash
LOG="$HOME/Library/Application Support/Nous/skill-fold-dogfood.jsonl"
wc -l "$LOG"
tail -n 20 "$LOG" | jq -r '[.mode, (.turnIndex|tostring), ([.matchedSkills[].name] | join(","))] | @tsv'
```

Expected: rows contain mode, turn index, and skill names only.

- [ ] **Step 3: Record the sample-size gate**

Use these thresholds:

```text
turns >= 20
active days >= 7
zero-signal days <= 23
```

Expected: write in the bead notes whether the review has enough evidence or should extend observation.

## Task 3: Run The Privacy Gate

**Files:**
- Read: `~/Library/Application Support/Nous/skill-fold-dogfood.jsonl`
- Read: `Sources/Nous/Models/SkillDogfoodLog.swift`
- Read: `Sources/Nous/Services/SkillDogfoodLogStore.swift`

- [ ] **Step 1: Inspect JSON keys**

Run:

```bash
LOG="$HOME/Library/Application Support/Nous/skill-fold-dogfood.jsonl"
tail -n 50 "$LOG" | jq -r 'keys_unsorted[]' | sort -u
```

Expected keys:

```text
id
inlineSkills
loadedSkills
matchedSkills
mode
recordedAt
turnIndex
```

- [ ] **Step 2: Inspect scalar paths**

Run:

```bash
LOG="$HOME/Library/Application Support/Nous/skill-fold-dogfood.jsonl"
tail -n 50 "$LOG" | jq -r 'paths(scalars) | map(tostring) | join(".")' | sort -u
```

Expected paths contain only:

```text
id
inlineSkills.<n>.id
inlineSkills.<n>.name
inlineSkills.<n>.priority
loadedSkills.<n>.id
loadedSkills.<n>.name
loadedSkills.<n>.priority
matchedSkills.<n>.id
matchedSkills.<n>.name
matchedSkills.<n>.priority
mode
recordedAt
turnIndex
```

- [ ] **Step 3: Grep for prompt-like fields**

Run:

```bash
LOG="$HOME/Library/Application Support/Nous/skill-fold-dogfood.jsonl"
if tail -n 50 "$LOG" | grep -Ei 'prompt|assistant|anchor|content|message|userText|assistantText|sourceText|currentUserInput'; then
  echo "PRIVACY GATE FAILED"
  exit 1
else
  echo "privacy gate passed"
fi
```

Expected: `privacy gate passed`.

- [ ] **Step 4: Stop if privacy fails**

If the privacy gate fails, do not update seed skills. Create a P0 bug bead and fix the logger first.

## Task 4: Classify Skill Evidence

**Files:**
- Read: `Sources/Nous/Resources/seed-skills.json`
- Read: `~/Library/Application Support/Nous/skill-fold-dogfood.jsonl`

- [ ] **Step 1: Count skills by mode**

Run:

```bash
LOG="$HOME/Library/Application Support/Nous/skill-fold-dogfood.jsonl"
jq -r '.mode as $mode | .matchedSkills[] | [$mode, .id, .name, (.priority|tostring)] | @tsv' "$LOG" \
  | sort \
  | uniq -c \
  | sort -nr
```

Expected: counts show which skills are firing in `plan`, `direction`, and `brainstorm`.

- [ ] **Step 2: Check the two Phase 2.2 additions**

Run:

```bash
LOG="$HOME/Library/Application Support/Nous/skill-fold-dogfood.jsonl"
jq -r 'select(.matchedSkills[].name == "pain-test-before-building" or .matchedSkills[].name == "inversion-before-commitment") | [.mode, (.turnIndex|tostring), ([.matchedSkills[].name] | join(","))] | @tsv' "$LOG"
```

Expected:

- `pain-test-before-building` appears in `plan`.
- `inversion-before-commitment` appears in `direction`.

- [ ] **Step 3: Write the evidence table in the bead notes**

Use this exact table shape:

```text
Skill Fold 30-day evidence:
- window: 2026-05-06 through 2026-06-05
- turns:
- active days:
- zero-signal days:
- top 5 skills:
- pain-test-before-building signal:
- inversion-before-commitment signal:
- wrong-mode observations:
- privacy gate:
- behavior gate:
- recommendation: keep | update | retire | extend
```

## Task 5: Run Behavior Gates Before Any Update

**Files:**
- Read: `scripts/run_behavior_evals.sh`
- Read: `scripts/run_behavior_experiments.sh`
- Read: `results/behavior_eval/runs.jsonl`
- Read: `results/behavior_eval/experiments.jsonl`

- [ ] **Step 1: Run a fresh quick baseline**

Run:

```bash
scripts/run_behavior_evals.sh --mode quick --live never
```

Expected: behavior eval passes and reports a trust score.

- [ ] **Step 2: Run a no-change Skill Fold experiment**

Run:

```bash
scripts/run_behavior_experiments.sh \
  --id skill-fold-phase-2-3-30-day-review \
  --mode quick \
  --live never \
  --expected-impact usefulness,voice,trust \
  --change-signature skill-fold-phase-2-3-review
```

Expected: no trust regression.

- [ ] **Step 3: Stop if trust regresses**

If trust drops, do not update seed skills. Open a bug bead for the trust regression and attach the experiment record.

## Task 6: Decide The Phase 2.4 Action

**Files:**
- Maybe modify: `Sources/Nous/Resources/seed-skills.json`
- Maybe modify: `Tests/NousTests/SeedSkillsResourceTests.swift`
- Maybe modify: `Tests/NousTests/QuickActionAddendumResolverTests.swift`

- [ ] **Step 1: Choose one action**

Choose exactly one:

```text
keep: no seed change; continue using current 10 skills
extend: no seed change; run another 30-day observation window
update: change at most two seed skill prompts or priorities
retire: disable or demote at most one clearly harmful skill
```

- [ ] **Step 2: If keep or extend, do not edit source**

Run:

```bash
git diff -- Sources/Nous/Resources/seed-skills.json Tests/NousTests/SeedSkillsResourceTests.swift Tests/NousTests/QuickActionAddendumResolverTests.swift
```

Expected: no new diff from the 30-day review.

- [ ] **Step 3: If update or retire, write the smallest regression test first**

For seed-count or mode-scope changes, update:

```bash
Tests/NousTests/SeedSkillsResourceTests.swift
```

The test must assert:

- total seed row count
- unchanged stable IDs for preserved skills
- expected mode scopes
- expected priority
- prompt fragment is non-empty

- [ ] **Step 4: Run the failing test before implementation**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/SeedSkillsResourceTests
```

Expected: if a seed change is planned, the test fails before the resource change.

- [ ] **Step 5: Make the minimal resource change**

Modify only:

```bash
Sources/Nous/Resources/seed-skills.json
```

Do not modify:

```bash
Sources/Nous/Resources/anchor.md
```

- [ ] **Step 6: Re-run seed tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/SeedSkillsResourceTests
```

Expected: tests pass.

## Task 7: Final Verification

**Files:**
- Read: `project.yml`
- Read: `Nous.xcodeproj/project.pbxproj`
- Read: `Sources/Nous`

- [ ] **Step 1: Regenerate the Xcode project**

Run:

```bash
xcodegen generate
```

Expected: project generation succeeds.

- [ ] **Step 2: Check for iCloud root Swift orphans**

Run:

```bash
find Sources/Nous -maxdepth 1 -name "*.swift" -print
```

Expected: no output.

- [ ] **Step 3: Run whitespace diff check**

Run:

```bash
git diff --check
```

Expected: no output.

- [ ] **Step 4: Run the relevant focused tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/SeedSkillsResourceTests \
  -only-testing:NousTests/SkillDogfoodLogStoreTests \
  -only-testing:NousTests/QuickActionAddendumResolverTests
```

Expected: all focused tests pass.

- [ ] **Step 5: Run the behavior gate after any update**

Run:

```bash
scripts/run_behavior_evals.sh --mode quick --live never
```

Expected: trust score does not regress from the pre-update baseline.

- [ ] **Step 6: Build the app**

Run:

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```

Expected: build succeeds.

- [ ] **Step 7: Run workflow check**

Run:

```bash
scripts/agentic_workflow_check.sh \
  --bead <review-bead-id> \
  --path docs/superpowers/plans/2026-06-05-skill-fold-phase-2-3-30-day-review.md \
  --path Sources/Nous/Resources/seed-skills.json \
  --path Tests/NousTests/SeedSkillsResourceTests.swift \
  --path Tests/NousTests/QuickActionAddendumResolverTests.swift \
  --path Sources/Nous/Services/SkillDogfoodLogStore.swift \
  --path Sources/BehaviorEvalRunner/SkillDogfoodSummaryCLI.swift \
  --path scripts/skill_dogfood_summary.sh
```

Expected: workflow check passes and confirms `anchor.md` is unchanged.

## Task 8: Close Or Extend

**Files:**
- Read: Beads task graph

- [ ] **Step 1: Close the review bead if a decision was made**

Run:

```bash
scripts/beads_agent_workflow.sh finish <review-bead-id> "<summary of evidence, decision, and verification>"
```

Expected: the review bead closes.

- [ ] **Step 2: If extending observation, create the next deferred bead**

Run:

```bash
bd create \
  --title "Skill Fold Phase 2.3 extended dogfood review" \
  --description "Review the extended Skill Fold dogfood observation window after the first 30-day sample was too small or inconclusive." \
  --acceptance "Dogfood summary, privacy gate, behavior gate, and keep/update/retire decision are recorded." \
  --type task \
  --priority 2
```

Then defer it 30 more days from the review date:

```bash
bd defer <new-bead-id> --until "2026-07-05"
```

Expected: a future review bead exists.

## Self-Review

- Spec coverage: The plan covers evidence collection, privacy gate, behavior gate, decision rules, optional update implementation, verification, and Beads handoff.
- Placeholder scan: No placeholder markers or unspecified test commands remain.
- Boundary check: The plan keeps `anchor.md` frozen and treats dogfood logs as local private metadata only.
