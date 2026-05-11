import Foundation

/// Single retrieval entry point that every chat mode (default, Plan, Direction,
/// Brainstorm) will eventually call. Replaces the dual MemoryProjectionService
/// (default chat blob) / MemoryQueryPlanner (quick-action atom) bifurcation.
///
/// Block 2 of the own-corpus path (`~/.claude/plans/atomic-zooming-sphinx.md`).
/// Wiring into `PromptContextAssembler` and `TurnMemoryContextBuilder` is
/// Block 4 — this class is "dark code" until then. The builder runs end-to-end
/// in tests but does NOT influence assembled prompts yet.
///
/// The builder reuses `MemoryQueryPlanner` for atom recall (preserves the
/// validated keyword-intent + vector-fallback + scope-filter logic), then
/// re-fetches the matched atoms by id so the full per-atom metadata
/// (confidence, eventTime, sourceNodeId, atomType) survives the projection
/// into `CitableEntry`. Block 1 added those optional fields; this class is the
/// first writer that populates them from atoms.
final class CitableContextBuilder {
    private let nodeStore: NodeStore
    private let planner: MemoryQueryPlanner
    private let lexicalIndex: LexicalIndex?

    init(nodeStore: NodeStore, lexicalIndex: LexicalIndex? = nil) {
        self.nodeStore = nodeStore
        self.planner = MemoryQueryPlanner(nodeStore: nodeStore)
        self.lexicalIndex = lexicalIndex
    }

    /// Build the citable context for a given turn.
    ///
    /// - Parameters:
    ///   - turnText: The user's current message. Drives intent classification +
    ///     vector fallback (when `queryEmbedding` is supplied).
    ///   - conversationId: Used for scope filtering (conversation-scoped atoms
    ///     attached to other conversations are excluded).
    ///   - projectId: Project scope filter; nil = free-chat.
    ///   - mode: Captured in the manifest for telemetry. Behavior of the
    ///     builder does NOT yet branch on mode — that's a Block 4 concern when
    ///     mode-specific budgets/floors are introduced.
    ///   - queryEmbedding: Optional embedding for vector fallback when keyword
    ///     intent classification fails.
    ///   - confidenceFloor: Atoms/claims below this confidence are dropped
    ///     before ranking. Default 0.6 leaves room for human-graded entries
    ///     (default 0.7 in MemoryAtom.init) while filtering low-confidence
    ///     extraction noise.
    ///   - cardCap: Hard ceiling on admitted entries — the prompt token
    ///     budget enforcer.
    ///   - atomLimit / reflectionLimit: Per-lane caps before global ranking.
    func build(
        turnText: String,
        conversationId: UUID,
        projectId: UUID?,
        mode: ChatMode = .companion,
        queryEmbedding: [Float]? = nil,
        confidenceFloor: Double = 0.6,
        cardCap: Int = 8,
        atomLimit: Int = 6,
        reflectionLimit: Int = 3,
        now: Date = Date()
    ) -> CitableContext {
        let packet = planner.recallPacket(
            currentMessage: turnText,
            projectId: projectId,
            conversationId: conversationId,
            limit: atomLimit,
            queryEmbedding: queryEmbedding,
            now: now
        )

        // Lexical lane (Block 6 — atom hybrid retrieval). Runs FTS5 trigram
        // search over memory_atoms.statement so CJK paraphrases hit atoms
        // the planner's English-only embedding misses, AND so queries with
        // no keyword-intent cue still get an atom recall lane (planner's
        // internal vector fallback is only used when an embedding is
        // supplied; lexical fills the no-embedding-no-intent gap). Hits
        // outside the existing planner result set are merged below.
        let lexicalAtomIds: [UUID] = (try? lexicalIndex?.searchMemoryAtoms(
            query: turnText,
            limit: atomLimit
        ).map(\.rowId)) ?? []
        let plannerIdSet = Set(packet.retrievedAtomIds)
        let lexicalOnlyIds = lexicalAtomIds.filter { !plannerIdSet.contains($0) }
        let mergedAtomIds: [UUID] = packet.retrievedAtomIds + lexicalOnlyIds

        let atomById: [UUID: MemoryAtom] = Self.fetchAtomsById(
            ids: mergedAtomIds,
            nodeStore: nodeStore
        )

        // `currentNodeId: conversationId` filters out per-conversation
        // reflection claims that belong to *other* conversations. Cross-
        // conversation claims (weekly tier, `r.node_id IS NULL`) always
        // come through; conversation-scoped claims surface only when the
        // user is back in the source chat.
        let claims = (try? nodeStore.fetchActiveReflectionClaims(
            projectId: projectId,
            currentNodeId: conversationId
        )) ?? []
        let pickedClaims = Array(claims.prefix(reflectionLimit))

        var totalSeen = 0
        var droppedByFloor = 0
        var ranked: [(entry: CitableEntry, score: Double)] = []

        // Atom lane — iterate planner-then-lexical id order so the keyword/
        // vector path keeps its priority for cases it can already serve, and
        // the lexical-only union extends coverage for paraphrases / CJK
        // queries the planner missed. Final rank is recomputed below for
        // cross-lane fairness so a high-confidence lexical-only hit can
        // still outrank a low-confidence planner hit.
        for id in mergedAtomIds {
            guard let atom = atomById[id] else { continue }
            totalSeen += 1
            if atom.confidence < confidenceFloor {
                droppedByFloor += 1
                continue
            }
            ranked.append((Self.shapeAtom(atom), Self.scoreAtom(atom, now: now)))
        }

        // Reflection lane.
        for claim in pickedClaims {
            totalSeen += 1
            if claim.confidence < confidenceFloor {
                droppedByFloor += 1
                continue
            }
            ranked.append((Self.shapeReflection(claim), Self.scoreReflection(claim, now: now)))
        }

        // Stable sort: score desc, ties broken by recordedAt desc.
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lTime = lhs.entry.recordedAt ?? .distantPast
            let rTime = rhs.entry.recordedAt ?? .distantPast
            return lTime > rTime
        }

        let admitted = Array(ranked.prefix(cardCap))
        let droppedByBudget = max(0, ranked.count - admitted.count)

        let manifest = CitableContextManifest(
            mode: mode,
            intent: packet.intent,
            totalCandidates: totalSeen,
            droppedByConfidenceFloor: droppedByFloor,
            droppedByBudget: droppedByBudget,
            admittedCount: admitted.count,
            timeWindowStart: packet.timeWindowStart,
            timeWindowEnd: packet.timeWindowEnd
        )

        return CitableContext(entries: admitted.map(\.entry), manifest: manifest)
    }

    // MARK: - AttributionShaper

    private static func shapeAtom(_ atom: MemoryAtom) -> CitableEntry {
        CitableEntry(
            id: atom.id.uuidString,
            text: atom.statement,
            scope: atom.scope,
            kind: nil,
            promptAnnotation: "atom-recall",
            confidence: atom.confidence,
            eventTime: atom.eventTime,
            sourceNodeId: atom.sourceNodeId,
            atomType: atom.type,
            recordedAt: atom.updatedAt
        )
    }

    private static func shapeReflection(_ claim: ReflectionClaim) -> CitableEntry {
        CitableEntry(
            id: claim.id.uuidString,
            text: claim.claim,
            scope: .selfReflection,
            kind: nil,
            promptAnnotation: "weekly-reflection",
            confidence: claim.confidence,
            eventTime: nil,
            sourceNodeId: nil,
            atomType: nil,
            recordedAt: claim.createdAt
        )
    }

    // MARK: - CorpusRanker

    /// `confidence × typeWeight × recencyFactor`. 30-day half-life with a 0.5
    /// floor keeps an aged-but-high-confidence atom from being buried under
    /// fresh low-confidence noise.
    private static func scoreAtom(_ atom: MemoryAtom, now: Date) -> Double {
        let referenceTime = atom.eventTime ?? atom.updatedAt
        return atom.confidence
            * atomTypeWeight(atom.type)
            * recencyFactor(referenceTime, now: now)
    }

    /// Reflections carry a structural baseline boost — they're already
    /// non-obvious by the WeeklyReflectionService prompt's design, which is
    /// exactly the texture the own-corpus path wants to surface.
    private static func scoreReflection(_ claim: ReflectionClaim, now: Date) -> Double {
        let reflectionTypeWeight: Double = 1.3
        return claim.confidence
            * reflectionTypeWeight
            * recencyFactor(claim.createdAt, now: now)
    }

    private static func atomTypeWeight(_ type: MemoryAtomType) -> Double {
        switch type {
        case .decision: return 1.2
        case .insight: return 1.15
        case .preference, .rule, .boundary, .goal, .constraint: return 1.0
        case .pattern, .belief, .correction: return 0.95
        case .plan, .proposal: return 0.9
        case .event, .task: return 0.85
        case .currentPosition: return 0.8
        case .reason, .rejection: return 0.75
        case .identity, .entity: return 0.7
        }
    }

    private static func recencyFactor(_ referenceTime: Date, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(referenceTime) / 86400.0)
        let halfLife = 30.0
        let decay = pow(0.5, ageDays / halfLife)
        return 0.5 + 0.5 * decay
    }

    // MARK: - Helpers

    private static func fetchAtomsById(
        ids: [UUID],
        nodeStore: NodeStore
    ) -> [UUID: MemoryAtom] {
        guard !ids.isEmpty else { return [:] }
        let allActive = (try? nodeStore.fetchMemoryAtoms(
            types: [],
            statuses: [.active],
            scope: nil,
            scopeRefId: nil,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: nil
        )) ?? []
        let idSet = Set(ids)
        let matched = allActive.filter { idSet.contains($0.id) }
        return Dictionary(uniqueKeysWithValues: matched.map { ($0.id, $0) })
    }
}
