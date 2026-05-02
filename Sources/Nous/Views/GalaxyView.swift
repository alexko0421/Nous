import SpriteKit
import SwiftUI

struct GalaxyView: View {
    @Bindable var vm: GalaxyViewModel
    @Binding var selectedLens: GalaxyLensFilter
    var onNodeSelected: ((NousNode) -> Void)?

    @State private var scene = GalaxyScene()
    @State private var selectedEdgeId: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { _ in
            mapPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GalaxyPalette.windowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        }
        .onAppear {
            vm.load()
        }
    }

    private var mapPanel: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(GalaxyPalette.mapBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .stroke(GalaxyPalette.stroke, lineWidth: 1)
                )

            if vm.isLoading {
                loadingView
            } else if vm.nodes.isEmpty {
                emptyView
            } else {
                GalaxySceneContainer(
                    scene: scene,
                    graphNodes: vm.nodes,
                    graphEdges: vm.edges,
                    highlightedEdgeIds: highlightedEdgeIds,
                    positions: vm.positions,
                    selectedNodeId: vm.selectedNodeId,
                    selectedEdgeId: selectedEdgeId,
                    onNodeTapped: handleNodeTap,
                    onEdgeTapped: handleEdgeTap,
                    onCanvasTapped: handleCanvasTap,
                    onNodeMoved: { id, position in
                        vm.updateNodePosition(id, x: position.x, y: position.y)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            }

            lensPicker
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 24)

            journalOverlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .shadow(color: .black.opacity(0.24), radius: 28, x: 0, y: 18)
    }

    @ViewBuilder
    private var journalOverlay: some View {
        if let selectedNode = journalSelectedNode {
            let summary = GalaxyJournalSummary(
                selectedNode: selectedNode,
                connectedNode: journalConnectedNode,
                edge: journalEdge
            )

            HStack {
                Spacer(minLength: 0)

                journalCard(summary: summary, selectedNode: selectedNode)
            }
            .padding(.vertical, GalaxyJournalLayout.verticalPadding)
            .padding(.trailing, GalaxyJournalLayout.trailingPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(smoothAnimation, value: vm.selectedNodeId)
                .animation(smoothAnimation, value: selectedEdgeId)
                .animation(smoothAnimation, value: selectedLens)
        }
    }

    private func journalCard(summary: GalaxyJournalSummary, selectedNode: NousNode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(summary.badge)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GalaxyPalette.darkInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(GalaxyPalette.accent))

                Text(summary.scoreText)
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(GalaxyPalette.secondaryText)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(summary.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(GalaxyPalette.primaryText)
                    .lineLimit(3)

                Text(summary.body)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(GalaxyPalette.secondaryText)
                    .lineSpacing(2)
                    .lineLimit(7)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(summary.evidence)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(GalaxyPalette.tertiaryText)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            HStack(spacing: 8) {
                Button {
                    onNodeSelected?(selectedNode)
                } label: {
                    Label("打开", systemImage: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GalaxyPalette.darkInk)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Capsule().fill(GalaxyPalette.accent))

                Button {
                } label: {
                    Label("固定", systemImage: "pin")
                        .font(.system(size: 13, weight: .bold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GalaxyPalette.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Capsule().fill(GalaxyPalette.panelLift))
            }
        }
        .padding(18)
        .frame(width: GalaxyJournalLayout.width)
        .frame(maxHeight: GalaxyJournalLayout.maxHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(GalaxyPalette.panel.opacity(0.78))
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(GalaxyPalette.stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 28, x: 0, y: 18)
    }

    private var lensPicker: some View {
        HStack(spacing: 2) {
            ForEach(GalaxyLensFilter.allCases) { lens in
                let isSelected = lens == selectedLens

                Button {
                    withAnimation(smoothAnimation) {
                        selectedLens = lens
                        if let selectedEdge, !lens.matches(selectedEdge) {
                            selectedEdgeId = nil
                        }
                    }
                } label: {
                    Text(lens.shortTitle)
                        .font(.system(size: 13, weight: isSelected ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? GalaxyPalette.darkInk : GalaxyPalette.secondaryText)
                        .frame(width: 52, height: 34)
                        .background(
                            Capsule()
                                .fill(isSelected ? GalaxyPalette.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(lens.title)
            }
        }
        .padding(5)
        .background(
            Capsule()
                .fill(GalaxyPalette.panel.opacity(0.66))
        )
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(GalaxyPalette.stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 12)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Drawing the quiet map")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GalaxyPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Text("No constellation yet")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(GalaxyPalette.primaryText)

            Text("Create conversations or notes first. Nous will connect the real pieces when they exist.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GalaxyPalette.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var highlightedEdgeIds: Set<UUID> {
        Set(vm.edges.filter(selectedLens.matches).map(\.id))
    }

    private var selectedEdgesForLens: [NodeEdge] {
        vm.selectedNodeEdges.filter(selectedLens.matches)
    }

    private var selectedEdge: NodeEdge? {
        guard let selectedEdgeId else { return nil }
        return vm.edges.first { $0.id == selectedEdgeId }
    }

    private var journalSelectedNode: NousNode? {
        if let selectedNode = vm.selectedNode {
            return selectedNode
        }

        guard let selectedEdge else { return nil }
        return vm.nodeForId(selectedEdge.sourceId) ?? vm.nodeForId(selectedEdge.targetId)
    }

    private var journalEdge: NodeEdge? {
        selectedEdge ?? selectedEdgesForLens.first ?? vm.selectedNodeEdges.first
    }

    private var journalConnectedNode: NousNode? {
        guard
            let edge = journalEdge,
            let selectedNode = journalSelectedNode
        else { return nil }

        let connectedId = edge.sourceId == selectedNode.id ? edge.targetId : edge.sourceId
        return vm.nodeForId(connectedId)
    }

    private var smoothAnimation: Animation? {
        reduceMotion ? nil : AppMotion.sidebarPanelSpring.animation
    }

    private func handleNodeTap(_ id: UUID) {
        withAnimation(smoothAnimation) {
            selectedEdgeId = nil
            vm.selectedNodeId = vm.selectedNodeId == id ? nil : id
        }
    }

    private func handleEdgeTap(_ id: UUID) {
        guard let edge = vm.edges.first(where: { $0.id == id }) else { return }

        withAnimation(smoothAnimation) {
            selectedEdgeId = edge.id
            selectedLens = GalaxyLensFilter.preferredLens(for: edge)

            if vm.selectedNodeId != edge.sourceId && vm.selectedNodeId != edge.targetId {
                vm.selectedNodeId = edge.sourceId
            }
        }
    }

    private func handleCanvasTap() {
        withAnimation(smoothAnimation) {
            selectedEdgeId = nil
            vm.selectedNodeId = nil
        }
    }
}

private enum GalaxyPalette {
    static let windowBackground = Color(red: 18/255, green: 17/255, blue: 16/255)
    static let mapBackground = Color(red: 29/255, green: 27/255, blue: 24/255)
    static let panel = Color(red: 38/255, green: 36/255, blue: 32/255)
    static let panelLift = Color.white.opacity(0.07)
    static let panelSelected = Color(red: 92/255, green: 73/255, blue: 51/255).opacity(0.34)
    static let accent = Color(red: 222/255, green: 179/255, blue: 120/255)
    static let primaryText = Color(red: 245/255, green: 238/255, blue: 224/255)
    static let secondaryText = Color(red: 220/255, green: 211/255, blue: 194/255).opacity(0.72)
    static let tertiaryText = Color(red: 220/255, green: 211/255, blue: 194/255).opacity(0.48)
    static let stroke = Color.white.opacity(0.12)
    static let strokeSoft = Color.white.opacity(0.07)
    static let darkInk = Color(red: 28/255, green: 24/255, blue: 20/255)
}
