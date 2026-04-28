import SwiftUI

struct AgentTraceAccordion: View {
    let records: [AgentTraceRecord]
    let isStreaming: Bool

    @State private var isExpanded: Bool

    init(records: [AgentTraceRecord], isStreaming: Bool) {
        self.records = records
        self.isStreaming = isStreaming
        self._isExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                pill
                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(records) { record in
                            AgentTraceRow(record: record)
                        }
                    }
                    .padding(.leading, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .onChange(of: isStreaming) { _, newValue in
                if !newValue && isExpanded {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded = false
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: records.count)
        }
    }

    private var pill: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                FrameSpinner(isAnimating: isStreaming)
                Text(AgentTraceFormatting.header(records: records, isStreaming: isStreaming))
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
    }
}

struct AgentTraceRow: View {
    let record: AgentTraceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.colaDarkText.opacity(0.72))
            if !record.detail.isEmpty {
                Text(record.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColor.secondaryText)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

enum AgentTraceFormatting {
    static func header(records: [AgentTraceRecord], isStreaming: Bool) -> String {
        if isStreaming {
            return "Nous is searching..."
        }
        let resultCount = records.filter { $0.kind == .toolResult }.count
        if resultCount == 1 {
            return "Nous searched 1 source"
        }
        return "Nous searched \(resultCount) sources"
    }
}
