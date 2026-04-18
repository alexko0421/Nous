import SwiftUI

struct MemoryDebugInspector: View {
    let nodeStore: NodeStore
    let userMemoryService: UserMemoryService
    let telemetry: GovernanceTelemetryStore

    private enum InspectorTab {
        case memory
        case judge
    }

    @State private var selectedInspectorTab: InspectorTab = .memory
    @State private var entries: [MemoryEntry] = []
    @State private var projectTitles: [UUID: String] = [:]
    @State private var nodeTitles: [UUID: String] = [:]
    @State private var searchText = ""
    @State private var selectedScope: ScopeFilter = .all
    @State private var selectedStatus: StatusFilter = .all
    @State private var expandedEntryIds: Set<UUID> = []
    @State private var sourceSnippetsByEntryId: [UUID: [MemoryEvidenceSnippet]] = [:]
    @State private var actingEntryId: UUID?
    @State private var loadError: String?

    @Environment(\.dismiss) private var dismiss

    private enum ScopeFilter: String, CaseIterable {
        case all = "All"
        case global = "Global"
        case project = "Project"
        case conversation = "Thread"
    }

    private enum StatusFilter: String, CaseIterable {
        case all = "All"
        case active = "Active"
        case conflicted = "Conflicted"
        case expired = "Expired"
        case archived = "Archived"
        case superseded = "Superseded"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 12)

            TabView(selection: $selectedInspectorTab) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        controlsCard
                        entriesCard
                        Spacer(minLength: 20)
                    }
                    .padding(24)
                }
                .tabItem { Label("Memory", systemImage: "brain") }
                .tag(InspectorTab.memory)

                JudgeEventsTab(telemetry: telemetry)
                    .tabItem { Label("Judge", systemImage: "wand.and.sparkles") }
                    .tag(InspectorTab.judge)
            }
        }
        .frame(minWidth: 820, minHeight: 640)
        .background(AppColor.colaBeige)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                Text("Inspect what Nous remembers, why it remembers it, and whether it still deserves to stay active.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Reload") { reload() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(AppColor.colaOrange)
                .clipShape(Capsule())

            Button("Close") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.colaDarkText.opacity(0.72))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.65))
                .clipShape(Capsule())
        }
    }

    private var controlsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    searchField
                    statPill(title: "Total", value: "\(entries.count)")
                    statPill(title: "Active", value: "\(entries.filter { $0.status == .active }.count)")
                    statPill(
                        title: "Needs Review",
                        value: "\(entries.filter { $0.status == .conflicted || $0.status == .expired }.count)"
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Scope")
                    filterRow(
                        options: ScopeFilter.allCases,
                        selection: selectedScope,
                        onSelect: { selectedScope = $0 }
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Status")
                    filterRow(
                        options: StatusFilter.allCases,
                        selection: selectedStatus,
                        onSelect: { selectedStatus = $0 }
                    )
                }

                if let loadError {
                    Text(loadError)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.red)
                }
            }
        }
    }

    private var entriesCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("Entries (\(filteredEntries.count))")

                if filteredEntries.isEmpty {
                    Text("No memory matches the current filters.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(AppColor.secondaryText)
                        .padding(.vertical, 10)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(filteredEntries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(AppColor.secondaryText)
            TextField("Search memory content or source title", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
    }

    private var filteredEntries: [MemoryEntry] {
        userVisibleEntries.filter { entry in
            let scopeMatches: Bool = {
                switch selectedScope {
                case .all:
                    return true
                case .global:
                    return entry.scope == .global
                case .project:
                    return entry.scope == .project
                case .conversation:
                    return entry.scope == .conversation
                }
            }()

            let statusMatches: Bool = {
                switch selectedStatus {
                case .all:
                    return true
                case .active:
                    return entry.status == .active
                case .conflicted:
                    return entry.status == .conflicted
                case .expired:
                    return entry.status == .expired
                case .archived:
                    return entry.status == .archived
                case .superseded:
                    return entry.status == .superseded
                }
            }()

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatches: Bool = {
                guard !query.isEmpty else { return true }
                let normalizedQuery = query.lowercased()
                if entry.content.lowercased().contains(normalizedQuery) {
                    return true
                }
                return sourceSummary(for: entry).lowercased().contains(normalizedQuery)
            }()

            return scopeMatches && statusMatches && searchMatches
        }
    }

    private var userVisibleEntries: [MemoryEntry] {
        entries.sorted { lhs, rhs in
            let lhsRank = statusRank(lhs.status)
            let rhsRank = statusRank(rhs.status)
            if lhsRank == rhsRank {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhsRank < rhsRank
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: MemoryEntry) -> some View {
        let isExpanded = expandedEntryIds.contains(entry.id)
        let isBusy = actingEntryId == entry.id
        let snippets = sourceSnippetsByEntryId[entry.id] ?? []

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        badge(text: scopeDisplay(for: entry), tint: AppColor.colaOrange.opacity(0.14), textColor: AppColor.colaDarkText)
                        badge(text: statusDisplay(entry.status), tint: statusTint(entry.status), textColor: statusTextColor(entry.status))
                        badge(
                            text: "\(Int((entry.confidence * 100).rounded()))% confidence",
                            tint: Color.white.opacity(0.7),
                            textColor: AppColor.colaDarkText.opacity(0.78)
                        )
                    }

                    Text(entry.content.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text("Updated \(Self.relative(entry.updatedAt))")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("\(kindDisplay(entry.kind)) · \(entry.stability.rawValue.capitalized)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                Text("Sources: \(sourceSummary(for: entry))")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                Text("Last confirmed: \(confirmationSummary(for: entry))")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                if let reviewNote = reviewNote(for: entry) {
                    Text(reviewNote)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(statusTextColor(entry.status))
                }
            }

            HStack(spacing: 10) {
                smallActionButton(
                    title: isExpanded ? "Hide Source" : "Inspect Source",
                    tint: Color.white.opacity(0.7),
                    textColor: AppColor.colaDarkText
                ) {
                    toggleSources(for: entry)
                }

                if entry.status == .active {
                    smallActionButton(
                        title: "Confirm",
                        tint: AppColor.colaOrange.opacity(0.15),
                        textColor: AppColor.colaDarkText
                    ) {
                        mutate(entry.id, failureMessage: "Failed to confirm memory.") {
                            userMemoryService.confirmMemoryEntry(id: entry.id)
                        }
                    }
                    .disabled(isBusy)
                }

                if entry.status != .archived {
                    smallActionButton(
                        title: "Archive",
                        tint: Color.white.opacity(0.7),
                        textColor: AppColor.colaDarkText
                    ) {
                        mutate(entry.id, failureMessage: "Failed to archive memory.") {
                            userMemoryService.archiveMemoryEntry(id: entry.id)
                        }
                    }
                    .disabled(isBusy)
                }

                smallActionButton(
                    title: "Delete",
                    tint: Color.red.opacity(0.12),
                    textColor: .red
                ) {
                    mutate(entry.id, failureMessage: "Failed to delete memory.") {
                        userMemoryService.deleteMemoryEntry(id: entry.id)
                    }
                }
                .disabled(isBusy)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            if isExpanded {
                sourceSnippetSection(snippets: snippets)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusBackground(entry.status))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(statusBorder(entry.status), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func sourceSnippetSection(snippets: [MemoryEvidenceSnippet]) -> some View {
        if snippets.isEmpty {
            Text("No linked source snippet is available for this memory yet.")
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
                .padding(.top, 4)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(snippets.enumerated()), id: \.offset) { _, snippet in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(snippet.label) · \(snippet.sourceTitle)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(AppColor.colaDarkText.opacity(0.72))
                        Text(snippet.snippet)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(AppColor.colaDarkText.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(AppColor.secondaryText)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.68))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppColor.panelStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.03), radius: 8, x: 0, y: 3)
    }

    @ViewBuilder
    private func statPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func filterRow<Option: Hashable & RawRepresentable>(
        options: [Option],
        selection: Option,
        onSelect: @escaping (Option) -> Void
    ) -> some View where Option.RawValue == String {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button(option.rawValue) {
                    onSelect(option)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .rounded))
                .foregroundColor(isSelected ? .white : AppColor.colaDarkText.opacity(0.78))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? AppColor.colaOrange : Color.white.opacity(0.7))
                .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private func badge(text: String, tint: Color, textColor: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(textColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func smallActionButton(
        title: String,
        tint: Color,
        textColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundColor(textColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(tint)
            .clipShape(Capsule())
    }

    private func reload() {
        do {
            entries = userMemoryService.allMemoryEntries()

            let projects = try nodeStore.fetchAllProjects()
            projectTitles = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.title) })

            let nodes = try nodeStore.fetchAllNodes()
            nodeTitles = Dictionary(
                uniqueKeysWithValues: nodes.map { node in
                    (node.id, node.title.isEmpty ? "Untitled" : node.title)
                }
            )

            let validIds = Set(entries.map(\.id))
            expandedEntryIds = expandedEntryIds.intersection(validIds)
            sourceSnippetsByEntryId = sourceSnippetsByEntryId.filter { validIds.contains($0.key) }
            loadError = nil
        } catch {
            loadError = "Failed to load memory: \(error.localizedDescription)"
        }
    }

    private func toggleSources(for entry: MemoryEntry) {
        if expandedEntryIds.contains(entry.id) {
            expandedEntryIds.remove(entry.id)
            return
        }

        if sourceSnippetsByEntryId[entry.id] == nil {
            sourceSnippetsByEntryId[entry.id] = userMemoryService.sourceSnippets(for: entry.id, limit: 3)
        }
        expandedEntryIds.insert(entry.id)
    }

    private func mutate(
        _ entryId: UUID,
        failureMessage: String,
        action: () -> Bool
    ) {
        actingEntryId = entryId
        let succeeded = action()
        actingEntryId = nil

        if succeeded {
            loadError = nil
            reload()
        } else {
            loadError = failureMessage
        }
    }

    private func scopeDisplay(for entry: MemoryEntry) -> String {
        switch entry.scope {
        case .global:
            return "Global"
        case .project:
            guard let scopeRefId = entry.scopeRefId else { return "Project" }
            return "Project · \(projectTitles[scopeRefId] ?? "Unknown")"
        case .conversation:
            guard let scopeRefId = entry.scopeRefId else { return "Thread" }
            return "Thread · \(nodeTitles[scopeRefId] ?? "Untitled")"
        }
    }

    private func kindDisplay(_ kind: MemoryKind) -> String {
        kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func sourceSummary(for entry: MemoryEntry) -> String {
        guard !entry.sourceNodeIds.isEmpty else { return "No linked source" }

        let titles = entry.sourceNodeIds.compactMap { nodeTitles[$0] }.prefix(2)
        if titles.isEmpty {
            return "\(entry.sourceNodeIds.count) linked source\(entry.sourceNodeIds.count == 1 ? "" : "s")"
        }

        let joined = titles.joined(separator: ", ")
        if entry.sourceNodeIds.count > titles.count {
            return "\(joined) +\(entry.sourceNodeIds.count - titles.count) more"
        }
        return joined
    }

    private func confirmationSummary(for entry: MemoryEntry) -> String {
        guard let lastConfirmedAt = entry.lastConfirmedAt else { return "Not confirmed yet" }
        return Self.relative(lastConfirmedAt)
    }

    private func reviewNote(for entry: MemoryEntry) -> String? {
        switch entry.status {
        case .conflicted:
            return "This memory conflicts with newer evidence and needs review."
        case .expired:
            return "This was treated as temporary context and has now expired."
        case .superseded:
            return "A newer memory replaced this one, but it remains visible for traceability."
        case .archived:
            return "Archived memories stay out of the active read path."
        case .active:
            return nil
        }
    }

    private func statusDisplay(_ status: MemoryStatus) -> String {
        switch status {
        case .active:
            return "Active"
        case .archived:
            return "Archived"
        case .conflicted:
            return "Conflicted"
        case .superseded:
            return "Superseded"
        case .expired:
            return "Expired"
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

    private func statusTint(_ status: MemoryStatus) -> Color {
        switch status {
        case .active:
            return AppColor.colaOrange.opacity(0.14)
        case .conflicted:
            return Color.red.opacity(0.14)
        case .expired:
            return Color.yellow.opacity(0.18)
        case .archived:
            return Color.white.opacity(0.7)
        case .superseded:
            return Color.gray.opacity(0.16)
        }
    }

    private func statusTextColor(_ status: MemoryStatus) -> Color {
        switch status {
        case .active:
            return AppColor.colaDarkText
        case .conflicted:
            return .red
        case .expired:
            return Color(red: 0.56, green: 0.42, blue: 0.08)
        case .archived, .superseded:
            return AppColor.colaDarkText.opacity(0.7)
        }
    }

    private func statusBackground(_ status: MemoryStatus) -> Color {
        switch status {
        case .active:
            return Color.white.opacity(0.7)
        case .conflicted:
            return Color.red.opacity(0.05)
        case .expired:
            return Color.yellow.opacity(0.06)
        case .archived, .superseded:
            return Color.white.opacity(0.56)
        }
    }

    private func statusBorder(_ status: MemoryStatus) -> Color {
        switch status {
        case .active:
            return AppColor.panelStroke
        case .conflicted:
            return Color.red.opacity(0.2)
        case .expired:
            return Color.yellow.opacity(0.25)
        case .archived, .superseded:
            return AppColor.panelStroke.opacity(0.9)
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct JudgeEventsTab: View {
    let telemetry: GovernanceTelemetryStore
    @State private var filter: JudgeEventFilter = .none
    @State private var events: [JudgeEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Filter", selection: $filter) {
                    Text("All").tag(JudgeEventFilter.none)
                    Text("Provoked").tag(JudgeEventFilter.shouldProvoke(true))
                    Text("Not provoked").tag(JudgeEventFilter.shouldProvoke(false))
                    Text("Failures").tag(JudgeEventFilter.fallback(.timeout))
                    Text("Bad JSON").tag(JudgeEventFilter.fallback(.badJSON))
                    Text("Scope breach").tag(JudgeEventFilter.fallback(.unknownEntryId))
                }
                .pickerStyle(.menu)
                Button("Refresh") { reload() }
            }
            List(events, id: \.id) { event in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(event.ts.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospaced())
                        Text(event.chatMode.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .background(.secondary.opacity(0.15))
                            .clipShape(Capsule())
                        Text(event.fallbackReason.rawValue)
                            .font(.caption)
                            .foregroundStyle(event.fallbackReason == .ok ? .green : .orange)
                        if let fb = event.userFeedback {
                            Image(systemName: fb == .up ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                                .font(.caption)
                                .foregroundStyle(fb == .up ? .green : .red)
                        }
                    }
                    Text(event.verdictJSON)
                        .font(.caption2.monospaced())
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: filter) { _, _ in reload() }
    }

    private func reload() {
        events = telemetry.recentJudgeEvents(limit: 200, filter: filter)
    }
}
