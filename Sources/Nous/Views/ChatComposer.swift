import SwiftUI

private enum ChatComposerMetrics {
    static let controlSize: CGFloat = 30
    static let labelFont: CGFloat = 12
    static let bodyFont: CGFloat = 14
    static let capsuleRadius: CGFloat = 18
}

struct ChatComposer: View {
    @Binding var text: String
    let attachments: [URL]
    let isGenerating: Bool
    let onPickFiles: () -> Void
    let onRemoveAttachment: (URL) -> Void
    let onSend: () -> Void

    @FocusState private var isTextFieldFocused: Bool
    @Binding var focusRequest: Bool

    private var canSend: Bool {
        (
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !attachments.isEmpty
        ) && !isGenerating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { fileURL in
                            AttachmentChip(fileURL: fileURL) {
                                onRemoveAttachment(fileURL)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            HStack(spacing: 12) {
                ComposerButton(
                    icon: "plus",
                    tint: AppColor.colaDarkText.opacity(0.78),
                    background: Color.white.opacity(0.68),
                    action: onPickFiles
                )

                TextField("Ask Nous anything...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: ChatComposerMetrics.bodyFont, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineLimit(1...3)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: ChatComposerMetrics.capsuleRadius, style: .continuous)
                            .fill(Color.white.opacity(0.74))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ChatComposerMetrics.capsuleRadius, style: .continuous)
                            .stroke(AppColor.colaDarkText.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    .onSubmit(onSend)
                    .focused($isTextFieldFocused)
                    .onChange(of: focusRequest) { _, newValue in
                        if newValue {
                            isTextFieldFocused = true
                            focusRequest = false
                        }
                    }

                ComposerButton(
                    icon: isGenerating ? "stop.fill" : "arrow.up",
                    tint: canSend ? .white : AppColor.colaOrange.opacity(0.55),
                    background: canSend ? AppColor.colaOrange : AppColor.colaOrange.opacity(0.12),
                    isDisabled: !canSend,
                    action: onSend
                )
            }
        }
    }
}

private struct AttachmentChip: View {
    let fileURL: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppColor.colaOrange)

            Text(fileURL.lastPathComponent)
                .font(.system(size: ChatComposerMetrics.labelFont, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.colaDarkText.opacity(0.74))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.42))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.58))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(AppColor.colaDarkText.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ComposerButton: View {
    let icon: String
    let tint: Color
    let background: Color
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(background)
                .frame(width: ChatComposerMetrics.controlSize, height: ChatComposerMetrics.controlSize)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(tint)
                )
                .overlay(
                    Circle()
                        .stroke(AppColor.colaDarkText.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.04), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}
