import SpriteKit
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Soft Morandi cloud patches drawn behind everything else in the Galaxy
/// scene. Atmosphere only — fades in as the user zooms out, fades to
/// near-zero when zoomed in. Deterministic per node-count seed so the
/// pattern stays stable across renders.
///
/// Implementation: each layer is one SKSpriteNode tinted to its Morandi
/// color, sharing a precomputed circular radial-gradient texture with a
/// 4-stop alpha falloff (peak / peak·0.65 / peak·0.2 / 0). Ellipse shape
/// comes from non-uniform sprite scaling (xScale/yScale). Mirrors
/// Principia's canvas createRadialGradient approach (file:1413-1418
/// of GalaxyMapViewPhysics.tsx).
enum NebulaLayer {
    /// One-time radial-gradient texture: white pixel with alpha falloff
    /// 1.0 → 0.65 (at 35%) → 0.20 (at 65%) → 0 (at edge). Sprites tint
    /// this with their Morandi color via colorBlendFactor.
    static let radialGradientTexture: SKTexture = makeRadialGradientTexture()

    /// Texture radius in pixels — sprites scale x/y from this base.
    /// Higher resolution (was 256) gives smoother filtering when sprites
    /// are stretched to large ellipses on screen.
    private static let textureRadius: CGFloat = 512

    /// Post-gradient Gaussian blur radius. The 4-stop curve already gives
    /// shape; this softens the discrete stops into a continuous falloff
    /// without visible "rings". Mirrors HaloTexture's approach.
    private static let postGradientBlur: CGFloat = 24

    private static func makeRadialGradientTexture() -> SKTexture {
        let size = CGSize(width: textureRadius * 2, height: textureRadius * 2)

        // Step 1 — render the 4-stop radial gradient
        let gradientImage = NSImage(size: size)
        gradientImage.lockFocusFlipped(false)
        if let ctx = NSGraphicsContext.current?.cgContext {
            let center = CGPoint(x: textureRadius, y: textureRadius)
            let stops: [CGFloat] = [0.0, 0.35, 0.65, 1.0]
            let colors = [
                NSColor(white: 1, alpha: 1.00).cgColor,
                NSColor(white: 1, alpha: 0.65).cgColor,
                NSColor(white: 1, alpha: 0.20).cgColor,
                NSColor(white: 1, alpha: 0.00).cgColor,
            ] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let grad = CGGradient(colorsSpace: space, colors: colors, locations: stops) {
                ctx.drawRadialGradient(
                    grad,
                    startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: textureRadius,
                    options: []
                )
            }
        }
        gradientImage.unlockFocus()

        // Step 2 — Gaussian blur the gradient for extra softness. The discrete
        // 4-stop curve gives the falloff; blur erases any visible ring banding
        // and adds atmospheric softness.
        guard
            let tiff = gradientImage.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let cg = bitmap.cgImage
        else {
            return SKTexture(image: gradientImage)
        }
        let ciImage = CIImage(cgImage: cg)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = ciImage
        blur.radius = Float(postGradientBlur)

        let context = CIContext(options: nil)
        // Clip to original extent so the blur doesn't bleed past the texture
        // bounds (would otherwise inflate sprite size invisibly).
        guard
            let output = blur.outputImage,
            let blurredCG = context.createCGImage(output, from: ciImage.extent)
        else {
            return SKTexture(image: gradientImage)
        }
        let blurred = NSImage(cgImage: blurredCG, size: size)
        let texture = SKTexture(image: blurred)
        texture.filteringMode = .linear
        return texture
    }

    /// The texture's diameter in points — useful when sizing sprites.
    static var textureDiameter: CGFloat { textureRadius * 2 }

    /// Seven Morandi cloud colors (RGB 0-255).
    private static let palette: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (168, 147, 124),  // Dusty Camel
        (143, 163, 160),  // Muted Teal
        (184, 160, 166),  // Dusty Rose
        (155, 142, 168),  // Lavender Grey
        (126, 154, 138),  // Sage
        (179, 139, 122),  // Terracotta
        (123, 160, 154),  // Jade Mist
    ]

    struct PatchLayer {
        let offsetX: CGFloat
        let offsetY: CGFloat
        let radiusX: CGFloat
        let radiusY: CGFloat
        let rotation: CGFloat
        let color: SKColor
        let peakOpacity: CGFloat
    }

    struct Patch {
        let centerX: CGFloat
        let centerY: CGFloat
        let layers: [PatchLayer]
    }

    /// Deterministic [0,1) hash from (seed, i).
    private static func seededRandom(seed: Int, i: Int) -> CGFloat {
        let x = sin(Double(seed) * 9301 + Double(i) * 49297 + 0.1) * 49979
        return CGFloat(x - floor(x))
    }

    /// Free-distribution patches. nodeCount drives the seed (determinism);
    /// extentRadius is half of the larger scene-axis dimension (so patches
    /// land roughly within where nodes ended up after layout).
    static func freeDistributionPatches(nodeCount: Int, extentRadius: CGFloat) -> [Patch] {
        let seed = max(nodeCount, 1)
        let patchCount = seed % 2 == 0 ? 3 : 4
        let baseRadius = extentRadius * 0.6  // each patch reaches ~60% of extent

        // Fixed relative placements (mirrors §21.8 placements array).
        let placements: [(rx: CGFloat, ry: CGFloat, scale: CGFloat)] = [
            (-0.2, -0.15, 1.2),
            ( 0.25,  0.2, 1.0),
            (-0.1,  0.3, 0.85),
            ( 0.3, -0.25, 0.9),
        ]

        var patches: [Patch] = []
        for p in 0..<patchCount {
            let pl = placements[p]
            let cx = extentRadius * pl.rx + extentRadius * 0.08 * (seededRandom(seed: seed, i: p * 7) - 0.5)
            let cy = extentRadius * pl.ry + extentRadius * 0.08 * (seededRandom(seed: seed, i: p * 13) - 0.5)
            let baseColor = palette[p % palette.count]
            let secondaryColor = palette[(p + 3) % palette.count]
            let r = baseRadius * pl.scale
            let mainRotation = seededRandom(seed: seed, i: p * 11) * .pi

            let mkColor = { (c: (CGFloat, CGFloat, CGFloat)) -> SKColor in
                SKColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
            }

            let layers: [PatchLayer] = [
                PatchLayer(
                    offsetX: 0, offsetY: 0,
                    radiusX: r * (0.8 + seededRandom(seed: seed, i: p * 3) * 0.4),
                    radiusY: r * (0.25 + seededRandom(seed: seed, i: p * 5) * 0.15),
                    rotation: mainRotation,
                    color: mkColor(baseColor),
                    peakOpacity: 0.13
                ),
                PatchLayer(
                    offsetX: r * 0.15 * (seededRandom(seed: seed, i: p * 17) - 0.5),
                    offsetY: r * 0.12 * (seededRandom(seed: seed, i: p * 19) - 0.5),
                    radiusX: r * (0.55 + seededRandom(seed: seed, i: p * 23) * 0.25),
                    radiusY: r * (0.18 + seededRandom(seed: seed, i: p * 29) * 0.12),
                    rotation: mainRotation + 0.3 + seededRandom(seed: seed, i: p * 47) * 0.2,
                    color: mkColor(secondaryColor),
                    peakOpacity: 0.09
                ),
                PatchLayer(
                    offsetX: r * 0.04 * (seededRandom(seed: seed, i: p * 31) - 0.5),
                    offsetY: r * 0.04 * (seededRandom(seed: seed, i: p * 37) - 0.5),
                    radiusX: r * 0.22,
                    radiusY: r * 0.10,
                    rotation: mainRotation + 0.1,
                    color: mkColor(baseColor),
                    peakOpacity: 0.20
                ),
                PatchLayer(
                    offsetX: r * 0.08 * (seededRandom(seed: seed, i: p * 41) - 0.5),
                    offsetY: r * 0.08 * (seededRandom(seed: seed, i: p * 43) - 0.5),
                    radiusX: r * 1.10,
                    radiusY: r * 0.40,
                    rotation: mainRotation - 0.15,
                    color: mkColor(baseColor),
                    peakOpacity: 0.04
                ),
            ]
            patches.append(Patch(centerX: cx, centerY: cy, layers: layers))
        }
        return patches
    }

    /// Alpha multiplier based on camera zoom. cameraScale is `cameraNode.xScale`.
    /// Mirrors Principia's smoothstep curve over the 0.85→0.35 vis-network
    /// scale range (≈ 1.18→2.86 in SpriteKit camera scale, since vis-network
    /// scale is the inverse of SpriteKit camera scale).
    ///
    /// At cameraScale ≤ 1.18 → 0% (invisible at default zoom).
    /// At cameraScale ≥ 2.86 → 100% (fully visible at max zoom-out).
    /// Smoothstep between gives a gentler ease than the previous linear
    /// curve — no abrupt onset right after the user starts zooming out.
    static func alphaForZoom(cameraScale: CGFloat) -> CGFloat {
        let lo: CGFloat = 1.18
        let hi: CGFloat = 2.86
        let t = max(0, min(1, (cameraScale - lo) / (hi - lo)))
        // smoothstep: t² × (3 - 2t)
        return t * t * (3 - 2 * t)
    }
}
