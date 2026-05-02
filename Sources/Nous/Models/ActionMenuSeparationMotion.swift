import CoreGraphics

struct ActionMenuSeparationMotion {
    let sourceYOffset: CGFloat
    let collapsedScale: CGSize
    let openingDelayStep: Double
    let closingDelayStep: Double

    init(
        sourceYOffset: CGFloat = 46,
        collapsedScale: CGSize = CGSize(width: 0.24, height: 0.68),
        openingDelayStep: Double = 0.035,
        closingDelayStep: Double = 0.018
    ) {
        self.sourceYOffset = sourceYOffset
        self.collapsedScale = collapsedScale
        self.openingDelayStep = openingDelayStep
        self.closingDelayStep = closingDelayStep
    }

    func capsuleOffset(isExpanded: Bool) -> CGSize {
        isExpanded ? .zero : CGSize(width: 0, height: sourceYOffset)
    }

    func capsuleScale(isExpanded: Bool) -> CGSize {
        isExpanded ? CGSize(width: 1, height: 1) : collapsedScale
    }

    func capsuleOpacity(isExpanded: Bool) -> Double {
        isExpanded ? 1 : 0
    }

    func capsuleBlur(isExpanded: Bool) -> CGFloat {
        isExpanded ? 0 : 8
    }

    func itemOffset(for index: Int, isExpanded: Bool) -> CGSize {
        .zero
    }

    func itemOpacity(isExpanded: Bool, isEnabled: Bool) -> Double {
        guard isExpanded else {
            return 0
        }

        return isEnabled ? 1 : 0.48
    }

    func delay(for index: Int, isExpanded: Bool, itemCount: Int = 3) -> Double {
        let safeIndex = max(index, 0)
        if isExpanded {
            return Double(safeIndex) * openingDelayStep
        }

        return Double(max(itemCount - safeIndex - 1, 0)) * closingDelayStep
    }
}
