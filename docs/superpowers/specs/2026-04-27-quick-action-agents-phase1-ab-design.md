# Quick-Action Agents — Phase 1 (A+B): Tool Use + Multi-Step Reasoning Loop

**Date:** 2026-04-27
**Branch context:** Builds on `alexko0421/quick-action-agents` after L2.5 fix shipped (chat markdown structure design `2026-04-26-chat-markdown-structure-design.md` v5, codex round 5 PASS)
**Status:** Phase 1 of strict-AI-agent phased plan — A (tool use) + B (multi-step reasoning loop). Phase 2 (D = agent self-state) and Phase 3 (C = background follow-up) are explicitly out of scope.
**Spec version:** v1 (pre-codex review)

## Context

L2.5 (`alexko0421/quick-action-agents`, 4+ commits) shipped per-mode `QuickActionAgent` contracts (Direction / Brainstorm / Plan) with a 12-bool memory access policy and per-turn lifecycle hooks. The 2026-04-26 chat-markdown-structure follow-up made Plan mode produce a structured deliverable instead of degenerating into chat. Both shipped and were live-validated 2026-04-27 (memory `validation_chat_markdown_structure_shipped`).

L2.5 is "agent" only in the OOP-policy-bundle sense (a `QuickActionAgent` is an object that bundles per-mode behavior). It is NOT a modern AI agent — no tool use, no multi-step loop, no autonomous tool dispatch. Per the phased plan recorded in memory `project_strict_ai_agent_phased_plan` (2026-04-26), Alex committed to:

> Phase 1 (next session): A+B — modern AI agent baseline. ~1-2 weeks. Builds tool registry + execution loop on top of L2.5 contracts. Each agent (Direction / Brainstorm / Plan) becomes a tool-using multi-step loop.

Phase 1 implements that baseline.

Two of the three quick-action agents (Direction, Plan) become genuine multi-step tool-using agents. Brainstorm stays as the L2.5 single-shot mode for design reasons explained in Section D — its `.lean` memory policy intentionally strips personal memory to encourage novelty, and adding personal-memory tools would directly defeat that contract.

### Decision history (from 2026-04-27 brainstorming session)

Seven multiple-choice decisions locked the scope:

1. **Scope ambition**: B (Minimal viable agent) — 3-5 read-only tools + tool-call UI + cost cap. 1-2 weeks. Read-only tools deliver immediate user-facing value without write-side confirmation flow complexity.
2. **Tool list**: B (Standard, 5 tools) — `search_memory`, `recall_recent_conversations`, `find_contradictions`, `search_conversations_by_topic`, `read_note`. Excludes `query_user_model` and `query_essential_story` because they duplicate static memory injection from L2.5's `memoryPolicy` already-injected layers.
3. **Loop iteration cap**: B (8 iterations max + soft warn at 5) — covers `search → read multiple notes → synthesize` exploration. Hard termination injects a "FINAL: synthesize now, no more tool calls" turn (mirrors L2.5 `PlanAgent.finalUrgentAddendum` pattern).
4. **Tool call UI**: C (collapsible accordion) — fork/extend `ThinkingAccordion` pattern. Default collapsed, streaming auto-expand during execution, auto-collapse on completion. Click to re-expand for re-read.
5. **Architectural placement**: A (`AgentLoopExecutor` replaces `TurnExecutor` for agent-mode turns) — minimal disruption to L2.5 turn pipeline. `ChatTurnRunner` adds one if-branch; new file `AgentLoopExecutor.swift`; `TurnExecutor` and `TurnPlanner` untouched.
6. **Per-mode tool sets**: A (Direction + Plan get all 5 tools; Brainstorm stays L2.5 single-shot) — honors `BrainstormAgent`'s explicit bias-prevention contract. Phase 1's "agent loop" applies to two modes, not three.
7. **Provider strategy**: A (Pin Sonnet 4.6 / OpenRouter only) — current foreground default. Other providers fall back to L2.5 single-shot. Provider abstraction deferred to Phase 2 D.

## Goals

- **Direction and Plan modes** become multi-step tool-using agents. Each user message in these modes can spawn 1-8 internal LLM calls plus tool executions before producing the visible reply.
- **Five read-only tools** are available to the agent: `search_memory`, `recall_recent_conversations`, `find_contradictions`, `search_conversations_by_topic`, `read_note`. Each is a thin wrapper around an existing memory/store service — no new infrastructure.
- **Loop hard cap of 8 iterations**. At cap, dispatcher injects a forced final-synthesis turn (no more tool calls) and exits the loop. Prevents runaway loops, mirrors L2.5 `PlanAgent` cap pattern.
- **Tool-call UI surface** (`AgentTraceAccordion`) shows the agent's tool trace in a collapsible block above the assistant message. Streams during execution; collapses after. Persists across renders so users can re-read what the agent looked at.
- **Brainstorm mode unchanged**. Keeps L2.5 single-shot behavior, lean memory policy, bullet-hybrid format.
- **Default chat mode unchanged**. Single-shot via existing `TurnExecutor`. No agent loop, no tools.
- **Provider strategy**: agent loop only runs on Sonnet 4.6 (OpenRouter). If user switches to Gemini or Claude direct, agent-mode turns silently fall back to L2.5 single-shot.

## Non-goals

- **Phase 2 D (agent self-state)** — cross-turn agent memory ("what I tried, what worked"). Phase 1 loops are within a single user turn; no persisted agent-state between turns beyond what L2.5 already provides via `ConversationSessionStore`.
- **Phase 3 C (background follow-up)** — independent product decision, deferred.
- **Write-side tools** — `save_reflection`, `update_essential_story`, scratchpad mutations, etc. Read-only tools deliver value without the confirmation-flow complexity of side effects.
- **Provider abstraction beyond Sonnet 4.6** — adapter for Anthropic Messages API + Gemini function calling defers to Phase 2 D.
- **Web search / external API tools** — Nous's value is grounding in *Alex's* memory, not the open web. Web tools shift the product surface significantly.
- **User confirmation flows** — out of scope because read-only tools don't need them.
- **Tool composition / agent-of-agents** — single-level agent loop only.
- **Editing the live agent loop UX during a turn** (e.g. cancel mid-loop, re-run, branch) — Phase 1 ships a complete-or-fail loop. Cancellation falls under existing `Task.cancel` semantics, no special UI.
- **Editing `anchor.md`** — frozen per `AGENTS.md:39, 131`, per memory `project_anchor_is_frozen`.

## Design

### A. Tool registry + 5 tool implementations

#### A.1 `AgentTool` protocol

New file: `Sources/Nous/Models/Agents/AgentTool.swift`

```swift
import Foundation

/// One tool an agent can call during a multi-step loop.
/// Each tool wraps an existing read-only service. Phase 1 has no write tools.
protocol AgentTool {
    /// Stable name. Used as the tool identifier in LLM tool-use calls.
    /// Snake_case to match OpenAI function-calling convention.
    var name: String { get }

    /// One-line description for the LLM (used in the tool declaration).
    /// Should describe WHAT the tool does and WHEN to use it.
    var description: String { get }

    /// JSON-Schema-shaped input description. Phase 1 supports object schemas with
    /// string and integer property types only. Nested objects, arrays, and unions
    /// deferred to a later phase.
    var inputSchema: AgentToolSchema { get }

    /// Execute the tool. The framework parses LLM-provided arguments into
    /// `AgentToolInput`, calls this method, and serializes the result for the
    /// next LLM iteration. Errors thrown here become `is_error: true` tool
    /// results passed back to the LLM, which decides how to recover.
    func execute(input: AgentToolInput) async throws -> AgentToolResult
}

/// JSON-Schema subset.
struct AgentToolSchema: Codable, Equatable {
    let type: String                  // "object"
    let properties: [String: Property]
    let required: [String]

    struct Property: Codable, Equatable {
        let type: String              // "string" | "integer"
        let description: String
    }
}

/// Tool input — parsed from LLM-provided arguments JSON. Use string/integer
/// access methods rather than free-form Codable to keep the surface small.
struct AgentToolInput {
    private let raw: [String: Any]

    init(raw: [String: Any]) { self.raw = raw }

    func string(_ key: String) -> String? { raw[key] as? String }
    func integer(_ key: String) -> Int? { raw[key] as? Int }
}

/// Tool result — serialized into the tool_result content for the next LLM
/// iteration. `summary` is what the LLM sees verbatim. `traceContent` is what
/// the user-visible accordion displays (typically the same as summary, but can
/// be more user-friendly).
struct AgentToolResult: Equatable {
    let summary: String
    let traceContent: String
}
```

#### A.2 Five tool implementations

Each tool lives in `Sources/Nous/Models/Agents/Tools/<ToolName>Tool.swift`. Constructors take the existing service dependencies (NodeStore, MemoryProjectionService, etc.) so unit tests can inject in-memory fakes.

**`SearchMemoryTool`** — wraps `MemoryProjectionService.search`-style query over `memory_entries`.

```swift
struct SearchMemoryTool: AgentTool {
    let name = "search_memory"
    let description = """
    Search Alex's memory entries (preferences, facts, identity, story bits) by \
    keyword or theme. Returns up to 5 most relevant entries with content snippets. \
    Use when you need to ground an answer in what Alex has said before about a topic.
    """
    let inputSchema = AgentToolSchema(
        type: "object",
        properties: [
            "query": .init(type: "string", description: "Search query — keyword, phrase, or theme."),
            "limit": .init(type: "integer", description: "Max results (1-10, default 5).")
        ],
        required: ["query"]
    )

    let memoryService: MemoryProjectionService

    func execute(input: AgentToolInput) async throws -> AgentToolResult {
        guard let query = input.string("query") else {
            throw AgentToolError.missingArgument("query")
        }
        let limit = input.integer("limit").map { max(1, min($0, 10)) } ?? 5
        let results = try await memoryService.searchMemoryEntries(query: query, limit: limit)
        // Format as compact text. Each result: "[scope/kind] content snippet (sourceTitle)"
        let summary = results.isEmpty
            ? "No memory entries matched."
            : results.map { "[\($0.scope.rawValue)/\($0.kind.rawValue)] \($0.snippet)" }
                     .joined(separator: "\n")
        return AgentToolResult(
            summary: summary,
            traceContent: "search_memory(query: \"\(query)\") → \(results.count) result\(results.count == 1 ? "" : "s")"
        )
    }
}
```

**`RecallRecentConversationsTool`** — wraps `NodeStore.fetchRecentConversationMemories`.

```swift
struct RecallRecentConversationsTool: AgentTool {
    let name = "recall_recent_conversations"
    let description = """
    Recall Alex's most recent N conversations with their titles and short memory \
    summaries. Use when the current question would benefit from continuity with \
    what Alex has been talking about lately.
    """
    let inputSchema = AgentToolSchema(
        type: "object",
        properties: [
            "limit": .init(type: "integer", description: "Number of recent conversations (1-10, default 5).")
        ],
        required: []
    )

    let nodeStore: NodeStore

    func execute(input: AgentToolInput) async throws -> AgentToolResult {
        let limit = input.integer("limit").map { max(1, min($0, 10)) } ?? 5
        let conversations = try nodeStore.fetchRecentConversationMemories(limit: limit)
        let summary = conversations.isEmpty
            ? "No recent conversations."
            : conversations.map { "\"\($0.title)\": \($0.memory)" }.joined(separator: "\n\n")
        return AgentToolResult(
            summary: summary,
            traceContent: "recall_recent_conversations(limit: \(limit)) → \(conversations.count) conversation\(conversations.count == 1 ? "" : "s")"
        )
    }
}
```

**`FindContradictionsTool`** — wraps `ContradictionMemoryService.contradictionRecallFacts`.

```swift
struct FindContradictionsTool: AgentTool {
    let name = "find_contradictions"
    let description = """
    Find contradictions between Alex's current statements and previously-recorded \
    facts. Returns potentially-conflicting facts. Use when you suspect what Alex \
    is saying now contradicts something he said before.
    """
    let inputSchema = AgentToolSchema(
        type: "object",
        properties: [
            "topic": .init(type: "string", description: "Topic or claim to check for contradictions.")
        ],
        required: ["topic"]
    )

    let contradictionService: ContradictionMemoryService

    func execute(input: AgentToolInput) async throws -> AgentToolResult {
        guard let topic = input.string("topic") else {
            throw AgentToolError.missingArgument("topic")
        }
        let facts = try await contradictionService.contradictionRecallFacts(topic: topic)
        let summary = facts.isEmpty
            ? "No prior facts found that could contradict this."
            : facts.map { "- \($0.statement) (recorded \($0.recordedAt.shortDate))" }.joined(separator: "\n")
        return AgentToolResult(
            summary: summary,
            traceContent: "find_contradictions(topic: \"\(topic)\") → \(facts.count) potentially-conflicting fact\(facts.count == 1 ? "" : "s")"
        )
    }
}
```

**`SearchConversationsByTopicTool`** — wraps `VectorStore.search` filtered to `NousNode.type == .conversation`.

```swift
struct SearchConversationsByTopicTool: AgentTool {
    let name = "search_conversations_by_topic"
    let description = """
    Semantic-search Alex's past conversations by topic or theme. Returns \
    conversation titles and similarity scores. Use to discover cross-time \
    connections or find when Alex last discussed something similar. Pair with \
    read_note(id:) to get full content.
    """
    let inputSchema = AgentToolSchema(
        type: "object",
        properties: [
            "query": .init(type: "string", description: "Topic or theme to search for."),
            "limit": .init(type: "integer", description: "Max results (1-10, default 5).")
        ],
        required: ["query"]
    )

    let vectorStore: VectorStore
    let embeddingService: EmbeddingService

    func execute(input: AgentToolInput) async throws -> AgentToolResult {
        guard let query = input.string("query") else {
            throw AgentToolError.missingArgument("query")
        }
        let limit = input.integer("limit").map { max(1, min($0, 10)) } ?? 5
        let queryEmbedding = try await embeddingService.embed(query)
        let results = try vectorStore.search(query: queryEmbedding, topK: limit)
            .filter { $0.node.type == .conversation }
        let summary = results.isEmpty
            ? "No conversations matched."
            : results.map { "[\(Int($0.similarity * 100))%] \"\($0.node.title)\" (id: \($0.node.id))" }
                     .joined(separator: "\n")
        return AgentToolResult(
            summary: summary,
            traceContent: "search_conversations_by_topic(query: \"\(query)\") → \(results.count) hit\(results.count == 1 ? "" : "s")"
        )
    }
}
```

**`ReadNoteTool`** — wraps `NodeStore.fetchNode(id:)`.

```swift
struct ReadNoteTool: AgentTool {
    let name = "read_note"
    let description = """
    Read the full content of a specific note or conversation by id. Pair with \
    search_conversations_by_topic or search_memory which return ids.
    """
    let inputSchema = AgentToolSchema(
        type: "object",
        properties: [
            "id": .init(type: "string", description: "Node id (UUID string).")
        ],
        required: ["id"]
    )

    let nodeStore: NodeStore

    func execute(input: AgentToolInput) async throws -> AgentToolResult {
        guard let idString = input.string("id"),
              let id = UUID(uuidString: idString) else {
            throw AgentToolError.invalidArgument("id (expected UUID string)")
        }
        guard let node = try nodeStore.fetchNode(id: id) else {
            return AgentToolResult(
                summary: "Note not found.",
                traceContent: "read_note(id: \"\(idString)\") → not found"
            )
        }
        // Truncate at ~2000 chars to keep tool result bounded.
        let content = node.content?.prefix(2000) ?? ""
        let truncated = (node.content?.count ?? 0) > 2000 ? "...[truncated]" : ""
        let summary = "Title: \(node.title)\n\nContent:\n\(content)\(truncated)"
        return AgentToolResult(
            summary: summary,
            traceContent: "read_note(id: \"\(idString)\") → \"\(node.title)\""
        )
    }
}
```

#### A.3 Tool registry

New file: `Sources/Nous/Models/Agents/AgentToolRegistry.swift`

```swift
final class AgentToolRegistry {
    private let tools: [String: AgentTool]

    init(tools: [AgentTool]) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    func tool(named name: String) -> AgentTool? {
        tools[name]
    }

    /// Filter to a subset by name. Used for per-mode tool sets.
    func subset(_ names: [String]) -> AgentToolRegistry {
        AgentToolRegistry(tools: names.compactMap { tools[$0] })
    }

    /// Tool declarations for an LLM tool-use call (provider-specific encoding
    /// happens at the `LLMService` boundary).
    var declarations: [AgentToolDeclaration] {
        tools.values.map {
            AgentToolDeclaration(
                name: $0.name,
                description: $0.description,
                inputSchema: $0.inputSchema
            )
        }
    }
}

struct AgentToolDeclaration: Equatable {
    let name: String
    let description: String
    let inputSchema: AgentToolSchema
}

enum AgentToolError: Error, LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)
    case toolNotFound(String)
    case timeout(String, Double)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name): return "Missing required argument: \(name)"
        case .invalidArgument(let name): return "Invalid argument: \(name)"
        case .toolNotFound(let name): return "Tool not found: \(name)"
        case .timeout(let name, let seconds): return "Tool \(name) exceeded \(seconds)s timeout"
        }
    }
}
```

### B. `AgentLoopExecutor` — loop body, termination, cap, error handling

New file: `Sources/Nous/Services/AgentLoopExecutor.swift`

```swift
final class AgentLoopExecutor {
    private let llmService: LLMService
    private let registry: AgentToolRegistry
    private let perToolTimeoutSeconds: Double = 5.0
    private let totalTurnTimeoutSeconds: Double = 60.0
    static let maxIterations = 8

    init(llmService: LLMService, registry: AgentToolRegistry) {
        self.llmService = llmService
        self.registry = registry
    }

    /// Execute a tool-using multi-step loop. Returns the final assistant text plus
    /// the trace for UI display. The caller (ChatTurnRunner) is responsible for
    /// committing the result via existing turn-commit logic.
    func execute(
        context: TurnSystemSlice,
        history: [Message],
        userMessage: String,
        traceObserver: AgentTraceObserver
    ) async throws -> AgentLoopResult {
        guard llmService.supportsToolUse else {
            throw AgentLoopError.providerUnsupported
        }

        let deadline = Date().addingTimeInterval(totalTurnTimeoutSeconds)
        var conversation = AgentLoopConversation(
            system: context.combined,
            history: history,
            userMessage: userMessage
        )

        for iter in 0..<Self.maxIterations {
            if Date() > deadline {
                throw AgentLoopError.totalTimeout(totalTurnTimeoutSeconds)
            }

            traceObserver.emit(.iterationStarted(iter))

            let response = try await llmService.callWithTools(
                system: conversation.system,
                messages: conversation.messages,
                tools: registry.declarations
            )

            traceObserver.emit(.iterationCompleted(iter, response.toolUses.isEmpty ? .text(response.text) : .toolUses(response.toolUses)))

            if response.toolUses.isEmpty {
                // Normal termination — final text response.
                return AgentLoopResult(
                    text: response.text,
                    iterations: iter + 1,
                    completedNormally: true
                )
            }

            for toolUse in response.toolUses {
                guard let tool = registry.tool(named: toolUse.name) else {
                    let error = AgentToolError.toolNotFound(toolUse.name)
                    conversation.appendToolError(toolUseId: toolUse.id, error: error)
                    traceObserver.emit(.toolError(toolUse.name, error))
                    continue
                }
                do {
                    let result = try await withTimeout(seconds: perToolTimeoutSeconds, name: toolUse.name) {
                        try await tool.execute(input: AgentToolInput(raw: toolUse.input))
                    }
                    conversation.appendToolResult(toolUseId: toolUse.id, result: result)
                    traceObserver.emit(.toolCompleted(toolUse.name, result))
                } catch {
                    conversation.appendToolError(toolUseId: toolUse.id, error: error)
                    traceObserver.emit(.toolError(toolUse.name, error))
                }
            }
        }

        // Cap reached — force final synthesis.
        traceObserver.emit(.capReached(Self.maxIterations))
        let finalResponse = try await llmService.callWithTools(
            system: conversation.system + "\n\nFINAL: synthesize now using whatever tool results you have. Do not call any more tools.",
            messages: conversation.messages,
            tools: []  // no tools available — force text response
        )
        traceObserver.emit(.forcedFinal(finalResponse.text))
        return AgentLoopResult(
            text: finalResponse.text,
            iterations: Self.maxIterations,
            completedNormally: false
        )
    }

    private func withTimeout<T>(seconds: Double, name: String, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AgentToolError.timeout(name, seconds)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

struct AgentLoopResult {
    let text: String
    let iterations: Int
    let completedNormally: Bool  // false = cap-forced final synthesis
}

enum AgentLoopError: Error {
    case providerUnsupported
    case totalTimeout(Double)
}

/// Conversation-state accumulator across loop iterations. Tracks the running
/// message list including tool_use blocks and tool_result blocks.
struct AgentLoopConversation {
    let system: String
    var messages: [LLMMessage]  // role-tagged messages, includes tool_use/tool_result content blocks

    init(system: String, history: [Message], userMessage: String) {
        self.system = system
        self.messages = history.map(LLMMessage.init(from:)) + [LLMMessage(role: .user, content: .text(userMessage))]
    }

    mutating func appendToolResult(toolUseId: String, result: AgentToolResult) {
        // Implementation: append assistant message with tool_use, then user
        // message with tool_result block referencing toolUseId. Exact shape
        // depends on the LLMMessage type (see LLMService notes below).
    }

    mutating func appendToolError(toolUseId: String, error: Error) {
        // Same shape as appendToolResult but with is_error = true and error
        // description as the result content.
    }
}
```

#### B.1 Trace observer

```swift
protocol AgentTraceObserver: AnyObject {
    func emit(_ event: AgentTraceEvent)
}

enum AgentTraceEvent {
    case iterationStarted(Int)
    case iterationCompleted(Int, IterationOutcome)
    case toolCompleted(String, AgentToolResult)
    case toolError(String, Error)
    case capReached(Int)
    case forcedFinal(String)

    enum IterationOutcome {
        case text(String)
        case toolUses([ToolUseRequest])
    }

    struct ToolUseRequest: Equatable {
        let id: String
        let name: String
        let input: [String: Any]  // serialize-as-JSON for trace storage

        // Equatable comparison serializes input via JSONSerialization.
        static func == (lhs: ToolUseRequest, rhs: ToolUseRequest) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name &&
                NSDictionary(dictionary: lhs.input).isEqual(to: rhs.input)
        }
    }
}
```

The trace observer collects events for two purposes: (1) live UI updates via `Combine` publisher, (2) persistence of the final trace as JSON in a new `Message.agent_trace_json` column.

### C. `LLMService.callWithTools` — provider boundary

`Sources/Nous/Services/LLMService.swift` (existing) gains:

```swift
protocol LLMService {
    // ... existing methods ...

    /// True if this provider supports tool-use in Phase 1. Sonnet 4.6 via OpenRouter
    /// returns true; Gemini and direct Claude return false.
    var supportsToolUse: Bool { get }

    /// Call the model with tool declarations available. The response may contain
    /// tool_use blocks (LLM wants to call tools) or text (final answer).
    /// If `tools` is empty, the model cannot call tools — used by the cap-reached
    /// final-synthesis turn.
    func callWithTools(
        system: String,
        messages: [LLMMessage],
        tools: [AgentToolDeclaration]
    ) async throws -> LLMToolUseResponse
}

struct LLMToolUseResponse: Equatable {
    let text: String                                  // text content blocks concatenated; empty if tool-use only
    let toolUses: [AgentTraceEvent.ToolUseRequest]    // tool_use blocks; empty if final text response
}
```

`OpenRouterSonnet46Service.callWithTools` translates:
- `AgentToolDeclaration` → OpenAI-format `{type: 'function', function: {name, description, parameters: inputSchema}}`
- LLM response `tool_calls` → `[ToolUseRequest]`
- Final text content → `text`

`GeminiService.callWithTools` and `ClaudeService.callWithTools` (if exist) throw `AgentLoopError.providerUnsupported` so the caller can fall back.

### D. `ChatTurnRunner` integration + per-mode setup

#### D.1 `ChatTurnRunner.run` adds an agent-loop branch

```swift
// Existing code (simplified):
func run(turnRequest: TurnRequest) async throws -> CommittedAssistantTurn {
    let plan = try await planner.plan(turnRequest)
    let outcome = try await executor.execute(plan)
    return commit(outcome)
}

// After Phase 1:
func run(turnRequest: TurnRequest) async throws -> CommittedAssistantTurn {
    let plan = try await planner.plan(turnRequest)

    if let activeAgent = turnRequest.activeQuickActionAgent,
       activeAgent.useAgentLoop,
       llmService.supportsToolUse {
        do {
            let registry = makeRegistry(forAgent: activeAgent)
            let loopExecutor = AgentLoopExecutor(llmService: llmService, registry: registry)
            let loopResult = try await loopExecutor.execute(
                context: plan.systemSlice,
                history: turnRequest.history,
                userMessage: turnRequest.userMessage,
                traceObserver: traceCollector
            )
            return commit(loopResult, trace: traceCollector.events)
        } catch AgentLoopError.providerUnsupported {
            // Should never reach here because of the guard above, but defensive.
            // Fall through to single-shot.
        }
    }

    let outcome = try await executor.execute(plan)
    return commit(outcome)
}
```

The guard `llmService.supportsToolUse` short-circuits to single-shot if the user is on Gemini / Claude direct.

`makeRegistry(forAgent:)` reads the agent's `tools` array and constructs an `AgentToolRegistry` filtered to those tool names.

#### D.2 `QuickActionAgent` protocol gains tool surface

`Sources/Nous/Models/Agents/QuickActionAgent.swift`:

```swift
protocol QuickActionAgent {
    var mode: QuickActionMode { get }
    func openingPrompt() -> String
    func contextAddendum(turnIndex: Int) -> String?
    func memoryPolicy() -> QuickActionMemoryPolicy
    func turnDirective(parsed: ClarificationContent, turnIndex: Int) -> QuickActionTurnDirective

    // NEW in Phase 1:
    var toolNames: [String] { get }      // empty → single-shot (Brainstorm)
    var useAgentLoop: Bool { get }       // computed from toolNames.isEmpty
}

extension QuickActionAgent {
    var useAgentLoop: Bool { !toolNames.isEmpty }
}
```

Per-mode tool sets:

```swift
// DirectionAgent.swift:
var toolNames: [String] {
    [
        "search_memory",
        "recall_recent_conversations",
        "find_contradictions",
        "search_conversations_by_topic",
        "read_note"
    ]
}

// PlanAgent.swift:
var toolNames: [String] { /* same 5 */ }

// BrainstormAgent.swift:
var toolNames: [String] { [] }  // explicit single-shot per memory-policy contract
```

`memoryPolicy()` and `contextAddendum()` are unchanged from L2.5 + chat-markdown-structure ship. Plan's cap-aware switch (turn 4+ → finalUrgentAddendum) coexists cleanly with the agent loop because the addendum is part of the *system* prompt at loop start; the loop's iteration cap is independent.

### E. Tool trace UI — `AgentTraceAccordion`

New file: `Sources/Nous/Views/AgentTraceAccordion.swift`

Forked from `ThinkingAccordion` pattern (same file, similar API) rather than extending `ThinkingAccordion` because the two surfaces serve different conceptual purposes (LLM internal reasoning vs external action trace) and dedup risks coupling.

```swift
struct AgentTraceAccordion: View {
    let trace: [AgentTraceEvent]
    let isStreaming: Bool

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if isExpanded || isStreaming {
                content.transition(.opacity)
            }
        }
        .onChange(of: isStreaming) { _, newValue in
            // Auto-expand while streaming, auto-collapse when done.
            withAnimation { isExpanded = newValue }
        }
    }

    private var header: some View {
        Button(action: { withAnimation { isExpanded.toggle() } }) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                Text(headerLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.6))
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private var headerLabel: String {
        let toolEvents = trace.compactMap {
            if case .toolCompleted = $0 { return $0 } else { return nil }
        }
        if isStreaming {
            return "Nous is searching..."
        }
        return "Nous searched \(toolEvents.count) source\(toolEvents.count == 1 ? "" : "s")"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(trace.enumerated()), id: \.offset) { _, event in
                traceLine(event)
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func traceLine(_ event: AgentTraceEvent) -> some View {
        switch event {
        case .toolCompleted(_, let result):
            HStack(alignment: .top, spacing: 6) {
                Text("→")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.4))
                Text(result.traceContent)
                    .font(.system(size: 12))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.8))
            }
        case .toolError(let name, let error):
            HStack(alignment: .top, spacing: 6) {
                Text("⚠")
                    .font(.system(size: 12))
                    .foregroundColor(AppColor.colaOrange)
                Text("\(name): \(error.localizedDescription)")
                    .font(.system(size: 12))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.6))
            }
        case .capReached(let n):
            Text("Reached iteration cap (\(n)) — synthesizing final answer.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppColor.colaOrange)
        case .iterationStarted, .iterationCompleted, .forcedFinal:
            EmptyView()  // not user-facing trace lines; iteration framing is internal
        }
    }
}
```

`MessageBubble` (`Sources/Nous/Views/ChatArea.swift:551+`) gains an agent-trace section above the markdown body for assistant messages with traces:

```swift
} else {
    HStack {
        VStack(alignment: .leading, spacing: 4) {
            if let trace = message.agentTrace, !trace.isEmpty {
                AgentTraceAccordion(trace: trace, isStreaming: message.isStreaming)
            }
            AssistantBubbleContent(displayText: assistantDisplayText)
        }
        Spacer(minLength: 0)
    }
}
```

#### E.1 Persistence

`Message` model (`Sources/Nous/Models/Message.swift`) gains:

```swift
struct Message {
    // ... existing fields ...
    let agentTraceJson: String?   // JSON-encoded [AgentTraceEvent], nil for non-agent messages
}
```

NodeStore schema migration adds column `agent_trace_json TEXT` to the `messages` table. (Migration in `MemoryV2Migrator` style or a new V3 migrator if needed — implementation detail decided during writing-plans.)

The trace JSON is read back at render time, decoded into `[AgentTraceEvent]`, and passed to `AgentTraceAccordion`.

### F. Provider strategy — Sonnet 4.6 only

`OpenRouterSonnet46Service` (or whatever the current Sonnet-on-OpenRouter service is named — verify during implementation) implements `callWithTools` with full tool-use semantics.

`GeminiService.callWithTools` and `ClaudeService.callWithTools` (if they exist as separate services) return immediately:

```swift
extension GeminiService: LLMService {
    var supportsToolUse: Bool { false }

    func callWithTools(...) async throws -> LLMToolUseResponse {
        throw AgentLoopError.providerUnsupported
    }
}
```

`ChatTurnRunner.run` checks `llmService.supportsToolUse` BEFORE constructing the loop executor. If false, falls through to L2.5 single-shot path. User sees no error — Direction / Plan act as before L2.5 fix (single-shot reply, mode-specific addendum still applied).

If user switches provider mid-conversation, currently-running turns continue under the previous provider until completion (existing behavior); new turns route per the new `supportsToolUse` value.

### G. Validation plan

#### Unit tests

Each test file lives in `Tests/NousTests/`.

- **Per-tool tests** (5 files: `SearchMemoryToolTests.swift`, etc.):
  - Schema validation: `inputSchema` matches the spec (object type, properties, required).
  - Execution: against in-memory `NodeStore` / `MemoryProjectionService` fakes, verify result content matches expected.
  - Error path: missing required arg → `AgentToolError.missingArgument`. Invalid arg type → `AgentToolError.invalidArgument`.
  - Edge: empty result set returns `summary: "No ... matched."` deterministically.

- **`AgentToolRegistryTests.swift`**:
  - Registration of multiple tools by name.
  - `subset(_:)` filters to named tools only.
  - `tool(named:)` returns nil for unknown name.
  - `declarations` returns one entry per registered tool.

- **`AgentLoopExecutorTests.swift`**:
  - Normal termination: LLM returns text on iteration 0 → executor returns (text, 1, normal=true).
  - Tool dispatch: LLM returns tool_use → executor runs tool → result is appended → next iteration.
  - Iteration cap: 8 iterations of tool_use → 9th call has empty tools, forced synthesis → result.completedNormally == false.
  - Tool error propagation: tool throws → conversation appends `is_error: true` block → LLM next call sees the error → can recover or continue.
  - Tool not found: LLM requests unknown tool → conversation appends error → LLM continues.
  - Per-tool timeout: tool that hangs > 5s → `AgentToolError.timeout` → trace has `.toolError`.
  - Total turn timeout: tool that succeeds but loop runs > 60s → `AgentLoopError.totalTimeout` thrown.
  - Provider unsupported: LLM service `supportsToolUse == false` → `AgentLoopError.providerUnsupported` thrown immediately.

- **`AgentTraceAccordionTests.swift`**:
  - JSON encode/decode roundtrip for `[AgentTraceEvent]`.
  - Trace lines for `.toolCompleted` / `.toolError` / `.capReached` render correct content.
  - `.iterationStarted` / `.iterationCompleted` / `.forcedFinal` render `EmptyView` (not user-facing).

- **`QuickActionAgentToolNamesTests.swift`** (extend existing `QuickActionAgentsTests`):
  - `DirectionAgent.toolNames == [5 tools]`, `useAgentLoop == true`.
  - `PlanAgent.toolNames == [5 tools]`, `useAgentLoop == true`.
  - `BrainstormAgent.toolNames == []`, `useAgentLoop == false`.

- **`ChatTurnRunnerAgentLoopTests.swift`**:
  - Active Direction agent + Sonnet 4.6 → routes to `AgentLoopExecutor`.
  - Active Brainstorm agent → routes to single-shot `TurnExecutor`.
  - Active Plan agent + Gemini provider → routes to single-shot (`supportsToolUse == false` fallback).
  - No active agent → routes to single-shot.

#### Manual live tests (macOS app)

After all unit tests pass and the app builds:

1. **Direction agent loop — basic**: Open fresh chat, click Direction, ask "我 startup 应该 pivot 边度？". Verify trace accordion appears above the assistant reply showing tool calls (e.g. `search_memory(query: "pivot")` → 3 results, `recall_recent_conversations` → 5 conversations). Trace auto-expands during streaming, auto-collapses on completion. Click to re-expand and read.

2. **Plan agent loop — multi-step**: Open fresh chat, click Plan, ask "我想 ship 个 feature 但担心 timing". Continue answering for 2-3 turns. Verify Plan eventually calls `find_contradictions(topic: "shipping timing")` and `search_memory(query: "ship velocity")` — trace shows both. Final reply uses the tool results in the structured plan output.

3. **Plan cap-reached force-synthesis**: Construct a query that would plausibly trigger 8 iterations (deeply iterative search). Verify cap triggers, trace shows `Reached iteration cap (8) — synthesizing final answer.`, and final reply still arrives within the 60s total-timeout budget.

4. **Brainstorm unchanged**: Open fresh chat, click Brainstorm, ask anything. Verify NO trace accordion appears, response arrives as a single shot. Output format matches the L2.5 ship (bullet+tradeoff + non-bullet judgment prose).

5. **Provider fallback**: In Settings, switch provider to Gemini (or whatever non-Sonnet is configured). Open fresh Direction chat, ask anything. Verify response arrives as a single shot (no trace accordion), no error or hang. Switch back to Sonnet 4.6 and verify the loop returns.

6. **Trace UI streaming**: During a long Plan loop (provoke 5+ iterations), watch the accordion live-stream tool calls. Each `.toolCompleted` event should append a new line. Header text updates from "Nous is searching..." to "Nous searched N sources".

7. **Tool error visibility**: Trigger a tool error (e.g. `read_note(id: "non-existent-uuid")`). Verify the trace shows `⚠ read_note: Note not found.` (or similar) and the LLM continues / synthesizes despite the error.

8. **Default chat unchanged**: Open new chat WITHOUT clicking any quick action. Ask any question. Verify NO trace accordion, single-shot response, identical to pre-Phase-1 behavior.

#### Cost / latency observation

After live tests pass, capture metrics from the trace JSON for ~10 real Direction + Plan turns:
- Median iterations per turn: target ≤ 3
- 95th percentile: target ≤ 6
- Mean wall-clock latency: target ≤ 15s
- Cap-hit rate: target < 5% of turns

If observed metrics significantly exceed targets, escalate to a v2 spec (reduce default cap, tighten tool descriptions, etc.).

### H. Out of scope (explicit deferrals)

- **Phase 2 D — agent self-state across turns**: cross-turn memory of "what I tried, what worked, what didn't." Phase 1 loops are isolated per user turn; agents can't remember inside-loop discoveries beyond what L2.5 conversation history already captures.
- **Phase 3 C — background follow-up**: independent product decision, deferred per `project_strict_ai_agent_phased_plan`.
- **Write-side tools**: `save_reflection`, `update_essential_story`, scratchpad mutations, etc. Read-only first.
- **Provider abstraction beyond Sonnet 4.6**: Gemini and direct Claude tool-use deferred to Phase 2 D.
- **Web search / external API tools**: out of product scope for v1.
- **User confirmation flows**: not needed for read-only tools.
- **Tool composition / agent-of-agents**: single-level loop only.
- **Mid-loop UX (cancel, branch, re-run)**: complete-or-fail loops only. `Task.cancel` semantics handle hard cancellation.
- **`anchor.md` edits**: frozen.

## Risks

- **LLM tool-call compliance**: Sonnet 4.6 might choose not to call tools even when they would be useful. The L2.5 fix (memory `validation_chat_markdown_structure_shipped`) showed partial compliance is the norm. Mitigation: tool descriptions emphasize WHEN to use; `contextAddendum` for Direction and Plan can encourage tool use ("ground your answer in Alex's memory by searching first"). Live test 1+2 will reveal compliance rate. If poor, escalate to a stronger system instruction in v2.
- **Trace accordion clutter**: every Direction / Plan reply now has an accordion header. Even collapsed, it's visual noise. Mitigation: only show when `trace.count > 0`. Verify in live test 1.
- **Tool latency**: per-tool timeout 5s is aggressive. If `MemoryProjectionService.search` is slow on a large `memory_entries` table, tools could time out. Mitigation: observe in live tests; expand timeout to 10s if widely tripped. Add an index on `memory_entries.scope` if search is the slow path.
- **JSON column migration**: adding `agent_trace_json` column to `messages` table is a schema change. Existing rows have NULL traces, which is correct (they're pre-Phase-1 messages). No data migration needed. Verify the migration path during writing-plans.
- **Streaming UX**: `AgentTraceAccordion` auto-expand during streaming requires the trace observer to publish events to SwiftUI. Implementation needs `@Published` or `Combine.Publisher` plumbing. If reactive updates are expensive, fall back to polling or per-iteration state pushes.
- **Context budget**: each loop iteration sends the full conversation including tool results. After 8 iterations, the prompt may be 30K+ tokens. Sonnet 4.6's context is 200K so we have headroom, but cost-per-turn could be 5-10× a single-shot. Acceptable for v1; observe in cost metrics.
- **Total turn timeout**: 60s is generous. If tools all complete fast and LLM is slow, a single-iteration call could approach the total timeout. Mitigation: per-iteration timeouts wrap the LLM call too (not just tool execution) — verify during implementation.
- **Mode interaction**: if a user switches mode mid-conversation (Plan → Direction), the agent loop in flight should complete before the next user turn picks up the new mode. Existing `Task.cancel` semantics on mode switch handle this; verify during live test.

## Open questions for codex review

These are things to flag for the codex review pass to scrutinize:

- Does the `LLMService.callWithTools` shape correctly model Anthropic's `content: [tool_use]` blocks AND OpenAI-format `tool_calls`? Both providers in scope (Sonnet 4.6 via OpenRouter speaks OpenAI format); Anthropic compat may not be needed for Phase 1, but the protocol shape should not preclude it.
- Is `AgentToolInput` (using `[String: Any]`) the right balance of flexibility vs type safety? Codable-based alternatives exist but require per-tool input types — high boilerplate.
- Per-tool timeout uses `withThrowingTaskGroup` racing against `Task.sleep`. Is there a cleaner Swift Concurrency pattern?
- `agent_trace_json` schema: store the full event stream verbatim? Or summarize down to user-visible lines only (`.toolCompleted`, `.toolError`, `.capReached`)? Trade-off: completeness vs storage.
- Should `BrainstormAgent.toolNames == []` use a sentinel `Optional<[String]>` instead, to make the intent ("no tools by design") more visible than empty array? The current empty-array shape is concise but reads as "tools just haven't been added yet."
- The `makeRegistry(forAgent:)` factory in `ChatTurnRunner` — where exactly does it live? `ChatTurnRunner` would need to know how to construct each tool with its dependencies. Probably better to inject a `AgentToolRegistry` factory at `ChatTurnRunner` init time.
