import SwiftUI

struct FrameSpinner: View {
    let isAnimating: Bool

    private static let cellSize: CGFloat = 3
    private static let spacing: CGFloat = 1
    private static let stride: CGFloat = cellSize + spacing
    private static let totalSize: CGFloat = cellSize * 3 + spacing * 2
    private static let frameDuration: Double = 0.12

    // Border positions in clockwise order starting at top-left.
    private static let borderCells: [(col: Int, row: Int)] = [
        (0, 0), (1, 0), (2, 0),
        (2, 1),
        (2, 2), (1, 2), (0, 2),
        (0, 1)
    ]

    @State private var litIndex: Int = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.borderCells.enumerated()), id: \.offset) { index, cell in
                RoundedRectangle(cornerRadius: 1)
                    .fill(AppColor.colaOrange)
                    .opacity(opacity(for: index))
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

    private func opacity(for cellIndex: Int) -> Double {
        guard isAnimating else { return 0.5 }
        return cellIndex == litIndex ? 1.0 : 0.3
    }
}

#Preview {
    HStack(spacing: 12) {
        FrameSpinner(isAnimating: true)
        FrameSpinner(isAnimating: false)
    }
    .padding(40)
}
