import Foundation
import Accelerate

enum RetrievalLane: Equatable {
    case semantic
    case longGap
}

struct SearchResult {
    let node: NousNode
    let similarity: Float
    let lane: RetrievalLane
    let previewSnippet: String?

    init(
        node: NousNode,
        similarity: Float,
        lane: RetrievalLane = .semantic,
        previewSnippet: String? = nil
    ) {
        self.node = node
        self.similarity = similarity
        self.lane = lane
        self.previewSnippet = previewSnippet
    }

    var surfacedSnippet: String {
        if let previewSnippet {
            let trimmed = previewSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let trimmedContent = node.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            return node.type == .conversation
                ? "This chat does not have a usable preview yet."
                : "This note does not have a usable preview yet."
        }

        if node.type == .conversation {
            let turns = trimmedContent
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !turns.isEmpty {
                return String(turns.suffix(2).joined(separator: "\n\n").prefix(320))
            }
        }

        return String(trimmedContent.prefix(320))
    }
}

final class VectorStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    /// Cosine similarity between two vectors using Accelerate vDSP.
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Brute-force top-K search over all embedded nodes.
    func search(query: [Float], topK: Int = 5, excludeIds: Set<UUID> = []) throws -> [SearchResult] {
        let allNodes = try nodeStore.fetchNodesWithEmbeddings()
        var results: [SearchResult] = []
        for (node, embedding) in allNodes {
            guard !excludeIds.contains(node.id) else { continue }
            let sim = cosineSimilarity(query, embedding)
            results.append(SearchResult(node: node, similarity: sim))
        }
        results.sort { $0.similarity > $1.similarity }
        return Array(results.prefix(topK))
    }

    func searchSourceChunks(
        query: [Float],
        topK: Int = 5,
        excludeSourceNodeIds: Set<UUID> = []
    ) throws -> [SourceChunkSearchResult] {
        try searchSourceChunks(
            query: query,
            topK: topK,
            sourceNodeIds: nil,
            excludeSourceNodeIds: excludeSourceNodeIds
        )
    }

    func searchSourceChunks(
        query: [Float],
        topK: Int = 5,
        sourceNodeIds: Set<UUID>,
        excludeSourceNodeIds: Set<UUID> = []
    ) throws -> [SourceChunkSearchResult] {
        try searchSourceChunks(
            query: query,
            topK: topK,
            sourceNodeIds: Optional(sourceNodeIds),
            excludeSourceNodeIds: excludeSourceNodeIds
        )
    }

    private func searchSourceChunks(
        query: [Float],
        topK: Int,
        sourceNodeIds: Set<UUID>?,
        excludeSourceNodeIds: Set<UUID>
    ) throws -> [SourceChunkSearchResult] {
        let chunks = try nodeStore.fetchSourceChunksWithEmbeddings()
        var results: [SourceChunkSearchResult] = []
        for (chunk, sourceNode, embedding) in chunks {
            if let sourceNodeIds, !sourceNodeIds.contains(sourceNode.id) { continue }
            guard !excludeSourceNodeIds.contains(sourceNode.id) else { continue }
            results.append(
                SourceChunkSearchResult(
                    sourceNode: sourceNode,
                    chunk: chunk,
                    similarity: cosineSimilarity(query, embedding)
                )
            )
        }
        results.sort { $0.similarity > $1.similarity }
        return Array(results.prefix(topK))
    }

    /// Chat-only retrieval keeps semantic matches dominant while reserving one
    /// slot for an older-but-still-relevant spark.
    func searchForChatCitations(
        query: [Float],
        queryText: String = "",
        topK: Int = 5,
        excludeIds: Set<UUID> = [],
        now: Date = Date(),
        candidatePoolSize: Int = 40,
        semanticSlots: Int = 3,
        minSimilarityForLongGap: Float = 0.55,
        minAgeDaysForLongGap: Int = 30,
        ageBoostAlpha: Float = 0.15
    ) throws -> [SearchResult] {
        guard topK > 0 else { return [] }

        let semanticQuota = min(semanticSlots, topK)
        let nodeCandidates = try search(
            query: query,
            topK: max(candidatePoolSize, topK, semanticQuota + 1),
            excludeIds: excludeIds
        )
        let chunkCandidates = try sourceChunkCitationCandidates(
            query: query,
            topK: max(candidatePoolSize, topK, semanticQuota + 1),
            excludeIds: excludeIds
        )
        let candidates = mergedChatCitationCandidates(nodeCandidates + chunkCandidates)

        var selected: [SearchResult] = []
        var seen = Set<UUID>()

        func admit(_ result: SearchResult) {
            guard selected.count < topK else { return }
            guard seen.insert(result.node.id).inserted else { return }
            selected.append(result)
        }

        if candidates.count <= semanticQuota {
            candidates.forEach(admit)
        } else {
            candidates.prefix(semanticQuota).forEach(admit)
        }

        if candidates.count > semanticQuota {
            let longGapCandidate = candidates
                .dropFirst(semanticQuota)
                .filter {
                    $0.similarity >= minSimilarityForLongGap &&
                    ageDays(since: $0.node.createdAt, now: now) >= minAgeDaysForLongGap
                }
                .max {
                    longGapInsightScore(for: $0, now: now, alpha: ageBoostAlpha) <
                    longGapInsightScore(for: $1, now: now, alpha: ageBoostAlpha)
                }

            if let longGapCandidate {
                admit(SearchResult(
                    node: longGapCandidate.node,
                    similarity: longGapCandidate.similarity,
                    lane: .longGap,
                    previewSnippet: longGapCandidate.previewSnippet
                ))
            }
        }

        for result in candidates where selected.count < topK {
            admit(result)
        }

        let surfaced = surfacedChatCitations(from: selected, topK: topK, now: now)
        return surfaced.map { result in
            SearchResult(
                node: result.node,
                similarity: result.similarity,
                lane: result.lane,
                previewSnippet: result.previewSnippet ?? anchoredPreviewSnippet(for: result.node, queryText: queryText)
            )
        }
    }

    private func sourceChunkCitationCandidates(
        query: [Float],
        topK: Int,
        excludeIds: Set<UUID>
    ) throws -> [SearchResult] {
        try searchSourceChunks(
            query: query,
            topK: topK,
            excludeSourceNodeIds: excludeIds
        ).map { result in
            SearchResult(
                node: result.sourceNode,
                similarity: result.similarity,
                previewSnippet: String(
                    result.chunk.text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .prefix(320)
                )
            )
        }
    }

    private func mergedChatCitationCandidates(_ candidates: [SearchResult]) -> [SearchResult] {
        var bestByNodeId: [UUID: SearchResult] = [:]

        for candidate in candidates {
            guard let current = bestByNodeId[candidate.node.id] else {
                bestByNodeId[candidate.node.id] = candidate
                continue
            }
            if shouldReplaceCitationCandidate(candidate, replacing: current) {
                bestByNodeId[candidate.node.id] = candidate
            }
        }

        return bestByNodeId.values.sorted {
            if $0.similarity == $1.similarity {
                return $0.node.updatedAt > $1.node.updatedAt
            }
            return $0.similarity > $1.similarity
        }
    }

    private func shouldReplaceCitationCandidate(
        _ candidate: SearchResult,
        replacing current: SearchResult
    ) -> Bool {
        if candidate.similarity != current.similarity {
            return candidate.similarity > current.similarity
        }
        if current.previewSnippet == nil, candidate.previewSnippet != nil {
            return true
        }
        return false
    }

    /// Find all nodes semantically similar to a given node above a threshold.
    func findSemanticNeighbors(for node: NousNode, threshold: Float = 0.75) throws -> [SearchResult] {
        guard let embedding = node.embedding else { return [] }
        let results = try search(query: embedding, topK: 50, excludeIds: [node.id])
        return results.filter { $0.similarity >= threshold }
    }

    /// Store embedding for a node.
    func storeEmbedding(_ embedding: [Float], for nodeId: UUID) throws {
        guard var node = try nodeStore.fetchNode(id: nodeId) else { return }
        node.embedding = embedding
        try nodeStore.updateNode(node)
    }

    private func ageDays(since createdAt: Date, now: Date) -> Int {
        let elapsed = max(0, now.timeIntervalSince(createdAt))
        return Int(elapsed / 86_400)
    }

    private func longGapInsightScore(for result: SearchResult, now: Date, alpha: Float) -> Float {
        let age = Float(ageDays(since: result.node.createdAt, now: now))
        return result.similarity * (1 + alpha * Float(log1p(Double(age))))
    }

    private func surfacedChatCitations(
        from results: [SearchResult],
        topK: Int,
        now: Date
    ) -> [SearchResult] {
        guard let strongest = results.first else { return [] }

        let semanticFloor = max(0.42, strongest.similarity - 0.28)
        let longGapFloor = max(0.60, strongest.similarity - 0.40)

        let filtered = results.filter { result in
            switch result.lane {
            case .semantic:
                return result.similarity >= semanticFloor
            case .longGap:
                return result.similarity >= longGapFloor &&
                    ageDays(since: result.node.createdAt, now: now) >= 45
            }
        }

        let hasStrongTopHit = strongest.similarity >= 0.58
        let solidMatchCount = filtered.filter { $0.similarity >= 0.50 }.count
        let hasStrongLongGap = filtered.contains {
            $0.lane == .longGap &&
            $0.similarity >= 0.64 &&
            ageDays(since: $0.node.createdAt, now: now) >= 45
        }

        guard hasStrongTopHit || solidMatchCount >= 2 || hasStrongLongGap else {
            return []
        }

        return Array(filtered.prefix(topK))
    }

    private func anchoredPreviewSnippet(for node: NousNode, queryText: String) -> String? {
        let trimmedContent = node.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return nil }

        let rawQuery = normalizedSearchText(queryText)
        let terms = significantQueryTerms(from: queryText)
        let chunks = previewChunks(for: node, content: trimmedContent)

        var bestChunk: String?
        var bestScore = 0

        for chunk in chunks {
            let score = previewScore(for: chunk, rawQuery: rawQuery, terms: terms)
            if score > bestScore {
                bestScore = score
                bestChunk = chunk
            }
        }

        guard bestScore > 0, let bestChunk else { return nil }
        return String(bestChunk.trimmingCharacters(in: .whitespacesAndNewlines).prefix(320))
    }

    private func previewChunks(for node: NousNode, content: String) -> [String] {
        switch node.type {
        case .conversation:
            let turns = content
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !turns.isEmpty else { return [content] }

            var chunks: [String] = []
            for index in turns.indices {
                let turn = turns[index]
                let chunk: String
                if turn.hasPrefix("Alex:"), index + 1 < turns.count {
                    chunk = [turn, turns[index + 1]].joined(separator: "\n\n")
                } else if turn.hasPrefix("Nous:"), index > 0 {
                    chunk = [turns[index - 1], turn].joined(separator: "\n\n")
                } else {
                    chunk = turn
                }

                if chunks.last != chunk {
                    chunks.append(chunk)
                }
            }
            return chunks
        case .note, .source:
            let paragraphs = content
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if paragraphs.count > 1 {
                return paragraphs
            }

            let sentences = content
                .split(whereSeparator: { ".!?\n".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !sentences.isEmpty else { return [content] }

            if sentences.count == 1 {
                return sentences
            }

            return sentences.indices.map { index in
                let end = min(index + 2, sentences.count)
                return sentences[index..<end].joined(separator: ". ")
            }
        }
    }

    private func previewScore(for chunk: String, rawQuery: String, terms: [String]) -> Int {
        let normalizedChunk = normalizedSearchText(chunk)
        guard !normalizedChunk.isEmpty else { return 0 }

        var score = 0
        if rawQuery.count >= 6 && normalizedChunk.contains(rawQuery) {
            score += 12
        }

        for term in terms where normalizedChunk.contains(term) {
            score += 3
        }

        return score
    }

    private func normalizedSearchText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func significantQueryTerms(from queryText: String) -> [String] {
        let stopwords: Set<String> = [
            "about", "again", "also", "and", "are", "but", "can", "could",
            "for", "from", "have", "into", "just", "like", "maybe", "more",
            "need", "really", "should", "that", "the", "them", "then", "this",
            "thing", "think", "what", "when", "with", "would", "your"
        ]

        var seen = Set<String>()
        let tokens = queryText
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter {
                !$0.isEmpty &&
                ($0.count >= 3 || $0.unicodeScalars.contains { $0.value > 127 }) &&
                !stopwords.contains($0)
            }

        return tokens.filter { seen.insert($0).inserted }
    }
}
