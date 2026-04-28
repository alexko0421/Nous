import SwiftUI
import SpriteKit

struct GalaxyView: View {
    @Bindable var vm: GalaxyViewModel
    var onNodeSelected: ((NousNode) -> Void)?
    @State private var scene = GalaxyScene()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
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

            if let node = vm.selectedNode {
                selectedNodeInspector(node)
                    .padding(20)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.galaxyBackground)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: vm.selectedNodeId)
        .onAppear {
            vm.load()
        }
    }

    private func handleNodeTap(_ id: UUID) {
        vm.selectedNodeId = (vm.selectedNodeId == id) ? nil : id
    }

    private func handleNodeMove(_ id: UUID, _ position: GraphPosition) {
        vm.updateNodePosition(id, x: position.x, y: position.y)
    }

    // MARK: - Inspector

    private func selectedNodeInspector(_ node: NousNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                nodeHeaderSection(node)

                openButton(for: node)

                connectionsSection
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func nodeHeaderSection(_ node: NousNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected Node")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.52))
                .tracking(0.4)

            typeTag(node.type)

            Text(node.title.isEmpty ? "Untitled" : node.title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(nodeExcerpt(node))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.66))
                .lineLimit(7)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openButton(for node: NousNode) -> some View {
        Button {
            onNodeSelected?(node)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: node.type == .conversation
                      ? "bubble.left.and.text.bubble.right.fill"
                      : "doc.text.fill")
                    .font(.system(size: 12, weight: .medium))

                Text(node.type == .conversation ? "Open Conversation" : "Open Note")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connected Nodes")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.52))
                .tracking(0.4)

            if vm.selectedNodeEdges.isEmpty {
                Text("No direct connections yet. This node still needs semantic or project context.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(vm.selectedNodeEdges.prefix(6)) { edge in
                    connectionRow(edge)
                }
            }
        }
    }

    private func connectionRow(_ edge: NodeEdge) -> some View {
        Button {
            if let connected = vm.connectedNode(for: edge) {
                vm.selectedNodeId = connected.id
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(relationTint(edge))
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 6) {
                    if let connected = vm.connectedNode(for: edge) {
                        Text(connected.title.isEmpty ? "Untitled" : connected.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    Text(relationLabel(edge))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(relationTint(edge).opacity(0.92))
                        .lineLimit(1)

                    if let explanation = edge.explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.56))
                            .lineLimit(3)
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let evidence = formattedEvidence(for: edge) {
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 1.5)

                            Text(evidence)
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.58))
                                .lineLimit(2)
                                .lineSpacing(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                Text("\(Int(edge.confidence * 100))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.74))
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tags & Helpers

    private func typeTag(_ type: NodeType) -> some View {
        Label(
            type == .conversation ? "Conversation" : "Note",
            systemImage: type == .conversation
                ? "bubble.left.and.text.bubble.right.fill"
                : "doc.text.fill"
        )
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.78))
        .tracking(0.3)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    private func relationTint(_ edge: NodeEdge) -> Color {
        switch edge.type {
        case .manual:
            return Self.warmTaupe
        case .shared:
            return Color.white.opacity(0.55)
        case .semantic:
            switch edge.relationKind {
            case .samePattern:
                return Self.dustyRose
            case .supports, .causeEffect, .tension, .contradicts:
                return Self.warmTaupe
            case .topicSimilarity:
                return Color.white.opacity(0.42)
            }
        }
    }

    // Morandi palette — dusty, low-saturation, warm-earthy. No saturated brand accents.
    private static let dustyRose = Color(red: 0.77, green: 0.63, blue: 0.60)   // #C4A09A
    private static let warmTaupe = Color(red: 0.66, green: 0.61, blue: 0.55)   // #A89C8C

    private func relationLabel(_ edge: NodeEdge) -> String {
        switch edge.type {
        case .manual:
            return "Manually linked"
        case .shared:
            return "Same project"
        case .semantic:
            switch edge.relationKind {
            case .samePattern: return "Same pattern"
            case .tension: return "Tension"
            case .supports: return "Supports"
            case .contradicts: return "Contradicts"
            case .causeEffect: return "Cause → effect"
            case .topicSimilarity: return "Related topic"
            }
        }
    }

    private func formattedEvidence(for edge: NodeEdge) -> String? {
        let primary = edge.sourceEvidence?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? edge.targetEvidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let primary, !primary.isEmpty else { return nil }
        return primary
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

    // MARK: - Empty / Loading

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.white.opacity(0.52))

            Text("Galaxy is empty")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.white)

            Text("Start a conversation or create a note\nto reveal the first threads.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.62))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color.white.opacity(0.62))

            Text("Mapping your connections…")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.64))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
