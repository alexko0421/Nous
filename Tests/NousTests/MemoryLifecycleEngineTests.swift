import XCTest
@testable import Nous

final class MemoryLifecycleEngineTests: XCTestCase {
    private var store: NodeStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testStableUserStatementStagesPendingMemoryOutsideActiveRecall() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let conversation = NousNode(type: .conversation, title: "Memory inbox")
        try store.insertNode(conversation)
        let message = Message(
            nodeId: conversation.id,
            role: .user,
            content: "Remember that I prefer direct memory plans with concrete next steps.",
            timestamp: now
        )
        try store.insertMessage(message)

        let engine = MemoryLifecycleEngine(
            nodeStore: store,
            embed: { text in text.contains("direct memory plans") ? [1, 0, 0] : nil }
        )

        let result = try engine.stageFromUserText(
            message.content,
            projectId: nil,
            conversationId: conversation.id,
            sourceNodeId: conversation.id,
            sourceMessageId: message.id,
            now: now
        )

        guard case let .staged(item) = result else {
            return XCTFail("Expected stable memory to be staged into inbox.")
        }
        XCTAssertEqual(item.atom.status, .pending)
        XCTAssertEqual(item.temporalScope, .semantic)
        XCTAssertEqual(item.atom.sourceMessageId, message.id)
        XCTAssertEqual(item.reason, "stable enough for memory refresh")

        XCTAssertEqual(try engine.inbox().map(\.atom.id), [item.atom.id])

        let activePacket = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "Working through direct memory plan wording",
            projectId: nil,
            conversationId: conversation.id,
            queryEmbedding: [1, 0, 0],
            now: now
        )
        XCTAssertTrue(activePacket.items.isEmpty)
        XCTAssertTrue(activePacket.retrievedAtomIds.isEmpty)
    }

    func testHardOptOutDoesNotStagePendingMemory() throws {
        let engine = MemoryLifecycleEngine(nodeStore: store)

        let result = try engine.stageFromUserText(
            "Don't remember this: I prefer hiding memory evidence.",
            projectId: nil,
            conversationId: UUID(),
            sourceNodeId: nil,
            sourceMessageId: nil,
            now: Date()
        )

        XCTAssertEqual(result, .suppressed(reason: .hardOptOut, curatorReason: "hard opt-out"))
        XCTAssertTrue(try engine.inbox().isEmpty)
    }

    func testApproveMovesPendingMemoryIntoHybridRecallWithReason() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let conversation = NousNode(type: .conversation, title: "Hybrid recall")
        try store.insertNode(conversation)
        let message = Message(
            nodeId: conversation.id,
            role: .user,
            content: "Remember that I prefer memory retrieval to explain why a memory was used.",
            timestamp: now
        )
        try store.insertMessage(message)

        let engine = MemoryLifecycleEngine(
            nodeStore: store,
            embed: { text in
                text.contains("explain why") ? [1, 0] : [0, 1]
            }
        )
        let result = try engine.stageFromUserText(
            message.content,
            projectId: nil,
            conversationId: conversation.id,
            sourceNodeId: conversation.id,
            sourceMessageId: message.id,
            now: now
        )
        guard case let .staged(item) = result else {
            return XCTFail("Expected pending memory proposal.")
        }

        let active = try XCTUnwrap(engine.approve(item.atom.id, now: now.addingTimeInterval(60)))
        XCTAssertEqual(active.status, .active)

        let results = try engine.hybridRecall(
            currentMessage: "Why did this memory get used?",
            projectId: nil,
            conversationId: conversation.id,
            queryEmbedding: [1, 0],
            limit: 3,
            now: now.addingTimeInterval(120)
        )

        XCTAssertEqual(results.first?.atom.id, active.id)
        XCTAssertTrue(results.first?.reason.contains("semantic=") == true)
        XCTAssertTrue(results.first?.reason.contains("graph=") == true)
        XCTAssertTrue(results.first?.reason.contains("recency=") == true)
        XCTAssertTrue(results.first?.reason.contains("importance=") == true)
        XCTAssertTrue(results.first?.reason.contains("interaction=") == true)
        XCTAssertTrue(results.first?.reason.contains("source_message_id=\(message.id.uuidString)") == true)
    }

    func testApproveThirdReflectionSourceStagesAutomaticReflectionInboxItem() throws {
        let now = Date(timeIntervalSince1970: 2_200)
        let sources = [
            makeLifecycleAtom(
                type: .preference,
                statement: "Alex wants memory approval before recall.",
                status: .pending,
                now: now
            ),
            makeLifecycleAtom(
                type: .rule,
                statement: "Nous memory should show evidence edges.",
                status: .pending,
                now: now.addingTimeInterval(1)
            ),
            makeLifecycleAtom(
                type: .goal,
                statement: "Alex is upgrading Nous toward reflective memory.",
                status: .pending,
                now: now.addingTimeInterval(2)
            )
        ]
        let engine = MemoryLifecycleEngine(
            nodeStore: store,
            reflectionSynthesizeInsight: { sources in
                "Automatic reflection from \(sources.count) approved memory atoms."
            }
        )
        for source in sources {
            _ = try engine.stageAtomProposal(source, now: source.createdAt)
        }

        _ = try engine.approve(sources[0].id, now: now.addingTimeInterval(10))
        _ = try engine.approve(sources[1].id, now: now.addingTimeInterval(20))
        XCTAssertTrue(try engine.inbox().filter { $0.atom.type == .insight }.isEmpty)

        _ = try engine.approve(sources[2].id, now: now.addingTimeInterval(30))

        let reflectionInbox = try engine.inbox().filter { $0.atom.type == .insight }
        XCTAssertEqual(reflectionInbox.count, 1)
        let reflection = try XCTUnwrap(reflectionInbox.first?.atom)
        XCTAssertEqual(reflection.status, .pending)
        XCTAssertEqual(reflection.scope, .selfReflection)
        XCTAssertEqual(reflection.statement, "Automatic reflection from 3 approved memory atoms.")
        XCTAssertEqual(
            Set(try store.fetchMemoryEdges(fromAtomId: reflection.id).map(\.toAtomId)),
            Set(sources.map(\.id))
        )
    }

    func testAutomaticReflectionTriggerDoesNotCreateSecondPendingReflection() throws {
        let now = Date(timeIntervalSince1970: 2_300)
        let engine = MemoryLifecycleEngine(
            nodeStore: store,
            reflectionSynthesizeInsight: { sources in
                "Automatic reflection candidate from \(sources.count) sources."
            }
        )
        let sources = [
            makeLifecycleAtom(type: .preference, statement: "Alex wants consentful recall.", status: .pending, now: now),
            makeLifecycleAtom(type: .rule, statement: "Reflection should cite source memory.", status: .pending, now: now.addingTimeInterval(1)),
            makeLifecycleAtom(type: .goal, statement: "Nous should surface durable thinking patterns.", status: .pending, now: now.addingTimeInterval(2)),
            makeLifecycleAtom(type: .belief, statement: "Automatic reflection can help Alex see repeated themes.", status: .pending, now: now.addingTimeInterval(3))
        ]
        for source in sources {
            _ = try engine.stageAtomProposal(source, now: source.createdAt)
            _ = try engine.approve(source.id, now: source.createdAt.addingTimeInterval(60))
        }

        let reflectionInbox = try engine.inbox().filter { $0.atom.type == .insight }
        XCTAssertEqual(reflectionInbox.count, 1)
    }

    func testRepeatedPendingProposalUpdatesExistingInboxItemInsteadOfDuplicating() throws {
        let now = Date(timeIntervalSince1970: 2_500)
        let conversation = NousNode(type: .conversation, title: "Pending dedupe")
        try store.insertNode(conversation)
        let firstMessage = Message(
            nodeId: conversation.id,
            role: .user,
            content: "Remember that I prefer memory inbox proposals to stay explicit.",
            timestamp: now
        )
        let secondMessage = Message(
            nodeId: conversation.id,
            role: .user,
            content: "Remember that I prefer memory inbox proposals to stay explicit.",
            timestamp: now.addingTimeInterval(30)
        )
        try store.insertMessage(firstMessage)
        try store.insertMessage(secondMessage)
        let engine = MemoryLifecycleEngine(nodeStore: store)

        let first = try engine.stageFromUserText(
            firstMessage.content,
            projectId: nil,
            conversationId: conversation.id,
            sourceNodeId: conversation.id,
            sourceMessageId: firstMessage.id,
            now: now
        )
        let second = try engine.stageFromUserText(
            secondMessage.content,
            projectId: nil,
            conversationId: conversation.id,
            sourceNodeId: conversation.id,
            sourceMessageId: secondMessage.id,
            now: now.addingTimeInterval(30)
        )

        guard case let .staged(firstItem) = first,
              case let .staged(secondItem) = second else {
            return XCTFail("Expected both proposals to stage.")
        }
        XCTAssertEqual(firstItem.atom.id, secondItem.atom.id)
        XCTAssertEqual(try engine.inbox().count, 1)

        let updated = try XCTUnwrap(store.fetchMemoryAtom(id: firstItem.atom.id))
        XCTAssertEqual(updated.status, .pending)
        XCTAssertEqual(updated.updatedAt, now.addingTimeInterval(30))
    }

    func testRepeatedProposalForActiveMemoryRefreshesWithoutDowngradingToPending() throws {
        let now = Date(timeIntervalSince1970: 2_800)
        let conversation = NousNode(type: .conversation, title: "Active refresh")
        try store.insertNode(conversation)
        let message = Message(
            nodeId: conversation.id,
            role: .user,
            content: "Remember that I prefer memory approval before recall.",
            timestamp: now
        )
        try store.insertMessage(message)
        let engine = MemoryLifecycleEngine(nodeStore: store)
        let staged = try engine.stageFromUserText(
            message.content,
            projectId: nil,
            conversationId: conversation.id,
            sourceNodeId: conversation.id,
            sourceMessageId: message.id,
            now: now
        )
        guard case let .staged(item) = staged else {
            return XCTFail("Expected proposal to stage.")
        }
        _ = try engine.approve(item.atom.id, now: now.addingTimeInterval(10))

        let repeated = try engine.stageFromUserText(
            message.content,
            projectId: nil,
            conversationId: conversation.id,
            sourceNodeId: conversation.id,
            sourceMessageId: message.id,
            now: now.addingTimeInterval(20)
        )

        guard case let .staged(repeatedItem) = repeated else {
            return XCTFail("Expected repeated active proposal to refresh the existing atom.")
        }
        XCTAssertEqual(repeatedItem.atom.id, item.atom.id)
        XCTAssertEqual(repeatedItem.atom.status, .active)
        XCTAssertTrue(try engine.inbox().isEmpty)
    }

    func testRejectedPendingProposalDoesNotRestageIntoInbox() throws {
        let now = Date(timeIntervalSince1970: 2_900)
        let conversation = NousNode(type: .conversation, title: "Rejected memory")
        try store.insertNode(conversation)
        let engine = MemoryLifecycleEngine(nodeStore: store)
        let text = "Remember that I prefer memory proposals to stay explicit before recall."

        let staged = try engine.stageFromUserText(
            text,
            projectId: nil,
            conversationId: conversation.id,
            sourceNodeId: conversation.id,
            sourceMessageId: nil,
            now: now
        )
        guard case let .staged(item) = staged else {
            return XCTFail("Expected first proposal to stage.")
        }
        _ = try engine.reject(item.atom.id, now: now.addingTimeInterval(10))
        XCTAssertTrue(try engine.inbox().isEmpty)

        let repeated = try engine.stageFromUserText(
            text,
            projectId: nil,
            conversationId: conversation.id,
            sourceNodeId: conversation.id,
            sourceMessageId: nil,
            now: now.addingTimeInterval(20)
        )

        XCTAssertEqual(
            repeated,
            .suppressed(reason: .unspecified, curatorReason: "matching memory proposal was rejected")
        )
        XCTAssertTrue(try engine.inbox().isEmpty)
        let atoms = try store.fetchMemoryAtoms()
        XCTAssertEqual(atoms.count, 1)
        XCTAssertEqual(atoms.first?.status, .archived)
    }

    func testApproveFactDerivedAtomActivatesMirroredFactEntry() throws {
        let now = Date(timeIntervalSince1970: 2_910)
        let conversation = NousNode(type: .conversation, title: "Fact mirror approval")
        try store.insertNode(conversation)
        let (fact, atom) = try insertPendingFactDerivedAtom(
            conversationId: conversation.id,
            content: "Alex treats explicit memory approval as a product boundary.",
            now: now
        )

        let approved = try XCTUnwrap(
            MemoryLifecycleEngine(nodeStore: store).approve(atom.id, now: now.addingTimeInterval(10))
        )

        XCTAssertEqual(approved.status, .active)
        XCTAssertEqual(try store.fetchMemoryAtom(id: atom.id)?.status, .active)
        XCTAssertEqual(try store.fetchMemoryFactEntry(id: fact.id)?.status, .active)
        XCTAssertEqual(try store.fetchMemoryFactEntry(id: fact.id)?.updatedAt, now.addingTimeInterval(10))
    }

    func testRejectFactDerivedAtomArchivesMirroredFactEntry() throws {
        let now = Date(timeIntervalSince1970: 2_920)
        let conversation = NousNode(type: .conversation, title: "Fact mirror rejection")
        try store.insertNode(conversation)
        let (fact, atom) = try insertPendingFactDerivedAtom(
            conversationId: conversation.id,
            content: "Alex treats Inbox rejection as a durable memory boundary.",
            now: now
        )

        let rejected = try XCTUnwrap(
            MemoryLifecycleEngine(nodeStore: store).reject(atom.id, now: now.addingTimeInterval(10))
        )

        XCTAssertEqual(rejected.status, .archived)
        XCTAssertEqual(try store.fetchMemoryAtom(id: atom.id)?.status, .archived)
        XCTAssertEqual(try store.fetchMemoryFactEntry(id: fact.id)?.status, .archived)
        XCTAssertEqual(try store.fetchMemoryFactEntry(id: fact.id)?.updatedAt, now.addingTimeInterval(10))
    }

    func testForgetFactDerivedAtomDeletesMirroredFactEntry() throws {
        let now = Date(timeIntervalSince1970: 2_930)
        let conversation = NousNode(type: .conversation, title: "Fact mirror forget")
        try store.insertNode(conversation)
        let (fact, atom) = try insertPendingFactDerivedAtom(
            conversationId: conversation.id,
            content: "Alex wants forgotten pending memory removed from both memory stores.",
            now: now
        )
        let linkedAtom = MemoryAtom(
            type: .rule,
            statement: "Forgotten memory should not leave evidence edges behind.",
            scope: .conversation,
            scopeRefId: conversation.id,
            status: .active,
            confidence: 0.8,
            createdAt: now,
            updatedAt: now
        )
        try store.insertMemoryAtom(linkedAtom)
        try store.insertMemoryEdge(MemoryEdge(
            fromAtomId: atom.id,
            toAtomId: linkedAtom.id,
            type: .derivedFrom,
            weight: 0.8,
            createdAt: now
        ))
        XCTAssertFalse(try store.fetchMemoryEdges(fromAtomId: atom.id).isEmpty)

        XCTAssertTrue(try MemoryLifecycleEngine(nodeStore: store).forget(atom.id))

        XCTAssertNil(try store.fetchMemoryAtom(id: atom.id))
        XCTAssertNil(try store.fetchMemoryFactEntry(id: fact.id))
        XCTAssertTrue(try store.fetchMemoryEdges(fromAtomId: atom.id).isEmpty)
    }

    func testApprovePendingCorrectionSupersedesMatchingActiveClaim() throws {
        let now = Date(timeIntervalSince1970: 2_950)
        let conversation = NousNode(type: .conversation, title: "Correction approval")
        try store.insertNode(conversation)
        let priorBelief = MemoryAtom(
            type: .belief,
            statement: "Wow-curve framing of onboarding holds up.",
            normalizedKey: "belief|wow-curve framing of onboarding holds up.",
            scope: .conversation,
            scopeRefId: conversation.id,
            status: .active,
            confidence: 0.82,
            eventTime: now.addingTimeInterval(-600),
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now.addingTimeInterval(-600),
            lastSeenAt: now.addingTimeInterval(-600),
            sourceNodeId: conversation.id
        )
        try store.insertMemoryAtom(priorBelief)

        let engine = MemoryLifecycleEngine(nodeStore: store)
        let pendingCorrection = try engine.stageAtomProposal(MemoryAtom(
            type: .correction,
            statement: "Alex no longer trusts the wow-curve framing of onboarding.",
            normalizedKey: "correction|alex no longer trusts the wow-curve framing of onboarding.",
            scope: .conversation,
            scopeRefId: conversation.id,
            status: .pending,
            confidence: 0.9,
            eventTime: now,
            createdAt: now,
            updatedAt: now,
            sourceNodeId: conversation.id,
            correctsTarget: "Wow-curve framing of onboarding holds up."
        ), now: now)

        XCTAssertEqual(pendingCorrection.status, .pending)
        XCTAssertEqual(try store.fetchMemoryAtom(id: priorBelief.id)?.status, .active)
        XCTAssertTrue(try store.fetchMemoryEdges().filter { $0.type == .supersedes }.isEmpty)

        let approved = try XCTUnwrap(engine.approve(pendingCorrection.id, now: now.addingTimeInterval(60)))

        XCTAssertEqual(approved.status, .active)
        XCTAssertEqual(approved.correctsTarget, "Wow-curve framing of onboarding holds up.")
        XCTAssertEqual(try store.fetchMemoryAtom(id: priorBelief.id)?.status, .superseded)
        let supersedesEdge = try XCTUnwrap(
            try store.fetchMemoryEdges().first {
                $0.type == .supersedes &&
                $0.fromAtomId == pendingCorrection.id &&
                $0.toAtomId == priorBelief.id
            }
        )
        XCTAssertEqual(supersedesEdge.weight, 0.9)
    }

    func testRejectPendingCorrectionLeavesMatchingActiveClaimUntouched() throws {
        let now = Date(timeIntervalSince1970: 2_960)
        let conversation = NousNode(type: .conversation, title: "Correction rejection")
        try store.insertNode(conversation)
        let priorBelief = MemoryAtom(
            type: .belief,
            statement: "Galaxy graph should stay visual-only.",
            normalizedKey: "belief|galaxy graph should stay visual-only.",
            scope: .conversation,
            scopeRefId: conversation.id,
            status: .active,
            confidence: 0.8,
            eventTime: now.addingTimeInterval(-600),
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now.addingTimeInterval(-600),
            sourceNodeId: conversation.id
        )
        try store.insertMemoryAtom(priorBelief)

        let engine = MemoryLifecycleEngine(nodeStore: store)
        let pendingCorrection = try engine.stageAtomProposal(MemoryAtom(
            type: .correction,
            statement: "Alex now wants Galaxy graph to drive retrieval.",
            normalizedKey: "correction|alex now wants galaxy graph to drive retrieval.",
            scope: .conversation,
            scopeRefId: conversation.id,
            status: .pending,
            confidence: 0.88,
            eventTime: now,
            createdAt: now,
            updatedAt: now,
            sourceNodeId: conversation.id,
            correctsTarget: "Galaxy graph should stay visual-only."
        ), now: now)

        _ = try engine.reject(pendingCorrection.id, now: now.addingTimeInterval(60))

        XCTAssertEqual(try store.fetchMemoryAtom(id: priorBelief.id)?.status, .active)
        XCTAssertEqual(try store.fetchMemoryAtom(id: pendingCorrection.id)?.status, .archived)
        XCTAssertTrue(try store.fetchMemoryEdges().filter { $0.type == .supersedes }.isEmpty)
    }

    func testApprovePendingDecisionChainApprovesWholeChainAndSupersedesPriorPosition() throws {
        let now = Date(timeIntervalSince1970: 2_970)
        let conversation = NousNode(type: .conversation, title: "Decision approval")
        try store.insertNode(conversation)
        let priorPosition = MemoryAtom(
            type: .currentPosition,
            statement: "Solve emotions",
            normalizedKey: "current_position|solve emotions",
            scope: .conversation,
            scopeRefId: conversation.id,
            status: .active,
            confidence: 0.8,
            eventTime: now.addingTimeInterval(-600),
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now.addingTimeInterval(-600),
            lastSeenAt: now.addingTimeInterval(-600),
            sourceNodeId: conversation.id
        )
        try store.insertMemoryAtom(priorPosition)

        let writer = MemoryGraphWriter(nodeStore: store)
        var atoms = try store.fetchMemoryAtoms()
        var edges = try store.fetchMemoryEdges()
        var writeResult = MemoryGraphWriteResult()
        try writer.writeDecisionChain(
            MemoryGraphDecisionChainInput(
                rejectedProposal: "Solve emotions",
                rejection: "Alex rejects solving emotions as a product frame.",
                reasons: ["Emotions are not solvable like a mechanical problem."],
                replacement: "Observe and coexist with emotions.",
                confidence: 0.91,
                scope: .conversation,
                scopeRefId: conversation.id,
                status: .pending,
                eventTime: now,
                sourceNodeId: conversation.id,
                sourceMessageId: nil,
                now: now
            ),
            atoms: &atoms,
            edges: &edges,
            result: &writeResult
        )

        let pendingAtoms = try store.fetchMemoryAtoms()
            .filter { $0.scope == .conversation && $0.scopeRefId == conversation.id && $0.status == .pending }
        let rejection = try XCTUnwrap(pendingAtoms.first { $0.type == .rejection })
        XCTAssertTrue(pendingAtoms.contains { $0.type == .proposal })
        XCTAssertTrue(pendingAtoms.contains { $0.type == .reason })
        XCTAssertTrue(pendingAtoms.contains { $0.type == .currentPosition })

        _ = try MemoryLifecycleEngine(nodeStore: store).approve(
            rejection.id,
            now: now.addingTimeInterval(60)
        )

        let chainAtoms = try store.fetchMemoryAtoms()
            .filter {
                $0.scope == .conversation &&
                $0.scopeRefId == conversation.id &&
                [.proposal, .rejection, .reason, .currentPosition].contains($0.type) &&
                $0.id != priorPosition.id
            }
        XCTAssertEqual(Set(chainAtoms.map(\.status)), [.active])
        XCTAssertEqual(try store.fetchMemoryAtom(id: priorPosition.id)?.status, .superseded)
        XCTAssertTrue(
            try store.fetchMemoryEdges().contains {
                $0.type == .supersedes &&
                $0.fromAtomId == rejection.id &&
                $0.toAtomId == priorPosition.id
            }
        )
    }

    func testHybridRecallUsesGraphNeighborSignal() throws {
        let now = Date(timeIntervalSince1970: 3_000)
        let seed = MemoryAtom(
            type: .preference,
            statement: "Alex prefers retrieval evidence in memory answers.",
            scope: .global,
            status: .active,
            confidence: 0.8,
            createdAt: now,
            updatedAt: now,
            embedding: [1, 0]
        )
        let neighbor = MemoryAtom(
            type: .rule,
            statement: "Memory answers should cite source messages.",
            scope: .global,
            status: .active,
            confidence: 0.8,
            createdAt: now,
            updatedAt: now,
            embedding: [0.35, 0.65]
        )
        let unlinked = MemoryAtom(
            type: .rule,
            statement: "Memory answers should stay short.",
            scope: .global,
            status: .active,
            confidence: 0.8,
            createdAt: now,
            updatedAt: now,
            embedding: [0.35, 0.65]
        )
        try store.insertMemoryAtom(seed)
        try store.insertMemoryAtom(neighbor)
        try store.insertMemoryAtom(unlinked)
        try store.insertMemoryEdge(MemoryEdge(
            fromAtomId: seed.id,
            toAtomId: neighbor.id,
            type: .supports,
            weight: 1.0,
            createdAt: now
        ))

        let results = try MemoryLifecycleEngine(nodeStore: store).hybridRecall(
            currentMessage: "retrieval evidence",
            projectId: nil,
            conversationId: UUID(),
            queryEmbedding: [1, 0],
            limit: 3,
            now: now
        )

        let neighborIndex = try XCTUnwrap(results.firstIndex { $0.atom.id == neighbor.id })
        let unlinkedIndex = try XCTUnwrap(results.firstIndex { $0.atom.id == unlinked.id })
        XCTAssertLessThan(neighborIndex, unlinkedIndex)
        XCTAssertTrue(results[neighborIndex].reason.contains("graph=1.00"))
    }

    private func makeLifecycleAtom(
        type: MemoryAtomType,
        statement: String,
        status: MemoryStatus,
        now: Date
    ) -> MemoryAtom {
        MemoryAtom(
            type: type,
            statement: statement,
            normalizedKey: MemoryGraphWriter.normalizedKey(type: type, statement: statement),
            scope: .global,
            status: status,
            confidence: 0.84,
            eventTime: now,
            createdAt: now,
            updatedAt: now
        )
    }

    private func insertPendingFactDerivedAtom(
        conversationId: UUID,
        content: String,
        now: Date
    ) throws -> (MemoryFactEntry, MemoryAtom) {
        let fact = MemoryFactEntry(
            scope: .conversation,
            scopeRefId: conversationId,
            kind: .boundary,
            content: content,
            confidence: 0.84,
            status: .pending,
            stability: .stable,
            sourceNodeIds: [conversationId],
            createdAt: now,
            updatedAt: now
        )
        try store.insertMemoryFactEntry(fact)
        let atom = try XCTUnwrap(MemoryGraphAtomMapper.atom(fromFact: fact, now: now))
        try store.insertMemoryAtom(atom)
        return (fact, atom)
    }
}
