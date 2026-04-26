import SpriteKit

/// Soft Morandi cloud patches drawn behind everything else in the Galaxy
/// scene. Atmosphere only — fades in as the user zooms out, fades to
/// near-zero when zoomed in. Deterministic per node-count seed so the
/// pattern stays stable across renders.
///
/// Source: ported from Principia's GalaxyMapViewPhysics nebula code
/// (§8 + §21.7 + §21.8 of the Principia design spec).
enum NebulaLayer {
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
    /// 1.0 (default) → 0% (invisible). 2.8 (max out) → 100%. Clamped.
    static func alphaForZoom(cameraScale: CGFloat) -> CGFloat {
        let t = (cameraScale - 1.0) / (2.8 - 1.0)
        return max(0, min(1, t))
    }
}
