import SwiftUI

/// Phase A per-row chat feedback component. Selected state uses
/// `AppColor.dustyRose` (Morandi palette), never `colaOrange`.
struct ThumbFeedbackView: View {
    @Binding var verdict: ThumbVerdict
    @Binding var note: String
    let onChange: (ThumbVerdict, String) -> Void

    var body: some View {
        chatBody
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

    private func setVerdict(_ v: ThumbVerdict) {
        verdict = v
        onChange(v, note)
    }
}
