import SpriteKit
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// One-time pre-blurred halo texture cache. Lavender-mist radial gradient
/// with Gaussian blur baked in, cached as a static so SpriteKit can
/// composite cheap sprite quads at render time instead of running
/// CIGaussianBlur every frame.
///
/// Used by GalaxyScene halo rendering (Task 19) — one SKSpriteNode per
/// constellation member, all sharing this texture. When sprites overlap
/// (because constellation members are spatially clustered), the texture's
/// soft alpha falloff visually merges them into an organic cloud.
enum HaloTexture {
    static let lavenderMistRGB: (r: CGFloat, g: CGFloat, b: CGFloat) = (155 / 255, 142 / 255, 196 / 255)
    static let radius: CGFloat = 70
    static let blurRadius: CGFloat = 24

    /// Lazily built once on first access. Subsequent accesses return the
    /// same SKTexture instance — sprites can share it freely.
    static let cached: SKTexture = build()

    private static func build() -> SKTexture {
        let size = CGSize(
            width: radius * 2 + blurRadius * 2,
            height: radius * 2 + blurRadius * 2
        )

        // Step 1: render radial gradient into an NSImage
        let gradientImage = NSImage(size: size)
        gradientImage.lockFocusFlipped(false)
        if let ctx = NSGraphicsContext.current?.cgContext {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let colors = [
                NSColor(
                    red: lavenderMistRGB.r,
                    green: lavenderMistRGB.g,
                    blue: lavenderMistRGB.b,
                    alpha: 0.85
                ).cgColor,
                NSColor(
                    red: lavenderMistRGB.r,
                    green: lavenderMistRGB.g,
                    blue: lavenderMistRGB.b,
                    alpha: 0.0
                ).cgColor
            ] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(
                    gradient,
                    startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: radius,
                    options: []
                )
            }
        }
        gradientImage.unlockFocus()

        // Step 2: apply Gaussian blur via Core Image (one-time, not per frame)
        guard
            let tiff = gradientImage.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let cg = bitmap.cgImage
        else {
            // Fallback: return un-blurred texture
            return SKTexture(image: gradientImage)
        }

        let ciImage = CIImage(cgImage: cg)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = ciImage
        blur.radius = Float(blurRadius)

        let context = CIContext(options: nil)
        guard
            let output = blur.outputImage,
            // Clip to ciImage.extent (not output.extent) to keep texture bounds stable.
            // Gaussian blur expands bounds; rendering with original extent loses a tiny
            // amount of the blur halo at edges — acceptable since alpha is already 0
            // at the gradient edge. Switch to output.extent if QA shows visible cropping.
            let blurredCG = context.createCGImage(output, from: ciImage.extent)
        else {
            return SKTexture(image: gradientImage)
        }

        let blurredImage = NSImage(cgImage: blurredCG, size: size)
        return SKTexture(image: blurredImage)
    }
}
