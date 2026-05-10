import SwiftUI

/// Block 4b Phase 1B — chip area renderer for the own-corpus atom path.
/// Mirrors `RAGCitationView`'s overall shell (collapsed `▽ N atoms` →
/// expandable list, hover popover, click-to-open) but each row carries the
/// atom statement directly with a `[atomType · date · conf]` header rather
/// than a conversation title. Reflection claims render as non-clickable
/// cards (no `sourceNodeId` to navigate to).
///
/// Phase 1C will add the UI confidence floor (0.7) and UI cap (5) at the
/// cascade boundary — this view stays pure presentation.
struct CorpusAtomCardListView: View {
    let entries: [ResolvedCitableEntry]
    @Binding var isExpanded: Bool
    var onOpenSource: (NousNode) -> Void = { _ in }

    @State private var hoveredEntryId: String?
    @State private var popoverEntryId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.secondaryText)

                    Text(headerLabel)
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
                    ForEach(Array(entries.enumerated()), id: \.element.entry.id) { index, resolved in
                        atomRow(resolved)
                        if index < entries.count - 1 {
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
            if !expanded { hoveredEntryId = nil; popoverEntryId = nil }
        }
        .onChange(of: entries.map(\.entry.id)) { _, ids in
            if let hovered = hoveredEntryId, !ids.contains(hovered) {
                hoveredEntryId = nil
            }
            if let popoverId = popoverEntryId, !ids.contains(popoverId) {
                popoverEntryId = nil
            }
        }
    }

    @ViewBuilder
    private func atomRow(_ resolved: ResolvedCitableEntry) -> some View {
        let isClickable = resolved.node != nil
        let row = VStack(alignment: .leading, spacing: 6) {
            Text(rowHeader(resolved))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)

            HStack(alignment: .top, spacing: 8) {
                Text(resolved.entry.text)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText)
                    // Non-clickable rows (reflections, atoms with deleted source nodes)
                    // have no popover or click-to-source path, so show more inline.
                    .lineLimit(isClickable ? 3 : 6)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isClickable {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(
                            hoveredEntryId == resolved.entry.id
                                ? AppColor.colaOrange
                                : AppColor.secondaryText.opacity(0.4)
                        )
                        .animation(.easeOut(duration: 0.15), value: hoveredEntryId)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    hoveredEntryId == resolved.entry.id && isClickable
                        ? AppColor.colaOrange.opacity(0.06)
                        : Color.clear
                )
                .animation(.easeOut(duration: 0.15), value: hoveredEntryId)
        )

        if isClickable, let node = resolved.node {
            Button {
                onOpenSource(node)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                hoveredEntryId = isHovering ? resolved.entry.id : nil
                if isHovering {
                    let thisId = resolved.entry.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        if hoveredEntryId == thisId {
                            popoverEntryId = thisId
                        }
                    }
                } else {
                    popoverEntryId = nil
                }
            }
            .popover(
                isPresented: Binding(
                    get: { popoverEntryId == resolved.entry.id },
                    set: { if !$0 { popoverEntryId = nil } }
                ),
                arrowEdge: .leading
            ) {
                atomPopover(resolved)
            }
        } else {
            row
        }
    }

    @ViewBuilder
    private func atomPopover(_ resolved: ResolvedCitableEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(rowHeader(resolved))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)
                Spacer()
            }

            Text(resolved.entry.text)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(AppColor.colaDarkText)
                .lineSpacing(3)
                .lineLimit(8)
                .multilineTextAlignment(.leading)

            if let node = resolved.node {
                Divider()
                    .overlay(AppColor.panelStroke)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Source")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText)
                    Text(node.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppColor.colaDarkText)
                        .lineLimit(2)
                }

                Button {
                    onOpenSource(node)
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
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Formatting

    private var headerLabel: String {
        let linkable = entries.filter { $0.node != nil }.count
        let total = entries.count
        let unit = total == 1 ? "atom" : "atoms"
        if linkable < total {
            return "\(total) \(unit) · \(linkable) linkable"
        }
        return "\(total) \(unit)"
    }

    private func rowHeader(_ resolved: ResolvedCitableEntry) -> String {
        var parts: [String] = []
        if resolved.entry.scope == .selfReflection {
            parts.append("reflection")
        } else if let atomType = resolved.entry.atomType {
            parts.append(atomType.rawValue)
        }
        if let date = resolved.entry.eventTime ?? resolved.entry.recordedAt {
            parts.append(Self.dateFormatter.string(from: date))
        }
        if let confidence = resolved.entry.confidence {
            parts.append(String(format: "conf %.2f", confidence))
        }
        return "[\(parts.joined(separator: " · "))]"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
