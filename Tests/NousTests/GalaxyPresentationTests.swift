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

    func testLensFiltersCountVisibleRelationshipKinds() {
        let sourceId = UUID()
        let targetId = UUID()
        let edges = [
            NodeEdge(sourceId: sourceId, targetId: targetId, strength: 0.91, type: .semantic, relationKind: .samePattern),
            NodeEdge(sourceId: sourceId, targetId: targetId, strength: 0.84, type: .semantic, relationKind: .tension),
            NodeEdge(sourceId: sourceId, targetId: targetId, strength: 0.73, type: .shared)
        ]

        XCTAssertEqual(GalaxyLensFilter.meaningful.count(in: edges), 3)
        XCTAssertEqual(GalaxyLensFilter.tensions.count(in: edges), 1)
        XCTAssertEqual(GalaxyLensFilter.patterns.count(in: edges), 1)
        XCTAssertEqual(GalaxyLensFilter.sameProject.count(in: edges), 1)
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
        XCTAssertEqual(summary.body, "它们反复指向同一种底层模式。")
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

        XCTAssertEqual(summary.body, "它们反复指向同一种底层模式。")
        XCTAssertEqual(summary.evidence, "Motivation 嘅来源 → 方向感")
    }

    func testGalaxySidebarUsesExistingChatSidebarWidth() {
        XCTAssertEqual(GalaxySidebarLayout.width, 154)
    }

    func testJournalLayoutStaysSecondaryToTheMap() {
        XCTAssertLessThanOrEqual(GalaxyJournalLayout.width, 236)
        XCTAssertLessThanOrEqual(GalaxyJournalLayout.maxHeight, 430)
        XCTAssertGreaterThanOrEqual(GalaxyJournalLayout.trailingPadding, 20)
    }
}
