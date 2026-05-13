import Foundation

final class SourceLearningMemoryService {
    private let nodeStore: NodeStore
    private let llmServiceProvider: () -> (any LLMService)?
    private let now: () -> Date

    init(
        nodeStore: NodeStore,
        llmServiceProvider: @escaping () -> (any LLMService)?,
        now: @escaping () -> Date = Date.init
    ) {
        self.nodeStore = nodeStore
        self.llmServiceProvider = llmServiceProvider
        self.now = now
    }

    func absorb(_ request: SourceLearningDigestRequest) async -> SourceLearningDigestResult {
        guard !request.sourceMaterials.isEmpty,
              let llm = llmServiceProvider() else {
            return .empty
        }

        do {
            let stream = try await llm.generate(
                messages: [LLMMessage(role: "user", content: Self.prompt(for: request))],
                system: Self.systemPrompt
            )
            var raw = ""
            for try await chunk in stream {
                if Task.isCancelled { return .empty }
                raw += chunk
            }

            let candidates = Self.decodeCandidates(from: raw)
            var insertedCount = 0
            var rejectedCount = 0
            let lifecycleEngine = MemoryLifecycleEngine(nodeStore: nodeStore)
            for candidate in candidates {
                let currentNow = now()
                guard let atom = Self.memoryAtom(
                    from: candidate,
                    request: request,
                    now: currentNow
                ) else {
                    rejectedCount += 1
                    continue
                }

                do {
                    let staged = try lifecycleEngine.stageAtomProposal(atom, now: currentNow)
                    if staged.status == .archived {
                        rejectedCount += 1
                    } else {
                        insertedCount += 1
                    }
                } catch {
                    rejectedCount += 1
                }
            }
            return SourceLearningDigestResult(
                insertedCount: insertedCount,
                rejectedCount: rejectedCount
            )
        } catch {
            return .empty
        }
    }

    private static let systemPrompt = """
    You extract Alex-specific learning from a source-attached chat turn.
    Store only Alex's stance, connection, decision, preference, goal, correction, or durable interpretation.
    Never turn source facts, transcript text, Gemini video analysis, or assistant explanations into Alex memory.
    Return strict JSON only.
    """

    private static func prompt(for request: SourceLearningDigestRequest) -> String {
        let sourceBlock = request.sourceMaterials.enumerated().map { index, material in
            let chunks = material.chunks.prefix(3).map { chunk in
                "- \(chunk.text)"
            }.joined(separator: "\n")
            return """
            [S\(index + 1)] \(material.title)
            URL/Filename: \(material.displaySource)
            Evidence: \(material.evidenceLevel.label)
            \(chunks)
            """
        }.joined(separator: "\n\n")

        return """
        Conversation id: \(request.conversationId.uuidString)
        Project id: \(request.projectId?.uuidString ?? "none")

        Alex message id: \(request.userMessage.id.uuidString)
        Alex said:
        \(request.userMessage.content)

        Nous replied:
        \(request.assistantMessage.content)

        Attached source material:
        \(sourceBlock)

        Return JSON:
        {
          "candidates": [
            {
              "type": "insight|belief|preference|decision|goal|pattern|correction",
              "statement": "Alex-specific memory statement",
              "scope": "conversation|project|global",
              "confidence": 0.0,
              "evidence_quote": "short exact quote from Alex's message"
            }
          ]
        }

        Rules:
        - evidence_quote must be copied from Alex's message, not Nous's reply and not the source.
        - Omit candidates if Alex only says "explain this", "interesting", "tell me more", or similar.
        - Omit pure source facts even if the source is useful.
        - Use project scope only when Alex connects it to his current project, strategy, app, or work.
        - Use global scope only for durable preferences, identity, boundaries, or always/never-style claims.
        - JSON only.
        """
    }

    private static func memoryAtom(
        from candidate: SourceLearningMemoryCandidate,
        request: SourceLearningDigestRequest,
        now: Date
    ) -> MemoryAtom? {
        guard allowedTypes.contains(candidate.type) else { return nil }
        guard hasUserLearningSignal(request.userMessage.content) else { return nil }

        let statement = candidate.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard statement.count >= 12,
              isAlexSpecific(statement),
              !isPureSourceFact(statement) else {
            return nil
        }

        let evidenceQuote = candidate.evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidenceQuote.isEmpty,
              normalizedContains(request.userMessage.content, evidenceQuote) else {
            return nil
        }

        let sourceNodeId = candidate.sourceNodeId.flatMap { id in
            request.sourceMaterials.contains { $0.sourceNodeId == id } ? id : nil
        } ?? request.sourceMaterials.first?.sourceNodeId
        guard let sourceNodeId else { return nil }

        let scope = resolvedScope(
            candidate.scope,
            userMessage: request.userMessage.content,
            projectId: request.projectId,
            conversationId: request.conversationId
        )
        let confidence = min(max(candidate.confidence, 0.55), 0.86)

        return MemoryAtom(
            type: candidate.type,
            statement: statement,
            normalizedKey: normalizedKey(statement),
            scope: scope.value,
            scopeRefId: scope.refId,
            status: .pending,
            confidence: confidence,
            eventTime: request.userMessage.timestamp,
            createdAt: now,
            updatedAt: now,
            lastSeenAt: nil,
            sourceNodeId: sourceNodeId,
            sourceMessageId: request.userMessage.id
        )
    }

    private static let allowedTypes: Set<MemoryAtomType> = [
        .insight,
        .belief,
        .preference,
        .decision,
        .goal,
        .pattern,
        .correction
    ]

    private static func isAlexSpecific(_ statement: String) -> Bool {
        let normalized = " \(statement.lowercased()) "
        if normalized.contains(" alex ") { return true }
        if normalized.contains(" i ") || normalized.contains(" i'm ") || normalized.contains(" my ") { return true }
        return statement.contains("我")
    }

    private static func hasUserLearningSignal(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }

        let normalized = " \(trimmed.lowercased()) "
        let compact = normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        let directCues = [
            " i think ",
            " i believe ",
            " i feel ",
            " i see ",
            " i realized ",
            " i realise ",
            " i learned ",
            " i decide ",
            " i decided ",
            " i prefer ",
            " i always ",
            " i never ",
            " i don't want ",
            " my strategy ",
            " my project ",
            " my product ",
            " my app ",
            " my work ",
            " my community ",
            " for my ",
            " connects to my ",
            " relates to my ",
            "我觉得",
            "我覺得",
            "我认为",
            "我認為",
            "我发现",
            "我發現",
            "我决定",
            "我決定",
            "我偏好",
            "我一直",
            "我唔想",
            "同我",
            "对我",
            "對我"
        ]
        if directCues.contains(where: { cue in
            cue.contains(" ") ? normalized.contains(cue) : compact.contains(cue)
        }) {
            return true
        }

        let hasFirstPerson = normalized.contains(" i ") ||
            normalized.contains(" my ") ||
            compact.contains("我")
        let hasConnectionCue = [
            "strategy",
            "project",
            "product",
            "startup",
            "community",
            "connect",
            "relate",
            "decision",
            "goal",
            "preference",
            "策略",
            "项目",
            "項目",
            "产品",
            "產品",
            "决定",
            "決定",
            "目标",
            "目標",
            "有关",
            "有關",
            "关系",
            "關係"
        ].contains { cue in
            cue.unicodeScalars.allSatisfy(\.isASCII)
                ? normalized.contains(cue)
                : compact.contains(cue)
        }
        return hasFirstPerson && hasConnectionCue
    }

    private static func isPureSourceFact(_ statement: String) -> Bool {
        let normalized = statement.lowercased()
        let sourceFactCues = [
            "lulu says",
            "the video says",
            "the source says",
            "the transcript says",
            "gemini says",
            "gemini analyzes",
            "learned that lulu",
            "learned that the video"
        ]
        return sourceFactCues.contains { normalized.contains($0) }
    }

    private static func resolvedScope(
        _ requestedScope: MemoryScope,
        userMessage: String,
        projectId: UUID?,
        conversationId: UUID
    ) -> (value: MemoryScope, refId: UUID?) {
        switch requestedScope {
        case .global:
            return hasDurableGlobalMarker(userMessage) ? (.global, nil) : (.conversation, conversationId)
        case .project:
            if let projectId, hasProjectMarker(userMessage) {
                return (.project, projectId)
            }
            return (.conversation, conversationId)
        case .conversation:
            return (.conversation, conversationId)
        case .selfReflection:
            return (.conversation, conversationId)
        }
    }

    private static func hasDurableGlobalMarker(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return [
            "i always",
            "i never",
            "i prefer",
            "i don't want",
            "我一直",
            "我永远",
            "我永遠",
            "我偏好",
            "我唔想"
        ].contains { normalized.contains($0) }
    }

    private static func hasProjectMarker(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return [
            "project",
            "strategy",
            "community",
            "app",
            "product",
            "startup",
            "项目",
            "項目",
            "产品",
            "產品",
            "策略"
        ].contains { normalized.contains($0) }
    }

    private static func normalizedContains(_ text: String, _ quote: String) -> Bool {
        let haystack = normalizedForMatching(text)
        let needle = normalizedForMatching(quote)
        guard !needle.isEmpty else { return false }
        return haystack.contains(needle)
    }

    private static func normalizedForMatching(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedKey(_ statement: String) -> String {
        statement
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private struct CandidateEnvelope: Decodable {
        let candidates: [CandidatePayload]
    }

    private struct CandidatePayload: Decodable {
        let type: String
        let statement: String
        let scope: String
        let confidence: Double
        let evidenceQuote: String
        let sourceNodeId: String?

        enum CodingKeys: String, CodingKey {
            case type
            case statement
            case scope
            case confidence
            case evidenceQuote = "evidence_quote"
            case sourceNodeId = "source_node_id"
        }

        var candidate: SourceLearningMemoryCandidate? {
            guard let type = MemoryAtomType(rawValue: type),
                  let scope = MemoryScope(rawValue: scope) else {
                return nil
            }
            return SourceLearningMemoryCandidate(
                type: type,
                statement: statement,
                scope: scope,
                confidence: confidence,
                evidenceQuote: evidenceQuote,
                sourceNodeId: sourceNodeId.flatMap(UUID.init(uuidString:))
            )
        }
    }

    private static func decodeCandidates(from output: String) -> [SourceLearningMemoryCandidate] {
        guard let json = extractJSON(from: output),
              let data = json.data(using: .utf8) else {
            return []
        }

        if let envelope = try? JSONDecoder().decode(CandidateEnvelope.self, from: data) {
            return envelope.candidates.compactMap(\.candidate)
        }
        if let payloads = try? JSONDecoder().decode([CandidatePayload].self, from: data) {
            return payloads.compactMap(\.candidate)
        }
        return []
    }

    private static func extractJSON(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return trimmed
        }

        if let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let end = trimmed.lastIndex(where: { $0 == "}" || $0 == "]" }),
           start <= end {
            return String(trimmed[start...end])
        }
        return nil
    }
}
