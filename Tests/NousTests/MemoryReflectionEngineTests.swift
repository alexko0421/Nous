import XCTest
@testable import Nous

final class MemoryReflectionEngineTests: XCTestCase {
    private var store: NodeStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testReflectionProposalStagesPendingInsightFromActiveSourcesOnly() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let activePreference = makeAtom(
            type: .preference,
            statement: "Alex keeps returning to explicit memory approval before recall.",
            status: .active,
            now: now,
            embedding: [1, 0, 0]
        )
        let activeRule = makeAtom(
            type: .rule,
            statement: "Memory architecture should expose why a memory was used.",
            status: .active,
            now: now,
            embedding: [0.9, 0.1, 0]
        )
        let pendingSource = makeAtom(
            type: .belief,
            statement: "A pending source must not support reflective memory yet.",
            status: .pending,
            now: now,
            embedding: [0, 1, 0]
        )
        try store.insertMemoryAtom(activePreference)
        try store.insertMemoryAtom(activeRule)
        try store.insertMemoryAtom(pendingSource)

        let result = try MemoryReflectionEngine(nodeStore: store).proposeReflection(
            insight: "Alex is shaping Nous memory around consent, provenance, and retrieval trust.",
            sourceAtomIds: [activePreference.id, pendingSource.id, activeRule.id],
            confidence: 0.82,
            now: now
        )

        let proposal = try XCTUnwrap(result)
        XCTAssertEqual(proposal.inboxItem.atom.type, .insight)
        XCTAssertEqual(proposal.inboxItem.atom.status, .pending)
        XCTAssertEqual(proposal.inboxItem.atom.scope, .selfReflection)
        XCTAssertEqual(proposal.inboxItem.temporalScope, .reflective)
        XCTAssertEqual(proposal.sourceAtomIds, [activePreference.id, activeRule.id])

        let reflectionInbox = try MemoryLifecycleEngine(nodeStore: store)
            .inbox()
            .filter { $0.atom.type == .insight }
        XCTAssertEqual(reflectionInbox.map(\.atom.id), [proposal.inboxItem.atom.id])

        let edges = try store.fetchMemoryEdges(fromAtomId: proposal.inboxItem.atom.id)
        XCTAssertEqual(Set(edges.map(\.toAtomId)), Set([activePreference.id, activeRule.id]))
        XCTAssertTrue(edges.allSatisfy { $0.type == .derivedFrom })
        XCTAssertFalse(edges.contains { $0.toAtomId == pendingSource.id })

        let recall = try MemoryLifecycleEngine(
            nodeStore: store,
            embed: reflectionEmbedding
        ).hybridRecall(
            currentMessage: "consent provenance retrieval trust",
            projectId: nil,
            conversationId: UUID(),
            queryEmbedding: [1, 0, 0],
            limit: 5,
            now: now
        )
        XCTAssertFalse(recall.contains { $0.atom.id == proposal.inboxItem.atom.id })
    }

    func testApproveReflectionMovesInsightIntoHybridRecall() throws {
        let now = Date(timeIntervalSince1970: 11_000)
        let sourceA = makeAtom(
            type: .preference,
            statement: "Alex prefers memory upgrades that keep user control visible.",
            status: .active,
            now: now,
            embedding: [1, 0]
        )
        let sourceB = makeAtom(
            type: .rule,
            statement: "Reflective memory should be earned from multiple approved memories.",
            status: .active,
            now: now,
            embedding: [0.8, 0.2]
        )
        try store.insertMemoryAtom(sourceA)
        try store.insertMemoryAtom(sourceB)

        let reflection = try XCTUnwrap(
            MemoryReflectionEngine(
                nodeStore: store,
                embed: reflectionEmbedding
            ).proposeReflection(
                insight: "Alex's memory architecture is converging on approved, explainable reflection.",
                sourceAtomIds: [sourceA.id, sourceB.id],
                confidence: 0.9,
                now: now
            )
        )

        let lifecycle = MemoryLifecycleEngine(
            nodeStore: store,
            embed: reflectionEmbedding
        )
        let approved = try XCTUnwrap(lifecycle.approve(reflection.inboxItem.atom.id, now: now.addingTimeInterval(60)))
        XCTAssertEqual(approved.status, .active)

        let recall = try lifecycle.hybridRecall(
            currentMessage: "approved explainable reflection",
            projectId: nil,
            conversationId: UUID(),
            queryEmbedding: [1, 0],
            limit: 5,
            now: now.addingTimeInterval(120)
        )

        XCTAssertEqual(recall.first?.atom.id, approved.id)
        XCTAssertTrue(recall.first?.reason.contains("graph=") == true)

        let plannerPacket = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "What did we say before about approved explainable reflection?",
            projectId: nil,
            conversationId: UUID(),
            queryEmbedding: [1, 0],
            now: now.addingTimeInterval(120)
        )
        XCTAssertTrue(plannerPacket.retrievedAtomIds.contains(approved.id))
    }

    func testReflectionProposalRequiresMultipleActiveSources() throws {
        let now = Date(timeIntervalSince1970: 12_000)
        let active = makeAtom(
            type: .preference,
            statement: "Alex prefers consentful memory.",
            status: .active,
            now: now,
            embedding: [1, 0]
        )
        let pending = makeAtom(
            type: .belief,
            statement: "Pending memory should not become reflection evidence.",
            status: .pending,
            now: now,
            embedding: [0, 1]
        )
        try store.insertMemoryAtom(active)
        try store.insertMemoryAtom(pending)

        let result = try MemoryReflectionEngine(nodeStore: store).proposeReflection(
            insight: "One active source is not enough for reflective memory.",
            sourceAtomIds: [active.id, pending.id],
            confidence: 0.8,
            now: now
        )

        XCTAssertNil(result)
        let reflectionInbox = try MemoryLifecycleEngine(nodeStore: store)
            .inbox()
            .filter { $0.atom.type == .insight }
        XCTAssertTrue(reflectionInbox.isEmpty)
        XCTAssertTrue(try store.fetchMemoryEdges().isEmpty)
    }

    func testAutomaticProposalSelectsActiveCurrentlyValidSourcesOnly() throws {
        let now = Date(timeIntervalSince1970: 13_000)
        let conversationId = UUID()
        let activePreference = makeAtom(
            type: .preference,
            statement: "Alex keeps asking for memory changes that preserve approval.",
            status: .active,
            now: now,
            embedding: [1, 0]
        )
        let activeRule = makeAtom(
            type: .rule,
            statement: "Nous memory should explain which evidence caused recall.",
            status: .active,
            now: now.addingTimeInterval(1),
            embedding: [0.9, 0.1]
        )
        let activeConversation = makeAtom(
            type: .belief,
            statement: "Reflection should summarize patterns across approved memory atoms.",
            status: .active,
            now: now.addingTimeInterval(2),
            embedding: [0.8, 0.2]
        )
        var pending = makeAtom(
            type: .belief,
            statement: "Pending memory must not become reflection evidence.",
            status: .pending,
            now: now.addingTimeInterval(3),
            embedding: [0, 1]
        )
        var expired = makeAtom(
            type: .goal,
            statement: "Expired memory must not become reflection evidence.",
            status: .active,
            now: now.addingTimeInterval(4),
            embedding: [0, 1]
        )
        var priorReflection = MemoryAtom(
            type: .insight,
            statement: "Existing reflections must not reflect on themselves.",
            scope: .selfReflection,
            status: .active,
            confidence: 0.9,
            eventTime: now,
            validUntil: nil,
            createdAt: now,
            updatedAt: now,
            embedding: [1, 0]
        )

        let scopedConversation = scoped(activeConversation, scope: .conversation, scopeRefId: conversationId)
        pending = scoped(pending, scope: .conversation, scopeRefId: conversationId)
        expired = scoped(expired, scope: .conversation, scopeRefId: conversationId)
        expired.validUntil = now
        priorReflection = scoped(priorReflection, scope: .selfReflection, scopeRefId: nil)

        try [activePreference, activeRule, scopedConversation, pending, expired, priorReflection]
            .forEach { try store.insertMemoryAtom($0) }

        let result = try MemoryReflectionEngine(
            nodeStore: store,
            synthesizeInsight: { sources in
                "Alex is repeatedly turning memory toward approval, evidence, and reflective trust from \(sources.count) sources."
            }
        ).proposeFromActiveMemory(
            projectId: nil,
            conversationId: conversationId,
            minimumSources: 3,
            now: now.addingTimeInterval(10)
        )

        let proposal = try XCTUnwrap(result)
        XCTAssertEqual(proposal.inboxItem.atom.type, .insight)
        XCTAssertEqual(proposal.inboxItem.atom.status, .pending)
        XCTAssertEqual(
            Set(proposal.sourceAtomIds),
            Set([activePreference.id, activeRule.id, scopedConversation.id])
        )
        XCTAssertFalse(proposal.sourceAtomIds.contains(pending.id))
        XCTAssertFalse(proposal.sourceAtomIds.contains(expired.id))
        XCTAssertFalse(proposal.sourceAtomIds.contains(priorReflection.id))
    }

    func testAutomaticProposalDedupesRepeatedRun() throws {
        let now = Date(timeIntervalSince1970: 14_000)
        let sources = [
            makeAtom(type: .preference, statement: "Alex wants approval before recall.", status: .active, now: now, embedding: [1, 0]),
            makeAtom(type: .rule, statement: "Memory proposals need evidence edges.", status: .active, now: now, embedding: [1, 0]),
            makeAtom(type: .preference, statement: "Nous should turn repeated thinking into reflection.", status: .active, now: now, embedding: [1, 0])
        ]
        try sources.forEach { try store.insertMemoryAtom($0) }

        let engine = MemoryReflectionEngine(
            nodeStore: store,
            synthesizeInsight: { _ in "Alex is converging on consentful reflective memory." }
        )
        let first = try XCTUnwrap(engine.proposeFromActiveMemory(
            projectId: nil,
            conversationId: nil,
            minimumSources: 3,
            now: now
        ))
        let second = try XCTUnwrap(engine.proposeFromActiveMemory(
            projectId: nil,
            conversationId: nil,
            minimumSources: 3,
            now: now.addingTimeInterval(60)
        ))

        XCTAssertEqual(first.inboxItem.atom.id, second.inboxItem.atom.id)
        let reflectionInbox = try MemoryLifecycleEngine(nodeStore: store)
            .inbox()
            .filter { $0.atom.type == .insight }
        XCTAssertEqual(reflectionInbox.count, 1)
        XCTAssertEqual(try store.fetchMemoryEdges(fromAtomId: first.inboxItem.atom.id).count, sources.count)
    }

    func testReflectionProposalKeepsSinglePendingProposalAcrossDifferentInsights() throws {
        let now = Date(timeIntervalSince1970: 14_500)
        let sources = [
            makeAtom(type: .preference, statement: "Alex wants memory approvals to be explicit.", status: .active, now: now, embedding: [1, 0]),
            makeAtom(type: .rule, statement: "Reflective memory should wait in Inbox.", status: .active, now: now, embedding: [1, 0]),
            makeAtom(type: .goal, statement: "Nous should turn repeated memory themes into one reviewable insight.", status: .active, now: now, embedding: [1, 0])
        ]
        try sources.forEach { try store.insertMemoryAtom($0) }
        let engine = MemoryReflectionEngine(nodeStore: store)

        let first = try XCTUnwrap(engine.proposeReflection(
            insight: "First pending reflection proposal.",
            sourceAtomIds: sources.map(\.id),
            confidence: 0.8,
            now: now
        ))
        let second = try XCTUnwrap(engine.proposeReflection(
            insight: "Second pending reflection proposal should not duplicate the Inbox.",
            sourceAtomIds: sources.map(\.id),
            confidence: 0.8,
            now: now.addingTimeInterval(10)
        ))

        XCTAssertEqual(first.inboxItem.atom.id, second.inboxItem.atom.id)
        let reflectionInbox = try MemoryLifecycleEngine(nodeStore: store)
            .inbox()
            .filter { $0.atom.type == .insight }
        XCTAssertEqual(reflectionInbox.count, 1)
        XCTAssertEqual(reflectionInbox.first?.atom.statement, "First pending reflection proposal.")
    }

    func testSummarizedAutomaticProposalUsesAsyncSummarizerAndStaysPending() async throws {
        let now = Date(timeIntervalSince1970: 15_000)
        let sources = [
            makeAtom(type: .preference, statement: "Alex wants memory approval before recall.", status: .active, now: now, embedding: [1, 0]),
            makeAtom(type: .rule, statement: "Nous memory should preserve source evidence.", status: .active, now: now.addingTimeInterval(1), embedding: [1, 0]),
            makeAtom(type: .preference, statement: "Alex is turning Nous into a reflective memory system.", status: .active, now: now.addingTimeInterval(2), embedding: [1, 0])
        ]
        try sources.forEach { try store.insertMemoryAtom($0) }
        var receivedSourceIds: [UUID] = []

        let result = try await MemoryReflectionEngine(nodeStore: store).proposeSummarizedFromActiveMemory(
            projectId: nil,
            conversationId: nil,
            minimumSources: 3,
            now: now.addingTimeInterval(10),
            summarizeInsight: { sources in
                receivedSourceIds = sources.map(\.id)
                return "Alex is converging on approval-gated reflective memory."
            }
        )

        let proposal = try XCTUnwrap(result)
        XCTAssertEqual(Set(receivedSourceIds), Set(sources.map(\.id)))
        XCTAssertEqual(proposal.inboxItem.atom.statement, "Alex is converging on approval-gated reflective memory.")
        XCTAssertEqual(proposal.inboxItem.atom.status, .pending)
        XCTAssertEqual(proposal.inboxItem.temporalScope, .reflective)

        let recall = try MemoryLifecycleEngine(nodeStore: store).hybridRecall(
            currentMessage: "approval reflective memory",
            projectId: nil,
            conversationId: UUID(),
            queryEmbedding: [1, 0],
            limit: 5,
            now: now.addingTimeInterval(20)
        )
        XCTAssertFalse(recall.contains { $0.atom.id == proposal.inboxItem.atom.id })
    }

    func testSummarizedAutomaticProposalFallsBackWhenSummarizerReturnsEmpty() async throws {
        let now = Date(timeIntervalSince1970: 16_000)
        let sources = [
            makeAtom(type: .preference, statement: "Alex wants reflection to stay consentful.", status: .active, now: now, embedding: [1, 0]),
            makeAtom(type: .rule, statement: "Reflection proposals should link back to memory sources.", status: .active, now: now.addingTimeInterval(1), embedding: [1, 0]),
            makeAtom(type: .preference, statement: "Nous should turn repeated memory themes into insight.", status: .active, now: now.addingTimeInterval(2), embedding: [1, 0])
        ]
        try sources.forEach { try store.insertMemoryAtom($0) }

        let result = try await MemoryReflectionEngine(
            nodeStore: store,
            synthesizeInsight: { _ in "Fallback reflection from approved memory." }
        ).proposeSummarizedFromActiveMemory(
            projectId: nil,
            conversationId: nil,
            minimumSources: 3,
            now: now.addingTimeInterval(10),
            summarizeInsight: { _ in "   " }
        )

        let proposal = try XCTUnwrap(result)
        XCTAssertEqual(proposal.inboxItem.atom.statement, "Fallback reflection from approved memory.")
        XCTAssertEqual(proposal.inboxItem.atom.status, .pending)
    }

    func testLLMSummarizerCollectsStreamedReflectionText() async throws {
        let now = Date(timeIntervalSince1970: 17_000)
        let sources = [
            makeAtom(type: .preference, statement: "Alex prefers memory proposals over silent memory writes.", status: .active, now: now, embedding: [1, 0]),
            makeAtom(type: .rule, statement: "Memory reflection must cite approved source atoms.", status: .active, now: now.addingTimeInterval(1), embedding: [1, 0]),
            makeAtom(type: .goal, statement: "Nous should make repeated thinking patterns visible.", status: .active, now: now.addingTimeInterval(2), embedding: [1, 0])
        ]
        let llm = StreamingReflectionLLMService(chunks: ["  Alex is ", "building approval-gated reflection.  "])

        let output = try await MemoryReflectionLLMSummarizer(llmService: llm).summarize(sources)

        XCTAssertEqual(output, "Alex is building approval-gated reflection.")
        XCTAssertTrue(llm.lastSystem?.contains("pending memory proposal") == true)
        XCTAssertTrue(llm.lastUserPrompt?.contains(sources[0].statement) == true)
    }

    func testRuntimeProposalServiceUsesLLMProviderAndKeepsReflectionPending() async throws {
        let now = Date(timeIntervalSince1970: 18_000)
        let sources = [
            makeAtom(type: .preference, statement: "Alex wants approved memory before recall.", status: .active, now: now, embedding: [1, 0]),
            makeAtom(type: .rule, statement: "Memory reflection should cite source atoms.", status: .active, now: now.addingTimeInterval(1), embedding: [1, 0]),
            makeAtom(type: .preference, statement: "Nous should turn repeated memory themes into insight.", status: .active, now: now.addingTimeInterval(2), embedding: [1, 0])
        ]
        try sources.forEach { try store.insertMemoryAtom($0) }
        let llm = StreamingReflectionLLMService(chunks: ["Runtime LLM reflection proposal."])

        let result = try await MemoryReflectionProposalService(
            nodeStore: store,
            llmServiceProvider: { llm }
        ).proposeFromApprovedMemory(
            projectId: nil,
            conversationId: nil,
            now: now.addingTimeInterval(10)
        )

        let proposal = try XCTUnwrap(result)
        XCTAssertEqual(proposal.inboxItem.atom.statement, "Runtime LLM reflection proposal.")
        XCTAssertEqual(proposal.inboxItem.atom.status, .pending)
        XCTAssertTrue(llm.lastUserPrompt?.contains(sources[0].statement) == true)

        let recall = try MemoryLifecycleEngine(nodeStore: store).hybridRecall(
            currentMessage: "Runtime LLM reflection proposal",
            projectId: nil,
            conversationId: UUID(),
            queryEmbedding: [1, 0],
            limit: 5,
            now: now.addingTimeInterval(20)
        )
        XCTAssertFalse(recall.contains { $0.atom.id == proposal.inboxItem.atom.id })
    }

    func testRuntimeApprovalPathUsesLLMReflectionInsteadOfDeterministicTrigger() async throws {
        let now = Date(timeIntervalSince1970: 19_000)
        let pendingSources = [
            makeAtom(type: .preference, statement: "Alex wants approval gates.", status: .pending, now: now, embedding: [1, 0]),
            makeAtom(type: .rule, statement: "Reflection proposals should be pending.", status: .pending, now: now.addingTimeInterval(1), embedding: [1, 0]),
            makeAtom(type: .preference, statement: "Nous should use a real summarizer when available.", status: .pending, now: now.addingTimeInterval(2), embedding: [1, 0])
        ]
        try pendingSources.forEach { try store.insertMemoryAtom($0) }
        let llm = StreamingReflectionLLMService(chunks: ["LLM-written runtime reflection."])
        let service = MemoryReflectionProposalService(
            nodeStore: store,
            llmServiceProvider: { llm },
            synthesizeInsight: { _ in "Deterministic fallback reflection." }
        )

        _ = try await service.approveAndPropose(pendingSources[0].id, now: now.addingTimeInterval(10))
        _ = try await service.approveAndPropose(pendingSources[1].id, now: now.addingTimeInterval(20))
        let result = try await service.approveAndPropose(pendingSources[2].id, now: now.addingTimeInterval(30))

        let proposal = try XCTUnwrap(result.reflectionProposal)
        XCTAssertEqual(proposal.inboxItem.atom.statement, "LLM-written runtime reflection.")
        XCTAssertEqual(try MemoryLifecycleEngine(nodeStore: store).inbox().filter { $0.atom.type == .insight }.count, 1)
    }

    private func makeAtom(
        type: MemoryAtomType,
        statement: String,
        status: MemoryStatus,
        now: Date,
        embedding: [Float]
    ) -> MemoryAtom {
        MemoryAtom(
            type: type,
            statement: statement,
            normalizedKey: MemoryGraphWriter.normalizedKey(type: type, statement: statement),
            scope: type == .rule || type == .preference ? .global : .conversation,
            scopeRefId: type == .rule || type == .preference ? nil : UUID(),
            status: status,
            confidence: 0.82,
            eventTime: now,
            createdAt: now,
            updatedAt: now,
            embedding: embedding
        )
    }

    private func scoped(_ atom: MemoryAtom, scope: MemoryScope, scopeRefId: UUID?) -> MemoryAtom {
        var copy = atom
        copy.scope = scope
        copy.scopeRefId = scopeRefId
        return copy
    }

    private func reflectionEmbedding(_ text: String) -> [Float]? {
        text.lowercased().contains("reflection") ? [1, 0] : [0.1, 0.9]
    }
}

private final class StreamingReflectionLLMService: LLMService {
    let chunks: [String]
    private(set) var lastSystem: String?
    private(set) var lastUserPrompt: String?

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        lastSystem = system
        lastUserPrompt = messages.first?.content
        let chunks = chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
