import Foundation
import Accelerate

struct SearchResult {
    let node: NousNode
    let similarity: Float
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
}
