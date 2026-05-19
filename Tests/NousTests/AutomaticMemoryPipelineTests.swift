import XCTest
@testable import Nous

final class AutomaticMemoryPipelineTests: XCTestCase {
    private var store: NodeStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testAutomaticDigestWritesTentativeActiveAtomWithSourceEvidence() async throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let fixture = try makeAutomaticFixture(
            userText: "I prefer automatic memory if it keeps source evidence visible.",
            assistantText: "Then we should make automation source-grounded.",
            now: now
        )
        let service = AutomaticMemoryPipelineService(
            nodeStore: store,
            llmServiceProvider: {
                StaticAutomaticMemoryLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "preference",
                      "statement": "Alex prefers automatic memory when source evidence stays visible.",
                      "scope": "global",
                      "confidence": 0.82,
                      "evidence_quote": "I prefer automatic memory if it keeps source evidence visible."
                    }
                  ]
                }
                """)
            },
            now: { now }
        )

        let result = await service.process(fixture.request)

        XCTAssertEqual(result.insertedCount, 1)
        XCTAssertEqual(result.rejectedCount, 0)
        let atom = try XCTUnwrap(try store.fetchMemoryAtoms().first)
        XCTAssertEqual(atom.status, .active)
        XCTAssertEqual(atom.authority, .tentative)
        XCTAssertEqual(atom.type, .preference)
        XCTAssertEqual(atom.scope, .global)
        XCTAssertEqual(atom.sourceNodeId, fixture.conversation.id)
        XCTAssertEqual(atom.sourceMessageId, fixture.userMessage.id)
        XCTAssertEqual(atom.evidenceQuote, "I prefer automatic memory if it keeps source evidence visible.")
        XCTAssertTrue(atom.captureReason?.contains("automatic memory digest") == true)

        let recall = try MemoryLifecycleEngine(nodeStore: store).hybridRecall(
            currentMessage: "automatic memory source evidence",
            projectId: nil,
            conversationId: fixture.conversation.id,
            limit: 3,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(recall.first?.atom.id, atom.id)
        XCTAssertTrue(recall.first?.reason.contains("authority=tentative") == true)
    }

    func testAutomaticDigestAcceptsFencedJSONFromLiveModel() async throws {
        let now = Date(timeIntervalSince1970: 20_500)
        let fixture = try makeAutomaticFixture(
            userText: "I prefer dogfood memory checks to use short replies without over-explaining.",
            assistantText: "Got it, short replies.",
            now: now
        )
        let service = AutomaticMemoryPipelineService(
            nodeStore: store,
            llmServiceProvider: {
                StaticAutomaticMemoryLLM(output: """
                Sure. Here is the JSON:
                ```json
                {
                  "candidates": [
                    {
                      "type": "preference",
                      "statement": "Alex prefers dogfood memory checks to use short replies without over-explaining.",
                      "scope": "global",
                      "confidence": 0.82,
                      "evidence_quote": "I prefer dogfood memory checks to use short replies without over-explaining."
                    }
                  ]
                }
                ```
                """)
            },
            now: { now }
        )

        let result = await service.process(fixture.request)

        XCTAssertEqual(result.insertedCount, 1)
        XCTAssertEqual(result.rejectedCount, 0)
        let atom = try XCTUnwrap(try store.fetchMemoryAtoms().first)
        XCTAssertEqual(atom.status, .active)
        XCTAssertEqual(atom.authority, .tentative)
        XCTAssertEqual(atom.sourceMessageId, fixture.userMessage.id)
    }

    func testAutomaticDigestKeepsLowConfidenceAndReflectiveCandidatesPending() async throws {
        let now = Date(timeIntervalSince1970: 20_700)
        let fixture = try makeAutomaticFixture(
            userText: "I prefer automatic memory, and I think this pattern may matter for my project.",
            assistantText: "We can keep low-confidence or reflective claims reviewable.",
            now: now
        )
        let service = AutomaticMemoryPipelineService(
            nodeStore: store,
            llmServiceProvider: {
                StaticAutomaticMemoryLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "preference",
                      "statement": "Alex prefers automatic memory.",
                      "scope": "global",
                      "confidence": 0.64,
                      "evidence_quote": "I prefer automatic memory"
                    },
                    {
                      "type": "insight",
                      "statement": "Alex may have a recurring project pattern around automatic memory.",
                      "scope": "conversation",
                      "confidence": 0.84,
                      "evidence_quote": "I think this pattern may matter for my project"
                    }
                  ]
                }
                """)
            },
            now: { now }
        )

        let result = await service.process(fixture.request)

        XCTAssertEqual(result.insertedCount, 2)
        XCTAssertEqual(result.activeCount, 0)
        XCTAssertEqual(result.pendingCount, 2)
        XCTAssertEqual(result.rejectedCount, 0)
        let atoms = try store.fetchMemoryAtoms().sorted { $0.statement < $1.statement }
        XCTAssertEqual(atoms.map(\.status), [.pending, .pending])
        XCTAssertTrue(atoms.allSatisfy { $0.authority == .tentative })
        XCTAssertTrue(atoms.allSatisfy { $0.sourceMessageId == fixture.userMessage.id })
    }

    func testAutomaticDigestRejectsAssistantOnlySourceFactAndHardOptOut() async throws {
        let now = Date(timeIntervalSince1970: 21_000)
        let sourceFactFixture = try makeAutomaticFixture(
            userText: "Explain this source.",
            assistantText: "The source says leaders create the worldview.",
            now: now
        )
        let service = AutomaticMemoryPipelineService(
            nodeStore: store,
            llmServiceProvider: {
                StaticAutomaticMemoryLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "belief",
                      "statement": "Alex believes leaders create the worldview.",
                      "scope": "conversation",
                      "confidence": 0.8,
                      "evidence_quote": "leaders create the worldview"
                    }
                  ]
                }
                """)
            },
            now: { now }
        )

        let sourceFactResult = await service.process(sourceFactFixture.request)
        XCTAssertEqual(sourceFactResult.insertedCount, 0)
        XCTAssertEqual(sourceFactResult.rejectedCount, 1)

        let optOutFixture = try makeAutomaticFixture(
            userText: "Don't remember this: I prefer unsafe memory automation.",
            assistantText: "I won't store that.",
            now: now.addingTimeInterval(10)
        )
        let optOutResult = await service.process(optOutFixture.request)
        XCTAssertEqual(optOutResult.insertedCount, 0)
        XCTAssertEqual(optOutResult.rejectedCount, 0)
        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty)
    }

    func testAutomaticDigestRejectsGenericHelpRequestEvenWithMatchingEvidence() async throws {
        let now = Date(timeIntervalSince1970: 21_500)
        let fixture = try makeAutomaticFixture(
            userText: "Tell me more about this source.",
            assistantText: "Here is more context from the source.",
            now: now
        )
        let service = AutomaticMemoryPipelineService(
            nodeStore: store,
            llmServiceProvider: {
                StaticAutomaticMemoryLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "preference",
                      "statement": "Alex wants more explanation about this source.",
                      "scope": "conversation",
                      "confidence": 0.8,
                      "evidence_quote": "Tell me more about this source."
                    }
                  ]
                }
                """)
            },
            now: { now }
        )

        let result = await service.process(fixture.request)

        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.rejectedCount, 1)
        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty)
    }

    func testAutomaticDigestRejectsGenericIWantYouRequest() async throws {
        let now = Date(timeIntervalSince1970: 21_700)
        let fixture = try makeAutomaticFixture(
            userText: "I want you to explain this PDF in more detail.",
            assistantText: "Here is a deeper explanation.",
            now: now
        )
        let service = AutomaticMemoryPipelineService(
            nodeStore: store,
            llmServiceProvider: {
                StaticAutomaticMemoryLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "goal",
                      "statement": "Alex wants detailed explanations of this PDF.",
                      "scope": "conversation",
                      "confidence": 0.8,
                      "evidence_quote": "I want you to explain this PDF in more detail."
                    }
                  ]
                }
                """)
            },
            now: { now }
        )

        let result = await service.process(fixture.request)

        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.rejectedCount, 1)
        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty)
    }

    func testAutomaticDigestAcceptsExplicitRememberRequestWithGenericCue() async throws {
        let now = Date(timeIntervalSince1970: 21_800)
        let fixture = try makeAutomaticFixture(
            userText: "I want you to help me remember that I prefer batch memory review.",
            assistantText: "Got it, I will keep that preference reviewable.",
            now: now
        )
        let service = AutomaticMemoryPipelineService(
            nodeStore: store,
            llmServiceProvider: {
                StaticAutomaticMemoryLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "preference",
                      "statement": "Alex prefers batch memory review.",
                      "scope": "global",
                      "confidence": 0.82,
                      "evidence_quote": "I want you to help me remember that I prefer batch memory review."
                    }
                  ]
                }
                """)
            },
            now: { now }
        )

        let result = await service.process(fixture.request)

        XCTAssertEqual(result.insertedCount, 1)
        XCTAssertEqual(result.rejectedCount, 0)
        let atom = try XCTUnwrap(try store.fetchMemoryAtoms().first)
        XCTAssertEqual(atom.status, .active)
        XCTAssertEqual(atom.statement, "Alex prefers batch memory review.")
    }

    func testAutomaticAtomPromotesAfterRepeatedIndependentEvidence() throws {
        let now = Date(timeIntervalSince1970: 22_000)
        let conversations = try (0..<3).map { index -> (NousNode, Message) in
            let node = NousNode(type: .conversation, title: "Evidence \(index)")
            try store.insertNode(node)
            let message = Message(
                nodeId: node.id,
                role: .user,
                content: "I prefer source-grounded automatic memory.",
                timestamp: now.addingTimeInterval(Double(index))
            )
            try store.insertMessage(message)
            return (node, message)
        }
        let engine = MemoryLifecycleEngine(nodeStore: store)

        for (index, pair) in conversations.enumerated() {
            let atom = MemoryAtom(
                type: .preference,
                statement: "Alex prefers source-grounded automatic memory.",
                normalizedKey: "alex-prefers-source-grounded-automatic-memory",
                scope: .global,
                status: .active,
                authority: .tentative,
                confidence: 0.76,
                eventTime: pair.1.timestamp,
                createdAt: now.addingTimeInterval(Double(index)),
                updatedAt: now.addingTimeInterval(Double(index)),
                sourceNodeId: pair.0.id,
                sourceMessageId: pair.1.id
            )
            _ = try engine.stageAutomaticAtom(atom, now: atom.createdAt)
        }

        let stored = try XCTUnwrap(try store.fetchMemoryAtoms().first)
        XCTAssertEqual(stored.status, .active)
        XCTAssertEqual(stored.authority, .durable)
        XCTAssertEqual(stored.confidence, 0.86, accuracy: 0.001)
    }

    func testArchivedAutomaticAtomStaysRejectedWhenExtractorSeesSameClaimAgain() async throws {
        let now = Date(timeIntervalSince1970: 22_500)
        let fixture = try makeAutomaticFixture(
            userText: "I prefer automatic memory only when I can archive mistakes.",
            assistantText: "Archive should stay sticky.",
            now: now
        )
        let service = AutomaticMemoryPipelineService(
            nodeStore: store,
            llmServiceProvider: {
                StaticAutomaticMemoryLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "preference",
                      "statement": "Alex prefers automatic memory only when mistakes can be archived.",
                      "scope": "global",
                      "confidence": 0.8,
                      "evidence_quote": "I prefer automatic memory only when I can archive mistakes."
                    }
                  ]
                }
                """)
            },
            now: { now }
        )

        let first = await service.process(fixture.request)
        XCTAssertEqual(first.insertedCount, 1)
        var archived = try XCTUnwrap(try store.fetchMemoryAtoms().first)
        archived.status = .archived
        try store.updateMemoryAtom(archived)

        let second = await service.process(fixture.request)

        XCTAssertEqual(second.insertedCount, 0)
        XCTAssertEqual(second.rejectedCount, 1)
        let atoms = try store.fetchMemoryAtoms()
        XCTAssertEqual(atoms.count, 1)
        XCTAssertEqual(atoms.first?.status, .archived)
    }

    func testInferredIdentityWithoutExplicitDeclarationStaysPending() async throws {
        let now = Date(timeIntervalSince1970: 22_700)
        let fixture = try makeAutomaticFixture(
            userText: "I wonder if chaos is the only way I can work.",
            assistantText: "That sounds like a hypothesis, not a settled identity.",
            now: now
        )
        let service = AutomaticMemoryPipelineService(
            nodeStore: store,
            llmServiceProvider: {
                StaticAutomaticMemoryLLM(output: """
                {
                  "candidates": [
                    {
                      "type": "identity",
                      "statement": "Alex is someone who can only work through chaos.",
                      "scope": "global",
                      "confidence": 0.78,
                      "evidence_quote": "I wonder if chaos is the only way I can work."
                    }
                  ]
                }
                """)
            },
            now: { now }
        )

        let result = await service.process(fixture.request)

        XCTAssertEqual(result.insertedCount, 1)
        let atom = try XCTUnwrap(try store.fetchMemoryAtoms().first)
        XCTAssertEqual(atom.type, .identity)
        XCTAssertEqual(atom.status, .pending)
        XCTAssertEqual(atom.authority, .tentative)
    }

    func testAutomaticCorrectionCreatesTensionInsteadOfOverwritingDurableAtom() throws {
        let now = Date(timeIntervalSince1970: 23_000)
        let durable = MemoryAtom(
            type: .preference,
            statement: "Alex prefers review-first memory automation.",
            normalizedKey: "memory-automation-preference",
            scope: .global,
            status: .active,
            authority: .durable,
            confidence: 0.9,
            createdAt: now,
            updatedAt: now
        )
        try store.insertMemoryAtom(durable)
        let conversation = NousNode(type: .conversation, title: "Correction")
        try store.insertNode(conversation)
        let message = Message(
            nodeId: conversation.id,
            role: .user,
            content: "Actually I want automatic memory to work before review.",
            timestamp: now.addingTimeInterval(10)
        )
        try store.insertMessage(message)

        let correction = MemoryAtom(
            type: .correction,
            statement: "Alex wants automatic memory to work before review.",
            normalizedKey: "memory-automation-preference",
            scope: .global,
            status: .active,
            authority: .tentative,
            confidence: 0.8,
            eventTime: message.timestamp,
            createdAt: message.timestamp,
            updatedAt: message.timestamp,
            sourceNodeId: conversation.id,
            sourceMessageId: message.id,
            correctsTarget: "review-first memory automation"
        )

        _ = try MemoryLifecycleEngine(nodeStore: store).stageAutomaticAtom(correction, now: message.timestamp)

        let existing = try XCTUnwrap(try store.fetchMemoryAtom(id: durable.id))
        XCTAssertEqual(existing.status, .conflicted)
        XCTAssertEqual(existing.authority, .durable)
        let tensions = try store.fetchMemoryTensions(statuses: [.open])
        XCTAssertEqual(tensions.count, 1)
        XCTAssertEqual(tensions.first?.existingAtomId, durable.id)
        XCTAssertEqual(tensions.first?.challengerAtomId, correction.id)
        XCTAssertEqual(tensions.first?.kind, .durableConflict)
    }

    func testResolveTensionMarksRecordResolved() throws {
        let now = Date(timeIntervalSince1970: 23_500)
        let existing = MemoryAtom(
            type: .preference,
            statement: "Alex prefers review-first memory automation.",
            normalizedKey: "resolve-tension-preference",
            scope: .global,
            status: .conflicted,
            authority: .durable,
            confidence: 0.9,
            createdAt: now,
            updatedAt: now
        )
        let challenger = MemoryAtom(
            type: .correction,
            statement: "Alex wants automatic memory to work before review.",
            normalizedKey: "resolve-tension-preference",
            scope: .global,
            status: .active,
            authority: .tentative,
            confidence: 0.8,
            createdAt: now,
            updatedAt: now
        )
        try store.insertMemoryAtom(existing)
        try store.insertMemoryAtom(challenger)
        let tension = MemoryTension(
            kind: .durableConflict,
            existingAtomId: existing.id,
            challengerAtomId: challenger.id,
            summary: "Automatic memory challenged a durable claim.",
            createdAt: now
        )
        try store.insertMemoryTension(tension)

        let resolved = try XCTUnwrap(try MemoryLifecycleEngine(nodeStore: store).resolveTension(tension.id, now: now.addingTimeInterval(30)))

        XCTAssertEqual(resolved.status, .resolved)
        XCTAssertEqual(resolved.resolvedAt, now.addingTimeInterval(30))
        XCTAssertTrue(try store.fetchMemoryTensions(statuses: [.open]).isEmpty)
        let stored = try XCTUnwrap(try store.fetchMemoryTensions().first(where: { $0.id == tension.id }))
        XCTAssertEqual(stored.status, .resolved)
        XCTAssertEqual(stored.resolvedAt, now.addingTimeInterval(30))
    }

    func testSceneAndLivingSelfModelAreStoredWithSourceLinks() throws {
        let now = Date(timeIntervalSince1970: 24_000)
        let projectId = UUID()
        try store.insertProject(Project(id: projectId, title: "Nous Memory"))
        let conversation = NousNode(type: .conversation, title: "Memory direction", projectId: projectId)
        try store.insertNode(conversation)

        for index in 0..<5 {
            let message = Message(
                nodeId: conversation.id,
                role: .user,
                content: "Memory signal \(index)",
                timestamp: now.addingTimeInterval(Double(index))
            )
            try store.insertMessage(message)
            try store.insertMemoryAtom(MemoryAtom(
                type: index == 0 ? .goal : .decision,
                statement: "Alex wants Nous automatic memory layer \(index) to stay sourced.",
                normalizedKey: "automatic-memory-layer-\(index)",
                scope: .project,
                scopeRefId: projectId,
                status: .active,
                authority: index < 3 ? .durable : .tentative,
                confidence: index < 3 ? 0.9 : 0.78,
                eventTime: message.timestamp,
                createdAt: message.timestamp,
                updatedAt: message.timestamp,
                sourceNodeId: conversation.id,
                sourceMessageId: message.id
            ))
        }
        let service = AutomaticMemoryPipelineService(
            nodeStore: store,
            llmServiceProvider: { nil },
            now: { now.addingTimeInterval(100) }
        )

        let result = try service.synthesizeDerivedMemory(projectId: projectId, conversationId: conversation.id)

        XCTAssertEqual(result.sceneCount, 1)
        XCTAssertEqual(result.selfModelCount, 1)
        let scene = try XCTUnwrap(try store.fetchMemoryScenes(scope: .project, scopeRefId: projectId).first)
        XCTAssertEqual(scene.status, .active)
        XCTAssertEqual(scene.authority, .tentative)
        XCTAssertEqual(try store.fetchAtomIdsForMemoryScene(scene.id).count, 5)

        let model = try XCTUnwrap(try store.fetchCurrentLivingSelfModel(scope: .project, scopeRefId: projectId))
        XCTAssertEqual(model.authority, .tentative)
        XCTAssertTrue(model.summary.contains("Inferred current self-model"))
        XCTAssertTrue(model.summary.contains("not anchor truth"))
        XCTAssertEqual(model.sourceSceneIds, [scene.id])
    }

    func testSceneSynthesisRespectsFifteenActiveSceneCap() throws {
        let now = Date(timeIntervalSince1970: 24_500)
        let projectId = UUID()
        try store.insertProject(Project(id: projectId, title: "Scene Cap"))
        let conversation = NousNode(type: .conversation, title: "Scene cap source", projectId: projectId)
        try store.insertNode(conversation)

        for index in 0..<5 {
            let atom = MemoryAtom(
                type: .decision,
                statement: "Alex wants scene cap evidence atom \(index) to stay source-linked.",
                normalizedKey: "scene-cap-evidence-\(index)",
                scope: .project,
                scopeRefId: projectId,
                status: .active,
                authority: .durable,
                confidence: 0.9,
                createdAt: now.addingTimeInterval(Double(index)),
                updatedAt: now.addingTimeInterval(Double(index))
            )
            try store.insertMemoryAtom(atom)
        }

        for index in 0..<16 {
            let scene = MemoryScene(
                scope: .project,
                scopeRefId: projectId,
                title: "Existing scene \(index)",
                summary: "Existing summary \(index)",
                status: .active,
                authority: .tentative,
                createdAt: now.addingTimeInterval(Double(index)),
                updatedAt: now.addingTimeInterval(Double(index))
            )
            try store.upsertMemoryScene(scene, sourceAtomIds: [])
        }
        XCTAssertEqual(try store.fetchMemoryScenes(scope: .project, scopeRefId: projectId).count, 16)

        let service = AutomaticMemoryPipelineService(
            nodeStore: store,
            llmServiceProvider: { nil },
            now: { now.addingTimeInterval(100) }
        )
        _ = try service.synthesizeDerivedMemory(projectId: projectId, conversationId: conversation.id)

        XCTAssertEqual(try store.fetchMemoryScenes(scope: .project, scopeRefId: projectId).count, 15)
    }

    func testPromptAssemblyRendersDerivedMemoryAsSourcedProvisionalContext() {
        let atomId = UUID()
        let scene = MemoryScene(
            scope: .global,
            title: "Automatic memory direction",
            summary: "Current automatic memory scene:\n- Alex wants automation with authority gates.",
            status: .active,
            authority: .tentative,
            createdAt: Date(timeIntervalSince1970: 25_100),
            updatedAt: Date(timeIntervalSince1970: 25_100)
        )
        let model = LivingSelfModel(
            scope: .global,
            summary: "Inferred current self-model, not anchor truth.\nAlex seems to prefer aggressive automation with reviewable authority.",
            authority: .tentative,
            sourceSceneIds: [scene.id],
            createdAt: Date(timeIntervalSince1970: 25_100),
            updatedAt: Date(timeIntervalSince1970: 25_100)
        )
        let derived = DerivedMemoryPromptContext(
            scenes: [DerivedMemorySceneContext(scene: scene, sourceAtomIds: [atomId])],
            selfModel: model
        )

        let slice = PromptContextAssembler.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            derivedMemoryContext: derived
        )

        XCTAssertTrue(slice.stable.contains("DERIVED MEMORY CONTEXT"))
        XCTAssertTrue(slice.stable.contains("authority=tentative"))
        XCTAssertTrue(slice.stable.contains(atomId.uuidString))
        XCTAssertTrue(slice.stable.contains("Inferred current self-model"))
        XCTAssertTrue(slice.stable.contains("never replace anchor.md"))

        let trace = PromptContextAssembler.governanceTrace(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            derivedMemoryContext: derived
        )
        XCTAssertTrue(trace.promptLayers.contains("memory_authority_policy"))
        XCTAssertTrue(trace.promptLayers.contains("derived_memory_context"))
        XCTAssertTrue(trace.hasMemorySignal)
    }

    func testTentativeCorpusCardIsLabeledAsProvisional() {
        let entry = CitableEntry(
            id: UUID().uuidString,
            text: "Alex prefers automatic memory with evidence.",
            scope: .global,
            promptAnnotation: "atom-recall",
            confidence: 0.76,
            eventTime: Date(timeIntervalSince1970: 25_000),
            sourceNodeId: UUID(),
            atomType: .preference,
            authority: .tentative
        )

        let card = CorpusCardFormatter.formatCard(entry)

        XCTAssertTrue(card?.contains("tentative") == true)
        XCTAssertTrue(card?.contains("conf 0.76") == true)
    }

    private struct AutomaticFixture {
        let conversation: NousNode
        let userMessage: Message
        let assistantMessage: Message
        let request: AutomaticMemoryDigestRequest
    }

    private func makeAutomaticFixture(
        userText: String,
        assistantText: String,
        now: Date
    ) throws -> AutomaticFixture {
        let conversation = NousNode(type: .conversation, title: "Automatic memory")
        try store.insertNode(conversation)
        let userMessage = Message(
            nodeId: conversation.id,
            role: .user,
            content: userText,
            timestamp: now
        )
        let assistantMessage = Message(
            nodeId: conversation.id,
            role: .assistant,
            content: assistantText,
            timestamp: now.addingTimeInterval(1)
        )
        try store.insertMessage(userMessage)
        try store.insertMessage(assistantMessage)
        return AutomaticFixture(
            conversation: conversation,
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            request: AutomaticMemoryDigestRequest(
                turnId: UUID(),
                conversationId: conversation.id,
                projectId: nil,
                userMessage: userMessage,
                assistantMessage: assistantMessage,
                sourceMaterials: []
            )
        )
    }
}

private struct StaticAutomaticMemoryLLM: LLMService {
    let output: String

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}
