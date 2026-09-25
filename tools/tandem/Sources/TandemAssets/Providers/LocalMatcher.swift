import Foundation

/// Searching a provider's whole index in memory (Noto, SVGL and Fontsource
/// publish everything in one response). Every query word must be the start
/// of some word in the asset; matches in the name rank above matches in
/// tags.
struct LocalMatcher {
    let words: [String]
    /// Emoji in the query, matched against tags as they are.
    let emoji: [String]

    init(_ text: String) {
        words = Self.tokens(text)
        emoji = AssetCatalog.emoji(in: text)
    }

    var isEmpty: Bool { words.isEmpty && emoji.isEmpty }

    static func tokens(_ text: String) -> [String] {
        String(text.filter { !AssetCatalog.isEmoji($0) })
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// A score above zero when every word matches: 2 for each word found in
    /// the name, 1 for each found only in the other text. Nil when a word
    /// doesn't match at all.
    func score(name: String, other: [String]) -> Int? {
        for character in emoji where !other.contains(character) { return nil }
        guard !words.isEmpty else { return emoji.isEmpty ? 0 : 1 }
        let nameTokens = Self.tokens(name)
        let otherTokens = other.flatMap(Self.tokens)
        var total = 0
        for word in words {
            if nameTokens.contains(where: { $0.hasPrefix(word) }) {
                total += 2
            } else if otherTokens.contains(where: { $0.hasPrefix(word) }) {
                total += 1
            } else {
                return nil
            }
        }
        return total
    }

    /// Filters and orders assets: best score first, then popularity, then
    /// the provider's own order.
    func rank(_ assets: [Asset]) -> [Asset] {
        assets.enumerated()
            .compactMap { index, asset in score(name: asset.name, other: asset.tags + [asset.providerID]).map { (asset, $0, index) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if (a.0.popularity ?? 0) != (b.0.popularity ?? 0) { return (a.0.popularity ?? 0) > (b.0.popularity ?? 0) }
                return a.2 < b.2
            }
            .map(\.0)
    }

    /// One page of results, 1-based.
    static func page<T>(_ items: [T], page: Int, perPage: Int) -> [T] {
        let size = max(1, perPage)
        let start = max(0, page - 1) * size
        guard start < items.count else { return [] }
        return Array(items[start..<min(items.count, start + size)])
    }
}
