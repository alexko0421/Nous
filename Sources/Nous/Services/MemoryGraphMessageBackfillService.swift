import Foundation

struct MemoryGraphMessageBackfillReport: Equatable {
    var scannedConversations = 0
    var skippedAlreadyProcessed = 0
    var skippedNoUserTurns = 0
    var processedConversations = 0
    var insertedAtoms = 0
    var updatedAtoms = 0
    var insertedEdges = 0
    var insertedMarkers = 0
    var droppedUnverifiedChains = 0
    var failedConversations = 0
}

final class MemoryGraphMessageBackfillService {
    private let nodeStore: NodeStore
    private let llmServiceProvider: () -> LLMService?
    private let backgroundTelemetry: (any BackgroundAIJobTelemetryRecording)?

    init(
        nodeStore: NodeStore,
        llmServiceProvider: @escaping () -> LLMService?,
        backgroundTelemetry: (any BackgroundAIJobTelemetryRecording)? = nil
    ) {
        self.nodeStore = nodeStore
        self.llmServiceProvider = llmServiceProvider
        self.backgroundTelemetry = backgroundTelemetry
    }

    @discardableResult
    func runIfNeeded(maxConversations: Int = 4) async -> MemoryGraphMessageBackfillReport {
        let startedAt = Date()
        var report = MemoryGraphMessageBackfillReport()
        guard maxConversations > 0 else {
            recordBackgroundRun(
                status: .skipped,
                startedAt: startedAt,
                report: report,
                detail: "max_conversations_zero"
            )
            return report
        }
        guard let llm = llmServiceProvider() else {
            recordBackgroundRun(
                status: .skipped,
                startedAt: startedAt,
                report: report,
                detail: "llm_unavailable"
            )
            return report
        }

        let processedMarkers = Set(((try? nodeStore.fetchMemoryObservations()) ?? [])
            .map(\.rawText)
            .filter { $0.hasPrefix(Self.markerPrefix) })

        let conversations = ((try? nodeStore.fetchAllNodes()) ?? [])
            .filter { $0.type == .conversation }

        var processedThisRun = 0
        for conversation in conversations {
            if processedThisRun >= maxConversations { break }
            report.scannedConversations += 1

            guard let messages = try? nodeStore.fetchMessages(nodeId: conversation.id) else {
                report.failedConversations += 1
                continue
            }

            let userMessages = Self.cleanedUserMessages(from: messages)
            guard !userMessages.isEmpty else {
                report.skippedNoUserTurns += 1
                continue
            }

            let fingerprint = Self.fingerprint(for: userMessages)
            let marker = Self.marker(nodeId: conversation.id, fingerprint: fingerprint)
            guard !processedMarkers.contains(marker) else {
                report.skippedAlreadyProcessed += 1
                continue
            }

            do {
                let extraction = try await extractDecisionChains(
                    llm: llm,
                    conversation: conversation,
                    userMessages: userMessages
                )

                let result = try persist(
                    extraction: extraction,
                    conversation: conversation,
                    userMessages: userMessages,
                    marker: marker
                )

                report.processedConversations += 1
                report.insertedAtoms += result.insertedAtoms
                report.updatedAtoms += result.updatedAtoms
                report.insertedEdges += result.insertedEdges
                report.insertedMarkers += 1
                report.droppedUnverifiedChains += result.droppedUnverifiedChains
                processedThisRun += 1
            } catch {
                report.failedConversations += 1
            }
        }

        recordBackgroundRun(
            status: .completed,
            startedAt: startedAt,
            report: report,
            detail: "processed=\(report.processedConversations),atoms=\(report.insertedAtoms + report.updatedAtoms),edges=\(report.insertedEdges),failed=\(report.failedConversations)"
        )
        return report
    }

    private func recordBackgroundRun(
        status: BackgroundAIJobStatus,
        startedAt: Date,
        report: MemoryGraphMessageBackfillReport,
        detail: String
    ) {
        backgroundTelemetry?.record(BackgroundAIJobRunRecord(
            id: UUID(),
            jobId: .memoryGraphMessageBackfill,
            status: status,
            startedAt: startedAt,
            endedAt: Date(),
            inputCount: report.scannedConversations,
            outputCount: report.insertedAtoms + report.updatedAtoms + report.insertedEdges,
            detail: detail,
            costCents: nil
        ))
    }

    private func extractDecisionChains(
        llm: LLMService,
        conversation: NousNode,
        userMessages: [Message]
    ) async throws -> RawMessageExtraction {
        let userTurns = userMessages
            .suffix(Self.maxUserTurnsPerPrompt)
            .map { message in
                let timestamp = Self.iso8601.string(from: message.timestamp)
                return "[message_id=\(message.id.uuidString) timestamp=\(timestamp)] \(message.content)"
            }
            .joined(separator: "\n---\n")

        let prompt = """
        Conversation title:
        \(conversation.title)

        Alex's user-role messages only (ALEX ONLY — assistant replies are intentionally omitted):
        \(userTurns)

        Extract only durable decision/rejection memory from this old conversation.

        Return strict JSON:
        {
          "decision_chains": [
            {
              "rejected_proposal":"the option Alex rejected",
              "rejection":"the explicit rejection/decision",
              "reasons":["why it was rejected"],
              "replacement":"the direction chosen instead, if any",
              "evidence_message_id":"the message_id containing the evidence quote",
              "evidence_quote":"short exact quote from Alex's message proving this chain",
              "confidence":0.0-1.0
            }
          ]
        }

        Rules:
        - Only extract explicit reject/deny/not-this moments, preferably with a reason or replacement direction.
        - Every decision_chain must include evidence_message_id and evidence_quote from one listed Alex message.
        - Do not infer private motives.
        - Do not summarize the whole chat.
        - If there are no durable rejection/decision chains, return {"decision_chains":[]}
        - JSON only. No Markdown, no commentary.
        """

        let stream = try await llm.generate(
            messages: [LLMMessage(role: "user", content: prompt)],
            system: """
            You backfill Nous's graph memory from old chats.
            Use only Alex's own messages. Return strict JSON only.
            """
        )

        var raw = ""
        for try await chunk in stream {
            if Task.isCancelled { throw CancellationError() }
            raw += chunk
        }

        return try Self.decodeExtraction(raw)
    }

    private struct PersistResult {
        var insertedAtoms = 0
        var updatedAtoms = 0
        var insertedEdges = 0
        var droppedUnverifiedChains = 0
    }

    private func persist(
        extraction: RawMessageExtraction,
        conversation: NousNode,
        userMessages: [Message],
        marker: String
    ) throws -> PersistResult {
        var result = PersistResult()
        var writeResult = MemoryGraphWriteResult()
        let now = Date()

        try nodeStore.inTransaction {
            let writer = MemoryGraphWriter(nodeStore: nodeStore)
            var atoms = try nodeStore.fetchMemoryAtoms()
            var edges = try nodeStore.fetchMemoryEdges()

            for chain in extraction.decisionChains {
                guard let match = MemoryGraphEvidenceMatcher.match(
                    evidenceMessageId: chain.evidenceMessageId,
                    evidenceQuote: chain.evidenceQuote,
                    messages: userMessages
                ) else {
                    result.droppedUnverifiedChains += 1
                    try nodeStore.insertMemoryObservation(MemoryObservation(
                        rawText: Self.unverifiedObservationText(chain: chain, nodeId: conversation.id),
                        extractedType: .rejection,
                        confidence: min(chain.confidence, 0.5),
                        sourceNodeId: conversation.id,
                        sourceMessageId: nil,
                        createdAt: now
                    ))
                    continue
                }

                try writer.writeDecisionChain(
                    MemoryGraphDecisionChainInput(
                        rejectedProposal: chain.rejectedProposal,
                        rejection: chain.rejection,
                        reasons: chain.reasons,
                        replacement: chain.replacement,
                        confidence: chain.confidence,
                        scope: .conversation,
                        scopeRefId: conversation.id,
                        eventTime: match.message.timestamp,
                        sourceNodeId: conversation.id,
                        sourceMessageId: match.message.id,
                        now: now
                    ),
                    atoms: &atoms,
                    edges: &edges,
                    result: &writeResult
                )
            }

            try nodeStore.insertMemoryObservation(MemoryObservation(
                rawText: marker,
                extractedType: nil,
                confidence: 1.0,
                sourceNodeId: conversation.id,
                createdAt: now
            ))
        }

        result.insertedAtoms = writeResult.insertedAtoms
        result.updatedAtoms = writeResult.updatedAtoms
        result.insertedEdges = writeResult.insertedEdges
        return result
    }

    private func upsert(
        atom candidate: MemoryAtom,
        atoms: inout [MemoryAtom],
        result: inout PersistResult
    ) throws -> MemoryAtom {
        if let index = atoms.firstIndex(where: { Self.matches($0, candidate: candidate) }) {
            let existing = atoms[index]
            var merged = existing
            merged.statement = candidate.statement
            merged.normalizedKey = candidate.normalizedKey ?? existing.normalizedKey
            merged.status = .active
            merged.confidence = max(existing.confidence, candidate.confidence)
            merged.eventTime = existing.eventTime ?? candidate.eventTime
            merged.updatedAt = max(existing.updatedAt, candidate.updatedAt)
            merged.lastSeenAt = Self.maxDate(existing.lastSeenAt, candidate.lastSeenAt)
            merged.sourceNodeId = existing.sourceNodeId ?? candidate.sourceNodeId

            if Self.hasMeaningfulChange(existing, merged) {
                try nodeStore.updateMemoryAtom(merged)
                atoms[index] = merged
                result.updatedAtoms += 1
            }
            return merged
        }

        try nodeStore.insertMemoryAtom(candidate)
        atoms.append(candidate)
        result.insertedAtoms += 1
        return candidate
    }

    private func insertEdgeIfNeeded(
        from fromAtomId: UUID,
        to toAtomId: UUID,
        type: MemoryEdgeType,
        weight: Double,
        edges: inout [MemoryEdge],
        result: inout PersistResult
    ) throws {
        guard edges.first(where: {
            $0.fromAtomId == fromAtomId && $0.toAtomId == toAtomId && $0.type == type
        }) == nil else {
            return
        }

        let edge = MemoryEdge(
            fromAtomId: fromAtomId,
            toAtomId: toAtomId,
            type: type,
            weight: weight
        )
        try nodeStore.insertMemoryEdge(edge)
        edges.append(edge)
        result.insertedEdges += 1
    }

    private static func cleanedUserMessages(from messages: [Message]) -> [Message] {
        let assistantTurns = messages
            .filter { $0.role == .assistant }
            .map { stripQuoteBlocks($0.content).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return messages
            .filter { $0.role == .user }
            .compactMap { message -> Message? in
                let content = stripQuoteBlocks(message.content)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return nil }
                for assistantTurn in assistantTurns {
                    if tokenJaccard(content, assistantTurn) >= 0.6 {
                        return nil
                    }
                }
                return Message(
                    id: message.id,
                    nodeId: message.nodeId,
                    role: message.role,
                    content: content,
                    timestamp: message.timestamp,
                    thinkingContent: nil
                )
            }
    }

    private static func stripQuoteBlocks(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
    }

    private static func tokenJaccard(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(tokens(lhs))
        let right = Set(tokens(rhs))
        guard left.count >= 3, right.count >= 3 else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private static func tokens(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func fingerprint(for messages: [Message]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for message in messages {
            mix(message.id.uuidString, into: &hash)
            mix(String(message.timestamp.timeIntervalSince1970), into: &hash)
            mix(message.content, into: &hash)
        }
        return String(hash, radix: 16)
    }

    private static func mix(_ string: String, into hash: inout UInt64) {
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
    }

    private static func marker(nodeId: UUID, fingerprint: String) -> String {
        "\(markerPrefix)\(nodeId.uuidString)|\(fingerprint)"
    }

    private static func unverifiedObservationText(chain: RawDecisionChain, nodeId: UUID) -> String {
        let quote = chain.evidenceQuote ?? "[missing quote]"
        return [
            "unverified_decision_chain",
            nodeId.uuidString,
            chain.rejection,
            "quote=\(quote)"
        ].joined(separator: "|")
    }

    private static func normalizedKey(type: MemoryAtomType, statement: String) -> String {
        "\(type.rawValue)|\(MemoryGraphAtomMapper.normalizedLine(statement))"
    }

    private static func matches(_ atom: MemoryAtom, candidate: MemoryAtom) -> Bool {
        guard atom.scope == candidate.scope,
              atom.scopeRefId == candidate.scopeRefId,
              atom.type == candidate.type
        else { return false }

        if let atomKey = atom.normalizedKey,
           let candidateKey = candidate.normalizedKey,
           atomKey == candidateKey {
            return true
        }

        return MemoryGraphAtomMapper.normalizedLine(atom.statement)
            == MemoryGraphAtomMapper.normalizedLine(candidate.statement)
    }

    private static func hasMeaningfulChange(_ lhs: MemoryAtom, _ rhs: MemoryAtom) -> Bool {
        lhs.statement != rhs.statement
            || lhs.normalizedKey != rhs.normalizedKey
            || lhs.status != rhs.status
            || lhs.confidence != rhs.confidence
            || lhs.eventTime != rhs.eventTime
            || lhs.updatedAt != rhs.updatedAt
            || lhs.lastSeenAt != rhs.lastSeenAt
            || lhs.sourceNodeId != rhs.sourceNodeId
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.none, .none):
            return nil
        case (.some(let lhs), .none):
            return lhs
        case (.none, .some(let rhs)):
            return rhs
        case (.some(let lhs), .some(let rhs)):
            return max(lhs, rhs)
        }
    }

    private static func decodeExtraction(_ raw: String) throws -> RawMessageExtraction {
        let cleaned = stripJSONCodeFence(raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw LLMError.invalidResponse
        }
        let payload = try JSONDecoder().decode(RawMessageExtractionEnvelope.self, from: data)
        return RawMessageExtraction(decisionChains: payload.decisionChains?.compactMap(RawDecisionChain.init(payload:)) ?? [])
    }

    private static func stripJSONCodeFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        text = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct RawMessageExtractionEnvelope: Decodable {
        let decisionChains: [RawDecisionChainPayload]?

        enum CodingKeys: String, CodingKey {
            case decisionChains = "decision_chains"
        }
    }

    private struct RawDecisionChainPayload: Decodable {
        let rejectedProposal: String?
        let rejection: String?
        let reasons: [String]?
        let replacement: String?
        let evidenceMessageId: String?
        let evidenceQuote: String?
        let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case rejectedProposal = "rejected_proposal"
            case rejection
            case reasons
            case replacement
            case evidenceMessageId = "evidence_message_id"
            case evidenceQuote = "evidence_quote"
            case confidence
        }
    }

    private struct RawMessageExtraction {
        let decisionChains: [RawDecisionChain]
    }

    private struct RawDecisionChain {
        let rejectedProposal: String
        let rejection: String
        let reasons: [String]
        let replacement: String?
        let evidenceMessageId: UUID?
        let evidenceQuote: String?
        let confidence: Double

        init?(payload: RawDecisionChainPayload) {
            let proposal = payload.rejectedProposal?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rejection = payload.rejection?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !proposal.isEmpty, !rejection.isEmpty else { return nil }

            self.rejectedProposal = proposal
            self.rejection = rejection
            self.reasons = (payload.reasons ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let replacement = payload.replacement?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.replacement = replacement.isEmpty ? nil : replacement
            let evidenceQuote = payload.evidenceQuote?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.evidenceQuote = evidenceQuote.isEmpty ? nil : evidenceQuote
            self.evidenceMessageId = payload.evidenceMessageId
                .flatMap(UUID.init(uuidString:))
            self.confidence = min(1.0, max(0.0, payload.confidence ?? 0.75))
        }
    }

    private static let markerPrefix = "raw_message_graph_backfill|"
    private static let maxUserTurnsPerPrompt = 16
    private static let iso8601 = ISO8601DateFormatter()
}
