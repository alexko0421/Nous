import XCTest
@testable import Nous

final class GalaxyPresentationTests: XCTestCase {
    func testQuietConstellationHeaderCopyMatchesApprovedDesign() {
        XCTAssertEqual(GalaxyPresentation.kicker, "连点成线")
        XCTAssertEqual(GalaxyPresentation.title, "Quiet Constellation")
        XCTAssertEqual(
            GalaxyPresentation.subtitle,
            "Click a node or edge. The journal floats in from the right."
        )
    }

    func testRelationshipLensFiltersMatchApprovedControls() {
        XCTAssertEqual(
            GalaxyLensFilter.allCases.map(\.title),
            ["Meaningful", "Tensions", "Patterns", "Same Project"]
        )
    }

    func testRelationshipLensFiltersHaveCompactCapsuleLabels() {
        XCTAssertEqual(
            GalaxyLensFilter.allCases.map(\.shortTitle),
            ["Me", "Te", "Pa", "Sa"]
        )
    }

    func testRelationshipLegendUsesChineseLineTypeLabels() {
        XCTAssertEqual(
            GalaxyRelationLineKind.legendCases.map(\.title),
            ["同一模式", "张力/矛盾", "支撑/因果", "同项目", "待验证"]
        )
    }

    func testRelationshipLineKindFollowsEdgeMeaning() {
        let sourceId = UUID()
        let targetId = UUID()

        XCTAssertEqual(
            GalaxyRelationLineKind.kind(
                for: displayableSemanticEdge(sourceId: sourceId, targetId: targetId, relationKind: .samePattern)
            ),
            .samePattern
        )
        XCTAssertEqual(
            GalaxyRelationLineKind.kind(
                for: displayableSemanticEdge(sourceId: sourceId, targetId: targetId, relationKind: .contradicts)
            ),
            .tension
        )
        XCTAssertEqual(
            GalaxyRelationLineKind.kind(
                for: displayableSemanticEdge(sourceId: sourceId, targetId: targetId, relationKind: .supports)
            ),
            .support
        )
        XCTAssertEqual(
            GalaxyRelationLineKind.kind(
                for: NodeEdge(sourceId: sourceId, targetId: targetId, strength: 0.35, type: .shared)
            ),
            .sameProject
        )
        XCTAssertEqual(
            GalaxyRelationLineKind.kind(for: vectorOnlyTopicEdge(sourceId: sourceId, targetId: targetId)),
            .candidate
        )
    }

    func testLensFiltersCountVisibleRelationshipKinds() {
        let sourceId = UUID()
        let targetId = UUID()
        let edges = [
            displayableSemanticEdge(sourceId: sourceId, targetId: targetId, relationKind: .samePattern),
            displayableSemanticEdge(sourceId: sourceId, targetId: targetId, relationKind: .tension),
            NodeEdge(sourceId: sourceId, targetId: targetId, strength: 0.73, type: .shared),
            vectorOnlyTopicEdge(sourceId: sourceId, targetId: targetId),
            unverifiedSemanticEdge(sourceId: sourceId, targetId: targetId, relationKind: .tension)
        ]

        XCTAssertEqual(GalaxyLensFilter.meaningful.count(in: edges), 4)
        XCTAssertEqual(GalaxyLensFilter.tensions.count(in: edges), 1)
        XCTAssertEqual(GalaxyLensFilter.patterns.count(in: edges), 1)
        XCTAssertEqual(GalaxyLensFilter.sameProject.count(in: edges), 1)
    }

    func testMeaningfulLensKeepsVectorSimilarityAsCandidateLineOnly() {
        let edge = vectorOnlyTopicEdge(sourceId: UUID(), targetId: UUID())

        XCTAssertTrue(GalaxyLensFilter.meaningful.matches(edge))
        XCTAssertFalse(GalaxyLensFilter.tensions.matches(edge))
        XCTAssertFalse(GalaxyLensFilter.patterns.matches(edge))
        XCTAssertEqual(GalaxyRelationLineKind.kind(for: edge), .candidate)
    }

    func testLensFiltersHideSemanticClaimsWithoutChineseEvidence() {
        let edge = unverifiedSemanticEdge(sourceId: UUID(), targetId: UUID(), relationKind: .tension)

        XCTAssertFalse(GalaxyLensFilter.meaningful.matches(edge))
        XCTAssertFalse(GalaxyLensFilter.tensions.matches(edge))
    }

    func testLensFilterCanBeInferredFromTappedEdge() {
        let sourceId = UUID()
        let targetId = UUID()

        XCTAssertEqual(
            GalaxyLensFilter.preferredLens(
                for: NodeEdge(sourceId: sourceId, targetId: targetId, strength: 0.84, type: .semantic, relationKind: .tension)
            ),
            .tensions
        )
        XCTAssertEqual(
            GalaxyLensFilter.preferredLens(
                for: NodeEdge(sourceId: sourceId, targetId: targetId, strength: 0.91, type: .semantic, relationKind: .samePattern)
            ),
            .patterns
        )
        XCTAssertEqual(
            GalaxyLensFilter.preferredLens(
                for: NodeEdge(sourceId: sourceId, targetId: targetId, strength: 0.73, type: .shared)
            ),
            .sameProject
        )
        XCTAssertEqual(
            GalaxyLensFilter.preferredLens(
                for: NodeEdge(sourceId: sourceId, targetId: targetId, strength: 0.66, type: .semantic, relationKind: .supports)
            ),
            .meaningful
        )
    }

    func testJournalSummaryUsesChineseTopicAndCopy() {
        let selected = NousNode(type: .conversation, title: "精神健康")
        let connected = NousNode(type: .note, title: "旧笔记")
        let edge = NodeEdge(
            sourceId: selected.id,
            targetId: connected.id,
            strength: 0.91,
            type: .semantic,
            relationKind: .samePattern,
            confidence: 0.91,
            explanation: nil,
            sourceEvidence: nil,
            targetEvidence: nil
        )

        let summary = GalaxyJournalSummary(
            selectedNode: selected,
            connectedNode: connected,
            edge: edge
        )

        XCTAssertEqual(summary.badge, "解释")
        XCTAssertEqual(summary.scoreText, "91%")
        XCTAssertEqual(summary.title, "精神健康")
        XCTAssertEqual(summary.relationTitle, "待验证")
        XCTAssertEqual(summary.body, "这条线目前只说明两段内容可能相近，还不足以证明张力、支撑、矛盾或因果。")
        XCTAssertEqual(summary.evidence, "精神健康 → 旧笔记")
    }

    func testJournalSummaryDoesNotSurfaceEnglishStoredExplanation() {
        let selected = NousNode(type: .conversation, title: "Motivation 嘅来源")
        let connected = NousNode(type: .note, title: "方向感")
        let edge = NodeEdge(
            sourceId: selected.id,
            targetId: connected.id,
            strength: 0.89,
            type: .semantic,
            relationKind: .samePattern,
            confidence: 0.89,
            explanation: "These nodes appear to express the same underlying pattern through different surface topics.",
            sourceEvidence: "Alex feels confused about the direction and purpose of the app.",
            targetEvidence: "需要重新整理方向感"
        )

        let summary = GalaxyJournalSummary(
            selectedNode: selected,
            connectedNode: connected,
            edge: edge
        )

        XCTAssertEqual(summary.relationTitle, "待验证")
        XCTAssertEqual(summary.body, "这条线目前只说明两段内容可能相近，还不足以证明张力、支撑、矛盾或因果。")
        XCTAssertEqual(summary.evidence, "Motivation 嘅来源 → 方向感")
    }

    func testJournalSummaryDowngradesGenericSemanticExplanation() {
        let selected = NousNode(
            type: .conversation,
            title: "Evo SL 定 Cloudmonster 3 最终决定",
            content: "Alex plans to buy the shoes tomorrow right after class."
        )
        let connected = NousNode(
            type: .note,
            title: "购物约会模式",
            content: "Alex and the Mexican girl previously hung out around shopping/buying things."
        )
        let edge = NodeEdge(
            sourceId: selected.id,
            targetId: connected.id,
            strength: 0.96,
            type: .semantic,
            relationKind: .tension,
            confidence: 0.96,
            explanation: "它们之间有一个值得留意的张力。",
            sourceEvidence: "Alex plans to buy the shoes tomorrow right after class",
            targetEvidence: "Alex and the Mexican girl previously hung out around shopping/buying things"
        )

        let summary = GalaxyJournalSummary(
            selectedNode: selected,
            connectedNode: connected,
            edge: edge
        )

        XCTAssertEqual(summary.relationTitle, "待验证")
        XCTAssertEqual(summary.body, "这条线目前只说明两段内容可能相近，还不足以证明张力、支撑、矛盾或因果。")
        XCTAssertFalse(summary.detailItems.contains { $0.text == summary.body })
        XCTAssertEqual(summary.caveat, "解释不够具体；这条关系需要重新验证，不能当作强结论。")
    }

    func testJournalSummaryDoesNotRepeatMainExplanationInsideDetails() {
        let selected = NousNode(type: .conversation, title: "未来方向")
        let connected = NousNode(type: .note, title: "文科选择")
        let edge = NodeEdge(
            sourceId: selected.id,
            targetId: connected.id,
            strength: 0.87,
            type: .semantic,
            relationKind: .samePattern,
            confidence: 0.87,
            explanation: "两段都在问同一个问题：未来选择要从真实兴趣出发，而不是只追一个外部看起来正确的身份。",
            sourceEvidence: "Alex 在问 UIUX 设计师未来是不是值得做。",
            targetEvidence: "Alex 对文科、哲学和长期方向感到摇摆。"
        )

        let summary = GalaxyJournalSummary(
            selectedNode: selected,
            connectedNode: connected,
            edge: edge
        )

        XCTAssertEqual(summary.body, "两段都在问同一个问题：未来选择要从真实兴趣出发，而不是只追一个外部看起来正确的身份。")
        XCTAssertFalse(summary.detailItems.contains { $0.text == summary.body })
    }

    func testJournalSummaryDoesNotSurfaceEnglishStoredEvidenceInDetails() {
        let selected = NousNode(type: .conversation, title: "未来方向")
        let connected = NousNode(type: .note, title: "文科选择")
        let edge = NodeEdge(
            sourceId: selected.id,
            targetId: connected.id,
            strength: 0.87,
            type: .semantic,
            relationKind: .samePattern,
            confidence: 0.87,
            explanation: "两段都在问同一个问题：未来选择要从真实兴趣出发，而不是只追一个外部看起来正确的身份。",
            sourceEvidence: "Alex is particularly interested in Stoicism.",
            targetEvidence: "Alex feels confused/lost about the direction and purpose of the app he is currently building"
        )

        let summary = GalaxyJournalSummary(
            selectedNode: selected,
            connectedNode: connected,
            edge: edge
        )

        XCTAssertEqual(summary.detailItems.first, GalaxyJournalDetailItem(label: "已选线索", text: "未来方向"))
        XCTAssertEqual(summary.detailItems.dropFirst().first, GalaxyJournalDetailItem(label: "关联线索", text: "文科选择"))
        XCTAssertFalse(summary.detailItems.contains { $0.text.contains("Stoicism") })
        XCTAssertFalse(summary.detailItems.contains { $0.text.contains("confused/lost") })
    }

    func testJournalSummaryBuildsEvidenceLedgerForSelectedRelationship() {
        let selected = NousNode(type: .conversation, title: "精神负荷", content: "不确定感一大，我就会用更快的速度去压住它。")
        let connected = NousNode(type: .note, title: "出货模式", content: "速度正在被当成压力阀，而不是清晰判断。")
        let sourceAtomId = UUID()
        let targetAtomId = UUID()
        let edge = NodeEdge(
            sourceId: selected.id,
            targetId: connected.id,
            strength: 0.89,
            type: .semantic,
            relationKind: .samePattern,
            confidence: 0.91,
            explanation: "两段都指出同一个模式：Alex 会用速度处理不确定感，但速度本身不等于判断变清楚。",
            sourceEvidence: "不确定感一大，我就会用更快的速度去压住它。",
            targetEvidence: "速度正在被当成压力阀，而不是清晰判断。",
            sourceAtomId: sourceAtomId,
            targetAtomId: targetAtomId
        )

        let summary = GalaxyJournalSummary(
            selectedNode: selected,
            connectedNode: connected,
            edge: edge
        )

        XCTAssertEqual(summary.relationTitle, "同一模式")
        XCTAssertEqual(summary.detailItems, [
            GalaxyJournalDetailItem(label: "已选线索", text: "不确定感一大，我就会用更快的速度去压住它。"),
            GalaxyJournalDetailItem(label: "关联线索", text: "速度正在被当成压力阀，而不是清晰判断。"),
            GalaxyJournalDetailItem(label: "证据等级", text: "记忆原子支持")
        ])
        XCTAssertEqual(summary.lineKind, .samePattern)
        XCTAssertNil(summary.caveat)
    }

    func testJournalSummaryDowngradesAtomBackedRelationWhenEvidenceIsNotChinese() {
        let selected = NousNode(type: .conversation, title: "未来方向")
        let connected = NousNode(type: .note, title: "文科选择")
        let edge = NodeEdge(
            sourceId: selected.id,
            targetId: connected.id,
            strength: 0.87,
            type: .semantic,
            relationKind: .samePattern,
            confidence: 0.87,
            explanation: "两段都在问同一个问题：未来选择要从真实兴趣出发，而不是只追一个外部看起来正确的身份。",
            sourceEvidence: "Alex is particularly interested in Stoicism.",
            targetEvidence: "Alex feels confused/lost about the direction and purpose of the app he is currently building",
            sourceAtomId: UUID(),
            targetAtomId: UUID()
        )

        let summary = GalaxyJournalSummary(
            selectedNode: selected,
            connectedNode: connected,
            edge: edge
        )

        XCTAssertEqual(summary.relationTitle, "待验证")
        XCTAssertNil(summary.lineKind)
        XCTAssertEqual(summary.caveat, "解释不够具体；这条关系需要重新验证，不能当作强结论。")
    }

    func testJournalSummaryWarnsWhenRelationIsOnlyVectorSimilarity() {
        let selected = NousNode(type: .conversation, title: "Visa planning")
        let connected = NousNode(type: .note, title: "Class schedule")
        let edge = NodeEdge(
            sourceId: connected.id,
            targetId: selected.id,
            strength: 0.78,
            type: .semantic,
            relationKind: .topicSimilarity,
            confidence: 0.78,
            explanation: "These nodes are semantically close, but Nous does not yet have stronger evidence for a deeper relationship.",
            sourceEvidence: "Santa Monica class calendar",
            targetEvidence: "F-1 visa planning"
        )

        let summary = GalaxyJournalSummary(
            selectedNode: selected,
            connectedNode: connected,
            edge: edge
        )

        XCTAssertEqual(summary.body, "这只是语义相似，不是强结论。先把它当成待验证的线索。")
        XCTAssertEqual(summary.detailItems, [
            GalaxyJournalDetailItem(label: "已选线索", text: "Visa planning"),
            GalaxyJournalDetailItem(label: "关联线索", text: "Class schedule"),
            GalaxyJournalDetailItem(label: "证据等级", text: "内容摘录 + 向量相似")
        ])
        XCTAssertEqual(summary.caveat, "这条线不能自动说明因果、支持或矛盾，只说明两段内容在表达上接近。")
    }

    func testGalaxySidebarUsesExistingChatSidebarWidth() {
        XCTAssertEqual(GalaxySidebarLayout.width, 154)
    }

    func testJournalLayoutStaysSecondaryToTheMap() {
        XCTAssertGreaterThanOrEqual(GalaxyJournalLayout.width, 300)
        XCTAssertLessThanOrEqual(GalaxyJournalLayout.width, 340)
        XCTAssertLessThanOrEqual(GalaxyJournalLayout.maxHeight, 540)
        XCTAssertGreaterThanOrEqual(GalaxyJournalLayout.trailingPadding, 20)
    }

    private func displayableSemanticEdge(
        sourceId: UUID,
        targetId: UUID,
        relationKind: GalaxyRelationKind
    ) -> NodeEdge {
        NodeEdge(
            sourceId: sourceId,
            targetId: targetId,
            strength: 0.91,
            type: .semantic,
            relationKind: relationKind,
            confidence: 0.91,
            explanation: "两段都在讲同一个可引用的判断：Alex 正在用具体选择测试长期方向，而不是只比较表面话题。",
            sourceEvidence: "Alex 讨论未来方向时，把文科身份和长期能力放在一起判断。",
            targetEvidence: "Alex 复盘花钱决定时，提到要分清即时冲动和长期价值。",
            sourceAtomId: UUID(),
            targetAtomId: UUID()
        )
    }

    private func vectorOnlyTopicEdge(sourceId: UUID, targetId: UUID) -> NodeEdge {
        NodeEdge(
            sourceId: sourceId,
            targetId: targetId,
            strength: 0.89,
            type: .semantic,
            relationKind: .topicSimilarity,
            confidence: 0.89
        )
    }

    private func unverifiedSemanticEdge(
        sourceId: UUID,
        targetId: UUID,
        relationKind: GalaxyRelationKind
    ) -> NodeEdge {
        NodeEdge(
            sourceId: sourceId,
            targetId: targetId,
            strength: 0.88,
            type: .semantic,
            relationKind: relationKind,
            confidence: 0.88,
            explanation: "它们之间有一个值得留意的张力。",
            sourceEvidence: "Alex is particularly interested in Stoicism.",
            targetEvidence: "Alex feels confused/lost about the direction and purpose of the app."
        )
    }
}
