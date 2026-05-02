import CoreGraphics
import Foundation

enum GalaxyPresentation {
    static let kicker = "连点成线"
    static let title = "Quiet Constellation"
    static let subtitle = "Click a node or edge. The journal floats in from the right."
}

enum GalaxySidebarLayout {
    static let width: CGFloat = 154
}

enum GalaxyJournalLayout {
    static let width: CGFloat = 226
    static let maxHeight: CGFloat = 410
    static let verticalPadding: CGFloat = 42
    static let trailingPadding: CGFloat = 24
}

enum GalaxyZoomPresentation {
    static let titleRevealScale: CGFloat = 0.86
    static let minimumScale: CGFloat = 0.26
    static let maximumScale: CGFloat = 3.2
}

enum GalaxyLensFilter: CaseIterable, Identifiable {
    case meaningful
    case tensions
    case patterns
    case sameProject

    var id: Self { self }

    var title: String {
        switch self {
        case .meaningful:
            return "Meaningful"
        case .tensions:
            return "Tensions"
        case .patterns:
            return "Patterns"
        case .sameProject:
            return "Same Project"
        }
    }

    var shortTitle: String {
        switch self {
        case .meaningful:
            return "Me"
        case .tensions:
            return "Te"
        case .patterns:
            return "Pa"
        case .sameProject:
            return "Sa"
        }
    }

    func count(in edges: [NodeEdge]) -> Int {
        edges.filter(matches).count
    }

    func matches(_ edge: NodeEdge) -> Bool {
        switch self {
        case .meaningful:
            return true
        case .tensions:
            return edge.type == .semantic && (edge.relationKind == .tension || edge.relationKind == .contradicts)
        case .patterns:
            return edge.type == .semantic && edge.relationKind == .samePattern
        case .sameProject:
            return edge.type == .shared
        }
    }

    static func preferredLens(for edge: NodeEdge) -> GalaxyLensFilter {
        switch edge.type {
        case .shared:
            return .sameProject
        case .manual:
            return .meaningful
        case .semantic:
            switch edge.relationKind {
            case .tension, .contradicts:
                return .tensions
            case .samePattern:
                return .patterns
            case .supports, .causeEffect, .topicSimilarity:
                return .meaningful
            }
        }
    }
}

struct GalaxyJournalSummary: Equatable {
    let badge: String
    let scoreText: String
    let title: String
    let body: String
    let evidence: String
    let connectedNodeTitle: String

    init(selectedNode: NousNode, connectedNode: NousNode?, edge: NodeEdge?) {
        badge = "解释"
        title = selectedNode.title.nonEmpty ?? connectedNode?.title.nonEmpty ?? "关系"
        connectedNodeTitle = connectedNode?.title.nonEmpty ?? "关联节点"

        if let edge {
            scoreText = "\(Int((edge.confidence * 100).rounded()))%"
            body = Self.localizedExplanation(for: edge) ?? Self.fallbackBody(for: edge)
            evidence = Self.evidenceText(for: edge, selectedNode: selectedNode, connectedNode: connectedNode)
        } else {
            scoreText = "新"
            body = "选择一条连接线，Nous 会解释为什么这些想法应该放在一起。"
            evidence = selectedNode.title.nonEmpty ?? "这个节点还在等待更强的关系。"
        }
    }

    private static func localizedExplanation(for edge: NodeEdge) -> String? {
        guard let explanation = edge.explanation?.nonEmpty else { return nil }
        return explanation.containsCJK ? explanation : nil
    }

    private static func fallbackBody(for edge: NodeEdge) -> String {
        switch edge.type {
        case .manual:
            return "这条连接是手动建立的。"
        case .shared:
            return "这些节点属于同一个项目语境。"
        case .semantic:
            switch edge.relationKind {
            case .samePattern:
                return "它们反复指向同一种底层模式。"
            case .tension:
                return "它们之间有一个值得留意的张力。"
            case .supports:
                return "其中一个想法正在支撑另一个想法。"
            case .contradicts:
                return "这些想法看起来互相矛盾。"
            case .causeEffect:
                return "其中一个想法可能解释了另一个想法的原因。"
            case .topicSimilarity:
                return "这些想法在语义上有关联。"
            }
        }
    }

    private static func evidenceText(
        for edge: NodeEdge,
        selectedNode: NousNode,
        connectedNode: NousNode?
    ) -> String {
        let source = edge.sourceEvidence?.nonEmpty
        let target = edge.targetEvidence?.nonEmpty

        if let source, let target, source.containsCJK, target.containsCJK {
            return "\(source) → \(target)"
        }

        if let source, source.containsCJK, target == nil {
            return source
        }

        if let target, target.containsCJK, source == nil {
            return target
        }

        if let connectedNode {
            return "\(selectedNode.title.nonEmpty ?? "已选节点") → \(connectedNode.title.nonEmpty ?? "关联节点")"
        }

        return selectedNode.title.nonEmpty ?? "暂时没有证据摘录。"
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }
}
