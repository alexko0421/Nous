import CoreGraphics

struct ActionMenuSeparationMotion {
    let sourceYOffset: CGFloat
    let collapsedScale: CGSize
    let openingDelayStep: Double
    let closingDelayStep: Double

    init(
        sourceYOffset: CGFloat = 46,
        collapsedScale: CGSize = CGSize(width: 0.24, height: 0.68),
        openingDelayStep: Double = 0.018,
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

enum ComposerSeparationPolicy {
    static func shouldSeparate(inputText: String, hasAttachments: Bool, isGenerating: Bool) -> Bool {
        let hasDraft = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasDraft || hasAttachments || isGenerating
    }
}

struct ComposerPrimaryActionMotion {
    let joinedIconOpacity: Double
    let separatedIconOpacity: Double
    let separatedTintAlpha: CGFloat
    let disabledSeparatedTintAlpha: CGFloat
    let separatedFillOpacity: Double
    let disabledSeparatedFillOpacity: Double
    let separatedGlowOpacity: Double

    init(
        joinedIconOpacity: Double = 0,
        separatedIconOpacity: Double = 1,
        separatedTintAlpha: CGFloat = 0.88,
        disabledSeparatedTintAlpha: CGFloat = 0.18,
        separatedFillOpacity: Double = 0.82,
        disabledSeparatedFillOpacity: Double = 0.16,
        separatedGlowOpacity: Double = 0.1
    ) {
        self.joinedIconOpacity = joinedIconOpacity
        self.separatedIconOpacity = separatedIconOpacity
        self.separatedTintAlpha = separatedTintAlpha
        self.disabledSeparatedTintAlpha = disabledSeparatedTintAlpha
        self.separatedFillOpacity = separatedFillOpacity
        self.disabledSeparatedFillOpacity = disabledSeparatedFillOpacity
        self.separatedGlowOpacity = separatedGlowOpacity
    }

    func tintAlpha(isSeparated: Bool, canAct: Bool) -> CGFloat {
        guard isSeparated else {
            return 0
        }

        return canAct ? separatedTintAlpha : disabledSeparatedTintAlpha
    }

    func iconOpacity(isSeparated: Bool) -> Double {
        isSeparated ? separatedIconOpacity : joinedIconOpacity
    }

    func fillOpacity(isSeparated: Bool, canAct: Bool) -> Double {
        guard isSeparated else {
            return 0
        }

        return canAct ? separatedFillOpacity : disabledSeparatedFillOpacity
    }

    func glowOpacity(isSeparated: Bool, canAct: Bool) -> Double {
        isSeparated && canAct ? separatedGlowOpacity : 0
    }
}
