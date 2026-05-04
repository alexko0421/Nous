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
    static let width: CGFloat = 320
    static let maxHeight: CGFloat = 520
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
            return GalaxyRelationVisibility.isVisible(edge)
        case .tensions:
            return edge.type == .semantic
                && (edge.relationKind == .tension || edge.relationKind == .contradicts)
                && GalaxyRelationVisibility.isDisplayableSemantic(edge)
        case .patterns:
            return edge.type == .semantic
                && edge.relationKind == .samePattern
                && GalaxyRelationVisibility.isDisplayableSemantic(edge)
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

enum GalaxyRelationVisibility {
    static func isVisible(_ edge: NodeEdge) -> Bool {
        switch edge.type {
        case .manual, .shared:
            return true
        case .semantic:
            return edge.relationKind == .topicSimilarity || isDisplayableSemantic(edge)
        }
    }

    static func isDisplayable(_ edge: NodeEdge) -> Bool {
        switch edge.type {
        case .manual, .shared:
            return true
        case .semantic:
            return isDisplayableSemantic(edge)
        }
    }

    static func isDisplayableSemantic(_ edge: NodeEdge) -> Bool {
        guard edge.relationKind != .topicSimilarity else { return false }
        guard GalaxyExplanationQuality.hasUsefulChineseExplanation(edge.explanation) else {
            return false
        }

        return GalaxyExplanationQuality.containsCJK(edge.sourceEvidence ?? "")
            && GalaxyExplanationQuality.containsCJK(edge.targetEvidence ?? "")
    }
}

enum GalaxyRelationLineKind: CaseIterable, Identifiable, Equatable {
    case samePattern
    case tension
    case support
    case sameProject
    case manual
    case candidate

    static let legendCases: [GalaxyRelationLineKind] = [
        .samePattern,
        .tension,
        .support,
        .sameProject,
        .candidate
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .samePattern:
            return "同一模式"
        case .tension:
            return "张力/矛盾"
        case .support:
            return "支撑/因果"
        case .sameProject:
            return "同项目"
        case .manual:
            return "手动"
        case .candidate:
            return "待验证"
        }
    }

    static func kind(for edge: NodeEdge) -> GalaxyRelationLineKind? {
        switch edge.type {
        case .manual:
            return .manual
        case .shared:
            return .sameProject
        case .semantic:
            guard edge.relationKind != .topicSimilarity else {
                return .candidate
            }
            guard GalaxyRelationVisibility.isDisplayableSemantic(edge) else {
                return nil
            }

            switch edge.relationKind {
            case .samePattern:
                return .samePattern
            case .tension, .contradicts:
                return .tension
            case .supports, .causeEffect:
                return .support
            case .topicSimilarity:
                return .candidate
            }
        }
    }
}

struct GalaxyJournalDetailItem: Equatable {
    let label: String
    let text: String
}

struct GalaxyJournalSummary: Equatable {
    let badge: String
    let relationTitle: String
    let scoreText: String
    let title: String
    let connectionText: String
    let body: String
    let evidence: String
    let detailItems: [GalaxyJournalDetailItem]
    let caveat: String?
    let lineKind: GalaxyRelationLineKind?

    init(selectedNode: NousNode, connectedNode: NousNode?, edge: NodeEdge?) {
        badge = "解释"
        title = selectedNode.title.nonEmpty ?? connectedNode?.title.nonEmpty ?? "关系"
        connectionText = Self.connectionText(selectedNode: selectedNode, connectedNode: connectedNode)

        if let edge {
            let isUnverified = Self.isUnverifiedSemanticRelation(edge)
            let edgeLineKind = GalaxyRelationLineKind.kind(for: edge)
            let explanationText = Self.explanationText(for: edge, isUnverified: isUnverified)
            relationTitle = (isUnverified || edgeLineKind == .candidate) ? "待验证" : Self.relationTitle(for: edge)
            scoreText = "\(Int((edge.confidence * 100).rounded()))%"
            body = explanationText
            evidence = Self.evidenceText(for: edge, selectedNode: selectedNode, connectedNode: connectedNode)
            detailItems = Self.detailItems(
                for: edge,
                selectedNode: selectedNode,
                connectedNode: connectedNode
            )
            caveat = Self.caveat(for: edge, isUnverified: isUnverified)
            lineKind = isUnverified ? nil : edgeLineKind
        } else {
            relationTitle = "等待连接"
            scoreText = "新"
            body = "选择一条连接线，Nous 会解释为什么这些想法应该放在一起。"
            evidence = selectedNode.title.nonEmpty ?? "这个节点还在等待更强的关系。"
            detailItems = [
                GalaxyJournalDetailItem(
                    label: "当前节点",
                    text: Self.nodeExcerpt(selectedNode) ?? "这个节点还没有可引用内容。"
                )
            ]
            caveat = nil
            lineKind = nil
        }
    }

    private static func connectionText(selectedNode: NousNode, connectedNode: NousNode?) -> String {
        let selectedTitle = selectedNode.title.nonEmpty ?? "已选节点"
        guard let connectedTitle = connectedNode?.title.nonEmpty else {
            return "连接节点：「\(selectedTitle)」"
        }
        return "连接节点：「\(selectedTitle)」↔「\(connectedTitle)」"
    }

    private static func relationTitle(for edge: NodeEdge) -> String {
        switch edge.type {
        case .manual:
            return "手动连接"
        case .shared:
            return "同项目"
        case .semantic:
            switch edge.relationKind {
            case .samePattern:
                return "同一模式"
            case .tension:
                return "张力"
            case .supports:
                return "支撑"
            case .contradicts:
                return "矛盾"
            case .causeEffect:
                return "因果线索"
            case .topicSimilarity:
                return "语义相似"
            }
        }
    }

    private static func localizedExplanation(for edge: NodeEdge) -> String? {
        guard let explanation = edge.explanation?.nonEmpty else { return nil }
        return GalaxyExplanationQuality.hasUsefulChineseExplanation(explanation) ? explanation : nil
    }

    private static func isUnverifiedSemanticRelation(_ edge: NodeEdge) -> Bool {
        guard edge.type == .semantic, edge.relationKind != .topicSimilarity else {
            return false
        }

        return !GalaxyRelationVisibility.isDisplayableSemantic(edge)
    }

    private static func explanationText(for edge: NodeEdge, isUnverified: Bool) -> String {
        if isUnverified {
            return "这条线目前只说明两段内容可能相近，还不足以证明张力、支撑、矛盾或因果。"
        }

        return localizedExplanation(for: edge) ?? fallbackBody(for: edge)
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
                return "虚线代表待验证：这只是语义相似，不是强结论。先把它当成可以回头检查的线索。"
            }
        }
    }

    private static func detailItems(
        for edge: NodeEdge,
        selectedNode: NousNode,
        connectedNode: NousNode?
    ) -> [GalaxyJournalDetailItem] {
        let orientedEvidence = orientedDisplayEvidence(
            for: edge,
            selectedNode: selectedNode,
            connectedNode: connectedNode
        )
        var items: [GalaxyJournalDetailItem] = [
            GalaxyJournalDetailItem(
                label: "已选线索",
                text: orientedEvidence.selected
            )
        ]

        if let connectedNode {
            items.append(GalaxyJournalDetailItem(
                label: "关联线索",
                text: orientedEvidence.connected ?? displayEvidence(nil, for: connectedNode)
            ))
        }

        items.append(GalaxyJournalDetailItem(
            label: "证据等级",
            text: evidenceGrade(for: edge)
        ))

        return items
    }

    private static func orientedDisplayEvidence(
        for edge: NodeEdge,
        selectedNode: NousNode,
        connectedNode: NousNode?
    ) -> (selected: String, connected: String?) {
        let source = edge.sourceEvidence?.nonEmpty
        let target = edge.targetEvidence?.nonEmpty
        let connectedNode = connectedNode ?? selectedNode

        if edge.sourceId == selectedNode.id {
            return (
                displayEvidence(source, for: selectedNode),
                displayEvidence(target, for: connectedNode)
            )
        }

        if edge.targetId == selectedNode.id {
            return (
                displayEvidence(target, for: selectedNode),
                displayEvidence(source, for: connectedNode)
            )
        }

        return (
            displayEvidence(source, for: selectedNode),
            displayEvidence(target, for: connectedNode)
        )
    }

    private static func displayEvidence(_ raw: String?, for node: NousNode) -> String {
        if let raw, raw.containsCJK {
            return raw
        }

        if let content = node.content.nonEmpty, content.containsCJK {
            return String(content.prefix(220))
        }

        if let title = node.title.nonEmpty {
            return title
        }

        if let content = node.content.nonEmpty {
            return String(content.prefix(120))
        }

        return "没有可引用线索。"
    }

    private static func evidenceGrade(for edge: NodeEdge) -> String {
        switch edge.type {
        case .manual:
            return "手动建立"
        case .shared:
            return "同项目结构关系"
        case .semantic:
            if edge.sourceAtomId != nil && edge.targetAtomId != nil {
                return "记忆原子支持"
            }

            if edge.sourceAtomId != nil || edge.targetAtomId != nil {
                return "单侧记忆原子支持"
            }

            if edge.sourceEvidence?.nonEmpty != nil || edge.targetEvidence?.nonEmpty != nil {
                return "内容摘录 + 向量相似"
            }

            return "只有向量相似，待验证"
        }
    }

    private static func caveat(for edge: NodeEdge, isUnverified: Bool) -> String? {
        if isUnverified {
            return "解释不够具体；这条关系需要重新验证，不能当作强结论。"
        }

        guard edge.type == .semantic, edge.relationKind == .topicSimilarity else {
            return nil
        }

        return "虚线不能自动说明因果、支持或矛盾；它只说明两段内容在表达上接近。"
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

    private static func nodeExcerpt(_ node: NousNode) -> String? {
        if let content = node.content.nonEmpty {
            return String(content.prefix(220))
        }

        return node.title.nonEmpty
    }
}

private extension String {
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
