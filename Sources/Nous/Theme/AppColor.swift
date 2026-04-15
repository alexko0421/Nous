import SwiftUI

struct AppColor {
    // Warm off-white/beige — adapts to dark mode
    static let colaBeige = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 30/255, green: 30/255, blue: 32/255, alpha: 1)
            : NSColor(red: 253/255, green: 251/255, blue: 247/255, alpha: 1)
    })

    // Vibrant earthy orange — same in both modes
    static let colaOrange = Color(red: 243/255, green: 131/255, blue: 53/255)

    // Text color — adapts to dark mode
    static let colaDarkText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 235/255, green: 235/255, blue: 240/255, alpha: 1)
            : NSColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 1)
    })

    // User chat bubble — adapts to dark mode
    static let colaBubble = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 55/255, green: 55/255, blue: 58/255, alpha: 1)
            : NSColor(red: 240/255, green: 235/255, blue: 225/255, alpha: 1)
    })

    // Galaxy
    static let galaxyBackground = Color(red: 26/255, green: 26/255, blue: 46/255)
    static let galaxyNodeGlow = Color(red: 243/255, green: 131/255, blue: 53/255)
}
