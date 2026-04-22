import SwiftUI
import AppKit

/// 1. Pure Optical Blur: A custom NSVisualEffectView tuned for maximum purity
/// We use the `.hudWindow` or `.popover` material to get a cleaner blur with less system tint,
/// and ensure it stays behind the window contents or acts as a clear backdrop.
fileprivate struct PureBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // .hudWindow often has less noise and a darker, more pure blur in dark mode
        // .popover or .selection can also be very clean. We use .hudWindow for a deep liquid feel.
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

public struct LiquidCrystalModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // LAYER 1 & 3: Base Background & Pure Optical Blur
                    // Using our custom PureBlurView to get a cleaner blur than standard materials
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.clear)
                        .background(PureBlurView())
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    
                    // LAYER 2: Color Enhancement (Saturation & Brightness)
                    // We use an overlay with a specific blend mode to enrich the colors coming through
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.05 : 0.2),
                                    Color.white.opacity(0.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.overlay)
                    
                    // (Optional inner shadow for the 'liquid' volume)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.black.opacity(colorScheme == .dark ? 0.4 : 0.1), lineWidth: 4)
                        .blur(radius: 4)
                        .offset(y: -2)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .blendMode(.multiply)
                }
            )
            // LAYER 4: Refraction Layer (Simulated via an inner stroke offset)
            // Simulates light bending around the curved edge of the glass
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.15 : 0.6), lineWidth: 3)
                    .blur(radius: 2)
                    .offset(y: 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            // LAYER 5: Specular Edge Highlights
            // The crisp 0.5px line that catches the light
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.4 : 0.9), // Core highlight
                                Color.white.opacity(colorScheme == .dark ? 0.05 : 0.1), // Fade out
                                Color.clear,
                                Color.white.opacity(colorScheme == .dark ? 0.1 : 0.3)  // Bottom edge bounce light
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            // Deep Floating Drop Shadows to complete the physical feel
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.5 : 0.15),
                radius: 24,
                x: 0,
                y: 12
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.06),
                radius: 6,
                x: 0,
                y: 3
            )
    }
}

public extension View {
    /// Applies the 5-layer Liquid Crystal effect
    func liquidCrystal(cornerRadius: CGFloat) -> some View {
        self.modifier(LiquidCrystalModifier(cornerRadius: cornerRadius))
    }
}
