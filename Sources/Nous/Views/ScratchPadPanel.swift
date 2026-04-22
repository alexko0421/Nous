import SwiftUI

// MARK: - ScratchPadPanel

/// A lightweight right-side scratchpad that supports raw Markdown editing
/// and a simple live preview. Lives in ContentView as a slide-in panel,
/// persists its content in @AppStorage so it survives restarts.
struct ScratchPadPanel: View {
    @Binding var isVisible: Bool
    // Task 6 will drive content off this store; the @AppStorage path below is about to be replaced.
    var store: ScratchPadStore
    @AppStorage("nous.scratchpad.content") private var content = ""
    @State private var isPreviewMode = false

    var body: some View {
        NativeGlassPanel(cornerRadius: 32, tintColor: AppColor.glassTint) {
            VStack(alignment: .leading, spacing: 0) {
                // ── Header ────────────────────────────────────────────────
                HStack(spacing: 10) {
                    Image(systemName: "note.text")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColor.colaOrange)

                    Text("Scratch Pad")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)

                    Spacer(minLength: 0)

                    // Write / Preview toggle
                    HStack(spacing: 2) {
                        modeButton(label: "Write", icon: "pencil",  active: !isPreviewMode) {
                            withAnimation(.easeInOut(duration: 0.15)) { isPreviewMode = false }
                        }
                        modeButton(label: "Preview", icon: "eye",   active: isPreviewMode) {
                            withAnimation(.easeInOut(duration: 0.15)) { isPreviewMode = true }
                        }
                    }
                    .padding(3)
                    .background(AppColor.subtleFill)
                    .clipShape(Capsule())

                    // Close button
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isVisible = false
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(AppColor.secondaryText)
                            .frame(width: 22, height: 22)
                            .background(AppColor.subtleFill)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

                // Thin divider
                Rectangle()
                    .fill(AppColor.panelStroke)
                    .frame(height: 0.5)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)

                // ── Body ──────────────────────────────────────────────────
                if isPreviewMode {
                    MarkdownPreview(markdown: content)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                } else {
                    TextEditor(text: $content)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(AppColor.colaDarkText)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
        .frame(width: 300)
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
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: active ? .semibold : .medium, design: .rounded))
            }
            .foregroundColor(active ? .white : AppColor.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(active ? AppColor.colaOrange : Color.clear)
            .clipShape(Capsule())
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColor.colaOrange)
                inlineText(text)
                    .font(.system(size: 13))
                    .foregroundColor(AppColor.colaDarkText)
            }
            .padding(.vertical, 2)

        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 13))
                .foregroundColor(AppColor.colaDarkText)
                .lineSpacing(4)
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
    @ViewBuilder
    private func inlineText(_ raw: String) -> some View {
        if #available(macOS 12, *) {
            Text(attributedString(from: raw))
        } else {
            Text(raw)
        }
    }

    @available(macOS 12, *)
    private func attributedString(from raw: String) -> AttributedString {
        var result = AttributedString()
        var remaining = raw

        while !remaining.isEmpty {
            // **bold**
            if let range = remaining.range(of: "**"),
               let endRange = remaining[range.upperBound...].range(of: "**") {
                result += plainAttr(String(remaining[remaining.startIndex..<range.lowerBound]))
                var bold = AttributedString(String(remaining[range.upperBound..<endRange.lowerBound]))
                bold.font = .system(size: 13, weight: .bold)
                result += bold
                remaining = String(remaining[endRange.upperBound...])
                continue
            }
            // *italic*
            if let range = remaining.range(of: "*"),
               let endRange = remaining[range.upperBound...].range(of: "*") {
                result += plainAttr(String(remaining[remaining.startIndex..<range.lowerBound]))
                var italic = AttributedString(String(remaining[range.upperBound..<endRange.lowerBound]))
                italic.font = .system(size: 13).italic()
                result += italic
                remaining = String(remaining[endRange.upperBound...])
                continue
            }
            // `code`
            if let range = remaining.range(of: "`"),
               let endRange = remaining[range.upperBound...].range(of: "`") {
                result += plainAttr(String(remaining[remaining.startIndex..<range.lowerBound]))
                var code = AttributedString(String(remaining[range.upperBound..<endRange.lowerBound]))
                code.font = .system(size: 12, design: .monospaced)
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

    @available(macOS 12, *)
    private func plainAttr(_ s: String) -> AttributedString {
        AttributedString(s)
    }
}
