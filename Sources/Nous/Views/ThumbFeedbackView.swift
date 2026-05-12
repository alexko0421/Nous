import SwiftUI

/// System telemetry surfaced in the galaxy inspector strip. Snapshot of
/// the latest judge decision for a node-pair: similarity score, which
/// path produced the verdict (`atom`/`llm`/`fallback`/`retrieval`),
/// confidence (nil for fallback paths that don't produce one), the
/// timestamp, and a count of any prior user verdicts on the same row.
struct TelemetryStrip: Equatable {
    let similarity: Double
    let judgePath: JudgePath
    let confidence: Double?
    let judgedAt: Date
    let priorVerdictCount: Int
}

/// Phase A shared feedback component. Two style modes:
///   - `.galaxy` mounts in the galaxy edge inspector — full size,
///     thumb-up/thumb-down chips, optional note field, telemetry strip
///     under the chips.
///   - `.chat` mounts per-row in the chat atom card list — compact
///     icon-only thumb pair; the note field reveals only on thumb-down
///     to keep the reading flow intact.
/// Selected state uses `AppColor.dustyRose` (Morandi palette), never
/// `colaOrange` — see the galaxy palette invariant memory.
struct ThumbFeedbackView: View {
    enum Style: Equatable {
        case galaxy
        case chat
    }

    @Binding var verdict: ThumbVerdict
    @Binding var note: String
    let style: Style
    let telemetry: TelemetryStrip?
    let onChange: (ThumbVerdict, String) -> Void

    var body: some View {
        switch style {
        case .galaxy:
            galaxyBody
        case .chat:
            chatBody
        }
    }

    @ViewBuilder
    private var galaxyBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("呢条关联啱吗？")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColor.secondaryText)

            HStack(spacing: 8) {
                thumbButton(.up, label: "👍 啱")
                thumbButton(.down, label: "👎 唔啱")
            }

            TextField("想补充？", text: $note, onEditingChanged: { editing in
                if !editing { onChange(verdict, note) }
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))

            if let telemetry {
                Text(telemetryLine(telemetry))
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.secondaryText)
            } else {
                Text("判断路径: 未记录（Phase A 之前）")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var chatBody: some View {
        HStack(spacing: 6) {
            Button { setVerdict(.up) } label: {
                Image(systemName: verdict == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.system(size: 11))
                    .foregroundStyle(verdict == .up ? AppColor.dustyRose : AppColor.secondaryText)
            }
            .buttonStyle(.plain)

            Button { setVerdict(.down) } label: {
                Image(systemName: verdict == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 11))
                    .foregroundStyle(verdict == .down ? AppColor.dustyRose : AppColor.secondaryText)
            }
            .buttonStyle(.plain)

            if verdict == .down {
                TextField("关联唔到呢条 message？", text: $note, onEditingChanged: { editing in
                    if !editing { onChange(verdict, note) }
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            }
        }
    }

    private func thumbButton(_ kind: ThumbVerdict, label: String) -> some View {
        Button { setVerdict(kind) } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(verdict == kind ? AppColor.dustyRose : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppColor.panelStroke, lineWidth: 1)
                )
                .foregroundStyle(verdict == kind ? .white : AppColor.colaDarkText)
        }
        .buttonStyle(.plain)
    }

    private func setVerdict(_ v: ThumbVerdict) {
        verdict = v
        onChange(v, note)
    }

    private func telemetryLine(_ t: TelemetryStrip) -> String {
        let confText = t.confidence.map { String(format: "信心 %.2f · ", $0) } ?? ""
        let priorText = t.priorVerdictCount > 0 ? " · 之前已表态 \(t.priorVerdictCount) 次" : ""
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        return String(
            format: "相似度 %.2f · 路径 %@ · %@判断於 %@%@",
            t.similarity,
            t.judgePath.rawValue,
            confText,
            timeFormatter.string(from: t.judgedAt),
            priorText
        )
    }
}
