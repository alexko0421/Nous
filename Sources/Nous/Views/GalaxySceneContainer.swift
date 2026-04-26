import AppKit
import SpriteKit
import SwiftUI

struct GalaxySceneContainer: NSViewRepresentable {
    let scene: GalaxyScene
    let graphNodes: [NousNode]
    let graphEdges: [NodeEdge]
    let constellations: [Constellation]
    let dominantConstellationId: UUID?
    let revealedConstellationIds: Set<UUID>
    let toggleAllVisible: Bool
    let positions: [UUID: GraphPosition]
    let selectedNodeId: UUID?
    let onNodeTapped: ((UUID) -> Void)?
    let onNodeMoved: ((UUID, GraphPosition) -> Void)?

    final class Coordinator {
        var lastConstellations: [Constellation] = []
        var lastDominantConstellationId: UUID? = nil
        var lastToggleAllVisible: Bool = false
        var lastRevealedConstellationIds: Set<UUID> = []
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractiveGalaxySKView {
        let view = InteractiveGalaxySKView()
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.shouldCullNonVisibleNodes = false
        view.preferredFramesPerSecond = 120
        view.presentScene(scene)
        configure(scene: scene, in: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: InteractiveGalaxySKView, context: Context) {
        if view.scene !== scene {
            view.presentScene(scene)
        }
        configure(scene: scene, in: view, coordinator: context.coordinator)
    }

    private func configure(scene: GalaxyScene, in view: SKView, coordinator: Coordinator) {
        let needsFullRebuild =
            scene.graphNodes.map(\.id) != graphNodes.map(\.id) ||
            scene.graphEdges.map(\.id) != graphEdges.map(\.id) ||
            scene.selectedNodeId != selectedNodeId ||
            coordinator.lastConstellations != constellations ||
            coordinator.lastDominantConstellationId != dominantConstellationId ||
            coordinator.lastToggleAllVisible != toggleAllVisible

        scene.scaleMode = .resizeFill
        scene.size = view.bounds.size
        scene.graphNodes = graphNodes
        scene.graphEdges = graphEdges
        scene.constellations = constellations
        scene.dominantConstellationId = dominantConstellationId
        scene.revealedConstellationIds = revealedConstellationIds
        scene.toggleAllVisible = toggleAllVisible
        scene.positions = positions
        scene.selectedNodeId = selectedNodeId
        scene.onNodeTapped = onNodeTapped
        scene.onNodeMoved = onNodeMoved

        if needsFullRebuild || scene.children.isEmpty {
            scene.rebuildScene()
        } else if coordinator.lastRevealedConstellationIds != revealedConstellationIds {
            scene.updateHaloAlphas()
        } else {
            scene.syncPositions()
        }

        coordinator.lastConstellations = constellations
        coordinator.lastDominantConstellationId = dominantConstellationId
        coordinator.lastToggleAllVisible = toggleAllVisible
        coordinator.lastRevealedConstellationIds = revealedConstellationIds
    }
}

final class InteractiveGalaxySKView: SKView {
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        if let scene {
            scene.mouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let scene {
            scene.mouseDragged(with: event)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let scene {
            scene.mouseUp(with: event)
        } else {
            super.mouseUp(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if let scene {
            scene.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        if let scene {
            scene.magnify(with: event)
        } else {
            super.magnify(with: event)
        }
    }
}
