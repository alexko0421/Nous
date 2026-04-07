import SwiftUI

struct AppColor {
    // Warm off-white/beige from ColaOS
    static let colaBeige = Color(red: 253/255, green: 251/255, blue: 247/255) 
    
    // Vibrant earthy orange from ColaOS logo
    static let colaOrange = Color(red: 243/255, green: 131/255, blue: 53/255) 
    
    // Dark text for contrast on beige
    static let colaDarkText = Color(red: 51/255, green: 51/255, blue: 51/255)
    
    // Slightly darker beige for user chat bubbles
    static let colaBubble = Color(red: 240/255, green: 235/255, blue: 225/255)
    
    // System ultra thin material for the premium blur
    // In SwiftUI we use `.ultraThinMaterial` directly where needed.
}
