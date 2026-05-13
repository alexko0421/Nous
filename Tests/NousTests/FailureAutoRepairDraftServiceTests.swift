import XCTest
@testable import Nous

final class FailureAutoRepairDraftServiceTests: XCTestCase {
    func testDefaultRepositoryURLPointsAtRepoRoot() throws {
        let root = FailureAutoRepairDraftService.defaultRepositoryURL()

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/beads_agent_workflow.sh").path))
        XCTAssertFalse(root.path.hasSuffix("/Sources"))
    }

    func testPreflightBlocksDirtyWorktree() throws {
        let candidate = Self.makeApprovedCandidate()
        let runner = FakeFailureRepairCommandRunner(outputs: [
            "git status --porcelain --untracked-files=all": " M Sources/Nous/Views/ChatArea.swift\n"
        ])
        let service = FailureAutoRepairDraftService(
            repositoryURL: URL(fileURLWithPath: "/repo"),
            commandRunner: runner
        )

        XCTAssertThrowsError(try service.preflight(candidate: candidate, latestRun: nil)) { error in
            XCTAssertEqual(error as? FailureAutoRepairDraftServiceError, .dirtyWorktree)
        }
    }

    func testPreflightBlocksNonApprovedIncompleteAndObserveOnlyCandidates() throws {
        let service = FailureAutoRepairDraftService(
            repositoryURL: URL(fileURLWithPath: "/repo"),
            commandRunner: FakeFailureRepairCommandRunner(outputs: ["git status --porcelain --untracked-files=all": ""])
        )

        var proposed = Self.makeApprovedCandidate()
        proposed.status = .proposed
        XCTAssertThrowsError(try service.preflight(candidate: proposed, latestRun: nil)) { error in
            XCTAssertEqual(error as? FailureAutoRepairDraftServiceError, .candidateRequiresApproval)
        }

        var observeOnly = Self.makeApprovedCandidate()
        observeOnly.repairKind = .observeOnly
        XCTAssertThrowsError(try service.preflight(candidate: observeOnly, latestRun: nil)) { error in
            XCTAssertEqual(error as? FailureAutoRepairDraftServiceError, .unsupportedRepairKind)
        }

        var incomplete = Self.makeApprovedCandidate()
        incomplete.checklist = SkillifyChecklist(rootCause: "missing the rest")
        XCTAssertThrowsError(try service.preflight(candidate: incomplete, latestRun: nil)) { error in
            XCTAssertEqual(error as? FailureAutoRepairDraftServiceError, .incompleteChecklist)
        }

        var invalidSmoke = Self.makeApprovedCandidate()
        invalidSmoke.checklist = Self.makeChecklist(
            smokeTestCommand: "xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testDownvoteFeedbackDetailCreatesFailureSkillCandidate; rm -rf /tmp/nous"
        )
        XCTAssertThrowsError(try service.preflight(candidate: invalidSmoke, latestRun: nil)) { error in
            XCTAssertEqual(error as? FailureAutoRepairDraftServiceError, .invalidChecklist)
        }

        let activeRun = FailureSkillRepairRun(
            id: UUID(),
            candidateId: incomplete.id,
            status: .running,
            beadId: nil,
            branchName: "codex/failure-repair-test",
            commitSHA: nil,
            prURL: nil,
            logExcerpt: nil,
            error: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertThrowsError(try service.preflight(candidate: Self.makeApprovedCandidate(), latestRun: activeRun)) { error in
            XCTAssertEqual(error as? FailureAutoRepairDraftServiceError, .repairAlreadyRunning)
        }

        var openedRun = activeRun
        openedRun.status = .draftPROpened
        XCTAssertThrowsError(try service.preflight(candidate: Self.makeApprovedCandidate(), latestRun: openedRun)) { error in
            XCTAssertEqual(error as? FailureAutoRepairDraftServiceError, .repairDraftAlreadyOpened)
        }
    }

    func testCreateDraftPRRecordsRunAndExecutesDeterministicCommandSequence() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let runStore = FailureSkillRepairRunStore(nodeStore: nodeStore)
        let candidate = Self.makeApprovedCandidate()
        try candidateStore.upsertCandidate(candidate)

        let runner = FakeFailureRepairCommandRunner(outputs: [
            "scripts/beads_agent_workflow.sh create AutoRepair for Judge feedback: too forceful Repair approved failure candidate 00000000-0000-0000-0000-00000000F001. 1": #"{"id":"new-york-auto"}"#,
            "git fetch origin main": "",
            "git switch -C codex/failure-repair-judgeFeedbackTooForceful-00000000 origin/main": "",
            "codex exec --cd /repo --sandbox workspace-write --ask-for-approval never": "codex repaired",
            "xcodegen generate": "",
            "/bin/zsh -lc xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testDownvoteFeedbackDetailCreatesFailureSkillCandidate -only-testing:NousTests/SkillMatcherTests/testModeMatchFires -only-testing:NousTests/SkillifyChecklistEvaluatorTests": "",
            "git diff --check": "",
            "scripts/agentic_workflow_check.sh --bead new-york-auto": "",
            "git add -A": "",
            "git diff --cached --check": "",
            "git commit -m Repair failure skill candidate judgeFeedbackTooForceful": "[branch abc123] Repair",
            "git rev-parse HEAD": "abc123\n",
            "git push -u origin codex/failure-repair-judgeFeedbackTooForceful-00000000": "",
            "gh pr create --draft --base main --head codex/failure-repair-judgeFeedbackTooForceful-00000000 --title [codex] Repair judgeFeedbackTooForceful failure candidate --body-file -": "https://github.com/alexko0421/Nous/pull/123\n",
            "scripts/beads_agent_workflow.sh finish new-york-auto AutoRepairDraft opened draft PR https://github.com/alexko0421/Nous/pull/123 after verification.": ""
        ], sequentialOutputs: [
            "git status --porcelain --untracked-files=all": [
                "",
                "?? Tests/NousTests/FailureRepairRegressionTests.swift\n"
            ]
        ])
        let service = FailureAutoRepairDraftService(
            repositoryURL: URL(fileURLWithPath: "/repo"),
            commandRunner: runner
        )

        let run = try service.createDraftPR(
            for: candidate,
            runStore: runStore,
            candidateStore: candidateStore
        )

        XCTAssertEqual(run.status, .draftPROpened)
        XCTAssertEqual(run.beadId, "new-york-auto")
        XCTAssertEqual(run.branchName, "codex/failure-repair-judgeFeedbackTooForceful-00000000")
        XCTAssertEqual(run.commitSHA, "abc123")
        XCTAssertEqual(run.prURL, "https://github.com/alexko0421/Nous/pull/123")
        XCTAssertTrue(runner.invocations.contains { $0.executable == "codex" && $0.arguments.prefix(5) == ["exec", "--cd", "/repo", "--sandbox", "workspace-write"] })
        let codexInvocation = try XCTUnwrap(runner.invocations.first { $0.executable == "codex" })
        XCTAssertTrue(codexInvocation.standardInput?.contains("Evidence:") == true)
        XCTAssertTrue(codexInvocation.standardInput?.contains("Allowed files:") == true)
        XCTAssertTrue(codexInvocation.standardInput?.contains("id=judge-1") == true)
    }

    func testCreateDraftPRKeepsDraftPROpenedWhenPostPRBeadFinishFails() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let runStore = FailureSkillRepairRunStore(nodeStore: nodeStore)
        let candidate = Self.makeApprovedCandidate()
        try candidateStore.upsertCandidate(candidate)

        let runner = FakeFailureRepairCommandRunner(outputs: [
            "scripts/beads_agent_workflow.sh create AutoRepair for Judge feedback: too forceful Repair approved failure candidate 00000000-0000-0000-0000-00000000F001. 1": #"{"id":"new-york-auto"}"#,
            "git fetch origin main": "",
            "git switch -C codex/failure-repair-judgeFeedbackTooForceful-00000000 origin/main": "",
            "codex exec --cd /repo --sandbox workspace-write --ask-for-approval never": "codex repaired",
            "xcodegen generate": "",
            "/bin/zsh -lc xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testDownvoteFeedbackDetailCreatesFailureSkillCandidate -only-testing:NousTests/SkillMatcherTests/testModeMatchFires -only-testing:NousTests/SkillifyChecklistEvaluatorTests": "",
            "git diff --check": "",
            "scripts/agentic_workflow_check.sh --bead new-york-auto": "",
            "git add -A": "",
            "git diff --cached --check": "",
            "git commit -m Repair failure skill candidate judgeFeedbackTooForceful": "[branch abc123] Repair",
            "git rev-parse HEAD": "abc123\n",
            "git push -u origin codex/failure-repair-judgeFeedbackTooForceful-00000000": "",
            "gh pr create --draft --base main --head codex/failure-repair-judgeFeedbackTooForceful-00000000 --title [codex] Repair judgeFeedbackTooForceful failure candidate --body-file -": "https://github.com/alexko0421/Nous/pull/123\n"
        ], sequentialOutputs: [
            "git status --porcelain --untracked-files=all": [
                "",
                "?? Tests/NousTests/FailureRepairRegressionTests.swift\n"
            ]
        ])
        let service = FailureAutoRepairDraftService(
            repositoryURL: URL(fileURLWithPath: "/repo"),
            commandRunner: runner
        )

        let run = try service.createDraftPR(
            for: candidate,
            runStore: runStore,
            candidateStore: candidateStore
        )

        XCTAssertEqual(run.status, .draftPROpened)
        XCTAssertEqual(run.prURL, "https://github.com/alexko0421/Nous/pull/123")
        let latestRun = try XCTUnwrap(runStore.fetchLatestRun(candidateId: candidate.id))
        XCTAssertEqual(latestRun.status, .draftPROpened)
        XCTAssertEqual(latestRun.prURL, "https://github.com/alexko0421/Nous/pull/123")
        XCTAssertTrue(runner.invocations.contains { invocation in
            invocation.executable == "scripts/beads_agent_workflow.sh"
                && invocation.arguments.count >= 3
                && invocation.arguments[0] == "finish"
                && invocation.arguments[1] == "new-york-auto"
                && invocation.arguments[2].contains("AutoRepairDraft opened draft PR")
        })
    }

    func testCreateDraftPRRejectsDisallowedRepairDiffPaths() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let runStore = FailureSkillRepairRunStore(nodeStore: nodeStore)
        let candidate = Self.makeApprovedCandidate()
        try candidateStore.upsertCandidate(candidate)

        let runner = FakeFailureRepairCommandRunner(outputs: [
            "scripts/beads_agent_workflow.sh create AutoRepair for Judge feedback: too forceful Repair approved failure candidate 00000000-0000-0000-0000-00000000F001. 1": #"{"id":"new-york-auto"}"#,
            "git fetch origin main": "",
            "git switch -C codex/failure-repair-judgeFeedbackTooForceful-00000000 origin/main": "",
            "codex exec --cd /repo --sandbox workspace-write --ask-for-approval never": "codex repaired",
            "xcodegen generate": "",
            "/bin/zsh -lc xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testDownvoteFeedbackDetailCreatesFailureSkillCandidate -only-testing:NousTests/SkillMatcherTests/testModeMatchFires -only-testing:NousTests/SkillifyChecklistEvaluatorTests": "",
            "git diff --check": "",
            "scripts/agentic_workflow_check.sh --bead new-york-auto": ""
        ], sequentialOutputs: [
            "git status --porcelain --untracked-files=all": [
                "",
                " M docs/repair-notes.md\n?? Tests/NousTests/FailureRepairRegressionTests.swift\n"
            ]
        ])
        let service = FailureAutoRepairDraftService(
            repositoryURL: URL(fileURLWithPath: "/repo"),
            commandRunner: runner
        )

        XCTAssertThrowsError(try service.createDraftPR(
            for: candidate,
            runStore: runStore,
            candidateStore: candidateStore
        )) { error in
            XCTAssertEqual(error as? FailureAutoRepairDraftServiceError, .disallowedRepairDiff(["docs/repair-notes.md"]))
        }

        let latestRun = try XCTUnwrap(runStore.fetchLatestRun(candidateId: candidate.id))
        XCTAssertEqual(latestRun.status, .failed)
        XCTAssertTrue(latestRun.error?.contains("docs/repair-notes.md") == true)
        XCTAssertFalse(runner.invocations.contains { $0.executable == "git" && $0.arguments.first == "add" })
    }

    func testCreateDraftPRFinishesBeadWhenRepairFailsAfterBeadCreation() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let runStore = FailureSkillRepairRunStore(nodeStore: nodeStore)
        let candidate = Self.makeApprovedCandidate()
        try candidateStore.upsertCandidate(candidate)

        let runner = FakeFailureRepairCommandRunner(outputs: [
            "git status --porcelain --untracked-files=all": "",
            "scripts/beads_agent_workflow.sh create AutoRepair for Judge feedback: too forceful Repair approved failure candidate 00000000-0000-0000-0000-00000000F001. 1": #"{"id":"new-york-auto"}"#,
            "git fetch origin main": "",
            "git switch -C codex/failure-repair-judgeFeedbackTooForceful-00000000 origin/main": "",
            "codex exec --cd /repo --sandbox workspace-write --ask-for-approval never": "codex repaired"
        ])
        let service = FailureAutoRepairDraftService(
            repositoryURL: URL(fileURLWithPath: "/repo"),
            commandRunner: runner
        )

        XCTAssertThrowsError(try service.createDraftPR(
            for: candidate,
            runStore: runStore,
            candidateStore: candidateStore
        ))

        let latestRun = try XCTUnwrap(runStore.fetchLatestRun(candidateId: candidate.id))
        XCTAssertEqual(latestRun.status, .failed)
        XCTAssertEqual(latestRun.beadId, "new-york-auto")
        XCTAssertTrue(runner.invocations.contains { invocation in
            invocation.executable == "scripts/beads_agent_workflow.sh"
                && invocation.arguments.count >= 3
                && invocation.arguments[0] == "finish"
                && invocation.arguments[1] == "new-york-auto"
                && invocation.arguments[2].contains("AutoRepairDraft failed")
        })
    }

    private static func makeApprovedCandidate() -> FailureSkillCandidate {
        FailureSkillCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000F001")!,
            userId: "alex",
            sourceKind: .judgeFeedback,
            sourceId: "judge-1",
            turnId: nil,
            conversationId: nil,
            assistantMessageId: nil,
            signature: .judgeFeedbackTooForceful,
            repairKind: .promptSkill,
            status: .approved,
            evidence: [FailureSkillEvidence(source: .userFeedback, id: "judge-1", snippet: "too sharp")],
            proposedSkillPayload: SkillPayload(
                payloadVersion: 1,
                name: "judge-feedback-too-forceful",
                description: "Use when judge feedback says the challenge was too forceful.",
                useWhen: "Use when judge feedback says the challenge was too forceful.",
                source: .alex,
                trigger: SkillTrigger(kind: .always, modes: [], priority: 45),
                action: SkillAction(kind: .promptFragment, content: "Surface tension in a lower-pressure way."),
                rationale: "Alex marked the judge intervention as too forceful.",
                antiPatternExamples: ["Turning a small concern into a hard verdict."]
            ),
            checklist: Self.makeChecklist(),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10),
            activatedSkillId: nil
        )
    }

    private static func makeChecklist(
        smokeTestCommand: String = "xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ProvocationOrchestrationTests/testDownvoteFeedbackDetailCreatesFailureSkillCandidate -only-testing:NousTests/SkillMatcherTests/testModeMatchFires -only-testing:NousTests/SkillifyChecklistEvaluatorTests"
    ) -> SkillifyChecklist {
        SkillifyChecklist(
            rootCause: "Alex marked the judge intervention as too forceful.",
            trigger: "thumbs-down judge feedback with too_forceful reason",
            useWhen: "Use when judge feedback says the challenge was too forceful.",
            antiPatternExample: "Turning a small concern into a hard verdict.",
            regressionTestReference: "ProvocationOrchestrationTests.testDownvoteFeedbackDetailCreatesFailureSkillCandidate",
            resolverTestReference: "SkillMatcherTests.testModeMatchFires",
            smokeTestCommand: smokeTestCommand
        )
    }
}

private final class FakeFailureRepairCommandRunner: FailureRepairCommandRunning {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let standardInput: String?
    }

    private var outputs: [String: [String]]
    private(set) var invocations: [Invocation] = []

    init(outputs: [String: String], sequentialOutputs: [String: [String]] = [:]) {
        var mappedOutputs = outputs.mapValues { [$0] }
        for (key, values) in sequentialOutputs {
            mappedOutputs[key] = values
        }
        self.outputs = mappedOutputs
    }

    func run(_ command: FailureRepairCommand) throws -> String {
        invocations.append(Invocation(
            executable: command.executable,
            arguments: command.arguments,
            standardInput: command.standardInput
        ))
        let key = ([command.executable] + command.arguments).joined(separator: " ")
        guard var values = outputs[key], !values.isEmpty else {
            throw FailureAutoRepairDraftServiceError.commandFailed(key)
        }
        let output = values[0]
        if values.count > 1 {
            values.removeFirst()
            outputs[key] = values
        }
        return output
    }
}
