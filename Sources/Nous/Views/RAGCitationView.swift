import SwiftUI

struct RAGCitationView: View {
    let citations: [SearchResult]
    @Binding var isExpanded: Bool
    var onOpenSource: (NousNode) -> Void = { _ in }
    @State private var hoveredNodeId: UUID?
    @State private var popoverNodeId: UUID?

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
                        // 单行 Citation，鼠标悬停时弹出 Popover 预览
                        Button {
                            onOpenSource(result.node)
                        } label: {
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

                                // Hover 提示 — 鼠标悬停时变橙色
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(
                                        hoveredNodeId == result.node.id
                                            ? AppColor.colaOrange
                                            : AppColor.secondaryText.opacity(0.4)
                                    )
                                    .animation(.easeOut(duration: 0.15), value: hoveredNodeId)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(
                                // Hover 时背景微高亮
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(
                                        hoveredNodeId == result.node.id
                                            ? AppColor.colaOrange.opacity(0.06)
                                            : Color.clear
                                    )
                                    .animation(.easeOut(duration: 0.15), value: hoveredNodeId)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovering in
                            hoveredNodeId = isHovering ? result.node.id : nil
                            // 延迟 120ms 后决定是否弹出，避免快速掠过也触发 popover
                            if isHovering {
                                let thisId = result.node.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                    if hoveredNodeId == thisId {
                                        popoverNodeId = thisId
                                    }
                                }
                            } else {
                                popoverNodeId = nil
                            }
                        }
                        // Quick Look Popover — 稳定悬停 120ms 后弹出预览浮窗
                        .popover(
                            isPresented: Binding(
                                get: { popoverNodeId == result.node.id },
                                set: { if !$0 { popoverNodeId = nil } }
                            ),
                            arrowEdge: .leading
                        ) {
                            citationPopover(for: result)
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
            if !expanded { hoveredNodeId = nil; popoverNodeId = nil }
        }
        .onChange(of: citationNodeIDs) { _, ids in
            if let hoveredNodeId, !ids.contains(hoveredNodeId) {
                self.hoveredNodeId = nil
            }
            if let popoverNodeId, !ids.contains(popoverNodeId) {
                self.popoverNodeId = nil
            }
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
        let label: String = switch node.type {
        case .conversation: "Chat"
        case .note: "Note"
        case .source: "Source"
        }
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

    // MARK: - Quick Look Popover 内容

    private func citationPopover(for result: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 顶部元信息
            HStack(spacing: 8) {
                typeBadge(for: result.node)
                Text(relative(result.node.createdAt))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)
                Spacer()
                if result.lane == .longGap {
                    infoBadge(
                        text: "Long-gap link",
                        tint: AppColor.colaOrange.opacity(0.12),
                        textColor: AppColor.colaOrange
                    )
                }
            }

            // 标题
            Text(result.node.title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(AppColor.colaDarkText)
                .lineLimit(2)

            // 内容 Snippet
            Text(result.surfacedSnippet)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(AppColor.colaDarkText.opacity(0.8))
                .lineSpacing(4)
                .lineLimit(8)
                .multilineTextAlignment(.leading)

            Divider()
                .overlay(AppColor.panelStroke)

            // 底部操作
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
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
