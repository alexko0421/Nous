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
    /// See spec §3.3, §4.1, §4.2. The 9-step pipeline is preserved in
    /// numbered comments below — keep them in order on edits.
    func loadActiveConstellations() throws -> [Constellation] {
        // 1. Pull active claims (across all projectIds — Galaxy is scope-agnostic).
        let claims = try nodeStore.fetchActiveReflectionClaims()
        guard !claims.isEmpty else { return [] }

        // 2. Bulk fetch evidence rows + bulk resolve messageId → conversation
        // nodeId. Both round-trips chunked at ≤900 ids inside NodeStore.
        let evidence = try nodeStore.fetchEvidence(forClaimIds: claims.map { $0.id })
        let evidenceByClaim: [UUID: [ReflectionEvidence]] =
            Dictionary(grouping: evidence, by: { $0.reflectionId })
        let messageToNode = try nodeStore.conversationNodeIds(
            forMessageIds: evidence.map { $0.messageId }
        )

        // 3. Build per-claim distinct nodeId sets. Drop claims whose evidence
        // collapses below 2 distinct nodeIds (no visualization value — surfaces
        // a single bubble, not a constellation). Pre-validator-change residue
        // can leave such claims behind.
        struct PreCap {
            let claim: ReflectionClaim
            var members: [UUID]
        }
        var preCap: [PreCap] = []
        for claim in claims {
            let claimEv = evidenceByClaim[claim.id] ?? []
            let nodeIds = claimEv.compactMap { messageToNode[$0.messageId] }
            let distinct = Array(Set(nodeIds))
            if distinct.count >= 2 {
                preCap.append(PreCap(claim: claim, members: distinct))
            }
        }
        guard !preCap.isEmpty else { return [] }

        // 4. K=2 per-node cap. Sort claims by confidence desc; for each member,
        // track membership count. Members already at K=2 are excluded from
        // the current claim's set.
        let sortedDescByConfidence = preCap.sorted {
            $0.claim.confidence > $1.claim.confidence
        }
        var perNodeCount: [UUID: Int] = [:]
        var afterCap: [PreCap] = []
        for var c in sortedDescByConfidence {
            c.members = c.members.filter { perNodeCount[$0, default: 0] < 2 }
            for m in c.members { perNodeCount[m, default: 0] += 1 }
            afterCap.append(c)
        }

        // 5. Second prune: drop constellations whose post-cap membership <2.
        // The cap can shrink a set below 2 (e.g., its lowest-confidence members
        // got capped out elsewhere). One pass suffices — pruning never grows
        // another set (cap removes from, never adds to, membership).
        let pruned = afterCap.filter { $0.members.count >= 2 }
        guard !pruned.isEmpty else { return [] }

        // 6. Centroid embedding (best-effort; nil if any member is missing
        // an embedding or member dimensions disagree).
        func centroid(for nodeIds: [UUID]) throws -> [Float]? {
            guard !nodeIds.isEmpty else { return nil }
            var sum: [Float]? = nil
            for nid in nodeIds {
                guard let emb = try fetchEmbedding(forNodeId: nid) else {
                    return nil
                }
                if sum == nil {
                    sum = emb
                } else {
                    guard sum!.count == emb.count else { return nil }
                    for i in 0..<sum!.count { sum![i] += emb[i] }
                }
            }
            guard var s = sum else { return nil }
            let n = Float(nodeIds.count)
            for i in 0..<s.count { s[i] /= n }
            return s
        }

        // 7. Dominant selection: latest run + highest-confidence + 14-day
        // freshness guard. An old "dominant" lingering for weeks misrepresents
        // current emotional weather — better silence than stale signal.
        let latestRun = try nodeStore.fetchLatestReflectionRun()
        let fourteenDays: TimeInterval = 86_400 * 14
        var dominantId: UUID? = nil
        if let lr = latestRun, Date().timeIntervalSince(lr.ranAt) < fourteenDays {
            let candidates = pruned.filter { $0.claim.runId == lr.id }
            dominantId = candidates
                .max(by: { $0.claim.confidence < $1.claim.confidence })?
                .claim.id
        }

        // 8. Snapshot ephemeral attachments under the lock. We re-check the
        // K=2 cap globally before merging so a node already at 2 evidence-side
        // memberships isn't pushed past the cap by ephemeral bridging.
        ephemeralLock.lock()
        let ephemeralCopy = ephemeralByConstellationId
        ephemeralLock.unlock()

        // 9. Build final Constellation values.
        var result: [Constellation] = []
        for p in pruned {
            var members = p.members
            if let extra = ephemeralCopy[p.claim.id] {
                for nid in extra {
                    if !members.contains(nid),
                       perNodeCount[nid, default: 0] < 2 {
                        members.append(nid)
                        perNodeCount[nid, default: 0] += 1
                    }
                }
            }
            let cent = try centroid(for: members)
            result.append(Constellation(
                id: p.claim.id,
                claimId: p.claim.id,
                label: p.claim.claim,
                derivedShortLabel: Constellation.derivedShortLabel(from: p.claim.claim),
                confidence: p.claim.confidence,
                memberNodeIds: members,
                centroidEmbedding: cent,
                isDominant: (p.claim.id == dominantId)
            ))
        }
        return result
    }

    /// Fetches a node's embedding via NodeStore (the canonical source —
    /// `nodes.embedding` blob is the single owner of node-level embeddings).
    /// Returns nil if the node is missing or has no embedding yet.
    private func fetchEmbedding(forNodeId nodeId: UUID) throws -> [Float]? {
        return try nodeStore.fetchNode(id: nodeId)?.embedding
    }

    /// Considers a node for ephemeral attachment to active constellations
    /// based on cosine similarity of the node's embedding against each
    /// constellation's centroid. Records ephemeral attachments to the
    /// top-2 constellations above the 0.7 threshold.
    ///
    /// In-memory only; cleared by clearEphemeral() on reflection completion
    /// and on app restart (since this is process-local state).
    func considerNodeForEphemeralBridging(_ node: NousNode) throws {
        guard let nodeEmb = node.embedding else { return }

        let snapshot = try loadActiveConstellations()
        guard !snapshot.isEmpty else { return }

        struct Score {
            let constellationId: UUID
            let similarity: Float
        }
        var scores: [Score] = []
        for c in snapshot {
            guard let cent = c.centroidEmbedding else { continue }
            // Skip constellations the node is already an evidence-side member of.
            if c.memberNodeIds.contains(node.id) { continue }
            let sim = Self.cosineSimilarity(nodeEmb, cent)
            if sim >= 0.7 {
                scores.append(Score(constellationId: c.id, similarity: sim))
            }
        }
        let topTwo = scores.sorted { $0.similarity > $1.similarity }.prefix(2)
        guard !topTwo.isEmpty else { return }

        ephemeralLock.lock()
        defer { ephemeralLock.unlock() }
        for s in topTwo {
            var current = ephemeralByConstellationId[s.constellationId] ?? Set<UUID>()
            current.insert(node.id)
            ephemeralByConstellationId[s.constellationId] = current
        }
    }

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        guard denom > 0 else { return 0 }
        return dot / denom
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
