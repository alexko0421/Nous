import Foundation

protocol SlowCognitionArtifactProviding {
    func artifacts(
        userId: String,
        currentInput: String,
        currentNode: NousNode,
        projectId: UUID?,
        now: Date
    ) throws -> [CognitionArtifact]
}

final class SlowCognitionArtifactProvider: SlowCognitionArtifactProviding {
    private let nodeStore: NodeStore
    private let shadowLearningStore: (any ShadowLearningStoring)?

    init(
        nodeStore: NodeStore,
        shadowLearningStore: (any ShadowLearningStoring)? = nil
    ) {
        self.nodeStore = nodeStore
        self.shadowLearningStore = shadowLearningStore
    }

    func artifacts(
        userId: String = "alex",
        currentInput: String,
        currentNode: NousNode,
        projectId: UUID?,
        now: Date
    ) throws -> [CognitionArtifact] {
        var artifacts: [CognitionArtifact] = []

        let claims = try nodeStore.fetchActiveReflectionClaims(projectId: projectId)
        let evidence = try nodeStore.fetchReflectionEvidence(reflectionIds: claims.map(\.id))
        artifacts.append(contentsOf: WeeklyReflectionCognitionAdapter.artifacts(
            claims: claims,
            evidence: evidence
        ))

        if let shadowLearningStore {
            let patterns = try shadowLearningStore.fetchPromptEligiblePatterns(
                userId: userId,
                now: now,
                limit: 16
            )
            artifacts.append(contentsOf: patterns.compactMap(ShadowLearningCognitionAdapter.artifact))
        }

        let relationshipArtifacts = try nodeStore.fetchEdges(nodeId: currentNode.id)
            .prefix(8)
            .compactMap { edge -> CognitionArtifact? in
                guard let source = try nodeStore.fetchNode(id: edge.sourceId),
                      let target = try nodeStore.fetchNode(id: edge.targetId) else {
                    return nil
                }
                return GalaxyRelationCognitionAdapter.artifact(edge: edge, source: source, target: target)
            }
        artifacts.append(contentsOf: relationshipArtifacts)

        return artifacts
    }
}

protocol CognitionReviewing {
    func review(plan: TurnPlan, executionResult: TurnExecutionResult) throws -> CognitionArtifact?
}

final class CognitionReviewer: CognitionReviewing {
    private static let sourceJobId = "silent_post_turn_review"
    private static let memoryReferencePhrases = [
        "based on your notes",
        "from your notes",
        "your notes",
        "from memory",
        "we discussed",
        "previously",
        "as you said before",
        "according to your",
        "你之前",
        "之前讲",
        "之前講",
        "根据你",
        "根據你",
        "记得",
        "記得"
    ]
    private static let excerptBoundaryCharacters: Set<Character> = [".", "!", "?", "。", "！", "？", "\n"]

    func review(plan: TurnPlan, executionResult: TurnExecutionResult) throws -> CognitionArtifact? {
        guard isReviewableHighStakesTurn(plan) else {
            return nil
        }

        let unsupportedMemoryExcerpt = unsupportedMemoryReferenceExcerpt(
            for: plan,
            executionResult: executionResult
        )
        let riskFlags = riskFlags(unsupportedMemoryExcerpt: unsupportedMemoryExcerpt)
        let artifact = CognitionArtifact(
            organ: .reviewer,
            title: "Silent reviewer audit",
            summary: summary(for: riskFlags, hasMemorySignal: plan.promptTrace.hasMemorySignal),
            confidence: riskFlags.isEmpty ? 0.74 : 0.62,
            jurisdiction: .turnContext,
            evidenceRefs: evidenceRefs(
                for: plan,
                unsupportedMemoryExcerpt: unsupportedMemoryExcerpt
            ),
            riskFlags: riskFlags,
            trace: CognitionTrace(
                producer: .reviewer,
                sourceJobId: Self.sourceJobId
            )
        )
        return try artifact.validated()
    }

    private func isReviewableHighStakesTurn(_ plan: TurnPlan) -> Bool {
        if let route = plan.promptTrace.turnSteward?.route,
           route == .plan || route == .direction {
            return true
        }

        if let mode = plan.nextQuickActionModeIfCompleted,
           mode == .plan || mode == .direction {
            return true
        }

        if let mode = plan.agentLoopMode,
           mode == .plan || mode == .direction {
            return true
        }

        return false
    }

    private func evidenceRefs(
        for plan: TurnPlan,
        unsupportedMemoryExcerpt: String?
    ) -> [CognitionEvidenceRef] {
        var refs = [
            CognitionEvidenceRef(
                source: .message,
                id: plan.prepared.userMessage.id.uuidString,
                quote: snippet(plan.prepared.userMessage.content)
            )
        ]

        refs.append(contentsOf: plan.citations.prefix(4).map { citation in
            CognitionEvidenceRef(
                source: .node,
                id: citation.node.id.uuidString,
                quote: snippet(citation.surfacedSnippet)
            )
        })

        if let unsupportedMemoryExcerpt {
            refs.append(
                CognitionEvidenceRef(
                    source: .assistantDraft,
                    id: "\(plan.turnId.uuidString):assistant_draft",
                    quote: unsupportedMemoryExcerpt
                )
            )
        }

        return refs
    }

    private func unsupportedMemoryReferenceExcerpt(
        for plan: TurnPlan,
        executionResult: TurnExecutionResult
    ) -> String? {
        guard !plan.promptTrace.hasMemorySignal else {
            return nil
        }

        return memoryReferenceExcerpt(in: executionResult.assistantContent)
    }

    private func riskFlags(unsupportedMemoryExcerpt: String?) -> [String] {
        guard unsupportedMemoryExcerpt != nil else {
            return []
        }
        return ["unsupported_memory_reference"]
    }

    private func memoryReferenceExcerpt(in text: String) -> String? {
        for candidate in excerptCandidates(in: text) {
            for phrase in Self.memoryReferencePhrases {
                if let range = candidate.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) {
                    return snippet(candidate, centeredOn: range)
                }
            }
        }
        return nil
    }

    private func excerptCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if Self.excerptBoundaryCharacters.contains(character) {
                appendCandidate(current, to: &candidates)
                current = ""
            }
        }
        appendCandidate(current, to: &candidates)

        return candidates
    }

    private func appendCandidate(_ text: String, to candidates: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        candidates.append(trimmed)
    }

    private func summary(for riskFlags: [String], hasMemorySignal: Bool) -> String {
        if riskFlags.isEmpty {
            if hasMemorySignal {
                return "Silent reviewer saw no obvious evidence-boundary issue against the attached memory signals."
            }
            return "Silent reviewer saw no obvious evidence-boundary issue in this high-stakes turn."
        }

        return "Silent reviewer flagged possible evidence-boundary issues: \(riskFlags.joined(separator: ", "))."
    }

    private func snippet(_ text: String, limit: Int = 220) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit))
    }

    private func snippet(
        _ text: String,
        centeredOn range: Range<String.Index>,
        limit: Int = 220
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }

        let matchStartOffset = trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)
        let matchLength = trimmed.distance(from: range.lowerBound, to: range.upperBound)
        let contextBefore = max(0, (limit - matchLength) / 2)
        let proposedStartOffset = max(0, matchStartOffset - contextBefore)
        let endOffset = min(trimmed.count, proposedStartOffset + limit)
        let startOffset = max(0, endOffset - limit)
        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: startOffset)
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: endOffset)
        return String(trimmed[startIndex..<endIndex])
    }
}

enum WeeklyReflectionCognitionAdapter {
    static func artifacts(
        run: ReflectionRun,
        claims: [ReflectionClaim],
        evidence: [ReflectionEvidence]
    ) -> [CognitionArtifact] {
        artifacts(claims: claims, evidence: evidence, sourceRunId: run.id)
    }

    static func artifacts(
        claims: [ReflectionClaim],
        evidence: [ReflectionEvidence]
    ) -> [CognitionArtifact] {
        artifacts(claims: claims, evidence: evidence, sourceRunId: nil)
    }

    private static func artifacts(
        claims: [ReflectionClaim],
        evidence: [ReflectionEvidence],
        sourceRunId: UUID?
    ) -> [CognitionArtifact] {
        claims.compactMap { claim in
            let evidenceRefs = evidence
                .filter { $0.reflectionId == claim.id }
                .map { CognitionEvidenceRef(source: .message, id: $0.messageId.uuidString) }

            let artifact = CognitionArtifact(
                id: claim.id,
                organ: .patternAnalyst,
                title: "Weekly reflection pattern",
                summary: claim.claim,
                confidence: claim.confidence,
                jurisdiction: .selfReflection,
                evidenceRefs: evidenceRefs,
                suggestedSurfacing: claim.whyNonObvious,
                trace: CognitionTrace(
                    runId: sourceRunId ?? claim.runId,
                    producer: .patternAnalyst,
                    sourceJobId: BackgroundAIJobID.weeklyReflection.rawValue,
                    createdAt: claim.createdAt
                ),
                createdAt: claim.createdAt
            )
            return try? artifact.validated()
        }
    }
}

enum ShadowLearningCognitionAdapter {
    static func artifact(from pattern: ShadowLearningPattern) -> CognitionArtifact? {
        let evidenceRefs = pattern.evidenceMessageIds.map {
            CognitionEvidenceRef(source: .message, id: $0.uuidString)
        }

        let artifact = CognitionArtifact(
            id: pattern.id,
            organ: .behaviorLearner,
            title: pattern.label,
            summary: pattern.summary,
            confidence: pattern.confidence,
            jurisdiction: .shadowLearning,
            evidenceRefs: evidenceRefs,
            suggestedSurfacing: pattern.promptFragment,
            riskFlags: pattern.status == .fading ? ["fading"] : [],
            trace: CognitionTrace(
                runId: pattern.id,
                producer: .behaviorLearner,
                sourceJobId: "shadow_learning",
                createdAt: pattern.lastSeenAt
            ),
            createdAt: pattern.lastSeenAt
        )
        return try? artifact.validated()
    }
}

enum GalaxyRelationCognitionAdapter {
    static func artifact(
        verdict: GalaxyRelationVerdict,
        source: NousNode,
        target: NousNode
    ) -> CognitionArtifact {
        var evidenceRefs = [
            CognitionEvidenceRef(
                source: .node,
                id: source.id.uuidString,
                quote: verdict.sourceEvidence
            ),
            CognitionEvidenceRef(
                source: .node,
                id: target.id.uuidString,
                quote: verdict.targetEvidence
            )
        ]

        if let sourceAtomId = verdict.sourceAtomId {
            evidenceRefs.append(CognitionEvidenceRef(source: .memoryAtom, id: sourceAtomId.uuidString))
        }
        if let targetAtomId = verdict.targetAtomId {
            evidenceRefs.append(CognitionEvidenceRef(source: .memoryAtom, id: targetAtomId.uuidString))
        }

        return CognitionArtifact(
            organ: .relationshipScout,
            title: "Galaxy relationship: \(verdict.relationKind.rawValue)",
            summary: verdict.explanation,
            confidence: Double(verdict.confidence),
            jurisdiction: .graphMemory,
            evidenceRefs: evidenceRefs,
            suggestedSurfacing: "Use only when the current turn touches this relationship.",
            trace: CognitionTrace(
                producer: .relationshipScout,
                sourceJobId: BackgroundAIJobID.galaxyRelationRefinement.rawValue
            )
        )
    }

    static func artifact(
        edge: NodeEdge,
        source: NousNode,
        target: NousNode
    ) -> CognitionArtifact? {
        guard let explanation = edge.explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !explanation.isEmpty else {
            return nil
        }

        var evidenceRefs = [
            CognitionEvidenceRef(
                source: .node,
                id: source.id.uuidString,
                quote: edge.sourceEvidence
            ),
            CognitionEvidenceRef(
                source: .node,
                id: target.id.uuidString,
                quote: edge.targetEvidence
            )
        ]

        if let sourceAtomId = edge.sourceAtomId {
            evidenceRefs.append(CognitionEvidenceRef(source: .memoryAtom, id: sourceAtomId.uuidString))
        }
        if let targetAtomId = edge.targetAtomId {
            evidenceRefs.append(CognitionEvidenceRef(source: .memoryAtom, id: targetAtomId.uuidString))
        }

        let artifact = CognitionArtifact(
            id: edge.id,
            organ: .relationshipScout,
            title: "Galaxy relationship: \(edge.relationKind.rawValue)",
            summary: explanation,
            confidence: Double(edge.confidence),
            jurisdiction: .graphMemory,
            evidenceRefs: evidenceRefs,
            suggestedSurfacing: "Use only when the current turn touches this relationship.",
            trace: CognitionTrace(
                runId: edge.id,
                producer: .relationshipScout,
                sourceJobId: BackgroundAIJobID.galaxyRelationRefinement.rawValue
            )
        )
        return try? artifact.validated()
    }
}

enum CognitionArtifactSelector {
    static func selectForChat(
        currentInput: String?,
        artifacts: [CognitionArtifact]
    ) -> CognitionArtifact? {
        let inputTokens = tokens(from: currentInput ?? "")
        guard !inputTokens.isEmpty else { return nil }

        return artifacts.first { artifact in
            guard (try? artifact.validated()) != nil else { return false }
            let artifactTokens = tokens(from: [
                artifact.title,
                artifact.summary,
                artifact.suggestedSurfacing ?? ""
            ].joined(separator: " "))
            return !inputTokens.isDisjoint(with: artifactTokens)
        }
    }

    private static func tokens(from text: String) -> Set<String> {
        var result = Set(
            text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
        )

        var cjkRun = ""
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjkRun.unicodeScalars.append(scalar)
            } else {
                insertCJKGrams(from: cjkRun, into: &result)
                cjkRun = ""
            }
        }
        insertCJKGrams(from: cjkRun, into: &result)
        return result
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF:
            return true
        default:
            return false
        }
    }

    private static func insertCJKGrams(from text: String, into result: inout Set<String>) {
        let characters = Array(text)
        guard characters.count >= 2 else { return }
        for size in 2...min(4, characters.count) {
            guard characters.count >= size else { continue }
            for start in 0...(characters.count - size) {
                result.insert(String(characters[start..<(start + size)]))
            }
        }
    }
}

enum CognitionPromptFormatter {
    static func volatileBlock(for artifact: CognitionArtifact) -> String {
        let evidence = artifact.evidenceRefs
            .prefix(4)
            .map { ref in
                if let quote = ref.quote, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "\(ref.source.rawValue):\(ref.id) quote=\"\(quote)\""
                }
                return "\(ref.source.rawValue):\(ref.id)"
            }
            .joined(separator: "\n")

        let suggestion = artifact.suggestedSurfacing
            .map { "\nSuggested use: \($0)" } ?? ""

        return """
        ---

        SLOW COGNITION SIGNAL:
        Organ: \(artifact.organ.rawValue)
        Title: \(artifact.title)
        Confidence: \(String(format: "%.2f", artifact.confidence))
        Summary: \(artifact.summary)
        Evidence:
        \(evidence)\(suggestion)

        Use this as a sourced, optional signal for this turn. Mention it only if it genuinely helps Alex think; do not describe internal organs, agents, traces, or this injection.
        """
    }
}
