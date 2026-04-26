import Foundation
import SwiftUI

private struct ProjectListSummary: Identifiable {
    let project: Project
    let nodeCount: Int
    let lastUpdatedAt: Date?

    var id: UUID { project.id }
}

struct ProjectListView: View {
    let nodeStore: NodeStore
    @Binding var selectedProjectId: UUID?
    var onProjectSelected: (() -> Void)?

    @State private var projects: [ProjectListSummary] = []
    @State private var showCreate: Bool = false
    @State private var newTitle: String = ""
    @State private var newEmoji: String = "📁"
    @State private var newGoal: String = ""

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if showCreate {
                createPanel
            }

            projectButton(
                title: "All Space",
                subtitle: "Cross-project view",
                emoji: "🗂️",
                isSelected: selectedProjectId == nil,
                footnote: "\(projects.count) projects"
            ) {
                selectedProjectId = nil
                onProjectSelected?()
            }

            ForEach(projects) { summary in
                projectButton(
                    title: summary.project.title,
                    subtitle: summary.project.goal.isEmpty ? "No goal yet" : summary.project.goal,
                    emoji: summary.project.emoji,
                    isSelected: selectedProjectId == summary.project.id,
                    footnote: summaryFootnote(summary)
                ) {
                    selectedProjectId = summary.project.id
                    onProjectSelected?()
                }
            }

            if projects.isEmpty {
                Text("Create a project to give one part of your graph a clear goal.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .onAppear { loadProjects() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .nousNodesDidChange,
                object: nodeStore
            )
        ) { _ in
            loadProjects()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Projects")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.6))

                Text("\(projects.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
            }

            Spacer()

            Button(action: { showCreate.toggle() }) {
                Image(systemName: showCreate ? "xmark" : "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.5))
                    .frame(width: 20, height: 20)
                    .background(AppColor.colaDarkText.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 2)
    }

    private var createPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("📁", text: $newEmoji)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .frame(width: 28)

                TextField("Name", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
            }

            TextField("Goal", text: $newGoal)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.secondaryText)

            Button(action: createProject) {
                Text("Create Project")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(AppColor.colaOrange)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(AppColor.colaDarkText.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func projectButton(
        title: String,
        subtitle: String,
        emoji: String,
        isSelected: Bool,
        footnote: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(emoji)
                        .font(.system(size: 15))

                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(isSelected ? AppColor.colaOrange : AppColor.colaDarkText.opacity(0.78))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }

                Text(subtitle)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(isSelected ? AppColor.colaDarkText.opacity(0.62) : AppColor.secondaryText)
                    .lineLimit(2)

                Text(footnote)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(isSelected ? AppColor.colaOrange.opacity(0.82) : AppColor.colaDarkText.opacity(0.42))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? AppColor.colaOrange.opacity(0.10) : AppColor.colaDarkText.opacity(0.03))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? AppColor.colaOrange.opacity(0.24) : AppColor.panelStroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadProjects() {
        let projectModels = (try? nodeStore.fetchAllProjects()) ?? []
        let allNodes = (try? nodeStore.fetchAllNodes()) ?? []
        let groupedNodes = Dictionary(grouping: allNodes) { $0.projectId }

        projects = projectModels.map { project in
            let projectNodes = groupedNodes[project.id] ?? []
            return ProjectListSummary(
                project: project,
                nodeCount: projectNodes.count,
                lastUpdatedAt: projectNodes.map(\.updatedAt).max()
            )
        }
        .sorted { lhs, rhs in
            let lhsDate = lhs.lastUpdatedAt ?? lhs.project.createdAt
            let rhsDate = rhs.lastUpdatedAt ?? rhs.project.createdAt
            return lhsDate > rhsDate
        }

        if let selectedProjectId,
           !projects.contains(where: { $0.project.id == selectedProjectId }) {
            self.selectedProjectId = nil
        }
    }

    private func createProject() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        let project = Project(
            title: title,
            goal: newGoal.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: newEmoji.isEmpty ? "📁" : newEmoji
        )
        try? nodeStore.insertProject(project)
        newTitle = ""
        newEmoji = "📁"
        newGoal = ""
        showCreate = false
        selectedProjectId = project.id
        loadProjects()
        onProjectSelected?()
    }

    private func summaryFootnote(_ summary: ProjectListSummary) -> String {
        let activity = summary.lastUpdatedAt.map {
            Self.relativeFormatter.localizedString(for: $0, relativeTo: Date())
        } ?? "no activity"
        return "\(summary.nodeCount) nodes • \(activity)"
    }
}
