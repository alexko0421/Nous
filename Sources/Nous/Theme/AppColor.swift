import AppKit
import SwiftUI

struct AppColor {
    private static func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
            case .darkAqua?:
                dark
            default:
                light
            }
        }
    }

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    // Warm off-white/beige from ColaOS
    static let colaBeige = dynamicColor(
        light: NSColor(red: 253/255, green: 251/255, blue: 247/255, alpha: 1),
        dark: NSColor(red: 24/255, green: 24/255, blue: 26/255, alpha: 1)
    )
    
    // Vibrant earthy orange from ColaOS logo (softened to amber in dark mode)
    static let colaOrange = dynamicColor(
        light: NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 1),
        dark: NSColor(red: 217/255, green: 131/255, blue: 65/255, alpha: 1) // #D98341
    )
    
    // Dark text for contrast on beige
    static let colaDarkText = dynamicColor(
        light: NSColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 1),
        dark: NSColor(red: 244/255, green: 240/255, blue: 232/255, alpha: 1)
    )
    
    // Slightly darker beige for user chat bubbles
    static let colaBubble = dynamicColor(
        light: NSColor(red: 240/255, green: 235/255, blue: 225/255, alpha: 1),
        dark: NSColor(red: 46/255, green: 46/255, blue: 49/255, alpha: 1)
    )

    static let surfacePrimary = dynamicColor(
        light: NSColor(white: 1, alpha: 0.88),
        dark: NSColor(white: 0.18, alpha: 0.92)
    )
    static let surfaceSecondary = dynamicColor(
        light: NSColor(white: 1, alpha: 0.72),
        dark: NSColor(white: 0.22, alpha: 0.88)
    )
    static let subtleFill = dynamicColor(
        light: NSColor(white: 0, alpha: 0.04),
        dark: NSColor(white: 1, alpha: 0.07)
    )
    static let panelStroke = dynamicColor(
        light: NSColor(white: 0.2, alpha: 0.08),
        dark: NSColor(white: 1, alpha: 0.12)
    )
    static let secondaryText = dynamicColor(
        light: NSColor(white: 0.2, alpha: 0.62),
        dark: NSColor(white: 1, alpha: 0.70)
    )
    static let welcomeGradientStart = dynamicColor(
        light: NSColor(white: 1, alpha: 1),
        dark: NSColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 1)
    )
    static let welcomeGradientEnd = dynamicColor(
        light: NSColor(red: 253/255, green: 251/255, blue: 247/255, alpha: 1),
        dark: NSColor(red: 20/255, green: 20/255, blue: 22/255, alpha: 1)
    )
    static let ambientHighlight = dynamicColor(
        light: NSColor(white: 1, alpha: 0.95),
        dark: NSColor(white: 1, alpha: 0.08)
    )
    static let glassTint = dynamicNSColor(
        light: NSColor(white: 0, alpha: 0.06),
        dark: NSColor(red: 34/255, green: 34/255, blue: 37/255, alpha: 0.20)
    )
    static let composerGlassTint = dynamicNSColor(
        light: NSColor(white: 1, alpha: 0.22),
        dark: NSColor(red: 72/255, green: 72/255, blue: 78/255, alpha: 0.24)
    )
    
    // 专门为茶色玻璃效果设计嘅 Tint Color (Tea/Brown Glass)
    static let teaGlassTint = dynamicNSColor(
        light: NSColor(red: 210/255, green: 160/255, blue: 110/255, alpha: 0.15), // 浅色模式：淡茶色/琥珀色透光
        dark: NSColor(red: 90/255, green: 50/255, blue: 30/255, alpha: 0.30)      // 深色模式：深红茶色透光
    )
    
    // 用于 Preview/Write 切换按钮的茶色 (琥珀色) 高亮
    static let teaPillColor = dynamicColor(
        light: NSColor(red: 210/255, green: 160/255, blue: 110/255, alpha: 0.8),
        dark: NSColor(red: 140/255, green: 80/255, blue: 45/255, alpha: 0.7)
    )
    
    // System ultra thin material for the premium blur
    // In SwiftUI we use `.ultraThinMaterial` directly where needed.

    // Galaxy dark theme
    static let galaxyBackground = Color(red: 26/255, green: 26/255, blue: 46/255)
    static let galaxyNodeGlow = Color(red: 243/255, green: 131/255, blue: 53/255)

    // Welcome/chat dark theme
    static let inkBackground = Color(red: 24/255, green: 24/255, blue: 26/255)
    static let inkPanel = Color(red: 31/255, green: 31/255, blue: 33/255)
    static let inkPanelRaised = Color(red: 42/255, green: 42/255, blue: 45/255)
    static let inkStroke = Color.white.opacity(0.10)
    static let inkText = Color(red: 244/255, green: 240/255, blue: 232/255)
    static let inkMuted = Color.white.opacity(0.54)
}
