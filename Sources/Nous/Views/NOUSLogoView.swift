import SwiftUI

struct NOUSLogoView: View {
    var logoColor: Color = AppColor.colaOrange

    @State private var isAppearing = false

    var body: some View {
        // Find the image in the main bundle
        if let path = Bundle.main.path(forResource: "nous_logo_transparent", ofType: "png"),
           let nsImage = NSImage(contentsOfFile: path) {
            
            Image(nsImage: nsImage)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundColor(logoColor)
                // 1. 微光影 (Ambient Glow)：令佢有种通电发光、嵌入玻璃嘅感觉
                .shadow(color: logoColor.opacity(0.4), radius: 12, x: 0, y: 4)
                // 2. 微动效 (Micro-animation)：出场弹性缩放
                .scaleEffect(isAppearing ? 1.0 : 0.92)
                .opacity(isAppearing ? 1.0 : 0.0)
                .onAppear {
                    withAnimation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.1)) {
                        isAppearing = true
                    }
                }
                
        } else {
            // Fallback if the image is missing
            Text("NOUS")
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .foregroundColor(logoColor)
        }
    }
}
