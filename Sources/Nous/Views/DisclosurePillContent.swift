import SwiftUI

struct DisclosurePillContent<Content: View>: View {
    let isExpanded: Bool
    let motion: DisclosurePillMotion
    let content: Content

    @State private var contentHeight: CGFloat = 0

    init(
        isExpanded: Bool,
        motion: DisclosurePillMotion = DisclosurePillMotion(),
        @ViewBuilder content: () -> Content
    ) {
        self.isExpanded = isExpanded
        self.motion = motion
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DisclosurePillContentHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )
            .offset(y: motion.contentOffsetY(isExpanded: isExpanded))
            .scaleEffect(x: 1, y: motion.contentScaleY(isExpanded: isExpanded), anchor: .top)
            .opacity(motion.contentOpacity(isExpanded: isExpanded))
            .blur(radius: motion.contentBlur(isExpanded: isExpanded))
            .frame(
                height: motion.visibleContentHeight(
                    fullHeight: contentHeight,
                    isExpanded: isExpanded
                ),
                alignment: .top
            )
            .clipped()
            .allowsHitTesting(isExpanded)
            .onPreferenceChange(DisclosurePillContentHeightKey.self) { height in
                contentHeight = height
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isExpanded)
            .animation(.easeOut(duration: 0.15), value: contentHeight)
    }
}

private struct DisclosurePillContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
