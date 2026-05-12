import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MessageAttachmentRow: View {
    let attachments: [AttachedFileContext]
    let alignment: HorizontalAlignment

    private let maxWidth: CGFloat = 480

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            let imageAttachments = attachments.filter { $0.kind == .image }
            let nonImageAttachments = attachments.filter { $0.kind != .image }

            if !imageAttachments.isEmpty {
                imageGrid(for: imageAttachments)
            }

            ForEach(nonImageAttachments) { attachment in
                switch attachment.kind {
                case .pdf:
                    PdfAttachmentCard(attachment: attachment)
                case .link:
                    LinkAttachmentCard(attachment: attachment)
                case .textFile, .image:
                    GenericFileCard(attachment: attachment)
                }
            }
        }
        .frame(maxWidth: maxWidth, alignment: alignmentToFrame(alignment))
    }

    private func imageGrid(for images: [AttachedFileContext]) -> some View {
        let columnCount = images.count == 1 ? 1 : 2
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: columnCount)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(images) { image in
                ImageAttachmentCard(attachment: image)
            }
        }
    }

    private func alignmentToFrame(_ alignment: HorizontalAlignment) -> Alignment {
        switch alignment {
        case .trailing: return .trailing
        case .leading: return .leading
        default: return .center
        }
    }
}

private struct ImageAttachmentCard: View {
    let attachment: AttachedFileContext

    var body: some View {
        Group {
            if let nsImage = renderImage() {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppColor.panelStroke, lineWidth: 1)
                    )
            } else {
                fallbackPlaceholder
            }
        }
    }

    private func renderImage() -> NSImage? {
        guard let data = attachment.imageData else { return nil }
        return NSImage(data: data)
    }

    private var fallbackPlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .foregroundColor(AppColor.colaOrange)
            Text(attachment.name)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColor.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
    }
}

private struct PdfAttachmentCard: View {
    let attachment: AttachedFileContext

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColor.colaOrange)
                .frame(width: 28, height: 28)
                .background(AppColor.colaOrange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineLimit(1)
                if let preview = attachment.extractedText, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(AppColor.secondaryText)
                        .lineLimit(2)
                } else {
                    Text("PDF")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(AppColor.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(AppColor.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
    }
}

private struct LinkAttachmentCard: View {
    let attachment: AttachedFileContext

    private var displayHost: String {
        if let urlString = attachment.linkURL,
           let url = URL(string: urlString),
           let host = url.host {
            return host
        }
        return attachment.name
    }

    var body: some View {
        Button(action: openURL) {
            HStack(alignment: .top, spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.linkTitle ?? attachment.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let description = attachment.linkDescription, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(AppColor.secondaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 9, weight: .semibold))
                        Text(displayHost)
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                    }
                    .foregroundColor(AppColor.secondaryText.opacity(0.75))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: 360, alignment: .leading)
            .background(AppColor.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.panelStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let urlString = attachment.linkThumbnailURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty, .failure:
                    placeholderIcon
                @unknown default:
                    placeholderIcon
                }
            }
            .frame(width: 56, height: 56)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            placeholderIcon
                .frame(width: 56, height: 56)
                .background(AppColor.colaOrange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var placeholderIcon: some View {
        Image(systemName: "link")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(AppColor.colaOrange)
    }

    private func openURL() {
        guard let urlString = attachment.linkURL,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct GenericFileCard: View {
    let attachment: AttachedFileContext

    private var systemImage: String {
        let pathExtension = URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension) else { return "doc" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        return "doc.text"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppColor.colaOrange)
            Text(attachment.name)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .lineLimit(1)
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
