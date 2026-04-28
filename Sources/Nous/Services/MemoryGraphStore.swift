import Foundation

struct MemoryDecisionChain: Equatable {
    let rejection: MemoryAtom
    let rejectedProposal: MemoryAtom?
    let reasons: [MemoryAtom]
    let replacement: MemoryAtom?
}

final class MemoryGraphStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func insertAtom(_ atom: MemoryAtom) throws {
        try nodeStore.insertMemoryAtom(atom)
    }

    func updateAtom(_ atom: MemoryAtom) throws {
        try nodeStore.updateMemoryAtom(atom)
    }

    func atom(id: UUID) throws -> MemoryAtom? {
        try nodeStore.fetchMemoryAtom(id: id)
    }

    func atoms(
        types: Set<MemoryAtomType> = [],
        statuses: Set<MemoryStatus> = [],
        scope: MemoryScope? = nil,
        scopeRefId: UUID? = nil,
        eventTimeStart: Date? = nil,
        eventTimeEnd: Date? = nil,
        limit: Int? = nil
    ) throws -> [MemoryAtom] {
        try nodeStore.fetchMemoryAtoms(
            types: types,
            statuses: statuses,
            scope: scope,
            scopeRefId: scopeRefId,
            eventTimeStart: eventTimeStart,
            eventTimeEnd: eventTimeEnd,
            limit: limit
        )
    }

    func deleteAtom(id: UUID) throws {
        try nodeStore.deleteMemoryAtom(id: id)
    }

    func insertEdge(_ edge: MemoryEdge) throws {
        try nodeStore.insertMemoryEdge(edge)
    }

    func edges(from atomId: UUID) throws -> [MemoryEdge] {
        try nodeStore.fetchMemoryEdges(fromAtomId: atomId)
    }

    func edges(to atomId: UUID) throws -> [MemoryEdge] {
        try nodeStore.fetchMemoryEdges(toAtomId: atomId)
    }

    func decisionChain(for rejectionId: UUID) throws -> MemoryDecisionChain? {
        guard let rejection = try nodeStore.fetchMemoryAtom(id: rejectionId) else {
            return nil
        }

        let outgoing = try nodeStore.fetchMemoryEdges(fromAtomId: rejectionId)
        let proposal = try firstTarget(for: outgoing, type: .rejected)
        let reasons = try targets(for: outgoing, type: .because)

        let directReplacement = try firstTarget(for: outgoing, type: .replacedBy)
        let proposalReplacement: MemoryAtom?
        if let proposal {
            proposalReplacement = try firstTarget(
                for: nodeStore.fetchMemoryEdges(fromAtomId: proposal.id),
                type: .replacedBy
            )
        } else {
            proposalReplacement = nil
        }

        return MemoryDecisionChain(
            rejection: rejection,
            rejectedProposal: proposal,
            reasons: reasons,
            replacement: directReplacement ?? proposalReplacement
        )
    }

    func insertObservation(_ observation: MemoryObservation) throws {
        try nodeStore.insertMemoryObservation(observation)
    }

    func observations() throws -> [MemoryObservation] {
        try nodeStore.fetchMemoryObservations()
    }

    func appendRecallEvent(_ event: MemoryRecallEvent) throws {
        try nodeStore.appendMemoryRecallEvent(event)
    }

    func recallEvents(limit: Int = 20) throws -> [MemoryRecallEvent] {
        try nodeStore.fetchMemoryRecallEvents(limit: limit)
    }

    private func firstTarget(for edges: [MemoryEdge], type: MemoryEdgeType) throws -> MemoryAtom? {
        guard let edge = edges.first(where: { $0.type == type }) else {
            return nil
        }
        return try nodeStore.fetchMemoryAtom(id: edge.toAtomId)
    }

    private func targets(for edges: [MemoryEdge], type: MemoryEdgeType) throws -> [MemoryAtom] {
        try edges
            .filter { $0.type == type }
            .compactMap { try nodeStore.fetchMemoryAtom(id: $0.toAtomId) }
    }
}
