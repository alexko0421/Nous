import SwiftUI
import UniformTypeIdentifiers

struct AttachmentChip: View {
    let attachment: AttachedFileContext
    let onRemove: () -> Void

    private var systemImage: String {
        let pathExtension = URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
        guard let type = UTType(filenameExtension: pathExtension) else { return "doc" }

        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .movie) { return "film" }
        return "doc"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppColor.colaOrange)

            Text(attachment.name)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(AppColor.secondaryText.opacity(0.72))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColor.surfaceSecondary)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
    }
}
