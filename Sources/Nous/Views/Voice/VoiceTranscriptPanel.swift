import SwiftUI

struct VoiceTranscriptPanel: View {
    let lines: [VoiceTranscriptLine]
    let isVisible: Bool

    @State private var userIsScrolling: Bool = false

    var body: some View {
        if isVisible && !lines.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(lines) { line in
                            bubble(for: line)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("__bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .frame(maxWidth: 480)
                .frame(maxHeight: 360)
                .background(
                    NativeGlassPanel(cornerRadius: 14, tintColor: AppColor.surfaceGlassTint) { EmptyView() }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppColor.colaOrange.opacity(0.18), lineWidth: 1)
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeOut(duration: 0.22), value: isVisible)
                .onChange(of: lines.count) { _, _ in
                    if !userIsScrolling {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("__bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: lines.last?.text) { _, _ in
                    if !userIsScrolling {
                        proxy.scrollTo("__bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(for line: VoiceTranscriptLine) -> some View {
        HStack(spacing: 0) {
            if line.role == .user { Spacer(minLength: 40) }
            VStack(alignment: line.role == .user ? .trailing : .leading, spacing: 4) {
                Text(line.role == .user ? "YOU" : "NOUS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                Text(line.text)
                    .font(.body)
                    .foregroundStyle(line.isFinal ? Color.primary : Color.primary.opacity(0.7))
                    .multilineTextAlignment(line.role == .user ? .trailing : .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(line.role == .user
                                  ? Color.clear
                                  : AppColor.colaOrange.opacity(0.04))
                    )
            }
            if line.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

#Preview("Multi-turn") {
    VoiceTranscriptPanel(
        lines: [
            VoiceTranscriptLine(role: .user, text: "Open Galaxy.", isFinal: true, createdAt: Date()),
            VoiceTranscriptLine(role: .assistant, text: "Opening Galaxy now.", isFinal: true, createdAt: Date()),
            VoiceTranscriptLine(role: .user, text: "Show my recent thoughts on Path B.", isFinal: true, createdAt: Date()),
            VoiceTranscriptLine(role: .assistant, text: "Searching memory…", isFinal: false, createdAt: Date()),
        ],
        isVisible: true
    )
    .padding()
    .frame(width: 600, height: 500)
}
