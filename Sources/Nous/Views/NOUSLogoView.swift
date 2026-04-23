import SwiftUI

struct NOUSLogoView: View {
    var logoColor: Color = AppColor.colaOrange

    var body: some View {
        // Find the image in the main bundle
        if let path = Bundle.main.path(forResource: "nous_logo_transparent", ofType: "png"),
           let nsImage = NSImage(contentsOfFile: path) {
            
            Image(nsImage: nsImage)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundColor(logoColor)
                
        } else {
            // Fallback if the image is missing
            Text("NOUS")
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .foregroundColor(logoColor)
        }
    }
}
