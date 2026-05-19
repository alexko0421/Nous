import Foundation

actor AutomaticMemoryPipelineScheduler {
    private let service: AutomaticMemoryPipelineService
    private static let maxReplayedActivityEvents = 20
    private var activityHandler: (@Sendable (MemoryActivityEvent) async -> Void)?
    private var latestActivityEventsByConversation: [UUID: MemoryActivityEvent] = [:]
    private var activityReplayOrder: [UUID] = []

    private struct ConversationTail {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var conversationTails: [UUID: ConversationTail] = [:]

    init(service: AutomaticMemoryPipelineService) {
        self.service = service
    }

    func setActivityHandler(_ handler: (@Sendable (MemoryActivityEvent) async -> Void)?) async {
        activityHandler = handler
        guard let handler else { return }
        for event in latestActivityEventsByConversation.values {
            await handler(event)
        }
    }

    func enqueue(_ request: AutomaticMemoryDigestRequest) {
        let previous = conversationTails[request.conversationId]?.task
        let token = UUID()
        let task = Task { [service, weak self] in
            if let previous {
                await previous.value
            }
            let result = await service.process(request)
            await self?.recordActivity(MemoryActivityEvent(
                source: .automatic,
                turnId: request.turnId,
                conversationId: request.conversationId,
                activeCount: result.activeCount,
                pendingCount: result.pendingCount,
                rejectedCount: result.rejectedCount,
                recordedAt: Date()
            ))
            _ = try? service.synthesizeDerivedMemory(
                projectId: request.projectId,
                conversationId: request.conversationId
            )
            await self?.finish(conversationId: request.conversationId, token: token)
        }
        conversationTails[request.conversationId] = ConversationTail(token: token, task: task)
    }

    func waitUntilIdle() async {
        let tasks = Array(conversationTails.values.map(\.task))
        for task in tasks {
            await task.value
        }
    }

    private func finish(conversationId: UUID, token: UUID) {
        guard conversationTails[conversationId]?.token == token else { return }
        conversationTails[conversationId] = nil
    }

    private func recordActivity(_ event: MemoryActivityEvent) async {
        if latestActivityEventsByConversation[event.conversationId] == nil {
            activityReplayOrder.append(event.conversationId)
        }
        latestActivityEventsByConversation[event.conversationId] = event
        while activityReplayOrder.count > Self.maxReplayedActivityEvents {
            let expiredConversationId = activityReplayOrder.removeFirst()
            latestActivityEventsByConversation[expiredConversationId] = nil
        }
        if let activityHandler {
            await activityHandler(event)
        }
    }
}

final class AutomaticMemoryPipelineService {
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

    func process(_ request: AutomaticMemoryDigestRequest) async -> AutomaticMemoryDigestResult {
        let curator = MemoryCurator()
        let assessment = curator.assess(
            latestUserText: request.userMessage.content,
            boundaryLines: []
        )
        guard assessment.persistenceDecision.shouldPersist else {
            return .empty
        }
        guard let llm = llmServiceProvider() else {
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
            let lifecycle = MemoryLifecycleEngine(nodeStore: nodeStore)
            var active = 0
            var pending = 0
            var rejected = 0
            for candidate in candidates {
                let currentNow = now()
                guard let atom = Self.atom(from: candidate, request: request, now: currentNow) else {
                    rejected += 1
                    continue
                }
                do {
                    let stored = try lifecycle.stageAutomaticAtom(atom, now: currentNow)
                    if stored.status == .archived {
                        rejected += 1
                    } else if stored.status == .pending {
                        pending += 1
                    } else {
                        active += 1
                    }
                } catch {
                    rejected += 1
                }
            }
            return AutomaticMemoryDigestResult(activeCount: active, pendingCount: pending, rejectedCount: rejected)
        } catch {
            return .empty
        }
    }

    func synthesizeDerivedMemory(
        projectId: UUID?,
        conversationId: UUID?
    ) throws -> AutomaticDerivedMemoryResult {
        let scope: MemoryScope = projectId == nil ? .global : .project
        let scopeRefId = projectId
        let atoms = try nodeStore.fetchMemoryAtoms(
            types: [],
            statuses: [.active],
            scope: scope,
            scopeRefId: scopeRefId,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: nil
        )
        .filter { $0.authority == .durable || ($0.authority == .tentative && $0.confidence >= 0.7) }

        guard atoms.count >= 5 else { return .empty }
        let currentNow = now()
        let existing = try nodeStore.fetchMemoryScenes(scope: scope, scopeRefId: scopeRefId).first
        let pickedAtoms = Array(atoms.prefix(8))
        let title = projectId == nil ? "Automatic memory direction" : "Project memory direction"
        let summary = Self.sceneSummary(from: pickedAtoms)
        let scene = MemoryScene(
            id: existing?.id ?? UUID(),
            scope: scope,
            scopeRefId: scopeRefId,
            title: existing?.title ?? title,
            summary: summary,
            status: .active,
            authority: .tentative,
            createdAt: existing?.createdAt ?? currentNow,
            updatedAt: currentNow
        )
        try nodeStore.upsertMemoryScene(scene, sourceAtomIds: pickedAtoms.map(\.id))
        try enforceSceneCap(scope: scope, scopeRefId: scopeRefId, now: currentNow)

        let existingModel = try nodeStore.fetchCurrentLivingSelfModel(scope: scope, scopeRefId: scopeRefId)
        let model = LivingSelfModel(
            id: existingModel?.id ?? UUID(),
            scope: scope,
            scopeRefId: scopeRefId,
            summary: Self.selfModelSummary(from: pickedAtoms, scene: scene),
            authority: .tentative,
            sourceSceneIds: [scene.id],
            createdAt: existingModel?.createdAt ?? currentNow,
            updatedAt: currentNow
        )
        try nodeStore.upsertLivingSelfModel(model)
        return AutomaticDerivedMemoryResult(sceneCount: 1, selfModelCount: 1)
    }

    private func enforceSceneCap(
        scope: MemoryScope,
        scopeRefId: UUID?,
        now: Date
    ) throws {
        let activeScenes = try nodeStore.fetchMemoryScenes(scope: scope, scopeRefId: scopeRefId)
        guard activeScenes.count > 15 else { return }

        for scene in activeScenes.dropFirst(15) {
            var archived = scene
            archived.status = .archived
            archived.updatedAt = now
            let sourceAtomIds = try nodeStore.fetchAtomIdsForMemoryScene(scene.id)
            try nodeStore.upsertMemoryScene(archived, sourceAtomIds: sourceAtomIds)
        }
    }

    private static let systemPrompt = """
    You extract Alex-specific long-term memory candidates from the latest completed Nous turn.
    Store only Alex's own preference, decision, correction, goal, rule, boundary, belief, pattern, or insight.
    Do not store assistant claims, source facts, or generic summaries as Alex memory.
    Return strict JSON only.
    """

    private static func prompt(for request: AutomaticMemoryDigestRequest) -> String {
        let sourceBlock = request.sourceMaterials.prefix(3).map { material in
            "- \(material.title): \(material.displaySource)"
        }.joined(separator: "\n")
        return """
        Conversation id: \(request.conversationId.uuidString)
        Project id: \(request.projectId?.uuidString ?? "none")
        Turn id: \(request.turnId.uuidString)

        Alex message id: \(request.userMessage.id.uuidString)
        Alex said:
        \(request.userMessage.content)

        Nous replied:
        \(request.assistantMessage.content)

        Attached source material:
        \(sourceBlock.isEmpty ? "none" : sourceBlock)

        Return JSON:
        {
          "candidates": [
            {
              "type": "identity|preference|rule|boundary|constraint|goal|plan|decision|belief|correction|pattern|insight|task",
              "statement": "Alex-specific memory statement",
              "scope": "conversation|project|global",
              "confidence": 0.0,
              "evidence_quote": "short exact quote from Alex's message",
              "corrects_target": "optional older claim this corrects"
            }
          ]
        }

        Rules:
        - evidence_quote must be copied from Alex's message only.
        - Omit candidates if Alex only asks to explain, summarize, continue, or inspect something.
        - Omit pure source facts even when the source is useful.
        - JSON only.
        """
    }

    private static func atom(
        from candidate: Candidate,
        request: AutomaticMemoryDigestRequest,
        now: Date
    ) -> MemoryAtom? {
        let statement = candidate.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard statement.count >= 12,
              let type = MemoryAtomType(rawValue: candidate.type),
              allowedTypes.contains(type)
        else { return nil }

        let evidence = candidate.evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenericPromptOnly(request.userMessage.content),
              !evidence.isEmpty,
              normalizedContains(request.userMessage.content, evidence),
              hasAlexSpecificSignal(request.userMessage.content)
        else { return nil }

        let scope = resolvedScope(
            candidate.scope,
            type: type,
            projectId: request.projectId,
            conversationId: request.conversationId
        )
        let confidence = min(max(candidate.confidence, 0.55), 0.86)
        let status = statusForAutomaticCandidate(type: type, confidence: confidence)
        return MemoryAtom(
            type: type,
            statement: statement,
            normalizedKey: MemoryGraphWriter.normalizedKey(type: type, statement: statement),
            scope: scope.value,
            scopeRefId: scope.refId,
            status: status,
            authority: .tentative,
            confidence: confidence,
            eventTime: request.userMessage.timestamp,
            createdAt: now,
            updatedAt: now,
            sourceNodeId: request.conversationId,
            sourceMessageId: request.userMessage.id,
            evidenceQuote: evidence,
            captureReason: "automatic memory digest matched Alex evidence quote",
            correctsTarget: candidate.correctsTarget?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private static let allowedTypes: Set<MemoryAtomType> = [
        .identity, .preference, .rule, .boundary, .constraint, .goal, .plan,
        .decision, .belief, .correction, .pattern, .insight, .task
    ]

    private static func statusForAutomaticCandidate(
        type: MemoryAtomType,
        confidence: Double
    ) -> MemoryStatus {
        if confidence < 0.70 {
            return .pending
        }
        if reviewRequiredTypes.contains(type) {
            return .pending
        }
        return .active
    }

    private static let reviewRequiredTypes: Set<MemoryAtomType> = [
        .identity,
        .rule,
        .boundary,
        .constraint,
        .correction,
        .pattern,
        .insight
    ]

    private static func resolvedScope(
        _ raw: String,
        type: MemoryAtomType,
        projectId: UUID?,
        conversationId: UUID
    ) -> (value: MemoryScope, refId: UUID?) {
        if raw == "global" || [.identity, .preference, .rule, .boundary, .constraint].contains(type) {
            return (.global, nil)
        }
        if raw == "project", let projectId {
            return (.project, projectId)
        }
        return (.conversation, conversationId)
    }

    private static func hasAlexSpecificSignal(_ text: String) -> Bool {
        let normalized = " \(text.lowercased()) "
        return hasExplicitSelfSignal(text) ||
            normalized.contains(" prefer ") ||
            normalized.contains(" decide ") ||
            normalized.contains(" decided ") ||
            normalized.contains(" goal ") ||
            normalized.contains(" rule ") ||
            normalized.contains("我觉得") ||
            normalized.contains("我覺得") ||
            normalized.contains("我想") ||
            normalized.contains("我唔想")
    }

    private static func isGenericPromptOnly(_ text: String) -> Bool {
        let normalized = " \(text.lowercased()) "
        let compact = normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        let genericCues = [
            " explain ",
            " explain this ",
            " explain to me ",
            " summarize ",
            " summary ",
            " tell me ",
            " tell me more ",
            " help me ",
            " help me understand ",
            " continue ",
            " inspect ",
            " look at ",
            " how ",
            " how is ",
            " how can ",
            " how should ",
            " useful ",
            " use this ",
            " apply this ",
            " what is ",
            " what does ",
            " what can ",
            "解释",
            "解釋",
            "总结",
            "總結",
            "继续",
            "繼續",
            "讲下",
            "講下",
            "睇下",
            "看看",
            "有咩用",
            "有什么用",
            "有什麼用",
            "點用",
            "点用",
            "點樣用",
            "点样用",
            "如何用"
        ]
        let hasGenericCue = genericCues.contains { cue in
            cue.unicodeScalars.allSatisfy(\.isASCII)
                ? normalized.contains(cue)
                : compact.contains(cue)
        }
        guard hasGenericCue else { return false }
        if hasExplicitRememberWriteCue(normalized: normalized, compact: compact) {
            return false
        }
        let delegatedRequestCues = [
            " i want you to ",
            " i need you to ",
            " can you ",
            " could you ",
            " please ",
            "我想你",
            "你可以",
            "你可唔可以",
            "帮我",
            "幫我"
        ]
        if delegatedRequestCues.contains(where: { cue in
            cue.unicodeScalars.allSatisfy(\.isASCII)
                ? normalized.contains(cue)
                : compact.contains(cue)
        }) {
            return true
        }
        return !hasDurableMemoryCue(normalized: normalized, compact: compact)
    }

    private static func hasExplicitRememberWriteCue(normalized: String, compact: String) -> Bool {
        let optOutCues = [
            " don't remember ",
            " do not remember ",
            " dont remember ",
            " never remember ",
            "不要记住",
            "不要記住",
            "唔好记住",
            "唔好記住"
        ]
        if optOutCues.contains(where: { cue in
            cue.unicodeScalars.allSatisfy(\.isASCII)
                ? normalized.contains(cue)
                : compact.contains(cue)
        }) {
            return false
        }

        let recallQuestionCues = [
            " do you remember ",
            " did you remember ",
            " have you remembered ",
            " remember what ",
            "你记住",
            "你記住",
            "记住了吗",
            "記住咗"
        ]
        if recallQuestionCues.contains(where: { cue in
            cue.unicodeScalars.allSatisfy(\.isASCII)
                ? normalized.contains(cue)
                : compact.contains(cue)
        }) {
            return false
        }

        let writeCues = [
            " remember that ",
            " remember this: ",
            " please remember ",
            " help me remember that ",
            " keep in memory ",
            " save this ",
            "记住",
            "記住",
            "记低",
            "記低"
        ]
        return writeCues.contains { cue in
            cue.unicodeScalars.allSatisfy(\.isASCII)
                ? normalized.contains(cue)
                : compact.contains(cue)
        }
    }

    private static func hasDurableMemoryCue(normalized: String, compact: String) -> Bool {
        let cues = [
            " i think ",
            " i believe ",
            " i realized ",
            " i realised ",
            " i learned ",
            " i prefer ",
            " i decide ",
            " i decided ",
            " i want ",
            " i don't want ",
            " my preference ",
            " my decision ",
            " my goal ",
            " my rule ",
            " my boundary ",
            "我觉得",
            "我覺得",
            "我认为",
            "我認為",
            "我发现",
            "我發現",
            "我决定",
            "我決定",
            "我偏好",
            "我唔想",
            "我的目标",
            "我的目標",
            "我嘅目标",
            "我嘅目標"
        ]
        return cues.contains { cue in
            cue.unicodeScalars.allSatisfy(\.isASCII)
                ? normalized.contains(cue)
                : compact.contains(cue)
        }
    }

    private static func hasExplicitSelfSignal(_ text: String) -> Bool {
        let normalized = " \(text.lowercased()) "
        return normalized.contains(" i ") ||
            normalized.contains(" i'm ") ||
            normalized.contains(" my ") ||
            normalized.contains(" to me ") ||
            normalized.contains(" for me ") ||
            text.contains("我")
    }

    private static func hasExplicitAuthoritySignal(_ text: String, type: MemoryAtomType) -> Bool {
        let normalized = " \(text.lowercased()) "
        if containsSpeculation(normalized) {
            return false
        }

        switch type {
        case .identity:
            return normalized.contains(" i am ") ||
                normalized.contains(" i'm ") ||
                normalized.contains(" i’m ") ||
                normalized.contains(" my identity is ") ||
                normalized.contains(" i see myself as ") ||
                normalized.contains(" i know i am ") ||
                normalized.contains(" i am the kind of ") ||
                text.contains("我係") ||
                text.contains("我是") ||
                text.contains("我就係") ||
                text.contains("我就是")
        case .rule:
            return normalized.contains(" my rule is ") ||
                normalized.contains(" the rule is ") ||
                normalized.contains(" i always ") ||
                normalized.contains(" i never ") ||
                normalized.contains(" i will ") ||
                normalized.contains(" i won't ") ||
                normalized.contains(" i won’t ") ||
                text.contains("我嘅原则") ||
                text.contains("我嘅原則") ||
                text.contains("我的原则") ||
                text.contains("我的原則") ||
                text.contains("我一定") ||
                text.contains("我唔會") ||
                text.contains("我不会")
        case .boundary:
            return normalized.contains(" my boundary is ") ||
                normalized.contains(" i don't want ") ||
                normalized.contains(" i don’t want ") ||
                normalized.contains(" i will not ") ||
                normalized.contains(" i won't ") ||
                normalized.contains(" i won’t ") ||
                text.contains("我唔想") ||
                text.contains("我不想") ||
                text.contains("我唔會") ||
                text.contains("我不会") ||
                text.contains("我嘅底线") ||
                text.contains("我嘅底線") ||
                text.contains("我的底线") ||
                text.contains("我的底線")
        default:
            return hasExplicitSelfSignal(text)
        }
    }

    private static func containsSpeculation(_ normalizedText: String) -> Bool {
        normalizedText.contains(" wonder if ") ||
            normalizedText.contains(" might ") ||
            normalizedText.contains(" maybe ") ||
            normalizedText.contains(" not sure ") ||
            normalizedText.contains(" could be ") ||
            normalizedText.contains(" i guess ") ||
            normalizedText.contains("我唔知") ||
            normalizedText.contains("我不知道") ||
            normalizedText.contains("可能") ||
            normalizedText.contains("會唔會") ||
            normalizedText.contains("会不会") ||
            normalizedText.contains("係咪") ||
            normalizedText.contains("是不是")
    }

    private static func normalizedContains(_ text: String, _ quote: String) -> Bool {
        normalize(text).contains(normalize(quote))
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeCandidates(from raw: String) -> [Candidate] {
        let decoder = JSONDecoder()
        for candidate in candidateJSONStrings(from: raw) {
            guard let data = candidate.data(using: .utf8),
                  let decoded = try? decoder.decode(CandidateEnvelope.self, from: data) else {
                continue
            }
            return decoded.candidates
        }
        return []
    }

    private static func candidateJSONStrings(from raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]

        if let fenced = fencedJSONBody(in: trimmed) {
            candidates.append(fenced)
        }
        if let object = outerJSONObject(in: trimmed) {
            candidates.append(object)
        }

        return candidates
    }

    private static func fencedJSONBody(in text: String) -> String? {
        guard let fenceStart = text.range(of: "```") else { return nil }
        let afterFence = text[fenceStart.upperBound...]
        let bodyStart: String.Index
        if afterFence.lowercased().hasPrefix("json"),
           let newline = afterFence.firstIndex(of: "\n") {
            bodyStart = afterFence.index(after: newline)
        } else {
            bodyStart = afterFence.startIndex
        }
        guard let fenceEnd = afterFence[bodyStart...].range(of: "```") else { return nil }
        return String(afterFence[bodyStart..<fenceEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func outerJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(text[start...end])
    }

    private static func sceneSummary(from atoms: [MemoryAtom]) -> String {
        let lines = atoms.prefix(5).map { "- \($0.statement)" }.joined(separator: "\n")
        return "Current automatic memory scene:\n\(lines)"
    }

    private static func selfModelSummary(from atoms: [MemoryAtom], scene: MemoryScene) -> String {
        let durableCount = atoms.filter { $0.authority == .durable }.count
        let tentativeCount = atoms.filter { $0.authority == .tentative }.count
        return """
        Inferred current self-model, not anchor truth.
        Scene: \(scene.title)
        Evidence mix: \(durableCount) durable memory atoms, \(tentativeCount) tentative memory atoms.
        \(scene.summary)
        """
    }

    private struct CandidateEnvelope: Decodable {
        let candidates: [Candidate]
    }

    private struct Candidate: Decodable {
        let type: String
        let statement: String
        let scope: String
        let confidence: Double
        let evidenceQuote: String
        let correctsTarget: String?

        enum CodingKeys: String, CodingKey {
            case type
            case statement
            case scope
            case confidence
            case evidenceQuote = "evidence_quote"
            case correctsTarget = "corrects_target"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
