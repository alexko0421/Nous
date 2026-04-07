import SwiftUI
import SpriteKit

struct GalaxyView: View {
    @Bindable var vm: GalaxyViewModel
    var onNodeSelected: ((NousNode) -> Void)?

    var body: some View {
        ZStack {
            if vm.isLoading {
                loadingView
            } else if vm.nodes.isEmpty {
                emptyStateView
            } else {
                SpriteView(scene: makeScene(), options: [.allowsTransparency])
                    .ignoresSafeArea()
            }
        }
        .background(AppColor.galaxyBackground)
        .clipShape(RoundedRectangle(cornerRadius: 36))
        .onAppear {
            vm.load()
        }
    }

    // MARK: - Scene Factory

    private func makeScene() -> GalaxyScene {
        let scene = GalaxyScene()
        scene.scaleMode = .resizeFill
        scene.graphNodes = vm.nodes
        scene.graphEdges = vm.edges
        scene.positions = vm.positions
        scene.onNodeTapped = { [weak vm] id in
            guard let vm else { return }
            vm.selectedNodeId = id
            if let node = vm.nodeForId(id) {
                onNodeSelected?(node)
            }
        }
        return scene
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Text("🌌")
                .font(.system(size: 64))
            Text("Your Galaxy is empty")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("Start a conversation or create a note\nto see your knowledge graph.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text("Mapping your galaxy…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
