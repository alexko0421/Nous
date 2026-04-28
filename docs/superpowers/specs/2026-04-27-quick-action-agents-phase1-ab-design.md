# Quick-Action Agents — Phase 1 (A+B): Tool Use + Multi-Step Reasoning Loop

**Date:** 2026-04-27
**Branch context:** Builds on `alexko0421/quick-action-agents` after L2.5 fix shipped (chat markdown structure design `2026-04-26-chat-markdown-structure-design.md` v5, codex round 5 PASS)
**Status:** Phase 1 of strict-AI-agent phased plan — A (tool use) + B (multi-step reasoning loop). Phase 2 (D = agent self-state) and Phase 3 (C = background follow-up) are explicitly out of scope.
**Spec version:** v4 (post-codex round 4 PASS — no P0/P1/P2; incorporates final P3 lifecycle note)

### v4 post-pass note (codex round 4)

Codex round 4 scored v4 **9/10 PASS**. The review output is saved at `.context/codex-quick-action-agents-phase1-round4.txt`.

The only remaining finding was P3: `currentAgentTrace` must be cleared anywhere draft assistant UI state is reset outside normal turn events. Section E now includes that lifecycle rule.

### v4 changes from v3 (post-codex round 3)

Codex round 3 scored v3 **7/10 FAIL**. The review output is saved at `.context/codex-quick-action-agents-phase1-round3.txt`.

Fixes in v4:

1. **System prompt preserved in tool path**: OpenRouter tool calls prepend `{role:"system", content: system}` before the agent transcript, matching the existing `OpenRouterLLMService.generate` behavior.
2. **Search results no longer auto-authorize raw cross-scope reads**: `discoveredNodeIds` only includes source nodes that pass the raw-read boundary without using the discovered-id rule itself.
3. **Numeric tool limits are bounded**: every tool-owned `limit` is clamped before DB/vector calls, with negative/huge tests required.
4. **In-flight trace renders before final text**: `ChatArea` must show the assistant bubble when `currentAgentTrace` is non-empty.
5. **Shared title normalization covers quick-action opening**: the helper also replaces duplicate `ChatViewModel` quick-action opening normalization.

### v3 changes from v2 (post-codex round 2)

Codex round 2 scored v2 **7/10 FAIL**. The review output is saved at `.context/codex-quick-action-agents-phase1-round2.txt`.

Fixes in v3:

1. **`read_note` nil-project leak closed**: optional project equality never authorizes reads. Same-project reads require both `context.projectId` and `node.projectId` to be non-nil and equal.
2. **OpenRouter wire shape made concrete**: `AgentToolDeclaration` / `AgentToolSchema` are specified, and every tool-loop request includes `tools` plus `tool_choice: "auto"` or `"none"`.
3. **Cancellation matches current runner semantics**: `AgentLoopExecutor.execute` returns `TurnExecutionResult?` and returns `nil` for cancellation, mirroring `TurnExecutor`.
4. **Assistant normalization is shared**: `<chat_title>` stripping and title sanitization move into a reusable helper so agent and non-agent turns cannot drift.
5. **Search discovery is explicit**: `search_conversations_by_topic` adds matched conversation ids to `discoveredNodeIds` so `search -> read_note` works.
6. **Trace model naming clarified**: storage is raw `Message.agentTraceJson`; decoding uses `AgentTraceCodec` / `message.decodedAgentTraceRecords`.

### v2 changes from v1 (post-codex round 1)

Codex round 1 scored v1 **4/10 FAIL**. The review output is saved at `.context/codex-quick-action-agents-phase1-round1.txt`.

Fixes in v2:

1. **Tool transcript model made concrete**: existing `LLMMessage` stays text-only for the single-shot path; Phase 1 adds `AgentLoopMessage` / `AgentToolCall` / `AgentToolLLMResponse` for OpenRouter tool transcripts.
2. **OpenAI/OpenRouter sequencing corrected**: assistant messages with `tool_calls` are preserved, then `role: "tool"` messages with `tool_call_id` are appended. No fake user `tool_result` blocks.
3. **Real `ChatTurnRunner` seam used**: the branch is inserted after `TurnPlan` + `.prepared` emission and before `TurnExecutor.execute(plan:sink:)`; `AgentLoopExecutor` returns `TurnExecutionResult` so existing commit flow remains.
4. **Tool APIs grounded in current services**: v1 references to nonexistent memory-search and topic-only contradiction APIs are replaced with small read protocols backed by `NodeStore`, `UserMemoryService`, `ContradictionMemoryService`, `VectorStore`, and `EmbeddingService`.
5. **Tool context added**: each tool receives `AgentToolContext` with `projectId`, `conversationId`, `currentMessage`, exclusion IDs, allowed read IDs, and output budget.
6. **Trace persistence made Codable**: runtime `Error` / `[String: Any]` events are not persisted. The UI stores `[AgentTraceRecord]` with JSON strings and error descriptions.
7. **Live trace UI wired to current streaming state**: adds `TurnEvent.agentTraceDelta`, `ChatViewModel.currentAgentTrace`, and persisted `Message.agentTraceJson`.
8. **Timeouts wrap LLM calls too**: the total 60s deadline is enforced around both provider calls and tool execution.
9. **Provider gate narrowed**: tool loop runs only for `LLMProvider.openrouter` with model id `anthropic/claude-sonnet-4.6`.
10. **Tests adjusted to current constraints**: no SwiftUI inspection dependency; trace rendering tests are pure formatting/unit tests plus manual QA.

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
7. **Provider strategy**: A (Pin Sonnet 4.6 / OpenRouter only) — the Phase 1 target provider/model. The app currently defaults to Gemini, so users must select OpenRouter Sonnet 4.6 before the loop activates. Other providers fall back to L2.5 single-shot. Provider abstraction deferred to Phase 2 D.

## Goals

- **Direction and Plan modes** become multi-step tool-using agents. Each user message in these modes can spawn 1-8 internal LLM calls plus tool executions before producing the visible reply.
- **Five read-only tools** are available to the agent: `search_memory`, `recall_recent_conversations`, `find_contradictions`, `search_conversations_by_topic`, `read_note`. Each wraps existing store/retrieval services, with only small read-only adapter methods where the current API is missing the exact query shape.
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

The implementation source of truth is v4 Sections A-F immediately below. The rejected v1/v2/v3 snippets were removed from this file to keep the implementation plan unambiguous; review findings live in `.context/codex-quick-action-agents-phase1-round1.txt`, `.context/codex-quick-action-agents-phase1-round2.txt`, and `.context/codex-quick-action-agents-phase1-round3.txt`.

### A. Tool contracts, context, and concrete read APIs

#### A.1 New files

- `Sources/Nous/Models/Agents/AgentTool.swift`
- `Sources/Nous/Models/Agents/AgentTraceRecord.swift`
- `Sources/Nous/Models/Agents/Tools/<ToolName>Tool.swift`
- `Sources/Nous/Services/AgentToolRegistry.swift`

`AgentTool` is read-only in Phase 1, but it is not context-free. Every tool call receives the same scoped context the normal RAG path already uses.

```swift
protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: AgentToolSchema { get }

    func execute(
        input: AgentToolInput,
        context: AgentToolContext
    ) async throws -> AgentToolResult
}

struct AgentToolContext: Equatable {
    let conversationId: UUID
    let projectId: UUID?
    let currentNodeId: UUID
    let currentMessage: String
    let excludeNodeIds: Set<UUID>
    let allowedReadNodeIds: Set<UUID>
    let maxToolResultCharacters: Int
}
```

Why this exists: existing memory reads are scoped by `projectId` / `conversationId` in `TurnPlanner` and `UserMemoryService`. Tool calls must follow the same boundary. `read_note` in particular cannot become "send any local note to OpenRouter by UUID" as an accidental side channel.

`makeAgentToolContext(plan:request:)` initializes `allowedReadNodeIds` with `context.currentNodeId` and only those plan-surfaced node ids that pass `AgentRawNodeReadAuthorizer.canReadRawNode(..., allowAlreadyDiscoveredIds: false)`. The loop creates a new context for later iterations by unioning `AgentToolResult.discoveredNodeIds`. Project scope is a separate guard, not a bulk allow-list: optional equality is never enough to authorize a read.

`AgentToolInput` stays deliberately small. It accepts JSON objects from OpenRouter tool calls and exposes typed accessors. Integers must tolerate both `Int` and `Double` because `JSONSerialization` may produce either.

```swift
struct AgentToolInput {
    private let raw: [String: Any]

    init(raw: [String: Any]) { self.raw = raw }

    func string(_ key: String) -> String? { raw[key] as? String }

    func integer(_ key: String) -> Int? {
        if let int = raw[key] as? Int { return int }
        if let double = raw[key] as? Double { return Int(double) }
        return nil
    }

    func boundedInteger(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard raw.keys.contains(key) else { return defaultValue }
        guard let value = integer(key) else { throw AgentToolError.invalidArgument(key) }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    func canonicalJSONString() -> String {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
```

`AgentToolResult` includes both LLM-facing content and UI-facing trace content:

```swift
struct AgentToolResult: Equatable {
    let summary: String
    let traceContent: String
    let discoveredNodeIds: Set<UUID>
}
```

Tool-owned numeric limits are never trusted directly from the LLM. Phase 1 bounds:

| Tool | Numeric input | Default | Range |
|---|---:|---:|---:|
| `search_memory` | `limit` | 5 | 1...8 |
| `recall_recent_conversations` | `limit` | 5 | 1...8 |
| `find_contradictions` | `limit` | 3 | 1...5 |
| `search_conversations_by_topic` | `limit` | 5 | 1...8 |
| `read_note` | none | n/a | n/a |

Missing numeric inputs use the default. Negative, zero, fractional, or huge numeric values are clamped before any DB/vector call; invalid non-numeric values remain `AgentToolError.invalidArgument` when the parameter is present.

Raw node-read authorization is centralized so tools cannot accidentally widen scope:

```swift
enum AgentRawNodeReadAuthorizer {
    static func canReadRawNode(
        _ node: NousNode,
        context: AgentToolContext,
        allowAlreadyDiscoveredIds: Bool
    ) -> Bool {
        if node.id == context.currentNodeId { return true }
        if allowAlreadyDiscoveredIds && context.allowedReadNodeIds.contains(node.id) { return true }
        if let contextProjectId = context.projectId,
           let nodeProjectId = node.projectId,
           nodeProjectId == contextProjectId {
            return true
        }
        return false
    }
}
```

`read_note` calls this with `allowAlreadyDiscoveredIds: true`. Search tools call it with `allowAlreadyDiscoveredIds: false` before adding any source node id to `discoveredNodeIds`. That prevents global memory snippets from becoming raw-read permission for unrelated notes or conversations.

`AgentToolSchema` and `AgentToolDeclaration` use the OpenAI/OpenRouter function-tool wire shape directly:

```swift
struct AgentToolDeclaration: Encodable, Equatable {
    let type = "function"
    let function: AgentToolFunctionDeclaration
}

struct AgentToolFunctionDeclaration: Encodable, Equatable {
    let name: String
    let description: String
    let parameters: AgentToolSchema
}

struct AgentToolSchema: Encodable, Equatable {
    let type = "object"
    let properties: [String: AgentToolSchemaProperty]
    let required: [String]
    let additionalProperties = false
}

struct AgentToolSchemaProperty: Encodable, Equatable {
    enum ValueType: String, Encodable { case string, integer }

    let type: ValueType
    let description: String
}
```

Phase 1 schemas only use `string` and `integer` properties. No nested objects, arrays, or enums are needed for the five approved tools.

#### A.2 Trace records are persistence DTOs, not runtime events

`AgentTraceRecord` is what the app stores in `messages.agent_trace_json`.

```swift
struct AgentTraceRecord: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case toolCall
        case toolResult
        case toolError
        case capReached
    }

    let id: UUID
    let kind: Kind
    let toolName: String?
    let title: String
    let detail: String
    let inputJSON: String?
    let createdAt: Date
}
```

No persisted `Error`. No persisted `[String: Any]`. Errors become strings at the boundary. Tool arguments become canonical JSON strings.

#### A.3 Tool read protocols

Phase 1 adds small read protocols so tools are testable without subclassing concrete services.

```swift
protocol MemoryEntrySearchProviding {
    func searchActiveMemoryEntries(
        query: String,
        projectId: UUID?,
        conversationId: UUID,
        limit: Int
    ) throws -> [MemoryEntry]
}

protocol RecentConversationMemoryProviding {
    func fetchRecentConversationMemories(limit: Int, excludingId: UUID?) throws -> [(title: String, memory: String)]
}

protocol ContradictionFactProviding {
    func contradictionRecallFacts(projectId: UUID?, conversationId: UUID) throws -> [MemoryFactEntry]
    func annotateContradictionCandidates(
        currentMessage: String,
        facts: [MemoryFactEntry],
        maxCandidates: Int
    ) -> [UserMemoryCore.AnnotatedContradictionFact]
}

protocol NodeReading {
    func fetchNode(id: UUID) throws -> NousNode?
}
```

Concrete mapping:

- `NodeStore` implements `MemoryEntrySearchProviding` with a new lexical read method over active `memory_entries`, scoped to global + current project + current conversation. It can start as token scoring in Swift over `fetchMemoryEntries()`; add SQL FTS only if this hurts.
- `NodeStore` already backs `RecentConversationMemoryProviding` through `fetchRecentConversationMemories(limit:excludingId:)`.
- `ContradictionMemoryService` already backs `ContradictionFactProviding`, but the tool calls `contradictionRecallFacts(projectId:conversationId:)` and then `annotateContradictionCandidates(currentMessage:facts:maxCandidates:)` with the requested topic.
- `NodeStore` already backs `NodeReading`.

#### A.4 Five tool implementations

**`search_memory`** uses `MemoryEntrySearchProviding.searchActiveMemoryEntries(query:projectId:conversationId:limit:)` with `limit = try input.boundedInteger("limit", default: 5, range: 1...8)`. Output includes scope/kind/content snippet and source node ids when present. It adds a source node id to `discoveredNodeIds` only after fetching that source node and passing `AgentRawNodeReadAuthorizer.canReadRawNode(..., allowAlreadyDiscoveredIds: false)`. Global memory entries can still be summarized as bounded snippets, but they do not grant raw-read access to unrelated source nodes.

**`recall_recent_conversations`** uses `fetchRecentConversationMemories(limit:excludingId:)` with `limit = try input.boundedInteger("limit", default: 5, range: 1...8)` and `excludingId: context.currentNodeId`, preserving the existing self-confirmation guard documented in `NodeStore.fetchRecentConversationMemories`. It returns bounded memory summaries only and does not add `discoveredNodeIds`, because this API does not return raw node ids.

**`find_contradictions`** takes `topic` and optional `limit` (`default: 3`, `range: 1...5`). It uses current scoped contradiction facts, then ranks with `annotateContradictionCandidates(currentMessage: topic, facts:maxCandidates:)`. Output uses `MemoryFactEntry.content` and `updatedAt`; v1's `statement` / `recordedAt` fields do not exist. It returns bounded fact text only and does not add `discoveredNodeIds`.

**`search_conversations_by_topic`** takes `query` and optional `limit` (`default: 5`, `range: 1...8`). It calls synchronous `EmbeddingService.embed(_:)`, then searches a larger candidate pool before filtering:

```swift
let limit = try input.boundedInteger("limit", default: 5, range: 1...8)
let candidatePoolSize = max(40, limit * 8)
let results = try vectorStore.search(
    query: embedding,
    topK: candidatePoolSize,
    excludeIds: context.excludeNodeIds
)
.filter { $0.node.type == .conversation }
.prefix(limit)
```

If `EmbeddingService` is not loaded, the tool returns an error result and the loop continues. It does not attempt a model download inside a foreground chat turn.

The tool adds matched conversation node ids to `discoveredNodeIds` only after each matched node passes `AgentRawNodeReadAuthorizer.canReadRawNode(..., allowAlreadyDiscoveredIds: false)`. Out-of-project global matches may still appear as bounded search summaries, but they do not become raw-readable by UUID.

**`read_note`** takes `id`. It fetches the node, then calls `AgentRawNodeReadAuthorizer.canReadRawNode(node, context: context, allowAlreadyDiscoveredIds: true)`. In plain language, it reads only when one of these conditions is true:

1. `id == context.currentNodeId`;
2. `id` is in `context.allowedReadNodeIds`; or
3. `context.projectId != nil && node.projectId != nil && node.projectId == context.projectId`.

A nil-project chat does **not** get access to every nil-project note/conversation. Unauthorized and missing ids return a bounded tool error string; they do not reveal whether a private node exists outside the agent's scope. Successful reads return title + type + a capped excerpt using `context.maxToolResultCharacters` (default 1200), not a fixed 2000 chars. Conversations are allowed, but this is intentionally a bounded raw transcript escape hatch.

### B. Tool transcript and provider boundary

The existing `LLMService` protocol stays source-compatible:

```swift
protocol LLMService {
    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error>
}

struct LLMMessage {
    let role: String
    let content: String
}
```

Phase 1 adds a separate protocol for tool-capable providers instead of pretending all providers can handle structured messages:

```swift
protocol ToolCallingLLMService {
    var supportsAgentToolUse: Bool { get }

    func callWithTools(
        system: String,
        messages: [AgentLoopMessage],
        tools: [AgentToolDeclaration],
        allowToolCalls: Bool
    ) async throws -> AgentToolLLMResponse
}
```

`AgentLoopMessage` models the OpenAI/OpenRouter wire shape exactly:

```swift
enum AgentLoopMessage: Equatable {
    case text(role: String, content: String)
    case assistantToolCalls(content: String?, toolCalls: [AgentToolCall])
    case toolResult(toolCallId: String, name: String, content: String, isError: Bool)
}

struct AgentToolCall: Equatable {
    let id: String
    let name: String
    let argumentsJSON: String
}

struct AgentToolLLMResponse: Equatable {
    let text: String
    let assistantMessage: AgentLoopMessage
    let toolCalls: [AgentToolCall]
}
```

OpenRouter serialization:

- `.text(role:content:)` -> `{ "role": role, "content": content }`
- `.assistantToolCalls` -> `{ "role": "assistant", "content": content, "tool_calls": [...] }`
- `.toolResult` -> `{ "role": "tool", "tool_call_id": id, "name": name, "content": content }`

OpenRouter request body for `callWithTools`:

```json
{
  "model": "anthropic/claude-sonnet-4.6",
  "stream": false,
  "messages": [],
  "tools": [],
  "tool_choice": "auto"
}
```

Rules:

- `messages` is `[{ "role": "system", "content": system }] + serializedAgentTranscript`.
- `system` is the full `plan.turnSlice.combined` string, preserving `anchor.md`, quick-action instructions, volatile context, citations, and memory layers in the tool path.
- `serializedAgentTranscript` is the serialized `[AgentLoopMessage]`.
- `tools` is always present during the agent loop, including the forced final-synthesis request after the iteration cap.
- `tool_choice` is `"auto"` when `allowToolCalls == true`.
- `tool_choice` is `"none"` when `allowToolCalls == false`; this is the cap-reached final call and forbids another tool call.
- `stream` is `false` in Phase 1 because the loop needs complete assistant messages with optional `tool_calls`.
- Response parsing reads `choices[0].message.content` and `choices[0].message.tool_calls`. Each tool call maps `id`, `function.name`, and `function.arguments` into `AgentToolCall`.

This fixes the v1 sequencing bug. The loop must append the assistant message containing `tool_calls` before it appends any `role: "tool"` result messages. Tool results are never sent as a user message.

`OpenRouterLLMService` implements `ToolCallingLLMService`. The existing streaming `generate` path is not used for the internal loop. `callWithTools` may use non-streaming chat completions for simplicity in Phase 1; the user still sees live tool trace events and the final answer appears as one `textDelta`.

### C. `AgentLoopExecutor`

New file: `Sources/Nous/Services/AgentLoopExecutor.swift`

`AgentLoopExecutor` returns the same optional result shape as `TurnExecutor`, so the existing `ChatTurnRunner` abort and commit paths remain intact. Cancellation returns `nil`; non-cancellation execution failures throw.

```swift
final class AgentLoopExecutor {
    static let maxIterations = 8

    private let llmService: ToolCallingLLMService
    private let registry: AgentToolRegistry
    private let perToolTimeoutSeconds: Double = 5
    private let totalTurnTimeoutSeconds: Double = 60

    func execute(
        plan: TurnPlan,
        request: TurnRequest,
        sink: TurnSequencedEventSink,
        context: AgentToolContext
    ) async throws -> TurnExecutionResult?
}
```

Loop outline:

1. Convert `plan.transcriptMessages` into `.text(role:content:)` `AgentLoopMessage`s.
2. For each iteration:
   - enforce the total deadline before and during the LLM call;
   - call OpenRouter with `allowToolCalls: true`;
   - append `response.assistantMessage` to the transcript;
   - if `response.toolCalls.isEmpty`, emit one `.textDelta(response.text)` and return `TurnExecutionResult(... agentTraceJson: encodedTrace)`;
   - for each tool call, parse `argumentsJSON`, emit `.agentTraceDelta(.toolCall)`, execute with per-tool timeout, append `.toolResult(...)`, emit `.agentTraceDelta(.toolResult/.toolError)`;
   - merge any `result.discoveredNodeIds` into the next iteration's `allowedReadNodeIds`.
3. At 8 iterations, emit `.agentTraceDelta(.capReached)`, call OpenRouter once with `allowToolCalls: false` (`tool_choice: "none"`), emit one `.textDelta(finalText)`, return `TurnExecutionResult` with `completedNormally == false` represented in trace detail.
4. If `Task.checkCancellation()` or a provider/tool operation throws `CancellationError`, catch it at the executor boundary and return `nil`, matching `TurnExecutor.execute(plan:sink:)`.

Timeout helper must wrap both provider calls and tool calls:

```swift
try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw AgentLoopError.timeout(label, seconds)
    }
    let value = try await group.next()!
    group.cancelAll()
    return value
}
```

The agent path must not reimplement assistant-content cleanup. Extract the existing private `TurnExecutor.normalizedResult(from:persistedThinking:didHitBudgetExhaustion:)` logic into a shared helper:

```swift
struct NormalizedAssistantTurn: Equatable {
    let rawAssistantContent: String
    let assistantContent: String
    let conversationTitle: String?
}

enum AssistantTurnNormalizer {
    static func normalize(_ rawAssistantContent: String) -> NormalizedAssistantTurn
}
```

`TurnExecutor`, `AgentLoopExecutor`, and the quick-action opening path in `ChatViewModel` call this helper before committing assistant content, so `<chat_title>` stripping and title sanitization stay identical across single-shot turns, agent turns, and opening quick-action turns. Remove the duplicate private title sanitizer from `ChatViewModel` after the helper exists.

### D. `ChatTurnRunner` integration + per-mode setup

The real seam is `ChatTurnRunner.runPreparedTurn` after planning and `.prepared`, before `turnExecutor.execute(plan:sink:)`.

`ChatTurnRunner` gains one injected optional dependency:

```swift
typealias AgentLoopExecutorFactory = (
    _ mode: QuickActionMode,
    _ plan: TurnPlan,
    _ request: TurnRequest
) -> AgentLoopExecutor?
```

Pseudocode in the actual runner shape:

```swift
onPlanReady(plan)
await sink.emit(.prepared(outcomeFactory.makePrepared(from: plan)))
try Task.checkCancellation()

let executionResult: TurnExecutionResult
if let mode = request.snapshot.activeQuickActionMode,
   mode.agent().useAgentLoop,
   let agentLoopExecutor = agentLoopExecutorFactory?(mode, plan, request) {
    guard let result = try await agentLoopExecutor.execute(
        plan: plan,
        request: request,
        sink: sink,
        context: makeAgentToolContext(plan: plan, request: request)
    ) else {
        await sink.emit(.aborted(abortReason()))
        return nil
    }
    executionResult = result
} else {
    guard let result = try await turnExecutor.execute(plan: plan, sink: sink) else {
        await sink.emit(.aborted(abortReason()))
        return nil
    }
    executionResult = result
}
```

Everything after `executionResult` stays the existing commit flow, except `ConversationSessionStore.commitAssistantTurn` and `NodeStore.insertMessage` receive `agentTraceJson`.

`QuickActionAgent` gains:

```swift
var toolNames: [String] { get }
var useAgentLoop: Bool { get }
```

Default:

```swift
extension QuickActionAgent {
    var toolNames: [String] { [] }
    var useAgentLoop: Bool { !toolNames.isEmpty }
}
```

Direction and Plan return the five tool names. Brainstorm returns `[]` explicitly and stays single-shot. This intentionally diverges from the original 2026-04-26 memory sentence "each agent becomes a loop" because the 2026-04-27 decision history narrowed Phase 1 to Direction + Plan to preserve Brainstorm's `.lean` bias-prevention contract.

### E. Tool trace UI + persistence

Model/storage:

- `Message` gains `var agentTraceJson: String?`.
- `Message` may expose a computed `decodedAgentTraceRecords` convenience, but the persisted field stays the raw optional JSON string.
- `NodeStore.createTables()` adds `agent_trace_json TEXT` to `messages` and calls `ensureColumnExists(table:"messages", column:"agent_trace_json", ...)`.
- `NodeStore.insertMessage` writes it.
- `NodeStore.fetchMessages` reads it.
- `ConversationSessionStore.commitAssistantTurn` accepts and persists it.
- `TurnExecutionResult` gains `agentTraceJson: String?`.
- `TurnEvent` gains `case agentTraceDelta(AgentTraceRecord)`.

Use one codec for persistence and UI decoding:

```swift
enum AgentTraceCodec {
    static func encode(_ records: [AgentTraceRecord]) -> String?
    static func decode(_ json: String?) -> [AgentTraceRecord]
}
```

Runtime UI:

- `ChatViewModel` gains `currentAgentTrace: [AgentTraceRecord]`.
- `.prepared` clears `currentAgentTrace`.
- `.agentTraceDelta(record)` appends to `currentAgentTrace`.
- `.completed`, `.aborted`, `.failed` clear it.
- Any non-event path that resets `currentResponse` or `currentThinking` also clears `currentAgentTrace`, including `startNewConversation`, `loadConversation`, regenerate setup, and `cancelInFlightResponse`.
- `ChatArea` passes `AgentTraceCodec.decode(message.agentTraceJson)` (or `message.decodedAgentTraceRecords`) for committed messages and `currentAgentTrace` for the in-flight assistant bubble.
- `ChatArea`'s in-flight assistant bubble condition becomes `!vm.currentThinking.isEmpty || !vm.currentResponse.isEmpty || !vm.currentAgentTrace.isEmpty`, so tool trace deltas render before the final answer's first `textDelta`.

`AgentTraceAccordion` accepts `[AgentTraceRecord]` and an `isStreaming` flag. It renders only user-visible records:

- `toolCall`: "Searching memory..." / "Reading note..."
- `toolResult`: the tool result `traceContent`
- `toolError`: error description string
- `capReached`: "Reached 8 steps. Synthesizing now."

No SwiftUI inspection dependency is required. Unit-test the record formatting helper; manually QA the SwiftUI accordion.

### F. Provider strategy — OpenRouter Sonnet 4.6 only

Only `OpenRouterLLMService` implements `ToolCallingLLMService`.

`supportsAgentToolUse` is true only when:

- `provider == .openrouter` at the call site; and
- `OpenRouterLLMService.model == "anthropic/claude-sonnet-4.6"`.

Do not add `callWithTools` requirements to `GeminiLLMService`, `ClaudeLLMService`, `OpenAILLMService`, or `LocalLLMService` in Phase 1. They keep the `LLMService.generate` path. Since `SettingsViewModel` currently defaults to Gemini, fresh installs stay single-shot until Alex selects OpenRouter Sonnet 4.6. If the current provider/model does not satisfy the gate, Direction and Plan fall back to L2.5 single-shot behavior silently.

### G. Validation plan

#### Unit tests

Each test file lives in `Tests/NousTests/`.

- **Per-tool tests** (5 files: `SearchMemoryToolTests.swift`, etc.):
  - Schema validation: `inputSchema` matches the spec (object type, properties, required).
  - Execution: against in-memory `NodeStore` and small protocol fakes (`MemoryEntrySearchProviding`, `ContradictionFactProviding`, etc.), verify result content matches expected.
  - Context boundary: `read_note` rejects ids outside `allowedReadNodeIds` unless the node is the current conversation or belongs to the same non-nil active project.
  - Nil-project boundary: a nil-project context cannot read arbitrary nil-project nodes by UUID.
  - Discovery boundary: `search_memory` and `search_conversations_by_topic` do not add out-of-project/global source ids to `discoveredNodeIds`; same-project/current-node ids are allowed.
  - Numeric bounds: negative, zero, fractional, and huge `limit` inputs clamp to the tool's declared range before DB/vector calls; non-numeric present values throw `AgentToolError.invalidArgument`.
  - Error path: missing required arg → `AgentToolError.missingArgument`. Invalid arg type → `AgentToolError.invalidArgument`.
  - Edge: empty result set returns `summary: "No ... matched."` deterministically.
  - `search_conversations_by_topic` uses a candidate pool larger than `limit` before filtering to conversations and returns matched conversation ids in `discoveredNodeIds`.

- **`AgentToolRegistryTests.swift`**:
  - Registration of multiple tools by name.
  - `subset(_:)` filters to named tools only.
  - `tool(named:)` returns nil for unknown name.
  - `declarations` returns one entry per registered tool.

- **`AgentLoopMessageOpenRouterEncodingTests.swift`**:
  - Request body prepends `{role:"system", content: system}` before the agent transcript.
  - Text messages serialize to `{role, content}`.
  - Assistant tool-call messages serialize with `role: "assistant"` and `tool_calls`.
  - Tool results serialize as `role: "tool"` with `tool_call_id`.
  - Tool declarations serialize as `{type:"function", function:{name,description,parameters}}`.
  - Forced synthesis request uses `tool_choice: "none"` while normal loop requests use `tool_choice: "auto"`.
  - Tool arguments round-trip from JSON string to `AgentToolInput`.

- **`AgentLoopExecutorTests.swift`**:
  - Normal termination: LLM returns text on iteration 0 → executor emits one `.textDelta` and returns `TurnExecutionResult`.
  - Tool dispatch: LLM returns `assistantToolCalls` → executor preserves that assistant message → runs tools → appends `toolResult` messages → next iteration.
  - Iteration cap: 8 iterations of tool calls → forced synthesis call uses `allowToolCalls: false`.
  - Cancellation: fake LLM/tool throws `CancellationError` → executor returns nil and `ChatTurnRunner` emits `.aborted`, not `.failed`.
  - Tool error propagation: tool throws → conversation appends `toolResult(... isError: true)` content and emits `.agentTraceDelta(.toolError)`.
  - Tool not found: LLM requests unknown tool → same error-result path; LLM can recover.
  - Per-tool timeout: hanging tool → `AgentLoopError.timeout` → trace has `toolError`.
  - Total turn timeout: slow LLM call or slow loop exceeds 60s → `AgentLoopError.timeout` thrown.
  - Provider gate: factory returns nil for non-OpenRouter or non-Sonnet-4.6 model → ChatTurnRunner falls back to `TurnExecutor`.

- **`AgentTraceAccordionTests.swift`**:
  - JSON encode/decode roundtrip for `[AgentTraceRecord]`.
  - `AgentTraceCodec.decode(nil)` and malformed JSON return `[]`.
  - Pure formatting helper returns correct rows for `toolCall`, `toolResult`, `toolError`, and `capReached`.
  - In-flight assistant render predicate is true when only `currentAgentTrace` is non-empty.
  - No SwiftUI inspection dependency.

- **`QuickActionAgentToolNamesTests.swift`** (extend existing `QuickActionAgentsTests`):
  - `DirectionAgent.toolNames == [5 tools]`, `useAgentLoop == true`.
  - `PlanAgent.toolNames == [5 tools]`, `useAgentLoop == true`.
  - `BrainstormAgent.toolNames == []`, `useAgentLoop == false`.

- **`ChatTurnRunnerAgentLoopTests.swift`**:
  - Active Direction agent + OpenRouter Sonnet 4.6 → routes to `AgentLoopExecutor`.
  - Active Brainstorm agent → routes to single-shot `TurnExecutor`.
  - Active Plan agent + Gemini provider → routes to single-shot (factory returns nil).
  - No active agent → routes to single-shot.
  - Agent loop returns `agentTraceJson`; `ConversationSessionStore.commitAssistantTurn` persists it.

#### Manual live tests (macOS app)

After all unit tests pass and the app builds:

1. **Direction agent loop — basic**: Open fresh chat, click Direction, ask "我 startup 应该 pivot 边度？". Verify trace accordion appears above the assistant reply showing tool calls (e.g. `search_memory(query: "pivot")` → 3 results, `recall_recent_conversations` → 5 conversations). Trace auto-expands during streaming, auto-collapses on completion. Click to re-expand and read.

2. **Plan agent loop — multi-step**: Open fresh chat, click Plan, ask "我想 ship 个 feature 但担心 timing". Continue answering for 2-3 turns. Verify Plan eventually calls `find_contradictions(topic: "shipping timing")` and `search_memory(query: "ship velocity")` — trace shows both. Final reply uses the tool results in the structured plan output.

3. **Plan cap-reached force-synthesis**: Construct a query that would plausibly trigger 8 iterations (deeply iterative search). Verify cap triggers, trace shows `Reached iteration cap (8) — synthesizing final answer.`, and final reply still arrives within the 60s total-timeout budget.

4. **Brainstorm unchanged**: Open fresh chat, click Brainstorm, ask anything. Verify NO trace accordion appears, response arrives as a single shot. Output format matches the L2.5 ship (bullet+tradeoff + non-bullet judgment prose).

5. **Provider fallback**: In Settings, switch provider to Gemini (or whatever non-Sonnet is configured). Open fresh Direction chat, ask anything. Verify response arrives as a single shot (no trace accordion), no error or hang. Switch back to Sonnet 4.6 and verify the loop returns.

6. **Trace UI streaming**: During a long Plan loop (provoke 5+ iterations), watch the accordion live-stream tool calls. Each `.agentTraceDelta(.toolResult)` event should append a new line. Header text updates from "Nous is searching..." to "Nous searched N sources".

7. **Tool error visibility**: Trigger a tool error (e.g. `read_note(id: "non-existent-uuid")`). Verify the trace shows `⚠ read_note: Note not found.` (or similar) and the LLM continues / synthesizes despite the error.

8. **Default chat unchanged**: Open new chat WITHOUT clicking any quick action. Ask any question. Verify NO trace accordion, single-shot response, identical to pre-Phase-1 behavior.

#### Cost / latency observation

After live tests pass, capture metrics from the trace JSON for ~10 real Direction + Plan turns:
- Median iterations per turn: target ≤ 3
- 95th percentile: target ≤ 6
- Mean wall-clock latency: target ≤ 15s
- Cap-hit rate: target < 5% of turns

If observed metrics significantly exceed targets, escalate to a v5 spec (reduce default cap, tighten tool descriptions, etc.).

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

- **LLM tool-call compliance**: Sonnet 4.6 might choose not to call tools even when they would be useful. The L2.5 fix (memory `validation_chat_markdown_structure_shipped`) showed partial compliance is the norm. Mitigation: tool descriptions emphasize WHEN to use; `contextAddendum` for Direction and Plan can encourage tool use ("ground your answer in Alex's memory by searching first"). Live test 1+2 will reveal compliance rate. If poor, escalate to a stronger system instruction in v5.
- **Trace accordion clutter**: every Direction / Plan reply now has an accordion header. Even collapsed, it's visual noise. Mitigation: only show when `trace.count > 0`. Verify in live test 1.
- **Tool latency**: per-tool timeout 5s is aggressive. If lexical search over `memory_entries` is slow, tools could time out. Mitigation: observe in live tests; expand timeout to 10s if widely tripped. Add an indexed SQL query or FTS only when this actually hurts.
- **JSON column migration**: adding `agent_trace_json` column to `messages` table is a schema change. Existing rows have NULL traces, which is correct (they're pre-Phase-1 messages). No data migration needed. Verify the migration path during writing-plans.
- **Streaming UX**: `AgentTraceAccordion` auto-expands from `TurnEvent.agentTraceDelta` events while the final answer may arrive as a single `textDelta`. This is acceptable for v1 because the visible work is the tool trace; if final-answer non-streaming feels dead, add streamed final synthesis in v5.
- **Context budget**: each loop iteration sends the full conversation including tool results. After 8 iterations, the prompt may be 30K+ tokens. Sonnet 4.6's context is 200K so we have headroom, but cost-per-turn could be 5-10× a single-shot. Acceptable for v1; observe in cost metrics.
- **Total turn timeout**: 60s is generous. It must wrap provider calls and tool execution, not just tool execution. Verify with a fake slow `ToolCallingLLMService`.
- **Mode interaction**: if a user switches mode mid-conversation (Plan → Direction), the agent loop in flight should complete before the next user turn picks up the new mode. Existing `Task.cancel` semantics on mode switch handle this; verify during live test.

## Open questions for codex review round 4

These are things to flag for the codex review pass to scrutinize:

- Does `AgentLoopMessage` fully cover the OpenAI/OpenRouter `tool_calls` transcript shape, including assistant text content alongside tool calls?
- Does the OpenRouter tool request preserve the full system prompt exactly once?
- Is `AgentToolInput` using `[String: Any]` acceptable now that only canonical JSON strings are persisted?
- Per-tool timeout uses `withThrowingTaskGroup` racing against `Task.sleep`. Is there a cleaner Swift Concurrency pattern?
- Is `read_note`'s current-node / discovered-id / same-non-nil-project boundary tight enough for an OpenRouter-only feature, especially now that search tools cannot discover out-of-project raw nodes?
- Should `search_memory` be a new `NodeStore.searchActiveMemoryEntries` method or a tiny `AgentMemorySearchService` wrapping `NodeStore.fetchMemoryEntries()`?
- Does the current spec contain enough detail for `superpowers:writing-plans`, or should the implementation plan split provider wiring and UI/persistence into separate task groups?
