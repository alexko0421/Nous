import CoreGraphics

enum RightPanelLayout {
    static let preferredWidth: CGFloat = 300
    static let defaultWindowWidth: CGFloat = 950
    static let defaultWindowHeight: CGFloat = 715
    static let minimumWindowWidth: CGFloat = 950
    static let minimumWindowHeight: CGFloat = 640
    static let windowPadding: CGFloat = 12

    private static let columnSpacing: CGFloat = 12

    static var minimumContentWidth: CGFloat {
        max(0, minimumWindowWidth - windowPadding * 2)
    }

    static var minimumContentHeight: CGFloat {
        max(0, minimumWindowHeight - windowPadding * 2)
    }

    static func estimatedOpenChatWidth(windowWidth: CGFloat, sidebarVisible: Bool) -> CGFloat {
        max(0, estimatedOpenContentWidth(windowWidth: windowWidth, sidebarVisible: sidebarVisible) - preferredWidth)
    }

    static func estimatedOpenChatShare(windowWidth: CGFloat, sidebarVisible: Bool) -> CGFloat {
        let contentWidth = estimatedOpenContentWidth(windowWidth: windowWidth, sidebarVisible: sidebarVisible)
        guard contentWidth > 0 else { return 0 }
        return estimatedOpenChatWidth(windowWidth: windowWidth, sidebarVisible: sidebarVisible) / contentWidth
    }

    static func estimatedOpenPanelShare(windowWidth: CGFloat, sidebarVisible: Bool) -> CGFloat {
        let contentWidth = estimatedOpenContentWidth(windowWidth: windowWidth, sidebarVisible: sidebarVisible)
        guard contentWidth > 0 else { return 0 }
        return preferredWidth / contentWidth
    }

    private static func estimatedOpenContentWidth(windowWidth: CGFloat, sidebarVisible: Bool) -> CGFloat {
        let sidebarWidth = sidebarVisible ? AppSidebarLayout.width : 0
        let visibleGaps: CGFloat = sidebarVisible ? 2 : 1
        return max(0, windowWidth - windowPadding * 2 - sidebarWidth - columnSpacing * visibleGaps)
    }
}
