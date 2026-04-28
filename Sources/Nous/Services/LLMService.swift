import Foundation

enum LLMProvider: String, Codable, CaseIterable {
    case local = "Local (MLX)"
    case gemini = "Gemini"
    case claude = "Claude API"
    case openai = "OpenAI API"
    case openrouter = "OpenRouter"
}

protocol LLMService {
    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error>
}

protocol ToolCallingLLMService {
    var supportsAgentToolUse: Bool { get }

    func callWithTools(
        system: String,
        messages: [AgentLoopMessage],
        tools: [AgentToolDeclaration],
        allowToolCalls: Bool
    ) async throws -> AgentToolLLMResponse
}

typealias ThinkingDeltaHandler = @MainActor (String) async -> Void

struct LLMMessage {
    let role: String // "user" or "assistant"
    let content: String
}

struct GeminiUsageMetadata: Equatable, Codable {
    let promptTokenCount: Int
    let cachedContentTokenCount: Int
    let candidatesTokenCount: Int?
    let thoughtsTokenCount: Int?
    let totalTokenCount: Int?

    var cacheHitRate: Double? {
        guard promptTokenCount > 0 else { return nil }
        return Double(cachedContentTokenCount) / Double(promptTokenCount)
    }
}

struct GeminiCachedContent: Equatable, Codable {
    let name: String
    let model: String
    let expireTime: Date?
}

enum ReasoningStreamEvent: Equatable {
    case thinkingDelta(String)
    case textDelta(String)
}

enum ClaudeSSEParser {
    static func parseLine(_ line: String) -> [ReasoningStreamEvent] {
        guard line.hasPrefix("data: ") else { return [] }
        let data = String(line.dropFirst(6))
        guard data != "[DONE]",
              let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = json["type"] as? String,
              type == "content_block_delta",
              let delta = json["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String else {
            return []
        }

        switch deltaType {
        case "thinking_delta":
            guard let thinking = delta["thinking"] as? String, !thinking.isEmpty else { return [] }
            return [.thinkingDelta(thinking)]
        case "text_delta":
            guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
            return [.textDelta(text)]
        default:
            return []
        }
    }
}

enum OpenRouterSSEParser {
    static func parseLine(_ line: String) -> [ReasoningStreamEvent] {
        guard line.hasPrefix("data: ") else { return [] }
        let data = String(line.dropFirst(6))
        guard data != "[DONE]",
              let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else {
            return []
        }

        var events: [ReasoningStreamEvent] = []
        if let reasoningDetails = delta["reasoning_details"] as? [[String: Any]] {
            for detail in reasoningDetails {
                guard let type = detail["type"] as? String else { continue }
                switch type {
                case "reasoning.text":
                    if let text = detail["text"] as? String, !text.isEmpty {
                        events.append(.thinkingDelta(text))
                    }
                case "reasoning.summary":
                    if let summary = detail["summary"] as? String, !summary.isEmpty {
                        events.append(.thinkingDelta(summary))
                    }
                default:
                    continue
                }
            }
        } else if let reasoning = delta["reasoning"] as? String, !reasoning.isEmpty {
            events.append(.thinkingDelta(reasoning))
        } else if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
            events.append(.thinkingDelta(reasoning))
        }

        if let text = delta["content"] as? String, !text.isEmpty {
            events.append(.textDelta(text))
        }

        return events
    }
}

// MARK: - Claude API

struct ClaudeLLMService: LLMService {
    let apiKey: String
    var model: String = "claude-sonnet-4-6-20250414"
    var thinkingBudgetTokens: Int? = nil
    var onThinkingDelta: ThinkingDeltaHandler? = nil
    /// Slow-changing system prefix (e.g. anchor.md + persisted memories) that
    /// should ride Anthropic's prompt cache. When set and matched as a prefix
    /// of `system`, the request body emits two text blocks with a single
    /// `cache_control: ephemeral` breakpoint at the end of the prefix.
    var cacheableSystemPrefix: String? = nil

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = Self.buildRequestBody(
            model: model,
            messages: messages,
            system: system,
            cacheableSystemPrefix: cacheableSystemPrefix,
            thinkingBudgetTokens: thinkingBudgetTokens
        )

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let capturedOnThinkingDelta = onThinkingDelta

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMError.invalidResponse)
                        return
                    }
                    guard httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: LLMError.httpError(httpResponse.statusCode))
                        return
                    }

                    for try await line in bytes.lines {
                        let events = ClaudeSSEParser.parseLine(line)
                        for event in events {
                            switch event {
                            case .thinkingDelta(let text):
                                if let cb = capturedOnThinkingDelta { await cb(text) }
                            case .textDelta(let text):
                                continuation.yield(text)
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    static func buildRequestBody(
        model: String,
        messages: [LLMMessage],
        system: String?,
        cacheableSystemPrefix: String?,
        thinkingBudgetTokens: Int?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8096,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        if let systemBlocks = systemBlocksWithCacheControl(
            system: system,
            cacheableSystemPrefix: cacheableSystemPrefix
        ) {
            body["system"] = systemBlocks
        } else if let system, !system.isEmpty {
            body["system"] = system
        }
        if let thinkingBudgetTokens {
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": thinkingBudgetTokens
            ]
        }
        return body
    }

    static func systemBlocksWithCacheControl(
        system: String?,
        cacheableSystemPrefix: String?
    ) -> [[String: Any]]? {
        guard let prefix = cacheableSystemPrefix?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty
        else { return nil }

        let cachedBlock: [String: Any] = [
            "type": "text",
            "text": prefix,
            "cache_control": ["type": "ephemeral"]
        ]

        guard let system, !system.isEmpty else {
            return [cachedBlock]
        }

        if system == prefix {
            return [cachedBlock]
        }

        guard system.hasPrefix(prefix) else {
            // Defensive: prefix doesn't match. Fall back to plain string system
            // so we never silently drop part of the prompt.
            return nil
        }

        let remainder = String(system.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.isEmpty {
            return [cachedBlock]
        }
        return [
            cachedBlock,
            ["type": "text", "text": remainder]
        ]
    }
}

// MARK: - OpenAI API

struct OpenAILLMService: LLMService {
    let apiKey: String
    var model: String = "gpt-4o"

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var allMessages: [[String: String]] = []
        if let system {
            allMessages.append(["role": "system", "content": system])
        }
        allMessages.append(contentsOf: messages.map { ["role": $0.role, "content": $0.content] })

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": allMessages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMError.invalidResponse)
                        return
                    }
                    guard httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: LLMError.httpError(httpResponse.statusCode))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let data = String(line.dropFirst(6))
                        guard data != "[DONE]" else { break }

                        guard
                            let jsonData = data.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                            let choices = json["choices"] as? [[String: Any]],
                            let first = choices.first,
                            let delta = first["delta"] as? [String: Any],
                            let text = delta["content"] as? String
                        else { continue }

                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }
}

// MARK: - OpenRouter API

struct OpenRouterLLMService: LLMService {
    let apiKey: String
    var model: String = "anthropic/claude-sonnet-4.6"
    var reasoningBudgetTokens: Int? = nil
    var onThinkingDelta: ThinkingDeltaHandler? = nil

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://nous.app", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Nous", forHTTPHeaderField: "X-Title")

        var allMessages: [[String: String]] = []
        if let system {
            allMessages.append(["role": "system", "content": system])
        }
        allMessages.append(contentsOf: messages.map { ["role": $0.role, "content": $0.content] })

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": allMessages
        ]
        var requestBody = body
        if let reasoningBudgetTokens {
            requestBody["reasoning"] = [
                "max_tokens": reasoningBudgetTokens
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let capturedOnThinkingDelta = onThinkingDelta

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMError.invalidResponse)
                        return
                    }
                    guard httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: LLMError.httpError(httpResponse.statusCode))
                        return
                    }

                    for try await line in bytes.lines {
                        let events = OpenRouterSSEParser.parseLine(line)
                        for event in events {
                            switch event {
                            case .thinkingDelta(let text):
                                if let cb = capturedOnThinkingDelta { await cb(text) }
                            case .textDelta(let text):
                                continuation.yield(text)
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }
}

extension OpenRouterLLMService: ToolCallingLLMService {
    var supportsAgentToolUse: Bool {
        model == "anthropic/claude-sonnet-4.6"
    }

    func callWithTools(
        system: String,
        messages: [AgentLoopMessage],
        tools: [AgentToolDeclaration],
        allowToolCalls: Bool
    ) async throws -> AgentToolLLMResponse {
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://nous.app", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Nous", forHTTPHeaderField: "X-Title")

        let requestBody = try Self.buildToolRequestBody(
            model: model,
            system: system,
            messages: messages,
            tools: tools,
            allowToolCalls: allowToolCalls
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw LLMError.httpError(httpResponse.statusCode)
        }
        return try Self.parseToolResponse(data)
    }

    static func buildToolRequestBody(
        model: String,
        system: String,
        messages: [AgentLoopMessage],
        tools: [AgentToolDeclaration],
        allowToolCalls: Bool
    ) throws -> [String: Any] {
        [
            "model": model,
            "stream": false,
            "messages": Self.serializeAgentMessages(system: system, messages: messages),
            "tools": try Self.serializeToolDeclarations(tools),
            "tool_choice": allowToolCalls ? "auto" : "none"
        ]
    }

    static func serializeAgentMessages(
        system: String,
        messages: [AgentLoopMessage]
    ) -> [[String: Any]] {
        var serialized: [[String: Any]] = []
        if !system.isEmpty {
            serialized.append(["role": "system", "content": system])
        }
        serialized.append(contentsOf: messages.map(serializeAgentMessage))
        return serialized
    }

    static func serializeAgentMessage(_ message: AgentLoopMessage) -> [String: Any] {
        switch message {
        case .text(let role, let content):
            return ["role": role, "content": content]
        case .assistantToolCalls(let content, let toolCalls):
            var payload: [String: Any] = [
                "role": "assistant",
                "tool_calls": toolCalls.map(serializeToolCall)
            ]
            payload["content"] = content ?? ""
            return payload
        case .toolResult(let toolCallId, let name, let content, _):
            return [
                "role": "tool",
                "tool_call_id": toolCallId,
                "name": name,
                "content": content
            ]
        }
    }

    static func serializeToolCall(_ toolCall: AgentToolCall) -> [String: Any] {
        [
            "id": toolCall.id,
            "type": "function",
            "function": [
                "name": toolCall.name,
                "arguments": toolCall.argumentsJSON
            ]
        ]
    }

    static func serializeToolDeclarations(_ tools: [AgentToolDeclaration]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(tools)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }
        return array
    }

    private static func parseToolResponse(_ data: Data) throws -> AgentToolLLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw LLMError.invalidResponse
        }

        let text = message["content"] as? String ?? ""
        let toolCalls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap(parseToolCall)
        let assistantMessage: AgentLoopMessage = toolCalls.isEmpty
            ? .text(role: "assistant", content: text)
            : .assistantToolCalls(
                content: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text,
                toolCalls: toolCalls
            )
        return AgentToolLLMResponse(
            text: text,
            assistantMessage: assistantMessage,
            toolCalls: toolCalls
        )
    }

    private static func parseToolCall(_ payload: [String: Any]) -> AgentToolCall? {
        guard let id = payload["id"] as? String,
              let function = payload["function"] as? [String: Any],
              let name = function["name"] as? String else {
            return nil
        }
        let arguments = function["arguments"] as? String ?? "{}"
        return AgentToolCall(id: id, name: name, argumentsJSON: arguments)
    }
}

// MARK: - Gemini API

enum GeminiSSEEvent: Equatable {
    case thoughtDelta(String)
    case textDelta(String)
    case usageMetadata(GeminiUsageMetadata)
    case budgetExhausted
    case finish(reason: String)
}

struct GeminiSSEParseState {
    var didYieldNonThoughtText: Bool = false
    var didFireBudgetExhausted: Bool = false
    var didEmitUsageMetadata: Bool = false
}

enum GeminiSSEParser {
    static func parseLine(_ line: String, state: inout GeminiSSEParseState) -> [GeminiSSEEvent] {
        guard line.hasPrefix("data: ") else { return [] }
        let data = String(line.dropFirst(6))
        guard
            let jsonData = data.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return [] }

        var events: [GeminiSSEEvent] = []
        if let usage = usageMetadata(from: json), !state.didEmitUsageMetadata {
            state.didEmitUsageMetadata = true
            events.append(.usageMetadata(usage))
        }

        guard
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first
        else { return events }

        if let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                guard let text = part["text"] as? String, !text.isEmpty else { continue }
                if (part["thought"] as? Bool) == true {
                    events.append(.thoughtDelta(text))
                } else {
                    state.didYieldNonThoughtText = true
                    events.append(.textDelta(text))
                }
            }
        }

        if let finishReason = first["finishReason"] as? String {
            if finishReason == "MAX_TOKENS"
                && !state.didYieldNonThoughtText
                && !state.didFireBudgetExhausted {
                state.didFireBudgetExhausted = true
                events.append(.budgetExhausted)
            }
            events.append(.finish(reason: finishReason))
        }

        return events
    }

    private static func usageMetadata(from json: [String: Any]) -> GeminiUsageMetadata? {
        guard let usage = json["usageMetadata"] as? [String: Any],
              let promptTokenCount = integer("promptTokenCount", in: usage) else {
            return nil
        }

        return GeminiUsageMetadata(
            promptTokenCount: promptTokenCount,
            cachedContentTokenCount: integer("cachedContentTokenCount", in: usage) ?? 0,
            candidatesTokenCount: integer("candidatesTokenCount", in: usage),
            thoughtsTokenCount: integer("thoughtsTokenCount", in: usage),
            totalTokenCount: integer("totalTokenCount", in: usage)
        )
    }

    private static func integer(_ key: String, in json: [String: Any]) -> Int? {
        if let value = json[key] as? Int {
            return value
        }
        if let value = json[key] as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

struct GeminiLLMService: LLMService {
    let apiKey: String
    var model: String = "gemini-2.5-pro"
    var thinkingBudgetTokens: Int? = nil
    var cachedContentName: String? = nil
    // Callbacks are @MainActor so the producer task `await`s them. That serializes
    // state updates with the SSE parse loop and guarantees the final budget-exhausted
    // signal has landed on MainActor before `continuation.finish()` is called, so
    // any consumer reading the flag after the stream ends sees the final value.
    var onThinkingDelta: (@MainActor (String) async -> Void)? = nil
    var onBudgetExhausted: (@MainActor () async -> Void)? = nil
    var onUsageMetadata: (@MainActor (GeminiUsageMetadata) async -> Void)? = nil

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var contents: [[String: Any]] = []
        for msg in messages {
            contents.append([
                "role": msg.role == "assistant" ? "model" : "user",
                "parts": [["text": msg.content]]
            ])
        }

        var body: [String: Any] = ["contents": contents]
        if let system {
            body["systemInstruction"] = [
                "parts": [["text": system]]
            ]
        }
        if let cachedContentName {
            body["cachedContent"] = cachedContentName
        }
        var generationConfig: [String: Any] = [
            "temperature": 0.7,
            "maxOutputTokens": 8192
        ]
        if let thinkingBudgetTokens {
            generationConfig["thinkingConfig"] = [
                "includeThoughts": true,
                "thinkingBudget": thinkingBudgetTokens
            ]
        }
        body["generationConfig"] = generationConfig

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let capturedOnThinkingDelta = onThinkingDelta
        let capturedOnBudgetExhausted = onBudgetExhausted
        let capturedOnUsageMetadata = onUsageMetadata

        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMError.invalidResponse)
                        return
                    }
                    guard httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: LLMError.httpError(httpResponse.statusCode))
                        return
                    }

                    var state = GeminiSSEParseState()
                    for try await line in bytes.lines {
                        let events = GeminiSSEParser.parseLine(line, state: &state)
                        for event in events {
                            switch event {
                            case .thoughtDelta(let text):
                                if let cb = capturedOnThinkingDelta { await cb(text) }
                            case .textDelta(let text):
                                continuation.yield(text)
                            case .usageMetadata(let usage):
                                if let cb = capturedOnUsageMetadata { await cb(usage) }
                            case .budgetExhausted:
                                if let cb = capturedOnBudgetExhausted { await cb() }
                            case .finish:
                                break
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    /// Non-streaming structured-output call. Returns the raw JSON text that
    /// Gemini produced (already constrained to `responseSchema`) plus usage
    /// metadata. Caller is responsible for `JSONDecoder().decode(...)` into
    /// the target type; we keep it as a string so reflection validation can
    /// inspect the shape before decoding.
    ///
    /// The REST field name is `responseJsonSchema` (camelCase) per the
    /// official Gemini API docs — not `responseSchema`. Getting that wrong
    /// is exactly what the W1 D1 spike was designed to catch.
    func generateStructured(
        messages: [LLMMessage],
        system: String? = nil,
        responseSchema: [String: Any],
        temperature: Double = 0.7
    ) async throws -> (text: String, usage: GeminiUsageMetadata?) {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var contents: [[String: Any]] = []
        for msg in messages {
            contents.append([
                "role": msg.role == "assistant" ? "model" : "user",
                "parts": [["text": msg.content]]
            ])
        }

        var body: [String: Any] = ["contents": contents]
        if let system {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        body["generationConfig"] = [
            "temperature": temperature,
            "responseMimeType": "application/json",
            "responseJsonSchema": responseSchema
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw LLMError.httpError(httpResponse.statusCode)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let firstCandidate = candidates.first,
            let content = firstCandidate["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else {
            throw LLMError.invalidResponse
        }

        let usage: GeminiUsageMetadata? = {
            guard let u = json["usageMetadata"] as? [String: Any] else { return nil }
            return GeminiUsageMetadata(
                promptTokenCount: (u["promptTokenCount"] as? Int) ?? 0,
                cachedContentTokenCount: (u["cachedContentTokenCount"] as? Int) ?? 0,
                candidatesTokenCount: u["candidatesTokenCount"] as? Int,
                thoughtsTokenCount: u["thoughtsTokenCount"] as? Int,
                totalTokenCount: u["totalTokenCount"] as? Int
            )
        }()

        return (text, usage)
    }

    func createCachedContent(
        messages: [LLMMessage],
        system: String? = nil,
        ttlSeconds: Int = 300,
        displayName: String? = nil
    ) async throws -> GeminiCachedContent {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/cachedContents")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": "models/\(model)",
            "contents": messages.map(Self.contentPayload(for:)),
            "ttl": "\(ttlSeconds)s"
        ]
        if let system {
            body["systemInstruction"] = [
                "parts": [["text": system]]
            ]
        }
        if let displayName, !displayName.isEmpty {
            body["displayName"] = displayName
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw LLMError.httpError(httpResponse.statusCode)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = json["name"] as? String
        else {
            throw LLMError.invalidResponse
        }

        let expireTime: Date? = {
            guard let raw = json["expireTime"] as? String else { return nil }
            return Self.parseRFC3339(raw)
        }()

        return GeminiCachedContent(name: name, model: model, expireTime: expireTime)
    }

    func deleteCachedContent(name: String) async throws {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(encoded)") else {
            throw LLMError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw LLMError.httpError(httpResponse.statusCode)
        }
    }

    private static func contentPayload(for message: LLMMessage) -> [String: Any] {
        [
            "role": message.role == "assistant" ? "model" : "user",
            "parts": [["text": message.content]]
        ]
    }

    private static func parseRFC3339(_ raw: String) -> Date? {
        if let date = rfc3339FractionalFormatter.date(from: raw) {
            return date
        }
        return rfc3339Formatter.date(from: raw)
    }

    private static let rfc3339FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let rfc3339Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Errors

enum LLMError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server."
        case .httpError(let code): return "HTTP error: \(code)."
        case .modelNotLoaded: return "Local model not loaded. Call loadModel() first."
        }
    }
}
