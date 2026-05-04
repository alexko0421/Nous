import SwiftUI
import Observation

/// Maps stable string IDs to the global frames of the SwiftUI views that registered them.
/// Views register via `.ghostCursorTarget(id:)`. Missing IDs return nil — overlay then
/// silently no-ops, matching the reference's "skip on null target" behavior.
@Observable
@MainActor
final class GhostCursorRegistry {
    private var frames: [String: CGRect] = [:]
    private var pulseTriggers: [String: UUID] = [:]

    /// Sets the registered frame for `id`. Last writer wins; if two views share an id,
    /// only the most recently rendered frame is reachable. `.ghostCursorTarget(id:)`
    /// is intended for stable, eagerly-rendered chrome (tabs, toolbar, capsule);
    /// avoid attaching it to views inside lazy containers (LazyVStack, recycled list
    /// cells), where mount/unmount ordering can cause brief stale-frame windows.
    func update(id: String, frame: CGRect) {
        frames[id] = frame
    }

    func remove(id: String) {
        frames.removeValue(forKey: id)
        pulseTriggers.removeValue(forKey: id)
    }

    func frame(for id: String) -> CGRect? {
        frames[id]
    }

    func center(for id: String) -> CGPoint? {
        guard let f = frames[id] else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }

    func pulseTrigger(for id: String) -> UUID? {
        pulseTriggers[id]
    }

    /// Triggers an arrival pulse animation on the registered target view.
    ///
    /// Coalesces calls within the ~180ms animation window — at most one pulse renders
    /// per animation cycle. Suitable for cursor-arrival feedback. Not suitable for
    /// rhythmic attention-getting effects that need every call to render distinctly.
    func pulse(id: String) {
        pulseTriggers[id] = UUID()
    }
}

extension View {
    func ghostCursorTarget(id: String) -> some View {
        modifier(GhostCursorTargetModifier(id: id))
    }
}

private struct GhostCursorTargetModifier: ViewModifier {
    let id: String
    @Environment(GhostCursorRegistry.self) private var registry: GhostCursorRegistry?

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: GhostCursorTargetFramePreferenceKey.self,
                            value: [GhostCursorTargetFrame(id: id, frame: proxy.frame(in: .global))]
                        )
                }
            )
            .overlay(GhostCursorTargetPulse(id: id))
            .onPreferenceChange(GhostCursorTargetFramePreferenceKey.self) { values in
                guard let registry else { return }
                for value in values where value.id == id {
                    registry.update(id: value.id, frame: value.frame)
                }
            }
            .onDisappear {
                registry?.remove(id: id)
            }
    }
}

private struct GhostCursorTargetFrame: Equatable, Sendable {
    let id: String
    let frame: CGRect
}

private struct GhostCursorTargetFramePreferenceKey: PreferenceKey {
    static var defaultValue: [GhostCursorTargetFrame] = []
    static func reduce(value: inout [GhostCursorTargetFrame], nextValue: () -> [GhostCursorTargetFrame]) {
        value.append(contentsOf: nextValue())
    }
}

private struct GhostCursorTargetPulse: View {
    let id: String
    @Environment(GhostCursorRegistry.self) private var registry: GhostCursorRegistry?
    @State private var pulse: Bool = false
    @State private var seenTrigger: UUID?

    var body: some View {
        Color.clear
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppColor.colaOrange.opacity(0.28), lineWidth: 3)
                    .blur(radius: 0.5)
                    .scaleEffect(pulse ? 1.06 : 1.0)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 0.18), value: pulse)
            )
            .allowsHitTesting(false)
            .onChange(of: registry?.pulseTrigger(for: id)) { _, newTrigger in
                guard let newTrigger, newTrigger != seenTrigger else { return }
                seenTrigger = newTrigger
                pulse = false
                Task { @MainActor in
                    // ~1 frame at 60Hz: lets the pulse=false reset commit before the
                    // pulse=true write triggers .animation(_:value:). Without this gap,
                    // SwiftUI sometimes coalesces both writes into one transaction and
                    // the ring disappears with no scale animation. Phase 3 live tests
                    // should validate this is still needed (vs an explicit Transaction
                    // disabling-animations + withAnimation pair).
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    pulse = true
                }
            }
    }
}
