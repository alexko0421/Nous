import XCTest
@testable import Nous

@MainActor
final class TemporaryBranchViewModelTests: XCTestCase {
    func testOpenAnchorsBranchToSourceMessageAndLocalContext() {
        let nodeId = UUID()
        let messages = [
            Message(id: UUID(), nodeId: nodeId, role: .user, content: "First thought"),
            Message(id: UUID(), nodeId: nodeId, role: .assistant, content: "This is the source line"),
            Message(id: UUID(), nodeId: nodeId, role: .user, content: "Next thought"),
            Message(id: UUID(), nodeId: nodeId, role: .assistant, content: "Outside radius")
        ]
        let branch = TemporaryBranchViewModel()

        branch.open(from: messages[1], in: messages, localContextRadius: 1)

        XCTAssertTrue(branch.isPresented)
        XCTAssertEqual(branch.sourceMessage?.id, messages[1].id)
        XCTAssertEqual(branch.localContext.map(\.content), [
            "First thought",
            "This is the source line",
            "Next thought"
        ])
        XCTAssertTrue(branch.messages.isEmpty)
    }

    func testClosePersistsBranchRecordAndCanReopenTranscript() throws {
        let source = Message(nodeId: UUID(), role: .user, content: "Open a side thought")
        let branch = TemporaryBranchViewModel()
        branch.open(from: source, in: [source])
        branch.inputText = "temporary note"
        branch.messages = [
            TemporaryBranchMessage(role: .user, content: "temporary note"),
            TemporaryBranchMessage(role: .assistant, content: "branch reply")
        ]

        branch.close()

        XCTAssertFalse(branch.isPresented)
        XCTAssertNil(branch.sourceMessage)
        XCTAssertTrue(branch.localContext.isEmpty)
        XCTAssertTrue(branch.messages.isEmpty)
        XCTAssertEqual(branch.inputText, "")
        XCTAssertEqual(branch.currentResponse, "")

        let record = try XCTUnwrap(branch.record(for: source.id))
        XCTAssertEqual(record.sourceMessage.id, source.id)
        XCTAssertEqual(record.messages.map(\.content), ["temporary note", "branch reply"])

        branch.open(from: source, in: [source])

        XCTAssertTrue(branch.isPresented)
        XCTAssertEqual(branch.messages.map(\.content), ["temporary note", "branch reply"])
    }

    func testCloseWithoutTranscriptDoesNotCreateEmptyRecord() {
        let source = Message(nodeId: UUID(), role: .assistant, content: "Nothing happened yet")
        let branch = TemporaryBranchViewModel()

        branch.open(from: source, in: [source])
        branch.close()

        XCTAssertNil(branch.record(for: source.id))
    }

    func testCanLoadPersistedBranchRecordsIntoFreshViewModel() throws {
        let source = Message(nodeId: UUID(), role: .user, content: "Open a side thought")
        let savedRecord = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "temporary note"),
                TemporaryBranchMessage(role: .assistant, content: "branch reply")
            ],
            updatedAt: Date()
        )
        let branch = TemporaryBranchViewModel()

        branch.loadRecords([savedRecord])

        XCTAssertEqual(branch.record(for: source.id)?.messages.map(\.content), [
            "temporary note",
            "branch reply"
        ])

        branch.open(from: source, in: [source])

        XCTAssertEqual(branch.messages.map(\.content), [
            "temporary note",
            "branch reply"
        ])
    }

    func testPresentedSnapshotClearsStaleEvaluationWhenTranscriptChanges() throws {
        let source = Message(nodeId: UUID(), role: .user, content: "Open a side thought")
        let appliedCandidate = TemporaryBranchMemoryCandidate(
            content: "Already saved branch decision.",
            scope: .project,
            kind: .decision,
            status: .applied,
            confidence: 0.88,
            reason: "Previously saved.",
            evidenceQuote: "old branch turn"
        )
        let pendingCandidate = TemporaryBranchMemoryCandidate(
            content: "Pending stale branch thought.",
            scope: .global,
            kind: .preference,
            confidence: 0.7,
            reason: "Needs re-evaluation.",
            evidenceQuote: "old branch turn"
        )
        let savedRecord = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "old branch turn")
            ],
            summary: TemporaryBranchSummary(
                topic: "Old branch",
                keyPoints: ["Old summary"],
                decisions: [],
                openQuestions: [],
                insights: [],
                preview: "Old summary"
            ),
            memoryCandidates: [appliedCandidate, pendingCandidate],
            updatedAt: Date(timeIntervalSince1970: 1),
            lastEvaluatedAt: Date(timeIntervalSince1970: 1)
        )
        let branch = TemporaryBranchViewModel()
        branch.loadRecords([savedRecord])
        branch.open(from: source, in: [source])

        branch.messages.append(TemporaryBranchMessage(role: .user, content: "new branch turn"))
        let snapshot = try XCTUnwrap(branch.presentedRecordSnapshot())

        XCTAssertNil(snapshot.summary)
        XCTAssertNil(snapshot.lastEvaluatedAt)
        XCTAssertEqual(snapshot.memoryCandidates.map(\.status), [.applied])
    }

    func testLegacyBranchRecordJSONDecodesWithoutMemoryFields() throws {
        let source = Message(nodeId: UUID(), role: .user, content: "Open a side thought")
        let legacyRecord = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "temporary note")
            ],
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let legacyData = try JSONEncoder().encode(legacyRecord)

        let decoded = try JSONDecoder().decode(TemporaryBranchRecord.self, from: legacyData)

        XCTAssertNil(decoded.summary)
        XCTAssertTrue(decoded.memoryCandidates.isEmpty)
        XCTAssertNil(decoded.lastEvaluatedAt)
    }

    func testNodeStorePersistsTemporaryBranchRecordsByConversation() throws {
        let store = try NodeStore(path: ":memory:")
        let node = NousNode(type: .conversation, title: "Branch persistence")
        let source = Message(nodeId: node.id, role: .user, content: "Open a side thought")
        let neighbor = Message(nodeId: node.id, role: .assistant, content: "Local context")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source, neighbor],
            messages: [
                TemporaryBranchMessage(role: .user, content: "temporary note"),
                TemporaryBranchMessage(role: .assistant, content: "branch reply")
            ],
            updatedAt: Date()
        )

        try store.insertNode(node)
        try store.insertMessage(source)
        try store.insertMessage(neighbor)
        try store.upsertTemporaryBranchRecord(record)

        let records = try store.fetchTemporaryBranchRecords(nodeId: node.id)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.sourceMessage.id, source.id)
        XCTAssertEqual(records.first?.localContext.map(\.content), ["Open a side thought", "Local context"])
        XCTAssertEqual(records.first?.messages.map(\.content), ["temporary note", "branch reply"])
    }

    func testTemporaryBranchPromptProtectsMainThreadFromBranchContent() {
        let source = Message(nodeId: UUID(), role: .assistant, content: "You said this was too hard.")

        let prompt = PromptContextAssembler.temporaryBranchSystemPrompt(
            sourceMessage: source,
            localContext: [source]
        )

        XCTAssertTrue(prompt.contains("TEMPORARY BRANCH MODE"))
        XCTAssertTrue(prompt.contains("Do not treat this branch as part of the main thread transcript"))
        XCTAssertTrue(prompt.contains("You said this was too hard."))
    }

    func testRegenerateLatestAssistantReplacesOnlyLastBranchReply() async throws {
        let source = Message(nodeId: UUID(), role: .assistant, content: "Open a side thought")
        let branch = TemporaryBranchViewModel()
        branch.open(from: source, in: [source])
        let oldAssistantId = UUID()
        branch.messages = [
            TemporaryBranchMessage(role: .user, content: "First branch turn"),
            TemporaryBranchMessage(id: oldAssistantId, role: .assistant, content: "Old branch reply")
        ]

        XCTAssertTrue(branch.canRegenerateAssistantMessage(oldAssistantId))

        await branch.regenerateLatestAssistant(using: {
            StaticTemporaryBranchLLMService(text: "New branch reply")
        })

        XCTAssertEqual(branch.messages.map(\.content), [
            "First branch turn",
            "New branch reply"
        ])
        XCTAssertNotEqual(branch.messages.last?.id, oldAssistantId)
        XCTAssertFalse(branch.isGenerating)
        XCTAssertEqual(branch.currentResponse, "")
    }

    func testEvaluatorSuppressesGreetingOnlyBranch() async throws {
        let source = Message(nodeId: UUID(), role: .user, content: "hi")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "hi"),
                TemporaryBranchMessage(role: .assistant, content: "Hey.")
            ],
            updatedAt: Date()
        )

        let evaluation = await TemporaryBranchMemoryEvaluator().evaluate(record: record)

        XCTAssertEqual(evaluation.summary.preview, "hi")
        XCTAssertTrue(evaluation.candidates.isEmpty)
    }

    func testEvaluatorSuppressesLowSignalBranchBeforeLLM() async throws {
        let source = Message(nodeId: UUID(), role: .user, content: "hi")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "hi")
            ],
            updatedAt: Date()
        )
        let evaluator = TemporaryBranchMemoryEvaluator(llmServiceProvider: {
            StaticTemporaryBranchLLMService(text: """
            {
              "summary": {
                "topic": "Greeting",
                "key_points": ["Alex said hi."],
                "decisions": [],
                "open_questions": [],
                "insights": [],
                "preview": "Alex said hi."
              },
              "memory_candidates": [
                {
                  "content": "Alex says hi in branches.",
                  "scope": "global",
                  "kind": "preference",
                  "confidence": 0.91,
                  "reason": "Grounded but low signal.",
                  "evidence_quote": "hi"
                }
              ]
            }
            """)
        })

        let evaluation = await evaluator.evaluate(record: record)

        XCTAssertEqual(evaluation.summary.preview, "hi")
        XCTAssertTrue(evaluation.candidates.isEmpty)
    }

    func testEvaluatorCreatesProjectCandidateForProductDecision() async throws {
        let source = Message(nodeId: UUID(), role: .assistant, content: "How should branch memory work?")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(
                    role: .user,
                    content: "Decision: Nous branch summary should enter thread context, but raw branch transcript must not pollute the main prompt."
                )
            ],
            updatedAt: Date()
        )

        let evaluation = await TemporaryBranchMemoryEvaluator().evaluate(record: record)

        let candidate = try XCTUnwrap(evaluation.candidates.first)
        XCTAssertEqual(candidate.scope, .project)
        XCTAssertEqual(candidate.kind, .decision)
        XCTAssertEqual(candidate.status, .pending)
        XCTAssertGreaterThanOrEqual(candidate.confidence, 0.55)
        XCTAssertTrue(candidate.evidenceQuote.contains("branch summary should enter thread context"))
    }

    func testEvaluatorCreatesGlobalCandidateForStableThinkingPreference() async throws {
        let source = Message(nodeId: UUID(), role: .user, content: "What is the philosophy here?")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(
                    role: .user,
                    content: "Long term, I prefer tools that support non-linear thinking and keep side thoughts separate from the main flow."
                )
            ],
            updatedAt: Date()
        )

        let evaluation = await TemporaryBranchMemoryEvaluator().evaluate(record: record)

        let candidate = try XCTUnwrap(evaluation.candidates.first)
        XCTAssertEqual(candidate.scope, .global)
        XCTAssertEqual(candidate.kind, .preference)
        XCTAssertTrue(candidate.content.contains("non-linear thinking"))
    }

    func testEvaluatorSuppressesHardOptOutMemoryCandidate() async throws {
        let source = Message(nodeId: UUID(), role: .user, content: "Do not remember this.")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "Do not remember this private detail: blue train.")
            ],
            updatedAt: Date()
        )

        let evaluation = await TemporaryBranchMemoryEvaluator().evaluate(record: record)

        XCTAssertTrue(evaluation.candidates.isEmpty)
        XCTAssertFalse(evaluation.summary.preview.contains("blue train"))
    }

    func testEvaluatorSuppressesSourceOptOutMemoryCandidate() async throws {
        let source = Message(nodeId: UUID(), role: .user, content: "Do not remember this private source detail: blue train.")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "Can we branch from this?")
            ],
            updatedAt: Date()
        )
        let evaluator = TemporaryBranchMemoryEvaluator(llmServiceProvider: {
            StaticTemporaryBranchLLMService(text: """
            {
              "summary": {
                "topic": "Source detail",
                "key_points": ["Alex mentioned blue train."],
                "decisions": [],
                "open_questions": [],
                "insights": [],
                "preview": "Alex mentioned blue train."
              },
              "memory_candidates": [
                {
                  "content": "Alex has a private source detail: blue train.",
                  "scope": "global",
                  "kind": "identity",
                  "confidence": 0.91,
                  "reason": "Grounded in source.",
                  "evidence_quote": "blue train"
                }
              ]
            }
            """)
        })

        let evaluation = await evaluator.evaluate(record: record)

        XCTAssertTrue(evaluation.candidates.isEmpty)
        XCTAssertEqual(evaluation.summary.preview, "Do-not-remember branch content redacted.")
    }

    func testEvaluatorRejectsLLMCandidateWithoutEvidenceQuote() async throws {
        let source = Message(nodeId: UUID(), role: .assistant, content: "How should branch memory work?")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "Decision: Branch summaries enter thread context.")
            ],
            updatedAt: Date()
        )
        let evaluator = TemporaryBranchMemoryEvaluator(llmServiceProvider: {
            StaticTemporaryBranchLLMService(text: """
            {
              "summary": {
                "topic": "Branch memory",
                "key_points": ["Branch summaries enter thread context."],
                "decisions": ["Use branch summaries."],
                "open_questions": [],
                "insights": [],
                "preview": "Branch summaries enter thread context."
              },
              "memory_candidates": [
                {
                  "content": "Alex secretly wants a different product.",
                  "scope": "global",
                  "kind": "preference",
                  "confidence": 0.91,
                  "reason": "No evidence.",
                  "evidence_quote": ""
                }
              ]
            }
            """)
        })

        let evaluation = await evaluator.evaluate(record: record)

        XCTAssertTrue(evaluation.candidates.isEmpty)
    }

    func testMemoryServiceAbsorbsBranchSummaryIntoThreadMemoryWithoutRawTranscript() async throws {
        let store = try NodeStore(path: ":memory:")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { nil })
        let node = NousNode(type: .conversation, title: "Branch memory")
        let source = Message(nodeId: node.id, role: .assistant, content: "How should branch memory work?")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "raw transcript should stay out of normal prompt")
            ],
            summary: TemporaryBranchSummary(
                topic: "Branch memory",
                keyPoints: ["Branch summary enters thread context."],
                decisions: ["Do not inject raw branch transcript into normal chat context."],
                openQuestions: [],
                insights: [],
                preview: "Branch summary enters thread context."
            ),
            updatedAt: Date()
        )

        try store.insertNode(node)
        try store.insertMessage(source)

        await service.absorbTemporaryBranchSummary(record: record)

        let memory = try XCTUnwrap(try store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id))
        XCTAssertTrue(memory.content.contains("Branch summary enters thread context."))
        XCTAssertFalse(memory.content.contains("raw transcript should stay out of normal prompt"))
    }

    func testMemoryServiceSkipsLowSignalBranchSummaryThreadMemory() async throws {
        let store = try NodeStore(path: ":memory:")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { nil })
        let node = NousNode(type: .conversation, title: "Branch memory")
        let source = Message(nodeId: node.id, role: .user, content: "hi")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "hi")
            ],
            summary: TemporaryBranchSummary(
                topic: "hi",
                keyPoints: [],
                decisions: [],
                openQuestions: [],
                insights: [],
                preview: "hi"
            ),
            updatedAt: Date()
        )

        try store.insertNode(node)
        try store.insertMessage(source)

        await service.absorbTemporaryBranchSummary(record: record)

        XCTAssertNil(try store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id))
    }

    func testMemoryServiceRedactsOptOutBranchSummarySourceExcerpt() async throws {
        let store = try NodeStore(path: ":memory:")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { nil })
        let node = NousNode(type: .conversation, title: "Branch memory")
        let source = Message(nodeId: node.id, role: .user, content: "Do not remember this private source detail: blue train.")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "Do not remember this private branch detail: green station.")
            ],
            summary: TemporaryBranchSummary(
                topic: "Memory boundary",
                keyPoints: ["Alex marked this branch content as do-not-remember."],
                decisions: [],
                openQuestions: [],
                insights: [],
                preview: "Do-not-remember branch content redacted."
            ),
            updatedAt: Date()
        )

        try store.insertNode(node)
        try store.insertMessage(source)

        await service.absorbTemporaryBranchSummary(record: record)

        let memory = try XCTUnwrap(try store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id))
        XCTAssertTrue(memory.content.contains("do-not-remember"))
        XCTAssertFalse(memory.content.contains("blue train"))
        XCTAssertFalse(memory.content.contains("green station"))
    }

    func testMemoryServiceDoesNotApplyProjectOrGlobalCandidatesWhenAbsorbingSummary() async throws {
        let store = try NodeStore(path: ":memory:")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { nil })
        let projectId = UUID()
        let project = Project(id: projectId, title: "Branch memory")
        let node = NousNode(type: .conversation, title: "Branch memory", projectId: projectId)
        let source = Message(nodeId: node.id, role: .assistant, content: "Try a branch.")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "Decision: maybe store this globally later.")
            ],
            summary: TemporaryBranchSummary(
                topic: "Branch memory",
                keyPoints: ["A branch can produce pending candidates."],
                decisions: ["Project/global candidates wait for explicit confirmation."],
                openQuestions: [],
                insights: [],
                preview: "Project/global candidates wait."
            ),
            memoryCandidates: [
                TemporaryBranchMemoryCandidate(
                    content: "Branch decisions should automatically become project memory.",
                    scope: .project,
                    kind: .decision,
                    confidence: 0.91,
                    reason: "Deliberately pending candidate.",
                    evidenceQuote: "maybe store this globally later"
                ),
                TemporaryBranchMemoryCandidate(
                    content: "Alex treats branch experiments as stable identity.",
                    scope: .global,
                    kind: .identity,
                    confidence: 0.85,
                    reason: "Deliberately pending candidate.",
                    evidenceQuote: "maybe store this globally later"
                )
            ],
            updatedAt: Date()
        )

        try store.insertProject(project)
        try store.insertNode(node)
        try store.insertMessage(source)

        await service.absorbTemporaryBranchSummary(record: record)

        XCTAssertNotNil(try store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id))
        XCTAssertNil(try store.fetchActiveMemoryEntry(scope: .project, scopeRefId: projectId))
        XCTAssertNil(try store.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil))
    }

    func testMemoryServiceAppliesProjectAndGlobalCandidatesToCorrectScopes() async throws {
        let store = try NodeStore(path: ":memory:")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { nil })
        let projectId = UUID()
        let project = Project(id: projectId, title: "Branch memory")
        let node = NousNode(type: .conversation, title: "Branch memory", projectId: projectId)
        let source = Message(nodeId: node.id, role: .user, content: "Branch memory architecture")
        let baseRecord = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "Decision: Branch summary enters thread context.")
            ],
            updatedAt: Date()
        )
        let projectCandidate = TemporaryBranchMemoryCandidate(
            content: "Branch summary enters thread context without injecting raw transcript.",
            scope: .project,
            kind: .decision,
            confidence: 0.88,
            reason: "Product architecture decision.",
            evidenceQuote: "Branch summary enters thread context"
        )
        let globalCandidate = TemporaryBranchMemoryCandidate(
            content: "Alex prefers tools that support non-linear thinking.",
            scope: .global,
            kind: .preference,
            confidence: 0.9,
            reason: "Stable thinking preference.",
            evidenceQuote: "non-linear thinking"
        )

        try store.insertProject(project)
        try store.insertNode(node)
        try store.insertMessage(source)

        let didApplyProjectCandidate = await service.applyTemporaryBranchCandidate(projectCandidate, record: baseRecord)
        let didApplyGlobalCandidate = await service.applyTemporaryBranchCandidate(globalCandidate, record: baseRecord)

        XCTAssertTrue(didApplyProjectCandidate)
        XCTAssertTrue(didApplyGlobalCandidate)

        let projectMemory = try XCTUnwrap(try store.fetchActiveMemoryEntry(scope: .project, scopeRefId: projectId))
        let globalMemory = try XCTUnwrap(try store.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil))
        XCTAssertTrue(projectMemory.content.contains("Branch summary enters thread context"))
        XCTAssertTrue(globalMemory.content.contains("non-linear thinking"))
    }

    func testMemoryServiceAppliesConversationCandidateToThreadScope() async throws {
        let store = try NodeStore(path: ":memory:")
        let service = UserMemoryService(nodeStore: store, llmServiceProvider: { nil })
        let node = NousNode(type: .conversation, title: "Branch thread memory")
        let source = Message(nodeId: node.id, role: .user, content: "Keep this only in the current thread.")
        let record = TemporaryBranchRecord(
            sourceMessage: source,
            localContext: [source],
            messages: [
                TemporaryBranchMessage(role: .user, content: "Thread-only branch context.")
            ],
            updatedAt: Date()
        )
        let candidate = TemporaryBranchMemoryCandidate(
            content: "Thread-only branch context should remain conversation scoped.",
            scope: .conversation,
            kind: .thread,
            confidence: 0.74,
            reason: "Temporary branch context is local to this conversation.",
            evidenceQuote: "Thread-only branch context"
        )

        try store.insertNode(node)
        try store.insertMessage(source)

        let didApply = await service.applyTemporaryBranchCandidate(candidate, record: record)

        XCTAssertTrue(didApply)
        let threadMemory = try XCTUnwrap(try store.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: node.id))
        XCTAssertTrue(threadMemory.content.contains("Thread-only branch context"))
        XCTAssertNil(try store.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil))
    }
}

private struct StaticTemporaryBranchLLMService: LLMService {
    let text: String

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }
}
