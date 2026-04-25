import SwiftUI
import SpriteKit

struct GalaxyView: View {
    @Bindable var vm: GalaxyViewModel
    var onNodeSelected: ((NousNode) -> Void)?
    @State private var scene = GalaxyScene()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ZStack {
                canvasBackground

                if vm.isLoading {
                    loadingView
                } else if vm.nodes.isEmpty {
                    emptyStateView
                } else {
                    GalaxySceneContainer(
                        scene: scene,
                        graphNodes: vm.nodes,
                        graphEdges: vm.edges,
                        positions: vm.positions,
                        selectedNodeId: vm.selectedNodeId,
                        onNodeTapped: handleNodeTap,
                        onNodeMoved: handleNodeMove
                    )
                    .ignoresSafeArea()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppColor.panelStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(AppColor.colaBeige)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onAppear {
            vm.load()
        }
    }

    private func handleNodeTap(_ id: UUID) {
        vm.selectedNodeId = id
        if let node = vm.nodeForId(id) {
            onNodeSelected?(node)
        }
    }

    private func handleNodeMove(_ id: UUID, _ position: GraphPosition) {
        vm.updateNodePosition(id, x: position.x, y: position.y)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Galaxy")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText)

                Text("Chats and notes should feel like one calm map, not a separate mode.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)
            }

            HStack(spacing: 8) {
                legendChip(label: "Notes", tint: AppColor.colaDarkText.opacity(0.78))
                legendChip(label: "Chats", tint: AppColor.colaOrange.opacity(0.82))

                Spacer()

                hintChip(
                    icon: "hand.draw",
                    text: "Drag nodes. Scroll to zoom."
                )
            }
        }
    }

    // MARK: - Background

    private var canvasBackground: some View {
        ZStack {
            AppColor.surfaceSecondary.opacity(0.72)

            Circle()
                .fill(AppColor.colaOrange.opacity(0.05))
                .frame(width: 280, height: 280)
                .blur(radius: 120)
                .offset(x: -260, y: -170)

            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 240, height: 240)
                .blur(radius: 140)
                .offset(x: 220, y: 160)
        }
        .ignoresSafeArea()
    }

    private func legendChip(label: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppColor.colaDarkText.opacity(0.72))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColor.surfacePrimary)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(AppColor.panelStroke, lineWidth: 1)
        }
    }

    private func hintChip(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColor.secondaryText)

            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppColor.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColor.surfacePrimary)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(AppColor.panelStroke, lineWidth: 1)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(AppColor.secondaryText)

            Text("Galaxy is empty")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColor.colaDarkText)

            Text("Start a conversation or create a note\nto reveal the first connections.")
                .font(.subheadline)
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(AppColor.colaOrange)

            Text("Mapping your connections…")
                .font(.subheadline)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
