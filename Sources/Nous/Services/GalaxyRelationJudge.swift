import Foundation

struct GalaxyRelationVerdict: Equatable {
    let relationKind: GalaxyRelationKind
    let confidence: Float
    let explanation: String
    let sourceEvidence: String
    let targetEvidence: String
    let sourceAtomId: UUID?
    let targetAtomId: UUID?

    init(
        relationKind: GalaxyRelationKind,
        confidence: Float,
        explanation: String,
        sourceEvidence: String,
        targetEvidence: String,
        sourceAtomId: UUID? = nil,
        targetAtomId: UUID? = nil
    ) {
        self.relationKind = relationKind
        self.confidence = confidence
        self.explanation = explanation
        self.sourceEvidence = sourceEvidence
        self.targetEvidence = targetEvidence
        self.sourceAtomId = sourceAtomId
        self.targetAtomId = targetAtomId
    }
}

final class GalaxyRelationJudge {
    private enum LLMVerdictError: Error {
        case invalidResponse
    }

    private let minimumTopicSimilarity: Float
    private let llmServiceProvider: (() -> (any LLMService)?)?
    private let telemetry: GalaxyRelationTelemetry?

    init(
        minimumTopicSimilarity: Float = GalaxyRelationTuning.semanticThreshold,
        telemetry: GalaxyRelationTelemetry? = nil,
        llmServiceProvider: (() -> (any LLMService)?)? = nil
    ) {
        self.minimumTopicSimilarity = minimumTopicSimilarity
        self.telemetry = telemetry
        self.llmServiceProvider = llmServiceProvider
    }

    func judge(
        source: NousNode,
        target: NousNode,
        similarity: Float,
        sourceAtoms: [MemoryAtom] = [],
        targetAtoms: [MemoryAtom] = []
    ) -> GalaxyRelationVerdict? {
        if let atomVerdict = judgeAtomRelationship(
            similarity: similarity,
            sourceAtoms: sourceAtoms,
            targetAtoms: targetAtoms
        ) {
            telemetry?.record(.localVerdict)
            return atomVerdict
        }

        guard similarity >= minimumTopicSimilarity else {
            telemetry?.record(.localNil)
            return nil
        }

        telemetry?.record(.localVerdict)
        return GalaxyRelationVerdict(
            relationKind: .topicSimilarity,
            confidence: similarity,
            explanation: "These nodes are semantically close, but Nous does not yet have stronger evidence for a deeper relationship.",
            sourceEvidence: evidenceExcerpt(from: source),
            targetEvidence: evidenceExcerpt(from: target)
        )
    }

    func judgeRefined(
        source: NousNode,
        target: NousNode,
        similarity: Float,
        sourceAtoms: [MemoryAtom] = [],
        targetAtoms: [MemoryAtom] = []
    ) async -> GalaxyRelationVerdict? {
        let localVerdict = judge(
            source: source,
            target: target,
            similarity: similarity,
            sourceAtoms: sourceAtoms,
            targetAtoms: targetAtoms
        )

        guard similarity >= minimumTopicSimilarity, let llm = llmServiceProvider?() else {
            return localVerdict
        }

        do {
            let verdict = try await llmVerdict(
                llm: llm,
                source: source,
                target: target,
                similarity: similarity,
                sourceAtoms: sourceAtoms,
                targetAtoms: targetAtoms
            )
            telemetry?.record(verdict == nil ? .llmNil : .llmVerdict)
            return verdict
        } catch {
            telemetry?.record(.llmFallback)
            return localVerdict
        }
    }

    private func judgeAtomRelationship(
        similarity: Float,
        sourceAtoms: [MemoryAtom],
        targetAtoms: [MemoryAtom]
    ) -> GalaxyRelationVerdict? {
        let sourceCandidates = sourceAtoms.filter { $0.status == .active }
        let targetCandidates = targetAtoms.filter { $0.status == .active }
        guard !sourceCandidates.isEmpty, !targetCandidates.isEmpty else { return nil }

        var best: GalaxyRelationVerdict?

        for sourceAtom in sourceCandidates {
            for targetAtom in targetCandidates {
                guard let relationKind = relationKind(sourceAtom: sourceAtom, targetAtom: targetAtom) else {
                    continue
                }

                let overlap = lexicalOverlap(sourceAtom.statement, targetAtom.statement)
                let atomConfidence = Float((sourceAtom.confidence + targetAtom.confidence) / 2)
                let confidence = min(
                    GalaxyRelationTuning.maximumAtomConfidence,
                    max(similarity, atomConfidence) + Float(overlap) * GalaxyRelationTuning.atomOverlapConfidenceBoost
                )

                guard confidence >= GalaxyRelationTuning.minimumAtomConfidence || overlap > 0 else { continue }

                let verdict = GalaxyRelationVerdict(
                    relationKind: relationKind,
                    confidence: confidence,
                    explanation: explanation(for: relationKind),
                    sourceEvidence: sourceAtom.statement,
                    targetEvidence: targetAtom.statement,
                    sourceAtomId: sourceAtom.id,
                    targetAtomId: targetAtom.id
                )

                if best.map({ verdict.confidence > $0.confidence }) ?? true {
                    best = verdict
                }
            }
        }

        return best
    }

    private func relationKind(sourceAtom: MemoryAtom, targetAtom: MemoryAtom) -> GalaxyRelationKind? {
        let pair = (sourceAtom.type, targetAtom.type)

        if sourceAtom.type == .pattern || targetAtom.type == .pattern {
            return .samePattern
        }

        if isTensionPair(pair) || isTensionPair((pair.1, pair.0)) {
            return .tension
        }

        if isSupportPair(pair) || isSupportPair((pair.1, pair.0)) {
            return .supports
        }

        if isCauseEffectPair(pair) || isCauseEffectPair((pair.1, pair.0)) {
            return .causeEffect
        }

        if isContradictionPair(pair) || isContradictionPair((pair.1, pair.0)) {
            return .contradicts
        }

        return nil
    }

    private func isTensionPair(_ pair: (MemoryAtomType, MemoryAtomType)) -> Bool {
        switch pair {
        case (.boundary, .goal), (.boundary, .plan), (.boundary, .proposal),
             (.constraint, .goal), (.constraint, .plan), (.constraint, .proposal),
             (.rejection, .proposal), (.correction, .belief):
            return true
        default:
            return false
        }
    }

    private func isSupportPair(_ pair: (MemoryAtomType, MemoryAtomType)) -> Bool {
        switch pair {
        case (.reason, .decision), (.reason, .rejection),
             (.insight, .decision), (.belief, .decision),
             (.rule, .decision), (.constraint, .decision):
            return true
        default:
            return false
        }
    }

    private func isCauseEffectPair(_ pair: (MemoryAtomType, MemoryAtomType)) -> Bool {
        switch pair {
        case (.event, .insight), (.event, .decision),
             (.reason, .plan), (.goal, .plan):
            return true
        default:
            return false
        }
    }

    private func isContradictionPair(_ pair: (MemoryAtomType, MemoryAtomType)) -> Bool {
        switch pair {
        case (.rejection, .belief), (.rejection, .goal),
             (.correction, .decision), (.boundary, .decision):
            return true
        default:
            return false
        }
    }

    private func explanation(for relationKind: GalaxyRelationKind) -> String {
        switch relationKind {
        case .samePattern:
            return "These nodes appear to express the same underlying pattern through different surface topics."
        case .tension:
            return "These nodes may pull against each other: one states a boundary or constraint while the other points toward a goal, plan, or proposal."
        case .supports:
            return "One node appears to give a reason, rule, or insight that supports the other."
        case .contradicts:
            return "These nodes may conflict with each other and are worth reviewing together."
        case .causeEffect:
            return "These nodes may describe a cause-and-effect chain."
        case .topicSimilarity:
            return "These nodes are semantically close, but Nous does not yet have stronger evidence for a deeper relationship."
        }
    }

    private func lexicalOverlap(_ lhs: String, _ rhs: String) -> Int {
        let left = Set(significantTerms(lhs))
        let right = Set(significantTerms(rhs))
        return left.intersection(right).count
    }

    private func significantTerms(_ text: String) -> [String] {
        let latinTerms = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }
            .filter { !Self.stopWords.contains($0) }

        return latinTerms + cjkPhraseTerms(from: text)
    }

    private func cjkPhraseTerms(from text: String) -> [String] {
        var terms: [String] = []
        var chunk: [Character] = []

        func flushChunk() {
            guard chunk.count >= 2 else {
                chunk.removeAll()
                return
            }

            for width in 2...min(3, chunk.count) {
                guard chunk.count >= width else { continue }
                for index in 0...(chunk.count - width) {
                    terms.append(String(chunk[index..<(index + width)]))
                }
            }
            chunk.removeAll()
        }

        for character in text {
            if character.unicodeScalars.contains(where: Self.isCJKScalar) {
                chunk.append(character)
            } else {
                flushChunk()
            }
        }
        flushChunk()

        return terms
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private func evidenceExcerpt(from node: NousNode) -> String {
        let content = node.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            return node.title
        }
        return String(content.prefix(220))
    }

    private func llmVerdict(
        llm: any LLMService,
        source: NousNode,
        target: NousNode,
        similarity: Float,
        sourceAtoms: [MemoryAtom],
        targetAtoms: [MemoryAtom]
    ) async throws -> GalaxyRelationVerdict? {
        let prompt = """
        Decide whether these two Nous nodes have a useful knowledge-graph relationship.

        Allowed relation values:
        same_pattern, tension, supports, contradicts, cause_effect, topic_similarity, none

        Bar:
        - same_pattern means different surface topics express the same underlying behavior, constraint, or decision pattern.
        - tension means one node pulls against a boundary, constraint, value, or prior decision in the other.
        - topic_similarity is allowed only when they are merely about the same topic.
        - none means the link would not help Alex think.

        Return strict JSON only:
        {
          "relation": "same_pattern|tension|supports|contradicts|cause_effect|topic_similarity|none",
          "confidence": 0.0,
          "explanation": "one short sentence",
          "source_evidence": "short exact or tight paraphrase from source",
          "target_evidence": "short exact or tight paraphrase from target",
          "source_atom_id": "UUID from SOURCE atoms if one supports this relation, otherwise null",
          "target_atom_id": "UUID from TARGET atoms if one supports this relation, otherwise null"
        }

        Vector similarity: \(String(format: "%.3f", similarity))

        SOURCE
        Title: \(source.title)
        Type: \(source.type.rawValue)
        Atoms:
        \(atomBlock(sourceAtoms))
        Content:
        \(contentExcerpt(from: source))

        TARGET
        Title: \(target.title)
        Type: \(target.type.rawValue)
        Atoms:
        \(atomBlock(targetAtoms))
        Content:
        \(contentExcerpt(from: target))
        """

        let stream = try await llm.generate(
            messages: [LLMMessage(role: "user", content: prompt)],
            system: "You are a strict knowledge-graph relation judge for Nous. Prefer none over weak links. Return JSON only."
        )
        var output = ""
        for try await chunk in stream {
            output += chunk
        }
        return try Self.decodeLLMVerdict(
            output,
            sourceAtomIds: Set(sourceAtoms.map(\.id)),
            targetAtomIds: Set(targetAtoms.map(\.id))
        )
    }

    private func atomBlock(_ atoms: [MemoryAtom]) -> String {
        let activeAtoms = atoms
            .filter { $0.status == .active }
            .prefix(8)
            .map { "- id: \($0.id.uuidString) | type: \($0.type.rawValue) | statement: \($0.statement)" }
            .joined(separator: "\n")
        return activeAtoms.isEmpty ? "none" : activeAtoms
    }

    private func contentExcerpt(from node: NousNode) -> String {
        let content = node.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return node.title }
        return String(content.prefix(1200))
    }

    private static func decodeLLMVerdict(
        _ raw: String,
        sourceAtomIds: Set<UUID>,
        targetAtomIds: Set<UUID>
    ) throws -> GalaxyRelationVerdict? {
        guard
            let jsonText = extractJSONObject(from: raw),
            let data = jsonText.data(using: .utf8),
            let payload = try? JSONDecoder().decode(LLMRelationPayload.self, from: data)
        else {
            throw LLMVerdictError.invalidResponse
        }

        guard payload.confidence >= GalaxyRelationTuning.minimumLLMConfidence else { return nil }
        guard payload.relation != .none else { return nil }

        let explanation = payload.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceEvidence = payload.sourceEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetEvidence = payload.targetEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceAtomId = validAtomId(payload.sourceAtomId, allowedIds: sourceAtomIds)
        let targetAtomId = validAtomId(payload.targetAtomId, allowedIds: targetAtomIds)
        guard !explanation.isEmpty, !sourceEvidence.isEmpty, !targetEvidence.isEmpty else {
            throw LLMVerdictError.invalidResponse
        }

        return GalaxyRelationVerdict(
            relationKind: payload.relation.relationKind,
            confidence: Float(min(max(payload.confidence, 0), 1)),
            explanation: explanation,
            sourceEvidence: sourceEvidence,
            targetEvidence: targetEvidence,
            sourceAtomId: sourceAtomId,
            targetAtomId: targetAtomId
        )
    }

    private static func validAtomId(_ raw: String?, allowedIds: Set<UUID>) -> UUID? {
        guard
            let raw,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let id = UUID(uuidString: raw),
            allowedIds.contains(id)
        else {
            return nil
        }

        return id
    }

    private static func extractJSONObject(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }

        guard
            let start = trimmed.firstIndex(of: "{"),
            let end = trimmed.lastIndex(of: "}"),
            start <= end
        else {
            return nil
        }

        return String(trimmed[start...end])
    }

    private struct LLMRelationPayload: Decodable {
        let relation: LLMRelationKind
        let confidence: Double
        let explanation: String
        let sourceEvidence: String
        let targetEvidence: String
        let sourceAtomId: String?
        let targetAtomId: String?

        enum CodingKeys: String, CodingKey {
            case relation
            case confidence
            case explanation
            case sourceEvidence = "source_evidence"
            case targetEvidence = "target_evidence"
            case sourceAtomId = "source_atom_id"
            case targetAtomId = "target_atom_id"
        }
    }

    private enum LLMRelationKind: String, Decodable {
        case samePattern = "same_pattern"
        case tension
        case supports
        case contradicts
        case causeEffect = "cause_effect"
        case topicSimilarity = "topic_similarity"
        case none

        var relationKind: GalaxyRelationKind {
            switch self {
            case .samePattern:
                return .samePattern
            case .tension:
                return .tension
            case .supports:
                return .supports
            case .contradicts:
                return .contradicts
            case .causeEffect:
                return .causeEffect
            case .topicSimilarity:
                return .topicSimilarity
            case .none:
                return .topicSimilarity
            }
        }
    }

    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "because", "been", "being", "from",
        "have", "into", "more", "need", "only", "over", "same", "should",
        "that", "their", "them", "then", "there", "these", "they", "this",
        "through", "what", "when", "where", "which", "with", "would", "your"
    ]
}
