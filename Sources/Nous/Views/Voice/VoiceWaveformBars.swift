import SwiftUI

/// Five vertical bars whose heights are driven by a 0...1 audio level. Center-weighted
/// envelope so middle bars peak higher, giving a "breathing" feel. Color is state-driven.
struct VoiceWaveformBars: View {
    enum BarState: Equatable {
        case idle
        case listening
        case thinking
        case error
    }

    let level: Float                    // 0.0 ... 1.0
    let state: BarState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barCount = 5
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 2
    private static let minHeight: CGFloat = 4
    private static let maxHeight: CGFloat = 22
    private static let phase: Double = 0.85

    private var isAnimating: Bool {
        !reduceMotion && (state == .listening || state == .thinking)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { context in
            let clock = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: Self.barGap) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: Self.barWidth / 2)
                        .fill(barColor)
                        .frame(width: Self.barWidth, height: barHeight(forIndex: i, clock: clock))
                }
            }
            .animation(.easeInOut(duration: 0.14), value: state)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    private func barHeight(forIndex i: Int, clock: Double) -> CGFloat {
        // Idle and error always show the spec's flat 4pt baseline, regardless of motion mode.
        if state == .idle || state == .error { return Self.minHeight }
        // Reduce-motion still distinguishes "active" (listening/thinking) from idle/error
        // by sitting at a stable 10pt midline rather than animating.
        if reduceMotion { return Self.minHeight + 6 }

        let envelope = 0.6 + 0.4 * sin(Double(i) * Self.phase + clock)
        let raw = CGFloat(level) * CGFloat(envelope) * Self.maxHeight
        return min(Self.maxHeight, max(Self.minHeight, raw))
    }

    private var barColor: Color {
        switch state {
        case .idle:      return AppColor.colaOrange.opacity(0.28)
        case .listening: return AppColor.colaOrange
        case .thinking:  return AppColor.colaOrange.opacity(0.6)
        case .error:     return Color.red
        }
    }

    private var accessibilityLabel: Text {
        switch state {
        case .idle:      return Text("Voice idle")
        case .listening: return Text("Listening")
        case .thinking:  return Text("Thinking")
        case .error:     return Text("Voice error")
        }
    }
}

#Preview("Listening high level") {
    VoiceWaveformBars(level: 0.9, state: .listening).padding()
}

#Preview("Idle") {
    VoiceWaveformBars(level: 0.0, state: .idle).padding()
}

#Preview("Thinking") {
    VoiceWaveformBars(level: 0.4, state: .thinking).padding()
}

#Preview("Error") {
    VoiceWaveformBars(level: 0.0, state: .error).padding()
}
