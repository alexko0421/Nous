import SwiftUI

struct MemoryDebugInspector: View {
    let nodeStore: NodeStore
    let userMemoryService: UserMemoryService
    let telemetry: GovernanceTelemetryStore

    private enum MemoryFocus: String, CaseIterable {
        case active = "All"
        case global = "Long-term"
        case project = "Project"
        case conversation = "Thread"
        case review = "Review"

        var icon: String {
            switch self {
            case .active:
                return "sparkles"
            case .global:
                return "brain.head.profile"
            case .project:
                return "folder"
            case .conversation:
                return "text.bubble"
            case .review:
                return "exclamationmark.bubble"
            }
        }

        var subtitle: String {
            switch self {
            case .active:
                return "Everything Nous may still rely on."
            case .global:
                return "Identity-level memory that follows Alex everywhere."
            case .project:
                return "Context that survives across chats inside a project."
            case .conversation:
                return "Memory local to one thread."
            case .review:
                return "Conflicted or expired notes worth checking."
            }
        }
    }

    @State private var entries: [MemoryEntry] = []
    @State private var projectTitles: [UUID: String] = [:]
    @State private var nodeTitles: [UUID: String] = [:]
    @State private var searchText = ""
    @State private var selectedFocus: MemoryFocus = .active
    @State private var selectedEntryId: UUID?
    @State private var sourceSnippetsByEntryId: [UUID: [MemoryEvidenceSnippet]] = [:]
    @State private var actingEntryId: UUID?
    @State private var loadError: String?
    @State private var showAdvancedTools = false
    @State private var pendingDeleteEntry: MemoryEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                overviewCard
                browseCard

                HStack(alignment: .top, spacing: 20) {
                    entriesPane
                        .frame(width: 260)
                    detailsPane
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .background(AppColor.colaBeige)
        .onAppear(perform: reload)
        .onChange(of: searchText) { _, _ in syncSelectedEntry() }
        .onChange(of: selectedFocus) { _, _ in syncSelectedEntry() }
        .sheet(isPresented: $showAdvancedTools) {
            advancedToolsSheet
        }
        .confirmationDialog(
            "Delete this memory row?",
            isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if $0 == false { pendingDeleteEntry = nil } }
            ),
            presenting: pendingDeleteEntry
        ) { entry in
            Button("Delete Row", role: .destructive) {
                let entryId = entry.id
                pendingDeleteEntry = nil
                mutate(entryId, failureMessage: "Failed to delete memory.") {
                    userMemoryService.deleteMemoryEntry(id: entryId)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteEntry = nil
            }
        } message: { _ in
            Text("Nous will stop using this memory. The original chat or note stays untouched.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                Text("A calm view of what Nous is carrying forward across Alex's life, projects, and threads.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack(spacing: 10) {
                Button("Advanced") { showAdvancedTools = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(AppColor.surfaceSecondary)
                    .clipShape(Capsule())

                Button("Reload") { reload() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(AppColor.colaOrange)
                    .clipShape(Capsule())
            }
        }
    }

    private var overviewCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Nous should remember the smallest durable set of notes that saves Alex from repeating himself.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                    overviewMetric(title: "Long-term", value: count(for: MemoryScope.global), subtitle: "Identity memory")
                    overviewMetric(title: "Project", value: count(for: MemoryScope.project), subtitle: "Cross-chat project context")
                    overviewMetric(title: "Thread", value: count(for: MemoryScope.conversation), subtitle: "Single-thread memory")
                    overviewMetric(title: "Review", value: reviewEntries.count, subtitle: "Needs attention", accent: reviewEntries.isEmpty ? AppColor.surfacePrimary : Color.red.opacity(0.10))
                }

                if let loadError {
                    Text(loadError)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.red)
                }
            }
        }
    }

    private var browseCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    searchField
                    statPill(title: "Active", value: "\(activeEntries.count)")
                    statPill(title: "Visible", value: "\(filteredEntries.count)")
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Browse")
                    filterRow(
                        options: MemoryFocus.allCases,
                        selection: selectedFocus,
                        onSelect: { selectedFocus = $0 }
                    )
                }
            }
        }
    }

    private var entriesPane: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel(selectedFocus == .active ? "Active Memory" : selectedFocus.rawValue)

                Text(selectedFocus.subtitle)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if filteredEntries.isEmpty {
                    emptyEntriesState
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredEntries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
        }
    }

    private var detailsPane: some View {
        card {
            if let entry = selectedEntry {
                entryDetail(entry)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Selected Memory")
                    Text("Choose a memory note on the left to read the full context here.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(AppColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyEntriesState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing to show here yet.")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
            Text(emptyStateCopy)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(AppColor.secondaryText)
            TextField("Search what Nous remembers", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppColor.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
    }

    private var filteredEntries: [MemoryEntry] {
        entriesForFocus.filter { entry in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            let normalizedQuery = query.lowercased()
            if entry.content.lowercased().contains(normalizedQuery) {
                return true
            }
            if sourceSummary(for: entry).lowercased().contains(normalizedQuery) {
                return true
            }
            return entryHeadline(for: entry).lowercased().contains(normalizedQuery)
        }
    }

    private var sortedEntries: [MemoryEntry] {
        entries.sorted { lhs, rhs in
            if statusRank(lhs.status) != statusRank(rhs.status) {
                return statusRank(lhs.status) < statusRank(rhs.status)
            }
            if scopeRank(lhs.scope) != scopeRank(rhs.scope) {
                return scopeRank(lhs.scope) < scopeRank(rhs.scope)
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private var activeEntries: [MemoryEntry] {
        sortedEntries.filter { $0.status == .active }
    }

    private var reviewEntries: [MemoryEntry] {
        sortedEntries.filter { $0.status == .conflicted || $0.status == .expired }
    }

    private var entriesForFocus: [MemoryEntry] {
        switch selectedFocus {
        case .active:
            return activeEntries
        case .global:
            return activeEntries.filter { $0.scope == .global }
        case .project:
            return activeEntries.filter { $0.scope == .project }
        case .conversation:
            return activeEntries.filter { $0.scope == .conversation }
        case .review:
            return reviewEntries
        }
    }

    private var selectedEntry: MemoryEntry? {
        filteredEntries.first(where: { $0.id == selectedEntryId })
    }

    @ViewBuilder
    private func entryRow(_ entry: MemoryEntry) -> some View {
        let isSelected = selectedEntryId == entry.id

        Button {
            selectEntry(entry)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text(entryHeadline(for: entry))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if entry.status != .active {
                        badge(text: statusDisplay(entry.status), tint: statusTint(entry.status), textColor: statusTextColor(entry.status))
                    }
                }

                Text(entry.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.88))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(kindDisplay(entry.kind)) · \(entry.stability.rawValue.capitalized)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(AppColor.secondaryText)
                    Text("\(sourceSummary(for: entry)) · Updated \(Self.relative(entry.updatedAt))")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(AppColor.secondaryText)
                    if let reviewNote = reviewNote(for: entry), entry.status != .active {
                        Text(reviewNote)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(statusTextColor(entry.status))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AppColor.colaOrange.opacity(0.10) : statusBackground(entry.status))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? AppColor.colaOrange : statusBorder(entry.status), lineWidth: isSelected ? 1.5 : 1)
        )
    }

    @ViewBuilder
    private func entryDetail(_ entry: MemoryEntry) -> some View {
        let isBusy = actingEntryId == entry.id
        let snippetsLoaded = sourceSnippetsByEntryId[entry.id] != nil
        let snippets = sourceSnippetsByEntryId[entry.id] ?? []

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if entry.status != .active {
                            badge(text: statusDisplay(entry.status), tint: statusTint(entry.status), textColor: statusTextColor(entry.status))
                        }
                        badge(
                            text: "\(Int((entry.confidence * 100).rounded()))% confidence",
                            tint: AppColor.surfacePrimary,
                            textColor: AppColor.colaDarkText.opacity(0.78)
                        )
                    }
                    Text(detailHeadline(for: entry))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                    Text(detailSubheadline(for: entry))
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(AppColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text(detailStatusLine(for: entry))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(entry.status == .active ? AppColor.colaDarkText : statusTextColor(entry.status))
                    Spacer()
                    Text("Updated \(Self.relative(entry.updatedAt))")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(AppColor.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(entry.status == .active ? AppColor.surfacePrimary : statusBackground(entry.status))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Content")
                Text(entry.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 15, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(AppColor.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Context")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    detailStatCard(title: "Kind", value: kindDisplay(entry.kind))
                    detailStatCard(title: "Stability", value: entry.stability.rawValue.capitalized)
                    detailStatCard(title: "Scope", value: scopeDisplay(for: entry))
                    detailStatCard(title: "Sources", value: sourceSummary(for: entry))
                    detailStatCard(title: "Created", value: timestamp(entry.createdAt))
                    detailStatCard(title: "Last confirmed", value: confirmationSummary(for: entry))
                    if let expiresAt = entry.expiresAt {
                        detailStatCard(title: "Expires", value: timestamp(expiresAt))
                    }
                    if let reviewNote = reviewNote(for: entry), entry.status != .active {
                        detailStatCard(title: "Review", value: reviewNote, accent: statusBackground(entry.status))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionLabel("Evidence")
                    Spacer()
                    if snippetsLoaded == false && !entry.sourceNodeIds.isEmpty {
                        smallActionButton(
                            title: "Inspect Source",
                            tint: AppColor.surfacePrimary,
                            textColor: AppColor.colaDarkText
                        ) {
                            ensureSourceSnippets(for: entry)
                        }
                    }
                }
                if snippetsLoaded {
                    sourceSnippetSection(snippets: snippets)
                } else if entry.sourceNodeIds.isEmpty {
                    Text("This memory does not yet have a linked source snippet.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(AppColor.secondaryText)
                        .padding(.top, 4)
                } else {
                    Text("Source evidence stays on demand so opening Memory remains quick.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(AppColor.secondaryText)
                        .padding(.top, 4)
                }
            }

            HStack(spacing: 10) {
                if entry.status == .active {
                    smallActionButton(
                        title: "Keep Using",
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
                        tint: AppColor.surfaceSecondary,
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
                    pendingDeleteEntry = entry
                }
                .disabled(isBusy)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .background(AppColor.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private func detailStatCard(title: String, value: String, accent: Color = AppColor.surfacePrimary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.secondaryText)

            Text(value)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .padding(12)
        .background(accent)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .background(AppColor.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        .background(AppColor.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                .foregroundColor(isSelected ? .white : AppColor.colaDarkText.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? AppColor.colaOrange : .clear)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : AppColor.panelStroke, lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func overviewMetric(title: String, value: Int, subtitle: String, accent: Color = AppColor.surfacePrimary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
            Text("\(value)")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
            Text(subtitle)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(accent)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private var advancedToolsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Advanced Memory Tools")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                    Text("Raw entries and judge review stay here, outside the main Settings flow.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(AppColor.secondaryText)
                }

                Spacer()

                Button("Done") { showAdvancedTools = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(AppColor.colaOrange)
                    .clipShape(Capsule())
            }
            .padding(24)

            TabView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        card {
                            VStack(alignment: .leading, spacing: 12) {
                                sectionLabel("Raw Entries")
                                Text("Every memory row, including archived and superseded notes.")
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundColor(AppColor.secondaryText)

                                if sortedEntries.isEmpty {
                                    Text("No memory entries yet.")
                                        .font(.system(size: 13, design: .rounded))
                                        .foregroundColor(AppColor.secondaryText)
                                } else {
                                    LazyVStack(alignment: .leading, spacing: 12) {
                                        ForEach(sortedEntries) { entry in
                                            advancedEntryRow(entry)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                }
                .background(AppColor.colaBeige)
                .tabItem { Label("Entries", systemImage: "tray.full") }

                JudgeEventsTab(telemetry: telemetry)
                    .tabItem { Label("Judge", systemImage: "wand.and.sparkles") }
            }
        }
        .frame(minWidth: 860, minHeight: 640)
        .background(AppColor.colaBeige)
    }

    @ViewBuilder
    private func advancedEntryRow(_ entry: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                badge(text: scopeDisplay(for: entry), tint: AppColor.colaOrange.opacity(0.14), textColor: AppColor.colaDarkText)
                badge(text: statusDisplay(entry.status), tint: statusTint(entry.status), textColor: statusTextColor(entry.status))
                Spacer()
                Text("Updated \(Self.relative(entry.updatedAt))")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
            }

            Text(entry.content.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(kindDisplay(entry.kind)) · \(sourceSummary(for: entry))")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
        }
        .padding(14)
        .background(statusBackground(entry.status))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(statusBorder(entry.status), lineWidth: 1)
        )
    }

    private func reload() {
        do {
            entries = userMemoryService.allMemoryEntries()

            let projects = try nodeStore.fetchAllProjects()
            projectTitles = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.title) })
            nodeTitles = try nodeStore.fetchAllNodeTitles()

            let validIds = Set(entries.map(\.id))
            sourceSnippetsByEntryId = sourceSnippetsByEntryId.filter { validIds.contains($0.key) }
            loadError = nil
            syncSelectedEntry()
        } catch {
            loadError = "Failed to load memory: \(error.localizedDescription)"
        }
    }

    private func ensureSourceSnippets(for entry: MemoryEntry) {
        if sourceSnippetsByEntryId[entry.id] == nil {
            sourceSnippetsByEntryId[entry.id] = userMemoryService.sourceSnippets(for: entry.id, limit: 3)
        }
    }

    private func selectEntry(_ entry: MemoryEntry) {
        selectedEntryId = entry.id
    }

    private func syncSelectedEntry() {
        guard !filteredEntries.isEmpty else {
            selectedEntryId = nil
            return
        }

        if let selectedEntryId,
           filteredEntries.contains(where: { $0.id == selectedEntryId }) {
            return
        }

        if let firstEntry = filteredEntries.first {
            selectEntry(firstEntry)
        }
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
            return "Long-term"
        case .project:
            guard let scopeRefId = entry.scopeRefId else { return "Project" }
            return "Project · \(projectTitles[scopeRefId] ?? "Unknown")"
        case .conversation:
            guard let scopeRefId = entry.scopeRefId else { return "Thread" }
            return "Thread · \(nodeTitles[scopeRefId] ?? "Untitled")"
        case .selfReflection:
            return "Self-reflection"
        }
    }

    private func count(for scope: MemoryScope) -> Int {
        activeEntries.filter { $0.scope == scope }.count
    }

    private func scopeRank(_ scope: MemoryScope) -> Int {
        switch scope {
        case .global:
            return 0
        case .project:
            return 1
        case .conversation:
            return 2
        case .selfReflection:
            return 3
        }
    }

    private func entryHeadline(for entry: MemoryEntry) -> String {
        switch entry.scope {
        case .global:
            return "Long-term memory"
        case .project:
            guard let scopeRefId = entry.scopeRefId else { return "Project memory" }
            return projectTitles[scopeRefId] ?? "Project memory"
        case .conversation:
            guard let scopeRefId = entry.scopeRefId else { return "Thread memory" }
            return nodeTitles[scopeRefId] ?? "Thread memory"
        case .selfReflection:
            return "Self-reflection"
        }
    }

    private func detailHeadline(for entry: MemoryEntry) -> String {
        switch entry.scope {
        case .global:
            return "Long-term memory about Alex"
        case .project:
            return entryHeadline(for: entry)
        case .conversation:
            return entryHeadline(for: entry)
        case .selfReflection:
            return "Self-reflection"
        }
    }

    private func detailSubheadline(for entry: MemoryEntry) -> String {
        switch entry.scope {
        case .global:
            return "This is durable identity or preference context Nous may quietly reuse across future conversations."
        case .project:
            return "This belongs to one project and should survive across chats until the project direction changes."
        case .conversation:
            return "This note stays local to one thread so the conversation can continue without restating the same context."
        case .selfReflection:
            return "Nous's weekly self-reflection about patterns across recent conversations."
        }
    }

    private func detailStatusLine(for entry: MemoryEntry) -> String {
        if let reviewNote = reviewNote(for: entry), entry.status != .active {
            return reviewNote
        }
        return "This memory is still active in Nous's read path."
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

    private func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private var emptyStateCopy: String {
        switch selectedFocus {
        case .active:
            return "Nous has nothing active to carry forward right now."
        case .global:
            return "No long-term identity memory is active yet."
        case .project:
            return "No project-level memory is active yet."
        case .conversation:
            return "No thread-level memory is active yet."
        case .review:
            return "Nothing is currently waiting for review."
        }
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
            return AppColor.surfaceSecondary
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
            return AppColor.surfacePrimary
        case .conflicted:
            return Color.red.opacity(0.05)
        case .expired:
            return Color.yellow.opacity(0.06)
        case .archived, .superseded:
            return AppColor.subtleFill
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

    static func relative(_ date: Date) -> String {
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
            if let summary = telemetry.geminiCacheSummary {
                geminiCacheSummaryCard(summary)
            }
            HStack {
                Picker("Filter", selection: $filter) {
                    Text("All").tag(JudgeEventFilter.none)
                    Text("Provoked").tag(JudgeEventFilter.shouldProvoke(true))
                    Text("Not provoked").tag(JudgeEventFilter.shouldProvoke(false))
                    Text("Contradiction").tag(JudgeEventFilter.provocationKind(.contradiction))
                    Text("Spark").tag(JudgeEventFilter.provocationKind(.spark))
                    Text("Neutral").tag(JudgeEventFilter.provocationKind(.neutral))
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

    private func geminiCacheSummaryCard(_ summary: GeminiCacheSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gemini Cache")
                .font(.headline)

            HStack(spacing: 12) {
                cacheStat(title: "Requests", value: "\(summary.requestCount)")
                cacheStat(title: "Overall Hit", value: percentage(summary.cacheHitRate))
                cacheStat(title: "Cached Tokens", value: "\(summary.totalCachedTokens)")
            }

            if let last = summary.lastSnapshot {
                Text(
                    "Last request: \(last.usage.cachedContentTokenCount)/\(last.usage.promptTokenCount) prompt tokens reused (\(percentage(last.cacheHitRate))) \(MemoryDebugInspector.relative(last.recordedAt))."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func cacheStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func percentage(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return "\(Int((value * 100).rounded()))%"
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func reload() {
        events = telemetry.recentJudgeEvents(limit: 200, filter: filter)
    }
}
