import XCTest
@testable import Nous

final class FailureSkillActivationTests: XCTestCase {
    func testApprovedCompletePromptSkillCandidateActivatesOnce() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let skillStore = SkillStore(nodeStore: nodeStore)
        var candidate = Self.makeCompletePromptSkillCandidate()
        candidate.status = .approved
        try candidateStore.upsertCandidate(candidate)

        let skill = try candidateStore.activateCandidate(id: candidate.id, skillStore: skillStore)

        XCTAssertEqual(skill.state, .active)
        XCTAssertEqual(skill.payload.name, "source-analysis-use-attached-material")
        XCTAssertTrue(try skillStore.fetchActiveSkills(userId: "alex").contains { $0.id == skill.id })
        let activatedCandidate = try XCTUnwrap(candidateStore.fetchCandidate(id: candidate.id))
        XCTAssertEqual(activatedCandidate.status, .activated)
        XCTAssertEqual(activatedCandidate.activatedSkillId, skill.id)
        XCTAssertThrowsError(try candidateStore.activateCandidate(id: candidate.id, skillStore: skillStore))
    }

    func testActivatedGlobalPromptSkillIsAvailableWithoutQuickActionMode() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let skillStore = SkillStore(nodeStore: nodeStore)
        var candidate = Self.makeCompletePromptSkillCandidate()
        candidate.status = .approved
        try candidateStore.upsertCandidate(candidate)

        let skill = try candidateStore.activateCandidate(id: candidate.id, skillStore: skillStore)
        let addendum = QuickActionAddendumResolver(
            skillStore: skillStore,
            skillMatcher: SkillMatcher()
        ).addendum(
            mode: nil,
            agent: nil,
            turnIndex: 1
        )

        XCTAssertEqual(skill.payload.trigger.kind, .always)
        XCTAssertEqual(skill.payload.trigger.modes, [])
        XCTAssertTrue(addendum?.contains("ground the answer in that source") == true)
    }

    func testConcurrentActivationOnlyInsertsOneSkill() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let skillStore = SkillStore(nodeStore: nodeStore)
        var candidate = Self.makeCompletePromptSkillCandidate()
        candidate.status = .approved
        try candidateStore.upsertCandidate(candidate)

        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let lock = NSLock()
        var successes: [Skill] = []
        var errors: [Error] = []

        for _ in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                do {
                    let skill = try candidateStore.activateCandidate(id: candidate.id, skillStore: skillStore)
                    lock.lock()
                    successes.append(skill)
                    lock.unlock()
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
                group.leave()
            }
        }
        for _ in 0..<16 {
            start.signal()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(try skillStore.fetchActiveSkills(userId: "alex").count, 1)
        XCTAssertEqual(
            errors.compactMap { $0 as? FailureSkillCandidateStoreError }.filter { $0 == .alreadyActivated }.count,
            15
        )
    }

    func testCompletePromptSkillCandidateCannotActivateBeforeApproval() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let skillStore = SkillStore(nodeStore: nodeStore)
        let candidate = Self.makeCompletePromptSkillCandidate()
        try candidateStore.upsertCandidate(candidate)

        XCTAssertThrowsError(try candidateStore.activateCandidate(id: candidate.id, skillStore: skillStore))
        XCTAssertTrue(try skillStore.fetchActiveSkills(userId: "alex").isEmpty)
        let fetched = try XCTUnwrap(candidateStore.fetchCandidate(id: candidate.id))
        XCTAssertEqual(fetched.status, .proposed)
        XCTAssertNil(fetched.activatedSkillId)
    }

    func testActivationRollsBackSkillInsertWhenCandidateUpdateFails() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let candidateStore = FailureSkillCandidateStore(nodeStore: nodeStore)
        let skillStore = SkillStore(nodeStore: nodeStore)
        var candidate = Self.makeCompletePromptSkillCandidate()
        candidate.status = .approved
        try candidateStore.upsertCandidate(candidate)
        try nodeStore.rawDatabase.exec("""
            CREATE TRIGGER fail_failure_skill_activation_update
            BEFORE UPDATE OF status ON failure_skill_candidates
            WHEN NEW.status = 'activated'
            BEGIN
                SELECT RAISE(ABORT, 'activation update failed');
            END;
        """)

        XCTAssertThrowsError(try candidateStore.activateCandidate(id: candidate.id, skillStore: skillStore))

        XCTAssertTrue(try skillStore.fetchActiveSkills(userId: "alex").isEmpty)
        let fetched = try XCTUnwrap(candidateStore.fetchCandidate(id: candidate.id))
        XCTAssertEqual(fetched.status, .approved)
        XCTAssertNil(fetched.activatedSkillId)
    }

    private static func makeCompletePromptSkillCandidate() -> FailureSkillCandidate {
        FailureSkillCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A111")!,
            userId: "alex",
            sourceKind: .contextManifest,
            sourceId: "manifest-1",
            turnId: UUID(uuidString: "00000000-0000-0000-0000-00000000A112")!,
            conversationId: UUID(uuidString: "00000000-0000-0000-0000-00000000A113")!,
            assistantMessageId: UUID(uuidString: "00000000-0000-0000-0000-00000000A114")!,
            signature: .sourceMaterialIgnored,
            repairKind: .promptSkill,
            status: .proposed,
            evidence: [FailureSkillEvidence(source: .contextManifest, id: "source-node-1", label: "source_material")],
            proposedSkillPayload: SkillPayload(
                payloadVersion: 1,
                name: "source-analysis-use-attached-material",
                description: "Force source-attached answers to quote the attached material.",
                useWhen: "Use when a turn has source material loaded.",
                source: .alex,
                trigger: SkillTrigger(kind: .always, modes: [], priority: 55),
                action: SkillAction(kind: .promptFragment, content: "When source material is attached, ground the answer in that source before giving general analysis."),
                rationale: "Prevents source-attached turns from drifting into generic advice.",
                antiPatternExamples: ["Answering from general memory while ignoring the attached source."]
            ),
            checklist: SkillifyChecklist(
                rootCause: "The assistant answered without using loaded source chunks.",
                trigger: "source material loaded",
                useWhen: "Use when source material is loaded into the prompt.",
                antiPatternExample: "Generic answer with no [S1] grounding.",
                regressionTestReference: "FailureToSkillDetectorTests.testSourceMaterialIgnoredCreatesPromptSkillCandidate",
                resolverTestReference: "SkillMatcherTests.testModeMatchFires",
                smokeTestCommand: "xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/FailureToSkillDetectorTests/testSourceMaterialIgnoredCreatesPromptSkillCandidate -only-testing:NousTests/SkillMatcherTests/testModeMatchFires -only-testing:NousTests/SkillifyChecklistEvaluatorTests",
                codeReference: nil
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            activatedSkillId: nil
        )
    }
}
