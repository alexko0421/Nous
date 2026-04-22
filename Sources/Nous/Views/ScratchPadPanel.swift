import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ScratchPadPanel

struct ScratchPadPanel: View {
    @Binding var isVisible: Bool
    @Bindable var store: ScratchPadStore
    @State private var isPreviewMode = true

    var body: some View {
        NativeGlassPanel(cornerRadius: 32, tintColor: AppColor.glassTint) {
            VStack(alignment: .leading, spacing: 0) {
                header
                divider
                paperSurface
            }
            .padding(.bottom, 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .onAppear { store.onPanelOpened() }
        .onChange(of: store.latestSummary) { _, _ in
            if isVisible { store.onPanelOpened() }
        }
        .alert(
            "有新嘅 summary",
            isPresented: Binding(
                get: { store.pendingOverwrite != nil },
                set: { newValue in
                    if newValue == false && store.pendingOverwrite != nil {
                        store.rejectPendingOverwrite()
                    }
                }
            ),
            presenting: store.pendingOverwrite
        ) { _ in
            Button("替换", role: .destructive) { store.acceptPendingOverwrite() }
            Button("保留现有", role: .cancel) { store.rejectPendingOverwrite() }
        } message: { _ in
            Text("你喺白纸度仲有未下载嘅改动。要用新嘅 summary 替换吗？")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppColor.colaOrange)
                    )
                Text("Markdown")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
            }
            .frame(height: 32)

            if store.isDirty {
                Text("•")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppColor.secondaryText)
            }

            Spacer(minLength: 0)

            Button(action: handleDownload) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 12, weight: .semibold))
                    Text("下载")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
            }
            .buttonStyle(OrangeGlassButtonStyle(isDisabled: store.currentContent.isEmpty))
            .disabled(store.currentContent.isEmpty)

            // Write / Preview grouped pill
            ZStack {
                NativeGlassPanel(
                    cornerRadius: 16,
                    tintColor: AppColor.glassTint
                ) { EmptyView() }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppColor.panelStroke, lineWidth: 1)
                )

                HStack(spacing: 2) {
                    modeButton(label: "Preview", icon: "eye", active: isPreviewMode) {
                        withAnimation(.easeInOut(duration: 0.15)) { isPreviewMode = true }
                    }
                    modeButton(label: "Write", icon: "pencil", active: !isPreviewMode) {
                        withAnimation(.easeInOut(duration: 0.15)) { isPreviewMode = false }
                    }
                }
                .padding(3)
            }
            .fixedSize()
            .frame(height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func handleDownload() {
        let content = store.currentContent
        guard !content.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "下载 Markdown"
        panel.nameFieldStringValue = filenameSlug(fromMarkdown: content)
        panel.canCreateDirectories = true
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(content.utf8).write(to: url, options: .atomic)
                store.markDownloaded()
            } catch {
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    @ViewBuilder
    private var divider: some View {
        Rectangle()
            .fill(AppColor.panelStroke)
            .frame(height: 0.5)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
    }

    // MARK: - Paper surface

    @ViewBuilder
    private var paperSurface: some View {
        paperContainer {
            if store.latestSummary == nil && store.currentContent.isEmpty {
                emptyState
            } else if isPreviewMode {
                MarkdownPreview(markdown: store.currentContent)
            } else {
                TextEditor(text: editorBinding)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .lineSpacing(6)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func paperContainer<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        inner()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .background(
                NativeGlassPanel(cornerRadius: 12, tintColor: AppColor.glassTint) { EmptyView() }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppColor.panelStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("想开始？")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
            Text("喺左边同 Nous 倾一阵，叫佢「总结一下」。生成嘅 summary 会自动出喺呢度，之后你仲可以手动改同下载。")
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
                .lineSpacing(6)

            TextEditor(text: editorBinding)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 120)
                .padding(.top, 8)
        }
    }

    private var editorBinding: Binding<String> {
        Binding(
            get: { store.currentContent },
            set: { store.updateContent($0) }
        )
    }

    // MARK: Helpers

    @ViewBuilder
    private func modeButton(
        label: String,
        icon: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: active ? .semibold : .medium, design: .rounded))
            }
            .foregroundColor(active ? .white : AppColor.secondaryText)
                .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                Group {
                    if active {
                        NativeGlassPanel(
                            cornerRadius: 13,
                            tintColor: NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.88)
                        ) { EmptyView() }
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    } else {
                        Color.clear
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MarkdownPreview

/// Converts a subset of Markdown to styled SwiftUI Text.
/// Covers: # headings, **bold**, *italic*, `code`, - bullet lists, blank-line paragraphs.
struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, block in
                    block.view
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // ── Parsing ────────────────────────────────────────────────────────────

    private var paragraphs: [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let rawLines = markdown.components(separatedBy: "\n")

        var paraLines: [String] = []

        func flushPara() {
            let joined = paraLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paraLines = []
        }

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Heading
            if let headingBlock = MarkdownBlock.heading(from: trimmed) {
                flushPara()
                blocks.append(headingBlock)
                continue
            }

            // Bullet
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushPara()
                let text = String(trimmed.dropFirst(2))
                blocks.append(.bullet(text))
                continue
            }

            // Blank line → paragraph break
            if trimmed.isEmpty {
                flushPara()
                blocks.append(.spacer)
                continue
            }

            paraLines.append(trimmed)
        }
        flushPara()
        return blocks
    }
}

// MARK: - MarkdownBlock

private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case bullet(String)
    case paragraph(String)
    case spacer

    // Factory for heading lines
    static func heading(from line: String) -> MarkdownBlock? {
        var level = 0
        var rest = line
        while rest.hasPrefix("#") {
            level += 1
            rest = String(rest.dropFirst())
        }
        guard level > 0, level <= 4, rest.hasPrefix(" ") else { return nil }
        return .heading(level: level, text: String(rest.dropFirst()))
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level: level))
                .foregroundColor(AppColor.colaDarkText)
                .padding(.top, level == 1 ? 16 : 10)
                .padding(.bottom, 4)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaOrange)
                inlineText(text)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
            }
            .padding(.vertical, 2)

        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .lineSpacing(6)
                .padding(.vertical, 1)

        case .spacer:
            Color.clear.frame(height: 6)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .system(size: 18, weight: .bold, design: .rounded)
        case 2: return .system(size: 15, weight: .semibold, design: .rounded)
        case 3: return .system(size: 13, weight: .semibold, design: .rounded)
        default: return .system(size: 12, weight: .semibold, design: .rounded)
        }
    }

    /// Renders **bold**, *italic*, and `code` spans inline.
    private func inlineText(_ raw: String) -> some View {
        Text(attributedString(from: raw))
    }

    private func attributedString(from raw: String) -> AttributedString {
        var result = AttributedString()
        var remaining = raw

        while !remaining.isEmpty {
            // **bold**
            if let range = remaining.range(of: "**"),
               let endRange = remaining[range.upperBound...].range(of: "**") {
                result += plainAttr(String(remaining[remaining.startIndex..<range.lowerBound]))
                var bold = AttributedString(String(remaining[range.upperBound..<endRange.lowerBound]))
                bold.font = .system(size: 14, weight: .bold, design: .rounded)
                result += bold
                remaining = String(remaining[endRange.upperBound...])
                continue
            }
            // *italic*
            if let range = remaining.range(of: "*"),
               let endRange = remaining[range.upperBound...].range(of: "*") {
                result += plainAttr(String(remaining[remaining.startIndex..<range.lowerBound]))
                var italic = AttributedString(String(remaining[range.upperBound..<endRange.lowerBound]))
                italic.font = .system(size: 14, design: .rounded).italic()
                result += italic
                remaining = String(remaining[endRange.upperBound...])
                continue
            }
            // `code`
            if let range = remaining.range(of: "`"),
               let endRange = remaining[range.upperBound...].range(of: "`") {
                result += plainAttr(String(remaining[remaining.startIndex..<range.lowerBound]))
                var code = AttributedString(String(remaining[range.upperBound..<endRange.lowerBound]))
                code.font = .system(size: 13, design: .monospaced)
                code.backgroundColor = .init(AppColor.subtleFill)
                result += code
                remaining = String(remaining[endRange.upperBound...])
                continue
            }
            // No more markers — append everything
            result += plainAttr(remaining)
            break
        }
        return result
    }

    private func plainAttr(_ s: String) -> AttributedString {
        var attr = AttributedString(s)
        attr.font = .system(size: 14, weight: .regular, design: .rounded)
        return attr
    }
}

// MARK: - OrangeGlassButtonStyle

struct OrangeGlassButtonStyle: ButtonStyle {
    let isDisabled: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isDisabled ? AppColor.secondaryText : (configuration.isPressed ? .white : AppColor.colaOrange))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                NativeGlassPanel(
                    cornerRadius: 14,
                    tintColor: isDisabled 
                        ? NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.10)
                        : (configuration.isPressed 
                            ? NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.88) 
                            : NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.18))
                ) { EmptyView() }
            )
            .overlay(
                Capsule()
                    .stroke(isDisabled ? Color.clear : (configuration.isPressed ? Color.white.opacity(0.2) : AppColor.colaOrange.opacity(0.3)), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
