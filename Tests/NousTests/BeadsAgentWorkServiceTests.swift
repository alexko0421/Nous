import XCTest
@testable import Nous

final class BeadsAgentWorkServiceTests: XCTestCase {
    func testDefaultCommandsExposeReadOnlyAgentWorkflow() {
        let commands = BeadsAgentWorkCommand.defaultCommands

        XCTAssertEqual(commands.map(\.command), [
            "bd prime",
            "bd ready --json",
            "scripts/nous_harness_check.sh quick",
            "scripts/nous_harness_check.sh full",
            "scripts/setup_beads_agent_memory.sh"
        ])
        XCTAssertTrue(commands.allSatisfy { !$0.command.contains(" close ") })
        XCTAssertTrue(commands.allSatisfy { !$0.command.contains(" update ") })
        XCTAssertTrue(commands.allSatisfy { !$0.command.contains(" remember ") })
    }

    func testSetupHintPointsMissingBdToSetupScript() {
        let hint = BeadsAgentWorkSetupHint.message(
            errorMessage: "Could not launch bd: The file bd does not exist.",
            beadsPath: ""
        )

        XCTAssertTrue(hint.contains("scripts/setup_beads_agent_memory.sh --install"))
    }

    func testRepositoryLocatorPrefersExplicitRepoRootEnvironment() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWorkRepositoryLocatorTests-\(UUID().uuidString)", isDirectory: true)
        let explicitRoot = tempRoot.appendingPathComponent("explicit", isDirectory: true)
        let fallbackRoot = tempRoot.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: explicitRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fallbackRoot.appendingPathComponent("Sources/Nous/Services", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "".write(to: explicitRoot.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        try "".write(to: fallbackRoot.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let located = AgentWorkRepositoryLocator.defaultWorkingDirectoryURL(
            environment: ["NOUS_REPO_ROOT": explicitRoot.path],
            sourceFileURL: fallbackRoot.appendingPathComponent("Sources/Nous/Services/BeadsAgentWorkService.swift"),
            currentDirectoryURL: fallbackRoot
        )

        XCTAssertEqual(located?.standardizedFileURL, explicitRoot.standardizedFileURL)
    }

    func testBeadsIssueDetectsCompleteOutcomeContract() throws {
        let json = """
        [{
          "id": "new-york-contract",
          "title": "Contracted task",
          "description": "Worker profile: explorer.\\nTask objective: map logs.\\nContext included: build logs only.\\nContext excluded: source code changes.\\nOwnership paths: logs/.\\nForbidden actions: do not edit files.\\nSandbox policy: read-only inspection; no writes.\\nOutput schema: findings table.\\nStop condition: stop after mapping the failure.\\nFailure behavior: stop if blocked.\\nAcceptance rubric: file refs and concrete risks.\\nVerification evidence: commands inspected.",
          "status": "open",
          "priority": 2,
          "issue_type": "task",
          "dependency_count": 0,
          "dependent_count": 0,
          "comment_count": 0
        }]
        """

        let issues = try JSONDecoder().decode([BeadsIssue].self, from: Data(json.utf8))

        XCTAssertEqual(issues[0].outcomeContract.workerProfile, .explorer)
        XCTAssertTrue(issues[0].outcomeContract.isComplete)
        XCTAssertEqual(issues[0].outcomeContract.missingLabels, [])
    }

    func testBeadsIssueRequiresSandboxPolicyEvenWithWorkerProfile() throws {
        let json = """
        [{
          "id": "new-york-no-sandbox",
          "title": "Contract without sandbox",
          "description": "Worker profile: worker.\\nTask objective: update tests.\\nContext included: focused test files.\\nContext excluded: unrelated UI.\\nOwnership paths: Tests/NousTests/.\\nForbidden actions: do not edit anchor.md.\\nOutput schema: changed files and verification.\\nStop condition: stop after focused tests.\\nFailure behavior: stop if blocked.\\nAcceptance rubric: tests prove the behavior.\\nVerification evidence: commands run.",
          "status": "open",
          "priority": 2,
          "issue_type": "task",
          "dependency_count": 0,
          "dependent_count": 0,
          "comment_count": 0
        }]
        """

        let issues = try JSONDecoder().decode([BeadsIssue].self, from: Data(json.utf8))

        XCTAssertEqual(issues[0].outcomeContract.workerProfile, .worker)
        XCTAssertFalse(issues[0].outcomeContract.isComplete)
        XCTAssertEqual(issues[0].outcomeContract.missingLabels, ["sandbox"])
    }

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
            ["profile", "objective", "context-in", "context-out", "ownership", "forbidden", "sandbox", "output", "stop", "failure", "rubric", "verification"]
        )
    }

    func testBeadsIssueDoesNotTreatIgnoredTextAsContextOut() throws {
        let json = """
        [{
          "id": "new-york-almost-contract",
          "title": "Almost contracted task",
          "description": "Worker profile: explorer.\\nTask objective: map logs.\\nContext included: build logs only.\\nIgnored an old warning after checking it was stale.\\nOwnership paths: logs/.\\nForbidden actions: do not edit files.\\nSandbox policy: read-only inspection; no writes.\\nOutput schema: findings table.\\nStop condition: stop after mapping the failure.\\nFailure behavior: stop if blocked.\\nAcceptance rubric: file refs and concrete risks.\\nVerification evidence: commands inspected.",
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
        XCTAssertEqual(issues[0].outcomeContract.missingLabels, ["context-out"])
    }

    func testOutcomeContractABFixtureSeparatesLooseAndContractedBeads() throws {
        let json = """
        [
          {
            "id": "new-york-a",
            "title": "A loose handoff",
            "description": "Ask another agent to inspect this and report back.",
            "status": "open",
            "priority": 2,
            "issue_type": "task",
            "dependency_count": 0,
            "dependent_count": 0,
            "comment_count": 0
          },
          {
            "id": "new-york-b",
            "title": "B contracted handoff",
            "description": "Worker profile: worker.\\nTask objective: inspect this gate.\\nContext included: changed workflow docs and tests.\\nContext excluded: unrelated voice UI files.\\nOwnership paths: docs/ and scripts/.\\nForbidden actions: do not edit unrelated files.\\nSandbox policy: write-scoped to ownership paths only.\\nOutput schema: findings first, then evidence.\\nStop condition: stop after checking changed files.\\nFailure behavior: stop and report blocker.\\nAcceptance rubric: every finding has file evidence.\\nVerification evidence: commands inspected.",
            "status": "open",
            "priority": 2,
            "issue_type": "task",
            "dependency_count": 0,
            "dependent_count": 0,
            "comment_count": 0
          }
        ]
        """

        let issues = try JSONDecoder().decode([BeadsIssue].self, from: Data(json.utf8))

        XCTAssertFalse(issues[0].outcomeContract.isComplete)
        XCTAssertTrue(issues[1].outcomeContract.isComplete)
        XCTAssertGreaterThan(
            issues[0].outcomeContract.missingLabels.count,
            issues[1].outcomeContract.missingLabels.count
        )
    }

    func testLoadSnapshotDecodesReadOnlyAgentWorkLists() throws {
        let runner = FakeBeadsCommandRunner(outputs: [
            "where": "/Users/alex/.local/share/nous/beads\n",
            "ready --json": """
            [
              {
                "id": "new-york-0hm",
                "title": "Evaluate native Beads graph",
                "description": "Decide whether a later native graph is worth it.",
                "status": "open",
                "priority": 3,
                "issue_type": "task",
                "created_at": "2026-04-30T20:00:00Z",
                "updated_at": "2026-04-30T20:05:00Z",
                "dependency_count": 0,
                "dependent_count": 0,
                "comment_count": 0
              }
            ]
            """,
            "list --status=in_progress --json": """
            [
              {
                "id": "new-york-129",
                "title": "Design read-only Beads surface in Nous",
                "description": "Show active coding-agent work without writing to Beads.",
                "status": "in_progress",
                "priority": 2,
                "issue_type": "feature",
                "assignee": "codex",
                "created_at": "2026-04-30T20:10:00Z",
                "updated_at": "2026-04-30T20:15:00Z",
                "started_at": "2026-04-30T20:12:00Z",
                "dependency_count": 1,
                "dependent_count": 0,
                "comment_count": 2,
                "dependencies": [
                  {
                    "issue_id": "new-york-129",
                    "depends_on_id": "new-york-b1e",
                    "type": "discovered-from",
                    "created_at": "2026-04-30T18:57:24Z",
                    "created_by": "codex",
                    "metadata": "{}"
                  }
                ]
              }
            ]
            """,
            "list --status=closed --sort=closed --reverse --limit=1 --json": """
            [
              {
                "id": "new-york-b1e",
                "title": "Wire Beads setup",
                "description": "Add shared Beads setup and protocol docs.",
                "status": "closed",
                "priority": 1,
                "issue_type": "task",
                "closed_at": "2026-04-30T20:20:00Z",
                "close_reason": "Setup script, docs, and workflow helper shipped.",
                "dependency_count": 0,
                "dependent_count": 1,
                "comment_count": 1
              },
              {
                "id": "new-york-l61",
                "title": "Older closed work",
                "description": "",
                "status": "closed",
                "priority": 4,
                "issue_type": "task",
                "closed_at": "2026-04-29T20:20:00Z",
                "dependency_count": 0,
                "dependent_count": 0,
                "comment_count": 0
              }
            ]
            """
        ])
        let service = BeadsAgentWorkService(commandRunner: runner, recentClosedLimit: 1)

        let snapshot = try service.loadSnapshot()

        XCTAssertEqual(snapshot.beadsPath, "/Users/alex/.local/share/nous/beads")
        XCTAssertEqual(snapshot.ready.map(\.id), ["new-york-0hm"])
        XCTAssertEqual(snapshot.inProgress.map(\.id), ["new-york-129"])
        XCTAssertEqual(snapshot.inProgress.first?.dependencies.map(\.id), ["new-york-b1e"])
        XCTAssertEqual(snapshot.inProgress.first?.dependencies.first?.relation, "discovered-from")
        XCTAssertEqual(snapshot.recentClosed.map(\.id), ["new-york-b1e"])
        XCTAssertEqual(snapshot.recentClosed.first?.closeReason, "Setup script, docs, and workflow helper shipped.")
        XCTAssertEqual(runner.invocations, [
            ["where"],
            ["ready", "--json"],
            ["list", "--status=in_progress", "--json"],
            ["list", "--status=closed", "--sort=closed", "--reverse", "--limit=1", "--json"]
        ])
    }

    func testLoadSnapshotUsesFirstPathLineFromMultilineBdWhereOutput() throws {
        let runner = FakeBeadsCommandRunner(outputs: [
            "where": """
            /Users/alex/.local/share/nous/beads
              (via redirect from /private/tmp/nous-v1-pr/.beads)
              database: /Users/alex/.local/share/nous/beads/embeddeddolt
            """,
            "ready --json": "[]",
            "list --status=in_progress --json": "[]",
            "list --status=closed --sort=closed --reverse --limit=6 --json": "[]"
        ])
        let service = BeadsAgentWorkService(commandRunner: runner)

        let snapshot = try service.loadSnapshot()

        XCTAssertEqual(snapshot.beadsPath, "/Users/alex/.local/share/nous/beads")
        XCTAssertEqual(snapshot.beadsConnection.message, "/Users/alex/.local/share/nous/beads")
    }

    func testProcessBeadsCommandRunnerTimesOutHungCommand() throws {
        let runner = ProcessBeadsCommandRunner(
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            timeout: 0.1,
            executableOverride: (
                url: URL(fileURLWithPath: "/bin/sh"),
                argumentsPrefix: ["-c", "sleep 2"]
            )
        )

        XCTAssertThrowsError(try runner.run([])) { error in
            guard case BeadsAgentWorkServiceError.commandTimedOut(let arguments, let timeout) = error else {
                XCTFail("Expected commandTimedOut, got \(error)")
                return
            }
            XCTAssertEqual(arguments, [])
            XCTAssertEqual(timeout, 0.1, accuracy: 0.001)
        }
    }

    func testProcessBeadsCommandRunnerDrainsLargeOutputBeforeWaitingForExit() throws {
        let runner = ProcessBeadsCommandRunner(
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            timeout: 2,
            executableOverride: (
                url: URL(fileURLWithPath: "/bin/sh"),
                argumentsPrefix: ["-c", "yes x | head -c 200000"]
            )
        )

        let output = try runner.run([])

        XCTAssertEqual(output.count, 200_000)
    }

    func testLoadSnapshotTreatsBlankJsonAsEmptyLists() throws {
        let runner = FakeBeadsCommandRunner(outputs: [
            "where": "  /shared/beads  \n",
            "ready --json": "",
            "list --status=in_progress --json": "   \n",
            "list --status=closed --sort=closed --reverse --limit=6 --json": "[]"
        ])
        let service = BeadsAgentWorkService(commandRunner: runner)

        let snapshot = try service.loadSnapshot()

        XCTAssertEqual(snapshot.beadsPath, "/shared/beads")
        XCTAssertTrue(snapshot.ready.isEmpty)
        XCTAssertTrue(snapshot.inProgress.isEmpty)
        XCTAssertTrue(snapshot.recentClosed.isEmpty)
    }

    func testLoadSnapshotAddsOutcomeContractHealthToRuntimeHarness() throws {
        let runner = FakeBeadsCommandRunner(outputs: [
            "where": "/Users/alex/.local/share/nous/beads\n",
            "ready --json": """
            [
              {
                "id": "new-york-ready-contract",
                "title": "Ready contracted task",
                "description": "Worker profile: explorer.\\nTask objective: map logs.\\nContext included: build logs only.\\nContext excluded: source code changes.\\nOwnership paths: logs/.\\nForbidden actions: do not edit files.\\nSandbox policy: read-only inspection; no writes.\\nOutput schema: findings table.\\nStop condition: stop after mapping the failure.\\nFailure behavior: stop if blocked.\\nAcceptance rubric: file refs and concrete risks.\\nVerification evidence: commands inspected.",
                "status": "open",
                "priority": 2,
                "issue_type": "task",
                "dependency_count": 0,
                "dependent_count": 0,
                "comment_count": 0
              }
            ]
            """,
            "list --status=in_progress --json": """
            [
              {
                "id": "new-york-loose-contract",
                "title": "Loose active task",
                "description": "Please investigate the issue.",
                "status": "in_progress",
                "priority": 2,
                "issue_type": "task",
                "dependency_count": 0,
                "dependent_count": 0,
                "comment_count": 0
              }
            ]
            """,
            "list --status=closed --sort=closed --reverse --limit=6 --json": "[]"
        ])
        let runtime = RuntimeHarnessSnapshot(totalTurnCount: 1)
        let service = BeadsAgentWorkService(
            commandRunner: runner,
            runtimeHarnessLoader: FakeRuntimeHarnessLoader(snapshot: runtime)
        )

        let snapshot = try service.loadSnapshot()

        XCTAssertEqual(snapshot.runtimeHarness.outcomeContracts.totalIssueCount, 2)
        XCTAssertEqual(snapshot.runtimeHarness.outcomeContracts.completeIssueCount, 1)
        XCTAssertEqual(snapshot.runtimeHarness.outcomeContracts.incompleteIssueCount, 1)
        XCTAssertEqual(snapshot.runtimeHarness.outcomeContracts.missingFieldCounts["objective"], 1)
        XCTAssertTrue(snapshot.runtimeHarness.outcomeContracts.summaryText.contains("Outcome contracts 1/2 ready"))
    }

    func testHarnessOnlySnapshotLoadsQualityStateWithoutBeadsCommands() {
        let harnessRun = HarnessRunRecord(
            mode: .quick,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 12),
            findings: [.sourceSetChanged],
            detail: "Quick gate passed."
        )
        let harness = HarnessHealthSnapshot(recentRuns: [harnessRun])
        let runtime = RuntimeHarnessSnapshot(
            totalTurnCount: 2,
            reviewedTurnCount: 2,
            reviewerCoverageRate: 1,
            riskFlagCounts: ["sycophancy_risk": 1],
            lastRiskFlags: ["sycophancy_risk"],
            sycophancyFixtureTrend: "9/9 sycophancy fixtures passing"
        )
        let runner = FakeBeadsCommandRunner(outputs: [:])
        let service = BeadsAgentWorkService(
            commandRunner: runner,
            harnessLoader: FakeHarnessHealthLoader(snapshot: harness),
            runtimeHarnessLoader: FakeRuntimeHarnessLoader(snapshot: runtime)
        )

        let snapshot = service.loadHarnessOnlySnapshot()

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertEqual(snapshot.harness.latestQuickRun, harnessRun)
        XCTAssertEqual(snapshot.runtimeHarness, runtime)
        XCTAssertTrue(snapshot.ready.isEmpty)
        XCTAssertTrue(snapshot.inProgress.isEmpty)
        XCTAssertTrue(snapshot.recentClosed.isEmpty)
    }

    func testHarnessOnlySnapshotCarriesBeadsConnectionErrorSeparately() {
        let harnessRun = HarnessRunRecord(
            mode: .quick,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 12),
            findings: [.sourceSetChanged],
            detail: "Quick gate passed."
        )
        let service = BeadsAgentWorkService(
            commandRunner: FakeBeadsCommandRunner(outputs: [:]),
            harnessLoader: FakeHarnessHealthLoader(snapshot: HarnessHealthSnapshot(recentRuns: [harnessRun])),
            runtimeHarnessLoader: FakeRuntimeHarnessLoader(snapshot: RuntimeHarnessSnapshot(totalTurnCount: 1))
        )

        let snapshot = service.loadHarnessOnlySnapshot(connectionError: "bd where exited with status 1.")

        XCTAssertEqual(snapshot.beadsConnection.status, .failed)
        XCTAssertEqual(snapshot.beadsConnection.message, "bd where exited with status 1.")
        XCTAssertEqual(snapshot.harness.latestQuickRun, harnessRun)
        XCTAssertEqual(snapshot.runtimeHarness.totalTurnCount, 1)
    }

    func testFailedBeadsConnectionDisplaysConcreteErrorInsteadOfUnavailablePath() {
        let connection = BeadsConnectionState.failed(message: "bd where exited with status 1: missing redirect")

        XCTAssertEqual(
            connection.pathDisplayText(beadsPath: "", unavailableText: "Beads path unavailable"),
            "bd where exited with status 1: missing redirect"
        )
    }

    @MainActor
    func testViewModelKeepsHarnessVisibleWhenBeadsRefreshFails() async {
        let harnessRun = HarnessRunRecord(
            mode: .quick,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 12),
            findings: [.sourceSetChanged],
            detail: "Quick gate passed."
        )
        let service = BeadsAgentWorkService(
            commandRunner: FakeBeadsCommandRunner(outputs: [:]),
            harnessLoader: FakeHarnessHealthLoader(snapshot: HarnessHealthSnapshot(recentRuns: [harnessRun])),
            runtimeHarnessLoader: FakeRuntimeHarnessLoader(snapshot: RuntimeHarnessSnapshot(totalTurnCount: 1))
        )
        let viewModel = BeadsAgentWorkViewModel(service: service)

        viewModel.refresh()
        for _ in 0..<50 where viewModel.isLoading {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.snapshot.harness.latestQuickRun, harnessRun)
        XCTAssertEqual(viewModel.snapshot.runtimeHarness.totalTurnCount, 1)
    }
}

private final class FakeBeadsCommandRunner: BeadsCommandRunning {
    private let outputs: [String: String]
    private(set) var invocations: [[String]] = []

    init(outputs: [String: String]) {
        self.outputs = outputs
    }

    func run(_ arguments: [String]) throws -> String {
        invocations.append(arguments)
        let key = arguments.joined(separator: " ")
        guard let output = outputs[key] else {
            throw MissingFakeBeadsOutput(arguments: arguments)
        }
        return output
    }
}

private struct MissingFakeBeadsOutput: Error {
    let arguments: [String]
}

private struct FakeHarnessHealthLoader: HarnessHealthLoading {
    let snapshot: HarnessHealthSnapshot

    func loadSnapshot() -> HarnessHealthSnapshot {
        snapshot
    }
}

private struct FakeRuntimeHarnessLoader: RuntimeHarnessLoading {
    let snapshot: RuntimeHarnessSnapshot

    func loadSnapshot() -> RuntimeHarnessSnapshot {
        snapshot
    }
}
