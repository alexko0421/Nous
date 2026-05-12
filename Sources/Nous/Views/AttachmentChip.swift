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

struct SourceDiscussionLinkChip: View {
    let context: SourceDiscussionContext
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppColor.colaOrange)

            Text(context.summaryTitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.colaDarkText.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)

            Text(context.timeRangeLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaOrange.opacity(0.78))
                .lineLimit(1)

            Text(context.evidenceLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.secondaryText.opacity(0.86))
                .lineLimit(1)

            Text(context.previewLine)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.secondaryText.opacity(0.74))
                .lineLimit(1)
                .truncationMode(.tail)

            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(AppColor.secondaryText.opacity(0.72))
            }
            .buttonStyle(.plain)
            .help("Clear source context")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColor.surfaceSecondary)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(AppColor.colaOrange.opacity(0.28), lineWidth: 1)
        )
        .accessibilityLabel("Source link \(context.summaryTitle)")
    }
}

struct SourceMaterialMessageChip: View {
    let material: SourceMaterialContext

    private var systemImage: String {
        if material.originalURL?.localizedCaseInsensitiveContains("youtube") == true ||
            material.originalURL?.localizedCaseInsensitiveContains("youtu.be") == true {
            return "play.rectangle.fill"
        }
        if material.originalFilename != nil { return "doc.text.fill" }
        return "link"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppColor.colaOrange)

            Text(material.title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText.opacity(0.78))
                .lineLimit(1)

            Text(material.evidenceLevel.label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.secondaryText.opacity(0.82))
                .lineLimit(1)

            Text(material.previewLine)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.secondaryText.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppColor.surfaceSecondary.opacity(0.82))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(AppColor.panelStroke.opacity(0.9), lineWidth: 1)
        )
        .accessibilityLabel("Attached source \(material.title)")
    }
}
