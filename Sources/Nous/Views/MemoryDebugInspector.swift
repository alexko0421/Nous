import SwiftUI

/// Phase 1.5 debug inspector. Read-only. Lets Alex eyeball whether the three
/// memory scopes are populating sensibly during real use. Replaced by the full
/// Memory Inspector in Phase 3 (read + edit + promote). Delete this file when
/// Phase 3 ships — nothing else depends on it.
struct MemoryDebugInspector: View {
    let nodeStore: NodeStore

    @State private var global: GlobalMemory?
    @State private var projectRows: [ProjectRow] = []
    @State private var conversationRows: [ConversationRow] = []
    @State private var loadError: String?

    @Environment(\.dismiss) private var dismiss

    struct ProjectRow: Identifiable {
        let id: UUID
        let title: String
        let memory: ProjectMemory?
    }

    struct ConversationRow: Identifiable {
        let id: UUID
        let title: String
        let memory: ConversationMemory?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let loadError {
                    Text(loadError)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }

                globalSection
                projectsSection
                conversationsSection

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(AppColor.colaBeige)
        .onAppear(perform: reload)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory (debug)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                Text("Read-only view of what Nous has learned across scopes.")
                    .font(.system(size: 12))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.55))
            }
            Spacer()
            Button("Reload") { reload() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AppColor.colaOrange)
                .clipShape(Capsule())

            Button("Close") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.colaDarkText.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.6))
                .clipShape(Capsule())
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var globalSection: some View {
        card {
            sectionLabel("Global")
            if let global, !global.content.isEmpty {
                memoryBlock(content: global.content, updatedAt: global.updatedAt)
            } else {
                emptyBlock("No global memory yet.")
            }
        }
    }

    @ViewBuilder
    private var projectsSection: some View {
        card {
            sectionLabel("Projects (\(projectRows.count))")
            if projectRows.isEmpty {
                emptyBlock("No projects.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(projectRows) { row in
                        projectRowView(row)
                        if row.id != projectRows.last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var conversationsSection: some View {
        card {
            sectionLabel("Conversations (\(conversationRows.count))")
            if conversationRows.isEmpty {
                emptyBlock("No conversations.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(conversationRows) { row in
                        conversationRowView(row)
                        if row.id != conversationRows.last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Row views

    @ViewBuilder
    private func projectRowView(_ row: ProjectRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
            if let memory = row.memory, !memory.content.isEmpty {
                memoryBlock(content: memory.content, updatedAt: memory.updatedAt)
            } else {
                emptyBlock("No project memory.")
            }
        }
    }

    @ViewBuilder
    private func conversationRowView(_ row: ConversationRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
            if let memory = row.memory, !memory.content.isEmpty {
                memoryBlock(content: memory.content, updatedAt: memory.updatedAt)
            } else {
                emptyBlock("No thread memory yet.")
            }
        }
    }

    // MARK: - Reusable chunks

    @ViewBuilder
    private func memoryBlock(content: String, updatedAt: Date) -> some View {
        let preview = Self.preview(of: content, maxChars: 200)
        VStack(alignment: .leading, spacing: 4) {
            Text(preview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(AppColor.colaDarkText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(content.count) chars · updated \(Self.relative(updatedAt))")
                .font(.system(size: 10))
                .foregroundColor(AppColor.colaDarkText.opacity(0.45))
        }
    }

    @ViewBuilder
    private func emptyBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(AppColor.colaDarkText.opacity(0.4))
            .italic()
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(AppColor.colaDarkText.opacity(0.45))
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppColor.colaDarkText.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 2)
    }

    // MARK: - Load

    private func reload() {
        do {
            let fetchedGlobal = try nodeStore.fetchGlobalMemory()

            let projects = try nodeStore.fetchAllProjects()
            let projectRows = try projects.map { project in
                ProjectRow(
                    id: project.id,
                    title: project.title,
                    memory: try nodeStore.fetchProjectMemory(projectId: project.id)
                )
            }

            let conversationNodes = try nodeStore.fetchAllNodes()
                .filter { $0.type == .conversation }
            let conversationRows = try conversationNodes.map { node in
                ConversationRow(
                    id: node.id,
                    title: node.title.isEmpty ? "Untitled" : node.title,
                    memory: try nodeStore.fetchConversationMemory(nodeId: node.id)
                )
            }

            self.global = fetchedGlobal
            self.projectRows = projectRows
            self.conversationRows = conversationRows
            self.loadError = nil
        } catch {
            self.loadError = "Failed to load memory: \(error.localizedDescription)"
        }
    }

    // MARK: - Formatters

    private static func preview(of content: String, maxChars: Int) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
        return trimmed[..<end] + "…"
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
