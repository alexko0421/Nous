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

    init(node: NousNode, similarity: Float, lane: RetrievalLane = .semantic) {
        self.node = node
        self.similarity = similarity
        self.lane = lane
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

    /// Chat-only retrieval keeps semantic matches dominant while reserving one
    /// slot for an older-but-still-relevant spark.
    func searchForChatCitations(
        query: [Float],
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
        let candidates = try search(
            query: query,
            topK: max(candidatePoolSize, topK, semanticQuota + 1),
            excludeIds: excludeIds
        )

        guard candidates.count > semanticQuota else {
            return Array(candidates.prefix(topK))
        }

        var selected: [SearchResult] = []
        var seen = Set<UUID>()

        func admit(_ result: SearchResult) {
            guard selected.count < topK else { return }
            guard seen.insert(result.node.id).inserted else { return }
            selected.append(result)
        }

        candidates.prefix(semanticQuota).forEach(admit)

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
                lane: .longGap
            ))
        }

        for result in candidates where selected.count < topK {
            admit(result)
        }

        return selected
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
}
