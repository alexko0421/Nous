import SwiftUI

struct RAGCitationView: View {
    let citations: [SearchResult]
    @Binding var isExpanded: Bool
    var onOpenSource: (NousNode) -> Void = { _ in }
    @State private var previewNodeId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.secondaryText)

                    Text(resultCountLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.secondaryText)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(AppColor.secondaryText)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppColor.subtleFill)
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(citations.enumerated()), id: \.element.node.id) { index, result in
                        Button {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                                previewNodeId = previewNodeId == result.node.id ? nil : result.node.id
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .center, spacing: 8) {
                                    Text(result.node.title)
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(AppColor.colaDarkText)
                                        .lineLimit(1)

                                    Spacer(minLength: 8)

                                    typeBadge(for: result.node)

                                    if result.lane == .longGap {
                                        infoBadge(
                                            text: "Long-gap link",
                                            tint: AppColor.colaOrange.opacity(0.14),
                                            textColor: AppColor.colaOrange
                                        )
                                    }
                                }

                                let collapsedSnippet = String(result.surfacedSnippet.prefix(140))
                                if !collapsedSnippet.isEmpty {
                                    Text(collapsedSnippet)
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundStyle(AppColor.secondaryText)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if previewNodeId == result.node.id {
                            citationPreview(for: result)
                                .padding(.horizontal, 18)
                                .padding(.bottom, 14)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if index < citations.count - 1 {
                            Divider()
                                .padding(.leading, 18)
                                .overlay(AppColor.panelStroke)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppColor.surfaceSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(AppColor.panelStroke, lineWidth: 1)
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                previewNodeId = nil
            }
        }
        .onChange(of: citationNodeIDs) { _, ids in
            guard let previewNodeId, !ids.contains(previewNodeId) else { return }
            self.previewNodeId = nil
        }
    }

    private var resultCountLabel: String {
        citations.count == 1 ? "1 result" : "\(citations.count) results"
    }

    private var citationNodeIDs: [UUID] {
        citations.map(\.node.id)
    }

    @ViewBuilder
    private func typeBadge(for node: NousNode) -> some View {
        let label = node.type == .conversation ? "Chat" : "Note"
        infoBadge(
            text: label,
            tint: AppColor.colaDarkText.opacity(0.06),
            textColor: AppColor.secondaryText
        )
    }

    private func infoBadge(text: String, tint: Color, textColor: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(textColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(tint)
            )
    }

    private func citationPreview(for result: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(result.node.type == .conversation ? "From chat" : "From note")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)

                Text(relative(result.node.createdAt))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText.opacity(0.9))

                Spacer()

                if result.lane == .longGap {
                    infoBadge(
                        text: "Pulled across time",
                        tint: AppColor.colaOrange.opacity(0.12),
                        textColor: AppColor.colaOrange
                    )
                }
            }

            Text(result.surfacedSnippet)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(AppColor.colaDarkText.opacity(0.84))
                .lineSpacing(3)
                .lineLimit(6)
                .multilineTextAlignment(.leading)

            Button {
                onOpenSource(result.node)
            } label: {
                HStack(spacing: 6) {
                    Text("Open source")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(AppColor.colaOrange)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(AppColor.colaOrange.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppColor.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
