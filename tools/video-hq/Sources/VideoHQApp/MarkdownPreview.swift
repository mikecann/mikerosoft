import Foundation
import SwiftUI

enum ScriptDisplayMode: String, CaseIterable, Identifiable {
    case raw = "Raw"
    case preview = "Preview"

    var id: Self { self }
}

enum MarkdownPreviewRenderer {
    static func render(_ markdown: String) -> AttributedString {
        let previewMarkdown = markdown
            .components(separatedBy: .newlines)
            .filter {
                $0.trimmingCharacters(in: .whitespaces) != "<empty-block/>"
            }
            .joined(separator: "\n")
        do {
            return try AttributedString(
                markdown: previewMarkdown,
                options: .init(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            // A malformed or incomplete draft should remain readable in Preview.
            return AttributedString(previewMarkdown)
        }
    }

    static func blocks(from markdown: String) -> [MarkdownPreviewBlock] {
        let rendered = render(markdown)
        var blocks: [MarkdownPreviewBlock] = []

        for run in rendered.runs {
            let components = run.presentationIntent?.components ?? []
            let blockID = components.first?.identity ?? -(blocks.count + 1)
            let content = AttributedString(rendered[run.range])

            if blocks.last?.id == blockID {
                blocks[blocks.count - 1].content.append(content)
            } else {
                blocks.append(MarkdownPreviewBlock(
                    id: blockID,
                    kind: blockKind(from: components),
                    content: content,
                    indentationLevel: listIndentation(in: components)
                ))
            }
        }

        return blocks.filter {
            String($0.content.characters).trimmingCharacters(in: .whitespacesAndNewlines) != "<empty-block/>"
        }
    }

    private static func blockKind(
        from components: [PresentationIntent.IntentType]
    ) -> MarkdownPreviewBlockKind {
        var listOrdinal: Int?
        var isUnorderedList = false
        var isOrderedList = false
        var isBlockQuote = false

        for component in components {
            switch component.kind {
            case .header(let level):
                return .heading(level: level)
            case .codeBlock(let language):
                return .codeBlock(language: language)
            case .thematicBreak:
                return .thematicBreak
            case .listItem(let ordinal):
                listOrdinal = ordinal
            case .unorderedList:
                isUnorderedList = true
            case .orderedList:
                isOrderedList = true
            case .blockQuote:
                isBlockQuote = true
            default:
                break
            }
        }

        if let listOrdinal, isOrderedList {
            return .orderedListItem(ordinal: listOrdinal)
        }
        if listOrdinal != nil, isUnorderedList {
            return .unorderedListItem
        }
        if isBlockQuote {
            return .blockQuote
        }
        return .paragraph
    }

    private static func listIndentation(
        in components: [PresentationIntent.IntentType]
    ) -> Int {
        components.reduce(into: 0) { level, component in
            switch component.kind {
            case .orderedList, .unorderedList:
                level += 1
            default:
                break
            }
        }
    }
}

enum MarkdownPreviewBlockKind: Equatable {
    case heading(level: Int)
    case paragraph
    case unorderedListItem
    case orderedListItem(ordinal: Int)
    case blockQuote
    case codeBlock(language: String?)
    case thematicBreak
}

struct MarkdownPreviewBlock: Identifiable, Equatable {
    let id: Int
    let kind: MarkdownPreviewBlockKind
    var content: AttributedString
    let indentationLevel: Int
}

struct MarkdownPreview: View {
    private let blocks: [MarkdownPreviewBlock]

    init(markdown: String) {
        blocks = MarkdownPreviewRenderer.blocks(from: markdown)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 15) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownPreviewBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.content)
                .font(headingFont(level: level))
                .fontWeight(.semibold)
                .padding(.top, level == 1 ? 8 : 3)
        case .paragraph:
            Text(block.content)
                .font(.body)
                .lineSpacing(3)
        case .unorderedListItem:
            listItem(block, marker: "•")
        case .orderedListItem(let ordinal):
            listItem(block, marker: "\(ordinal).")
        case .blockQuote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: 3)
                Text(block.content)
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        case .codeBlock(let language):
            VStack(alignment: .leading, spacing: 7) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(block.content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .thematicBreak:
            Divider()
        }
    }

    private func listItem(_ block: MarkdownPreviewBlock, marker: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Text(block.content)
                .font(.body)
                .lineSpacing(3)
        }
        .padding(.leading, CGFloat(max(0, block.indentationLevel - 1)) * 22)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }
}
