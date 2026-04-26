import SwiftUI
import AppKit

struct NativeGlassPanel<Content: View>: NSViewRepresentable {
    let cornerRadius: CGFloat
    let tintColor: NSColor?
    let content: Content

    init(
        cornerRadius: CGFloat,
        tintColor: NSColor? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
        self.content = content()
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glassView = NSGlassEffectView()
        configure(glassView)
        glassView.contentView = makeContentContainer()
        return glassView
    }

    func updateNSView(_ glassView: NSGlassEffectView, context: Context) {
        configure(glassView)

        if let hostingView = glassView.contentView?.subviews.first as? NSHostingView<Content> {
            hostingView.rootView = content
        } else {
            glassView.contentView = makeContentContainer()
        }
    }

    private func configure(_ glassView: NSGlassEffectView) {
        glassView.style = .regular
        glassView.cornerRadius = cornerRadius
        glassView.tintColor = tintColor
    }

    private func makeContentContainer() -> NSView {
        let container = NSView()
        let hostingView = NSHostingView(rootView: content)

        container.translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }
}

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
        .frame(width: 18, height: 18)
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
        .frame(width: 18, height: 18)
    }
}

struct NavIconButton<Icon: View>: View {
    let icon: Icon
    let label: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                NativeGlassPanel(
                    cornerRadius: 18,
                    tintColor: isActive
                        ? NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.22)
                        : AppColor.glassTint
                ) {
                    EmptyView()
                }
                .frame(width: 36, height: 36)
                .overlay(
                    Circle()
                        .stroke(isActive ? AppColor.colaOrange.opacity(0.35) : AppColor.panelStroke, lineWidth: 1)
                )
                .overlay(icon)
                
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(isActive ? AppColor.colaOrange : AppColor.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.07 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct SidebarDivider: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 4))
            path.addQuadCurve(
                to: CGPoint(x: 108, y: 4),
                control: CGPoint(x: 54, y: 0.8)
            )
        }
        .stroke(
            AppColor.panelStroke.opacity(0.95),
            style: StrokeStyle(lineWidth: 1, lineCap: .round)
        )
        .frame(width: 108, height: 6)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct MacOSTrafficLights: View {
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 6) { // 6pt spacing + 14pt size = 20pt center-to-center, matching macOS Big Sur+
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
            .frame(width: 14, height: 14) // Standard size for Big Sur+
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
    let selectedNodeId: UUID?
    var onNodeSelected: ((NousNode) -> Void)?
    var onNewChat: (() -> Void)?

    @AppStorage("nous.username") private var username = "ALEX"

    @State private var favorites: [NousNode] = []
    @State private var recents: [NousNode] = []
    @State private var showProjectList = false

    var body: some View {
        NativeGlassPanel(
            cornerRadius: 32,
            tintColor: AppColor.glassTint
        ) {
            VStack(alignment: .leading, spacing: 0) {
                MacOSTrafficLights()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 26)
                    .padding(.bottom, 24)

                HStack(spacing: 12) {
                    NavIconButton(
                        icon: GalaxyIcon(color: selectedTab == .galaxy ? AppColor.colaOrange : AppColor.colaDarkText.opacity(0.8)),
                        label: "Galaxy",
                        isActive: selectedTab == .galaxy,
                        action: {
                            showProjectList = false
                            selectedTab = .galaxy
                        }
                    )
                    NavIconButton(
                        icon: ProjectIcon(color: showProjectList || selectedProjectId != nil ? AppColor.colaOrange : AppColor.colaDarkText.opacity(0.8)),
                        label: "Project",
                        isActive: showProjectList || selectedProjectId != nil,
                        action: {
                            let nextValue = !showProjectList
                            showProjectList = nextValue
                            if nextValue {
                                selectedTab = .galaxy
                            }
                        }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 14)

                SidebarDivider()
                    .padding(.bottom, 10)

                // New Chat button
                Button(action: {
                    onNewChat?()
                    selectedTab = .chat
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 12, weight: .medium))
                        Text("New Chat")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(AppColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .padding(.leading, 20)
                .padding(.trailing, 8)
                .padding(.bottom, 10)

                SidebarDivider()
                    .padding(.bottom, 14)

                if showProjectList {
                    ProjectListView(
                        nodeStore: nodeStore,
                        selectedProjectId: $selectedProjectId,
                        onProjectSelected: {
                            showProjectList = false
                            selectedTab = .galaxy
                        }
                    )
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 28) {
                            if !favorites.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 4) {
                                        Text("Favorites")
                                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 7, weight: .bold))
                                            .opacity(0.5)
                                    }
                                    .foregroundColor(AppColor.colaDarkText.opacity(0.6))

                                    ForEach(favorites) { node in
                                        SidebarNodeItem(
                                            node: node,
                                            isSelected: selectedNodeId == node.id,
                                            action: { onNodeSelected?(node) }
                                        )
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Recents")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundColor(AppColor.colaDarkText.opacity(0.6))

                                ForEach(recents) { node in
                                    SidebarNodeItem(
                                        node: node,
                                        isSelected: selectedNodeId == node.id,
                                        action: { onNodeSelected?(node) }
                                    )
                                    .contextMenu {
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

                SidebarDivider()
                    .padding(.bottom, 12)

                HStack(spacing: 12) {
                    NativeGlassPanel(
                        cornerRadius: 15,
                        tintColor: selectedTab == .settings
                            ? NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.88)
                            : NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.18)
                    ) { EmptyView() }
                    .frame(width: 30, height: 30)
                    .overlay(
                        Text(username.first.map(String.init)?.uppercased() ?? "A")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(selectedTab == .settings ? .white : AppColor.colaOrange)
                    )

                    Text(username.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedTab = .settings
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(selectedTab == .settings ? AppColor.colaOrange.opacity(0.08) : Color.clear)
                .cornerRadius(12)
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 172)
        .onAppear { loadData() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .nousNodesDidChange,
                object: nodeStore
            )
        ) { _ in
            loadData()
        }
    }

    private func loadData() {
        favorites = (try? nodeStore.fetchFavorites()) ?? []
        recents = (try? nodeStore.fetchRecents(limit: 20)) ?? []
    }
}

// MARK: - SidebarNodeItem

struct SidebarNodeItem: View {
    let node: NousNode
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(node.title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(isSelected ? AppColor.colaOrange : AppColor.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    ZStack {
                        if isSelected {
                            NativeGlassPanel(
                                cornerRadius: 12,
                                tintColor: NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.15)
                            ) { EmptyView() }
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AppColor.colaOrange.opacity(0.3), lineWidth: 0.5)
                            )
                        } else if isHovered {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(AppColor.colaDarkText.opacity(0.04))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
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
