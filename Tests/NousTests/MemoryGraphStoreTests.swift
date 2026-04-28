import XCTest
@testable import Nous

final class MemoryGraphStoreTests: XCTestCase {

    var store: NodeStore!
    var graphStore: MemoryGraphStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
        graphStore = MemoryGraphStore(nodeStore: store)
    }

    override func tearDown() {
        graphStore = nil
        store = nil
        super.tearDown()
    }

    func testAtomEdgeObservationAndRecallEventRoundTrip() throws {
        let node = NousNode(
            type: .conversation,
            title: "Decision source",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        try store.insertNode(node)
        let message = Message(
            nodeId: node.id,
            role: .user,
            content: "I decided not to compete on price.",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        try store.insertMessage(message)

        let atom = MemoryAtom(
            type: .decision,
            statement: "Alex decided not to compete on price.",
            normalizedKey: "decision|compete_on_price",
            scope: .conversation,
            scopeRefId: node.id,
            confidence: 0.91,
            eventTime: Date(timeIntervalSince1970: 20),
            validFrom: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 31),
            lastSeenAt: Date(timeIntervalSince1970: 32),
            sourceNodeId: node.id,
            sourceMessageId: message.id,
            embedding: [0.1, 0.2, 0.3]
        )
        try graphStore.insertAtom(atom)

        XCTAssertEqual(try graphStore.atom(id: atom.id), atom)

        let reason = MemoryAtom(
            type: .reason,
            statement: "Competing on price weakens the product position.",
            scope: .conversation,
            scopeRefId: node.id,
            eventTime: Date(timeIntervalSince1970: 20),
            sourceNodeId: node.id,
            sourceMessageId: message.id
        )
        try graphStore.insertAtom(reason)

        let edge = MemoryEdge(
            fromAtomId: atom.id,
            toAtomId: reason.id,
            type: .because,
            weight: 0.95,
            createdAt: Date(timeIntervalSince1970: 33),
            sourceMessageId: message.id
        )
        try graphStore.insertEdge(edge)

        XCTAssertEqual(try graphStore.edges(from: atom.id), [edge])
        XCTAssertEqual(try graphStore.edges(to: reason.id), [edge])

        let observation = MemoryObservation(
            rawText: "I decided not to compete on price.",
            extractedType: .decision,
            confidence: 0.82,
            sourceNodeId: node.id,
            sourceMessageId: message.id,
            createdAt: Date(timeIntervalSince1970: 34)
        )
        try graphStore.insertObservation(observation)
        XCTAssertEqual(try graphStore.observations(), [observation])

        let recallEvent = MemoryRecallEvent(
            query: "What did I decide?",
            intent: "decision_lookup",
            timeWindowStart: Date(timeIntervalSince1970: 0),
            timeWindowEnd: Date(timeIntervalSince1970: 40),
            retrievedAtomIds: [atom.id, reason.id],
            answerSummary: "Alex decided not to compete on price.",
            createdAt: Date(timeIntervalSince1970: 35)
        )
        try graphStore.appendRecallEvent(recallEvent)
        XCTAssertEqual(try graphStore.recallEvents(limit: 5), [recallEvent])
    }

    func testDecisionChainTraversalReturnsRejectedPlanReasonAndReplacement() throws {
        let eventTime = Date(timeIntervalSince1970: 100)
        let proposal = MemoryAtom(
            type: .proposal,
            statement: "Solve emotions.",
            normalizedKey: "proposal|solve_emotions",
            scope: .conversation,
            scopeRefId: UUID(),
            eventTime: eventTime
        )
        let rejection = MemoryAtom(
            type: .rejection,
            statement: "Alex rejected the plan to solve emotions.",
            normalizedKey: "rejection|solve_emotions",
            scope: proposal.scope,
            scopeRefId: proposal.scopeRefId,
            eventTime: eventTime
        )
        let reason = MemoryAtom(
            type: .reason,
            statement: "Emotions cannot be solved like a mechanical problem.",
            scope: proposal.scope,
            scopeRefId: proposal.scopeRefId,
            eventTime: eventTime
        )
        let replacement = MemoryAtom(
            type: .currentPosition,
            statement: "Observe and coexist with emotions.",
            normalizedKey: "current_position|emotions",
            scope: proposal.scope,
            scopeRefId: proposal.scopeRefId,
            eventTime: eventTime
        )

        try [proposal, rejection, reason, replacement].forEach(graphStore.insertAtom)
        try graphStore.insertEdge(MemoryEdge(fromAtomId: rejection.id, toAtomId: proposal.id, type: .rejected))
        try graphStore.insertEdge(MemoryEdge(fromAtomId: rejection.id, toAtomId: reason.id, type: .because))
        try graphStore.insertEdge(MemoryEdge(fromAtomId: proposal.id, toAtomId: replacement.id, type: .replacedBy))

        let chain = try XCTUnwrap(graphStore.decisionChain(for: rejection.id))
        XCTAssertEqual(chain.rejection.id, rejection.id)
        XCTAssertEqual(chain.rejection.statement, rejection.statement)
        XCTAssertEqual(chain.rejectedProposal?.id, proposal.id)
        XCTAssertEqual(chain.reasons.map(\.id), [reason.id])
        XCTAssertEqual(chain.replacement?.id, replacement.id)
    }

    func testAtomQueryFiltersByTypeStatusScopeAndEventWindow() throws {
        let scopeId = UUID()
        let inWindow = MemoryAtom(
            type: .rejection,
            statement: "Rejected plan A.",
            scope: .conversation,
            scopeRefId: scopeId,
            status: .active,
            eventTime: Date(timeIntervalSince1970: 150)
        )
        let old = MemoryAtom(
            type: .rejection,
            statement: "Rejected older plan.",
            scope: .conversation,
            scopeRefId: scopeId,
            status: .active,
            eventTime: Date(timeIntervalSince1970: 50)
        )
        let wrongType = MemoryAtom(
            type: .reason,
            statement: "Reason in the same window.",
            scope: .conversation,
            scopeRefId: scopeId,
            status: .active,
            eventTime: Date(timeIntervalSince1970: 150)
        )
        let archived = MemoryAtom(
            type: .rejection,
            statement: "Archived rejection.",
            scope: .conversation,
            scopeRefId: scopeId,
            status: .archived,
            eventTime: Date(timeIntervalSince1970: 150)
        )

        try [inWindow, old, wrongType, archived].forEach(graphStore.insertAtom)

        let results = try graphStore.atoms(
            types: [.rejection],
            statuses: [.active],
            scope: .conversation,
            scopeRefId: scopeId,
            eventTimeStart: Date(timeIntervalSince1970: 100),
            eventTimeEnd: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(results.map(\.id), [inWindow.id])
        XCTAssertEqual(results.first?.statement, inWindow.statement)
    }

    /// When the live extractor produces a rejection of a proposal that Alex
    /// previously held as a `decision` or `currentPosition`, the prior atom
    /// must be marked `superseded` and a `supersedes` edge must be written
    /// from the new rejection to the old position. Without this, two
    /// contradictory atoms (old "want X" and new "no longer want X") would
    /// stay equally active in graph, producing the same fake-memory drift
    /// the audit flagged. This test pins the minimal cross-type supersede
    /// flow: matched on normalized statement within the same scope, no
    /// matter that the original key was `current_position|...` and the
    /// new candidate looks like `proposal|...`.
    func testWritingDecisionChainSupersedesPriorMatchingPosition() throws {
        let scopeId = UUID()
        let priorPosition = MemoryAtom(
            type: .currentPosition,
            statement: "Solve emotions",
            normalizedKey: "current_position|solve emotions",
            scope: .conversation,
            scopeRefId: scopeId,
            status: .active,
            eventTime: Date(timeIntervalSince1970: 100)
        )
        try graphStore.insertAtom(priorPosition)

        let writer = MemoryGraphWriter(nodeStore: store)
        var atoms = try store.fetchMemoryAtoms()
        var edges = try store.fetchMemoryEdges()
        var result = MemoryGraphWriteResult()
        let now = Date(timeIntervalSince1970: 200)

        try writer.writeDecisionChain(
            MemoryGraphDecisionChainInput(
                rejectedProposal: "Solve emotions",
                rejection: "Reject solving emotions",
                reasons: ["Emotions are not solvable"],
                replacement: "Observe and coexist",
                confidence: 0.9,
                scope: .conversation,
                scopeRefId: scopeId,
                eventTime: now,
                sourceNodeId: nil,
                sourceMessageId: nil,
                now: now
            ),
            atoms: &atoms,
            edges: &edges,
            result: &result
        )

        let updatedPrior = try XCTUnwrap(graphStore.atom(id: priorPosition.id))
        XCTAssertEqual(updatedPrior.status, .superseded, "Prior matching position must be marked superseded after a rejection.")

        let supersedesEdge = try XCTUnwrap(
            try store.fetchMemoryEdges().first { $0.type == .supersedes && $0.toAtomId == priorPosition.id },
            "A supersedes edge from the new rejection to the prior position must exist."
        )
        let fromAtom = try XCTUnwrap(store.fetchMemoryAtom(id: supersedesEdge.fromAtomId))
        XCTAssertEqual(fromAtom.type, .rejection)
    }

    /// Supersede must NOT fire when a matching atom is in a different scope —
    /// otherwise rejecting "Solve emotions" inside Conversation A would
    /// silently archive an unrelated `currentPosition` Alex set inside
    /// Conversation B. Cross-scope semantic resolution belongs to a
    /// dedicated promotion flow, not to a per-chain write.
    func testSupersedesOnlyFiresWithinSameScope() throws {
        let scopeA = UUID()
        let scopeB = UUID()
        let priorInOtherScope = MemoryAtom(
            type: .currentPosition,
            statement: "Solve emotions",
            normalizedKey: "current_position|solve emotions",
            scope: .conversation,
            scopeRefId: scopeB,
            status: .active,
            eventTime: Date(timeIntervalSince1970: 100)
        )
        try graphStore.insertAtom(priorInOtherScope)

        let writer = MemoryGraphWriter(nodeStore: store)
        var atoms = try store.fetchMemoryAtoms()
        var edges = try store.fetchMemoryEdges()
        var result = MemoryGraphWriteResult()
        let now = Date(timeIntervalSince1970: 200)

        try writer.writeDecisionChain(
            MemoryGraphDecisionChainInput(
                rejectedProposal: "Solve emotions",
                rejection: "Reject solving emotions",
                reasons: ["Different conversation"],
                replacement: nil,
                confidence: 0.9,
                scope: .conversation,
                scopeRefId: scopeA,
                eventTime: now,
                sourceNodeId: nil,
                sourceMessageId: nil,
                now: now
            ),
            atoms: &atoms,
            edges: &edges,
            result: &result
        )

        let untouched = try XCTUnwrap(graphStore.atom(id: priorInOtherScope.id))
        XCTAssertEqual(untouched.status, .active, "Atoms in another scope must not be superseded by a different chat.")

        let supersedesEdges = try store.fetchMemoryEdges().filter { $0.type == .supersedes }
        XCTAssertTrue(supersedesEdges.isEmpty, "No cross-scope supersedes edge should be written.")
    }

    /// Writer-level: a `correction` atom must be able to supersede a prior
    /// `belief` (or `preference`) atom in the same scope when a `corrects`
    /// target text matches the prior atom's normalized statement. Without
    /// this, "I no longer think X" coexists as just another active atom
    /// next to the prior X belief — same fake-memory drift the audit
    /// flagged at the decision-chain layer, now also closed for the
    /// preference / belief surface.
    func testCorrectionSupersedesPriorMatchingBeliefViaWriter() throws {
        let scopeId = UUID()
        let priorBelief = MemoryAtom(
            type: .belief,
            statement: "Wow-curve framing of onboarding holds up.",
            normalizedKey: "belief|wow-curve framing of onboarding holds up.",
            scope: .conversation,
            scopeRefId: scopeId,
            status: .active,
            eventTime: Date(timeIntervalSince1970: 100)
        )
        try graphStore.insertAtom(priorBelief)

        let writer = MemoryGraphWriter(nodeStore: store)
        var atoms = try store.fetchMemoryAtoms()
        var edges = try store.fetchMemoryEdges()
        var result = MemoryGraphWriteResult()
        let now = Date(timeIntervalSince1970: 200)

        let correction = MemoryAtom(
            type: .correction,
            statement: "Alex no longer trusts the wow-curve framing.",
            normalizedKey: "correction|alex no longer trusts the wow-curve framing.",
            scope: .conversation,
            scopeRefId: scopeId,
            status: .active,
            confidence: 0.85,
            eventTime: now,
            createdAt: now,
            updatedAt: now,
            lastSeenAt: now
        )
        let upserted = try writer.upsertAtom(correction, atoms: &atoms, result: &result)

        try writer.supersedeMatchingClaims(
            matching: "Wow-curve framing of onboarding holds up.",
            targetTypes: [.belief, .preference],
            superseder: upserted,
            confidence: 0.85,
            now: now,
            atoms: &atoms,
            edges: &edges,
            result: &result
        )

        let updatedPrior = try XCTUnwrap(graphStore.atom(id: priorBelief.id))
        XCTAssertEqual(updatedPrior.status, .superseded)

        let supersedesEdge = try XCTUnwrap(
            try store.fetchMemoryEdges().first {
                $0.type == .supersedes && $0.toAtomId == priorBelief.id
            },
            "A supersedes edge from the new correction to the prior belief must exist."
        )
        XCTAssertEqual(supersedesEdge.fromAtomId, upserted.id)
    }

    /// Cross-scope guard for correction supersede — symmetrical to the
    /// decision-chain guard. Beliefs Alex held in another conversation
    /// must not be silently retracted by a correction stated inside this
    /// conversation.
    func testCorrectionDoesNotSupersedeOtherScopeBeliefs() throws {
        let scopeA = UUID()
        let scopeB = UUID()
        let beliefInOtherScope = MemoryAtom(
            type: .belief,
            statement: "Wow-curve framing holds up.",
            normalizedKey: "belief|wow-curve framing holds up.",
            scope: .conversation,
            scopeRefId: scopeB,
            status: .active,
            eventTime: Date(timeIntervalSince1970: 100)
        )
        try graphStore.insertAtom(beliefInOtherScope)

        let writer = MemoryGraphWriter(nodeStore: store)
        var atoms = try store.fetchMemoryAtoms()
        var edges = try store.fetchMemoryEdges()
        var result = MemoryGraphWriteResult()
        let now = Date(timeIntervalSince1970: 200)

        let correction = MemoryAtom(
            type: .correction,
            statement: "Alex no longer trusts the wow-curve framing.",
            normalizedKey: "correction|alex no longer trusts the wow-curve framing.",
            scope: .conversation,
            scopeRefId: scopeA,
            status: .active,
            confidence: 0.85,
            eventTime: now,
            createdAt: now,
            updatedAt: now,
            lastSeenAt: now
        )
        let upserted = try writer.upsertAtom(correction, atoms: &atoms, result: &result)

        try writer.supersedeMatchingClaims(
            matching: "Wow-curve framing holds up.",
            targetTypes: [.belief, .preference],
            superseder: upserted,
            confidence: 0.85,
            now: now,
            atoms: &atoms,
            edges: &edges,
            result: &result
        )

        let untouched = try XCTUnwrap(graphStore.atom(id: beliefInOtherScope.id))
        XCTAssertEqual(untouched.status, .active)
        let supersedesEdges = try store.fetchMemoryEdges().filter { $0.type == .supersedes }
        XCTAssertTrue(supersedesEdges.isEmpty)
    }

    func testDeletingConversationNodeRemovesScopedAtomsAndEdges() throws {
        let node = NousNode(type: .conversation, title: "Delete me")
        try store.insertNode(node)

        let proposal = MemoryAtom(
            type: .proposal,
            statement: "Plan A",
            scope: .conversation,
            scopeRefId: node.id,
            sourceNodeId: node.id
        )
        let rejection = MemoryAtom(
            type: .rejection,
            statement: "Rejected Plan A",
            scope: .conversation,
            scopeRefId: node.id,
            sourceNodeId: node.id
        )
        try graphStore.insertAtom(proposal)
        try graphStore.insertAtom(rejection)
        try graphStore.insertEdge(MemoryEdge(fromAtomId: rejection.id, toAtomId: proposal.id, type: .rejected))

        try store.deleteNode(id: node.id)

        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty)
        XCTAssertTrue(try store.fetchMemoryEdges().isEmpty)
    }
}
