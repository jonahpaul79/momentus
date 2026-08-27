import Foundation
import SwiftUI

/// Renders the block-level Markdown Claude commonly returns without treating
/// the user's own messages as markup.
struct MarkdownMessageView: View {
    let markdown: String
    let theme: AppTheme

    private enum Block {
        case paragraph(String)
        case heading(level: Int, text: String)
        case unorderedItem(String)
        case orderedItem(number: String, text: String)
        case quote(String)
        case code(String)
        case divider
    }

    var body: some View {
        let blocks = Self.parse(markdown)

        VStack(alignment: .leading, spacing: theme.spacing.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(theme.colors.accentPrimary)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            inlineMarkdown(text)
                .font(theme.typography.bodyMedium)

        case .heading(let level, let text):
            inlineMarkdown(text)
                .font(level == 1 ? theme.typography.headlineLarge : theme.typography.headlineSmall)
                .padding(.top, theme.spacing.xs)

        case .unorderedItem(let text):
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.s) {
                Text("•")
                inlineMarkdown(text)
            }
            .font(theme.typography.bodyMedium)

        case .orderedItem(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: theme.spacing.s) {
                Text("\(number).")
                    .monospacedDigit()
                inlineMarkdown(text)
            }
            .font(theme.typography.bodyMedium)

        case .quote(let text):
            HStack(alignment: .top, spacing: theme.spacing.s) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.colors.accentPrimary.opacity(0.55))
                    .frame(width: 3)
                inlineMarkdown(text)
                    .font(theme.typography.bodyMedium)
                    .foregroundStyle(theme.colors.textSecondary)
            }

        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(theme.spacing.m)
            }
            .background(theme.colors.backgroundPrimary.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.s))

        case .divider:
            Divider()
                .overlay(theme.colors.border)
        }
    }

    private func inlineMarkdown(_ source: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(source)
    }

    private static func parse(_ markdown: String) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                index += 1
                var codeLines: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
            } else if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if let item = unorderedItem(from: trimmed) {
                flushParagraph()
                blocks.append(.unorderedItem(item))
            } else if let item = orderedItem(from: trimmed) {
                flushParagraph()
                blocks.append(.orderedItem(number: item.number, text: item.text))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else {
                paragraph.append(trimmed)
            }

            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...3).contains(level), line.dropFirst(level).first == " " else { return nil }
        return (level, String(line.dropFirst(level + 1)))
    }

    private static func unorderedItem(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func orderedItem(from line: String) -> (number: String, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = String(line[..<dot])
        guard Int(number) != nil else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return (number, String(line[line.index(after: afterDot)...]))
    }
}
