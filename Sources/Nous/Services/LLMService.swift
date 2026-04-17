import Foundation

enum LLMProvider: String, Codable, CaseIterable {
    case local = "Local (MLX)"
    case gemini = "Gemini"
    case claude = "Claude API"
    case openai = "OpenAI API"
}

enum LLMChunk {
    case thought(String)
    case answer(String)
}

protocol LLMService {
    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<LLMChunk, Error>
}

struct LLMMessage {
    let role: String // "user" or "assistant"
    let content: String
}

// MARK: - Claude API

struct ClaudeLLMService: LLMService {
    let apiKey: String
    var model: String = "claude-sonnet-4-6-20250414"

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<LLMChunk, Error> {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8096,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        if let system {
            body["system"] = system
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { continuation in
            Task {
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
                            let type = json["type"] as? String,
                            type == "content_block_delta",
                            let delta = json["delta"] as? [String: Any],
                            let deltaType = delta["type"] as? String,
                            deltaType == "text_delta",
                            let text = delta["text"] as? String
                        else { continue }

                        continuation.yield(.answer(text))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - OpenAI API

struct OpenAILLMService: LLMService {
    let apiKey: String
    var model: String = "gpt-4o"

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<LLMChunk, Error> {
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
            Task {
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

                        continuation.yield(.answer(text))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Gemini API

struct GeminiLLMService: LLMService {
    let apiKey: String
    var model: String = "gemini-2.5-pro"

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<LLMChunk, Error> {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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
        body["generationConfig"] = [
            "temperature": 0.7,
            "maxOutputTokens": 8192,
            "thinkingConfig": [
                "includeThoughts": true
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let systemLen = system?.count ?? 0
        let userLen = messages.map(\.content.count).reduce(0, +)
        print("[Gemini] req model=\(model) system.chars=\(systemLen) user.chars=\(userLen)")
        let startedAt = Date()

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let headerTime = Date().timeIntervalSince(startedAt)
                    print("[Gemini] headers in \(String(format: "%.2f", headerTime))s")
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMError.invalidResponse)
                        return
                    }
                    guard httpResponse.statusCode == 200 else {
                        var bodyText = ""
                        for try await line in bytes.lines {
                            bodyText += line + "\n"
                            if bodyText.count > 2000 { break }
                        }
                        print("[Gemini] HTTP \(httpResponse.statusCode) body: \(bodyText)")
                        continuation.finish(throwing: LLMError.httpError(httpResponse.statusCode))
                        return
                    }

                    var firstByteTime: TimeInterval? = nil
                    for try await line in bytes.lines {
                        if firstByteTime == nil, line.hasPrefix("data: ") {
                            firstByteTime = Date().timeIntervalSince(startedAt)
                            print("[Gemini] first byte in \(String(format: "%.2f", firstByteTime!))s")
                        }
                        guard line.hasPrefix("data: ") else { continue }
                        let data = String(line.dropFirst(6))

                        guard
                            let jsonData = data.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                            let candidates = json["candidates"] as? [[String: Any]],
                            let first = candidates.first,
                            let content = first["content"] as? [String: Any],
                            let parts = content["parts"] as? [[String: Any]]
                        else { continue }

                        for part in parts {
                            guard let text = part["text"] as? String else { continue }
                            let isThought = (part["thought"] as? Bool) ?? false
                            continuation.yield(isThought ? .thought(text) : .answer(text))
                        }
                    }
                    let total = Date().timeIntervalSince(startedAt)
                    print("[Gemini] stream complete in \(String(format: "%.2f", total))s")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
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
