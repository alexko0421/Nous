import Foundation

/// Derives Constellation values from the reflection layer (ReflectionClaim
/// + ReflectionEvidence) and merges in-memory ephemeral attachments
/// produced by embedding-NN bridging between reflection cycles.
///
/// Owned at app-lifetime scope alongside NodeStore. Ephemeral state is
/// process-local (NSLock-guarded), cleared on app restart and on
/// successful ReflectionRun completion.
final class ConstellationService {
    private let nodeStore: NodeStore
    private let vectorStore: VectorStore

    /// constellationId → set of ephemeral nodeIds attached.
    /// Cleared on reflection completion. Not persisted.
    private var ephemeralByConstellationId: [UUID: Set<UUID>] = [:]
    private let ephemeralLock = NSLock()

    init(nodeStore: NodeStore, vectorStore: VectorStore) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
    }

    /// Builds the active constellation snapshot from current reflection
    /// data merged with in-memory ephemeral attachments. Applies K=2
    /// per-node cap then a second prune for constellations whose
    /// membership dropped below 2.
    ///
    /// Stub implementation in this task; filled in by Task 11.
    func loadActiveConstellations() throws -> [Constellation] {
        return []
    }

    /// Computes cosine similarity of a node's embedding against each
    /// active constellation centroid; records ephemeral attachments
    /// in memory for those above threshold (top-2 by similarity).
    /// Idempotent.
    ///
    /// Stub implementation in this task; filled in by Task 12.
    func considerNodeForEphemeralBridging(_ node: NousNode) throws {
        // Implemented in Task 12
    }

    /// Drops any ephemeral attachments referencing this nodeId.
    /// Called on node deletion.
    func releaseEphemeral(nodeId: UUID) {
        ephemeralLock.lock()
        defer { ephemeralLock.unlock() }
        for key in ephemeralByConstellationId.keys {
            ephemeralByConstellationId[key]?.remove(nodeId)
        }
    }

    /// Wipes all ephemeral attachments. Called after successful
    /// ReflectionRun completion (the derived snapshot now reflects
    /// fresh evidence).
    func clearEphemeral() {
        ephemeralLock.lock()
        defer { ephemeralLock.unlock() }
        ephemeralByConstellationId.removeAll()
    }
}
