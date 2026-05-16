import SwiftUI

enum SourceBriefingCardExpansionPolicy {
    private static let collapsedOverviewCharacterLimit = 180

    static func hasExpandableContent(_ briefing: SourceBriefing) -> Bool {
        let hasAnalystItemDetails = !briefing.items.isEmpty
        let hasExtraItems = briefing.items.count > 2
        let hasExtraGuidePoints = (briefing.guide?.keyPoints.count ?? 0) > 2
        let hasGuideDetail = !(briefing.guide?.suggestedQuestions.isEmpty ?? true) ||
            !(briefing.guide?.caveats.isEmpty ?? true)
        let overview = SourceBriefingText.body(briefing.guide?.overview ?? "") ?? ""
        let hasLongGuideOverview = overview.count > collapsedOverviewCharacterLimit
        return hasAnalystItemDetails || hasExtraItems || hasExtraGuidePoints || hasGuideDetail || hasLongGuideOverview
    }
}

struct SourceBriefingCard: View {
    let briefing: SourceBriefing

    @State private var isExpanded = false

    private var visibleItems: [SourceBriefingItem] {
        isExpanded ? briefing.items : Array(briefing.items.prefix(2))
    }

    private var visibleGuidePoints: [SourceGuidePoint] {
        guard let guide = briefing.guide else { return [] }
        return isExpanded ? guide.keyPoints : Array(guide.keyPoints.prefix(2))
    }

    private var hasExpandableContent: Bool {
        SourceBriefingCardExpansionPolicy.hasExpandableContent(briefing)
    }

    private var titleText: String {
        SourceBriefingText.title(briefing.title) ?? "Source analyst brief"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColor.colaOrange)

                Text(titleText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if hasExpandableContent {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppColor.secondaryText)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse source brief" : "Expand source brief")
                }
            }

            VStack(alignment: .leading, spacing: isExpanded ? 12 : 8) {
                if let guide = briefing.guide, !guide.isEmpty {
                    SourceGuideView(
                        guide: guide,
                        visiblePoints: visibleGuidePoints,
                        isExpanded: isExpanded
                    )
                }

                ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, item in
                    SourceBriefingItemView(item: item, isExpanded: isExpanded)
                }
            }
        }
        .padding(12)
        .background(AppColor.surfaceSecondary.opacity(0.9))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SourceGuideView: View {
    let guide: SourceGuide
    let visiblePoints: [SourceGuidePoint]
    let isExpanded: Bool

    private var overviewText: String {
        SourceBriefingText.body(guide.overview) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !overviewText.isEmpty {
                Text(overviewText)
                    .font(.system(size: 11))
                    .foregroundColor(AppColor.secondaryText)
                    .lineLimit(isExpanded ? nil : 3)
            }

            ForEach(Array(visiblePoints.enumerated()), id: \.offset) { _, point in
                SourceGuidePointView(point: point, isExpanded: isExpanded)
            }

            if isExpanded {
                let questions = guide.suggestedQuestions.compactMap(SourceBriefingText.body)
                if !questions.isEmpty {
                    SourceBriefingField(label: "Questions", text: questions.prefix(3).joined(separator: "  "))
                }
                let caveats = guide.caveats.compactMap(SourceBriefingText.body)
                if !caveats.isEmpty {
                    SourceBriefingField(label: "Caveats", text: caveats.prefix(3).joined(separator: "  "))
                }
            }
        }
    }
}

private struct SourceGuidePointView: View {
    let point: SourceGuidePoint
    let isExpanded: Bool

    private var titleText: String {
        SourceBriefingText.headline(point.title) ?? "Guide point"
    }

    private var summaryText: String {
        SourceBriefingText.body(point.summary) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(titleText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppColor.colaDarkText)
                .lineLimit(isExpanded ? nil : 2)

            Text(summaryText)
                .font(.system(size: 11))
                .foregroundColor(AppColor.secondaryText)
                .lineLimit(isExpanded ? nil : 2)

            if isExpanded {
                SourceBriefingField(label: "Locator", text: SourceBriefingText.body(point.locatorLabel) ?? "")
                SourceBriefingField(label: "Evidence", text: SourceBriefingText.evidence(point.evidence) ?? "")
            }
        }
    }
}

private struct SourceBriefingItemView: View {
    let item: SourceBriefingItem
    let isExpanded: Bool

    private var confidenceText: String {
        "\(Int((min(max(item.confidence, 0), 1) * 100).rounded()))%"
    }

    private var headlineText: String {
        SourceBriefingText.headline(item.headline) ?? "Source update"
    }

    private var whyItMattersText: String {
        SourceBriefingText.body(item.whyItMatters) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headlineText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineLimit(isExpanded ? nil : 2)

                Spacer(minLength: 8)

                Text(confidenceText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(AppColor.secondaryText)
            }

            if isExpanded {
                SourceBriefingField(label: "Changed", text: SourceBriefingText.body(item.whatChanged) ?? "")
                SourceBriefingField(label: "Matters", text: whyItMattersText)
                SourceBriefingField(label: "Alex", text: SourceBriefingText.body(item.alexRelevance) ?? "")
                SourceBriefingField(label: "Risk", text: SourceBriefingText.body(item.tensionOrRisk) ?? "")
                SourceBriefingField(label: "Next", text: SourceBriefingText.body(item.suggestedNextAction) ?? "")
                SourceBriefingField(label: "Evidence", text: SourceBriefingText.evidence(item.evidence) ?? "")
            } else {
                Text(whyItMattersText)
                    .font(.system(size: 11))
                    .foregroundColor(AppColor.secondaryText)
                    .lineLimit(2)
            }
        }
    }
}

private struct SourceBriefingField: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(AppColor.secondaryText)
                .textCase(.uppercase)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(AppColor.colaDarkText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
