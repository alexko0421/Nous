import SwiftUI

struct MemoryGraphInspector: View {
    let nodeStore: NodeStore

    private enum GraphFocus: String, CaseIterable {
        case active = "Active"
        case chains = "Chains"
        case review = "Review"
        case all = "All"
    }

    private struct GraphDecisionChain: Identifiable {
        let rejection: MemoryAtom
        let proposal: MemoryAtom?
        let reasons: [MemoryAtom]
        let replacement: MemoryAtom?

        var id: UUID { rejection.id }
    }

    @State private var atoms: [MemoryAtom] = []
    @State private var edges: [MemoryEdge] = []
    @State private var observations: [MemoryObservation] = []
    @State private var recallEvents: [MemoryRecallEvent] = []
    @State private var nodeTitles: [UUID: String] = [:]
    @State private var projectTitles: [UUID: String] = [:]
    @State private var selectedAtomId: UUID?
    @State private var searchText = ""
    @State private var selectedFocus: GraphFocus = .active
    @State private var loadError: String?

    var body: some View {
        graphContainer {
            VStack(alignment: .leading, spacing: 16) {
                header
                metrics
                controls
                content
                unverifiedSection
                recallEventsSection
            }
        }
        .onAppear(perform: reload)
        .onChange(of: searchText) { _, _ in syncSelectedAtom() }
        .onChange(of: selectedFocus) { _, _ in syncSelectedAtom() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColor.colaOrange)
                .frame(width: 34, height: 34)
                .background(AppColor.colaOrange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Graph Memory Audit")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                Text("Atoms are the claims. Edges are the relationships. Chains show what was rejected, why, and what replaced it.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Reload") { reload() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(AppColor.surfacePrimary)
                .clipShape(Capsule())
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 10)], spacing: 10) {
            metric(title: "Atoms", value: "\(activeAtoms.count)", subtitle: "active claims")
            metric(title: "Edges", value: "\(edges.count)", subtitle: "relationships")
            metric(title: "Chains", value: "\(decisionChains.count)", subtitle: "rejection paths")
            metric(
                title: "Unverified",
                value: "\(unverifiedObservations.count)",
                subtitle: "not promoted",
                accent: unverifiedObservations.isEmpty ? AppColor.surfacePrimary : Color.yellow.opacity(0.12)
            )
            metric(title: "Recalls", value: "\(recallEvents.count)", subtitle: "recent events")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(AppColor.secondaryText)
                    TextField("Search atoms, sources, or chains", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AppColor.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text("\(filteredAtoms.count) visible")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(AppColor.surfacePrimary)
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                ForEach(GraphFocus.allCases, id: \.self) { focus in
                    let selected = selectedFocus == focus
                    Button(focus.rawValue) {
                        selectedFocus = focus
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .rounded))
                    .foregroundColor(selected ? .white : AppColor.colaDarkText.opacity(0.78))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selected ? AppColor.colaOrange : .clear)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(selected ? Color.clear : AppColor.panelStroke, lineWidth: 1)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            Text(loadError)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.red)
                .padding(.vertical, 8)
        } else if atoms.isEmpty {
            emptyState
        } else {
            HStack(alignment: .top, spacing: 14) {
                atomList
                    .frame(width: 300)
                atomDetail
            }
        }
    }

    private var atomList: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(selectedFocus == .chains ? "Decision Atoms" : "Atoms")

            if selectedFocus == .chains, !decisionChains.isEmpty {
                chainShortcutList
            }

            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(filteredAtoms) { atom in
                    atomRow(atom)
                }
            }
        }
        .padding(14)
        .background(AppColor.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var atomDetail: some View {
        if let atom = selectedAtom {
            VStack(alignment: .leading, spacing: 14) {
                atomSummary(atom)
                provenanceGrid(atom)
                decisionChainDetail(for: atom)
                sourceQuoteBlock(for: atom)
                edgeList(title: "Outgoing Edges", edges: outgoingEdges(for: atom), direction: .outgoing)
                edgeList(title: "Incoming Edges", edges: incomingEdges(for: atom), direction: .incoming)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Selected Atom")
                Text("Choose an atom to inspect its source, status, and graph relationships.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        }
    }

    private var chainShortcutList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(decisionChains.prefix(5)) { chain in
                Button {
                    selectedAtomId = chain.rejection.id
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(chain.proposal?.statement ?? "[unknown proposal]")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(AppColor.colaDarkText)
                            .lineLimit(2)
                        Text(chain.reasons.map(\.statement).joined(separator: " / "))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(AppColor.secondaryText)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColor.colaOrange.opacity(chain.rejection.id == selectedAtomId ? 0.14 : 0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func atomRow(_ atom: MemoryAtom) -> some View {
        let selected = atom.id == selectedAtomId
        return Button {
            selectedAtomId = atom.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    badge(text: atom.type.rawValue.replacingOccurrences(of: "_", with: " "), tint: typeTint(atom.type))
                    if atom.status != .active {
                        badge(text: atom.status.rawValue, tint: statusTint(atom.status))
                    }
                    Spacer(minLength: 0)
                }

                Text(atom.statement)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(scopeLabel(atom.scope, refId: atom.scopeRefId)) · \(timeLabel(atom.eventTime ?? atom.updatedAt))")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppColor.colaOrange.opacity(0.12) : AppColor.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? AppColor.colaOrange : AppColor.panelStroke, lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func atomSummary(_ atom: MemoryAtom) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                badge(text: atom.type.rawValue.replacingOccurrences(of: "_", with: " "), tint: typeTint(atom.type))
                badge(text: atom.status.rawValue, tint: statusTint(atom.status))
                badge(text: "\(Int((atom.confidence * 100).rounded()))% confidence", tint: AppColor.surfacePrimary)
            }

            Text(atom.statement)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Text("atom_id=\(atom.id.uuidString)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AppColor.secondaryText)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(AppColor.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func provenanceGrid(_ atom: MemoryAtom) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 152), spacing: 10)], spacing: 10) {
            statCard(title: "Scope", value: scopeLabel(atom.scope, refId: atom.scopeRefId))
            statCard(title: "Event Time", value: timeLabel(atom.eventTime))
            statCard(title: "Created", value: timeLabel(atom.createdAt))
            statCard(title: "Last Seen", value: timeLabel(atom.lastSeenAt))
            statCard(title: "Source Node", value: sourceNodeLabel(atom.sourceNodeId))
            statCard(title: "Source Message", value: atom.sourceMessageId?.uuidString ?? "missing")
        }
    }

    @ViewBuilder
    private func decisionChainDetail(for atom: MemoryAtom) -> some View {
        if let chain = decisionChain(for: atom) {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Decision Chain")
                chainField("Rejected proposal", chain.proposal?.statement ?? "[unknown proposal]")
                chainField("Rejection", chain.rejection.statement)
                if !chain.reasons.isEmpty {
                    chainField("Reason", chain.reasons.map(\.statement).joined(separator: " / "))
                }
                if let replacement = chain.replacement {
                    chainField("Replacement", replacement.statement)
                }
            }
            .padding(14)
            .background(AppColor.colaOrange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private func sourceQuoteBlock(for atom: MemoryAtom) -> some View {
        if let quote = sourceQuote(for: atom) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Source Quote")
                Text(quote)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(14)
            .background(AppColor.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private enum EdgeDirection {
        case outgoing
        case incoming
    }

    @ViewBuilder
    private func edgeList(title: String, edges: [MemoryEdge], direction: EdgeDirection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(title)
            if edges.isEmpty {
                Text("No \(title.lowercased()).")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(edges) { edge in
                        edgeRow(edge, direction: direction)
                    }
                }
            }
        }
        .padding(14)
        .background(AppColor.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func edgeRow(_ edge: MemoryEdge, direction: EdgeDirection) -> some View {
        let relatedId = direction == .outgoing ? edge.toAtomId : edge.fromAtomId
        let related = atomById[relatedId]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                badge(text: edge.type.rawValue.replacingOccurrences(of: "_", with: " "), tint: AppColor.colaOrange.opacity(0.10))
                Text(String(format: "%.2f weight", edge.weight))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                Spacer()
            }
            Text(related?.statement ?? relatedId.uuidString)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(AppColor.colaDarkText.opacity(0.86))
                .lineLimit(2)
            Text("edge_id=\(edge.id.uuidString)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(AppColor.secondaryText)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var unverifiedSection: some View {
        if !unverifiedObservations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Unverified Observations")
                Text("These were extracted by a backfill pass but were not promoted into graph memory because the evidence quote did not match a user message.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(unverifiedObservations.prefix(4)) { observation in
                        Text(observation.rawText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppColor.colaDarkText.opacity(0.8))
                            .lineLimit(3)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.yellow.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(14)
            .background(AppColor.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private var recallEventsSection: some View {
        if !recallEvents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Recent Recall Events")
                Text("Each row records the query, detected intent, time window, and atom ids injected into the prompt.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(recallEvents.prefix(5))) { event in
                        recallEventRow(event)
                    }
                }
            }
            .padding(14)
            .background(AppColor.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func recallEventRow(_ event: MemoryRecallEvent) -> some View {
        let retrieved = retrievedAtomLabel(for: event)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                badge(text: event.intent ?? "unknown", tint: AppColor.colaOrange.opacity(0.10))
                badge(text: "\(event.retrievedAtomIds.count) atoms", tint: AppColor.surfacePrimary)
                Text(timeLabel(event.createdAt))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                Spacer(minLength: 0)
            }

            Text(event.query.isEmpty ? "[empty query]" : preview(event.query, maxChars: 180))
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Text("window: \(timeWindowLabel(for: event))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(AppColor.secondaryText)
                .textSelection(.enabled)

            if !retrieved.isEmpty {
                Text("retrieved: \(retrieved)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let summary = event.answerSummary, !summary.isEmpty {
                Text("answer: \(preview(summary, maxChars: 180))")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func timeWindowLabel(for event: MemoryRecallEvent) -> String {
        guard let start = event.timeWindowStart,
              let end = event.timeWindowEnd
        else {
            return "none"
        }
        return "\(timeLabel(start)) to \(timeLabel(end))"
    }

    private func retrievedAtomLabel(for event: MemoryRecallEvent) -> String {
        event.retrievedAtomIds
            .prefix(4)
            .map { atomId in
                if let atom = atomById[atomId] {
                    let type = atom.type.rawValue.replacingOccurrences(of: "_", with: " ")
                    return "\(type): \(preview(atom.statement, maxChars: 90))"
                }
                return atomId.uuidString
            }
            .joined(separator: " / ")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No graph memory yet.")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
            Text("Once Nous extracts decision chains or facts, atom-level provenance will appear here.")
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
        }
        .padding(14)
        .background(AppColor.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var activeAtoms: [MemoryAtom] {
        atoms.filter { $0.status == .active }
    }

    private var decisionAtoms: [MemoryAtom] {
        atoms.filter { [.proposal, .rejection, .reason, .currentPosition, .decision].contains($0.type) }
    }

    private var reviewAtoms: [MemoryAtom] {
        atoms.filter { $0.status != .active }
    }

    private var filteredAtoms: [MemoryAtom] {
        let base: [MemoryAtom]
        switch selectedFocus {
        case .active:
            base = activeAtoms
        case .chains:
            base = decisionAtoms.filter { $0.status == .active }
        case .review:
            base = reviewAtoms
        case .all:
            base = atoms
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return base
            .filter { atom in
                guard !query.isEmpty else { return true }
                return atom.statement.lowercased().contains(query)
                    || atom.type.rawValue.lowercased().contains(query)
                    || scopeLabel(atom.scope, refId: atom.scopeRefId).lowercased().contains(query)
                    || sourceNodeLabel(atom.sourceNodeId).lowercased().contains(query)
            }
            .sorted { lhs, rhs in
                let leftTime = lhs.eventTime ?? lhs.updatedAt
                let rightTime = rhs.eventTime ?? rhs.updatedAt
                if lhs.status != rhs.status {
                    return statusRank(lhs.status) < statusRank(rhs.status)
                }
                return leftTime > rightTime
            }
    }

    private var selectedAtom: MemoryAtom? {
        filteredAtoms.first(where: { $0.id == selectedAtomId })
    }

    private var atomById: [UUID: MemoryAtom] {
        Dictionary(uniqueKeysWithValues: atoms.map { ($0.id, $0) })
    }

    private var unverifiedObservations: [MemoryObservation] {
        observations.filter { $0.rawText.hasPrefix("unverified_decision_chain|") }
    }

    private var decisionChains: [GraphDecisionChain] {
        atoms
            .filter { $0.type == .rejection && $0.status == .active }
            .compactMap(decisionChain(for:))
            .sorted {
                ($0.rejection.eventTime ?? $0.rejection.updatedAt)
                    > ($1.rejection.eventTime ?? $1.rejection.updatedAt)
            }
    }

    private func decisionChain(for atom: MemoryAtom) -> GraphDecisionChain? {
        if atom.type == .rejection {
            return chainForRejection(atom)
        }
        if let edge = edges.first(where: {
            ($0.type == .rejected || $0.type == .because) && $0.toAtomId == atom.id
        }), let rejection = atomById[edge.fromAtomId] {
            return chainForRejection(rejection)
        }
        if let edge = edges.first(where: { $0.type == .replacedBy && $0.toAtomId == atom.id }),
           let proposal = atomById[edge.fromAtomId],
           let rejectedEdge = edges.first(where: { $0.type == .rejected && $0.toAtomId == proposal.id }),
           let rejection = atomById[rejectedEdge.fromAtomId] {
            return chainForRejection(rejection)
        }
        return nil
    }

    private func chainForRejection(_ rejection: MemoryAtom) -> GraphDecisionChain? {
        guard rejection.type == .rejection else { return nil }
        let outgoing = edges.filter { $0.fromAtomId == rejection.id }
        let proposal = outgoing
            .first { $0.type == .rejected }
            .flatMap { atomById[$0.toAtomId] }
        let reasons = outgoing
            .filter { $0.type == .because }
            .compactMap { atomById[$0.toAtomId] }
        let directReplacement = outgoing
            .first { $0.type == .replacedBy }
            .flatMap { atomById[$0.toAtomId] }
        let proposalReplacement = proposal.flatMap { proposal in
            edges
                .first { $0.fromAtomId == proposal.id && $0.type == .replacedBy }
                .flatMap { atomById[$0.toAtomId] }
        }
        return GraphDecisionChain(
            rejection: rejection,
            proposal: proposal,
            reasons: reasons,
            replacement: directReplacement ?? proposalReplacement
        )
    }

    private func outgoingEdges(for atom: MemoryAtom) -> [MemoryEdge] {
        edges.filter { $0.fromAtomId == atom.id }
    }

    private func incomingEdges(for atom: MemoryAtom) -> [MemoryEdge] {
        edges.filter { $0.toAtomId == atom.id }
    }

    private func reload() {
        do {
            atoms = try nodeStore.fetchMemoryAtoms()
            edges = try nodeStore.fetchMemoryEdges()
            observations = try nodeStore.fetchMemoryObservations()
            recallEvents = try nodeStore.fetchMemoryRecallEvents(limit: 20)
            nodeTitles = try nodeStore.fetchAllNodeTitles()
            let projects = try nodeStore.fetchAllProjects()
            projectTitles = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.title) })
            loadError = nil
            syncSelectedAtom()
        } catch {
            loadError = "Failed to load graph memory: \(error.localizedDescription)"
        }
    }

    private func syncSelectedAtom() {
        guard !filteredAtoms.isEmpty else {
            selectedAtomId = nil
            return
        }
        if let selectedAtomId,
           filteredAtoms.contains(where: { $0.id == selectedAtomId }) {
            return
        }
        selectedAtomId = filteredAtoms.first?.id
    }

    private func sourceQuote(for atom: MemoryAtom) -> String? {
        guard let sourceNodeId = atom.sourceNodeId,
              let sourceMessageId = atom.sourceMessageId,
              let messages = try? nodeStore.fetchMessages(nodeId: sourceNodeId),
              let message = messages.first(where: { $0.id == sourceMessageId })
        else {
            return nil
        }
        return preview(message.content, maxChars: 220)
    }

    private func chainField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
            Text(value)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
            Text(value)
                .font(.system(size: 12, design: title == "Source Message" ? .monospaced : .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        .background(AppColor.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metric(title: String, value: String, subtitle: String, accent: Color = AppColor.surfacePrimary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
            Text(subtitle)
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func badge(text: String, tint: Color) -> some View {
        Text(text.capitalized)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(AppColor.colaDarkText.opacity(0.78))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint)
            .clipShape(Capsule())
    }

    private func graphContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(AppColor.secondaryText)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private func typeTint(_ type: MemoryAtomType) -> Color {
        switch type {
        case .rejection:
            return Color.red.opacity(0.10)
        case .proposal, .currentPosition, .decision:
            return AppColor.colaOrange.opacity(0.12)
        case .reason, .constraint, .boundary:
            return Color.yellow.opacity(0.14)
        default:
            return AppColor.surfacePrimary
        }
    }

    private func statusTint(_ status: MemoryStatus) -> Color {
        switch status {
        case .active:
            return AppColor.colaOrange.opacity(0.12)
        case .conflicted:
            return Color.red.opacity(0.12)
        case .expired:
            return Color.yellow.opacity(0.16)
        case .archived, .superseded:
            return AppColor.subtleFill
        }
    }

    private func statusRank(_ status: MemoryStatus) -> Int {
        switch status {
        case .active:
            return 0
        case .conflicted:
            return 1
        case .expired:
            return 2
        case .archived:
            return 3
        case .superseded:
            return 4
        }
    }

    private func scopeLabel(_ scope: MemoryScope, refId: UUID?) -> String {
        switch scope {
        case .global:
            return "Long-term"
        case .project:
            guard let refId else { return "Project" }
            return "Project · \(projectTitles[refId] ?? "Unknown")"
        case .conversation:
            guard let refId else { return "Thread" }
            return "Thread · \(nodeTitles[refId] ?? "Untitled")"
        case .selfReflection:
            return "Self-reflection"
        }
    }

    private func sourceNodeLabel(_ sourceNodeId: UUID?) -> String {
        guard let sourceNodeId else { return "missing" }
        return nodeTitles[sourceNodeId] ?? sourceNodeId.uuidString
    }

    private func timeLabel(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func preview(_ content: String, maxChars: Int) -> String {
        let trimmed = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        let limit = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
        return String(trimmed[..<limit]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
