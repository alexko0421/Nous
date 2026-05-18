import SwiftUI
import WebKit

struct YouTubeLearningPanel: View {
    @Bindable var viewModel: YouTubeLearningViewModel
    let currentProjectId: UUID?
    let onSelectContext: (SourceDiscussionContext) -> Void
    let onClose: () -> Void
    @State private var isFileImporterPresented = false
    @State private var isDocumentDropTargeted = false

    var body: some View {
        NativeGlassPanel(cornerRadius: 32, tintColor: AppColor.rightPanelGlassTint) {
            VStack(alignment: .leading, spacing: 0) {
                header
                divider
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        urlInput
                        sourcePreview
                        player
                        errorState
                        evidencePill
                        summaries
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 18)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
        .overlay {
            if isDocumentDropTargeted {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(AppColor.colaOrange.opacity(0.55), lineWidth: 1.5)
            }
        }
        .frame(width: RightPanelLayout.preferredWidth)
        .frame(maxHeight: .infinity)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: AttachmentDropSupport.sourceReaderContentTypes,
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        .onDrop(
            of: AttachmentDropSupport.allFileTypeIdentifiers,
            isTargeted: $isDocumentDropTargeted,
            perform: handleDocumentDrop
        )
    }

    private var canLoad: Bool {
        !viewModel.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !viewModel.isLoading
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColor.colaOrange)

            Text("URL")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColor.secondaryText)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(AppColor.panelStroke)
            .frame(height: 0.5)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
    }

    private var urlInput: some View {
        HStack(spacing: 8) {
            TextField("URL or document", text: $viewModel.urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(
                    NativeGlassPanel(cornerRadius: 16, tintColor: AppColor.controlGlassTint) { EmptyView() }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppColor.panelStroke, lineWidth: 1)
                )
                .onSubmit(load)

            Button {
                isFileImporterPresented = true
            } label: {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColor.secondaryText)
            .background(
                NativeGlassPanel(cornerRadius: 17, tintColor: AppColor.controlGlassTint) { EmptyView() }
            )
            .overlay(
                Circle()
                    .stroke(AppColor.panelStroke, lineWidth: 1)
            )
            .help("Open document")

            Button(action: load) {
                Group {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canLoad ? AppColor.colaDarkText : AppColor.secondaryText)
            .background(
                NativeGlassPanel(cornerRadius: 17, tintColor: AppColor.controlGlassTint) { EmptyView() }
            )
            .overlay(
                Circle()
                    .stroke(AppColor.panelStroke, lineWidth: 1)
            )
            .disabled(!canLoad)
            .help("Read source")
        }
    }

    @ViewBuilder
    private var sourcePreview: some View {
        if let preview = viewModel.sourcePreview {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(preview.title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    Text(preview.subtitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText)
                        .lineLimit(1)
                }

                Text(preview.body)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)
                    .lineSpacing(4)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                NativeGlassPanel(cornerRadius: 18, tintColor: AppColor.controlGlassTint) { EmptyView() }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppColor.panelStroke, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var player: some View {
        if let embed = viewModel.playerEmbed {
            YouTubePlayerView(embed: embed)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(AppColor.panelStroke, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var errorState: some View {
        if let errorMessage = viewModel.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.colaOrange)
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)
                    .lineSpacing(4)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                NativeGlassPanel(cornerRadius: 16, tintColor: AppColor.controlGlassTint) { EmptyView() }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppColor.panelStroke, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var evidencePill: some View {
        if let label = viewModel.currentEvidenceLabel {
            HStack(spacing: 6) {
                Image(systemName: viewModel.currentEvidenceLevel?.isQuoteLevelReliable == true ? "text.quote" : "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.colaOrange)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                NativeGlassPanel(cornerRadius: 14, tintColor: AppColor.controlGlassTint) { EmptyView() }
            )
            .overlay(
                Capsule()
                    .stroke(AppColor.panelStroke, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var summaries: some View {
        if !viewModel.summarySections.isEmpty || viewModel.isSummaryUnavailable || viewModel.isLoading {
            VStack(alignment: .leading, spacing: 10) {
                Text("Summary")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)

                if viewModel.isLoading {
                    summaryLoadingRow
                } else if let message = viewModel.summaryUnavailableMessage {
                    Text(message)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            NativeGlassPanel(cornerRadius: 16, tintColor: AppColor.controlGlassTint) { EmptyView() }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(AppColor.panelStroke, lineWidth: 1)
                        )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.summarySections) { section in
                            summaryBranch(for: section)
                        }
                    }
                }
            }
        }
    }

    private var summaryLoadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Reading source")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppColor.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            NativeGlassPanel(cornerRadius: 16, tintColor: AppColor.controlGlassTint) { EmptyView() }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
    }

    private func summaryBranch(for section: YouTubeSummarySection) -> some View {
        let isSelected = viewModel.selectedSectionID == section.id

        return Button {
            guard let context = viewModel.selectSectionForDiscussionAndPlayback(section) else { return }
            onSelectContext(context)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? AppColor.colaOrange : AppColor.secondaryText)
                    .frame(width: 22, height: 22)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppColor.colaDarkText)
                        .lineLimit(2)

                    Text(section.summary)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText)
                        .lineSpacing(4)
                        .lineLimit(4)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? AppColor.colaOrange : AppColor.secondaryText)
                    .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                NativeGlassPanel(
                    cornerRadius: 16,
                    tintColor: isSelected
                        ? NSColor(red: 243 / 255, green: 131 / 255, blue: 53 / 255, alpha: 0.14)
                        : AppColor.controlGlassTint
                ) { EmptyView() }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? AppColor.colaOrange.opacity(0.36) : AppColor.panelStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Discuss this summary branch")
    }

    private func load() {
        guard canLoad else { return }
        Task {
            await viewModel.load(projectId: currentProjectId)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        let attachments = AttachmentExtractor.fileContexts(from: urls)
        viewModel.loadDocumentAttachments(attachments, projectId: currentProjectId)
    }

    private func handleDocumentDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            let attachments = await AttachmentExtractor.droppedAttachmentContexts(from: providers)
            await MainActor.run {
                viewModel.loadDocumentAttachments(attachments, projectId: currentProjectId)
            }
        }
        return true
    }
}

private struct YouTubePlayerView: NSViewRepresentable {
    let embed: YouTubePlayerEmbed

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15"
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let cacheKey = embed.cacheKey
        guard context.coordinator.loadedEmbedURL != cacheKey else { return }
        context.coordinator.loadedEmbedURL = cacheKey
        webView.loadHTMLString(embed.html, baseURL: YouTubePlayerEmbed.embedOrigin)
    }

    final class Coordinator {
        var loadedEmbedURL: String?
    }
}
