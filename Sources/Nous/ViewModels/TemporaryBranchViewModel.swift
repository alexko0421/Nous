import Foundation
import Observation

struct TemporaryBranchMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

struct TemporaryBranchSummary: Codable, Equatable {
    var topic: String
    var keyPoints: [String]
    var decisions: [String]
    var openQuestions: [String]
    var insights: [String]
    var preview: String

    enum CodingKeys: String, CodingKey {
        case topic
        case keyPoints = "key_points"
        case decisions
        case openQuestions = "open_questions"
        case insights
        case preview
    }
}

enum TemporaryBranchMemoryCandidateStatus: String, Codable {
    case pending
    case accepted
    case applied
    case rejected
}

enum TemporaryBranchMemoryCandidateScope: String, Codable {
    case conversation
    case project
    case global
    case ignore

    var memoryScope: MemoryScope? {
        switch self {
        case .conversation:
            return .conversation
        case .project:
            return .project
        case .global:
            return .global
        case .ignore:
            return nil
        }
    }
}

enum TemporaryBranchMemoryCandidateAction {
    case save
    case ignore
}

struct TemporaryBranchMemoryCandidate: Identifiable, Codable, Equatable {
    var id: UUID
    var content: String
    var scope: TemporaryBranchMemoryCandidateScope
    var kind: MemoryKind
    var status: TemporaryBranchMemoryCandidateStatus
    var confidence: Double
    var reason: String
    var evidenceQuote: String

    init(
        id: UUID = UUID(),
        content: String,
        scope: TemporaryBranchMemoryCandidateScope,
        kind: MemoryKind,
        status: TemporaryBranchMemoryCandidateStatus = .pending,
        confidence: Double,
        reason: String,
        evidenceQuote: String
    ) {
        self.id = id
        self.content = content
        self.scope = scope
        self.kind = kind
        self.status = status
        self.confidence = confidence
        self.reason = reason
        self.evidenceQuote = evidenceQuote
    }

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case scope
        case kind
        case status
        case confidence
        case reason
        case evidenceQuote = "evidence_quote"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        content = try container.decode(String.self, forKey: .content)
        if let scopeRaw = try container.decodeIfPresent(String.self, forKey: .scope) {
            scope = TemporaryBranchMemoryCandidateScope(rawValue: scopeRaw) ?? .ignore
        } else {
            scope = .ignore
        }
        kind = try container.decode(MemoryKind.self, forKey: .kind)
        status = try container.decodeIfPresent(TemporaryBranchMemoryCandidateStatus.self, forKey: .status) ?? .pending
        confidence = try container.decode(Double.self, forKey: .confidence)
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        evidenceQuote = try container.decodeIfPresent(String.self, forKey: .evidenceQuote) ?? ""
    }
}

struct TemporaryBranchRecord: Identifiable, Codable {
    var id: UUID { sourceMessage.id }

    let sourceMessage: Message
    let localContext: [Message]
    var messages: [TemporaryBranchMessage]
    var summary: TemporaryBranchSummary?
    var memoryCandidates: [TemporaryBranchMemoryCandidate]
    var updatedAt: Date
    var lastEvaluatedAt: Date?

    init(
        sourceMessage: Message,
        localContext: [Message],
        messages: [TemporaryBranchMessage],
        summary: TemporaryBranchSummary? = nil,
        memoryCandidates: [TemporaryBranchMemoryCandidate] = [],
        updatedAt: Date,
        lastEvaluatedAt: Date? = nil
    ) {
        self.sourceMessage = sourceMessage
        self.localContext = localContext
        self.messages = messages
        self.summary = summary
        self.memoryCandidates = memoryCandidates
        self.updatedAt = updatedAt
        self.lastEvaluatedAt = lastEvaluatedAt
    }

    enum CodingKeys: String, CodingKey {
        case sourceMessage
        case localContext
        case messages
        case summary
        case memoryCandidates
        case updatedAt
        case lastEvaluatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceMessage = try container.decode(Message.self, forKey: .sourceMessage)
        localContext = try container.decode([Message].self, forKey: .localContext)
        messages = try container.decode([TemporaryBranchMessage].self, forKey: .messages)
        summary = try container.decodeIfPresent(TemporaryBranchSummary.self, forKey: .summary)
        memoryCandidates = try container.decodeIfPresent([TemporaryBranchMemoryCandidate].self, forKey: .memoryCandidates) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastEvaluatedAt = try container.decodeIfPresent(Date.self, forKey: .lastEvaluatedAt)
    }

    var sourceExcerpt: String {
        Self.excerpt(from: sourceMessage.content, limit: 160)
    }

    var previewText: String {
        if let summaryPreview = summary?.preview.trimmingCharacters(in: .whitespacesAndNewlines),
           !summaryPreview.isEmpty {
            return Self.excerpt(from: summaryPreview, limit: 96)
        }
        guard let lastMessage = messages.last else { return "" }
        return Self.excerpt(from: lastMessage.content, limit: 96)
    }

    var messageCountLabel: String {
        "\(messages.count) messages"
    }

    private static func excerpt(from text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return "\(collapsed.prefix(max(0, limit - 3)))..."
    }
}

struct TemporaryBranchMemoryEvaluation {
    var summary: TemporaryBranchSummary
    var candidates: [TemporaryBranchMemoryCandidate]
}

final class TemporaryBranchMemoryEvaluator {
    private let llmServiceProvider: () -> (any LLMService)?

    init(llmServiceProvider: @escaping () -> (any LLMService)? = { nil }) {
        self.llmServiceProvider = llmServiceProvider
    }

    func evaluate(record: TemporaryBranchRecord) async -> TemporaryBranchMemoryEvaluation {
        let transcript = Self.userTranscript(from: record)
        if SafetyGuardrails.containsHardMemoryOptOut(transcript) {
            return TemporaryBranchMemoryEvaluation(
                summary: TemporaryBranchSummary(
                    topic: "Memory boundary",
                    keyPoints: ["Alex marked this branch content as do-not-remember."],
                    decisions: [],
                    openQuestions: [],
                    insights: [],
                    preview: "Do-not-remember branch content redacted."
                ),
                candidates: []
            )
        }

        if Self.isLowSignalTranscript(transcript) {
            return TemporaryBranchMemoryEvaluation(
                summary: TemporaryBranchSummary(
                    topic: Self.topic(from: record),
                    keyPoints: [],
                    decisions: [],
                    openQuestions: [],
                    insights: [],
                    preview: Self.preview(from: record)
                ),
                candidates: []
            )
        }

        if let llmEvaluation = await evaluateWithLLM(record: record, transcript: transcript) {
            return llmEvaluation
        }

        return evaluateWithHeuristics(record: record, transcript: transcript)
    }

    func evaluatedRecord(_ record: TemporaryBranchRecord) async -> TemporaryBranchRecord {
        let evaluation = await evaluate(record: record)
        return TemporaryBranchRecord(
            sourceMessage: record.sourceMessage,
            localContext: record.localContext,
            messages: record.messages,
            summary: evaluation.summary,
            memoryCandidates: Self.mergeCandidateStatuses(
                previous: record.memoryCandidates,
                proposed: evaluation.candidates
            ),
            updatedAt: Date(),
            lastEvaluatedAt: Date()
        )
    }

    private func evaluateWithLLM(record: TemporaryBranchRecord, transcript: String) async -> TemporaryBranchMemoryEvaluation? {
        guard let llmService = llmServiceProvider() else { return nil }
        do {
            let stream = try await llmService.generate(
                messages: [
                    LLMMessage(role: "user", content: Self.evaluationPrompt(record: record, transcript: transcript))
                ],
                system: nil
            )
            var raw = ""
            for try await chunk in stream {
                raw += chunk
            }
            guard let payload = Self.decodePayload(from: raw) else { return nil }
            return TemporaryBranchMemoryEvaluation(
                summary: payload.summary,
                candidates: payload.memoryCandidates.filter { candidate in
                    Self.shouldSurface(candidate) &&
                    Self.isGrounded(candidate, in: Self.evidenceCorpus(record: record, transcript: transcript))
                }
            )
        } catch {
            return nil
        }
    }

    private func evaluateWithHeuristics(record: TemporaryBranchRecord, transcript: String) -> TemporaryBranchMemoryEvaluation {
        let summary = TemporaryBranchSummary(
            topic: Self.topic(from: record),
            keyPoints: transcript.isEmpty ? [] : [Self.excerpt(transcript, limit: 160)],
            decisions: Self.lines(containing: "decision", in: transcript),
            openQuestions: [],
            insights: [],
            preview: Self.preview(from: record)
        )
        var candidates: [TemporaryBranchMemoryCandidate] = []

        if let decisionLine = Self.firstLine(containingAny: ["decision:", "决定:", "決定:"], in: transcript)
            ?? (Self.looksLikeProjectDecision(transcript) ? Self.firstUserLine(from: record) : nil) {
            candidates.append(TemporaryBranchMemoryCandidate(
                content: Self.trimDecisionPrefix(decisionLine),
                scope: .project,
                kind: .decision,
                confidence: 0.72,
                reason: "Temporary branch captured an explicit product decision.",
                evidenceQuote: Self.excerpt(decisionLine, limit: 180)
            ))
        }

        if Self.looksLikeStablePreference(transcript) {
            candidates.append(TemporaryBranchMemoryCandidate(
                content: Self.excerpt(Self.firstUserLine(from: record) ?? transcript, limit: 180),
                scope: .global,
                kind: .preference,
                confidence: 0.68,
                reason: "Temporary branch captured a stable thinking preference.",
                evidenceQuote: Self.excerpt(Self.firstUserLine(from: record) ?? transcript, limit: 180)
            ))
        }

        return TemporaryBranchMemoryEvaluation(summary: summary, candidates: candidates)
    }

    private static func evaluationPrompt(record: TemporaryBranchRecord, transcript: String) -> String {
        """
        Summarize this temporary branch without importing the raw transcript into the main chat.
        Return strict JSON with keys: summary, memory_candidates.
        Source: \(record.sourceMessage.content)
        Branch transcript:
        \(transcript)
        """
    }

    private static func decodePayload(from raw: String) -> TemporaryBranchMemoryPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let first = trimmed.firstIndex(of: "{"),
           let last = trimmed.lastIndex(of: "}") {
            json = String(trimmed[first...last])
        } else {
            json = trimmed
        }
        return try? JSONDecoder().decode(TemporaryBranchMemoryPayload.self, from: Data(json.utf8))
    }

    private static func shouldSurface(_ candidate: TemporaryBranchMemoryCandidate) -> Bool {
        candidate.confidence >= 0.55 &&
        candidate.scope != .ignore &&
        candidate.status != .applied &&
        candidate.status != .rejected
    }

    private static func isGrounded(_ candidate: TemporaryBranchMemoryCandidate, in transcript: String) -> Bool {
        let evidence = candidate.evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidence.isEmpty else { return false }
        return transcript.range(of: evidence, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func evidenceCorpus(record: TemporaryBranchRecord, transcript: String) -> String {
        [
            record.sourceMessage.content,
            record.localContext.map(\.content).joined(separator: "\n"),
            transcript
        ]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func userTranscript(from record: TemporaryBranchRecord) -> String {
        record.messages
            .filter { $0.role == .user }
            .map(\.content)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preview(from record: TemporaryBranchRecord) -> String {
        if let firstUserLine = firstUserLine(from: record) {
            return excerpt(firstUserLine, limit: 96)
        }
        return excerpt(record.messages.first?.content ?? record.sourceMessage.content, limit: 96)
    }

    private static func firstUserLine(from record: TemporaryBranchRecord) -> String? {
        record.messages.first(where: { $0.role == .user })?.content
    }

    private static func topic(from record: TemporaryBranchRecord) -> String {
        let source = record.sourceMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? "Temporary branch" : excerpt(source, limit: 48)
    }

    private static func lines(containing needle: String, in text: String) -> [String] {
        text.components(separatedBy: .newlines).filter {
            $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func firstLine(containing needle: String, in text: String) -> String? {
        lines(containing: needle, in: text).first
    }

    private static func firstLine(containingAny needles: [String], in text: String) -> String? {
        needles.lazy.compactMap { firstLine(containing: $0, in: text) }.first
    }

    private static func trimDecisionPrefix(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"^\s*(decision|决定|決定)\s*[:：]\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func looksLikeStablePreference(_ text: String) -> Bool {
        let lower = text.lowercased()
        return (lower.contains("long term") || lower.contains("长期") || lower.contains("長期")) &&
            (lower.contains("prefer") || lower.contains("偏好") || lower.contains("non-linear thinking"))
    }

    private static func looksLikeProjectDecision(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("should") ||
            lower.contains("must") ||
            lower.contains("应该") ||
            lower.contains("應該") else {
            return false
        }
        return lower.contains("nous") ||
            lower.contains("branch") ||
            lower.contains("memory") ||
            lower.contains("ui") ||
            lower.contains("product") ||
            lower.contains("architecture") ||
            lower.contains("架构") ||
            lower.contains("產品") ||
            lower.contains("产品")
    }

    private static func mergeCandidateStatuses(
        previous: [TemporaryBranchMemoryCandidate],
        proposed: [TemporaryBranchMemoryCandidate]
    ) -> [TemporaryBranchMemoryCandidate] {
        let settled = previous.filter { $0.status == .applied || $0.status == .rejected }
        var merged = settled
        for candidate in proposed where shouldSurface(candidate) {
            if let old = previous.first(where: { normalizedKey($0) == normalizedKey(candidate) }) {
                if old.status == .applied || old.status == .rejected {
                    continue
                }
                var restored = candidate
                restored.id = old.id
                restored.status = old.status
                merged.append(restored)
            } else {
                merged.append(candidate)
            }
        }
        return merged
    }

    private static func normalizedKey(_ candidate: TemporaryBranchMemoryCandidate) -> String {
        "\(candidate.scope.rawValue)|\(candidate.content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private static func isLowSignalTranscript(_ text: String) -> Bool {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return true }

        let normalized = collapsed.lowercased().unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.punctuationCharacters.contains(scalar) &&
                !CharacterSet.symbols.contains(scalar)
            }
            .map(String.init)
            .joined()

        let lowSignalTokens: Set<String> = [
            "hi", "hey", "hello", "yo", "ok", "okay", "okkk", "thanks", "thankyou",
            "lol", "haha", "哈哈", "好", "好呀", "嗯", "嗯嗯", "唔该", "唔該"
        ]
        return lowSignalTokens.contains(normalized)
    }

    private static func excerpt(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return "\(collapsed.prefix(max(0, limit - 3)))..."
    }
}

private struct TemporaryBranchMemoryPayload: Decodable {
    var summary: TemporaryBranchSummary
    var memoryCandidates: [TemporaryBranchMemoryCandidate]

    enum CodingKeys: String, CodingKey {
        case summary
        case memoryCandidates = "memory_candidates"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(TemporaryBranchSummary.self, forKey: .summary)
        memoryCandidates = try container.decodeIfPresent([TemporaryBranchMemoryCandidate].self, forKey: .memoryCandidates) ?? []
    }
}

@Observable
@MainActor
final class TemporaryBranchViewModel {
    var sourceMessage: Message?
    var localContext: [Message] = []
    var messages: [TemporaryBranchMessage] = []
    var inputText: String = ""
    var currentResponse: String = ""
    var currentThinkingStartedAt: Date?
    var isGenerating: Bool = false
    private var feedbackByMessageId: [UUID: JudgeFeedback] = [:]
    private var recordsBySourceMessageId: [UUID: TemporaryBranchRecord] = [:]

    var isPresented: Bool {
        sourceMessage != nil
    }

    var sourceExcerpt: String {
        guard let sourceMessage else { return "" }
        return Self.excerpt(from: sourceMessage.content)
    }

    func open(
        from message: Message,
        in messages: [Message],
        localContextRadius: Int = 3
    ) {
        let resolvedLocalContext = Self.localContext(
            around: message,
            in: messages,
            radius: localContextRadius
        )

        sourceMessage = message
        localContext = resolvedLocalContext
        self.messages = recordsBySourceMessageId[message.id]?.messages ?? []
        inputText = ""
        currentResponse = ""
        currentThinkingStartedAt = nil
        isGenerating = false
    }

    func close() {
        persistPresentedBranchIfNeeded()
        sourceMessage = nil
        localContext = []
        messages = []
        inputText = ""
        currentResponse = ""
        currentThinkingStartedAt = nil
        isGenerating = false
    }

    func record(for sourceMessageId: UUID) -> TemporaryBranchRecord? {
        recordsBySourceMessageId[sourceMessageId]
    }

    func loadRecords(_ records: [TemporaryBranchRecord]) {
        recordsBySourceMessageId = Dictionary(
            uniqueKeysWithValues: records.map { ($0.sourceMessage.id, $0) }
        )
    }

    func reset(records: [TemporaryBranchRecord] = []) {
        sourceMessage = nil
        localContext = []
        messages = []
        inputText = ""
        currentResponse = ""
        currentThinkingStartedAt = nil
        isGenerating = false
        loadRecords(records)
        feedbackByMessageId = [:]
    }

    func presentedRecordSnapshot() -> TemporaryBranchRecord? {
        guard let sourceMessage else { return nil }
        return recordSnapshot(for: sourceMessage, localContext: localContext)
    }

    func feedback(forMessageId messageId: UUID) -> JudgeFeedback? {
        feedbackByMessageId[messageId]
    }

    func recordFeedback(forMessageId messageId: UUID, feedback: JudgeFeedback) {
        if feedbackByMessageId[messageId] == feedback {
            feedbackByMessageId[messageId] = nil
        } else {
            feedbackByMessageId[messageId] = feedback
        }
    }

    func canRegenerateAssistantMessage(_ messageId: UUID) -> Bool {
        guard !isGenerating,
              let latestAssistant = messages.last,
              latestAssistant.id == messageId,
              latestAssistant.role == .assistant
        else { return false }

        return messages.dropLast().contains { $0.role == .user }
    }

    func send(using llmServiceProvider: () -> (any LLMService)?) async {
        guard let sourceMessage else { return }
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isGenerating else { return }

        let userMessage = TemporaryBranchMessage(role: .user, content: query)
        messages.append(userMessage)
        inputText = ""
        currentResponse = ""
        currentThinkingStartedAt = Date()
        isGenerating = true
        defer {
            isGenerating = false
            currentResponse = ""
            currentThinkingStartedAt = nil
        }

        guard let llmService = llmServiceProvider() else {
            messages.append(TemporaryBranchMessage(
                role: .assistant,
                content: "No active model is available for this temporary branch."
            ))
            return
        }

        do {
            let stream = try await llmService.generate(
                messages: transcriptMessages(),
                system: PromptContextAssembler.temporaryBranchSystemPrompt(
                    sourceMessage: sourceMessage,
                    localContext: localContext
                )
            )
            var accumulated = ""
            for try await chunk in stream {
                accumulated += chunk
                currentResponse = accumulated
            }

            let normalized = AssistantTurnNormalizer.normalize(accumulated).assistantContent
            let finalContent = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalContent.isEmpty {
                messages.append(TemporaryBranchMessage(
                    role: .assistant,
                    content: finalContent
                ))
            }
        } catch is CancellationError {
            return
        } catch {
            messages.append(TemporaryBranchMessage(
                role: .assistant,
                content: "I couldn't finish this branch reply. \(error.localizedDescription)"
            ))
        }
    }

    func regenerateLatestAssistant(using llmServiceProvider: () -> (any LLMService)?) async {
        guard let sourceMessage,
              let latestAssistant = messages.last,
              canRegenerateAssistantMessage(latestAssistant.id)
        else { return }

        feedbackByMessageId[latestAssistant.id] = nil
        messages.removeLast()
        currentResponse = ""
        currentThinkingStartedAt = Date()
        isGenerating = true
        defer {
            isGenerating = false
            currentResponse = ""
            currentThinkingStartedAt = nil
        }

        guard let llmService = llmServiceProvider() else {
            messages.append(TemporaryBranchMessage(
                role: .assistant,
                content: "No active model is available for this temporary branch."
            ))
            return
        }

        do {
            let stream = try await llmService.generate(
                messages: transcriptMessages(),
                system: PromptContextAssembler.temporaryBranchSystemPrompt(
                    sourceMessage: sourceMessage,
                    localContext: localContext
                )
            )
            var accumulated = ""
            for try await chunk in stream {
                accumulated += chunk
                currentResponse = accumulated
            }

            let normalized = AssistantTurnNormalizer.normalize(accumulated).assistantContent
            let finalContent = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalContent.isEmpty {
                messages.append(TemporaryBranchMessage(
                    role: .assistant,
                    content: finalContent
                ))
            }
        } catch is CancellationError {
            return
        } catch {
            messages.append(TemporaryBranchMessage(
                role: .assistant,
                content: "I couldn't finish this branch reply. \(error.localizedDescription)"
            ))
        }
    }

    private func transcriptMessages() -> [LLMMessage] {
        messages.map { message in
            LLMMessage(
                role: message.role == .user ? "user" : "assistant",
                content: message.content
            )
        }
    }

    private func persistPresentedBranchIfNeeded() {
        guard let sourceMessage else { return }

        guard let record = recordSnapshot(for: sourceMessage, localContext: localContext) else { return }
        recordsBySourceMessageId[sourceMessage.id] = record
    }

    private func recordSnapshot(
        for sourceMessage: Message,
        localContext: [Message]
    ) -> TemporaryBranchRecord? {
        var transcript = messages
        let streamingText = currentResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if !streamingText.isEmpty {
            transcript.append(TemporaryBranchMessage(role: .assistant, content: streamingText))
        }

        guard !transcript.isEmpty else { return nil }
        let existingRecord = recordsBySourceMessageId[sourceMessage.id]
        let didTranscriptChange = existingRecord?.messages != transcript
        let preservedCandidates: [TemporaryBranchMemoryCandidate]
        if didTranscriptChange {
            preservedCandidates = existingRecord?.memoryCandidates.filter {
                $0.status == .applied || $0.status == .rejected
            } ?? []
        } else {
            preservedCandidates = existingRecord?.memoryCandidates ?? []
        }

        return TemporaryBranchRecord(
            sourceMessage: sourceMessage,
            localContext: localContext,
            messages: transcript,
            summary: didTranscriptChange ? nil : existingRecord?.summary,
            memoryCandidates: preservedCandidates,
            updatedAt: Date(),
            lastEvaluatedAt: didTranscriptChange ? nil : existingRecord?.lastEvaluatedAt
        )
    }

    private static func localContext(
        around sourceMessage: Message,
        in messages: [Message],
        radius: Int
    ) -> [Message] {
        guard let sourceIndex = messages.firstIndex(where: { $0.id == sourceMessage.id }) else {
            return [sourceMessage]
        }

        let lowerBound = max(messages.startIndex, sourceIndex - radius)
        let upperBound = min(messages.index(before: messages.endIndex), sourceIndex + radius)
        return Array(messages[lowerBound...upperBound])
    }

    private static func excerpt(from text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 160 else { return collapsed }
        return "\(collapsed.prefix(157))..."
    }
}
