import SwiftUI

struct FrameSpinner: View {
    let isAnimating: Bool

    private static let cellSize: CGFloat = 4
    private static let spacing: CGFloat = 1
    private static let stride: CGFloat = cellSize + spacing
    private static let totalSize: CGFloat = cellSize * 3 + spacing * 2
    private static let frameDuration: Double = 0.11

    // Border positions in clockwise order starting at top-left.
    private static let borderCells: [(col: Int, row: Int)] = [
        (0, 0), (1, 0), (2, 0),
        (2, 1),
        (2, 2), (1, 2), (0, 2),
        (0, 1)
    ]

    // Per-cell (alpha, glow) for distance-from-head around the ring.
    // Index = distance back from the currently-lit head cell.
    private static let trail: [(alpha: Double, glow: Double)] = [
        (1.00, 0.95),  // head: brightest + strongest bloom
        (0.75, 0.55),  // +1 trailing
        (0.50, 0.28),  // +2 trailing
        (0.30, 0.00)   // dark ring cells
    ]

    @State private var litIndex: Int = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.borderCells.enumerated()), id: \.offset) { index, cell in
                let intensity = intensity(for: index)
                RoundedRectangle(cornerRadius: 1)
                    .fill(AppColor.colaOrange)
                    .opacity(intensity.alpha)
                    // SwiftUI shadow doubles as a bloom: warm colaOrange halo
                    // bleeds past the pixel edge, matching the reference's
                    // emissive pixel-art look without losing crisp corners.
                    .shadow(color: AppColor.colaOrange.opacity(intensity.glow), radius: 2.5)
                    .frame(width: Self.cellSize, height: Self.cellSize)
                    .offset(
                        x: CGFloat(cell.col) * Self.stride,
                        y: CGFloat(cell.row) * Self.stride
                    )
            }
        }
        .frame(width: Self.totalSize, height: Self.totalSize, alignment: .topLeading)
        // `.task(id:)` ties the animation loop to the view's lifetime and restarts
        // when `isAnimating` flips. The task is auto-cancelled on view removal or
        // id change, so there are no zombie loops reading stale state.
        .task(id: isAnimating) {
            guard isAnimating else { return }
            let nanos = UInt64(Self.frameDuration * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                litIndex = (litIndex + 1) % Self.borderCells.count
            }
        }
    }

    private func intensity(for cellIndex: Int) -> (alpha: Double, glow: Double) {
        guard isAnimating else { return (0.35, 0.0) }
        let count = Self.borderCells.count
        let distance = (litIndex - cellIndex + count) % count
        let clamped = min(distance, Self.trail.count - 1)
        return Self.trail[clamped]
    }
}

#Preview {
    HStack(spacing: 12) {
        FrameSpinner(isAnimating: true)
        FrameSpinner(isAnimating: false)
    }
    .padding(40)
}
