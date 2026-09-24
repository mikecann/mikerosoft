import Foundation

struct PromptItem: Equatable {
    enum Kind: Equatable {
        /// Something to read. Only lines are navigation stops.
        case line
        /// A markdown heading, shown as a small section label.
        case heading
        /// A production note, such as a Notion callout.
        case cue
        /// A fenced code block, shown dimmed for reference.
        case code
    }

    var kind: Kind
    var text: String
    var depth: Int = 0

    static func line(_ text: String, depth: Int = 0) -> PromptItem {
        PromptItem(kind: .line, text: text, depth: depth)
    }

    static func heading(_ text: String) -> PromptItem {
        PromptItem(kind: .heading, text: text)
    }

    static func cue(_ text: String, depth: Int = 0) -> PromptItem {
        PromptItem(kind: .cue, text: text, depth: depth)
    }
}

/// Turns pasted notes (plain text, markdown, or Notion's markdown copy) into
/// prompter items. It strips list markers, inline formatting, and Notion's
/// layout tags, and keeps list nesting as a depth so the structure stays
/// readable.
enum ScriptParser {
    static func parse(_ text: String) -> [PromptItem] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let indent = IndentScale(lines: lines)

        var items: [PromptItem] = []
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let depth = indent.depth(of: raw)
            index += 1

            if trimmed.isEmpty || isDivider(trimmed) || trimmed == "<empty-block/>" {
                continue
            }

            if trimmed.hasPrefix("```") {
                // A fence closes only with at least as many backticks as it opened with.
                let fence = String(trimmed.prefix { $0 == "`" })
                var code: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // closing fence
                let body = code.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    items.append(PromptItem(kind: .code, text: body, depth: depth))
                }
                continue
            }

            if trimmed.hasPrefix("<callout") {
                var body: [String] = []
                let singleLine = trimmed.contains("</callout>")
                if singleLine {
                    body.append(trimmed)
                } else {
                    while index < lines.count,
                          lines[index].trimmingCharacters(in: .whitespaces) != "</callout>" {
                        body.append(lines[index])
                        index += 1
                    }
                    index += 1 // closing tag
                }
                let text = body.map(cleanLine).filter { !$0.isEmpty }.joined(separator: "\n")
                if !text.isEmpty {
                    items.append(.cue(text, depth: depth))
                }
                continue
            }

            if let heading = headingText(trimmed) {
                let text = cleanInline(heading)
                if !text.isEmpty { items.append(.heading(text)) }
                continue
            }

            let text = cleanLine(trimmed)
            if !text.isEmpty {
                items.append(.line(text, depth: depth))
            }
        }
        return items
    }

    // MARK: - Line cleanup

    private static func isDivider(_ line: String) -> Bool {
        line.count >= 3 && ["-", "*", "_"].contains { marker in
            line.allSatisfy { String($0) == marker || $0 == " " }
        }
    }

    private static func headingText(_ line: String) -> String? {
        guard let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else {
            return nil
        }
        return String(line[match.upperBound...])
    }

    private static func cleanLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        // Quote markers, then one list marker, then an optional checkbox.
        text = replacing(#"^(>\s?)+"#, in: text, with: "")
        text = replacing(#"^[-*+•◦▪‣–](\s+|$)"#, in: text, with: "")
        text = replacing(#"^\d{1,3}[.)]\s+"#, in: text, with: "")
        text = replacing(#"^\[[ xX]\]\s+"#, in: text, with: "")
        return cleanInline(text)
    }

    private static func cleanInline(_ line: String) -> String {
        // Swap code spans for placeholders so `<div>` in backticks survives
        // the tag and markup cleanup, then put their contents back.
        var spans: [String] = []
        var text = line
        while let match = text.range(of: #"`[^`]+`"#, options: .regularExpression) {
            spans.append(String(text[match].dropFirst().dropLast()))
            text.replaceSubrange(match, with: "\u{E000}\(spans.count - 1)\u{E001}")
        }
        text = cleanMarkup(text)
        for (index, span) in spans.enumerated() {
            text = text.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: span)
        }
        return text
    }

    private static func cleanMarkup(_ line: String) -> String {
        var text = line
        // Notion annotates blocks with trailing attributes such as
        // {toggle="true"} or {color="gray"}.
        text = replacing(#"\s*\{[^{}]*="[^{}]*\}\s*$"#, in: text, with: "")
        text = replacing(#"</?[A-Za-z][^>]*>"#, in: text, with: " ")
        text = replacing(#"!\[[^\]]*\]\([^)]*\)"#, in: text, with: "")
        text = replacing(#"\[([^\]]+)\]\([^)]*\)"#, in: text, with: "$1")
        text = replacing(#"\*\*(.+?)\*\*"#, in: text, with: "$1")
        text = replacing(#"__(.+?)__"#, in: text, with: "$1")
        text = replacing(#"~~(.+?)~~"#, in: text, with: "$1")
        text = replacing(#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, in: text, with: "$1")
        text = replacing(#"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, in: text, with: "$1")
        for (entity, value) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = replacing(#"\s+"#, in: text, with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

/// Works out how much leading whitespace makes one level of nesting. Notion
/// copies use four spaces, other editors two, and some use tabs.
private struct IndentScale {
    private let unit: Int
    private let base: Int

    init(lines: [String]) {
        var measured: [(tabs: Int, spaces: Int)] = []
        var insideBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if insideBlock {
                if trimmed.hasPrefix("```") || trimmed == "</callout>" { insideBlock = false }
                continue
            }
            if trimmed.hasPrefix("```")
                || (trimmed.hasPrefix("<callout") && !trimmed.contains("</callout>")) {
                insideBlock = true
            }
            measured.append(Self.leading(line))
        }

        let spaceOnly = measured.filter { $0.tabs == 0 }.map(\.spaces)
        let minimumSpaces = spaceOnly.min() ?? 0
        let steps = spaceOnly.map { $0 - minimumSpaces }.filter { $0 > 0 }
        let unit = steps.min() ?? 4
        self.unit = unit
        base = measured.map { $0.tabs * unit + $0.spaces }.min() ?? 0
    }

    func depth(of line: String) -> Int {
        let leading = Self.leading(line)
        return max(0, (leading.tabs * unit + leading.spaces - base) / unit)
    }

    private static func leading(_ line: String) -> (tabs: Int, spaces: Int) {
        var tabs = 0
        var spaces = 0
        for character in line {
            if character == "\t" { tabs += 1 } else if character == " " { spaces += 1 } else { break }
        }
        return (tabs, spaces)
    }
}
