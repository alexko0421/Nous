import Foundation
import SpriteKit
import SwiftUI

struct GalaxyView: View {
    @Bindable var vm: GalaxyViewModel
    var onOpenNode: ((NousNode) -> Void)?
    @State private var scene = GalaxyScene()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        ZStack {
            galaxyBackground
            sceneLayer
        }
        .overlay(alignment: .topLeading) {
            headerCluster
        }
        .overlay(alignment: .bottom) {
            if let node = vm.selectedNode {
                selectedNodeSheet(node)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(GalaxyPaperPalette.paperStroke.opacity(0.42), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.36), value: vm.selectedNodeId)
        .onAppear {
            vm.load()
        }
    }

    private var sceneLayer: some View {
        ZStack {
            if vm.isLoading {
                loadingView
            } else if vm.nodes.isEmpty {
                emptyStateView
            } else {
                GalaxySceneContainer(
                    scene: scene,
                    graphNodes: vm.nodes,
                    graphEdges: vm.edges,
                    constellations: vm.constellations,
                    dominantConstellationId: vm.dominantConstellationId,
                    revealedConstellationIds: vm.revealedConstellationIds,
                    toggleAllVisible: vm.showAllConstellations,
                    positions: vm.positions,
                    selectedNodeId: vm.selectedNodeId,
                    onNodeTapped: handleNodeTap,
                    onNodeMoved: handleNodeMove,
                    onSimulationSettled: { settled in
                        Task { @MainActor in
                            vm.handleSimulationSettled(positions: settled)
                        }
                    }
                )
                .ignoresSafeArea()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var galaxyBackground: some View {
        Color.black
            .ignoresSafeArea()
    }

    private var headerCluster: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("KNOWLEDGE GALAXY")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(GalaxyPaperPalette.secondaryText)

                connectionMark
            }

            Text(currentScopeTitle)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(GalaxyPaperPalette.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .padding(22)
    }

    private var quietMetrics: some View {
        HStack(spacing: 8) {
            metricPill(value: "\(vm.nodes.count)", label: "nodes")
            metricPill(value: "\(vm.edges.count)", label: "links")
            metricPill(value: "\(vm.visibleConversationCount)", label: "chats")
            metricPill(value: "\(vm.visibleNoteCount)", label: "notes")
        }
        .padding(22)
    }

    private var connectionMark: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(GalaxyPaperPalette.camel)
                .frame(width: 5, height: 5)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            GalaxyPaperPalette.camel.opacity(0.78),
                            GalaxyPaperPalette.sage.opacity(0.55)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 24, height: 1)

            Circle()
                .fill(GalaxyPaperPalette.sage.opacity(0.78))
                .frame(width: 5, height: 5)
        }
        .opacity(0.88)
    }

    private func selectedNodeSheet(_ node: NousNode) -> some View {
        let project = vm.projectForId(node.projectId)
        let connections = vm.selectedConnections

        return VStack(alignment: .leading, spacing: 15) {
            HStack {
                Spacer()
                Capsule()
                    .fill(GalaxyPaperPalette.secondaryText.opacity(0.26))
                    .frame(width: 42, height: 4)
                Spacer()
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        typeTag(node.type)

                        if let project {
                            projectTag(project)
                        }

                        Text(relativeDateString(node.updatedAt))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(GalaxyPaperPalette.secondaryText)
                            .lineLimit(1)
                    }

                    Text(node.title.isEmpty ? "Untitled" : node.title)
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .foregroundStyle(GalaxyPaperPalette.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(nodeExcerpt(node))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(GalaxyPaperPalette.bodyText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                VStack(alignment: .trailing, spacing: 10) {
                    Button {
                        vm.selectNode(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(GalaxyPaperPalette.secondaryText)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .background(Color.black.opacity(0.18), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(GalaxyPaperPalette.paperStroke.opacity(0.60), lineWidth: 1)
                    }

                    Button {
                        openNode(node)
                    } label: {
                        Label(
                            node.type == .conversation ? "Open Chat" : "Open Note",
                            systemImage: node.type == .conversation ? "bubble.left.and.text.bubble.right.fill" : "doc.text.fill"
                        )
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(GalaxyPaperPalette.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(GalaxyPaperPalette.primaryText, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            let motifs = motifsForSelectedNode()
            if !motifs.isEmpty {
                motifStrip(motifs)
                Divider()
                    .overlay(GalaxyPaperPalette.paperStroke)
            }

            Divider()
                .overlay(GalaxyPaperPalette.paperStroke)

            connectionStrip(connections)
        }
        .padding(.top, 10)
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: 760)
        .background {
            ZStack {
                paperSurface(cornerRadius: 32, opacity: 0.88)
                    .shadow(color: Color.black.opacity(0.30), radius: 24, x: 0, y: -8)
                Canvas { ctx, size in
                    let pixelCount = 600
                    let seed: UInt64 = 0xC0FFEE
                    var rng = SplitMix64(state: seed)
                    for _ in 0..<pixelCount {
                        let x = CGFloat(rng.next() % 10_000) / 10_000 * size.width
                        let y = CGFloat(rng.next() % 10_000) / 10_000 * size.height
                        let rect = CGRect(x: x, y: y, width: 1, height: 1)
                        ctx.fill(Path(rect), with: .color(.white.opacity(0.04)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .blendMode(.overlay)
                .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private func motifsForSelectedNode() -> [Constellation] {
        guard let id = vm.selectedNodeId else { return [] }
        return vm.visibleConstellations
            .filter { $0.visibleMembers.contains(id) }
            .map { $0.constellation }
    }

    private func motifStrip(_ motifs: [Constellation]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MOTIFS")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(GalaxyPaperPalette.secondaryText)
                Spacer()
                Text("\(motifs.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(GalaxyPaperPalette.olive)
            }
            ForEach(motifs) { motif in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color(red: 155 / 255, green: 142 / 255, blue: 196 / 255))
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    Text(motif.label)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(GalaxyPaperPalette.bodyText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func connectionStrip(_ connections: [GalaxyConnection]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CONNECTED")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(GalaxyPaperPalette.secondaryText)

                Spacer()

                Text("\(connections.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(GalaxyPaperPalette.olive)
            }

            if connections.isEmpty {
                Text("No direct links yet.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(GalaxyPaperPalette.secondaryText)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(connections.prefix(8)) { connection in
                            connectionChip(connection)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func connectionChip(_ connection: GalaxyConnection) -> some View {
        Button {
            vm.selectNode(connection.node.id)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(edgeTint(connection.edge.type))
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.node.title.isEmpty ? "Untitled" : connection.node.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(GalaxyPaperPalette.primaryText)
                        .lineLimit(1)

                    Text(connectionLabel(connection))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(GalaxyPaperPalette.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 46)
            .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(edgeTint(connection.edge.type).opacity(0.28), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func metricPill(value: String, label: String) -> some View {
        HStack(spacing: 7) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(GalaxyPaperPalette.primaryText)

            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(GalaxyPaperPalette.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background {
            paperSurface(cornerRadius: 15, opacity: 0.58)
        }
    }

    private func typeTag(_ type: NodeType) -> some View {
        Label(
            type == .conversation ? "CHAT" : "NOTE",
            systemImage: type == .conversation ? "bubble.left.and.text.bubble.right.fill" : "doc.text.fill"
        )
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .tracking(0.6)
        .foregroundStyle(type == .conversation ? GalaxyPaperPalette.ink : GalaxyPaperPalette.primaryText)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(type == .conversation ? GalaxyPaperPalette.sand : GalaxyPaperPalette.slate, in: Capsule())
    }

    private func projectTag(_ project: Project) -> some View {
        Text("\(project.emoji) \(project.title)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(GalaxyPaperPalette.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.black.opacity(0.16), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(GalaxyPaperPalette.paperStroke.opacity(0.58), lineWidth: 1)
            }
    }

    private func paperSurface(cornerRadius: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(GalaxyPaperPalette.panel.opacity(opacity))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(GalaxyPaperPalette.paperStroke.opacity(0.78), lineWidth: 1)
            }
    }

    private func edgeTint(_ type: EdgeType) -> Color {
        switch type {
        case .manual:
            return GalaxyPaperPalette.camel
        case .semantic:
            return GalaxyPaperPalette.sage
        }
    }

    private func connectionLabel(_ connection: GalaxyConnection) -> String {
        switch connection.edge.type {
        case .manual:
            return "manual"
        case .semantic:
            return "\(Int(connection.edge.strength * 100)) semantic"
        }
    }

    private func handleNodeTap(_ id: UUID) {
        vm.selectNode(id)
    }

    private func handleNodeMove(_ id: UUID, _ position: GraphPosition) {
        vm.updateNodePosition(id, x: position.x, y: position.y)
    }

    private func openNode(_ node: NousNode) {
        onOpenNode?(node)
    }

    private func nodeExcerpt(_ node: NousNode) -> String {
        let trimmed = node.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return node.type == .conversation
                ? "This conversation has no visible summary yet."
                : "This note has no body text yet."
        }

        return String(trimmed.prefix(220))
    }

    private func relativeDateString(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private var currentScopeTitle: String {
        if let project = vm.selectedProject {
            return project.goal.isEmpty ? "\(project.emoji) \(project.title)" : project.goal
        }

        return "Whole Galaxy"
    }

    private var emptyStateView: some View {
        VStack(spacing: 15) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.16))
                    .frame(width: 64, height: 64)
                    .overlay {
                        Circle()
                            .stroke(GalaxyPaperPalette.paperStroke.opacity(0.55), lineWidth: 1)
                    }

                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(GalaxyPaperPalette.olive)
            }

            Text("Create your knowledge galaxy")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(GalaxyPaperPalette.primaryText)

            Text("Conversations and notes will form a quiet map here.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(GalaxyPaperPalette.secondaryText)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(GalaxyPaperPalette.olive)

            Text("Mapping connections")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(GalaxyPaperPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Deterministic pseudo-random for stable bottom-sheet grain noise.
private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}

private enum GalaxyPaperPalette {
    static let panel = Color(red: 28/255, green: 28/255, blue: 28/255)
    static let paperStroke = Color(red: 231/255, green: 212/255, blue: 179/255).opacity(0.22)

    static let ink = Color(red: 28/255, green: 28/255, blue: 28/255)
    static let primaryText = Color(red: 231/255, green: 212/255, blue: 179/255)
    static let bodyText = Color(red: 209/255, green: 177/255, blue: 153/255)
    static let secondaryText = Color(red: 184/255, green: 154/255, blue: 122/255)

    static let camel = Color(red: 164/255, green: 130/255, blue: 96/255)
    static let sand = Color(red: 215/255, green: 185/255, blue: 150/255)
    static let brown = Color(red: 92/255, green: 74/255, blue: 50/255)
    static let sage = Color(red: 129/255, green: 154/255, blue: 132/255)
    static let olive = Color(red: 103/255, green: 119/255, blue: 87/255)
    static let slate = Color(red: 104/255, green: 111/255, blue: 126/255)
    static let stoneBlue = Color(red: 112/255, green: 145/255, blue: 161/255)

}
