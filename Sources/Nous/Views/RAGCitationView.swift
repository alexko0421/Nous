import SwiftUI

struct RAGCitationView: View {
    let citations: [SearchResult]
    var onTap: (NousNode) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(citations.prefix(3), id: \.node.id) { result in
                Button {
                    onTap(result.node)
                } label: {
                    HStack(spacing: 6) {
                        Text("📎")
                            .font(.caption)
                        Text(result.node.title)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(AppColor.colaDarkText)
                        Spacer()
                        Text("\(Int(result.similarity * 100))%")
                            .font(.caption2)
                            .foregroundStyle(AppColor.colaDarkText.opacity(0.6))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AppColor.colaDarkText.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
