import Foundation

final class MemoryCuratorReviewService {
    private let nodeStore: NodeStore
    private let planner: MemoryCuratorReviewPlanner

    init(
        nodeStore: NodeStore,
        planner: MemoryCuratorReviewPlanner = MemoryCuratorReviewPlanner()
    ) {
        self.nodeStore = nodeStore
        self.planner = planner
    }

    func makePlan() throws -> MemoryCuratorReviewPlan {
        let entries = try nodeStore.fetchMemoryEntries()
        return planner.plan(entries: entries) { [nodeStore] entry in
            Self.hasInspectableSourceEvidence(for: entry, nodeStore: nodeStore)
        }
    }

    private static func hasInspectableSourceEvidence(
        for entry: MemoryEntry,
        nodeStore: NodeStore
    ) -> Bool {
        for sourceNodeId in dedupe(entry.sourceNodeIds) {
            guard let node = try? nodeStore.fetchNode(id: sourceNodeId) else { continue }
            if hasInspectableContent(for: node, nodeStore: nodeStore) {
                return true
            }
        }
        return false
    }

    private static func hasInspectableContent(
        for node: NousNode,
        nodeStore: NodeStore
    ) -> Bool {
        if !node.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        if node.type == .conversation,
           let messages = try? nodeStore.fetchMessages(nodeId: node.id),
           messages.contains(where: { message in
               message.role == .user &&
                   !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           }) {
            return true
        }

        if node.type == .source,
           let chunks = try? nodeStore.fetchSourceChunks(nodeId: node.id),
           chunks.contains(where: { chunk in
               !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           }) {
            return true
        }

        return false
    }

    private static func dedupe(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
