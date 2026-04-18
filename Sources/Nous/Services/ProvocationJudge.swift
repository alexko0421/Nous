import Foundation

enum JudgeError: Error, Equatable {
    case timeout
    case apiError
    case badJSON
    case emptyOutput
}

final class ProvocationJudge {
    private let llmService: any LLMService
    private let timeout: TimeInterval

    init(llmService: any LLMService, timeout: TimeInterval = 1.5) {
        self.llmService = llmService
        self.timeout = timeout
    }

    func judge(
        userMessage: String,
        citablePool: [CitableEntry],
        chatMode: ChatMode,
        provider: LLMProvider
    ) async throws -> JudgeVerdict {
        let systemPrompt = Self.buildPrompt(pool: citablePool, chatMode: chatMode)
        let llmMessages = [LLMMessage(role: "user", content: userMessage)]

        let rawOutput: String
        do {
            rawOutput = try await withTimeout(seconds: timeout) {
                try await self.collect(try await self.llmService.generate(messages: llmMessages, system: systemPrompt))
            }
        } catch is TimeoutError {
            throw JudgeError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JudgeError.apiError
        }

        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JudgeError.emptyOutput }

        let jsonString = Self.extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonString.data(using: .utf8) else { throw JudgeError.badJSON }
        do {
            return try JSONDecoder().decode(JudgeVerdict.self, from: data)
        } catch {
            throw JudgeError.badJSON
        }
    }

    // MARK: Prompt

    static func buildPrompt(pool: [CitableEntry], chatMode: ChatMode) -> String {
        let poolText: String
        if pool.isEmpty {
            poolText = "(empty — no citable entries this turn)"
        } else {
            poolText = pool.enumerated().map { idx, e in
                "[\(idx + 1)] id=\(e.id) scope=\(e.scope.rawValue)\n\(e.text)"
            }.joined(separator: "\n---\n")
        }

        return """
        You are a silent judge deciding whether Nous should interject during its next reply to the user.
        Do NOT address the user. Your entire output is one JSON object exactly matching the schema below — nothing before or after.

        SCHEMA
        {
          "tension_exists": true | false,
          "user_state": "deciding" | "exploring" | "venting",
          "should_provoke": true | false,
          "entry_id": "<id from citable entries>" | null,
          "reason": "<short natural-language reason>"
        }

        RULES (must hold in your output)
        - should_provoke = true REQUIRES: tension_exists = true, user_state != "venting", and entry_id is a real id from CITABLE ENTRIES below.
        - user_state = "venting" FORCES should_provoke = false regardless of any tension. Venting is not a moment to challenge.
        - entry_id MUST be copied verbatim from the `id=` field of one CITABLE ENTRY. Do not invent.
        - CHAT_MODE-dependent threshold:
          * strategist → if tension_exists is true AND user_state ∈ {deciding, exploring}, set should_provoke = true. Soft tensions count.
          * companion  → only set should_provoke = true when the tension is strong AND clearly relevant to a decision the user is making. Soft tensions → false.

        CHAT_MODE
        \(chatMode.rawValue)

        CITABLE ENTRIES
        \(poolText)

        USER MESSAGE (next after this system block)
        """
    }

    // MARK: Output helpers

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var acc = ""
        for try await chunk in stream { acc += chunk }
        return acc
    }

    /// Pulls the first top-level `{...}` block out of free-form model output.
    /// Tolerates leading prose or stray backticks from models that don't perfectly follow
    /// "output JSON only" instructions.
    /// String-aware: correctly handles escaped quotes and literal `}` inside strings.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]

            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...idx]) }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}

// MARK: - Timeout helper

private struct TimeoutError: Error {}

private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
