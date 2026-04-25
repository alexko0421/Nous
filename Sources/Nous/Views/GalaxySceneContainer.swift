import AppKit
import SpriteKit
import SwiftUI

struct GalaxySceneContainer: NSViewRepresentable {
    let scene: GalaxyScene
    let graphNodes: [NousNode]
    let graphEdges: [NodeEdge]
    let positions: [UUID: GraphPosition]
    let selectedNodeId: UUID?
    let onNodeTapped: ((UUID) -> Void)?
    let onNodeMoved: ((UUID, GraphPosition) -> Void)?

    func makeNSView(context: Context) -> InteractiveGalaxySKView {
        let view = InteractiveGalaxySKView()
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.shouldCullNonVisibleNodes = false
        view.preferredFramesPerSecond = 120
        view.presentScene(scene)
        configure(scene: scene, in: view)
        return view
    }

    func updateNSView(_ view: InteractiveGalaxySKView, context: Context) {
        if view.scene !== scene {
            view.presentScene(scene)
        }
        configure(scene: scene, in: view)
    }

    private func configure(scene: GalaxyScene, in view: SKView) {
        let shouldRebuild =
            scene.graphNodes.map(\.id) != graphNodes.map(\.id) ||
            scene.graphEdges.map(\.id) != graphEdges.map(\.id) ||
            scene.selectedNodeId != selectedNodeId

        scene.scaleMode = .resizeFill
        scene.size = view.bounds.size
        scene.graphNodes = graphNodes
        scene.graphEdges = graphEdges
        scene.positions = positions
        scene.selectedNodeId = selectedNodeId
        scene.onNodeTapped = onNodeTapped
        scene.onNodeMoved = onNodeMoved

        if shouldRebuild || scene.children.isEmpty {
            scene.rebuildScene()
        } else {
            scene.syncPositions()
        }
    }
}

final class InteractiveGalaxySKView: SKView {
    override var acceptsFirstResponder: Bool { true }

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
