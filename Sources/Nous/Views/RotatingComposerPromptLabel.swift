import Combine
import SwiftUI

struct RotatingComposerPromptLabel: View {
    let inputText: String
    let isFocused: Bool
    var horizontalPadding: CGFloat = 0

    @State private var promptIndex = 0

    private let prompt = RotatingComposerPrompt()
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    private var currentText: String {
        prompt.text(at: promptIndex)
    }

    private var shouldShow: Bool {
        prompt.shouldShow(inputText: inputText)
    }

    var body: some View {
        Group {
            if shouldShow {
                Text(currentText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.secondaryText.opacity(0.72))
                    .lineLimit(1)
                    .padding(.horizontal, horizontalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(currentText)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: shouldShow)
        .animation(.easeInOut(duration: 0.24), value: promptIndex)
        .onReceive(timer) { _ in
            guard prompt.shouldAdvance(inputText: inputText, isFocused: isFocused) else {
                return
            }

            withAnimation(.easeInOut(duration: 0.24)) {
                promptIndex = prompt.nextIndex(after: promptIndex)
            }
        }
    }
}
