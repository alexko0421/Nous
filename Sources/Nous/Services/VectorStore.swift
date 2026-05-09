import Foundation
import Accelerate

enum RetrievalLane: Equatable {
    case semantic
    case longGap
}

/// Tuning knobs for `VectorStore.searchHybrid` — how chat-typed and
/// source-typed results compete in the citation pool. Per the
/// 2026-05-08 multilingual retrieval plan, Move 3.
///
/// Defaults follow the plan's locked baseline (3 chat slots, 2 source
/// slots, 0.05 displacement margin). Future per-mode overrides plug in
/// via `QuickActionMemoryPolicy.citationPolicy` (Move 3 wiring lives
/// in TurnPlanner).
struct HybridRetrievalPolicy: Equatable {
    /// Max number of chat-typed (`.conversation` / `.note`) results
    /// admitted to the final citation pool.
    var chatQuota: Int
    /// Max number of source-typed (`.source`) results admitted to the
    /// final citation pool.
    var sourceQuota: Int
    /// A source must have a positive lexical signal (title or chunk
    /// match) AND its fused score must exceed the lowest admitted
    /// chat's fused score by this margin to enter the chat bucket.
    /// Without this, sources that align with CJK noise would crowd out
    /// real chat memory.
    var sourceDisplacementMargin: Double
    /// Reciprocal Rank Fusion constant. Industry default 60.
    var rrfK: Double
    /// Vector-lane minimum cosine for a result to count as "in lane".
    /// Below this it's noise.
    var vectorLaneFloor: Float
    /// Whether to run hybrid (vector + lexical) at all. Set false to
    /// fall through to vector-only retrieval (legacy callers).
    var useHybridRetrieval: Bool

    static let balanced = HybridRetrievalPolicy(
        chatQuota: 3,
        sourceQuota: 2,
        sourceDisplacementMargin: 0.05,
        rrfK: 60,
        vectorLaneFloor: 0.40,
        useHybridRetrieval: true
    )

    static let vectorOnly = HybridRetrievalPolicy(
        chatQuota: 5,
        sourceQuota: 0,
        sourceDisplacementMargin: 0.0,
        rrfK: 60,
        vectorLaneFloor: 0.40,
        useHybridRetrieval: false
    )
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
    ///
    /// Per the 2026-05-08 multilingual retrieval plan, when `queryText` is
    /// non-empty AND `policy.useHybridRetrieval` is true (the default), this
    /// runs both vector + lexical lanes and fuses via RRF with type-aware
    /// quotas. When `queryText` is empty, behavior falls through to
    /// vector-only retrieval (preserves existing call sites that pass only
    /// embeddings).
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
        ageBoostAlpha: Float = 0.15,
        hybridPolicy: HybridRetrievalPolicy = .balanced
    ) throws -> [SearchResult] {
        guard topK > 0 else { return [] }

        let semanticQuota = min(semanticSlots, topK)

        // When we have query text AND hybrid retrieval is enabled, prefer
        // hybrid path (vector + lexical fusion with type-aware quotas).
        // Otherwise fall through to vector-only (legacy callers, empty
        // query text).
        let candidates: [SearchResult]
        if hybridPolicy.useHybridRetrieval, !QueryNormalizer.normalize(queryText).isEmpty {
            candidates = try searchHybrid(
                queryText: queryText,
                queryEmbedding: query,
                topK: max(candidatePoolSize, topK, semanticQuota + 1),
                excludeIds: excludeIds,
                policy: hybridPolicy
            )
        } else {
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
            candidates = mergedChatCitationCandidates(nodeCandidates + chunkCandidates)
        }

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

    /// Vector + lexical fused retrieval. Two lanes run independently,
    /// gates are applied per-lane, then results merged via RRF with
    /// type-aware quotas (chat-typed vs source-typed).
    ///
    /// Plan reference:
    /// `docs/superpowers/plans/2026-05-08-memory-retrieval-multilingual-architecture.md`
    /// Move 1 + Move 3.
    func searchHybrid(
        queryText: String,
        queryEmbedding: [Float],
        topK: Int,
        excludeIds: Set<UUID> = [],
        policy: HybridRetrievalPolicy = .balanced
    ) throws -> [SearchResult] {
        guard topK > 0 else { return [] }
        let normalizedText = QueryNormalizer.normalize(queryText)

        // Vector lane — same surface as before but expressed via search()
        // and sourceChunkCitationCandidates(). Both already exclude IDs.
        let vectorChatResults = try search(
            query: queryEmbedding,
            topK: max(topK * 4, 20),
            excludeIds: excludeIds
        ).filter { $0.similarity >= policy.vectorLaneFloor }
        let vectorChunkResults = try sourceChunkCitationCandidates(
            query: queryEmbedding,
            topK: max(topK * 4, 20),
            excludeIds: excludeIds
        ).filter { $0.similarity >= policy.vectorLaneFloor }
        let vectorResults = mergedChatCitationCandidates(vectorChatResults + vectorChunkResults)

        // Lexical lane — three sub-lanes (titles / messages / source chunks).
        // Each returns at most poolSize hits; we reduce-by-nodeId taking
        // the best per node (titles win ties because BM25 on shorter docs
        // tends to score higher anyway).
        let poolSize = max(topK * 4, 20)
        var lexicalByNodeId: [UUID: LexicalIndex.LexicalHit] = [:]
        if !normalizedText.isEmpty {
            for hit in try nodeStore.lexicalIndex.searchTitles(
                query: queryText, limit: poolSize, excludeNodeIds: excludeIds
            ) {
                merge(hit: hit, into: &lexicalByNodeId)
            }
            for hit in try nodeStore.lexicalIndex.searchMessages(
                query: queryText, limit: poolSize, excludeNodeIds: excludeIds
            ) {
                merge(hit: hit, into: &lexicalByNodeId)
            }
            for hit in try nodeStore.lexicalIndex.searchSourceChunks(
                query: queryText, limit: poolSize, excludeSourceNodeIds: excludeIds
            ) {
                merge(hit: hit, into: &lexicalByNodeId)
            }
        }

        // Build rank maps (nodeId → rank, 0-indexed) for each lane.
        // Vector lane is already sorted descending by similarity.
        let vectorRanks: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: vectorResults.enumerated().map { ($1.node.id, $0) }
        )
        let lexicalRanks: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: lexicalByNodeId
                .sorted { $0.value.score > $1.value.score }
                .enumerated()
                .map { ($1.value.nodeId, $0) }
        )

        // RRF fusion. Score = 1/(k + rank_v) + 1/(k + rank_l), zero if
        // not in that lane.
        let allNodeIds = Set(vectorRanks.keys).union(lexicalRanks.keys)
        var fused: [(node: NousNode, similarity: Float, rrfScore: Double, hasLexical: Bool, previewSnippet: String?)] = []
        fused.reserveCapacity(allNodeIds.count)

        let vectorByNodeId = Dictionary(uniqueKeysWithValues: vectorResults.map { ($0.node.id, $0) })

        for nodeId in allNodeIds {
            // Need a NousNode to attach to result. Source it from
            // vector lane if present (already loaded), otherwise fetch
            // via NodeStore.
            let resolvedNode: NousNode?
            let resolvedSimilarity: Float
            let resolvedSnippet: String?
            if let vectorResult = vectorByNodeId[nodeId] {
                resolvedNode = vectorResult.node
                resolvedSimilarity = vectorResult.similarity
                resolvedSnippet = vectorResult.previewSnippet
            } else {
                resolvedNode = try? nodeStore.fetchNode(id: nodeId)
                resolvedSimilarity = 0.0
                resolvedSnippet = nil
            }
            guard let node = resolvedNode else { continue }

            let vScore = vectorRanks[nodeId].map { 1.0 / (policy.rrfK + Double($0)) } ?? 0.0
            let lScore = lexicalRanks[nodeId].map { 1.0 / (policy.rrfK + Double($0)) } ?? 0.0
            let rrf = vScore + lScore
            guard rrf > 0 else { continue }
            fused.append((
                node: node,
                similarity: resolvedSimilarity,
                rrfScore: rrf,
                hasLexical: lexicalRanks[nodeId] != nil,
                previewSnippet: resolvedSnippet
            ))
        }

        fused.sort { $0.rrfScore > $1.rrfScore }

        // Type-aware quotas + lexical-required for sources.
        // Sources without lexical signal get filtered out entirely
        // (vector-only similarity on CJK noise zone is exactly the
        // false-positive class we are eliminating).
        let chatBucket = fused
            .filter { $0.node.type != .source }
            .prefix(policy.chatQuota)
        let sourceBucket = fused
            .filter { $0.node.type == .source && $0.hasLexical }
            .prefix(policy.sourceQuota)

        // Apply displacement margin: sources only enter chat slots if
        // their fused score clears the lowest chat by margin AND the
        // chat bucket is at quota. For Move 1 we keep buckets parallel
        // and merge by RRF score; future tuning can fold in margin if
        // empirical data shows source crowding.
        let combined = (Array(chatBucket) + Array(sourceBucket))
            .sorted { $0.rrfScore > $1.rrfScore }
            .prefix(topK)

        return combined.map { entry in
            SearchResult(
                node: entry.node,
                similarity: entry.similarity,
                lane: .semantic,
                previewSnippet: entry.previewSnippet
            )
        }
    }

    private func merge(
        hit: LexicalIndex.LexicalHit,
        into dict: inout [UUID: LexicalIndex.LexicalHit]
    ) {
        if let existing = dict[hit.nodeId] {
            if hit.score > existing.score {
                dict[hit.nodeId] = hit
            }
        } else {
            dict[hit.nodeId] = hit
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
