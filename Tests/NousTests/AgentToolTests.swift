import XCTest
@testable import Nous

final class AgentToolInputTests: XCTestCase {
    func testBoundedIntegerClampsNegativeAndHugeValues() throws {
        let input = AgentToolInput(raw: ["negative": -20, "huge": 999, "double": 2.8])

        XCTAssertEqual(try input.boundedInteger("negative", default: 5, range: 1...8), 1)
        XCTAssertEqual(try input.boundedInteger("huge", default: 5, range: 1...8), 8)
        XCTAssertEqual(try input.boundedInteger("double", default: 5, range: 1...8), 2)
        XCTAssertEqual(try input.boundedInteger("missing", default: 5, range: 1...8), 5)
    }

    func testBoundedIntegerRejectsPresentNonNumericValue() {
        let input = AgentToolInput(raw: ["limit": "a lot"])

        XCTAssertThrowsError(try input.boundedInteger("limit", default: 5, range: 1...8)) { error in
            XCTAssertEqual(error as? AgentToolError, .invalidArgument("limit"))
        }
    }
}

final class AgentTraceCodecTests: XCTestCase {
    func testTraceCodecRoundTripsRecordsAndTreatsInvalidInputAsEmpty() throws {
        let records = [
            AgentTraceRecord(
                kind: .toolCall,
                toolName: AgentToolNames.searchMemory,
                title: "Searching memory...",
                detail: "",
                inputJSON: #"{"query":"pivot"}"#
            )
        ]

        let encoded = try XCTUnwrap(AgentTraceCodec.encode(records))
        XCTAssertEqual(AgentTraceCodec.decode(encoded), records)
        XCTAssertEqual(AgentTraceCodec.decode(nil), [])
        XCTAssertEqual(AgentTraceCodec.decode("not-json"), [])
    }
}

final class ReadNoteToolTests: XCTestCase {
    private var store: NodeStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    func testNilProjectContextCannotReadArbitraryNilProjectNode() async throws {
        let current = NousNode(type: .conversation, title: "Current")
        let other = NousNode(type: .note, title: "Other", content: "Private note")
        try store.insertNode(current)
        try store.insertNode(other)

        let tool = ReadNoteTool(nodeReader: store)
        let context = AgentToolContext(
            conversationId: current.id,
            projectId: nil,
            currentNodeId: current.id,
            currentMessage: "read",
            excludeNodeIds: [current.id],
            allowedReadNodeIds: [current.id],
            maxToolResultCharacters: 1200
        )

        await XCTAssertThrowsErrorAsync(
            try await tool.execute(input: AgentToolInput(raw: ["id": other.id.uuidString]), context: context)
        ) { error in
            XCTAssertEqual(error as? AgentToolError, .unauthorized("Node"))
        }
    }

    func testSameNonNilProjectNodeIsReadable() async throws {
        let project = Project(title: "Nous")
        try store.insertProject(project)
        let current = NousNode(type: .conversation, title: "Current", projectId: project.id)
        let note = NousNode(type: .note, title: "Plan", content: "Ship the focused version.", projectId: project.id)
        try store.insertNode(current)
        try store.insertNode(note)

        let tool = ReadNoteTool(nodeReader: store)
        let context = AgentToolContext(
            conversationId: current.id,
            projectId: project.id,
            currentNodeId: current.id,
            currentMessage: "read",
            excludeNodeIds: [current.id],
            allowedReadNodeIds: [current.id],
            maxToolResultCharacters: 1200
        )

        let result = try await tool.execute(
            input: AgentToolInput(raw: ["id": note.id.uuidString]),
            context: context
        )
        XCTAssertTrue(result.summary.contains("Ship the focused version."))
    }
}

final class SearchMemoryToolTests: XCTestCase {
    private var store: NodeStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    func testGlobalMemorySearchDoesNotDiscoverOutOfScopeRawSourceNodes() async throws {
        let project = Project(title: "Nous")
        try store.insertProject(project)
        let current = NousNode(type: .conversation, title: "Current", projectId: project.id)
        let sameProjectNote = NousNode(type: .note, title: "Scoped", content: "Scoped raw", projectId: project.id)
        let nilProjectNote = NousNode(type: .note, title: "Out", content: "Out raw")
        try store.insertNode(current)
        try store.insertNode(sameProjectNote)
        try store.insertNode(nilProjectNote)
        try store.insertMemoryEntry(MemoryEntry(
            scope: .global,
            kind: .decision,
            stability: .stable,
            content: "pivot decision in scoped source",
            sourceNodeIds: [sameProjectNote.id]
        ))
        try store.insertMemoryEntry(MemoryEntry(
            scope: .global,
            kind: .decision,
            stability: .stable,
            content: "pivot decision in unrelated source",
            sourceNodeIds: [nilProjectNote.id]
        ))

        let tool = SearchMemoryTool(memorySearchProvider: store, nodeReader: store)
        let context = AgentToolContext(
            conversationId: current.id,
            projectId: project.id,
            currentNodeId: current.id,
            currentMessage: "pivot",
            excludeNodeIds: [current.id],
            allowedReadNodeIds: [current.id],
            maxToolResultCharacters: 1200
        )

        let result = try await tool.execute(
            input: AgentToolInput(raw: ["query": "pivot", "limit": 8]),
            context: context
        )

        XCTAssertTrue(result.summary.contains("pivot decision"))
        XCTAssertTrue(result.summary.contains(sameProjectNote.id.uuidString))
        XCTAssertFalse(result.summary.contains(nilProjectNote.id.uuidString))
        XCTAssertTrue(result.discoveredNodeIds.contains(sameProjectNote.id))
        XCTAssertFalse(result.discoveredNodeIds.contains(nilProjectNote.id))
    }
}

final class SearchConversationsByTopicToolTests: XCTestCase {
    func testOnlyEmitsSnippetsForReadableConversationsAndIncludesReadableIds() async throws {
        let projectId = UUID()
        let current = NousNode(type: .conversation, title: "Current", projectId: projectId)
        let outOfScope = NousNode(
            type: .conversation,
            title: "Out of scope",
            content: "Do not leak this conversation snippet.",
            projectId: nil
        )
        let readable = NousNode(
            type: .conversation,
            title: "Readable",
            content: "Readable conversation snippet.",
            projectId: projectId
        )
        let sameProjectNote = NousNode(
            type: .note,
            title: "Note",
            content: "Notes are not conversation topic results.",
            projectId: projectId
        )

        let tool = SearchConversationsByTopicTool(
            vectorStore: FakeVectorSearcher(results: [
                SearchResult(node: outOfScope, similarity: 0.99),
                SearchResult(node: sameProjectNote, similarity: 0.98),
                SearchResult(node: readable, similarity: 0.97)
            ]),
            embeddingService: FakeConversationEmbeddingProvider(isLoaded: true),
            nodeReader: EmptyNodeReader()
        )
        let context = AgentToolContext(
            conversationId: current.id,
            projectId: projectId,
            currentNodeId: current.id,
            currentMessage: "topic",
            excludeNodeIds: [current.id],
            allowedReadNodeIds: [current.id],
            maxToolResultCharacters: 1200
        )

        let result = try await tool.execute(
            input: AgentToolInput(raw: ["query": "snippet", "limit": 1]),
            context: context
        )

        XCTAssertTrue(result.summary.contains(readable.id.uuidString))
        XCTAssertTrue(result.summary.contains("Readable conversation snippet."))
        XCTAssertFalse(result.summary.contains(outOfScope.id.uuidString))
        XCTAssertFalse(result.summary.contains("Do not leak this conversation snippet."))
        XCTAssertEqual(result.discoveredNodeIds, [readable.id])
    }

    func testNoReadableConversationMatchDoesNotLeakOutOfScopeSnippet() async throws {
        let projectId = UUID()
        let current = NousNode(type: .conversation, title: "Current", projectId: projectId)
        let outOfScope = NousNode(
            type: .conversation,
            title: "Out of scope",
            content: "This raw conversation must stay private.",
            projectId: nil
        )
        let tool = SearchConversationsByTopicTool(
            vectorStore: FakeVectorSearcher(results: [
                SearchResult(node: outOfScope, similarity: 0.99)
            ]),
            embeddingService: FakeConversationEmbeddingProvider(isLoaded: true),
            nodeReader: EmptyNodeReader()
        )
        let context = AgentToolContext(
            conversationId: current.id,
            projectId: projectId,
            currentNodeId: current.id,
            currentMessage: "topic",
            excludeNodeIds: [current.id],
            allowedReadNodeIds: [current.id],
            maxToolResultCharacters: 1200
        )

        let result = try await tool.execute(
            input: AgentToolInput(raw: ["query": "private"]),
            context: context
        )

        XCTAssertEqual(result.summary, "No readable conversations matched that topic.")
        XCTAssertFalse(result.summary.contains("This raw conversation must stay private."))
        XCTAssertTrue(result.discoveredNodeIds.isEmpty)
    }
}

final class FindContradictionsToolTests: XCTestCase {
    func testContradictionResultsIncludeUpdatedDate() async throws {
        let updatedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-27T12:00:00Z"))
        let fact = MemoryFactEntry(
            scope: .project,
            scopeRefId: UUID(),
            kind: .constraint,
            content: "Alex decided not to add write tools in Phase 1.",
            stability: .stable,
            updatedAt: updatedAt
        )
        let tool = FindContradictionsTool(
            contradictionProvider: FakeContradictionProvider(facts: [fact])
        )
        let context = AgentToolContext(
            conversationId: UUID(),
            projectId: UUID(),
            currentNodeId: UUID(),
            currentMessage: "Add write tools now",
            excludeNodeIds: [],
            allowedReadNodeIds: [],
            maxToolResultCharacters: 1200
        )

        let result = try await tool.execute(
            input: AgentToolInput(raw: ["topic": "Add write tools now"]),
            context: context
        )

        XCTAssertTrue(result.summary.contains("updated 2026-04-27"))
        XCTAssertTrue(result.summary.contains("Alex decided not to add write tools in Phase 1."))
    }
}

final class OpenRouterToolEncodingTests: XCTestCase {
    func testToolRequestBodySerializesTranscriptAndToolChoice() throws {
        let declaration = AgentToolDeclaration(
            function: AgentToolFunctionDeclaration(
                name: AgentToolNames.searchMemory,
                description: "Search memory.",
                parameters: AgentToolSchema(
                    properties: [
                        "query": AgentToolSchemaProperty(type: .string, description: "Query")
                    ],
                    required: ["query"]
                )
            )
        )

        let body = try OpenRouterLLMService.buildToolRequestBody(
            model: "anthropic/claude-sonnet-4.6",
            system: "system prompt",
            messages: [
                .text(role: "user", content: "Find old context"),
                .assistantToolCalls(
                    content: nil,
                    toolCalls: [
                        AgentToolCall(
                            id: "call_1",
                            name: AgentToolNames.searchMemory,
                            argumentsJSON: #"{"query":"visa"}"#
                        )
                    ]
                ),
                .toolResult(
                    toolCallId: "call_1",
                    name: AgentToolNames.searchMemory,
                    content: "memory result",
                    isError: false
                )
            ],
            tools: [declaration],
            allowToolCalls: false
        )

        XCTAssertEqual(body["model"] as? String, "anthropic/claude-sonnet-4.6")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["tool_choice"] as? String, "none")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "system prompt")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "Find old context")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertEqual(messages[2]["content"] as? String, "")
        let toolCalls = try XCTUnwrap(messages[2]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.first?["id"] as? String, "call_1")
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, AgentToolNames.searchMemory)
        XCTAssertEqual(function["arguments"] as? String, #"{"query":"visa"}"#)
        XCTAssertEqual(messages[3]["role"] as? String, "tool")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(messages[3]["name"] as? String, AgentToolNames.searchMemory)
        XCTAssertEqual(messages[3]["content"] as? String, "memory result")

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let encodedFunction = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertEqual(encodedFunction["name"] as? String, AgentToolNames.searchMemory)
    }
}

final class AgentLoopExecutorTests: XCTestCase {
    func testUnknownToolCallIsReturnedAsToolErrorBeforeFinalSynthesis() async throws {
        let turnId = UUID()
        let node = NousNode(type: .conversation, title: "Current")
        let userMessage = Message(nodeId: node.id, role: .user, content: "Find context")
        let unknownCall = AgentToolCall(
            id: "call_missing",
            name: "missing_tool",
            argumentsJSON: "{}"
        )
        let llm = ScriptedToolCallingLLM(responses: [
            AgentToolLLMResponse(
                text: "",
                assistantMessage: .assistantToolCalls(content: nil, toolCalls: [unknownCall]),
                toolCalls: [unknownCall]
            ),
            AgentToolLLMResponse(
                text: "Final answer",
                assistantMessage: .text(role: "assistant", content: "Final answer"),
                toolCalls: []
            )
        ])
        let executor = AgentLoopExecutor(
            llmService: llm,
            registry: AgentToolRegistry(tools: []),
            perToolTimeoutSeconds: 1,
            totalTurnTimeoutSeconds: 5
        )
        let capture = CapturingTurnEventSink()
        let sink = TurnSequencedEventSink(turnId: turnId, sink: capture)

        let result = try await executor.execute(
            plan: makeAgentLoopPlan(turnId: turnId, node: node, userMessage: userMessage),
            request: makeAgentLoopRequest(turnId: turnId, node: node, userMessage: userMessage),
            sink: sink,
            context: makeAgentToolContext(node: node, userMessage: userMessage)
        )

        XCTAssertEqual(result?.assistantContent, "Final answer")
        let calls = await llm.capturedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].messages.count, 3)
        guard case .assistantToolCalls(_, let toolCalls) = calls[1].messages[1] else {
            return XCTFail("Expected assistant tool-call message in follow-up transcript.")
        }
        XCTAssertEqual(toolCalls, [unknownCall])
        guard case .toolResult(let toolCallId, let name, let content, let isError) = calls[1].messages[2] else {
            return XCTFail("Expected tool-result message in follow-up transcript.")
        }
        XCTAssertEqual(toolCallId, "call_missing")
        XCTAssertEqual(name, "missing_tool")
        XCTAssertTrue(content.contains("Tool error:"))
        XCTAssertTrue(content.contains("missing_tool was not found."))
        XCTAssertTrue(isError)

        let events = await capture.events()
        XCTAssertEqual(events.count, 3)
        guard case .agentTraceDelta(let errorTrace) = events[1].event else {
            return XCTFail("Expected a tool-error trace event.")
        }
        XCTAssertEqual(errorTrace.kind, .toolError)
    }

    func testCancellationReturnsNil() async throws {
        let turnId = UUID()
        let node = NousNode(type: .conversation, title: "Current")
        let userMessage = Message(nodeId: node.id, role: .user, content: "Find context")
        let executor = AgentLoopExecutor(
            llmService: SlowToolCallingLLM(),
            registry: AgentToolRegistry(tools: []),
            perToolTimeoutSeconds: 1,
            totalTurnTimeoutSeconds: 5
        )
        let capture = CapturingTurnEventSink()
        let sink = TurnSequencedEventSink(turnId: turnId, sink: capture)

        let task = Task {
            try await executor.execute(
                plan: makeAgentLoopPlan(turnId: turnId, node: node, userMessage: userMessage),
                request: makeAgentLoopRequest(turnId: turnId, node: node, userMessage: userMessage),
                sink: sink,
                context: makeAgentToolContext(node: node, userMessage: userMessage)
            )
        }
        task.cancel()

        let result = try await task.value
        XCTAssertNil(result)
    }

    func testDiscoveredIdsDoNotAuthorizeSiblingToolCallsInSameBatch() async throws {
        let store = try NodeStore(path: ":memory:")
        let current = NousNode(type: .conversation, title: "Current")
        let note = NousNode(type: .note, title: "Out of batch", content: "Sibling read should not see this.")
        try store.insertNode(current)
        try store.insertNode(note)

        let turnId = UUID()
        let userMessage = Message(nodeId: current.id, role: .user, content: "Find context")
        let discoverCall = AgentToolCall(
            id: "call_discover",
            name: DiscoverNodeTool.toolName,
            argumentsJSON: "{}"
        )
        let readCall = AgentToolCall(
            id: "call_read",
            name: AgentToolNames.readNote,
            argumentsJSON: #"{"id":"\#(note.id.uuidString)"}"#
        )
        let llm = ScriptedToolCallingLLM(responses: [
            AgentToolLLMResponse(
                text: "",
                assistantMessage: .assistantToolCalls(content: nil, toolCalls: [discoverCall, readCall]),
                toolCalls: [discoverCall, readCall]
            ),
            AgentToolLLMResponse(
                text: "Final answer",
                assistantMessage: .text(role: "assistant", content: "Final answer"),
                toolCalls: []
            )
        ])
        let executor = AgentLoopExecutor(
            llmService: llm,
            registry: AgentToolRegistry(tools: [
                DiscoverNodeTool(nodeId: note.id),
                ReadNoteTool(nodeReader: store)
            ]),
            perToolTimeoutSeconds: 1,
            totalTurnTimeoutSeconds: 5
        )
        let capture = CapturingTurnEventSink()
        let sink = TurnSequencedEventSink(turnId: turnId, sink: capture)

        _ = try await executor.execute(
            plan: makeAgentLoopPlan(turnId: turnId, node: current, userMessage: userMessage),
            request: makeAgentLoopRequest(turnId: turnId, node: current, userMessage: userMessage),
            sink: sink,
            context: makeAgentToolContext(node: current, userMessage: userMessage)
        )

        let calls = await llm.capturedCalls()
        XCTAssertEqual(calls.count, 2)
        guard case .toolResult(_, let discoverToolName, _, false) = calls[1].messages[2],
              discoverToolName == DiscoverNodeTool.toolName else {
            return XCTFail("Expected first sibling tool to discover a node.")
        }
        guard case .toolResult(_, let readToolName, let content, true) = calls[1].messages[3],
              readToolName == AgentToolNames.readNote else {
            return XCTFail("Expected sibling read_note to remain unauthorized.")
        }
        XCTAssertTrue(content.contains("Tool error:"))
        XCTAssertTrue(content.contains("outside the readable scope"))
        XCTAssertFalse(content.contains("Sibling read should not see this."))
    }

    func testCapReachedForcesFinalSynthesisWithToolCallsDisabled() async throws {
        let turnId = UUID()
        let node = NousNode(type: .conversation, title: "Current")
        let userMessage = Message(nodeId: node.id, role: .user, content: "Keep searching")
        let loopResponses = (0..<AgentLoopExecutor.maxIterations).map { index in
            let toolCall = AgentToolCall(
                id: "call_\(index)",
                name: NoopTool.toolName,
                argumentsJSON: "{}"
            )
            return AgentToolLLMResponse(
                text: "",
                assistantMessage: .assistantToolCalls(content: nil, toolCalls: [toolCall]),
                toolCalls: [toolCall]
            )
        }
        let finalResponse = AgentToolLLMResponse(
            text: "Forced synthesis",
            assistantMessage: .text(role: "assistant", content: "Forced synthesis"),
            toolCalls: []
        )
        let llm = ScriptedToolCallingLLM(responses: loopResponses + [finalResponse])
        let executor = AgentLoopExecutor(
            llmService: llm,
            registry: AgentToolRegistry(tools: [NoopTool()]),
            perToolTimeoutSeconds: 1,
            totalTurnTimeoutSeconds: 5
        )
        let capture = CapturingTurnEventSink()
        let sink = TurnSequencedEventSink(turnId: turnId, sink: capture)

        let result = try await executor.execute(
            plan: makeAgentLoopPlan(turnId: turnId, node: node, userMessage: userMessage),
            request: makeAgentLoopRequest(turnId: turnId, node: node, userMessage: userMessage),
            sink: sink,
            context: makeAgentToolContext(node: node, userMessage: userMessage)
        )

        XCTAssertEqual(result?.assistantContent, "Forced synthesis")
        let calls = await llm.capturedCalls()
        XCTAssertEqual(calls.count, AgentLoopExecutor.maxIterations + 1)
        XCTAssertTrue(calls.dropLast().allSatisfy { $0.allowToolCalls })
        XCTAssertEqual(calls.last?.allowToolCalls, false)
        let events = await capture.events()
        XCTAssertTrue(events.contains { envelope in
            guard case .agentTraceDelta(let record) = envelope.event else { return false }
            return record.kind == .capReached
        })
    }
}

final class ChatTurnRunnerAgentRoutingTests: XCTestCase {
    func testDirectionUsesAgentLoopWhenFactoryProvidesExecutor() async throws {
        let store = try NodeStore(path: ":memory:")
        let agentLLM = ScriptedToolCallingLLM(responses: [
            AgentToolLLMResponse(
                text: "Agent loop answer",
                assistantMessage: .text(role: "assistant", content: "Agent loop answer"),
                toolCalls: []
            )
        ])
        let runner = makeChatTurnRunner(
            nodeStore: store,
            provider: .openrouter,
            singleShotText: "Single shot answer"
        ) { _, _, _ in
            AgentLoopExecutor(
                llmService: agentLLM,
                registry: AgentToolRegistry(tools: []),
                perToolTimeoutSeconds: 1,
                totalTurnTimeoutSeconds: 5
            )
        }
        let sinkStore = CapturingTurnEventSink()
        let sink = TurnSequencedEventSink(turnId: UUID(), sink: sinkStore)

        let completion = await runner.run(
            request: makeRunnerRequest(mode: .direction),
            sink: sink,
            abortReason: { .cancelledByUser }
        )

        XCTAssertEqual(completion?.assistantMessage.content, "Agent loop answer")
        let calls = await agentLLM.capturedCalls()
        XCTAssertEqual(calls.count, 1)
    }

    func testDirectionFallsBackToSingleShotWhenFactoryReturnsNil() async throws {
        let store = try NodeStore(path: ":memory:")
        let runner = makeChatTurnRunner(
            nodeStore: store,
            provider: .gemini,
            singleShotText: "Single shot answer"
        ) { _, plan, _ in
            XCTAssertEqual(plan.provider, .gemini)
            return nil
        }
        let sinkStore = CapturingTurnEventSink()
        let sink = TurnSequencedEventSink(turnId: UUID(), sink: sinkStore)

        let completion = await runner.run(
            request: makeRunnerRequest(mode: .direction),
            sink: sink,
            abortReason: { .cancelledByUser }
        )

        XCTAssertEqual(completion?.assistantMessage.content, "Single shot answer")
    }

    func testBrainstormDoesNotRequestAgentLoopFactory() async throws {
        let store = try NodeStore(path: ":memory:")
        var factoryCallCount = 0
        let runner = makeChatTurnRunner(
            nodeStore: store,
            provider: .openrouter,
            singleShotText: "Brainstorm single shot"
        ) { _, _, _ in
            factoryCallCount += 1
            return nil
        }
        let sinkStore = CapturingTurnEventSink()
        let sink = TurnSequencedEventSink(turnId: UUID(), sink: sinkStore)

        let completion = await runner.run(
            request: makeRunnerRequest(mode: .brainstorm),
            sink: sink,
            abortReason: { .cancelledByUser }
        )

        XCTAssertEqual(completion?.assistantMessage.content, "Brainstorm single shot")
        XCTAssertEqual(factoryCallCount, 0)
    }
}

private struct FakeConversationEmbeddingProvider: AgentConversationEmbeddingProviding {
    let isLoaded: Bool

    func embed(_ text: String) throws -> [Float] {
        [1, 0]
    }
}

private struct FakeVectorSearcher: AgentVectorSearching {
    let results: [SearchResult]

    func search(query: [Float], topK: Int, excludeIds: Set<UUID>) throws -> [SearchResult] {
        Array(results.filter { !excludeIds.contains($0.node.id) }.prefix(topK))
    }
}

private struct EmptyNodeReader: NodeReading {
    func fetchNode(id: UUID) throws -> NousNode? {
        nil
    }
}

private struct FakeContradictionProvider: ContradictionFactProviding {
    let facts: [MemoryFactEntry]

    func contradictionRecallFacts(projectId: UUID?, conversationId: UUID) throws -> [MemoryFactEntry] {
        facts
    }

    func annotateContradictionCandidates(
        currentMessage: String,
        facts: [MemoryFactEntry],
        maxCandidates: Int
    ) -> [UserMemoryCore.AnnotatedContradictionFact] {
        facts.prefix(maxCandidates).map {
            UserMemoryCore.AnnotatedContradictionFact(
                fact: $0,
                isContradictionCandidate: true,
                relevanceScore: 1
            )
        }
    }
}

private struct DiscoverNodeTool: AgentTool {
    static let toolName = "discover_node"
    let name = Self.toolName
    let description = "Discovers a node id for test coverage."
    let inputSchema = AgentToolSchema(properties: [:], required: [])
    let nodeId: UUID

    func execute(input: AgentToolInput, context: AgentToolContext) async throws -> AgentToolResult {
        AgentToolResult(summary: "Discovered node.", discoveredNodeIds: [nodeId])
    }
}

private struct NoopTool: AgentTool {
    static let toolName = "noop_tool"
    let name = Self.toolName
    let description = "Returns a no-op result for test coverage."
    let inputSchema = AgentToolSchema(properties: [:], required: [])

    func execute(input: AgentToolInput, context: AgentToolContext) async throws -> AgentToolResult {
        AgentToolResult(summary: "ok")
    }
}

private struct CapturedToolLLMCall: Sendable {
    let system: String
    let messages: [AgentLoopMessage]
    let tools: [AgentToolDeclaration]
    let allowToolCalls: Bool
}

private actor ScriptedToolCallingLLM: ToolCallingLLMService {
    nonisolated var supportsAgentToolUse: Bool { true }

    private var responses: [AgentToolLLMResponse]
    private var calls: [CapturedToolLLMCall] = []

    init(responses: [AgentToolLLMResponse]) {
        self.responses = responses
    }

    func callWithTools(
        system: String,
        messages: [AgentLoopMessage],
        tools: [AgentToolDeclaration],
        allowToolCalls: Bool
    ) async throws -> AgentToolLLMResponse {
        calls.append(CapturedToolLLMCall(
            system: system,
            messages: messages,
            tools: tools,
            allowToolCalls: allowToolCalls
        ))
        guard !responses.isEmpty else {
            throw LLMError.invalidResponse
        }
        return responses.removeFirst()
    }

    func capturedCalls() -> [CapturedToolLLMCall] {
        calls
    }
}

private actor SlowToolCallingLLM: ToolCallingLLMService {
    nonisolated var supportsAgentToolUse: Bool { true }

    func callWithTools(
        system: String,
        messages: [AgentLoopMessage],
        tools: [AgentToolDeclaration],
        allowToolCalls: Bool
    ) async throws -> AgentToolLLMResponse {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return AgentToolLLMResponse(
            text: "Too late",
            assistantMessage: .text(role: "assistant", content: "Too late"),
            toolCalls: []
        )
    }
}

private actor CapturingTurnEventSink: TurnEventSink {
    private var capturedEvents: [TurnEventEnvelope] = []

    func emit(_ envelope: TurnEventEnvelope) async {
        capturedEvents.append(envelope)
    }

    func events() -> [TurnEventEnvelope] {
        capturedEvents
    }
}

private struct StaticStreamingLLMService: LLMService {
    let text: String

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }
}

private func makeChatTurnRunner(
    nodeStore: NodeStore,
    provider: LLMProvider,
    singleShotText: String,
    agentLoopExecutorFactory: AgentLoopExecutorFactory?
) -> ChatTurnRunner {
    let core = UserMemoryCore(nodeStore: nodeStore, llmServiceProvider: { nil })
    let memoryProjection = MemoryProjectionService(core: core)
    let contradiction = ContradictionMemoryService(core: core)
    let planner = TurnPlanner(
        nodeStore: nodeStore,
        vectorStore: VectorStore(nodeStore: nodeStore),
        embeddingService: EmbeddingService(),
        memoryProjectionService: memoryProjection,
        contradictionMemoryService: contradiction,
        currentProviderProvider: { provider },
        judgeLLMServiceFactory: { nil }
    )
    return ChatTurnRunner(
        conversationSessionStore: ConversationSessionStore(nodeStore: nodeStore),
        turnPlanner: planner,
        turnExecutor: TurnExecutor(
            llmServiceProvider: { StaticStreamingLLMService(text: singleShotText) },
            shouldUseGeminiHistoryCache: { false },
            shouldPersistAssistantThinking: { true }
        ),
        agentLoopExecutorFactory: agentLoopExecutorFactory,
        outcomeFactory: TurnOutcomeFactory(shouldPersistMemory: { _, _ in false })
    )
}

private func makeRunnerRequest(mode: QuickActionMode) -> TurnRequest {
    TurnRequest(
        turnId: UUID(),
        snapshot: TurnSessionSnapshot(
            currentNode: nil,
            messages: [],
            defaultProjectId: nil,
            activeChatMode: nil,
            activeQuickActionMode: mode
        ),
        inputText: "Need help choosing next step",
        attachments: [],
        now: Date()
    )
}

private func makeAgentLoopPlan(
    turnId: UUID,
    node: NousNode,
    userMessage: Message
) -> TurnPlan {
    TurnPlan(
        turnId: turnId,
        prepared: PreparedConversationTurn(
            node: node,
            userMessage: userMessage,
            messagesAfterUserAppend: [userMessage]
        ),
        citations: [],
        promptTrace: PromptGovernanceTrace(
            promptLayers: [],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false
        ),
        effectiveMode: .strategist,
        nextQuickActionModeIfCompleted: nil,
        judgeEventDraft: nil,
        turnSlice: TurnSystemSlice(stable: "stable", volatile: "volatile"),
        transcriptMessages: [
            LLMMessage(role: "user", content: userMessage.content)
        ],
        focusBlock: nil,
        provider: .openrouter
    )
}

private func makeAgentLoopRequest(
    turnId: UUID,
    node: NousNode,
    userMessage: Message
) -> TurnRequest {
    TurnRequest(
        turnId: turnId,
        snapshot: TurnSessionSnapshot(
            currentNode: node,
            messages: [],
            defaultProjectId: nil,
            activeChatMode: nil,
            activeQuickActionMode: nil
        ),
        inputText: userMessage.content,
        attachments: [],
        now: Date()
    )
}

private func makeAgentToolContext(
    node: NousNode,
    userMessage: Message
) -> AgentToolContext {
    AgentToolContext(
        conversationId: node.id,
        projectId: node.projectId,
        currentNodeId: node.id,
        currentMessage: userMessage.content,
        excludeNodeIds: [node.id],
        allowedReadNodeIds: [node.id],
        maxToolResultCharacters: 1200
    )
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw.", file: file, line: line)
    } catch {
        handler(error)
    }
}
