import SwiftUI

/// Lightweight Markdown renderer for chat content.
///
/// SwiftUI's built-in `Text(AttributedString(markdown:))` only honors
/// inline syntax (`**bold**`, `*italic*`, `[links]`, `` `code` ``). Block
/// elements (headings, lists, fenced code, paragraphs) are stripped to
/// plain prose, which is exactly the "unstructured response" operator
/// complaint that motivated this view.
///
/// `MarkdownText` parses the message into a small set of block kinds and
/// renders each with proper SwiftUI typography + `FeralTheme` styling:
///
/// - `# / ## / ### / #### / ##### / ######` headings
/// - Unordered list items (`- `, `* `, `+ `)
/// - Ordered list items (`1. `, `2. `, ...)
/// - Fenced code blocks (` ``` `)
/// - Plain paragraphs (with inline markdown still applied)
///
/// Anything we cannot parse falls back to inline-Markdown `AttributedString`
/// so we never lose user content. The renderer is intentionally
/// permissive — assistant output is human-authored text, not a strict
/// CommonMark grammar.
struct MarkdownText: View {
    let raw: String
    var textColor: Color = FeralTheme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    private var blocks: [Block] { Self.parse(raw) }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineAttributed(text))
                .font(headingFont(for: level))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(inlineAttributed(text))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        case .unordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(FeralTheme.textSecondary)
                        Text(inlineAttributed(item))
                            .foregroundStyle(textColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).")
                            .foregroundStyle(FeralTheme.textSecondary)
                            .monospacedDigit()
                        Text(inlineAttributed(item))
                            .foregroundStyle(textColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code(let language, let body):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(FeralTheme.fontMonoCaption)
                        .foregroundStyle(FeralTheme.textTertiary)
                }
                Text(body)
                    .font(FeralTheme.fontMono)
                    .foregroundStyle(textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: FeralTheme.radiusSM, style: .continuous)
                            .fill(Color.black.opacity(0.30))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: FeralTheme.radiusSM, style: .continuous)
                            .stroke(FeralTheme.hairline, lineWidth: 0.5)
                    )
            }
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    /// Parse inline markdown (`**bold**`, `*italic*`, `` `code` ``, links).
    /// Falls back to plain text if AttributedString rejects the source.
    private func inlineAttributed(_ source: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: source, options: opts) {
            return attributed
        }
        return AttributedString(source)
    }

    // MARK: - Block parser

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case unordered([String])
        case ordered([String])
        case code(language: String?, body: String)
    }

    /// Walk the raw text once, accumulating blocks. The grammar is
    /// intentionally tolerant: list runs aggregate consecutive bullet
    /// lines, code fences swallow everything until the closing fence,
    /// blank lines flush the current paragraph.
    static func parse(_ raw: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var unordered: [String] = []
        var ordered: [String] = []
        var inCode = false
        var codeLang: String? = nil
        var codeBody: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }
        func flushUnordered() {
            if !unordered.isEmpty {
                blocks.append(.unordered(unordered))
                unordered.removeAll()
            }
        }
        func flushOrdered() {
            if !ordered.isEmpty {
                blocks.append(.ordered(ordered))
                ordered.removeAll()
            }
        }
        func flushAll() {
            flushParagraph()
            flushUnordered()
            flushOrdered()
        }

        let lines = raw.components(separatedBy: "\n")
        for line in lines {
            // Code fence handling supersedes everything else.
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: codeLang, body: codeBody.joined(separator: "\n")))
                    codeBody.removeAll()
                    codeLang = nil
                    inCode = false
                } else {
                    flushAll()
                    let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLang = lang.isEmpty ? nil : lang
                    inCode = true
                }
                continue
            }
            if inCode {
                codeBody.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushAll()
                continue
            }

            // Heading: 1-6 leading hashes followed by space.
            if let hashCount = leadingHashCount(trimmed), hashCount >= 1, hashCount <= 6 {
                flushAll()
                let body = String(trimmed.dropFirst(hashCount)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: hashCount, text: body))
                continue
            }

            // Unordered list item: `- `, `* `, or `+ `.
            if let item = unorderedItem(trimmed) {
                flushParagraph()
                flushOrdered()
                unordered.append(item)
                continue
            }

            // Ordered list item: `1. ` etc.
            if let item = orderedItem(trimmed) {
                flushParagraph()
                flushUnordered()
                ordered.append(item)
                continue
            }

            // Otherwise it's a paragraph line. Flush list runs first.
            flushUnordered()
            flushOrdered()
            paragraph.append(line)
        }

        if inCode {
            // Unclosed fence — emit whatever we collected so we don't
            // silently drop the assistant's code.
            blocks.append(.code(language: codeLang, body: codeBody.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    private static func leadingHashCount(_ s: String) -> Int? {
        var count = 0
        for ch in s {
            if ch == "#" { count += 1 } else { break }
        }
        guard count > 0 else { return nil }
        // Must be followed by whitespace to count as a heading marker.
        let rest = s.dropFirst(count)
        guard let first = rest.first, first.isWhitespace else { return nil }
        return count
    }

    private static func unorderedItem(_ s: String) -> String? {
        for marker in ["- ", "* ", "+ "] {
            if s.hasPrefix(marker) {
                return String(s.dropFirst(marker.count))
            }
        }
        return nil
    }

    private static func orderedItem(_ s: String) -> String? {
        // Match `<digits>. <body>`.
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber { idx = s.index(after: idx) }
        guard idx > s.startIndex, idx < s.endIndex, s[idx] == "." else { return nil }
        let after = s.index(after: idx)
        guard after < s.endIndex, s[after].isWhitespace else { return nil }
        let body = s[s.index(after: after)...]
        return String(body)
    }
}
