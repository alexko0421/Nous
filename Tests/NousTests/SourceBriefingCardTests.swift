import XCTest
@testable import Nous

final class SourceBriefingCardTests: XCTestCase {
    func testExpansionPolicyAllowsSingleAnalystItemDetailsToExpand() {
        let sourceId = UUID()
        let briefing = SourceBriefing(
            title: "Brief",
            items: [
                SourceBriefingItem(
                    sourceNodeId: sourceId,
                    headline: "Margin pressure eased",
                    whatChanged: "Supplier renegotiation improved gross margin.",
                    whyItMatters: "It changes the read on margin quality.",
                    alexRelevance: "Useful for judging whether the business is improving.",
                    tensionOrRisk: "It may be a one-quarter timing effect.",
                    suggestedNextAction: "Check whether the next quarter repeats it.",
                    evidence: "supplier renegotiation improved gross margin",
                    confidence: 0.8
                )
            ]
        )

        XCTAssertTrue(SourceBriefingCardExpansionPolicy.hasExpandableContent(briefing))
    }

    func testExpansionPolicyAllowsLongGuideOverviewToExpand() {
        let sourceId = UUID()
        let longOverview = Array(repeating: "This overview is intentionally long enough to overflow the collapsed three-line guide preview.", count: 4)
            .joined(separator: " ")
        let briefing = SourceBriefing(
            title: "Brief",
            items: [],
            guide: SourceGuide(
                overview: longOverview,
                keyPoints: [
                    SourceGuidePoint(
                        sourceNodeId: sourceId,
                        title: "Only point",
                        summary: "One guide point means extra-point count alone should not trigger expansion.",
                        locatorLabel: "## Only",
                        evidence: "Only evidence."
                    )
                ],
                suggestedQuestions: [],
                caveats: []
            )
        )

        XCTAssertTrue(SourceBriefingCardExpansionPolicy.hasExpandableContent(briefing))
    }

    func testExpansionPolicyKeepsShortSingleGuideCollapsed() {
        let sourceId = UUID()
        let briefing = SourceBriefing(
            title: "Brief",
            items: [],
            guide: SourceGuide(
                overview: "Short overview.",
                keyPoints: [
                    SourceGuidePoint(
                        sourceNodeId: sourceId,
                        title: "Only point",
                        summary: "Short summary.",
                        locatorLabel: "## Only",
                        evidence: "Only evidence."
                    )
                ],
                suggestedQuestions: [],
                caveats: []
            )
        )

        XCTAssertFalse(SourceBriefingCardExpansionPolicy.hasExpandableContent(briefing))
    }
}
