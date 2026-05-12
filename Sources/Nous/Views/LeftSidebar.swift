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

struct MatteGlassPanel<Content: View>: NSViewRepresentable {
    let cornerRadius: CGFloat
    let overlayColor: NSColor?
    let content: Content

    init(
        cornerRadius: CGFloat,
        overlayColor: NSColor? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.overlayColor = overlayColor
        self.content = content()
    }

    func makeNSView(context: Context) -> NSView {
        let rootView = NSView()
        let effectView = NSVisualEffectView()
        let tintView = NSView()
        let hostingView = NSHostingView(rootView: content)

        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = cornerRadius
        rootView.layer?.cornerCurve = .continuous
        rootView.layer?.masksToBounds = true

        [effectView, tintView, hostingView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview($0)
        }

        tintView.wantsLayer = true
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        configure(effectView, tintView: tintView)

        NSLayoutConstraint.activate(
            [effectView, tintView, hostingView].flatMap { child in
                [
                    child.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                    child.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                    child.topAnchor.constraint(equalTo: rootView.topAnchor),
                    child.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
                ]
            }
        )

        return rootView
    }

    func updateNSView(_ rootView: NSView, context: Context) {
        rootView.layer?.cornerRadius = cornerRadius

        guard rootView.subviews.count == 3,
              let effectView = rootView.subviews[0] as? NSVisualEffectView,
              let hostingView = rootView.subviews[2] as? NSHostingView<Content> else {
            return
        }

        configure(effectView, tintView: rootView.subviews[1])
        hostingView.rootView = content
    }

    private func configure(_ effectView: NSVisualEffectView, tintView: NSView) {
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.isEmphasized = false
        tintView.layer?.backgroundColor = overlayColor?.cgColor
    }
}

enum AppWindowLookup {
    static func mainWindow(in windows: [NSWindow], keyWindow: NSWindow?) -> NSWindow? {
        windows.first(where: { $0 is NousMainWindow })
            ?? windows.first(where: { $0.titleVisibility == .hidden && $0.canBecomeMain })
            ?? keyWindow
            ?? windows.first
    }
}

// Helper for window controls
func getAppWindow() -> NSWindow? {
    AppWindowLookup.mainWindow(
        in: NSApplication.shared.windows,
        keyWindow: NSApplication.shared.keyWindow
    )
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
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                NativeGlassPanel(cornerRadius: 18, tintColor: AppColor.controlGlassTint) {
                    EmptyView()
                }
                .frame(width: 36, height: 36)
                .overlay(
                    Circle()
                        .stroke(AppColor.sidebarGlassStroke.opacity(0.55), lineWidth: 1)
                )
                .overlay(icon)
                
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.sidebarMutedText)
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
            AppColor.sidebarGlassStroke.opacity(0.62),
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
    let conversationSessionStore: ConversationSessionStore
    @Binding var selectedTab: MainTab
    @Binding var selectedProjectId: UUID?
    let selectedNodeId: UUID?
    var onNodeSelected: ((NousNode) -> Void)?
    var onNewChat: (() -> Void)?

    @AppStorage("nous.username") private var username = "ALEX"

    @State private var favorites: [NousNode] = []
    @State private var recents: [NousNode] = []
    @State private var showProjectList = false
    @State private var renameTarget: NousNode?
    @State private var searchQuery: String = ""
    @State private var searchResults: [NousNode] = []

    var body: some View {
        NativeGlassPanel(
            cornerRadius: 32,
            tintColor: AppColor.sidebarGlassTint
        ) {
            VStack(alignment: .leading, spacing: 0) {
                MacOSTrafficLights()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 26)
                    .padding(.bottom, 28)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppColor.sidebarMutedText)
                    TextField("Search", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(AppColor.sidebarText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(AppColor.sidebarGlassStroke.opacity(0.48), lineWidth: 1)
                )
                .padding(.horizontal, 16)
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
                    .foregroundColor(AppColor.sidebarMutedText)
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

                if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Results")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(AppColor.sidebarMutedText)

                            if searchResults.isEmpty {
                                Text("No matches")
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundColor(AppColor.sidebarMutedText.opacity(0.72))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(searchResults) { node in
                                    let session: ConversationStreamingSession? = {
                                        guard node.type == .conversation else { return nil }
                                        return conversationSessionStore.streamingSession(for: node.id)
                                    }()
                                    SidebarNodeItem(
                                        node: node,
                                        isSelected: selectedNodeId == node.id,
                                        streamingSession: session,
                                        action: { onNodeSelected?(node) }
                                    )
                                }
                            }
                        }
                        .padding(.leading, 20)
                        .padding(.trailing, 8)
                    }
                } else if showProjectList {
                    ProjectListView(nodeStore: nodeStore, selectedProjectId: $selectedProjectId)
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
                                    .foregroundColor(AppColor.sidebarMutedText)

                                    ForEach(favorites) { node in
                                        SidebarNodeItem(
                                            node: node,
                                            isSelected: selectedNodeId == node.id,
                                            streamingSession: node.type == .conversation
                                                ? conversationSessionStore.streamingSession(for: node.id)
                                                : nil,
                                            action: { onNodeSelected?(node) }
                                        )
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Recents")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundColor(AppColor.sidebarMutedText)

                                ForEach(recents) { node in
                                    SidebarNodeItem(
                                        node: node,
                                        isSelected: selectedNodeId == node.id,
                                        streamingSession: node.type == .conversation
                                            ? conversationSessionStore.streamingSession(for: node.id)
                                            : nil,
                                        action: { onNodeSelected?(node) }
                                    )
                                    .contextMenu {
                                        Button {
                                            renameTarget = node
                                        } label: {
                                            Label("Rename", systemImage: "pencil")
                                        }
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
                        .foregroundColor(AppColor.sidebarText)

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
        .frame(width: GalaxySidebarLayout.width)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(AppColor.sidebarGlassStroke.opacity(0.22), lineWidth: 1)
        )
        .onAppear { loadData() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .nousNodesDidChange,
                object: nodeStore
            )
        ) { _ in
            loadData()
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                runSearch()
            }
        }
        .onChange(of: searchQuery) { _, _ in
            runSearch()
        }
        .sheet(item: $renameTarget) { node in
            RenameConversationSheet(node: node) { newTitle in
                var updated = node
                updated.title = newTitle
                updated.updatedAt = Date()
                try? nodeStore.updateNode(updated)
                loadData()
            }
        }
    }

    private func loadData() {
        favorites = (try? nodeStore.fetchFavorites()) ?? []
        recents = (try? nodeStore.fetchRecents(limit: 20)) ?? []
    }

    private func runSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }

        let titleHits = (try? nodeStore.lexicalIndex.searchTitles(query: trimmed, limit: 30)) ?? []
        let messageHits = (try? nodeStore.lexicalIndex.searchMessages(query: trimmed, limit: 30)) ?? []

        var seen = Set<UUID>()
        var hits: [NousNode] = []
        for hit in titleHits + messageHits {
            guard !seen.contains(hit.nodeId) else { continue }
            seen.insert(hit.nodeId)
            if let node = try? nodeStore.fetchNode(id: hit.nodeId), node.type == .conversation {
                hits.append(node)
            }
        }
        searchResults = hits
    }
}

// MARK: - SidebarNodeItem

struct SidebarNodeItem: View {
    let node: NousNode
    let isSelected: Bool
    let streamingSession: ConversationStreamingSession?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(node.title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(isSelected ? AppColor.colaOrange : AppColor.sidebarMutedText)
                    .lineLimit(1)

                if let streamingSession, streamingSession.hasUnseenCompletion {
                    Circle()
                        .fill(AppColor.colaOrange)
                        .frame(width: 5, height: 5)
                        .padding(.leading, 4)
                        .accessibilityLabel("New reply")
                }
            }
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
                                .fill(Color.white.opacity(0.045))
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

// MARK: - RenameConversationSheet

struct RenameConversationSheet: View {
    let node: NousNode
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(node: NousNode, onSave: @escaping (String) -> Void) {
        self.node = node
        self.onSave = onSave
        _text = State(initialValue: node.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename conversation")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)

            TextField("Title", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .rounded))
                .onSubmit { commit() }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        let value = trimmed
        guard !value.isEmpty, value != node.title else {
            dismiss()
            return
        }
        onSave(value)
        dismiss()
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
