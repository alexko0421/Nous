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

        // Mic RMS values land in roughly 0.05 - 0.25 for normal speech, so the
        // raw `level` is too compressed to read as motion. Apply a gain so a
        // typical speaking voice reaches the upper portion of the bar range.
        let amplifiedLevel = min(1.0, CGFloat(level) * Self.audioGain)

        // When the user is actually speaking, the baseline should fade out so
        // audio drives the motion instead of the sine clock. `quietness` is 1
        // during silence and goes to 0 as speech amplitude rises — multiplied
        // into the baseline amplitude so the breathing visibly recedes.
        let quietness = max(0.0, 1.0 - amplifiedLevel)
        let baselineEnvelope = 0.5 + 0.5 * sin(Double(i) * Self.phase + clock)
        let baselineAmplitude = (Self.maxHeight * Self.baselineFraction - Self.minHeight) * quietness
        let baseline = Self.minHeight + CGFloat(baselineEnvelope) * baselineAmplitude

        // Audio-driven envelope: per-bar offset so neighboring bars don't all
        // peak together — keeps the waveform looking like sound, not a block.
        let envelope = 0.6 + 0.4 * sin(Double(i) * Self.phase + clock)
        let audioDriven = amplifiedLevel * CGFloat(envelope) * Self.maxHeight

        return min(Self.maxHeight, max(baseline, audioDriven))
    }

    private static let audioGain: CGFloat = 3.0
    private static let baselineFraction: CGFloat = 0.2

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
