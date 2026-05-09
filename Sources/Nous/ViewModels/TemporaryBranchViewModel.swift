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
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope
        self.kind = kind
        self.status = status
        self.confidence = Self.clampedConfidence(confidence)
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.evidenceQuote = evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let scopeRaw = try container.decodeIfPresent(String.self, forKey: .scope) {
            scope = TemporaryBranchMemoryCandidateScope(rawValue: scopeRaw) ?? .ignore
        } else {
            scope = .ignore
        }
        kind = try container.decode(MemoryKind.self, forKey: .kind)
        status = try container.decodeIfPresent(TemporaryBranchMemoryCandidateStatus.self, forKey: .status) ?? .pending
        confidence = Self.clampedConfidence(try container.decode(Double.self, forKey: .confidence))
        reason = (try container.decodeIfPresent(String.self, forKey: .reason) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        evidenceQuote = (try container.decodeIfPresent(String.self, forKey: .evidenceQuote) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clampedConfidence(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
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
        if SafetyGuardrails.containsHardMemoryOptOut(Self.evidenceCorpus(record: record, transcript: transcript)) {
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
        !candidate.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !candidate.evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
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
        guard !isQuestionLike(lower) else { return false }
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
        if lowSignalTokens.contains(normalized) { return true }
        if looksProbeOnlyQuestion(collapsed) { return true }
        if hasSubstantiveDurableSignal(collapsed) { return false }
        if looksLowSignalChat(collapsed) { return true }

        let lowSignalProbePhrases = [
            "contextunclear",
            "finalprobe",
            "recallprobe",
            "qaprobe",
            "memoryprobe",
            "测试probe",
            "測試probe"
        ]
        return normalized == "probe" || lowSignalProbePhrases.contains { normalized.contains($0) }
    }

    private static func looksLowSignalChat(_ text: String) -> Bool {
        guard !hasSubstantiveDurableSignal(text) else { return false }
        let lower = text.lowercased()
        let compact = lower.unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.punctuationCharacters.contains(scalar) &&
                !CharacterSet.symbols.contains(scalar)
            }
            .map(String.init)
            .joined()
        let lowSignalExact: Set<String> = [
            "hi", "hey", "hello", "yo", "ok", "okay", "okkk",
            "thanks", "thankyou", "thx", "cool", "nice", "sure",
            "yes", "no", "yep", "nope", "gotit", "understood",
            "noted", "done", "makessense", "soundsgood", "good",
            "continue", "continueplease", "继续", "繼續", "继续吧", "繼續吧",
            "继续扫", "繼續掃", "继续扫继续扫", "繼續掃繼續掃"
        ]
        if lowSignalExact.contains(compact) {
            return true
        }

        let lowSignalPhrases = [
            "thank you",
            "got it",
            "makes sense",
            "sounds good",
            "you are right",
            "you're right",
            "keep going",
            "go on",
            "continue review",
            "continue scanning",
            "继续扫",
            "繼續掃",
            "继续找",
            "繼續搵",
            "继续稳",
            "繼續穩",
            "继续检查",
            "繼續檢查",
            "继续 review",
            "繼續 review"
        ]
        return lowSignalPhrases.contains { lower.contains($0) }
    }

    private static func looksProbeOnlyQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard isQuestionLike(lower) else { return false }
        let phrases = [
            "based on what you know",
            "do you remember",
            "can you recall",
            "previously",
            "should nous",
            "should memory",
            "should we remember",
            "should we save",
            "should i remember",
            "should i save",
            "should you remember",
            "should you save",
            "should this be remembered",
            "should this be saved",
            "do we save",
            "do i save",
            "do you need to remember",
            "what should nous",
            "what should memory",
            "what should branch",
            "nous 应该",
            "nous 應該",
            "memory 应该",
            "memory 應該",
            "应该记",
            "應該記",
            "应不应该记",
            "應不應該記",
            "應唔應該記",
            "该不该记",
            "該不該記",
            "应该保存",
            "應該保存",
            "你觉得",
            "你覺得",
            "这个 project",
            "這個 project",
            "这个项目",
            "這個項目"
        ]
        return phrases.contains { lower.contains($0) }
    }

    private static func hasSubstantiveDurableSignal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let memoryMarkers = [
            "remember that",
            "记住",
            "記住",
            "记低",
            "記低"
        ]
        if memoryMarkers.contains(where: { marker in
            guard let range = lower.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) else {
                return false
            }
            let suffix = String(lower[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’「」『』（）()[]{}，,。.!！?？；;：:"))
            let compact = suffix.unicodeScalars
                .filter { scalar in
                    !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                    !CharacterSet.punctuationCharacters.contains(scalar) &&
                    !CharacterSet.symbols.contains(scalar)
                }
                .map(String.init)
                .joined()
            return compact.count >= 8 && !["了吗", "了嗎", "咗咩", "未", "what", "anything", "this", "that", "it"].contains(compact)
        }) {
            return true
        }

        let questionLike = isQuestionLike(lower)
        let horizonPhrases = [
            "from now on",
            "going forward",
            "以后",
            "以後",
            "long term",
            "长期",
            "長期"
        ]
        if !questionLike, horizonPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        guard !questionLike else { return false }

        let declarativePhrases = [
            "i prefer",
            "my preference is",
            "i decided",
            "we decided",
            "decision:",
            "decision：",
            "决定:",
            "决定：",
            "決定:",
            "決定：",
            "我偏好",
            "我決定",
            "我决定"
        ]
        let correctionMarkers = [
            "correction:",
            "correction：",
            "修正:",
            "修正：",
            "更正:",
            "更正："
        ]
        return declarativePhrases.contains { lower.contains($0) } ||
            correctionMarkers.contains { lower.contains($0) }
    }

    private static func isQuestionLike(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("?") ||
            lower.contains("？") ||
            lower.hasSuffix("吗") ||
            lower.hasSuffix("嗎") ||
            lower.hasSuffix("咩") ||
            lower.hasSuffix("么") ||
            lower.hasSuffix("未") {
            return true
        }

        let questionPrefixes = [
            "should ",
            "do you ",
            "can you ",
            "could you ",
            "would you ",
            "what ",
            "when ",
            "why ",
            "how ",
            "where ",
            "is ",
            "are ",
            "am i "
        ]
        if questionPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        let questionPhrases = [
            " should you ",
            " should we ",
            " should i ",
            " should this ",
            "是不是",
            "是否",
            "有没有",
            "有沒有",
            "应不应该",
            "應不應該",
            "應唔應該",
            "该不该",
            "該不該",
            "可不可以",
            "可唔可以",
            "能不能",
            "能唔能",
            "要不要",
            "要唔要",
            "你觉得",
            "你覺得"
        ]
        return questionPhrases.contains { lower.contains($0) }
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
