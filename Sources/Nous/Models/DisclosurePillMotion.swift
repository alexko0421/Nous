import CoreGraphics

struct DisclosurePillMotion {
    let collapsedScaleY: CGFloat
    let collapsedBlur: CGFloat
    let expandedSpacing: CGFloat

    init(
        collapsedScaleY: CGFloat = 0.96,
        collapsedBlur: CGFloat = 4,
        expandedSpacing: CGFloat = 6
    ) {
        self.collapsedScaleY = collapsedScaleY
        self.collapsedBlur = collapsedBlur
        self.expandedSpacing = expandedSpacing
    }

    func visibleContentHeight(fullHeight: CGFloat, isExpanded: Bool) -> CGFloat {
        isExpanded ? max(fullHeight, 0) : 0
    }

    func contentOffsetY(isExpanded: Bool) -> CGFloat {
        0
    }

    func contentOpacity(isExpanded: Bool) -> Double {
        isExpanded ? 1 : 0
    }

    func contentScaleY(isExpanded: Bool) -> CGFloat {
        isExpanded ? 1 : collapsedScaleY
    }

    func contentBlur(isExpanded: Bool) -> CGFloat {
        isExpanded ? 0 : collapsedBlur
    }

    func contentSpacing(isExpanded: Bool) -> CGFloat {
        isExpanded ? expandedSpacing : 0
    }
}
