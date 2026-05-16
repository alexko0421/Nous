# Agent Outcome Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Upgrade Nous's agent workflow so delegation is driven by explicit outcome contracts, measurable rubrics, and reviewable reflection instead of vague "agent team" enthusiasm.

**Architecture:** Keep Nous on its current one-lead-agent default. Borrow the useful parts of Managed Agents research: isolated context boundaries, structured handoff contracts, outcome rubrics, and post-run learning. Do not adopt an external managed-agent runtime in this phase; preserve Beads as engineering memory and Nous as Alex/product memory.

**Tech Stack:** Swift/XcodeGen macOS project, Beads CLI, existing Agent Work settings surface, `GovernanceTelemetryStore`, `BehaviorEvalRunner`, `RuntimeHarnessSnapshot`, shell guard scripts.

---

## Research Fit

### Source Notes

- Anthropic's Managed Agents overview describes Managed Agents as a managed harness best suited for long-running, asynchronous work with cloud infrastructure, stateful sessions, built-in tools, prompt caching, and compaction: https://platform.claude.com/docs/en/managed-agents/overview
- The multiagent docs describe coordinator-led delegation where agents share a filesystem but run in isolated session threads. The useful patterns are fan-out parallelization, specialization, and escalation to a stronger agent/model for a subset of work: https://platform.claude.com/docs/en/managed-agents/multi-agent
- The outcomes docs define a rubric-driven loop: the worker produces an artifact, a separate grader context evaluates it per criterion, and feedback is routed back until satisfied or the iteration cap is reached: https://platform.claude.com/docs/en/managed-agents/define-outcomes
- The PDF's strongest practical rule is output-contract standardization: handoffs fail when one agent returns loose prose and the next agent expects structured data.

### Fit For Nous

| Concept | Fit | Decision |
|---|---:|---|
| External Claude Managed Agents runtime | 2/5 | Do not adopt now. It would outsource tool/runtime/memory control and conflicts with the local trust boundary. |
| Fan-out read-only exploration | 5/5 | Adopt as a clearer pattern for independent file/log/source analysis. |
| Specialist coding teams | 2/5 | Keep deferred. Too much context loss unless write sets are genuinely disjoint. |
| Outcome rubrics | 5/5 | Adopt as local contracts for Beads tasks, plan tasks, and verifier handoffs. |
| Separate grader context | 4/5 | Adopt through fresh review/verifier prompts and behavior evals, not vendor-managed outcomes. |
| Dreaming/background learning | 4/5 | Adopt only as reviewable reflection over engineering outcomes. Never auto-write Alex/product memory. |
| Up to 20 agents / 25 threads | 1/5 | Not a goal. Nous's risk is bad coordination, not too little parallelism. |

## Product Principle

This upgrade is for Alex's real bottleneck: coding agents can drift, duplicate work, claim completion too early, or lose context across sessions. The absence hurts when the task is long, dirty, or cross-surface. The fix should make delegation more trustworthy, not more theatrical.

## Non-Goals

- Do not modify `Sources/Nous/Resources/anchor.md`.
- Do not integrate Claude Managed Agents, Anthropic containers, or a new cloud runtime.
- Do not turn Beads issues into `NousNode`, Galaxy nodes, or Nous memory rows.
- Do not add third-party dependencies.
- Do not change quick-action runtime semantics in this plan.
- Do not spawn worker agents by default; keep the one-lead-agent posture.

## Target Shape

Every non-trivial delegated task should have an **Agent Outcome Contract**:

```text
Task objective:
Context included:
Context excluded:
Output schema:
Failure behavior:
Acceptance rubric:
Verification evidence:
Stop condition:
```

The contract is deliberately boring. If the lead cannot fill it in, the task should stay in the lead thread.

## Files

- Modify: `docs/agentic-engineering-workflow.md`
- Modify: `scripts/beads_agent_workflow.sh`
- Modify: `scripts/agentic_workflow_check.sh`
- Modify: `Sources/Nous/Models/BeadsAgentWork.swift`
- Modify: `Sources/Nous/Services/BeadsAgentWorkService.swift`
- Modify: `Sources/Nous/Views/AgentWorkView.swift`
- Modify: `Sources/Nous/Models/HarnessHealth.swift`
- Modify: `Sources/Nous/Services/GovernanceTelemetryStore.swift`
- Modify: `Sources/Nous/Services/RuntimeHarnessService.swift`
- Modify: `Sources/Nous/Services/BehaviorEvalRunner.swift`
- Test: `Tests/NousTests/BeadsAgentWorkServiceTests.swift`
- Test: `Tests/NousTests/HarnessHealthTests.swift`
- Test: `Tests/NousTests/BehaviorEvalTests.swift`
- Test: `Tests/NousTests/PromptGovernanceTraceTests.swift`

## Phase 1: Contract The Existing Workflow

### Task 1: Extend The Context Boundary Card

**Files:**
- Modify: `docs/agentic-engineering-workflow.md`
- Modify: `scripts/beads_agent_workflow.sh`
- Modify: `scripts/agentic_workflow_check.sh`

- [x] **Step 1: Update the playbook contract**

Add these three fields to the Context Boundary Card in `docs/agentic-engineering-workflow.md`:

```markdown
- **Output schema:** the exact structure the lead expects back: bullets, JSON,
  table, patch summary, changed files, or pass/fail findings.
- **Failure behavior:** what the subagent should do when blocked, uncertain,
  or unable to verify. It should report the gap and stop rather than inventing.
- **Acceptance rubric:** the concrete criteria the lead will use to decide
  whether the returned work is usable.
```

Expected: the card now distinguishes "what to do" from "what usable output looks like."

- [x] **Step 2: Update reusable prompts**

In every reusable prompt that says `Context Boundary Card:`, include:

```text
- Output schema: Return bullets under Findings, Evidence, Open Questions, and Remaining Risk unless the prompt names a narrower format.
- Failure behavior: If blocked, return the blocker, evidence inspected, and the next smallest unblock.
- Acceptance rubric: The result is acceptable only if the lead can use it without re-reading the assigned files and every claim has a file, command, or source reference.
```

Expected: read-only exploration, parallel explorer split, worker implementation, verifier, memory steward, and handoff prompts all mention the output contract when relevant.

- [x] **Step 3: Update helper script reminder**

In `scripts/beads_agent_workflow.sh`, change the agentic gate line from:

```bash
- Use the Context Boundary Card before delegating.
```

to:

```bash
- Use the Context Boundary Card with output schema, failure behavior, and acceptance rubric before delegating.
```

Expected: `scripts/beads_agent_workflow.sh start` prints the upgraded reminder.

- [x] **Step 4: Update guard script wording**

In `scripts/agentic_workflow_check.sh`, update the printed agentic workflow reminder the same way.

Expected: `scripts/agentic_workflow_check.sh --path docs/agentic-engineering-workflow.md` surfaces the upgraded rule in its output.

- [x] **Step 5: Verify docs/script-only gate**

Run:

```bash
scripts/agentic_workflow_check.sh --bead new-york-9fwc \
  --path docs/agentic-engineering-workflow.md \
  --path scripts/beads_agent_workflow.sh \
  --path scripts/agentic_workflow_check.sh
```

Expected: no anchor edit, no `.codex` edit, scoped changed files are exactly the three files above.

## Phase 2: Surface Outcome Readiness In Agent Work

### Task 2: Parse Outcome Contract Signals From Beads

**Files:**
- Modify: `Sources/Nous/Models/BeadsAgentWork.swift`
- Modify: `Sources/Nous/Services/BeadsAgentWorkService.swift`
- Test: `Tests/NousTests/BeadsAgentWorkServiceTests.swift`

- [x] **Step 1: Add a lightweight contract summary model**

Add this model near `BeadsIssue` in `Sources/Nous/Models/BeadsAgentWork.swift`:

```swift
struct AgentOutcomeContractSummary: Equatable {
    let hasObjective: Bool
    let hasContextIncluded: Bool
    let hasContextExcluded: Bool
    let hasOutputSchema: Bool
    let hasFailureBehavior: Bool
    let hasAcceptanceRubric: Bool
    let hasVerificationEvidence: Bool

    var isComplete: Bool {
        hasObjective &&
            hasContextIncluded &&
            hasContextExcluded &&
            hasOutputSchema &&
            hasFailureBehavior &&
            hasAcceptanceRubric &&
            hasVerificationEvidence
    }

    var missingLabels: [String] {
        var labels: [String] = []
        if !hasObjective { labels.append("objective") }
        if !hasContextIncluded { labels.append("context-in") }
        if !hasContextExcluded { labels.append("context-out") }
        if !hasOutputSchema { labels.append("output") }
        if !hasFailureBehavior { labels.append("failure") }
        if !hasAcceptanceRubric { labels.append("rubric") }
        if !hasVerificationEvidence { labels.append("verification") }
        return labels
    }
}
```

Expected: no behavior changes yet.

- [x] **Step 2: Attach the summary to `BeadsIssue`**

Add:

```swift
let outcomeContract: AgentOutcomeContractSummary
```

Initialize it after decoding `description` and any available `notes`/`design` fields. If the current `BeadsIssue` decoder does not expose `notes` or `design`, add optional decoded fields:

```swift
let notes: String?
let design: String?
```

Then compute:

```swift
outcomeContract = AgentOutcomeContractParser.parse(
    [description, notes ?? "", design ?? ""].joined(separator: "\n\n")
)
```

Expected: existing JSON without notes/design still decodes.

- [x] **Step 3: Add parser**

Add this small parser in `Sources/Nous/Models/BeadsAgentWork.swift`:

```swift
enum AgentOutcomeContractParser {
    static func parse(_ text: String) -> AgentOutcomeContractSummary {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        return AgentOutcomeContractSummary(
            hasObjective: containsAny(normalized, ["task objective", "objective:", "goal:"]),
            hasContextIncluded: containsAny(normalized, ["context included", "context needed", "context in"]),
            hasContextExcluded: containsAny(normalized, ["context excluded", "context out", "ignore"]),
            hasOutputSchema: containsAny(normalized, ["output schema", "expected output", "return format"]),
            hasFailureBehavior: containsAny(normalized, ["failure behavior", "if blocked", "when blocked"]),
            hasAcceptanceRubric: containsAny(normalized, ["acceptance rubric", "acceptance criteria", "rubric"]),
            hasVerificationEvidence: containsAny(normalized, ["verification evidence", "verification", "commands run"])
        )
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
```

Expected: parser is deterministic and does not inspect user/product memory.

- [x] **Step 4: Add decoder tests**

In `Tests/NousTests/BeadsAgentWorkServiceTests.swift`, add:

```swift
func testBeadsIssueDetectsCompleteOutcomeContract() throws {
    let json = """
    [{
      "id": "new-york-contract",
      "title": "Contracted task",
      "description": "Task objective: map logs.\\nContext included: build logs only.\\nContext excluded: source code changes.\\nOutput schema: findings table.\\nFailure behavior: stop if blocked.\\nAcceptance rubric: file refs and concrete risks.\\nVerification evidence: commands inspected.",
      "status": "open",
      "priority": 2,
      "issue_type": "task",
      "dependency_count": 0,
      "dependent_count": 0,
      "comment_count": 0
    }]
    """

    let issues = try JSONDecoder().decode([BeadsIssue].self, from: Data(json.utf8))
    XCTAssertTrue(issues[0].outcomeContract.isComplete)
    XCTAssertEqual(issues[0].outcomeContract.missingLabels, [])
}
```

Expected: PASS.

- [x] **Step 5: Add partial-contract test**

Add:

```swift
func testBeadsIssueReportsMissingOutcomeContractFields() throws {
    let json = """
    [{
      "id": "new-york-loose",
      "title": "Loose task",
      "description": "Please investigate the issue and tell me what you find.",
      "status": "open",
      "priority": 2,
      "issue_type": "task",
      "dependency_count": 0,
      "dependent_count": 0,
      "comment_count": 0
    }]
    """

    let issues = try JSONDecoder().decode([BeadsIssue].self, from: Data(json.utf8))
    XCTAssertFalse(issues[0].outcomeContract.isComplete)
    XCTAssertEqual(
        issues[0].outcomeContract.missingLabels,
        ["objective", "context-in", "context-out", "output", "failure", "rubric", "verification"]
    )
}
```

Expected: PASS.

- [x] **Step 6: Run focused tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/BeadsAgentWorkServiceTests
```

Expected: `BeadsAgentWorkServiceTests` passes.

### Task 3: Show Contract Readiness In Agent Work

**Files:**
- Modify: `Sources/Nous/Views/AgentWorkView.swift`
- Test: `Tests/NousTests/SettingsUILayoutTests.swift`

- [x] **Step 1: Add a compact contract badge**

In the issue row view in `AgentWorkView.swift`, add a small status row that shows:

```text
Contract ready
```

when `issue.outcomeContract.isComplete == true`, otherwise:

```text
Missing objective/output/failure/rubric/verification
```

Use existing rounded text/pill styling from the Agent Work view. Do not introduce a new color system.

Expected: the UI stays read-only and does not become a task editor.

- [x] **Step 2: Keep the current hierarchy calm**

Make the badge secondary to the bead title and status. Use the existing `AppColor.secondaryText` for incomplete detail and `Color(red: 0.16, green: 0.54, blue: 0.36)` for ready state.

Expected: Agent Work remains an engineering status panel, not a noisy dashboard.

- [x] **Step 3: Add layout regression test**

Extend `Tests/NousTests/SettingsUILayoutTests.swift` with a text assertion that `AgentWorkView.swift` contains `Contract ready` and `Missing`.

Expected: accidental removal of the contract surface is caught by the existing UI static test style.

- [x] **Step 4: Run focused tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/BeadsAgentWorkServiceTests -only-testing:NousTests/SettingsUILayoutTests
```

Expected: both tests pass.

## Phase 3: Turn Rubrics Into Local Outcome Checks

### Task 4: Add Outcome Contract Health To Runtime Harness

**Files:**
- Modify: `Sources/Nous/Models/HarnessHealth.swift`
- Modify: `Sources/Nous/Services/BeadsAgentWorkService.swift`
- Modify: `Sources/Nous/Services/RuntimeHarnessService.swift`
- Test: `Tests/NousTests/HarnessHealthTests.swift`

- [x] **Step 1: Add summary model**

Add to `Sources/Nous/Models/HarnessHealth.swift`:

```swift
struct AgentOutcomeContractHealthSummary: Equatable {
    let activeIssueCount: Int
    let completeContractCount: Int

    init(activeIssueCount: Int = 0, completeContractCount: Int = 0) {
        self.activeIssueCount = activeIssueCount
        self.completeContractCount = completeContractCount
    }

    var completionRate: Double {
        guard activeIssueCount > 0 else { return 0 }
        return Double(completeContractCount) / Double(activeIssueCount)
    }

    var summaryText: String {
        guard activeIssueCount > 0 else { return "No active Beads contract signals." }
        return "Outcome contracts \(completeContractCount)/\(activeIssueCount)"
    }
}
```

Expected: static model compiles.

- [x] **Step 2: Add field to `RuntimeHarnessSnapshot`**

Add:

```swift
var outcomeContracts: AgentOutcomeContractHealthSummary
```

Default it to `.init()` in the initializer and include it in `empty`.

Expected: existing callers compile after default argument insertion.

- [x] **Step 3: Compute summary from Beads snapshot**

In `BeadsAgentWorkService.loadSnapshot()`, compute active issues:

```swift
let activeIssues = inProgress + ready
let outcomeContracts = AgentOutcomeContractHealthSummary(
    activeIssueCount: activeIssues.count,
    completeContractCount: activeIssues.filter { $0.outcomeContract.isComplete }.count
)
```

Attach it to the returned runtime harness snapshot. If `RuntimeHarnessSnapshot` is loaded before Beads issues, add a `withOutcomeContracts(_:)` helper instead of threading Beads into `RuntimeHarnessService`.

Expected: Agent Work can show contract coverage without changing Beads storage.

- [x] **Step 4: Add harness test**

In `Tests/NousTests/HarnessHealthTests.swift`, add:

```swift
func testOutcomeContractHealthSummarizesCoverage() {
    let summary = AgentOutcomeContractHealthSummary(activeIssueCount: 4, completeContractCount: 3)
    XCTAssertEqual(summary.summaryText, "Outcome contracts 3/4")
    XCTAssertEqual(summary.completionRate, 0.75)
}
```

Expected: PASS.

- [x] **Step 5: Run focused tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/HarnessHealthTests -only-testing:NousTests/BeadsAgentWorkServiceTests
```

Expected: focused harness and Beads tests pass.

### Task 5: Add Behavior Eval Axis For Delegation Contract Quality

**Files:**
- Modify: `Sources/Nous/Models/BehaviorEval.swift`
- Modify: `Sources/Nous/Services/BehaviorEvalRunner.swift`
- Test: `Tests/NousTests/BehaviorEvalTests.swift`

- [x] **Step 1: Add axis**

Add a new case to `BehaviorEvalAxis`:

```swift
case delegationContract = "delegation_contract"
```

Expected: compile errors reveal every switch that needs the new axis handled.

- [x] **Step 2: Add deterministic result**

In `BehaviorEvalRunner.runQuickSuite(...)`, include a new result:

```swift
delegationContractResult()
```

Implement:

```swift
private func delegationContractResult() -> BehaviorEvalResult {
    let complete = AgentOutcomeContractParser.parse("""
    Task objective: inspect build logs.
    Context included: build logs and failing command output.
    Context excluded: source edits and unrelated tests.
    Output schema: return findings with file refs.
    Failure behavior: stop and report blocker.
    Acceptance rubric: at least one concrete finding or explicit no-issue evidence.
    Verification evidence: commands inspected.
    """)

    guard complete.isComplete else {
        return BehaviorEvalResult(
            id: "delegation_contract_complete_fixture",
            axis: .delegationContract,
            verdict: .failure,
            findings: [
                BehaviorEvalFinding(
                    code: "contract_parser_complete_fixture_failed",
                    severity: .failure,
                    message: "Delegation contract parser did not recognize the complete fixture."
                )
            ]
        )
    }

    return BehaviorEvalResult(
        id: "delegation_contract_complete_fixture",
        axis: .delegationContract,
        verdict: .pass,
        findings: []
    )
}
```

Expected: the quick behavior suite now guards the contract parser.

- [x] **Step 3: Add behavior eval test**

In `Tests/NousTests/BehaviorEvalTests.swift`, add:

```swift
func testQuickSuiteIncludesDelegationContractAxis() {
    let summary = BehaviorEvalRunner().runQuickSuite()
    XCTAssertTrue(summary.results.contains { $0.axis == .delegationContract && $0.verdict == .pass })
}
```

Expected: PASS.

- [x] **Step 4: Run focused tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/BehaviorEvalTests
```

Expected: behavior eval tests pass.

## Phase 4: Add Reviewable Dreaming, Not Auto-Memory

### Task 6: Write The Local Dream Review Rule

**Files:**
- Modify: `docs/agentic-engineering-workflow.md`
- Modify: `docs/beads-agent-memory.md`

- [x] **Step 1: Add a "Dream Review" section to the playbook**

Add:

```markdown
## Dream Review

For Nous, "dreaming" means periodic review of engineering outcomes, not
automatic memory mutation. A dream review may summarize Beads history,
delegation metrics, verifier misses, and repeated blockers. It may recommend:

- a playbook edit,
- a new behavior eval fixture,
- a Beads follow-up,
- or no durable change.

It must not write Alex/product/semantic memory, must not modify `anchor.md`, and
must not auto-promote lessons into `bd remember` without a Memory Steward pass.
```

Expected: future agents have a safe local interpretation of Dreaming.

- [x] **Step 2: Add boundary text to Beads protocol**

In `docs/beads-agent-memory.md`, add:

```markdown
Dream reviews are engineering retrospectives. Store only stable repo-specific
lessons in Beads. Product strategy, Alex memory, design taste, and one-off
conversation notes remain in Nous or nowhere.
```

Expected: the memory boundary stays explicit.

- [x] **Step 3: Run docs check**

Run:

```bash
scripts/agentic_workflow_check.sh --bead new-york-9fwc \
  --path docs/agentic-engineering-workflow.md \
  --path docs/beads-agent-memory.md
```

Expected: docs-only scoped check passes.

## Verification Plan

Run these after implementing the relevant phases:

```bash
git diff --check
scripts/agentic_workflow_check.sh --bead new-york-9fwc \
  --path docs/agentic-engineering-workflow.md \
  --path docs/beads-agent-memory.md \
  --path scripts/beads_agent_workflow.sh \
  --path scripts/agentic_workflow_check.sh \
  --path Sources/Nous/Models/BeadsAgentWork.swift \
  --path Sources/Nous/Services/BeadsAgentWorkService.swift \
  --path Sources/Nous/Views/AgentWorkView.swift \
  --path Sources/Nous/Models/HarnessHealth.swift \
  --path Sources/Nous/Services/BehaviorEvalRunner.swift \
  --path Tests/NousTests/BeadsAgentWorkServiceTests.swift \
  --path Tests/NousTests/HarnessHealthTests.swift \
  --path Tests/NousTests/BehaviorEvalTests.swift
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/BeadsAgentWorkServiceTests \
  -only-testing:NousTests/HarnessHealthTests \
  -only-testing:NousTests/BehaviorEvalTests \
  -only-testing:NousTests/SettingsUILayoutTests
```

If project config changes are introduced later, run `xcodegen generate` before the Xcode test command.

## Rollout Order

1. Ship Phase 1 alone if the branch is dirty or time is tight. It has the best safety-to-value ratio.
2. Ship Phases 2-3 when Agent Work is actively used to inspect Beads state.
3. Ship Phase 4 only after at least five real tasks have used Outcome Contracts, so the dream review has evidence instead of vibes.

## Stop Conditions

- Stop if the plan starts requiring external Managed Agents runtime.
- Stop if a proposed memory action crosses from Beads engineering memory into Nous user/product memory.
- Stop if UI work tries to make Agent Work editable instead of read-only.
- Stop if implementation touches unrelated voice/chat changes already dirty in the worktree.
