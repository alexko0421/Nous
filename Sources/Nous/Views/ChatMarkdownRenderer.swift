import SwiftUI
import AppKit

enum Segment: Equatable {
    case heading(level: Int, text: String)
    case bulletBlock([String])
    case table(headers: [String], rows: [[String]])
    case horizontalRule
    case prose(String)
    case verbatim(String)
}

enum VisualLineBreaks {
    static func lines(for text: String, width: CGFloat, font: NSFont) -> [String] {
        guard !text.isEmpty else { return [] }
        guard width.isFinite, width > 0 else { return [text] }

        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping

        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var lines: [String] = []
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var glyphRange = NSRange(location: 0, length: 0)
            layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &glyphRange
            )

            guard glyphRange.length > 0 else { break }
            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            if let range = Range(characterRange, in: text) {
                lines.append(String(text[range]))
            }
            glyphIndex = NSMaxRange(glyphRange)
        }

        return lines.isEmpty ? [text] : lines
    }
}

struct StreamingVisualLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let revealDelay: TimeInterval
}

enum StreamingVisualLineRevealTiming {
    static let lineStagger: TimeInterval = 0.45
}

enum StreamingVisualLineRevealPolicy {
    static func revealableLines(
        _ visualLines: [String],
        revealTrailingLine: Bool
    ) -> [String] {
        guard !visualLines.isEmpty else { return [] }
        guard !revealTrailingLine else { return visualLines }

        return Array(visualLines.dropLast())
    }
}

enum StreamingVisualLineRevealSyncReason {
    case initial
    case textChanged
    case measuredWidthChanged
    case trailingRevealChanged

    var resetsExistingLines: Bool {
        switch self {
        case .initial, .measuredWidthChanged:
            return true
        case .textChanged, .trailingRevealChanged:
            return false
        }
    }
}

struct StreamingVisualLineRevealState {
    private var nextLineID = 0
    private(set) var lines: [StreamingVisualLine] = []

    mutating func update(
        visualLines: [String],
        revealTrailingLine: Bool,
        reason: StreamingVisualLineRevealSyncReason
    ) {
        let revealableTexts = StreamingVisualLineRevealPolicy.revealableLines(
            visualLines,
            revealTrailingLine: revealTrailingLine
        )
        update(
            revealableTexts: revealableTexts,
            resetExisting: reason.resetsExistingLines
        )
    }

    mutating func update(revealableTexts: [String], resetExisting: Bool = false) {
        if resetExisting || revealableTexts.count < lines.count {
            replace(with: revealableTexts)
            return
        }

        guard revealableTexts.count > lines.count else { return }

        for (index, text) in revealableTexts.dropFirst(lines.count).enumerated() {
            append(text, revealDelay: Double(index) * StreamingVisualLineRevealTiming.lineStagger)
        }
    }

    mutating func reset() {
        nextLineID = 0
        lines = []
    }

    private mutating func replace(with texts: [String]) {
        reset()
        for (index, text) in texts.enumerated() {
            append(text, revealDelay: Double(index) * StreamingVisualLineRevealTiming.lineStagger)
        }
    }

    private mutating func append(_ text: String, revealDelay: TimeInterval) {
        lines.append(StreamingVisualLine(id: nextLineID, text: text, revealDelay: revealDelay))
        nextLineID += 1
    }
}

enum ChatMarkdownRenderer {

    private static let boldPairRegex = try! NSRegularExpression(pattern: #"\*\*([^\*]+)\*\*"#)
    private static let italicAsteriskRegex = try! NSRegularExpression(
        pattern: #"(?<!\*)\*([^\*\s][^\*]*?)\*(?!\*)"#
    )
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
    private static let orderedListPrefixRegex = try! NSRegularExpression(pattern: #"^\d+\.\s+"#)
    private static let quotePrefixRegex = try! NSRegularExpression(pattern: #"^>\s+"#)

    /// Strips unsupported markdown delimiters from a single line of prose.
    /// Underscores are NEVER touched (preserves snake_case_var, __init__).
    private static func sanitizeProse(_ line: String) -> String {
        var result = line

        // Line-start prefixes first (always strip).
        result = applyRegex(orderedListPrefixRegex, to: result, replacement: "")
        result = applyRegex(quotePrefixRegex, to: result, replacement: "")

        // Balanced-pair stripping. ORDERING IS LOAD-BEARING:
        // Bold MUST run before italic. On `***word***`, bold-first strips outer pair
        // → `*word*` → italic strips → `word`. Italic-first leaves `*word*` residue
        // because the italic regex requires non-`*` after the opening `*`.
        result = applyRegex(boldPairRegex, to: result, replacement: "$1")
        result = applyRegex(italicAsteriskRegex, to: result, replacement: "$1")
        result = applyRegex(inlineCodeRegex, to: result, replacement: "$1")

        return result
    }

    private static func applyRegex(
        _ regex: NSRegularExpression,
        to input: String,
        replacement: String
    ) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
    }

    private static func isFenceOpen(_ line: String) -> Bool {
        // Triple backtick at line start, possibly followed by language tag.
        return line.hasPrefix("```")
    }

    /// Returns either (verbatim segment, indexAfterClosingFence) on closed fence,
    /// or nil if the fence is unclosed (caller falls back to re-parsing).
    private static func parseFence(lines: [String], startIndex: Int) -> (Segment, Int)? {
        guard startIndex < lines.count, isFenceOpen(lines[startIndex]) else { return nil }
        var captured: [String] = []
        var i = startIndex + 1
        while i < lines.count {
            if lines[i].hasPrefix("```") {
                // Closing fence found.
                return (.verbatim(captured.joined(separator: "\n")), i + 1)
            }
            captured.append(lines[i])
            i += 1
        }
        // Reached EOF without closing fence — caller handles fallback.
        return nil
    }

    /// Parses raw assistant text into typed segments. Line-based parsing.
    static func parse(_ text: String) -> [Segment] {
        // `"".components(separatedBy:)` returns [""], which would produce [.prose("")].
        // Blank-line rendering policy is deferred to Task 7; guard here to preserve
        // the Task 1 contract that parse("") returns [].
        guard !text.isEmpty else { return [] }

        var segments: [Segment] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Try fence first (must be checked before prose fallback).
            if isFenceOpen(line) {
                if let (verbatim, nextIndex) = parseFence(lines: lines, startIndex: i) {
                    segments.append(verbatim)
                    i = nextIndex
                    continue  // `i` advanced to nextIndex by parseFence; do not increment here.
                } else {
                    // Unclosed fence: bare ``` line as prose; captured content re-parsed
                    // by main loop on subsequent iterations (no recursion needed — just
                    // continue past the ``` line and let normal parsing handle the rest).
                    segments.append(.prose(sanitizeProse(line)))
                    i += 1
                    continue
                }
            }

            if let heading = parseHeading(line: line) {
                segments.append(heading)
                i += 1
                continue
            }
            if isBulletLine(line) {
                var bullets: [String] = []
                while i < lines.count, isBulletLine(lines[i]) {
                    bullets.append(sanitizeProse(bulletContent(lines[i])))
                    i += 1
                }
                segments.append(.bulletBlock(bullets))
                continue  // `i` was advanced inside the inner while; do not increment here.
            }
            if let (tableSegment, nextIndex) = parseTable(lines: lines, startIndex: i) {
                segments.append(tableSegment)
                i = nextIndex
                continue  // `i` advanced to nextIndex by parseTable; do not increment here.
            }
            if isHorizontalRule(line) {
                segments.append(.horizontalRule)
                i += 1
                continue
            }
            segments.append(.prose(sanitizeProse(line)))
            i += 1
        }
        return segments
    }

    private static let escapedPipeSentinel = "\u{0001}"  // ASCII SOH, won't appear in chat

    private static func splitPipes(_ line: String) -> [String]? {
        // Returns nil if line is not pipe-bordered (no leading | or no trailing |).
        // Strip any stray SOH first — converts the "LLMs don't emit U+0001" assumption
        // into an enforced invariant so the sentinel-substitute trick can't silently
        // corrupt input that happens to contain SOH.
        let trimmed = line
            .replacingOccurrences(of: escapedPipeSentinel, with: "")
            .trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
        let escaped = trimmed.replacingOccurrences(of: "\\|", with: escapedPipeSentinel)
        var cells = escaped.components(separatedBy: "|")
        // Bordering pipes produce empty leading and trailing fields — drop them.
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.map {
            $0.replacingOccurrences(of: escapedPipeSentinel, with: "|")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private static func isSeparatorRow(_ line: String, expectedColumns: Int) -> Bool {
        guard let cells = splitPipes(line), cells.count == expectedColumns else { return false }
        let pattern = "^:?-+:?$"
        return cells.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    private static func parseTable(lines: [String], startIndex: Int) -> (Segment, Int)? {
        // Returns the table segment and the index of the next non-table line, or nil if not a table.
        guard startIndex + 1 < lines.count,
              let headers = splitPipes(lines[startIndex]),
              headers.count >= 2 else { return nil }
        guard isSeparatorRow(lines[startIndex + 1], expectedColumns: headers.count) else { return nil }

        var rows: [[String]] = []
        var i = startIndex + 2
        while i < lines.count, var cells = splitPipes(lines[i]) {
            // Normalize column count to header count.
            if cells.count < headers.count {
                cells.append(contentsOf: Array(repeating: "", count: headers.count - cells.count))
            } else if cells.count > headers.count {
                cells = Array(cells.prefix(headers.count))
            }
            rows.append(cells)
            i += 1
        }
        guard !rows.isEmpty else { return nil }
        return (.table(headers: headers, rows: rows), i)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let marker = trimmed.first else { return false }
        guard marker == "-" || marker == "_" || marker == "*" else { return false }
        return trimmed.allSatisfy { $0 == marker }
    }

    private static func isBulletLine(_ line: String) -> Bool {
        // Must start with "- " (dash-space; content trimmed separately).
        return line.hasPrefix("- ")
    }

    private static func bulletContent(_ line: String) -> String {
        return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func parseHeading(line: String) -> Segment? {
        if line.hasPrefix("## ") {
            let body = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return .heading(level: 2, text: body)
        }
        if line.hasPrefix("# ") {
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return .heading(level: 1, text: body)
        }
        return nil
    }
}

struct ChatMarkdownView: View {

    let segments: [Segment]
    let isStreamingDraft: Bool

    init(segments: [Segment], isStreamingDraft: Bool = false) {
        self.segments = segments
        self.isStreamingDraft = isStreamingDraft
    }

    private let bodyFont: Font = .system(size: 14, weight: .regular)
    private let bodyNSFont: NSFont = .systemFont(ofSize: 14, weight: .regular)
    private let h1Font: Font = .system(size: 16, weight: .semibold)
    private let h2Font: Font = .system(size: 15, weight: .semibold)
    private let tableHeaderFont: Font = .system(size: 14, weight: .semibold)
    private let bodyLineSpacing: CGFloat = 6
    private let segmentSpacing: CGFloat = 5
    private let bulletIndent: CGFloat = 4
    private let bulletContentGap: CGFloat = 8   // glyph (•) to content
    private let bulletRowGap: CGFloat = 6       // between consecutive bullets

    var body: some View {
        VStack(alignment: .leading, spacing: segmentSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                segmentView(
                    segment,
                    isFinalStreamingSegment: isStreamingDraft && index == segments.count - 1
                )
            }
        }
    }

    @ViewBuilder
    private func segmentView(
        _ segment: Segment,
        isFinalStreamingSegment: Bool
    ) -> some View {
        switch segment {
        case .heading(let level, let text):
            Text(text)
                .font(level == 1 ? h1Font : h2Font)
                .foregroundColor(AppColor.colaDarkText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .bulletBlock(let bullets):
            VStack(alignment: .leading, spacing: bulletRowGap) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: bulletContentGap) {
                        Text("•")
                            .font(bodyFont)
                            .foregroundColor(AppColor.colaDarkText)
                        Text(bullet)
                            .font(bodyFont)
                            .foregroundColor(AppColor.colaDarkText)
                            .lineSpacing(bodyLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, bulletIndent)
                }
            }

        case .table(let headers, let rows):
            ChatMarkdownTableView(headers: headers, rows: rows)

        case .horizontalRule:
            Divider()
                .padding(.vertical, 4)

        case .prose(let text):
            if isStreamingDraft {
                StreamingProseVisualLineView(
                    text: text,
                    bodyFont: bodyFont,
                    bodyNSFont: bodyNSFont,
                    lineSpacing: bodyLineSpacing,
                    revealTrailingLine: !isFinalStreamingSegment
                )
            } else {
                Text(text)
                    .font(bodyFont)
                    .foregroundColor(AppColor.colaDarkText)
                    .lineSpacing(bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

        case .verbatim(let text):
            Text(text)
                .font(bodyFont)
                .foregroundColor(AppColor.colaDarkText)
                .lineSpacing(bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct StreamingProseVisualLineView: View {
    let text: String
    let bodyFont: Font
    let bodyNSFont: NSFont
    let lineSpacing: CGFloat
    let revealTrailingLine: Bool

    @State private var measuredWidth: CGFloat = 0
    @State private var revealState = StreamingVisualLineRevealState()

    private var effectiveWidth: CGFloat {
        measuredWidth > 1 ? measuredWidth : 520
    }

    var body: some View {
        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(revealState.lines) { line in
                StreamingVisualLineRow(
                    text: line.text,
                    revealDelay: line.revealDelay,
                    bodyFont: bodyFont
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: StreamingProseWidthPreferenceKey.self,
                    value: proxy.size.width
                )
            }
        )
        .onPreferenceChange(StreamingProseWidthPreferenceKey.self) { width in
            guard width > 1, abs(width - measuredWidth) > 0.5 else { return }
            measuredWidth = width
        }
        .onAppear {
            syncRevealState(reason: .initial)
        }
        .onChange(of: text) { _, _ in
            syncRevealState(reason: .textChanged)
        }
        .onChange(of: measuredWidth) { _, _ in
            syncRevealState(reason: .measuredWidthChanged)
        }
        .onChange(of: revealTrailingLine) { _, _ in
            syncRevealState(reason: .trailingRevealChanged)
        }
    }

    private func syncRevealState(reason: StreamingVisualLineRevealSyncReason) {
        guard !text.isEmpty else {
            revealState.reset()
            return
        }

        let visualLines = VisualLineBreaks.lines(
            for: text,
            width: effectiveWidth,
            font: bodyNSFont
        )
        revealState.update(
            visualLines: visualLines,
            revealTrailingLine: revealTrailingLine,
            reason: reason
        )
    }
}

private struct StreamingVisualLineRow: View {
    let text: String
    let revealDelay: TimeInterval
    let bodyFont: Font

    @State private var isVisible = false

    private static let revealOffset: CGFloat = 10
    private static let revealAnimation = Animation.timingCurve(
        0.17,
        0.76,
        0.18,
        1,
        duration: 0.74
    )

    var body: some View {
        Text(text)
            .font(bodyFont)
            .foregroundColor(AppColor.colaDarkText)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : Self.revealOffset)
            .onAppear(perform: reveal)
    }

    private func reveal() {
        guard !isVisible else { return }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + revealDelay
        ) {
            withAnimation(Self.revealAnimation) {
                isVisible = true
            }
        }
    }
}

private struct StreamingProseWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 1 {
            value = next
        }
    }
}

private struct ChatMarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    private let bodyFont: Font = .system(size: 14, weight: .regular)
    private let headerFont: Font = .system(size: 14, weight: .semibold)
    private let bodyLineSpacing: CGFloat = 6
    private let rowVerticalPadding: CGFloat = 10
    private let headerVerticalPadding: CGFloat = 8
    private let firstColumnWidth: CGFloat = 86
    private let secondColumnWidth: CGFloat = 158
    private let dividerOpacity: Double = 0.72
    private let columnDividerOpacity: Double = 0.48

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tableDivider

            ChatMarkdownTableRow(
                cells: headers,
                isHeader: true,
                bodyFont: bodyFont,
                headerFont: headerFont,
                bodyLineSpacing: bodyLineSpacing,
                firstColumnWidth: firstColumnWidth,
                secondColumnWidth: secondColumnWidth,
                columnDividerOpacity: columnDividerOpacity
            )
            .padding(.vertical, headerVerticalPadding)

            tableDivider

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                ChatMarkdownTableRow(
                    cells: row,
                    isHeader: false,
                    bodyFont: bodyFont,
                    headerFont: headerFont,
                    bodyLineSpacing: bodyLineSpacing,
                    firstColumnWidth: firstColumnWidth,
                    secondColumnWidth: secondColumnWidth,
                    columnDividerOpacity: columnDividerOpacity
                )
                .padding(.vertical, rowVerticalPadding)

                if index < rows.count - 1 {
                    tableDivider
                }
            }

            tableDivider
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var tableDivider: some View {
        Rectangle()
            .fill(AppColor.panelStroke.opacity(dividerOpacity))
            .frame(height: 1)
    }
}

private struct ChatMarkdownTableRow: View {
    let cells: [String]
    let isHeader: Bool
    let bodyFont: Font
    let headerFont: Font
    let bodyLineSpacing: CGFloat
    let firstColumnWidth: CGFloat
    let secondColumnWidth: CGFloat
    let columnDividerOpacity: Double

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                tableCell(cell, at: index)

                if index < cells.count - 1 {
                    Rectangle()
                        .fill(AppColor.panelStroke.opacity(columnDividerOpacity))
                        .frame(width: 1)
                        .padding(.vertical, 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableCell(_ text: String, at index: Int) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(isHeader ? headerFont : bodyFont)
            .foregroundColor(AppColor.colaDarkText)
            .lineSpacing(bodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(width: fixedWidth(for: index), alignment: .leading)
            .frame(maxWidth: index == cells.count - 1 ? .infinity : nil, alignment: .leading)
            .layoutPriority(index == cells.count - 1 ? 1 : 0)
            .padding(.leading, leadingPadding(for: index))
            .padding(.trailing, trailingPadding(for: index))
    }

    private func fixedWidth(for index: Int) -> CGFloat? {
        guard cells.count >= 3 else {
            return index == 0 ? 164 : nil
        }

        switch index {
        case 0:
            return firstColumnWidth
        case 1:
            return secondColumnWidth
        default:
            return nil
        }
    }

    private func leadingPadding(for index: Int) -> CGFloat {
        index == 0 ? 2 : 18
    }

    private func trailingPadding(for index: Int) -> CGFloat {
        index == cells.count - 1 ? 2 : 18
    }
}
