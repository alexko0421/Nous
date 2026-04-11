import Combine
import SwiftUI

// Helper for window controls
func getAppWindow() -> NSWindow? {
    NSApplication.shared.windows.first(where: { $0.titleVisibility == .hidden }) 
        ?? NSApplication.shared.keyWindow 
        ?? NSApplication.shared.windows.first
}

// Galaxy Icon - clean port of the React reference
struct GalaxyIcon: View {
    let color: Color
    var body: some View {
        ZStack {
            // Two tiny stardust dots
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 2, height: 2)
                .offset(x: -7, y: -7)
            Circle()
                .fill(color.opacity(0.25))
                .frame(width: 1.5, height: 1.5)
                .offset(x: 8, y: 5)

            // Central planet body (stroked circle)
            Circle()
                .stroke(color, lineWidth: 1.5)
                .frame(width: 10, height: 10)

            // Ring (stroked ellipse, rotated -20°)
            Ellipse()
                .stroke(color.opacity(0.85), lineWidth: 1.5)
                .frame(width: 20, height: 6)
                .rotationEffect(.degrees(-20))
        }
        .frame(width: 22, height: 22)
    }
}

// Project Icon - clean 'stacked tray' design
struct ProjectIcon: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let r: CGFloat = 3.5
            let lw: CGFloat = 1.5

            // Outer rounded rect
            let outerRect = CGRect(x: 2, y: 4, width: w - 4, height: h - 6)
            ctx.stroke(
                Path(roundedRect: outerRect, cornerRadius: r),
                with: .color(color),
                lineWidth: lw
            )

            // Inner shelf — a strong horizontal line 1/3 down from top
            let shelfY = outerRect.minY + outerRect.height * 0.38
            var shelf = Path()
            shelf.move(to: CGPoint(x: outerRect.minX, y: shelfY))
            shelf.addLine(to: CGPoint(x: outerRect.maxX, y: shelfY))
            ctx.stroke(shelf, with: .color(color), lineWidth: lw)
        }
        .frame(width: 22, height: 22)
    }
}

struct NavIconButton<Icon: View>: View {
    let icon: Icon
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(AppColor.colaDarkText.opacity(0.04))
                    .frame(width: 44, height: 44)
                    .overlay(icon)
                
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
    }
}

struct MacOSTrafficLights: View {
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Close
            trafficLightButton(
                color: Color(red: 255/255, green: 95/255, blue: 86/255),
                icon: "xmark",
                iconSize: 7,
                action: { 
                    getAppWindow()?.close() 
                    // Safely exit app if it's the only window
                    NSApplication.shared.terminate(nil)
                }
            )
            
            // Minimize
            trafficLightButton(
                color: Color(red: 255/255, green: 189/255, blue: 46/255),
                icon: "minus",
                iconSize: 8,
                action: { getAppWindow()?.miniaturize(nil) }
            )
            
            // Zoom/Fullscreen
            trafficLightButton(
                color: Color(red: 39/255, green: 201/255, blue: 63/255),
                icon: "arrow.up.left.and.arrow.down.right",
                iconSize: 6,
                action: { getAppWindow()?.toggleFullScreen(nil) }
            )
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    @ViewBuilder
    func trafficLightButton(color: Color, icon: String, iconSize: CGFloat, action: @escaping () -> Void) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundColor(.black.opacity(0.5))
                    .opacity(isHovered ? 1 : 0)
            )
            .onTapGesture {
                action()
            }
    }
}

struct LeftSidebar: View {
    let nodeStore: NodeStore
    @Binding var selectedTab: MainTab
    @Binding var selectedProjectId: UUID?
    var selectedNodeId: UUID?
    var onNodeSelected: ((NousNode) -> Void)?
    var onNewChat: (() -> Void)?

    @State private var favorites: [NousNode] = []
    @State private var recents: [NousNode] = []
    @State private var projects: [Project] = []
    @State private var showProjectList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacOSTrafficLights()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 24)
                .padding(.bottom, 30)

            HStack(spacing: 12) {
                NavIconButton(
                    icon: GalaxyIcon(color: AppColor.colaDarkText.opacity(0.8)),
                    label: "Galaxy",
                    action: { selectedTab = .galaxy }
                )
                NavIconButton(
                    icon: ProjectIcon(color: AppColor.colaDarkText.opacity(0.8)),
                    label: "Project",
                    action: { showProjectList.toggle() }
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 24)

            Rectangle()
                .fill(AppColor.colaDarkText.opacity(0.1))
                .frame(width: 80, height: 1)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 16)

            // New Chat button
            Button(action: {
                onNewChat?()
                selectedTab = .chat
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .medium))
                    Text("New Chat")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .foregroundColor(AppColor.colaOrange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(AppColor.colaOrange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            if showProjectList {
                ProjectListView(nodeStore: nodeStore, selectedProjectId: $selectedProjectId)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        if !favorites.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 4) {
                                    Text("Favorites")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .opacity(0.5)
                                }
                                .foregroundColor(AppColor.colaDarkText.opacity(0.6))

                                ForEach(favorites) { node in
                                    Button(action: { onNodeSelected?(node) }) {
                                        HStack(spacing: 10) {
                                            Text(node.type == .conversation ? "💬" : "📝")
                                                .font(.system(size: 16))
                                            Text(node.title)
                                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                                .foregroundColor(AppColor.colaDarkText.opacity(0.7))
                                                .lineLimit(1)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text("Recents")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText.opacity(0.6))

                            ForEach(recents) { node in
                                let isSelected = node.id == selectedNodeId
                                Button(action: { onNodeSelected?(node) }) {
                                    HStack(spacing: 6) {
                                        Text(Self.nodeEmoji(node))
                                            .font(.system(size: 11))
                                        Text(node.title)
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundColor(isSelected ? AppColor.colaOrange : AppColor.colaDarkText.opacity(0.7))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 6)
                                    .background(isSelected ? AppColor.colaOrange.opacity(0.08) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(isSelected ? AppColor.colaOrange.opacity(0.3) : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Menu("Add to Project") {
                                        ForEach(projects) { project in
                                            Button(action: {
                                                if var n = try? nodeStore.fetchNode(id: node.id) {
                                                    n.projectId = project.id
                                                    n.updatedAt = Date()
                                                    try? nodeStore.updateNode(n)
                                                    loadData()
                                                }
                                            }) {
                                                Label("\(project.emoji) \(project.title)", systemImage: node.projectId == project.id ? "checkmark" : "folder")
                                            }
                                        }
                                        if node.projectId != nil {
                                            Divider()
                                            Button("Remove from Project") {
                                                if var n = try? nodeStore.fetchNode(id: node.id) {
                                                    n.projectId = nil
                                                    n.updatedAt = Date()
                                                    try? nodeStore.updateNode(n)
                                                    loadData()
                                                }
                                            }
                                        }
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        try? nodeStore.deleteNode(id: node.id)
                                        loadData()
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.leading, 20)
                    .padding(.trailing, 8)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: { selectedTab = .settings }) {
                    Circle()
                        .fill(AppColor.colaOrange.opacity(0.15))
                        .frame(width: 30, height: 30)
                        .overlay(
                            Text("A")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(AppColor.colaOrange)
                        )
                }
                .buttonStyle(.plain)

                Text("ALEX")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)

                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            .padding(.bottom, 30)
        }
        .frame(width: 150)
        .background(Color.white.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .onAppear { loadData() }
        .onChange(of: selectedTab) { loadData() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            loadData()
        }
    }

    private static func nodeEmoji(_ node: NousNode) -> String {
        if let emoji = node.emoji { return emoji }
        if node.type == .note { return "📝" }
        return "💬"
    }

    private func loadData() {
        favorites = (try? nodeStore.fetchFavorites()) ?? []
        recents = (try? nodeStore.fetchRecents(limit: 20)) ?? []
        projects = (try? nodeStore.fetchAllProjects()) ?? []
    }
}

// 修改为横向布局的聊天记录项
struct ChatRecentItem: View {
    let emoji: String
    let title: String
    
    var body: some View {
        Button(action: {}) {
            HStack(spacing: 10) {
                Text(emoji)
                    .font(.system(size: 16))
                
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
