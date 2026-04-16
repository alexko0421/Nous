import SwiftUI

struct WelcomeView<Composer: View>: View {
    let onQuickAction: (String) -> Void
    private let composer: Composer

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private let quickActions: [(icon: String, label: String, prompt: String)] = [
        ("building.2", "Business", "Help me think through a business decision."),
        ("safari", "Direction", "I need clarity on what direction to take next."),
        ("brain", "Brain Storm", "Let's brainstorm from first principles."),
        ("heart.text.square", "Mental Health", "Help me untangle what I'm feeling."),
    ]

    init(
        onQuickAction: @escaping (String) -> Void = { _ in },
        @ViewBuilder composer: () -> Composer
    ) {
        self.onQuickAction = onQuickAction
        self.composer = composer()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 4) {
                Text("NOUS")
                    .font(.system(size: 72, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaOrange)
                    .padding(.bottom, 4)

                Text("\(greeting), Alex!")
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
            }
            .padding(.bottom, 40)

            composer
                .frame(maxWidth: 620)
                .padding(.horizontal, 48)
                .padding(.bottom, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(quickActions, id: \.label) { action in
                        Button(action: { onQuickAction(action.prompt) }) {
                            HStack(spacing: 6) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(action.label)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                            }
                            .foregroundColor(AppColor.colaDarkText.opacity(0.65))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.55))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(AppColor.colaDarkText.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 48)
            }
            .frame(height: 38)

            Spacer()
        }
    }
}
