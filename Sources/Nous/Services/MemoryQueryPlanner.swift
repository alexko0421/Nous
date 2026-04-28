import Foundation

enum MemoryQueryIntent: String, CaseIterable {
    case decisionHistory = "decision_history"
    case contradictionReview = "contradiction_review"
    case preferenceRecall = "preference_recall"
    case ruleRecall = "rule_recall"
    case goalPlanRecall = "goal_plan_recall"
    case generalRecall = "general_recall"
}

struct MemoryGraphRecallPacket: Equatable {
    var intent: MemoryQueryIntent?
    var timeWindowStart: Date?
    var timeWindowEnd: Date?
    var items: [String]
    var retrievedAtomIds: [UUID]

    static let empty = MemoryGraphRecallPacket(
        intent: nil,
        timeWindowStart: nil,
        timeWindowEnd: nil,
        items: [],
        retrievedAtomIds: []
    )
}

final class MemoryQueryPlanner {
    private struct Candidate {
        let text: String
        let atomIds: [UUID]
        let score: Double
        let updatedAt: Date
    }

    private static let timestampFormatter = ISO8601DateFormatter()
    static let allIntents = Set(MemoryQueryIntent.allCases)

    private let nodeStore: NodeStore
    private let graphStore: MemoryGraphStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
        self.graphStore = MemoryGraphStore(nodeStore: nodeStore)
    }

    func recall(
        currentMessage: String,
        projectId: UUID?,
        conversationId: UUID,
        limit: Int = 4,
        allowedIntents: Set<MemoryQueryIntent> = MemoryQueryPlanner.allIntents,
        queryEmbedding: [Float]? = nil,
        now: Date = Date()
    ) -> [String] {
        recallPacket(
            currentMessage: currentMessage,
            projectId: projectId,
            conversationId: conversationId,
            limit: limit,
            allowedIntents: allowedIntents,
            queryEmbedding: queryEmbedding,
            now: now
        ).items
    }

    func recallPacket(
        currentMessage: String,
        projectId: UUID?,
        conversationId: UUID,
        limit: Int = 4,
        allowedIntents: Set<MemoryQueryIntent> = MemoryQueryPlanner.allIntents,
        queryEmbedding: [Float]? = nil,
        now: Date = Date()
    ) -> MemoryGraphRecallPacket {
        let query = currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !query.isEmpty else { return .empty }

        guard let intent = Self.intent(for: query, allowedIntents: allowedIntents) else {
            // Vector entry-point: when the keyword cue matcher fails but
            // we have a query embedding AND .generalRecall is allowed,
            // run a cosine-similarity fallback so paraphrased queries
            // can still reach memory. This is the plan's "vector finds
            // the entry → graph traverses" pattern, in MVP form.
            return vectorFallbackPacket(
                query: query,
                queryEmbedding: queryEmbedding,
                projectId: projectId,
                conversationId: conversationId,
                limit: limit,
                allowedIntents: allowedIntents,
                now: now
            )
        }
        let timeWindow = Self.timeWindow(for: query, now: now)

        // SQL pushdown for type/status hits idx_memory_atoms_type_status_time.
        // Scope filter stays in Swift because isInRecallScope cross-checks a
        // conversation atom's source node project — that needs a node lookup.
        // Time window stays in Swift to preserve the fallback to created_at
        // when event_time is null.
        let atoms = ((try? nodeStore.fetchMemoryAtoms(
            types: Self.types(for: intent),
            statuses: [.active],
            scope: nil,
            scopeRefId: nil,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: nil
        )) ?? [])
            .filter { atom in
                isInRecallScope(atom, projectId: projectId, conversationId: conversationId) &&
                Self.isCurrentlyValid(atom, now: now) &&
                Self.isInTimeWindow(atom, timeWindow: timeWindow)
            }

        let candidates = buildCandidates(
            query: query,
            intent: intent,
            atoms: atoms,
            timeWindow: timeWindow,
            now: now
        )
        .sorted {
            if $0.score == $1.score {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.score > $1.score
        }
        .prefix(limit)

        let items = candidates.map(\.text)
        let retrievedAtomIds = orderedUnique(candidates.flatMap(\.atomIds))
        guard !items.isEmpty else { return .empty }

        try? graphStore.appendRecallEvent(MemoryRecallEvent(
            query: query,
            intent: intent.rawValue,
            timeWindowStart: timeWindow?.start,
            timeWindowEnd: timeWindow?.end,
            retrievedAtomIds: retrievedAtomIds,
            answerSummary: "Retrieved \(items.count) graph memory item(s)."
        ))

        return MemoryGraphRecallPacket(
            intent: intent,
            timeWindowStart: timeWindow?.start,
            timeWindowEnd: timeWindow?.end,
            items: items,
            retrievedAtomIds: retrievedAtomIds
        )
    }

    private func vectorFallbackPacket(
        query: String,
        queryEmbedding: [Float]?,
        projectId: UUID?,
        conversationId: UUID,
        limit: Int,
        allowedIntents: Set<MemoryQueryIntent>,
        now: Date
    ) -> MemoryGraphRecallPacket {
        guard let queryEmbedding,
              !queryEmbedding.isEmpty,
              allowedIntents.contains(.generalRecall)
        else {
            return .empty
        }

        let pool = ((try? nodeStore.fetchMemoryAtomsNearest(
            embedding: queryEmbedding,
            topK: max(limit * 4, limit),
            statuses: [.active]
        )) ?? [])
            .filter { atom in
                isInRecallScope(atom, projectId: projectId, conversationId: conversationId) &&
                Self.isCurrentlyValid(atom, now: now)
            }

        // Rerank by `cosine × decay + confidenceBoost`. Pure cosine surfaces
        // semantically-closest atoms but ignores whether they're still
        // load-bearing — a stale low-confidence atom can outrank a fresh
        // high-confidence one. The keyword path already applies these
        // signals; vector fallback should match.
        let scored = pool.compactMap { atom -> (atom: MemoryAtom, score: Double)? in
            guard let candidate = atom.embedding,
                  candidate.count == queryEmbedding.count
            else { return nil }
            let cosine = Double(Self.cosineSimilarity(queryEmbedding, candidate))
            let decay = Self.decayWeight(
                atom: atom,
                intent: .generalRecall,
                timeWindow: nil,
                now: now
            )
            let score = cosine * decay + Self.confidenceBoost(atom.confidence)
            return (atom, score)
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)

        guard !scored.isEmpty else { return .empty }

        let neighbors = scored.map(\.atom)
        let items = neighbors.map { formatAtomRecall($0, intent: .generalRecall) }
        let retrievedAtomIds = orderedUnique(neighbors.map(\.id))

        try? graphStore.appendRecallEvent(MemoryRecallEvent(
            query: query,
            intent: "vector_fallback",
            timeWindowStart: nil,
            timeWindowEnd: nil,
            retrievedAtomIds: retrievedAtomIds,
            answerSummary: "Vector fallback returned \(items.count) atom(s)."
        ))

        return MemoryGraphRecallPacket(
            intent: .generalRecall,
            timeWindowStart: nil,
            timeWindowEnd: nil,
            items: items,
            retrievedAtomIds: retrievedAtomIds
        )
    }

    private func buildCandidates(
        query: String,
        intent: MemoryQueryIntent,
        atoms: [MemoryAtom],
        timeWindow: (start: Date, end: Date)?,
        now: Date
    ) -> [Candidate] {
        var usedChainAtomIds = Set<UUID>()
        var candidates: [Candidate] = []

        if intent == .decisionHistory || intent == .generalRecall {
            for rejection in atoms where rejection.type == .rejection {
                if let chain = try? graphStore.decisionChain(for: rejection.id) {
                    let text = formatDecisionChainRecall(chain)
                    let ids = chainAtomIds(chain)
                    usedChainAtomIds.formUnion(ids)
                    candidates.append(Candidate(
                        text: text,
                        atomIds: ids,
                        score: Self.score(
                            query: query,
                            text: text,
                            intent: intent,
                            type: .rejection,
                            atom: rejection,
                            timeWindow: timeWindow,
                            now: now
                        ) + 0.3,
                        updatedAt: Self.rankingTime(for: rejection)
                    ))
                }
            }
        }

        for atom in atoms where !usedChainAtomIds.contains(atom.id) {
            if intent == .decisionHistory, !usedChainAtomIds.isEmpty, atom.type != .rejection {
                continue
            }
            let text = formatAtomRecall(atom, intent: intent)
            let score = Self.score(
                query: query,
                text: text,
                intent: intent,
                type: atom.type,
                atom: atom,
                timeWindow: timeWindow,
                now: now
            )
            if score >= Self.minimumScore(for: intent) {
                candidates.append(Candidate(
                    text: text,
                    atomIds: [atom.id],
                    score: score,
                    updatedAt: Self.rankingTime(for: atom)
                ))
            }
        }

        return candidates
    }

    private func isInRecallScope(_ atom: MemoryAtom, projectId: UUID?, conversationId: UUID) -> Bool {
        switch atom.scope {
        case .global:
            return true
        case .project:
            return atom.scopeRefId == projectId
        case .conversation:
            guard let scopeRefId = atom.scopeRefId else { return false }
            if scopeRefId == conversationId { return true }
            guard let projectId else { return true }
            guard let sourceNode = try? nodeStore.fetchNode(id: scopeRefId) else { return false }
            return sourceNode.projectId == projectId
        case .selfReflection:
            return false
        }
    }

    private func formatDecisionChainRecall(_ chain: MemoryDecisionChain) -> String {
        let eventTime = chain.rejection.eventTime.map { Self.timestampFormatter.string(from: $0) } ?? "unknown"
        let sourceNode = chain.rejection.sourceNodeId?.uuidString ?? "unknown"
        let sourceMessage = chain.rejection.sourceMessageId?.uuidString ?? "unknown"
        var parts = [
            "- MEMORY_CHAIN atom_id=\(chain.rejection.id.uuidString) status=\(chain.rejection.status.rawValue) event_time=\(eventTime)",
            "  source_node_id=\(sourceNode) source_message_id=\(sourceMessage)",
            "  rejected_proposal: \(chain.rejectedProposal?.statement ?? "[unknown proposal]")",
            "  rejection: \(chain.rejection.statement)"
        ]
        if !chain.reasons.isEmpty {
            parts.append("  reason: \(chain.reasons.map(\.statement).joined(separator: " / "))")
        }
        if let replacement = chain.replacement {
            parts.append("  replacement_current_direction: \(replacement.statement)")
        }
        if let sourceQuote = sourceQuote(for: chain.rejection) {
            parts.append("  source_quote: \(sourceQuote)")
        }
        return parts.joined(separator: "\n")
    }

    private func formatAtomRecall(_ atom: MemoryAtom, intent: MemoryQueryIntent) -> String {
        let eventTime = atom.eventTime.map { Self.timestampFormatter.string(from: $0) } ?? "unknown"
        let sourceNode = atom.sourceNodeId?.uuidString ?? "unknown"
        let sourceMessage = atom.sourceMessageId?.uuidString ?? "unknown"
        var parts = [
            "- MEMORY_ATOM atom_id=\(atom.id.uuidString) type=\(atom.type.rawValue) intent=\(intent.rawValue) status=\(atom.status.rawValue) event_time=\(eventTime)",
            "  source_node_id=\(sourceNode) source_message_id=\(sourceMessage)",
            "  statement: \(atom.statement)"
        ]

        let related = relatedLines(for: atom, limit: 2)
        if !related.isEmpty {
            parts.append("  related: \(related.joined(separator: " / "))")
        }

        if let sourceQuote = sourceQuote(for: atom) {
            parts.append("  source_quote: \(sourceQuote)")
        }
        return parts.joined(separator: "\n")
    }

    private func relatedLines(for atom: MemoryAtom, limit: Int) -> [String] {
        let outgoing = ((try? graphStore.edges(from: atom.id)) ?? [])
            .compactMap { edge -> String? in
                guard let target = try? nodeStore.fetchMemoryAtom(id: edge.toAtomId) else { return nil }
                return "\(edge.type.rawValue) -> \(Self.preview(target.statement, maxChars: 90))"
            }
        let incoming = ((try? graphStore.edges(to: atom.id)) ?? [])
            .compactMap { edge -> String? in
                guard let source = try? nodeStore.fetchMemoryAtom(id: edge.fromAtomId) else { return nil }
                return "\(edge.type.rawValue) <- \(Self.preview(source.statement, maxChars: 90))"
            }
        return Array((outgoing + incoming).prefix(limit))
    }

    private func sourceQuote(for atom: MemoryAtom) -> String? {
        guard let sourceNodeId = atom.sourceNodeId,
              let sourceMessageId = atom.sourceMessageId,
              let messages = try? nodeStore.fetchMessages(nodeId: sourceNodeId),
              let message = messages.first(where: { $0.id == sourceMessageId })
        else {
            return nil
        }
        return Self.preview(UserMemoryCore.stripQuoteBlocks(message.content), maxChars: 140)
    }

    private func chainAtomIds(_ chain: MemoryDecisionChain) -> [UUID] {
        orderedUnique(
            [chain.rejection.id, chain.rejectedProposal?.id, chain.replacement?.id]
                .compactMap { $0 } + chain.reasons.map(\.id)
        )
    }

    private func orderedUnique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    private static func intent(
        for query: String,
        allowedIntents: Set<MemoryQueryIntent>
    ) -> MemoryQueryIntent? {
        let normalized = query.lowercased()
        let hasHistoricalCue = containsAny(normalized, [
            "remember", "memory", "before", "previous", "last time", "three weeks",
            "3 weeks", "we had", "we said", "we discussed", "did we",
            "記得", "记得", "之前", "以前", "上次", "三周", "三週", "我哋有冇", "我们有没有"
        ])
        let hasDecisionCue = containsAny(normalized, [
            "reject", "rejected", "rejection", "decision", "decided", "proposal",
            "plan", "why", "reason", "否決", "否决", "否定", "方案", "決定",
            "决定", "點解", "点解", "為什麼", "为什么", "原因"
        ])
        let hasContradictionCue = containsAny(normalized, [
            "contradict", "conflict", "tension", "inconsistent", "矛盾", "衝突",
            "冲突", "打架", "唔一致", "不一致"
        ])
        let hasPreferenceCue = containsAny(normalized, [
            "prefer", "preference", "like", "dislike", "never want", "always want",
            "偏好", "鍾意", "钟意", "喜歡", "喜欢", "唔想", "不想", "不要", "唔要"
        ])
        let hasRuleCue = containsAny(normalized, [
            "rule", "boundary", "constraint", "principle", "instruction",
            "規則", "规则", "邊界", "边界", "約束", "约束", "原則", "原则"
        ])
        let hasGoalPlanCue = containsAny(normalized, [
            "goal", "priority", "next step", "current direction", "目標", "目标",
            "優先", "优先", "下一步", "方向", "plan", "計劃", "计划"
        ])

        let ordered: [MemoryQueryIntent?] = [
            hasContradictionCue ? .contradictionReview : nil,
            hasPreferenceCue && hasHistoricalCue ? .preferenceRecall : nil,
            hasRuleCue && hasHistoricalCue ? .ruleRecall : nil,
            hasGoalPlanCue && hasHistoricalCue ? .goalPlanRecall : nil,
            hasDecisionCue && (hasHistoricalCue || normalized.contains("reject") || normalized.contains("否決") || normalized.contains("否决")) ? .decisionHistory : nil,
            hasHistoricalCue ? .generalRecall : nil
        ]

        return ordered.compactMap { $0 }.first { allowedIntents.contains($0) }
    }

    private static func types(for intent: MemoryQueryIntent) -> Set<MemoryAtomType> {
        switch intent {
        case .decisionHistory:
            return [.decision, .rejection, .proposal, .reason, .plan]
        case .contradictionReview:
            return [.belief, .boundary, .constraint, .correction, .decision, .rejection]
        case .preferenceRecall:
            return [.preference, .boundary, .rule]
        case .ruleRecall:
            return [.rule, .constraint, .boundary, .preference]
        case .goalPlanRecall:
            return [.goal, .plan, .currentPosition, .decision, .rejection]
        case .generalRecall:
            return Set(MemoryAtomType.allCases)
        }
    }

    private static func score(
        query: String,
        text: String,
        intent: MemoryQueryIntent,
        type: MemoryAtomType,
        atom: MemoryAtom,
        timeWindow: (start: Date, end: Date)?,
        now: Date
    ) -> Double {
        let normalizedQuery = MemoryGraphAtomMapper.normalizedLine(query)
        let normalizedText = MemoryGraphAtomMapper.normalizedLine(text)
        let queryTokens = tokens(normalizedQuery)
        let textTokens = tokens(normalizedText)
        let intersection = Set(queryTokens).intersection(textTokens).count
        let union = Set(queryTokens).union(textTokens).count
        let jaccard = union == 0 ? 0 : Double(intersection) / Double(union)
        let tokenHits = queryTokens.filter { normalizedText.contains($0) }.count
        let base = jaccard
            + min(Double(tokenHits) * 0.08, 0.4)
            + typeBoost(intent: intent, type: type)
            + confidenceBoost(atom.confidence)
            + temporalBoost(atom: atom, timeWindow: timeWindow)
        return base * decayWeight(atom: atom, intent: intent, timeWindow: timeWindow, now: now)
    }

    private static func isCurrentlyValid(_ atom: MemoryAtom, now: Date) -> Bool {
        if let validFrom = atom.validFrom, validFrom > now { return false }
        if let validUntil = atom.validUntil, validUntil < now { return false }
        return true
    }

    private static func isInTimeWindow(
        _ atom: MemoryAtom,
        timeWindow: (start: Date, end: Date)?
    ) -> Bool {
        guard let timeWindow else { return true }
        let eventTime = atom.eventTime ?? atom.createdAt
        return eventTime >= timeWindow.start && eventTime <= timeWindow.end
    }

    private static func timeWindow(for query: String, now: Date) -> (start: Date, end: Date)? {
        let normalized = query.lowercased()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2

        if containsAny(normalized, ["today", "今日", "今天"]) {
            return dayWindow(for: now, calendar: calendar)
        }

        if containsAny(normalized, ["yesterday", "昨日", "昨天"]) {
            guard let date = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            return dayWindow(for: date, calendar: calendar)
        }

        if containsAny(normalized, ["recently", "recent", "最近", "近排"]) {
            guard let start = calendar.date(byAdding: .day, value: -14, to: startOfDay(now, calendar: calendar)) else {
                return nil
            }
            return (start, endOfDay(now, calendar: calendar))
        }

        if containsAny(normalized, ["last week", "previous week", "上周", "上週", "上星期", "上個星期", "上个星期"]) {
            let thisWeekStart = startOfWeek(now, calendar: calendar)
            guard let start = calendar.date(byAdding: .day, value: -7, to: thisWeekStart),
                  let end = calendar.date(byAdding: .second, value: -1, to: thisWeekStart)
            else { return nil }
            return (start, end)
        }

        if containsAny(normalized, ["last month", "previous month", "上月", "上個月", "上个月"]) {
            return monthWindow(monthsAgo: 1, now: now, calendar: calendar)
        }

        if let daysAgo = relativeAmount(in: normalized, units: ["day", "days", "日", "天"]) {
            guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { return nil }
            return dayWindow(for: date, calendar: calendar)
        }

        if let weeksAgo = relativeAmount(in: normalized, units: ["week", "weeks", "周", "週", "星期", "個星期", "个星期"]) {
            guard let center = calendar.date(byAdding: .day, value: -(weeksAgo * 7), to: now),
                  let startDate = calendar.date(byAdding: .day, value: -3, to: center),
                  let endDate = calendar.date(byAdding: .day, value: 3, to: center)
            else { return nil }
            return (
                startOfDay(startDate, calendar: calendar),
                endOfDay(endDate, calendar: calendar)
            )
        }

        if let monthsAgo = relativeAmount(in: normalized, units: ["month", "months", "月", "個月", "个月"]) {
            return monthWindow(monthsAgo: monthsAgo, now: now, calendar: calendar)
        }

        return nil
    }

    private static func temporalBoost(
        atom: MemoryAtom,
        timeWindow: (start: Date, end: Date)?
    ) -> Double {
        guard let timeWindow else { return 0 }
        let eventTime = atom.eventTime ?? atom.createdAt
        let midpoint = timeWindow.start.timeIntervalSince1970
            + (timeWindow.end.timeIntervalSince1970 - timeWindow.start.timeIntervalSince1970) / 2
        let halfWidth = max((timeWindow.end.timeIntervalSince1970 - timeWindow.start.timeIntervalSince1970) / 2, 1)
        let distance = abs(eventTime.timeIntervalSince1970 - midpoint)
        return max(0, 0.18 * (1 - min(distance / halfWidth, 1)))
    }

    private static func decayWeight(
        atom: MemoryAtom,
        intent: MemoryQueryIntent,
        timeWindow: (start: Date, end: Date)?,
        now: Date
    ) -> Double {
        guard timeWindow == nil else { return 1 }
        let referenceTime = rankingTime(for: atom)
        let ageDays = max(0, now.timeIntervalSince(referenceTime) / 86_400)
        let halfLife = halfLifeDays(for: atom.type, intent: intent)
        let floor = decayFloor(for: atom.type)
        let decayed = pow(0.5, ageDays / halfLife)
        return floor + (1 - floor) * decayed
    }

    private static func rankingTime(for atom: MemoryAtom) -> Date {
        [
            atom.lastSeenAt,
            Optional(atom.updatedAt),
            atom.eventTime,
            Optional(atom.createdAt)
        ]
        .compactMap { $0 }
        .max() ?? atom.createdAt
    }

    private static func halfLifeDays(for type: MemoryAtomType, intent: MemoryQueryIntent) -> Double {
        if intent == .decisionHistory || intent == .contradictionReview {
            return 180
        }

        switch type {
        case .identity, .rule, .boundary, .constraint, .preference:
            return 120
        case .goal, .plan, .currentPosition, .task:
            return 30
        case .event, .proposal, .decision, .rejection, .reason:
            return 75
        case .belief, .correction, .pattern, .insight:
            return 90
        case .entity:
            return 150
        }
    }

    private static func decayFloor(for type: MemoryAtomType) -> Double {
        switch type {
        case .identity, .rule, .boundary, .constraint, .preference:
            return 0.62
        case .goal, .plan, .currentPosition, .task:
            return 0.28
        case .event, .proposal, .decision, .rejection, .reason:
            return 0.4
        case .belief, .correction, .pattern, .insight, .entity:
            return 0.5
        }
    }

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    private static func confidenceBoost(_ confidence: Double) -> Double {
        min(max(confidence, 0), 1) * 0.08
    }

    private static func typeBoost(intent: MemoryQueryIntent, type: MemoryAtomType) -> Double {
        switch (intent, type) {
        case (.decisionHistory, .rejection):
            return 0.45
        case (.decisionHistory, .decision), (.decisionHistory, .proposal):
            return 0.28
        case (.preferenceRecall, .preference):
            return 0.45
        case (.ruleRecall, .rule), (.ruleRecall, .boundary), (.ruleRecall, .constraint):
            return 0.4
        case (.goalPlanRecall, .goal), (.goalPlanRecall, .plan), (.goalPlanRecall, .currentPosition):
            return 0.36
        case (.contradictionReview, .correction), (.contradictionReview, .rejection), (.contradictionReview, .boundary):
            return 0.32
        case (.generalRecall, _):
            return 0.1
        default:
            return 0.12
        }
    }

    private static func minimumScore(for intent: MemoryQueryIntent) -> Double {
        switch intent {
        case .generalRecall:
            return 0.16
        default:
            return 0.22
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func relativeAmount(in text: String, units: [String]) -> Int? {
        for unit in units {
            if let digitValue = firstRegexInt(in: text, pattern: #"(\d+)\s*\#(unit)"#),
               hasPastMarker(after: unit, in: text) {
                return digitValue
            }

            for (word, value) in chineseNumbers {
                if text.contains("\(word)\(unit)") && hasPastMarker(after: unit, in: text) {
                    return value
                }
            }
        }
        return nil
    }

    private static func firstRegexInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[swiftRange])
    }

    private static func hasPastMarker(after unit: String, in text: String) -> Bool {
        text.contains("\(unit) ago") ||
        text.contains("\(unit)前") ||
        text.contains("last \(unit)") ||
        text.contains("previous \(unit)") ||
        text.contains("before")
    }

    private static var chineseNumbers: [(String, Int)] {
        [
            ("一", 1), ("二", 2), ("兩", 2), ("两", 2), ("三", 3),
            ("四", 4), ("五", 5), ("六", 6), ("七", 7), ("八", 8),
            ("九", 9), ("十", 10), ("十一", 11), ("十二", 12)
        ]
    }

    private static func dayWindow(
        for date: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        (
            startOfDay(date, calendar: calendar),
            endOfDay(date, calendar: calendar)
        )
    }

    private static func monthWindow(
        monthsAgo: Int,
        now: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date)? {
        guard let target = calendar.date(byAdding: .month, value: -monthsAgo, to: now),
              let interval = calendar.dateInterval(of: .month, for: target),
              let end = calendar.date(byAdding: .second, value: -1, to: interval.end)
        else {
            return nil
        }
        return (interval.start, end)
    }

    private static func startOfWeek(_ date: Date, calendar: Calendar) -> Date {
        let startOfDay = startOfDay(date, calendar: calendar)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay) ?? startOfDay
    }

    private static func startOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay(date, calendar: calendar)),
              let end = calendar.date(byAdding: .second, value: -1, to: nextDay)
        else {
            return date
        }
        return end
    }

    private static func tokens(_ normalized: String) -> [String] {
        normalized
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { token in
                token.count >= 3 &&
                !["what", "why", "when", "did", "the", "that", "this", "before", "about", "with"].contains(token)
            }
    }

    private static func preview(_ content: String, maxChars: Int) -> String {
        let collapsed = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxChars else { return collapsed }
        return String(collapsed.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
