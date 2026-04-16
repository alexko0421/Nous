import SwiftUI

struct ClarificationCardView: View {
    let card: ClarificationCard
    let onOptionSelected: (String) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NativeGlassPanel(
            cornerRadius: 22,
            tintColor: AppColor.glassTint
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppColor.colaOrange)

                    Text("Choose One")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColor.secondaryText)
                }

                Text(card.question)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(card.options, id: \.self) { option in
                        Button(action: { onOptionSelected(option) }) {
                            Text(option)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText)
                                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                                .padding(.horizontal, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(AppColor.surfacePrimary)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(AppColor.panelStroke, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
    }
}
