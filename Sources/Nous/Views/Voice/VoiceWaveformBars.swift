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

    @State private var clock: Double = 0
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: Self.barGap) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: Self.barWidth / 2)
                    .fill(barColor)
                    .frame(width: Self.barWidth, height: barHeight(forIndex: i))
                    .animation(.spring(response: 0.18, dampingFraction: 0.7), value: barHeight(forIndex: i))
                    .animation(.easeInOut(duration: 0.14), value: state)
            }
        }
        .onReceive(timer) { _ in
            guard !reduceMotion else { return }
            clock += 1.0 / 30.0
        }
    }

    private func barHeight(forIndex i: Int) -> CGFloat {
        if reduceMotion { return Self.minHeight + 6 }
        if state == .idle || state == .error { return Self.minHeight }

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
