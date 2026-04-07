import SwiftUI

struct ProjectListView: View {
    let nodeStore: NodeStore
    @Binding var selectedProjectId: UUID?

    @State private var projects: [Project] = []
    @State private var showCreate: Bool = false
    @State private var newTitle: String = ""
    @State private var newEmoji: String = "📁"
    @State private var newGoal: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Projects")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.6))
                Spacer()
                Button(action: { showCreate.toggle() }) {
                    Image(systemName: showCreate ? "xmark" : "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppColor.colaDarkText.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            // Create form
            if showCreate {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Emoji", text: $newEmoji)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .frame(width: 40)

                    TextField("Name", text: $newTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)

                    TextField("Goal", text: $newGoal)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText.opacity(0.7))

                    Button(action: createProject) {
                        Text("Create")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(AppColor.colaOrange)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            // "All" option
            Button(action: { selectedProjectId = nil }) {
                HStack(spacing: 10) {
                    Text("🗂️")
                        .font(.system(size: 14))
                    Text("All")
                        .font(.system(size: 12, weight: selectedProjectId == nil ? .semibold : .medium, design: .rounded))
                        .foregroundColor(selectedProjectId == nil ? AppColor.colaOrange : AppColor.colaDarkText.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            // Project list
            ForEach(projects) { project in
                Button(action: { selectedProjectId = project.id }) {
                    HStack(spacing: 10) {
                        Text(project.emoji)
                            .font(.system(size: 14))
                        Text(project.title)
                            .font(.system(size: 12, weight: selectedProjectId == project.id ? .semibold : .medium, design: .rounded))
                            .foregroundColor(selectedProjectId == project.id ? AppColor.colaOrange : AppColor.colaDarkText.opacity(0.7))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { loadProjects() }
    }

    private func loadProjects() {
        projects = (try? nodeStore.fetchAllProjects()) ?? []
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
        loadProjects()
    }
}
